"""Fixture Ollama + LightRAG for the isolated e2e stack (project `vd-e2e`).

One stdlib process, two ports, so the e2e webapp never reaches a real LLM or
knowledge graph on the LAN:

- :11434  Ollama   GET /api/tags, POST /v1/chat/completions, POST /api/chat
- :9621   LightRAG GET /health, POST /query, POST /documents/text,
                   DELETE /documents/delete_document

No model is in the loop. Every chat call the session pipeline makes is
recognised by its prompt (`CHAT_KINDS`) and answered with a canned reply:

    transcript_correction  transcript_corrector   /api/chat
    fluency_check          fluency_checker        /api/chat
    entity_validation      llm_validator          /api/chat
    work_activities        harvest_llm            /api/chat
    speech_summary         enrichment             /api/chat
    context_summary        document_processor     /v1/chat/completions
    analysis               document_processor     /v1/chat/completions

Replies for transcript-bearing kinds are keyed by fixture: the first fixture in
`FIXTURES` whose marker patterns match the request claims it. A transcript no
fixture claims gets the neutral replies, so any recording still reaches `done`.
The analysis date comes from the prompt, never the clock, so the same request
always gets byte-identical bytes back.

Every pipeline request is recorded with its kind, fixture and body digest;
`GET /_fixture/requests` on either port returns the log, and
`GET /_fixture/documents` on the LightRAG port returns the documents inserted
so far (the day narrative is the `diary:<date>` one). Both live in memory, so
restarting the service empties them. Answers use the fictional e2e cast only;
nothing here is a secret.
"""

import hashlib
import json
import re
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

OLLAMA_PORT = 11434
LIGHTRAG_PORT = 9621

CONTEXT_SUMMARY = (
    "**Letzte Woche:**\n- Thema: Release-Planung Projekt Leuchtturm\n"
    "- Offenes TODO: Testplan mit Mira Lindqvist abstimmen\n"
    "**Personen-Kontext:**\n- Mira Lindqvist: Produktleiterin, letzte Interaktion: Planung"
)
FALLBACK_TEXT = "Fixture-Antwort: Jonas Falk stimmt den Testplan mit Mira Lindqvist ab."

# Matched against the whole prompt (system and user messages), first hit wins.
CHAT_KINDS = (
    ("Kontext-Komprimierer", "context_summary"),
    ("Du analysierst das Tagebuch", "analysis"),
    ("transcript correction assistant", "transcript_correction"),
    ("fluency analyser", "fluency_check"),
    ("entity validation assistant", "entity_validation"),
    ("time tracking assistant", "work_activities"),
    ("Stimme einer persönlichen Tagebuch-Assistenz", "speech_summary"),
    ("voice of a personal diary assistant", "speech_summary"),
)
ANALYSIS_DATE = re.compile(r"Du analysierst das Tagebuch eines CTOs vom (\d{4}-\d{2}-\d{2})")
ANALYSIS_SECTIONS = ("relationships", "projects", "decisions", "todos", "insights", "recurring_themes")


def cast_analysis(date: str) -> dict:
    return {
        "relationships": [
            {
                "source": "Jonas Falk",
                "relationship": "diskutierte_mit",
                "target": "Mira Lindqvist",
                "context": "Abstimmung zum Testplan",
                "continuity": "new",
                "date": date,
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
                "date": date,
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
                "date": date,
            }
        ],
        "insights": [],
        "recurring_themes": [],
    }


# What a transcript no fixture claims gets. A reply is JSON-able data, a string
# (sent as is) or a function of the analysis date.
NEUTRAL_REPLIES = {
    "transcript_correction": {"corrections": []},
    "fluency_check": {"issues": []},
    "entity_validation": {"validations": []},
    "work_activities": {"activities": []},
    "analysis": lambda date: {section: [] for section in ANALYSIS_SECTIONS},
    "context_summary": CONTEXT_SUMMARY,
    "speech_summary": FALLBACK_TEXT,
}

# Fixtures override the neutral replies they have an answer for. The session
# clip (e2e/fixture_speech.m4a) speaks the cast's names, so it lands on this one.
FIXTURES = {
    "e2e-cast": {
        # Regexes, case-insensitive. Whisper may inflect a name ("Jonas Falke"),
        # so only the start of a name is anchored; "Mira" alone must be a word.
        "markers": (r"\bJonas Falk", r"\bMira\b", r"Leuchtturm", r"Fjordwerk"),
        "replies": {
            "analysis": cast_analysis,
            "work_activities": {
                "activities": [
                    {
                        "description": "Abstimmung des Testplans für Projekt Leuchtturm",
                        "estimated_hours": 1.5,
                        "category": "planning",
                    }
                ]
            },
        },
    },
}

_log: list[dict] = []
_documents: dict[str, dict] = {}
_lock = threading.Lock()


def _record(service: str, method: str, path: str, body: bytes, kind: str, fixture: str | None = None) -> None:
    entry = {
        "service": service,
        "method": method,
        "path": path,
        "kind": kind,
        "fixture": fixture,
        "bytes": len(body),
        "sha256": hashlib.sha256(body).hexdigest(),
    }
    with _lock:
        _log.append(entry)


def chat_kind(prompt: str) -> str:
    return next((kind for marker, kind in CHAT_KINDS if marker in prompt), "unknown")


def select_fixture(prompt: str) -> str | None:
    for name, fixture in FIXTURES.items():
        if any(re.search(marker, prompt, re.IGNORECASE) for marker in fixture["markers"]):
            return name
    return None


def chat_reply(payload: dict) -> tuple[str, str | None, str]:
    """`(kind, fixture, content)` for one chat request, either wire shape."""
    prompt = "\n".join(str(m.get("content", "")) for m in payload.get("messages") or [] if isinstance(m, dict))
    kind = chat_kind(prompt)
    # The summariser's prompt carries LightRAG text, not the transcript.
    fixture = None if kind in ("context_summary", "speech_summary", "unknown") else select_fixture(prompt)
    replies = {**NEUTRAL_REPLIES, **(FIXTURES[fixture]["replies"] if fixture else {})}
    reply = replies.get(kind, FALLBACK_TEXT)
    if callable(reply):
        match = ANALYSIS_DATE.search(prompt)
        reply = reply(match.group(1) if match else "")
    content = reply if isinstance(reply, str) else json.dumps(reply, ensure_ascii=False)
    return kind, fixture, content


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
            with _lock:
                return self._send(200, list(_log))
        if self.path == "/_fixture/documents" and self.service == "lightrag":
            with _lock:
                return self._send(200, dict(_documents))
        if self.client_address[0] != "127.0.0.1":  # skip the container's own healthcheck
            _record(self.service, "GET", self.path, b"", "probe")
        if self.service == "ollama" and self.path == "/api/tags":
            return self._send(200, {"models": [{"name": "fixture"}]})
        if self.service == "lightrag" and self.path == "/health":
            return self._send(200, {"status": "healthy"})
        self._send(404, {"detail": "not_found"})

    def do_POST(self):  # noqa: N802
        raw = self._body()
        payload = self._json(raw)
        if self.service == "ollama" and self.path in ("/v1/chat/completions", "/api/chat"):
            kind, fixture, content = chat_reply(payload)
            _record(self.service, "POST", self.path, raw, kind, fixture)
            message = {"role": "assistant", "content": content}
            if self.path == "/api/chat":
                return self._send(200, {"message": message, "done": True})
            return self._send(200, {"choices": [{"message": message}]})
        if self.service == "lightrag" and self.path == "/query":
            _record(self.service, "POST", self.path, raw, "lightrag_query")
            return self._send(200, {"response": CONTEXT_SUMMARY})
        if self.service == "lightrag" and self.path == "/documents/text":
            _record(self.service, "POST", self.path, raw, "lightrag_insert")
            text = str(payload.get("text", ""))
            with _lock:  # one id, one document: re-posting replaces, as LightRAG does
                _documents[str(payload.get("id", ""))] = {
                    "file_source": payload.get("file_source", ""),
                    "sha256": hashlib.sha256(text.encode()).hexdigest(),
                    "text": text,
                }
            return self._send(200, {"status": "success", "message": "fixture", "track_id": "fixture"})
        _record(self.service, "POST", self.path, raw, "unknown")
        self._send(404, {"detail": "not_found"})

    def do_DELETE(self):  # noqa: N802
        raw = self._body()
        if self.service == "lightrag" and self.path == "/documents/delete_document":
            _record(self.service, "DELETE", self.path, raw, "lightrag_delete")
            with _lock:
                for doc_id in self._json(raw).get("doc_ids") or []:
                    _documents.pop(str(doc_id), None)
            return self._send(200, {"status": "deletion_started", "message": "fixture"})
        _record(self.service, "DELETE", self.path, raw, "unknown")
        self._send(404, {"detail": "not_found"})


def _serve(service: str, port: int) -> ThreadingHTTPServer:
    handler = type(f"{service.title()}Handler", (_Handler,), {"service": service})
    return ThreadingHTTPServer(("0.0.0.0", port), handler)


if __name__ == "__main__":
    ollama = _serve("ollama", OLLAMA_PORT)
    threading.Thread(target=ollama.serve_forever, daemon=True).start()
    _serve("lightrag", LIGHTRAG_PORT).serve_forever()
