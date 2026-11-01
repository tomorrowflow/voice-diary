"""Stdlib HTTP client for the isolated e2e stack, run on the host by
scripts/e2e_stack.py (or by hand).

    python3 e2e_client.py health
    python3 e2e_client.py ready [--timeout SECONDS]
    python3 e2e_client.py session [--audio PATH] [--session-id ID] [--timeout SECONDS]

Reads BASE_URL (default http://$TAILNET_IP:8100) and IOS_BEARER_TOKEN from the
environment. Each call prints one JSON record; the bearer value is never
printed. Exit status is non-zero when an assertion fails.

`session` posts a one-segment bundle and polls GET /api/sessions/{id}/status to
its end state (anything but `processing`). The default audio is
fixture_speech.m4a next to this file: a short German clip synthesised with
espeak-ng (no real person's voice) that names only the fictional e2e cast, so
Whisper returns words and the session reaches analysis. `--audio` replaces it.
"""

import argparse
import json
import os
import sys
import time
import uuid
import urllib.error
import urllib.request
from datetime import date
from pathlib import Path

DEFAULT_AUDIO = Path(__file__).resolve().with_name("fixture_speech.m4a")
BASE = os.environ.get("BASE_URL") or f"http://{os.environ.get('TAILNET_IP', '127.0.0.1')}:8100"
TOKEN = os.environ.get("IOS_BEARER_TOKEN", "")
SEGMENT_ID = "s01"

failures: list[str] = []


def check(label: str, ok: bool) -> None:
    print(("PASS  " if ok else "FAIL  ") + label, flush=True)
    if not ok:
        failures.append(label)


# The stack is on the tailnet: never route it through an HTTP(S)_PROXY.
OPENER = urllib.request.build_opener(urllib.request.ProxyHandler({}))


def call(method: str, path: str, *, auth: bool, data: bytes | None = None,
         content_type: str | None = None, quiet: bool = False):
    headers = {}
    if auth:
        headers["Authorization"] = f"Bearer {TOKEN}"
    if content_type:
        headers["Content-Type"] = content_type
    req = urllib.request.Request(BASE + path, data=data, method=method, headers=headers)
    try:
        with OPENER.open(req, timeout=30) as resp:
            status, raw = resp.status, resp.read()
    except urllib.error.HTTPError as exc:
        status, raw = exc.code, exc.read()
    try:
        body = json.loads(raw)
    except ValueError:
        body = raw.decode(errors="replace")
    if not quiet:
        print(json.dumps({"method": method, "path": path, "bearer": "sent" if auth else "none",
                          "status": status, "body": body}, indent=2, sort_keys=True), flush=True)
    return status, body


def bundle(session_id: str, audio: bytes) -> tuple[str, bytes]:
    today = date.today().isoformat()
    manifest = {
        "session_id": session_id,
        "date": today,
        "device": "iPhone17,2",
        "app_version": "1.0",
        "audio_codec": {"codec": "aac-lc", "sample_rate": 16000, "channels": 1, "bitrate": 64000},
        "segments": [{
            "segment_id": SEGMENT_ID,
            "segment_type": "drive_by",
            "audio_file": f"segments/{SEGMENT_ID}.m4a",
            "captured_at": f"{today}T10:00:00Z",
        }],
    }
    boundary = "e2e-" + uuid.uuid4().hex
    parts = [
        ("manifest", "manifest.json", "application/json", json.dumps(manifest).encode()),
        (f"segments/{SEGMENT_ID}.m4a", f"{SEGMENT_ID}.m4a", "audio/mp4", audio),
    ]
    body = b""
    for name, filename, ctype, payload in parts:
        body += (f"--{boundary}\r\nContent-Disposition: form-data; name=\"{name}\"; "
                 f"filename=\"{filename}\"\r\nContent-Type: {ctype}\r\n\r\n").encode() + payload + b"\r\n"
    body += f"--{boundary}--\r\n".encode()
    return f"multipart/form-data; boundary={boundary}", body


def health() -> None:
    status, body = call("GET", "/health", auth=False)
    check("GET /health -> 200 without bearer", status == 200)
    up = body.get("upstream", {}) if isinstance(body, dict) else {}
    check("postgres ok", up.get("postgres") == "ok")
    check("qdrant ok", up.get("qdrant") == "ok")
    check("whisper ok", up.get("whisper") == "ok")
    check("ollama and lightrag answer from the fixture upstreams",
          up.get("ollama") == "ok" and up.get("lightrag") == "ok")
    check("msgraph serves fixtures", up.get("msgraph") == "fixture")
    status, body = call("GET", "/api/sessions/dates", auth=False)
    check("route without bearer -> 401", status == 401)
    status, body = call("GET", "/api/sessions/dates", auth=True)
    check("route with the e2e bearer -> 200", status == 200)


def ready(timeout: float) -> None:
    """Wait for /health to report `ok`: `up --wait` returns while Whisper is
    still loading its model, and the first probe after that reads `down`."""
    deadline = time.monotonic() + timeout
    status = None
    while time.monotonic() < deadline:
        try:
            code, body = call("GET", "/health", auth=False, quiet=True)
            status = body.get("status") if code == 200 and isinstance(body, dict) else None
        except OSError:
            status = None
        if status == "ok":
            break
        time.sleep(3)
    check("stack reports /health ok before the timeout", status == "ok")


def session(audio_path: str | None, session_id: str | None, timeout: float) -> None:
    audio = Path(audio_path or DEFAULT_AUDIO).read_bytes()
    session_id = session_id or f"e2e-{int(time.time())}"
    ctype, data = bundle(session_id, audio)
    status, body = call("POST", "/api/sessions", auth=True, data=data, content_type=ctype)
    check("POST /api/sessions accepted", status == 200 and body.get("session_id") == session_id)
    if failures:
        return
    deadline = time.monotonic() + timeout
    final = None
    while time.monotonic() < deadline:
        status, final = call("GET", f"/api/sessions/{session_id}/status", auth=True, quiet=True)
        if status != 200 or final["state"] != "processing":
            break
        time.sleep(2)
    print(json.dumps({"session_status": final}, indent=2, sort_keys=True), flush=True)
    state = final.get("state") if isinstance(final, dict) else None
    check("session reached an end state before the timeout", state in ("done", "partial", "failed"))
    print(f"END_STATE={state}", flush=True)


def main() -> int:
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="cmd", required=True)
    sub.add_parser("health")
    r = sub.add_parser("ready")
    r.add_argument("--timeout", type=float, default=300)
    s = sub.add_parser("session")
    s.add_argument("--audio")
    s.add_argument("--session-id")
    s.add_argument("--timeout", type=float, default=600)
    args = parser.parse_args()
    if not TOKEN:
        print("IOS_BEARER_TOKEN is not set", file=sys.stderr)
        return 2
    if args.cmd == "health":
        health()
    elif args.cmd == "ready":
        ready(args.timeout)
    else:
        session(args.audio, args.session_id, args.timeout)
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
