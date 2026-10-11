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
import routers.sessions as sessions_router
from tests.test_sessions import _auth, _client, _manifest, _setup, _stub_pending_session_for_retry

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


def test_process_segment_writes_detected_entities_not_a_reviewed_draft(monkeypatch, tmp_path):
    import correction as correction_module
    import transcript_ingest
    from entity_detector import DetectedEntity
    from models import Manifest

    session_dir = tmp_path / "sess-detected"
    session_dir.mkdir()
    (session_dir / "s01.m4a").write_bytes(b"fake-audio")
    manifest_dict = _manifest("sess-detected")
    manifest_dict["segments"][0]["audio_file"] = "s01.m4a"
    manifest = Manifest.model_validate(manifest_dict)
    segment = manifest.segments[0]

    async def fake_transcribe_and_persist(audio_bytes, *, src_suffix, filename, date, author, language="de"):
        return transcript_ingest.TranscribedSegment(transcript_id=11, raw_text="hallo anna")

    async def fake_correct(raw_text, *, persons, terms, text_corrections=None, dismissals=None, on_step=None):
        entity = DetectedEntity(
            start=6, end=10, original_text="anna", canonical="Anna",
            entity_type="PERSON", match_type="exact", confidence="high",
            status="auto-matched",
        )
        return correction_module.CorrectionResult(corrected_text="hallo Anna", entities=[entity])

    async def empty():
        return []

    saved_drafts: list[tuple] = []
    detected: list[tuple] = []

    async def fake_save_draft(*args, **kwargs):
        saved_drafts.append((args, kwargs))

    async def fake_save_detected_entities(transcript_id, corrected_text, detected_entities_json):
        detected.append((transcript_id, corrected_text, detected_entities_json))

    monkeypatch.setattr(sessions_router.transcript_ingest, "transcribe_and_persist", fake_transcribe_and_persist)
    monkeypatch.setattr(sessions_router.correction, "correct_and_detect_entities", fake_correct)
    monkeypatch.setattr(db, "load_person_dictionary", empty)
    monkeypatch.setattr(db, "load_term_dictionary", empty)
    monkeypatch.setattr(db, "load_text_corrections", empty)
    monkeypatch.setattr(db, "load_entity_dismissals", empty)
    monkeypatch.setattr(db, "save_draft", fake_save_draft)
    monkeypatch.setattr(db, "save_detected_entities", fake_save_detected_entities, raising=False)

    artifact = asyncio.run(
        sessions_router._process_segment(manifest=manifest, segment=segment, session_dir=session_dir)
    )

    assert saved_drafts == []
    assert len(detected) == 1
    transcript_id, corrected_text, payload = detected[0]
    assert (transcript_id, corrected_text) == (11, "hallo Anna")
    assert json.loads(payload) == artifact.entities
    assert artifact.entities[0]["text"] == "Anna"


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
    _setup(monkeypatch)
    _stub_pending_session_for_retry(monkeypatch, tmp_path, session_id)

    async def fake_get_transcript(transcript_id):
        return transcript_row

    async def no_saved_document(transcript_id):
        return None

    seen = {}

    async def fake_run_processor(*, manifest, artifacts, todos_by_segment):
        seen["entities"] = [a.entities for a in artifacts]

    monkeypatch.setattr(db, "get_transcript", fake_get_transcript)
    monkeypatch.setattr(db, "get_latest_processed_document", no_saved_document)
    monkeypatch.setattr(sessions_router, "_run_session_document_processor", fake_run_processor)

    resp = _client().post(f"/api/sessions/{session_id}/retry-analysis", headers=_auth())
    assert resp.status_code == 200
    return seen["entities"]


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
