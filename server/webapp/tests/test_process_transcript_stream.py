"""Tests for `main.py`'s `/api/transcripts/{id}/process` SSE endpoint
(`process_transcript_stream` / `_process_transcript_events`) after it was
rewired to delegate to `correction.correct_and_detect_entities` (#51).

These focus on the SSE-bridging logic in main.py itself — turning
`correction`'s callback-shaped `on_step` progress into the async-generator
events the endpoint yields, and the fluency/entities/validation phases that
follow, which stay HTMX-only (decision D2) — not on
`correction.correct_and_detect_entities`'s own internals (covered by
`test_correction.py`). `correction.correct_and_detect_entities` is
monkeypatched with a fake that drives `on_step` directly, mirroring the
existing `test_process_document_stream.py` pattern for `narrative`.

Run inside the webapp container so deps + env match prod:

    docker compose run --rm webapp pytest webapp/tests/test_process_transcript_stream.py
"""

from __future__ import annotations

import asyncio
import json

import correction
import fluency_checker
import llm_validator
import main
import vector_store
from entity_detector import DetectedEntity


def _collect(agen):
    async def run():
        return [item async for item in agen]

    return asyncio.run(run())


def _entity(text: str) -> DetectedEntity:
    return DetectedEntity(
        start=0, end=len(text), original_text=text, canonical=text,
        entity_type="PERSON", match_type="exact", confidence="high",
        status="auto-matched",
    )


def test_happy_path_relays_correction_steps_then_fluency_and_entities(monkeypatch):
    async def fake_correct_and_detect_entities(
        raw_text, *, persons, terms, text_corrections=None, dismissals=None, on_step=None
    ):
        on_step("log", {"message": "Applying dictionary corrections...", "level": "info"})
        on_step("log", {"message": "Detecting entities...", "level": "info"})
        return correction.CorrectionResult(
            corrected_text="hallo Welt",
            llm_corrections=[{"original": "welt", "corrected": "Welt", "reason": "casing", "start": 6, "end": 10}],
            applied_corrections=[{"original": "hallo", "corrected": "hallo", "count": 1}],
            entities=[_entity("Welt")],
        )

    monkeypatch.setattr(correction, "correct_and_detect_entities", fake_correct_and_detect_entities)
    monkeypatch.setattr(fluency_checker, "FLUENCY_CHECK_ENABLED", False)
    monkeypatch.setattr(vector_store, "VECTOR_SEARCH_ENABLED", False)

    async def fake_validate_entities_stream(text, entities, entity_usage_samples=None):
        yield {"event": "result", "data": json.dumps([e.to_dict() for e in entities])}

    monkeypatch.setattr(main, "validate_entities_stream", fake_validate_entities_stream)

    events = _collect(
        main._process_transcript_events(
            "hallo welt", persons=[], terms=[], text_corrections=[], dismissals=[]
        )
    )
    names = [e["event"] for e in events]

    assert names == ["log", "log", "correction", "log", "fluency", "entities", "log", "result"]

    correction_payload = json.loads(events[2]["data"])
    assert correction_payload == {
        "text": "hallo Welt",
        "corrections": [{"original": "welt", "corrected": "Welt", "reason": "casing", "start": 6, "end": 10}],
        "applied_corrections": [{"original": "hallo", "corrected": "hallo", "count": 1}],
    }

    fluency_payload = json.loads(events[4]["data"])
    assert fluency_payload == {"issues": []}

    entities_payload = json.loads(events[5]["data"])
    assert len(entities_payload) == 1
    assert entities_payload[0]["canonical"] == "Welt"


def test_dismissed_entities_never_reach_llm_validation(monkeypatch):
    """The dismissal filtering now happens inside
    `correction.correct_and_detect_entities`; this endpoint must forward
    whatever entity list it returns, unfiltered further."""
    async def fake_correct_and_detect_entities(
        raw_text, *, persons, terms, text_corrections=None, dismissals=None, on_step=None
    ):
        assert dismissals == ["Baumarkt"]
        return correction.CorrectionResult(corrected_text=raw_text, entities=[_entity("Thomas")])

    monkeypatch.setattr(correction, "correct_and_detect_entities", fake_correct_and_detect_entities)
    monkeypatch.setattr(fluency_checker, "FLUENCY_CHECK_ENABLED", False)
    monkeypatch.setattr(vector_store, "VECTOR_SEARCH_ENABLED", False)

    seen_entities = []

    async def fake_validate_entities_stream(text, entities, entity_usage_samples=None):
        seen_entities.extend(entities)
        yield {"event": "result", "data": json.dumps([])}

    monkeypatch.setattr(main, "validate_entities_stream", fake_validate_entities_stream)

    _collect(
        main._process_transcript_events(
            "Thomas war im Baumarkt.", persons=[], terms=[], text_corrections=[],
            dismissals=["Baumarkt"],
        )
    )

    assert [e.canonical for e in seen_entities] == ["Thomas"]
