"""HTTP driver for the verify-server skill. Runs inside the `driver` service on the
verify stack's network and talks to the real webapp at $BASE_URL.

    python /drive.py doctor
    python /drive.py health | calendar-today | sessions-dates
    python /drive.py session-upload-whisper-down <session_id>
    python /drive.py session-status <session_id> legacy|coded
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


LAST_RESPONSE_HEADERS = {}


def call(method, path, auth, body=None, multipart=None):
    """`multipart` is (content_type, bytes) and replaces the JSON `body`."""
    headers = {}
    data = None
    if auth:
        headers["Authorization"] = f"Bearer {TOKEN}"
    if body is not None:
        data = json.dumps(body).encode()
        headers["Content-Type"] = "application/json"
    if multipart is not None:
        headers["Content-Type"], data = multipart
    req = urllib.request.Request(BASE + path, data=data, method=method, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            status, raw = resp.status, resp.read()
            LAST_RESPONSE_HEADERS.clear()
            LAST_RESPONSE_HEADERS.update({k.lower(): v for k, v in resp.headers.items()})
    except urllib.error.HTTPError as exc:
        status, raw = exc.code, exc.read()
        LAST_RESPONSE_HEADERS.clear()
        LAST_RESPONSE_HEADERS.update({k.lower(): v for k, v in exc.headers.items()})
    try:
        parsed = json.loads(raw)
    except ValueError:
        parsed = raw.decode(errors="replace")
    print(json.dumps({
        "request": {
            "method": method, "path": path, "bearer": "sent" if auth else "none",
            "body": body if multipart is None else "<multipart session bundle>",
        },
        "response": {"status": status, "body": parsed, "retry_after": LAST_RESPONSE_HEADERS.get("retry-after")},
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


def _session_bundle(session_id):
    """A minimal one-segment iOS session bundle as multipart/form-data."""
    manifest = {
        "session_id": session_id,
        "date": "2026-07-01",
        "device": "iPhone17,2",
        "app_version": "1.0",
        "audio_codec": {"codec": "aac-lc", "sample_rate": 16000, "channels": 1, "bitrate": 64000},
        "segments": [{
            "segment_id": "s01",
            "segment_type": "drive_by",
            "audio_file": "segments/s01.m4a",
            "captured_at": "2026-07-01T10:00:00Z",
        }],
    }
    boundary = "----verify-server-ufh01"
    parts = [
        ("manifest", "manifest.json", "application/json", json.dumps(manifest).encode()),
        ("segments/s01.m4a", "s01.m4a", "audio/mp4", b"verify-server-not-real-audio"),
    ]
    body = b""
    for name, filename, ctype, content in parts:
        body += (
            f'--{boundary}\r\nContent-Disposition: form-data; name="{name}"; '
            f'filename="{filename}"\r\nContent-Type: {ctype}\r\n\r\n'
        ).encode() + content + b"\r\n"
    body += f"--{boundary}--\r\n".encode()
    return f"multipart/form-data; boundary={boundary}", body


def session_upload_whisper_down(session_id):
    """Whisper is not in this stack, so the real preflight fails: expect the
    failure contract and (checked separately with psql) nothing persisted."""
    status, body = call("POST", "/api/sessions", auth=False, multipart=_session_bundle(session_id))
    check("POST /api/sessions without bearer -> 401", status == 401)
    status, body = call("POST", "/api/sessions", auth=True, multipart=_session_bundle(session_id))
    check("with bearer -> 503", status == 503)
    check("body is the failure contract (string detail + code/upstream/retryable)",
          body == {"detail": "whisper_unavailable", "code": "whisper_unavailable",
                   "upstream": "whisper", "retryable": True})
    check("no Retry-After header (no wait is known)", "retry-after" not in LAST_RESPONSE_HEADERS)
    status, body = call("GET", f"/api/sessions/{session_id}/status", auth=True)
    check("status of the rejected upload -> 404 session_not_found (nothing persisted)",
          status == 404 and body.get("detail") == "session_not_found")


def session_status(session_id, expect):
    """Read back a seeded row. expect = legacy (segments without code/upstream
    keys) or coded (segments carrying them)."""
    require_auth_first(f"/api/sessions/{session_id}/status")
    status, body = call("GET", f"/api/sessions/{session_id}/status", auth=True)
    check("with bearer -> 200", status == 200)
    segments = body.get("segments", []) if isinstance(body, dict) else []
    check("segments present", len(segments) > 0)
    if expect == "legacy":
        check("every segment reads back with null code and upstream, error unchanged",
              all(s.get("code") is None and s.get("upstream") is None and s.get("error") for s in segments))
    else:
        check("failed segment carries code whisper_timeout / upstream whisper next to its error",
              any(s.get("code") == "whisper_timeout" and s.get("upstream") == "whisper" and s.get("error")
                  for s in segments))
        check("pending_analysis segment carries code ollama_unavailable / upstream ollama",
              any(s.get("code") == "ollama_unavailable" and s.get("upstream") == "ollama"
                  for s in segments))


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
    "session-upload-whisper-down": (session_upload_whisper_down, 1),
    "session-status": (session_status, 2),
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
