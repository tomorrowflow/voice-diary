"""ARCH-1: route-level coverage for the legacy review streaming flow.

The two SSE routes live in `routers/review_stream.py`, not `main.py`, while
keeping their paths and bearer gating. The generator-level tests
(`test_process_transcript_stream.py`, `test_process_document_stream.py`,
`test_bug57_lifecycle.py`) cover event order and cancellation; these drive
the same routes over HTTP so the route wiring (lookup, 404, pre-loading,
`EventSourceResponse` framing) is covered too.

`TestClient(main.app)` without a `with` block never runs the lifespan, so no
real Postgres/Qdrant/Ollama is touched.
"""

from __future__ import annotations

import json

import pytest
from fastapi.routing import APIRoute
from fastapi.testclient import TestClient

import correction
import db
import fluency_checker
import main
import narrative
import routers.review_stream as review_stream
import vector_store
from entity_detector import DetectedEntity

BEARER_TOKEN = "test-bearer-token"
AUTH = {"Authorization": f"Bearer {BEARER_TOKEN}"}

client = TestClient(main.app)


@pytest.fixture(autouse=True)
def _bearer_token(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("IOS_BEARER_TOKEN", BEARER_TOKEN)


def _entity(text: str) -> DetectedEntity:
    return DetectedEntity(
        start=0, end=len(text), original_text=text, canonical=text,
        entity_type="PERSON", match_type="exact", confidence="high",
        status="auto-matched",
    )


def _route(path: str) -> APIRoute:
    for route in main.app.routes:
        candidate = getattr(route, "original_router", route)
        for sub in getattr(candidate, "routes", [candidate]):
            if isinstance(sub, APIRoute) and sub.path == path and "GET" in sub.methods:
                return sub
    raise AssertionError(f"no route for GET {path}")


def _parse_sse(body: str) -> list[tuple[str, dict | list]]:
    events = []
    for block in body.replace("\r\n", "\n").strip().split("\n\n"):
        name = None
        data = None
        for line in block.split("\n"):
            if line.startswith("event:"):
                name = line[len("event:"):].strip()
            elif line.startswith("data:"):
                data = json.loads(line[len("data:"):].strip())
        if name is not None:
            events.append((name, data))
    return events


@pytest.mark.parametrize(
    "path",
    [
        "/api/transcripts/{transcript_id}/process",
        "/api/transcripts/{transcript_id}/process-document",
    ],
)
def test_review_stream_routes_live_in_review_stream_module(path: str) -> None:
    assert _route(path).endpoint.__module__ == "routers.review_stream"


@pytest.mark.parametrize(
    "path", ["/api/transcripts/1/process", "/api/transcripts/1/process-document"]
)
def test_unknown_transcript_returns_404(monkeypatch: pytest.MonkeyPatch, path: str) -> None:
    async def fake_get_transcript(transcript_id):
        return None

    monkeypatch.setattr(db, "get_transcript", fake_get_transcript)

    response = client.get(path, headers=AUTH)

    assert response.status_code == 404
    assert response.json() == {"error": "not found"}


def test_process_route_streams_events_in_order(monkeypatch: pytest.MonkeyPatch) -> None:
    async def fake_get_transcript(transcript_id):
        return {"id": transcript_id, "raw_text": "hallo welt"}

    async def fake_list():
        return []

    monkeypatch.setattr(db, "get_transcript", fake_get_transcript)
    monkeypatch.setattr(db, "load_person_dictionary", fake_list)
    monkeypatch.setattr(db, "load_term_dictionary", fake_list)
    monkeypatch.setattr(db, "load_text_corrections", fake_list)
    monkeypatch.setattr(db, "load_entity_dismissals", fake_list)

    async def fake_correct(raw_text, *, persons, terms, text_corrections=None,
                           dismissals=None, on_step=None):
        on_step("log", {"message": "Detecting entities...", "level": "info"})
        return correction.CorrectionResult(
            corrected_text="hallo Welt", entities=[_entity("Welt")]
        )

    async def fake_validate(text, entities, entity_usage_samples=None):
        yield {"event": "result", "data": json.dumps([])}

    monkeypatch.setattr(correction, "correct_and_detect_entities", fake_correct)
    monkeypatch.setattr(fluency_checker, "FLUENCY_CHECK_ENABLED", False)
    monkeypatch.setattr(vector_store, "VECTOR_SEARCH_ENABLED", False)
    monkeypatch.setattr(review_stream, "validate_entities_stream", fake_validate)

    response = client.get("/api/transcripts/5/process", headers=AUTH)

    assert response.status_code == 200
    assert response.headers["content-type"].startswith("text/event-stream")
    events = _parse_sse(response.text)
    assert [name for name, _ in events] == [
        "log", "correction", "log", "fluency", "entities", "log", "result",
    ]
    assert events[1][1]["text"] == "hallo Welt"


def test_process_document_route_streams_and_saves(monkeypatch: pytest.MonkeyPatch) -> None:
    async def fake_get_transcript(transcript_id):
        return {
            "id": transcript_id,
            "date": "2026-05-10",
            "raw_text": "raw",
            "corrected_text": "corrected",
            "entities_json": '[{"canonical": "Welt"}]',
            "author": "Ann",
        }

    seen = {}

    async def fake_build(text, entities, date, *, author=None, ports=None, on_step=None):
        seen.update(text=text, entities=entities, date=date, author=author)
        on_step("step", {"step": "context", "state": "done"})
        return narrative.NarrativeResult(
            context_summary="", enriched_context={}, analysis={}, markdown="# doc", metadata={},
        )

    async def fake_save(**kwargs):
        assert kwargs["transcript_id"] == 5
        return {"id": 42, "version": 1}

    monkeypatch.setattr(db, "get_transcript", fake_get_transcript)
    monkeypatch.setattr(narrative, "build_day_narrative", fake_build)
    monkeypatch.setattr(db, "save_processed_document", fake_save)

    response = client.get("/api/transcripts/5/process-document", headers=AUTH)

    assert response.status_code == 200
    events = _parse_sse(response.text)
    assert [name for name, _ in events] == ["step", "step", "log", "document", "step", "done"]
    assert events[-1][1] == {"doc_id": 42}
    assert seen == {
        "text": "corrected",
        "entities": [{"canonical": "Welt"}],
        "date": "2026-05-10",
        "author": "Ann",
    }
