"""Tests for `main.py`'s SSE endpoint (`process_document_stream` /
`_process_document_events`) after it was rewired to delegate to
`narrative.build_day_narrative` (SRV-A1/#50).

These focus on the SSE-bridging logic in main.py itself — turning
`narrative`'s callback-shaped `on_step` progress into the async-generator
events the endpoint yields, and the save step that follows — not on
`narrative.build_day_narrative`'s own internals (covered by
`test_narrative.py`). `narrative.build_day_narrative` is monkeypatched with
a fake that drives `on_step` directly, mirroring the existing
`_fake_document_processor_pipeline` pattern in `test_sessions.py`.

Run inside the webapp container so deps + env match prod:

    docker compose run --rm webapp pytest webapp/tests/test_process_document_stream.py
"""

from __future__ import annotations

import asyncio
import json

import db
import main
import narrative


def _collect(agen):
    async def run():
        return [item async for item in agen]

    return asyncio.run(run())


def test_happy_path_relays_narrative_steps_then_saves_and_emits_document(monkeypatch):
    async def fake_build_day_narrative(text, entities, date, *, author=None, ports=None, on_step=None):
        on_step("step", {"step": "context", "state": "active"})
        on_step("step", {"step": "context", "state": "done"})
        return narrative.NarrativeResult(
            context_summary="Keine historischen Daten verfügbar.",
            enriched_context={},
            analysis={"todos": []},
            markdown="# Tagebuch",
            metadata={"date": date},
        )

    monkeypatch.setattr(narrative, "build_day_narrative", fake_build_day_narrative)

    async def fake_save_processed_document(**kwargs):
        assert kwargs["document_markdown"] == "# Tagebuch"
        assert kwargs["analysis_json"] == {"todos": []}
        return {"id": 42, "version": 1}

    monkeypatch.setattr(db, "save_processed_document", fake_save_processed_document)

    events = _collect(main._process_document_events(7, "raw text", [], "2026-05-10"))
    names = [e["event"] for e in events]

    assert names == ["step", "step", "step", "log", "document", "step", "done"]
    assert names[2:4] == ["step", "log"]  # document step: active + log, before save
    document_payload = json.loads(events[-3]["data"])
    assert document_payload["doc_id"] == 42
    assert document_payload["markdown"] == "# Tagebuch"
    done_payload = json.loads(events[-1]["data"])
    assert done_payload == {"doc_id": 42}


def test_analysis_failure_stops_before_any_save(monkeypatch):
    async def fake_build_day_narrative(text, entities, date, *, author=None, ports=None, on_step=None):
        on_step("step", {"step": "analysis", "state": "error"})
        on_step("log", {"message": "Analysis failed: boom", "level": "error"})
        on_step("error", {"message": "Analysis failed: boom"})
        raise RuntimeError("boom")

    monkeypatch.setattr(narrative, "build_day_narrative", fake_build_day_narrative)

    def fail_if_called(**kwargs):
        raise AssertionError("must not save a document when analysis failed")

    monkeypatch.setattr(db, "save_processed_document", fail_if_called)

    events = _collect(main._process_document_events(7, "raw text", [], "2026-05-10"))

    assert [e["event"] for e in events] == ["step", "log", "error"]
    assert json.loads(events[-1]["data"]) == {"message": "Analysis failed: boom"}


def test_save_failure_emits_document_error_event(monkeypatch):
    async def fake_build_day_narrative(text, entities, date, *, author=None, ports=None, on_step=None):
        return narrative.NarrativeResult(
            context_summary="", enriched_context={}, analysis={}, markdown="# doc", metadata={},
        )

    monkeypatch.setattr(narrative, "build_day_narrative", fake_build_day_narrative)

    async def failing_save(**kwargs):
        raise RuntimeError("db unreachable")

    monkeypatch.setattr(db, "save_processed_document", failing_save)

    events = _collect(main._process_document_events(7, "raw text", [], "2026-05-10"))

    assert [e["event"] for e in events] == ["step", "log", "step", "error"]
    assert json.loads(events[-2]["data"]) == {"step": "document", "state": "error"}
    assert "db unreachable" in json.loads(events[-1]["data"])["message"]
