"""BUG-55 (#55): pipeline-detected entities vs human-reviewed entities.

`transcripts.status = 'saved'` and `transcripts.entities_json` mean "a human
reviewed this" — `main.review_page` uses them to skip SSE fluency/validator
processing. The iOS session path must therefore persist its corrected text
and detected entities into `detected_entities_json` without touching either.
"""

from __future__ import annotations

import asyncio
import json
import os
import re
import sys
from pathlib import Path

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

import db
import main
from tests.session_helpers import (
    FakeSessionIngests,
    NarrativeStage,
    SegmentPipeline,
    fresh_processor,
    manifest_dict,
    segment_row,
    stage_bundle,
    stage_pending_session,
)

WEBAPP_DIR = Path(__file__).resolve().parent.parent


class _RecordingPool:
    def __init__(self):
        self.executed: list[tuple[str, tuple]] = []

    async def execute(self, query, *args):
        self.executed.append((query, args))


def _use_pool(monkeypatch) -> _RecordingPool:
    pool = _RecordingPool()

    async def fake_get_pool():
        return pool

    monkeypatch.setattr(db, "get_pool", fake_get_pool)
    return pool


# --- db layer ---------------------------------------------------------


def test_save_detected_entities_leaves_status_and_reviewed_entities_untouched(monkeypatch):
    pool = _use_pool(monkeypatch)

    asyncio.run(db.save_detected_entities(7, "hallo Anna", '[{"text": "Anna"}]'))

    assert len(pool.executed) == 1
    query, args = pool.executed[0]
    assert args == (7, "hallo Anna", '[{"text": "Anna"}]')
    assigned = query.split("SET", 1)[1].split("WHERE", 1)[0]
    assert "corrected_text" in assigned
    assert "detected_entities_json" in assigned
    # `entities_json` must not be assigned (detected_entities_json contains it
    # as a substring, so only match it as a whole word).
    assert not re.search(r"(?<![\w])entities_json", assigned)
    assert "status" not in assigned


def test_save_draft_still_marks_saved_and_writes_reviewed_entities(monkeypatch):
    pool = _use_pool(monkeypatch)

    asyncio.run(db.save_draft(7, "text", entities_json="[]"))

    query, _ = pool.executed[0]
    assert "status = 'saved'" in query
    assert "entities_json = COALESCE" in query


# --- iOS ingestion path -----------------------------------------------


def test_session_ingest_writes_detected_entities_not_a_reviewed_draft(monkeypatch, tmp_path):
    import correction as correction_module
    from entity_detector import DetectedEntity

    processor = fresh_processor(monkeypatch)
    manifest = manifest_dict("sess-detected")
    manifest["segments"][0]["audio_file"] = "s01.m4a"
    parsed, session_dir = stage_bundle(monkeypatch, tmp_path, "sess-detected", manifest)
    FakeSessionIngests(
        "sess-detected", "processing", [segment_row("s01", "pending_analysis")]
    ).install()

    async def fake_correct(raw_text):
        entity = DetectedEntity(
            start=6, end=10, original_text="anna", canonical="Anna",
            entity_type="PERSON", match_type="exact", confidence="high",
            status="auto-matched",
        )
        return correction_module.CorrectionResult(corrected_text="hallo Anna", entities=[entity])

    pipeline = SegmentPipeline(monkeypatch, transcript_ids={"s01": 11}, correct=fake_correct)
    stage = NarrativeStage(monkeypatch)
    saved_drafts: list[tuple] = []

    async def fake_save_draft(*args, **kwargs):
        saved_drafts.append((args, kwargs))

    monkeypatch.setattr(db, "save_draft", fake_save_draft)

    asyncio.run(processor.run_accepted(parsed, session_dir))

    assert saved_drafts == []
    assert len(pipeline.saved_entities) == 1
    transcript_id, corrected_text, payload = pipeline.saved_entities[0]
    assert (transcript_id, corrected_text) == (11, "hallo Anna")
    assert json.loads(payload) == stage.runs[0]["entities"]
    assert stage.runs[0]["entities"][0]["text"] == "Anna"


# --- review UI --------------------------------------------------------


def test_review_page_runs_full_processing_for_ios_ingested_transcript(monkeypatch):
    """An iOS-ingested transcript carries corrected text + detected entities
    but is not human-reviewed (status pending, entities_json NULL): the
    review page must hand it to the SSE pipeline, not render it as saved."""

    async def fake_get_transcript(transcript_id):
        return {
            "id": transcript_id,
            "filename": "sess::s01.m4a",
            "date": "2026-07-01",
            "author": "Florian Wolf",
            "status": "pending",
            "raw_text": "hallo anna",
            "corrected_text": "hallo Anna",
            "entities_json": None,
            "detected_entities_json": json.dumps([{"text": "Anna", "type": "PERSON"}]),
        }

    async def empty():
        return []

    captured = {}

    class _Templates:
        def TemplateResponse(self, request, name, ctx):
            captured.update(ctx)
            return ctx

    monkeypatch.setattr(db, "get_transcript", fake_get_transcript)
    monkeypatch.setattr(db, "load_person_dictionary", empty)
    monkeypatch.setattr(db, "load_term_dictionary", empty)
    monkeypatch.setattr(db, "load_text_corrections", empty)
    monkeypatch.setattr(main, "templates", _Templates())

    asyncio.run(main.review_page(request=object(), transcript_id=3))

    assert captured["needs_processing"] is True
    assert captured["entities_json"] == "[]"
    assert captured["raw_text"] == "hallo anna"


# --- retry-analysis ---------------------------------------------------


def _retry_with_transcript(monkeypatch, tmp_path, session_id, transcript_row):
    """Entities handed to the narrative stage when a retry reloads
    `transcript_row` from Postgres."""
    processor = fresh_processor(monkeypatch)
    stage_pending_session(monkeypatch, tmp_path, session_id)
    stage = NarrativeStage(monkeypatch)

    async def fake_get_transcript(transcript_id):
        return transcript_row

    monkeypatch.setattr(db, "get_transcript", fake_get_transcript)

    asyncio.run(processor.retry_analysis(session_id))
    return [run["entities"] for run in stage.runs]


def test_retry_analysis_reads_detected_entities_json(monkeypatch, tmp_path):
    detected = [{"type": "PERSON", "text": "Anna"}]
    entities = _retry_with_transcript(
        monkeypatch,
        tmp_path,
        "sess-retry-detected",
        {
            "id": 5,
            "raw_text": "hallo anna",
            "corrected_text": "hallo Anna",
            "entities_json": None,
            "detected_entities_json": json.dumps(detected),
        },
    )

    assert entities == [detected]


def test_retry_analysis_prefers_detected_over_reviewed_entities(monkeypatch, tmp_path):
    detected = [{"type": "PERSON", "text": "Anna"}]
    entities = _retry_with_transcript(
        monkeypatch,
        tmp_path,
        "sess-retry-prefers",
        {
            "id": 5,
            "raw_text": "hallo anna",
            "corrected_text": "hallo Anna",
            "entities_json": json.dumps([{"type": "PERSON", "text": "Reviewed"}]),
            "detected_entities_json": json.dumps(detected),
        },
    )

    assert entities == [detected]


def test_retry_analysis_falls_back_to_entities_json_for_pre_migration_rows(monkeypatch, tmp_path):
    """Rows ingested before BUG-55 only have `entities_json` (iOS wrote there)."""
    legacy = [{"type": "PERSON", "text": "Anna"}]
    entities = _retry_with_transcript(
        monkeypatch,
        tmp_path,
        "sess-retry-legacy",
        {
            "id": 5,
            "raw_text": "hallo anna",
            "corrected_text": "hallo Anna",
            "entities_json": json.dumps(legacy),
            "detected_entities_json": None,
        },
    )

    assert entities == [legacy]


# --- schema -----------------------------------------------------------


def test_schema_adds_detected_entities_json_idempotently():
    schema = (WEBAPP_DIR / "schema.sql").read_text()
    assert (
        "ALTER TABLE transcripts ADD COLUMN IF NOT EXISTS detected_entities_json JSONB;"
        in schema
    )
