"""HTTP driver for the verify-server skill. Runs inside the `driver` service on the
verify stack's network and talks to the real webapp at $BASE_URL.

    python /drive.py doctor
    python /drive.py health | calendar-today | sessions-dates
    python /drive.py static-entity-create <name>
    python /drive.py static-entity-list <name>
    python /drive.py static-entity-delete <id>

Every call prints one JSON record (method, path, whether a bearer was sent,
response status + body) to stdout; the bearer value itself is never printed.
Exit code is non-zero if an assertion fails.
"""

import json
import os
import sys
import urllib.error
import urllib.request
from datetime import date

BASE = os.environ.get("BASE_URL", "http://webapp:8000")
TOKEN = os.environ["IOS_BEARER_TOKEN"]


def call(method, path, auth, body=None):
    headers = {}
    data = None
    if auth:
        headers["Authorization"] = f"Bearer {TOKEN}"
    if body is not None:
        data = json.dumps(body).encode()
        headers["Content-Type"] = "application/json"
    req = urllib.request.Request(BASE + path, data=data, method=method, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            status, raw = resp.status, resp.read()
    except urllib.error.HTTPError as exc:
        status, raw = exc.code, exc.read()
    try:
        parsed = json.loads(raw)
    except ValueError:
        parsed = raw.decode(errors="replace")
    print(json.dumps({
        "request": {"method": method, "path": path, "bearer": "sent" if auth else "none", "body": body},
        "response": {"status": status, "body": parsed},
    }, indent=2, sort_keys=True), flush=True)
    return status, parsed


failures = []


def check(label, ok):
    print(("PASS  " if ok else "FAIL  ") + label, flush=True)
    if not ok:
        failures.append(label)


def require_auth_first(path):
    status, body = call("GET", path, auth=False)
    check(f"GET {path} without bearer -> 401 missing_bearer_token",
          status == 401 and body.get("detail") == "missing_bearer_token")


def doctor():
    status, body = call("GET", "/health", auth=False)
    check("GET /health -> 200 without bearer", status == 200)
    up = body.get("upstream", {}) if isinstance(body, dict) else {}
    check("health: postgres ok", up.get("postgres") == "ok")
    check("health: qdrant ok", up.get("qdrant") == "ok")
    check("health: msgraph is fixture (no Entra needed)", up.get("msgraph") == "fixture")
    require_auth_first("/api/sessions/dates")
    status, _ = call("GET", "/api/sessions/dates", auth=True)
    check("GET /api/sessions/dates with bearer -> 200", status == 200)
    print("note: health.status is expected to be down/degraded: whisper, voxtral, ollama and "
          "lightrag are deliberately not in this stack.")


def health():
    status, body = call("GET", "/health", auth=False)
    check("200", status == 200)
    check("upstream has postgres + qdrant + msgraph",
          isinstance(body, dict) and {"postgres", "qdrant", "msgraph"} <= set(body.get("upstream", {})))


def calendar_today():
    today = date.today().isoformat()
    path = f"/today/calendar?date={today}"
    require_auth_first(path)
    status, body = call("GET", path, auth=True)
    check("with bearer -> 200", status == 200)
    check("date echoed and fixture events returned",
          isinstance(body, dict) and body.get("date") == today and len(body.get("events", [])) > 0)


def sessions_dates():
    require_auth_first("/api/sessions/dates")
    status, body = call("GET", "/api/sessions/dates", auth=True)
    check("with bearer -> 200 and dates is a list", status == 200 and isinstance(body.get("dates"), list))
    status, body = call("GET", "/api/sessions/dates?date_from=not-a-date", auth=True)
    check("bad date_from -> 400 invalid_date_from", status == 400 and body.get("detail") == "invalid_date_from")


def static_entity_create(name):
    payload = {"name": name, "entity_type": "Category", "description": "KA-8 verify-server probe"}
    status, body = call("POST", "/api/admin/static-entities", auth=False, body=payload)
    check("POST without bearer -> 401", status == 401)
    status, body = call("POST", "/api/admin/static-entities", auth=True, body=payload)
    check("POST with bearer -> 200 {status: ok, id}", status == 200 and body.get("status") == "ok" and "id" in body)
    print(f"ENTITY_ID={body.get('id') if isinstance(body, dict) else ''}")


def static_entity_list(name):
    status, body = call("GET", "/api/admin/static-entities", auth=True)
    check("GET -> 200 and list contains the probe row",
          status == 200 and any(r.get("name") == name for r in body))


def static_entity_delete(entity_id):
    status, body = call("DELETE", f"/api/admin/static-entities/{entity_id}", auth=True)
    check("DELETE -> 200", status == 200)


COMMANDS = {
    "doctor": (doctor, 0),
    "health": (health, 0),
    "calendar-today": (calendar_today, 0),
    "sessions-dates": (sessions_dates, 0),
    "static-entity-create": (static_entity_create, 1),
    "static-entity-list": (static_entity_list, 1),
    "static-entity-delete": (static_entity_delete, 1),
}

if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else ""
    if cmd not in COMMANDS:
        sys.exit(__doc__)
    fn, nargs = COMMANDS[cmd]
    fn(*sys.argv[2:2 + nargs])
    sys.exit(1 if failures else 0)
