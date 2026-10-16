#!/usr/bin/env python3
"""Stub Voice Diary server for the verify-ios skill (standard library only).

Serves the few routes the iOS app calls on the Evening tab, with a scenario per route, so a
simulator run can reach states a real server never produces on demand (the SPEC section 10.6.1
failure contract: HTTP 503 with `detail`, `code`, `upstream`, `retryable`).

    python3 features/verify-ios/stub_server.py --port 8781 --route /today/calendar=retryable
    python3 features/verify-ios/stub_server.py --port 8781 --set /today/calendar=not-bootstrapped
    python3 features/verify-ios/stub_server.py --port 8781 --check

Without `--set` or `--check` it serves until killed. Binds 127.0.0.1 only; the simulator reaches
the host loopback, so the app's server URL is `http://127.0.0.1:<port>`.

Scenarios (a route takes a comma-separated list: request n gets the n-th, the last repeats):

    ok                 200, the route's normal body
    retryable          503 msgraph_unavailable, retryable true
    not-bootstrapped   503 msgraph_not_bootstrapped, retryable false
    rate-limited       429 msgraph_rate_limited, retryable true, Retry-After: 5
    engine-error       502 msgraph_engine_error, retryable true
    slow               the retryable 503 after a delay (default 15 s)
    slow-ok            the 200 after a delay (default 15 s)

`name:seconds` overrides the delay of `slow` / `slow-ok` (and adds one to any other scenario).
"""

from __future__ import annotations

import argparse
import json
import socketserver
import sys
import threading
import time
import urllib.error
import urllib.request
from datetime import date as date_type
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import parse_qs, urlsplit

HOST = "127.0.0.1"
DEFAULT_DELAY = 15.0
CONTROL_PATH = "/__stub/routes"

# Routes the app calls. Everything but /health needs a bearer, as on the real server.
ROUTES = ("/health", "/today/calendar", "/api/sessions/dates")
AUTHED = frozenset({"/today/calendar", "/api/sessions/dates"})

# name -> (status, code, upstream, retryable, Retry-After). The SPEC 10.6.1 catalogue for Graph.
FAILURES: dict[str, tuple[int, str, str, bool, str | None]] = {
    "retryable": (503, "msgraph_unavailable", "msgraph", True, None),
    "not-bootstrapped": (503, "msgraph_not_bootstrapped", "msgraph", False, None),
    "rate-limited": (429, "msgraph_rate_limited", "msgraph", True, "5"),
    "engine-error": (502, "msgraph_engine_error", "msgraph", True, None),
    "slow": (503, "msgraph_unavailable", "msgraph", True, None),
}
SCENARIOS = ("ok", "slow-ok", *FAILURES)


def parse_scenario(text: str) -> tuple[str, float]:
    name, _, seconds = text.partition(":")
    name = name.strip()
    if name not in SCENARIOS:
        raise ValueError(f"unknown scenario {name!r}; one of {', '.join(SCENARIOS)}")
    if seconds:
        delay = float(seconds)
    else:
        delay = DEFAULT_DELAY if name in ("slow", "slow-ok") else 0.0
    return name, delay


def parse_sequence(text: str) -> list[tuple[str, float]]:
    return [parse_scenario(item) for item in text.split(",") if item.strip()]


def parse_route_arg(text: str) -> tuple[str, list[tuple[str, float]]]:
    route, sep, scenario = text.partition("=")
    if not sep or route not in ROUTES:
        raise ValueError(f"expected <route>=<scenario> with route one of {', '.join(ROUTES)}: {text!r}")
    sequence = parse_sequence(scenario)
    if not sequence:
        raise ValueError(f"no scenario in {text!r}")
    return route, sequence


def calendar_body(date: str, rsvp_filter: list[str]) -> dict:
    """`GET /today/calendar`: the server's TodayCalendarResponse with a few local-time events."""
    def event(event_id: str, subject: str, start: str, end: str, rsvp: str, organizer: dict,
              attendees: list[dict]) -> dict:
        return {
            "graph_event_id": event_id, "subject": subject,
            "start": f"{date}T{start}:00+02:00", "end": f"{date}T{end}:00+02:00",
            "is_all_day": False, "show_as": "busy", "rsvp_status": rsvp,
            "organizer": organizer, "attendees": attendees,
            "body_preview": "", "is_recurring": False, "web_link": "",
        }

    monica = {"name": "Monica Breitkreutz", "email": "monica.breitkreutz@example.com"}
    florian = {"name": "Florian Wolf", "email": "florian.wolf@example.com"}
    events = [
        event("STUB-1on1", "1:1 mit Monica Breitkreutz", "10:00", "10:30", "accepted", monica, [monica, florian]),
        event("STUB-sync", "BYOD Policy Sync", "11:00", "12:00", "organizer", florian, [florian, monica]),
    ]
    return {"date": date, "rsvp_filter": rsvp_filter, "events": events}


def ok_body(route: str, query: dict[str, list[str]]) -> dict:
    if route == "/health":
        return {"status": "ok", "upstream": {"postgres": "ok", "whisper": "ok", "msgraph": "fixture"}}
    if route == "/today/calendar":
        date = (query.get("date") or [date_type.today().isoformat()])[0]
        rsvp = (query.get("rsvp_filter") or ["accepted,organizer"])[0]
        return calendar_body(date, [item for item in rsvp.split(",") if item])
    return {"dates": []}


class State:
    """Per-route scenario sequences and request counters, shared by the handler threads."""

    def __init__(self, routes: dict[str, list[tuple[str, float]]], token: str | None) -> None:
        self.lock = threading.Lock()
        self.routes = {route: [("ok", 0.0)] for route in ROUTES}
        self.routes.update(routes)
        self.counts = {route: 0 for route in ROUTES}
        self.token = token

    def next_scenario(self, route: str) -> tuple[str, float]:
        with self.lock:
            sequence = self.routes[route]
            index = min(self.counts[route], len(sequence) - 1)
            self.counts[route] += 1
            return sequence[index]

    def set_route(self, route: str, sequence: list[tuple[str, float]]) -> None:
        with self.lock:
            self.routes[route] = sequence
            self.counts[route] = 0

    def snapshot(self) -> dict:
        with self.lock:
            return {route: ",".join(f"{n}:{d:g}" if d else n for n, d in seq)
                    for route, seq in self.routes.items()}


class StubServer(socketserver.ThreadingMixIn, HTTPServer):
    daemon_threads = True
    allow_reuse_address = True

    def __init__(self, address: tuple[str, int], state: State) -> None:
        self.state = state
        super().__init__(address, Handler)

    def server_bind(self) -> None:
        # HTTPServer.server_bind calls socket.getfqdn(), a reverse DNS lookup that hangs on
        # the Mac node. Bind with the plain TCP server and fill the names in by hand.
        socketserver.TCPServer.server_bind(self)
        host, port = self.server_address[:2]
        self.server_name = str(host)
        self.server_port = port


class Handler(BaseHTTPRequestHandler):
    server: StubServer
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt: str, *args: object) -> None:
        sys.stderr.write(f"{time.strftime('%H:%M:%S')} {self.address_string()} {fmt % args}\n")
        sys.stderr.flush()

    def send_json(self, status: int, body: dict, headers: dict[str, str] | None = None) -> None:
        payload = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        for name, value in (headers or {}).items():
            self.send_header(name, value)
        self.end_headers()
        self.wfile.write(payload)

    def do_GET(self) -> None:  # noqa: N802 (http.server naming)
        parts = urlsplit(self.path)
        state = self.server.state
        if parts.path == CONTROL_PATH:
            self.send_json(200, state.snapshot())
            return
        route = parts.path
        if route not in ROUTES:
            self.send_json(404, {"detail": "Not Found"})
            return
        if route in AUTHED:
            auth = self.headers.get("Authorization", "")
            if not auth.startswith("Bearer ") or not auth[7:].strip():
                self.send_json(401, {"detail": "missing_bearer_token"})
                return
            if state.token is not None and auth[7:].strip() != state.token:
                self.send_json(401, {"detail": "invalid_bearer_token"})
                return
        name, delay = state.next_scenario(route)
        if delay:
            time.sleep(delay)
        if name in ("ok", "slow-ok"):
            self.send_json(200, ok_body(route, parse_qs(parts.query)))
            return
        status, code, upstream, retryable, retry_after = FAILURES[name]
        self.send_json(
            status,
            {"detail": code, "code": code, "upstream": upstream, "retryable": retryable},
            {"Retry-After": retry_after} if retry_after else None,
        )

    def do_POST(self) -> None:  # noqa: N802
        if urlsplit(self.path).path != CONTROL_PATH:
            self.send_json(404, {"detail": "Not Found"})
            return
        length = int(self.headers.get("Content-Length") or 0)
        try:
            route, sequence = parse_route_arg(self.rfile.read(length).decode())
        except ValueError as exc:
            self.send_json(400, {"detail": str(exc)})
            return
        self.server.state.set_route(route, sequence)
        self.send_json(200, self.server.state.snapshot())


# --- client modes ---------------------------------------------------------


def request(port: int, method: str, path: str, *, data: bytes | None = None,
            bearer: str | None = None, timeout: float = 60.0) -> tuple[int, dict, dict, float]:
    """One request to the stub over 127.0.0.1: (status, headers, JSON body, seconds)."""
    req = urllib.request.Request(f"http://{HOST}:{port}{path}", data=data, method=method)
    if bearer:
        req.add_header("Authorization", f"Bearer {bearer}")
    started = time.monotonic()
    try:
        with urllib.request.urlopen(req, timeout=timeout) as response:
            status, headers, raw = response.status, response.headers, response.read()
    except urllib.error.HTTPError as err:
        status, headers, raw = err.code, err.headers, err.read()
    return status, dict(headers.items()), json.loads(raw), time.monotonic() - started


def set_route(port: int, text: str) -> dict:
    status, _, body, _ = request(port, "POST", CONTROL_PATH, data=text.encode())
    if status != 200:
        raise RuntimeError(f"set {text!r}: HTTP {status} {body}")
    return body


def check(port: int) -> int:
    """Request every route under each scenario, print one PASS/FAIL line each, restore the routes."""
    failures = 0

    def report(label: str, ok: bool, detail: str) -> None:
        nonlocal failures
        failures += 0 if ok else 1
        print(f"{'PASS' if ok else 'FAIL'} {label}: {detail}")

    _, _, before, _ = request(port, "GET", CONTROL_PATH)
    try:
        for route in ROUTES:
            bearer = "check" if route in AUTHED else None
            if route in AUTHED:
                status, _, body, _ = request(port, "GET", route)
                report(f"{route} without bearer", status == 401 and body.get("detail") == "missing_bearer_token",
                       f"HTTP {status} {json.dumps(body)}")
            for scenario in ("ok", "retryable", "not-bootstrapped", "rate-limited", "engine-error",
                             "slow:1", "slow-ok:1"):
                name, delay = parse_scenario(scenario)
                set_route(port, f"{route}={scenario}")
                path = f"{route}?date=2026-10-16" if route == "/today/calendar" else route
                status, headers, body, seconds = request(port, "GET", path, bearer=bearer)
                label = f"{route} [{scenario}]"
                detail = f"HTTP {status} {json.dumps(body)[:200]}"
                if name in ("ok", "slow-ok"):
                    good = status == 200 and (route != "/today/calendar" or (
                        body.get("date") == "2026-10-16" and len(body.get("events", [])) == 2
                        and {"graph_event_id", "subject", "start", "end", "rsvp_status", "organizer",
                             "attendees", "is_all_day", "show_as", "body_preview", "is_recurring",
                             "web_link"} <= set(body["events"][0])))
                else:
                    want = FAILURES[name]
                    good = (status == want[0] and body.get("code") == want[1] and body.get("upstream") == want[2]
                            and body.get("retryable") is want[3] and body.get("detail") == want[1]
                            and headers.get("Retry-After") == want[4])
                    if want[4]:
                        detail += f" Retry-After={headers.get('Retry-After')}"
                if delay:
                    good = good and seconds >= delay
                    detail += f" after {seconds:.1f}s"
                report(label, good, detail)
    finally:
        for route, scenario in before.items():
            set_route(port, f"{route}={scenario}")
    _, _, after, _ = request(port, "GET", CONTROL_PATH)
    report("routes restored", after == before, json.dumps(after))
    return 1 if failures else 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--port", type=int, required=True, help="TCP port on 127.0.0.1")
    parser.add_argument("--route", action="append", default=[], metavar="ROUTE=SCENARIO[,SCENARIO...]",
                        help="initial scenario for a route (default ok); repeatable")
    parser.add_argument("--token", help="bearer token the authed routes accept (default: any)")
    parser.add_argument("--set", dest="set_route", metavar="ROUTE=SCENARIO[,SCENARIO...]",
                        help="change a route on the stub already running on --port, then exit")
    parser.add_argument("--check", action="store_true",
                        help="request every route under each scenario on the running stub, then exit")
    args = parser.parse_args()

    if args.set_route:
        print(json.dumps(set_route(args.port, args.set_route)))
        return 0
    if args.check:
        return check(args.port)

    routes: dict[str, list[tuple[str, float]]] = {}
    for item in args.route:
        route, sequence = parse_route_arg(item)
        routes[route] = sequence
    server = StubServer((HOST, args.port), State(routes, args.token))
    print(f"stub listening on http://{HOST}:{args.port} {json.dumps(server.state.snapshot())}", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
