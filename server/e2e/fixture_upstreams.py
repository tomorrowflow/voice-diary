"""Fixture Ollama + LightRAG for the isolated e2e stack (project `vd-e2e`).

One stdlib process, two ports, so the e2e webapp never reaches a real LLM or
knowledge graph on the LAN:

- :11434  Ollama   GET /api/tags, POST /v1/chat/completions, POST /api/chat
- :9621   LightRAG GET /health, POST /query, POST /documents/text,
                   DELETE /documents/delete_document

Answers are canned and use the fictional e2e cast only. Every request is
recorded; `GET /_fixture/requests` on either port returns the log so a test can
prove the server actually called the upstream. Nothing here is a secret.
"""

import json
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

OLLAMA_PORT = 11434
LIGHTRAG_PORT = 9621

CONTEXT_SUMMARY = (
    "**Letzte Woche:**\n- Thema: Release-Planung Projekt Leuchtturm\n"
    "- Offenes TODO: Testplan mit Mira Lindqvist abstimmen\n"
    "**Personen-Kontext:**\n- Mira Lindqvist: Produktleiterin, letzte Interaktion: Planung"
)
ANALYSIS = {
    "relationships": [
        {
            "source": "Jonas Falk",
            "relationship": "diskutierte_mit",
            "target": "Mira Lindqvist",
            "context": "Abstimmung zum Testplan",
            "continuity": "new",
            "date": "2026-01-01",
        }
    ],
    "projects": [
        {
            "name": "Projekt Leuchtturm",
            "status": "in_arbeit",
            "status_change": "unchanged",
            "involved_persons": ["Jonas Falk", "Mira Lindqvist"],
            "involved_companies": ["Fjordwerk"],
            "technologies": [],
            "context": "Release-Planung",
            "date": "2026-01-01",
        }
    ],
    "decisions": [],
    "todos": [
        {
            "action": "Testplan abstimmen",
            "assignee": "Jonas Falk",
            "priority": "mittel",
            "context": "Vor dem Release",
            "recurrence": "new",
            "first_mentioned": None,
            "date": "2026-01-01",
        }
    ],
    "insights": [],
    "recurring_themes": [],
}

_log: list[dict] = []
_log_lock = threading.Lock()


def _record(service: str, method: str, path: str, body: bytes) -> None:
    entry = {"service": service, "method": method, "path": path, "bytes": len(body)}
    with _log_lock:
        _log.append(entry)


def _chat_answer(payload: dict) -> str:
    messages = payload.get("messages") or []
    prompt = str(messages[-1].get("content", "")) if messages else ""
    if payload.get("response_format", {}).get("type") == "json_object":
        return json.dumps(ANALYSIS, ensure_ascii=False)
    if "Kontext-Komprimierer" in prompt:
        return CONTEXT_SUMMARY
    return "Fixture-Antwort: Jonas Falk stimmt den Testplan mit Mira Lindqvist ab."


class _Handler(BaseHTTPRequestHandler):
    service = ""

    def log_message(self, fmt, *args):  # noqa: D102 - quiet; the request log is the record
        return

    def _send(self, status: int, body: object) -> None:
        raw = json.dumps(body, ensure_ascii=False).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def _body(self) -> bytes:
        return self.rfile.read(int(self.headers.get("Content-Length") or 0))

    def _json(self, raw: bytes) -> dict:
        try:
            parsed = json.loads(raw or b"{}")
        except ValueError:
            return {}
        return parsed if isinstance(parsed, dict) else {}

    def do_GET(self):  # noqa: N802
        if self.path == "/_fixture/requests":
            with _log_lock:
                return self._send(200, list(_log))
        if self.client_address[0] != "127.0.0.1":  # skip the container's own healthcheck
            _record(self.service, "GET", self.path, b"")
        if self.service == "ollama" and self.path == "/api/tags":
            return self._send(200, {"models": [{"name": "fixture"}]})
        if self.service == "lightrag" and self.path == "/health":
            return self._send(200, {"status": "healthy"})
        self._send(404, {"detail": "not_found"})

    def do_POST(self):  # noqa: N802
        raw = self._body()
        _record(self.service, "POST", self.path, raw)
        payload = self._json(raw)
        if self.service == "ollama" and self.path == "/v1/chat/completions":
            return self._send(
                200, {"choices": [{"message": {"role": "assistant", "content": _chat_answer(payload)}}]}
            )
        if self.service == "ollama" and self.path == "/api/chat":
            return self._send(
                200, {"message": {"role": "assistant", "content": _chat_answer(payload)}, "done": True}
            )
        if self.service == "lightrag" and self.path == "/query":
            return self._send(200, {"response": CONTEXT_SUMMARY})
        if self.service == "lightrag" and self.path == "/documents/text":
            return self._send(200, {"status": "success", "message": "fixture", "track_id": "fixture"})
        self._send(404, {"detail": "not_found"})

    def do_DELETE(self):  # noqa: N802
        raw = self._body()
        _record(self.service, "DELETE", self.path, raw)
        if self.service == "lightrag" and self.path == "/documents/delete_document":
            return self._send(200, {"status": "deletion_started", "message": "fixture"})
        self._send(404, {"detail": "not_found"})


def _serve(service: str, port: int) -> ThreadingHTTPServer:
    handler = type(f"{service.title()}Handler", (_Handler,), {"service": service})
    return ThreadingHTTPServer(("0.0.0.0", port), handler)


if __name__ == "__main__":
    ollama = _serve("ollama", OLLAMA_PORT)
    threading.Thread(target=ollama.serve_forever, daemon=True).start()
    _serve("lightrag", LIGHTRAG_PORT).serve_forever()
