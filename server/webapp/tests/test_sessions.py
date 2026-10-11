"""Tests for `routers/sessions.py` session-ingest status persistence (SRV-A6).

Run inside the webapp container so deps + env match prod:

    docker compose run --rm webapp pytest webapp/tests/test_sessions.py

No live Postgres is needed: `db` calls are monkeypatched at the module
level, so these exercise the router's caching/fallback logic in isolation.
"""

from __future__ import annotations

import asyncio
import json as jsonlib
import os
import sys
from dataclasses import dataclass

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

import httpx
import pytest
from fastapi import FastAPI
from fastapi.testclient import TestClient

import db
import routers.sessions as sessions_router
from models import SegmentResult, SessionStatus


BEARER = "test-token"


def _client() -> TestClient:
    app = FastAPI()
    app.include_router(sessions_router.router)
    return TestClient(app)


def _auth() -> dict:
    return {"Authorization": f"Bearer {BEARER}"}


def _setup(monkeypatch):
    monkeypatch.setenv("IOS_BEARER_TOKEN", BEARER)
    sessions_router._session_status.clear()
    getattr(sessions_router, "_sessions_in_flight", set()).clear()


def test_status_falls_back_to_persisted_row_when_not_in_memory_cache(monkeypatch):
    """A restart clears the in-memory cache; the status endpoint must still
    return a previously-completed session's status from the db."""
    _setup(monkeypatch)

    async def fake_get_session_status(session_id: str) -> dict | None:
        assert session_id == "sess-1"
        return {
            "session_id": "sess-1",
            "received_at": "2026-07-01T10:00:00Z",
            "state": "done",
            "segments": [
                {
                    "segment_id": "s01",
                    "status": "processed",
                    "transcript_id": 42,
                    "error": None,
                }
            ],
        }

    monkeypatch.setattr(db, "get_session_status", fake_get_session_status)

    resp = _client().get("/api/sessions/sess-1/status", headers=_auth())

    assert resp.status_code == 200
    body = resp.json()
    assert body["state"] == "done"
    assert body["segments"][0]["transcript_id"] == 42


def test_status_still_404s_when_neither_cache_nor_db_has_the_session(monkeypatch):
    _setup(monkeypatch)

    async def fake_get_session_status(session_id: str) -> dict | None:
        return None

    monkeypatch.setattr(db, "get_session_status", fake_get_session_status)

    resp = _client().get("/api/sessions/unknown/status", headers=_auth())

    assert resp.status_code == 404


def test_derive_session_state_all_processed_is_done():
    results = [SegmentResult(segment_id="s01", status="processed", transcript_id=1)]
    assert sessions_router._derive_session_state(results) == "done"


def test_derive_session_state_all_failed_is_failed():
    results = [SegmentResult(segment_id="s01", status="failed", error="boom")]
    assert sessions_router._derive_session_state(results) == "failed"


def test_derive_session_state_mixed_is_partial():
    results = [
        SegmentResult(segment_id="s01", status="processed", transcript_id=1),
        SegmentResult(segment_id="s02", status="failed", error="boom"),
    ]
    assert sessions_router._derive_session_state(results) == "partial"


def test_persist_session_status_updates_cache_and_writes_through_to_db(monkeypatch):
    _setup(monkeypatch)
    sessions_router._session_status["sess-x"] = SessionStatus(
        session_id="sess-x",
        received_at="2026-07-01T10:00:00Z",
        state="processing",
        segments=[SegmentResult(segment_id="s01", status="pending_analysis")],
    )

    updated: list[tuple] = []

    async def fake_update_session_status(session_id, state, segments) -> None:
        updated.append((session_id, state, segments))

    monkeypatch.setattr(db, "update_session_status", fake_update_session_status)

    new_results = [SegmentResult(segment_id="s01", status="processed", transcript_id=7)]
    asyncio.run(
        sessions_router._persist_session_status("sess-x", "done", new_results)
    )

    assert sessions_router._session_status["sess-x"].state == "done"
    assert sessions_router._session_status["sess-x"].segments == new_results
    assert updated == [
        ("sess-x", "done", [{"segment_id": "s01", "status": "processed", "transcript_id": 7, "error": None}])
    ]


def test_process_session_bg_marks_failed_in_db_on_crash(monkeypatch):
    _setup(monkeypatch)
    sessions_router._session_status["sess-crash"] = SessionStatus(
        session_id="sess-crash",
        received_at="2026-07-01T10:00:00Z",
        state="processing",
        segments=[SegmentResult(segment_id="s01", status="pending_analysis")],
    )

    async def fake_process_session(parsed, session_dir):
        raise RuntimeError("boom")

    marked_failed: list[str] = []

    async def fake_mark_session_failed(session_id: str) -> None:
        marked_failed.append(session_id)

    monkeypatch.setattr(sessions_router, "_process_session", fake_process_session)
    monkeypatch.setattr(db, "mark_session_failed", fake_mark_session_failed)

    @dataclass
    class _FakeManifest:
        session_id: str

    asyncio.run(sessions_router._process_session_bg(_FakeManifest("sess-crash"), None))

    assert marked_failed == ["sess-crash"]
    assert sessions_router._session_status["sess-crash"].state == "failed"


def _manifest(session_id: str) -> dict:
    return {
        "session_id": session_id,
        "date": "2026-07-01",
        "device": "iPhone17,2",
        "app_version": "1.0",
        "audio_codec": {
            "codec": "aac-lc",
            "sample_rate": 16000,
            "channels": 1,
            "bitrate": 64000,
        },
        "segments": [
            {
                "segment_id": "s01",
                "segment_type": "drive_by",
                "audio_file": "segments/s01.m4a",
                "captured_at": "2026-07-01T10:00:00Z",
            }
        ],
    }


def _bundle(session_id: str) -> list[tuple]:
    manifest = jsonlib.dumps(_manifest(session_id)).encode()
    return [
        ("manifest", ("manifest.json", manifest, "application/json")),
        ("segments/s01.m4a", ("s01.m4a", b"fake-audio-bytes", "audio/mp4")),
    ]


def test_post_session_persists_status_row_before_returning(monkeypatch, tmp_path):
    """The accepted-response status must already be durable — not just in
    the process-local cache — before the client sees a 200."""
    _setup(monkeypatch)
    monkeypatch.setenv("DATA_DIR", str(tmp_path))

    async def fake_whisper_reachable() -> bool:
        return True

    async def fake_process_session_bg(parsed, session_dir) -> None:
        return None

    created: list[tuple] = []

    async def fake_create_session_status(session_id, received_at, state, segments) -> None:
        created.append((session_id, received_at, state, segments))

    monkeypatch.setattr(sessions_router, "_whisper_reachable", fake_whisper_reachable)
    monkeypatch.setattr(sessions_router, "_process_session_bg", fake_process_session_bg)
    monkeypatch.setattr(db, "create_session_status", fake_create_session_status)

    resp = _client().post("/api/sessions", files=_bundle("sess-post-1"), headers=_auth())

    assert resp.status_code == 200
    assert len(created) == 1
    session_id, received_at, state, segments = created[0]
    assert session_id == "sess-post-1"
    assert state == "processing"
    assert segments == [
        {"segment_id": "s01", "status": "pending_analysis", "transcript_id": None, "error": None}
    ]


def test_post_session_deletes_persisted_row_when_whisper_unreachable(monkeypatch, tmp_path):
    """The row written before the Whisper pre-flight must not linger as a
    permanently 'processing' ghost once the 503 rollback kicks in."""
    _setup(monkeypatch)
    monkeypatch.setenv("DATA_DIR", str(tmp_path))

    async def fake_whisper_unreachable() -> bool:
        return False

    async def fake_create_session_status(session_id, received_at, state, segments) -> None:
        return None

    deleted: list[str] = []

    async def fake_delete_session_status(session_id) -> None:
        deleted.append(session_id)

    monkeypatch.setattr(sessions_router, "_whisper_reachable", fake_whisper_unreachable)
    monkeypatch.setattr(db, "create_session_status", fake_create_session_status)
    monkeypatch.setattr(db, "delete_session_status", fake_delete_session_status)

    resp = _client().post("/api/sessions", files=_bundle("sess-post-2"), headers=_auth())

    assert resp.status_code == 503
    assert deleted == ["sess-post-2"]
    assert "sess-post-2" not in sessions_router._session_status


def test_process_segment_uses_shared_transcribe_and_persist_core(monkeypatch, tmp_path):
    """SRV-A7: `_process_segment`'s ffmpeg/Whisper/persist steps must go
    through `transcript_ingest.transcribe_and_persist` (the same core
    `main.py`'s `/api/ingest/upload` uses) instead of driving `asr_client`
    and `db.create_transcript` inline."""
    from models import Manifest
    import transcript_ingest

    session_dir = tmp_path / "sess-seg"
    session_dir.mkdir()
    (session_dir / "s01.m4a").write_bytes(b"fake-audio")

    manifest_dict = _manifest("sess-seg")
    manifest_dict["date"] = "2026-07-04"
    manifest_dict["segments"][0]["audio_file"] = "s01.m4a"
    manifest = Manifest.model_validate(manifest_dict)
    segment = manifest.segments[0]

    calls = []

    async def fake_transcribe_and_persist(audio_bytes, *, src_suffix, filename, date, author, language="de"):
        calls.append(
            {
                "audio_bytes": audio_bytes,
                "src_suffix": src_suffix,
                "filename": filename,
                "date": date,
                "author": author,
                "language": language,
            }
        )
        return transcript_ingest.TranscribedSegment(transcript_id=7, raw_text="hallo welt")

    async def fake_correct_and_detect_entities(raw_text, *, persons, terms, text_corrections=None, dismissals=None, on_step=None):
        return sessions_router.correction.CorrectionResult(corrected_text=raw_text)

    async def fake_load_person_dictionary():
        return []

    async def fake_load_term_dictionary():
        return []

    async def fake_load_text_corrections():
        return []

    async def fake_load_entity_dismissals():
        return []

    async def fake_save_draft(transcript_id, text, raw_text=None, entities_json=None):
        pass

    monkeypatch.setattr(sessions_router.transcript_ingest, "transcribe_and_persist", fake_transcribe_and_persist)
    monkeypatch.setattr(sessions_router.correction, "correct_and_detect_entities", fake_correct_and_detect_entities)
    monkeypatch.setattr(db, "load_person_dictionary", fake_load_person_dictionary)
    monkeypatch.setattr(db, "load_term_dictionary", fake_load_term_dictionary)
    monkeypatch.setattr(db, "load_text_corrections", fake_load_text_corrections)
    monkeypatch.setattr(db, "load_entity_dismissals", fake_load_entity_dismissals)
    monkeypatch.setattr(db, "save_draft", fake_save_draft)

    artifact = asyncio.run(
        sessions_router._process_segment(
            manifest=manifest, segment=segment, session_dir=session_dir
        )
    )

    assert artifact.transcript_id == 7
    assert artifact.raw_text == "hallo welt"
    assert len(calls) == 1
    assert calls[0]["filename"] == "sess-seg::s01.m4a"
    assert calls[0]["date"] == "2026-07-04"
    assert calls[0]["author"] == "Florian Wolf"
    assert calls[0]["src_suffix"] == ".m4a"
    assert calls[0]["language"] == "de"


def test_process_segment_uses_shared_correction_module(monkeypatch, tmp_path):
    """#51: `_process_segment` must delegate dictionary corrections, LLM
    correction and entity detection/dismissal filtering to
    `correction.correct_and_detect_entities` — the same chain the HTMX
    review flow runs — instead of calling `transcript_corrector` and
    `detect_entities` directly (which skipped dictionary corrections,
    few-shot examples and dismissal filtering for iOS sessions)."""
    from models import Manifest
    import correction as correction_module
    import transcript_ingest
    from entity_detector import DetectedEntity

    session_dir = tmp_path / "sess-corr"
    session_dir.mkdir()
    (session_dir / "s01.m4a").write_bytes(b"fake-audio")

    manifest_dict = _manifest("sess-corr")
    manifest_dict["segments"][0]["audio_file"] = "s01.m4a"
    manifest = Manifest.model_validate(manifest_dict)
    segment = manifest.segments[0]

    async def fake_transcribe_and_persist(audio_bytes, *, src_suffix, filename, date, author, language="de"):
        return transcript_ingest.TranscribedSegment(transcript_id=9, raw_text="hallo welt")

    text_corrections = [{"original_text": "welt", "corrected_text": "Welt"}]
    dismissals = ["Baumarkt"]
    persons = [{"canonical_name": "Anna"}]
    terms = [{"canonical_name": "Sprint"}]

    calls = []

    async def fake_correct_and_detect_entities(
        raw_text, *, persons, terms, text_corrections=None, dismissals=None, on_step=None
    ):
        calls.append(
            {
                "raw_text": raw_text,
                "persons": persons,
                "terms": terms,
                "text_corrections": text_corrections,
                "dismissals": dismissals,
                "on_step": on_step,
            }
        )
        entity = DetectedEntity(
            start=0, end=4, original_text="Anna", canonical="Anna",
            entity_type="PERSON", match_type="exact", confidence="high",
            status="auto-matched",
        )
        return correction_module.CorrectionResult(
            corrected_text="hallo Welt", entities=[entity],
        )

    async def fake_load_person_dictionary():
        return persons

    async def fake_load_term_dictionary():
        return terms

    async def fake_load_text_corrections():
        return text_corrections

    async def fake_load_entity_dismissals():
        return dismissals

    saved_drafts = []

    async def fake_save_draft(transcript_id, text, raw_text=None, entities_json=None):
        saved_drafts.append((transcript_id, text, entities_json))

    monkeypatch.setattr(sessions_router.transcript_ingest, "transcribe_and_persist", fake_transcribe_and_persist)
    monkeypatch.setattr(sessions_router.correction, "correct_and_detect_entities", fake_correct_and_detect_entities)
    monkeypatch.setattr(db, "load_person_dictionary", fake_load_person_dictionary)
    monkeypatch.setattr(db, "load_term_dictionary", fake_load_term_dictionary)
    monkeypatch.setattr(db, "load_text_corrections", fake_load_text_corrections)
    monkeypatch.setattr(db, "load_entity_dismissals", fake_load_entity_dismissals)
    monkeypatch.setattr(db, "save_draft", fake_save_draft)

    artifact = asyncio.run(
        sessions_router._process_segment(
            manifest=manifest, segment=segment, session_dir=session_dir
        )
    )

    assert len(calls) == 1
    assert calls[0]["raw_text"] == "hallo welt"
    assert calls[0]["persons"] == persons
    assert calls[0]["terms"] == terms
    assert calls[0]["text_corrections"] == text_corrections
    assert calls[0]["dismissals"] == dismissals

    assert artifact.corrected_text == "hallo Welt"
    assert len(saved_drafts) == 1
    assert saved_drafts[0][0] == 9
    assert saved_drafts[0][1] == "hallo Welt"
    assert jsonlib.loads(saved_drafts[0][2]) == artifact.entities
    assert artifact.entities == [
        {
            "start": 0, "end": 4, "original_text": "Anna", "canonical": "Anna",
            "entity_type": "PERSON", "match_type": "exact", "confidence": "high",
            "status": "auto-matched", "dictionary_id": None, "source": "term",
            "role": "", "candidates": [], "llm_validated": False, "llm_reason": "",
            "llm_suggested": False, "text": "Anna", "type": "PERSON",
        }
    ]


def test_process_segment_persists_entities_even_when_correction_leaves_text_unchanged(
    monkeypatch, tmp_path
):
    """#52: `_process_segment` only called `db.save_draft` when correction
    changed the text, so detected entities were never persisted for the iOS
    session path — a retry rebuilding the session narrative from Postgres
    would always see an empty entity list. `save_draft` must always run
    with `entities_json` so a later retry can reload what was detected."""
    from models import Manifest
    import correction as correction_module
    import transcript_ingest
    from entity_detector import DetectedEntity

    session_dir = tmp_path / "sess-entities"
    session_dir.mkdir()
    (session_dir / "s01.m4a").write_bytes(b"fake-audio")

    manifest_dict = _manifest("sess-entities")
    manifest_dict["segments"][0]["audio_file"] = "s01.m4a"
    manifest = Manifest.model_validate(manifest_dict)
    segment = manifest.segments[0]

    async def fake_transcribe_and_persist(audio_bytes, *, src_suffix, filename, date, author, language="de"):
        return transcript_ingest.TranscribedSegment(transcript_id=11, raw_text="hallo Anna")

    async def fake_correct_and_detect_entities(
        raw_text, *, persons, terms, text_corrections=None, dismissals=None, on_step=None
    ):
        entity = DetectedEntity(
            start=6, end=10, original_text="Anna", canonical="Anna",
            entity_type="PERSON", match_type="exact", confidence="high",
            status="auto-matched",
        )
        # Correction leaves the text unchanged — only entity detection ran.
        return correction_module.CorrectionResult(corrected_text=raw_text, entities=[entity])

    async def fake_load_dict():
        return []

    async def fake_load_corrections():
        return []

    monkeypatch.setattr(sessions_router.transcript_ingest, "transcribe_and_persist", fake_transcribe_and_persist)
    monkeypatch.setattr(sessions_router.correction, "correct_and_detect_entities", fake_correct_and_detect_entities)
    monkeypatch.setattr(db, "load_person_dictionary", fake_load_dict)
    monkeypatch.setattr(db, "load_term_dictionary", fake_load_dict)
    monkeypatch.setattr(db, "load_text_corrections", fake_load_corrections)
    monkeypatch.setattr(db, "load_entity_dismissals", fake_load_corrections)

    saved_drafts = []

    async def fake_save_draft(transcript_id, text, raw_text=None, entities_json=None):
        saved_drafts.append((transcript_id, text, entities_json))

    monkeypatch.setattr(db, "save_draft", fake_save_draft)

    artifact = asyncio.run(
        sessions_router._process_segment(
            manifest=manifest, segment=segment, session_dir=session_dir
        )
    )

    assert artifact.corrected_text == "hallo Anna"
    assert len(saved_drafts) == 1
    saved_transcript_id, saved_text, saved_entities_json = saved_drafts[0]
    assert saved_transcript_id == 11
    assert saved_text == "hallo Anna"
    assert jsonlib.loads(saved_entities_json) == artifact.entities
    assert artifact.entities[0]["text"] == "Anna"


def _fake_document_processor_pipeline(monkeypatch, *, ingest=None):
    """Stub every `document_processor` step `narrative.build_day_narrative`
    calls before/around `ingest_to_lightrag` (via `narrative.sync_and_ingest`),
    so tests can focus on the save/mark bookkeeping around it. Also stubs
    `skeleton_sync.sync_incremental` — `sync_and_ingest` calls it for real
    now that it's an explicit step (SRV-A1/#50, T3), and there's no DB here."""
    import document_processor
    import skeleton_sync

    async def fake_query_lightrag_context(date_str, *, client=None):
        return ""

    async def fake_query_lightrag_entity_history(names, date_str, *, client=None):
        return ""

    async def fake_summarize_context(recent_ctx, entity_hist, date_str, *, transport=None):
        return ""

    def fake_build_enriched_context(transcript_record, entities, context_summary):
        return {}

    async def fake_analyze_transcript(enriched, *, transport=None):
        return {}

    def fake_generate_narrative_document(enriched, analysis):
        return "# narrative"

    def fake_build_document_metadata(enriched):
        return {}

    async def fake_sync_incremental(triggered_by: str):
        return skeleton_sync.SyncStats()

    monkeypatch.setattr(document_processor, "query_lightrag_context", fake_query_lightrag_context)
    monkeypatch.setattr(document_processor, "query_lightrag_entity_history", fake_query_lightrag_entity_history)
    monkeypatch.setattr(document_processor, "summarize_context", fake_summarize_context)
    monkeypatch.setattr(document_processor, "build_enriched_context", fake_build_enriched_context)
    monkeypatch.setattr(document_processor, "analyze_transcript", fake_analyze_transcript)
    monkeypatch.setattr(document_processor, "generate_narrative_document", fake_generate_narrative_document)
    monkeypatch.setattr(document_processor, "build_document_metadata", fake_build_document_metadata)
    monkeypatch.setattr(skeleton_sync, "sync_incremental", fake_sync_incremental)

    if ingest is not None:
        monkeypatch.setattr(document_processor, "ingest_to_lightrag", ingest)


def test_run_session_document_processor_marks_each_saved_document_ingested_on_success(monkeypatch):
    """T1/#49: after a successful LightRAG ingest, every `processed_documents`
    row saved for the session must be marked ingested — otherwise the day
    shows as "not ingested" on `/process/{id}` forever."""
    from models import Manifest

    async def fake_ingest(markdown, metadata, *, client=None):
        return None

    _fake_document_processor_pipeline(monkeypatch, ingest=fake_ingest)

    saved_docs = []

    async def fake_save_processed_document(*, transcript_id, document_markdown, analysis_json, context_summary, metadata):
        doc_id = 100 + transcript_id
        saved_docs.append(doc_id)
        return {"id": doc_id, "version": 1, "created_at": None}

    marked_ids = []

    async def fake_mark_document_ingested(doc_id):
        marked_ids.append(doc_id)
        return {"id": doc_id, "lightrag_ingested_at": None}

    monkeypatch.setattr(db, "save_processed_document", fake_save_processed_document)
    monkeypatch.setattr(db, "mark_document_ingested", fake_mark_document_ingested)

    manifest = Manifest.model_validate(_manifest("sess-mark"))
    segment = manifest.segments[0]
    artifacts = [
        sessions_router._SegmentArtifact(
            segment=segment, transcript_id=1, raw_text="hallo", corrected_text="hallo",
        ),
        sessions_router._SegmentArtifact(
            segment=segment, transcript_id=2, raw_text="welt", corrected_text="welt",
        ),
    ]

    asyncio.run(
        sessions_router._run_session_document_processor(
            manifest=manifest, artifacts=artifacts, todos_by_segment={},
        )
    )

    assert marked_ids == saved_docs == [101, 102]


def test_retry_analysis_404s_for_unknown_session(monkeypatch):
    """#52: retrying a session the server has never heard of (neither cache
    nor persisted row) must 404, matching the status endpoint's behaviour."""
    _setup(monkeypatch)

    async def fake_get_session_status(session_id: str) -> dict | None:
        return None

    monkeypatch.setattr(db, "get_session_status", fake_get_session_status)

    resp = _client().post("/api/sessions/unknown/retry-analysis", headers=_auth())

    assert resp.status_code == 404


def test_retry_analysis_409s_when_no_segment_is_pending_analysis(monkeypatch):
    """#52: a session with no `pending_analysis` segment (e.g. fully `done`,
    or still `processing`) is not in a retryable state."""
    _setup(monkeypatch)

    async def fake_get_session_status(session_id: str) -> dict | None:
        return {
            "session_id": "sess-done",
            "received_at": "2026-07-01T10:00:00Z",
            "state": "done",
            "segments": [
                {"segment_id": "s01", "status": "processed", "transcript_id": 1, "error": None},
            ],
        }

    monkeypatch.setattr(db, "get_session_status", fake_get_session_status)

    resp = _client().post("/api/sessions/sess-done/retry-analysis", headers=_auth())

    assert resp.status_code == 409


def test_retry_analysis_ingest_only_failure_reingests_without_rerunning_analysis(
    monkeypatch, tmp_path
):
    """#52 acceptance: when analysis already succeeded and saved a document
    (only the LightRAG ingest failed), retry must re-ingest that saved
    narrative and mark it ingested — not re-run the LLM analysis."""
    _setup(monkeypatch)
    monkeypatch.setenv("DATA_DIR", str(tmp_path))

    session_id = "sess-retry-ingest-only"
    session_dir = sessions_router._sessions_data_dir() / sessions_router._slug_session_id(session_id)
    session_dir.mkdir(parents=True)
    (session_dir / "manifest.json").write_text(jsonlib.dumps(_manifest(session_id)))

    async def fake_get_session_status(sid: str) -> dict | None:
        return {
            "session_id": session_id,
            "received_at": "2026-07-01T10:00:00Z",
            "state": "partial",
            "segments": [
                {
                    "segment_id": "s01",
                    "status": "pending_analysis",
                    "transcript_id": 5,
                    "error": "analysis_pending: lightrag unreachable",
                },
            ],
        }

    monkeypatch.setattr(db, "get_session_status", fake_get_session_status)

    async def fake_get_transcript(transcript_id: int) -> dict | None:
        return {"id": 5, "raw_text": "hallo welt", "corrected_text": "Hallo Welt", "entities_json": None}

    monkeypatch.setattr(db, "get_transcript", fake_get_transcript)

    saved_document = {
        "id": 42,
        "document_markdown": "# already analyzed narrative",
        "metadata": {"date": "2026-07-01", "author": "Florian Wolf"},
        "lightrag_ingested": False,
    }

    async def fake_get_latest_processed_document(transcript_id: int) -> dict | None:
        assert transcript_id == 5
        return saved_document

    monkeypatch.setattr(db, "get_latest_processed_document", fake_get_latest_processed_document)

    import document_processor

    async def fail_if_called(*args, **kwargs):
        raise AssertionError("analysis must not re-run on an ingest-only retry")

    monkeypatch.setattr(document_processor, "analyze_transcript", fail_if_called)

    sync_calls = []

    async def fake_sync_and_ingest(markdown, metadata, *, lightrag_client=None):
        sync_calls.append((markdown, metadata))
        return {}

    monkeypatch.setattr(sessions_router.narrative, "sync_and_ingest", fake_sync_and_ingest)

    marked_ids: list[int] = []

    async def fake_mark_document_ingested(doc_id: int):
        marked_ids.append(doc_id)
        return {"id": doc_id, "lightrag_ingested_at": None}

    monkeypatch.setattr(db, "mark_document_ingested", fake_mark_document_ingested)

    async def fake_update_session_status(session_id: str, state: str, segments: list[dict]):
        return None

    monkeypatch.setattr(db, "update_session_status", fake_update_session_status)

    resp = _client().post(f"/api/sessions/{session_id}/retry-analysis", headers=_auth())

    assert resp.status_code == 200
    body = resp.json()
    assert body["state"] == "done"
    assert body["segments"][0]["status"] == "processed"
    assert sync_calls == [("# already analyzed narrative", {"date": "2026-07-01", "author": "Florian Wolf"})]
    assert marked_ids == [42]


def test_retry_analysis_rebuilds_narrative_from_persisted_transcripts_and_marks_done(
    monkeypatch, tmp_path
):
    """#52: the happy path — analysis never completed (no saved document
    yet), so retry must reload the manifest from disk, reload each pending
    segment's transcript + entities from Postgres, re-run the full narrative
    stage, and flip the segment (and session) to done."""
    _setup(monkeypatch)
    monkeypatch.setenv("DATA_DIR", str(tmp_path))

    session_id = "sess-retry-full"
    session_dir = sessions_router._sessions_data_dir() / sessions_router._slug_session_id(session_id)
    session_dir.mkdir(parents=True)
    (session_dir / "manifest.json").write_text(jsonlib.dumps(_manifest(session_id)))

    async def fake_get_session_status(sid: str) -> dict | None:
        return {
            "session_id": session_id,
            "received_at": "2026-07-01T10:00:00Z",
            "state": "partial",
            "segments": [
                {
                    "segment_id": "s01",
                    "status": "pending_analysis",
                    "transcript_id": 5,
                    "error": "analysis_pending: lightrag unreachable",
                },
            ],
        }

    monkeypatch.setattr(db, "get_session_status", fake_get_session_status)

    async def fake_get_transcript(transcript_id: int) -> dict | None:
        assert transcript_id == 5
        return {
            "id": 5,
            "raw_text": "hallo welt",
            "corrected_text": "Hallo Welt",
            "entities_json": jsonlib.dumps([{"type": "PERSON", "text": "Anna"}]),
        }

    monkeypatch.setattr(db, "get_transcript", fake_get_transcript)

    async def fake_get_latest_processed_document(transcript_id: int) -> dict | None:
        return None

    monkeypatch.setattr(db, "get_latest_processed_document", fake_get_latest_processed_document)

    async def fake_ingest(markdown, metadata, *, client=None):
        return None

    _fake_document_processor_pipeline(monkeypatch, ingest=fake_ingest)

    saved_docs: list[int] = []

    async def fake_save_processed_document(
        *, transcript_id, document_markdown, analysis_json, context_summary, metadata
    ):
        saved_docs.append(transcript_id)
        return {"id": 900 + transcript_id, "version": 1, "created_at": None}

    monkeypatch.setattr(db, "save_processed_document", fake_save_processed_document)

    marked_ids: list[int] = []

    async def fake_mark_document_ingested(doc_id: int):
        marked_ids.append(doc_id)
        return {"id": doc_id, "lightrag_ingested_at": None}

    monkeypatch.setattr(db, "mark_document_ingested", fake_mark_document_ingested)

    persisted_updates: list[tuple] = []

    async def fake_update_session_status(session_id: str, state: str, segments: list[dict]):
        persisted_updates.append((session_id, state, segments))

    monkeypatch.setattr(db, "update_session_status", fake_update_session_status)

    resp = _client().post(f"/api/sessions/{session_id}/retry-analysis", headers=_auth())

    assert resp.status_code == 200
    body = resp.json()
    assert body["state"] == "done"
    assert body["segments"] == [
        {"segment_id": "s01", "status": "processed", "transcript_id": 5, "error": None}
    ]
    assert saved_docs == [5]
    assert marked_ids == [905]
    assert persisted_updates == [(session_id, "done", body["segments"])]


def _stub_pending_session_for_retry(monkeypatch, tmp_path, session_id: str) -> list[tuple]:
    """Persisted single-segment `pending_analysis` session with its manifest
    on disk and transcript row; returns the list `update_session_status`
    calls are recorded into."""
    monkeypatch.setenv("DATA_DIR", str(tmp_path))
    session_dir = sessions_router._sessions_data_dir() / sessions_router._slug_session_id(session_id)
    session_dir.mkdir(parents=True)
    (session_dir / "manifest.json").write_text(jsonlib.dumps(_manifest(session_id)))

    async def fake_get_session_status(sid: str) -> dict | None:
        return {
            "session_id": session_id,
            "received_at": "2026-07-01T10:00:00Z",
            "state": "done",
            "segments": [
                {
                    "segment_id": "s01",
                    "status": "pending_analysis",
                    "transcript_id": 5,
                    "error": "analysis_pending: first failure",
                },
            ],
        }

    async def fake_get_transcript(transcript_id: int) -> dict | None:
        return {"id": 5, "raw_text": "hallo welt", "corrected_text": "Hallo Welt", "entities_json": None}

    persisted_updates: list[tuple] = []

    async def fake_update_session_status(session_id: str, state: str, segments: list[dict]):
        persisted_updates.append((session_id, state, segments))

    monkeypatch.setattr(db, "get_session_status", fake_get_session_status)
    monkeypatch.setattr(db, "get_transcript", fake_get_transcript)
    monkeypatch.setattr(db, "update_session_status", fake_update_session_status)
    return persisted_updates


def test_retry_analysis_returns_pending_status_when_analysis_fails_again(monkeypatch, tmp_path):
    """BUG-56/#56: the narrative stage failing again on retry must not 500 —
    the segments stay `pending_analysis` with an `analysis_pending: …` error
    (same shape as `_process_session`), the status is persisted, and the
    route returns it with 200."""
    _setup(monkeypatch)
    session_id = "sess-retry-analysis-fails"
    persisted_updates = _stub_pending_session_for_retry(monkeypatch, tmp_path, session_id)

    async def fake_get_latest_processed_document(transcript_id: int) -> dict | None:
        return None

    monkeypatch.setattr(db, "get_latest_processed_document", fake_get_latest_processed_document)

    async def failing_run_processor(**kwargs):
        raise RuntimeError("ollama unreachable")

    monkeypatch.setattr(sessions_router, "_run_session_document_processor", failing_run_processor)

    resp = _client().post(f"/api/sessions/{session_id}/retry-analysis", headers=_auth())

    assert resp.status_code == 200
    body = resp.json()
    expected_segments = [
        {
            "segment_id": "s01",
            "status": "pending_analysis",
            "transcript_id": 5,
            "error": "analysis_pending: ollama unreachable",
        }
    ]
    assert body["segments"] == expected_segments
    assert persisted_updates == [(session_id, body["state"], expected_segments)]
    # Still retryable afterwards: the cached status is the updated one.
    status_resp = _client().get(f"/api/sessions/{session_id}/status", headers=_auth())
    assert status_resp.json()["segments"] == expected_segments


def test_retry_analysis_returns_pending_status_when_ingest_fails_again(monkeypatch, tmp_path):
    """BUG-56/#56: same as above for the ingest-only shortcut — a saved
    document whose LightRAG re-ingest fails again stays unmarked, the segment
    stays `pending_analysis` with the new error, and the route returns 200."""
    _setup(monkeypatch)
    session_id = "sess-retry-ingest-fails"
    persisted_updates = _stub_pending_session_for_retry(monkeypatch, tmp_path, session_id)

    async def fake_get_latest_processed_document(transcript_id: int) -> dict | None:
        return {
            "id": 42,
            "document_markdown": "# already analyzed narrative",
            "metadata": {"date": "2026-07-01"},
            "lightrag_ingested": False,
        }

    monkeypatch.setattr(db, "get_latest_processed_document", fake_get_latest_processed_document)

    async def failing_sync_and_ingest(markdown, metadata, *, lightrag_client=None):
        raise RuntimeError("lightrag unreachable")

    monkeypatch.setattr(sessions_router.narrative, "sync_and_ingest", failing_sync_and_ingest)

    marked_ids: list[int] = []

    async def fake_mark_document_ingested(doc_id: int):
        marked_ids.append(doc_id)

    monkeypatch.setattr(db, "mark_document_ingested", fake_mark_document_ingested)

    resp = _client().post(f"/api/sessions/{session_id}/retry-analysis", headers=_auth())

    assert resp.status_code == 200
    body = resp.json()
    expected_segments = [
        {
            "segment_id": "s01",
            "status": "pending_analysis",
            "transcript_id": 5,
            "error": "analysis_pending: lightrag unreachable",
        }
    ]
    assert body["segments"] == expected_segments
    assert marked_ids == []
    assert persisted_updates == [(session_id, body["state"], expected_segments)]


def test_retry_stuck_sessions_on_startup_logs_one_line_per_session_whose_retry_fails_again(
    monkeypatch, caplog
):
    """BUG-56/#56: a narrative failure no longer raises out of the retry, so
    the sweep must notice the still-pending segments itself and log exactly
    one line per such session (and none for sessions that recovered)."""
    import logging

    _setup(monkeypatch)

    async def fake_list_pending_analysis_session_ids():
        return ["sess-recovers", "sess-fails"]

    monkeypatch.setattr(db, "list_pending_analysis_session_ids", fake_list_pending_analysis_session_ids)

    async def fake_lookup(session_id):
        return SessionStatus(
            session_id=session_id, received_at="2026-07-01T10:00:00Z",
            state="done", segments=[],
        )

    monkeypatch.setattr(sessions_router, "_lookup_session_status", fake_lookup)

    async def fake_retry_session_analysis(session_id, status_obj):
        if session_id == "sess-fails":
            segment = SegmentResult(
                segment_id="s01", status="pending_analysis", transcript_id=5,
                error="analysis_pending: ollama unreachable",
            )
        else:
            segment = SegmentResult(segment_id="s01", status="processed", transcript_id=5)
        return SessionStatus(
            session_id=session_id, received_at="2026-07-01T10:00:00Z",
            state="done", segments=[segment],
        )

    monkeypatch.setattr(sessions_router, "_retry_session_analysis", fake_retry_session_analysis)

    with caplog.at_level(logging.INFO, logger=sessions_router.logger.name):
        asyncio.run(sessions_router.retry_stuck_sessions_on_startup())

    sweep_lines = [r for r in caplog.records if "startup retry sweep" in r.getMessage()]
    assert len(sweep_lines) == 1
    assert "sess-fails" in sweep_lines[0].getMessage()
    assert "ollama unreachable" in sweep_lines[0].getMessage()
    assert sweep_lines[0].exc_info is None


def test_retry_stuck_sessions_on_startup_retries_each_pending_session_and_keeps_going_on_failure(
    monkeypatch,
):
    """#52: the startup sweep must be bounded/sequential/best-effort — one
    session's retry blowing up must not stop the rest from being tried, and
    a failure is logged and left `pending_analysis`, not re-raised."""
    _setup(monkeypatch)

    async def fake_list_pending_analysis_session_ids():
        return ["sess-a", "sess-b", "sess-c"]

    monkeypatch.setattr(db, "list_pending_analysis_session_ids", fake_list_pending_analysis_session_ids)

    attempted: list[str] = []

    async def fake_retry_session_analysis(session_id, status_obj):
        attempted.append(session_id)
        if session_id == "sess-b":
            raise RuntimeError("lightrag unreachable")
        return status_obj

    monkeypatch.setattr(sessions_router, "_retry_session_analysis", fake_retry_session_analysis)

    async def fake_lookup(session_id):
        return SessionStatus(
            session_id=session_id, received_at="2026-07-01T10:00:00Z",
            state="partial", segments=[],
        )

    monkeypatch.setattr(sessions_router, "_lookup_session_status", fake_lookup)

    asyncio.run(sessions_router.retry_stuck_sessions_on_startup())

    assert attempted == ["sess-a", "sess-b", "sess-c"]


# --- BUG-54/#54: per-session in-flight guard ------------------------------


def _async_client() -> httpx.AsyncClient:
    """In-loop client, so several requests can be in flight at once (the
    sync `TestClient` serialises them)."""
    app = FastAPI()
    app.include_router(sessions_router.router)
    return httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url="http://test")


def _latched_processor(monkeypatch):
    """Replace the narrative stage with a fake that records each run and
    blocks until `release` is set. Returns `(calls, started, release)`."""
    calls: list[dict] = []
    started = asyncio.Event()
    release = asyncio.Event()

    async def latched_run_processor(**kwargs):
        calls.append(kwargs)
        started.set()
        await release.wait()

    monkeypatch.setattr(sessions_router, "_run_session_document_processor", latched_run_processor)
    return calls, started, release


def _no_saved_document(monkeypatch):
    async def fake_get_latest_processed_document(transcript_id: int) -> dict | None:
        return None

    monkeypatch.setattr(db, "get_latest_processed_document", fake_get_latest_processed_document)


def test_concurrent_retry_analysis_runs_narrative_once_and_409s_the_other(monkeypatch, tmp_path):
    """A double tap: while the first retry is in flight, the second gets
    409 `session_busy`, and the narrative stage ran exactly once."""
    _setup(monkeypatch)
    session_id = "sess-retry-double-tap"
    _stub_pending_session_for_retry(monkeypatch, tmp_path, session_id)
    _no_saved_document(monkeypatch)

    async def scenario():
        calls, started, release = _latched_processor(monkeypatch)
        url = f"/api/sessions/{session_id}/retry-analysis"
        async with _async_client() as client:
            first = asyncio.create_task(client.post(url, headers=_auth()))
            try:
                await asyncio.wait_for(started.wait(), 5)
                second = await asyncio.wait_for(client.post(url, headers=_auth()), 2)
            finally:
                release.set()
            first_resp = await first
        return calls, first_resp, second

    calls, first_resp, second = asyncio.run(scenario())

    assert second.status_code == 409
    assert second.json()["detail"] == "session_busy"
    assert first_resp.status_code == 200
    assert len(calls) == 1


def test_retry_analysis_409s_session_busy_during_original_ingest(monkeypatch, tmp_path):
    """A manual retry that overlaps the original background ingest gets the
    same 409 `session_busy`; the guard is released once the ingest ends."""
    _setup(monkeypatch)
    monkeypatch.setenv("DATA_DIR", str(tmp_path))
    session_id = "sess-retry-vs-ingest"

    async def fake_whisper_reachable() -> bool:
        return True

    async def fake_create_session_status(session_id, received_at, state, segments) -> None:
        return None

    started = asyncio.Event()
    release = asyncio.Event()

    async def latched_process_session(parsed, session_dir):
        started.set()
        await release.wait()
        return []

    monkeypatch.setattr(sessions_router, "_whisper_reachable", fake_whisper_reachable)
    monkeypatch.setattr(db, "create_session_status", fake_create_session_status)
    monkeypatch.setattr(sessions_router, "_process_session", latched_process_session)

    async def scenario():
        url = f"/api/sessions/{session_id}/retry-analysis"
        async with _async_client() as client:
            post = asyncio.create_task(
                client.post("/api/sessions", files=_bundle(session_id), headers=_auth())
            )
            try:
                await asyncio.wait_for(started.wait(), 5)
                during = await client.post(url, headers=_auth())
            finally:
                release.set()
            post_resp = await post
            after = await client.post(url, headers=_auth())
        return during, post_resp, after

    during, post_resp, after = asyncio.run(scenario())

    assert post_resp.status_code == 200
    assert during.status_code == 409
    assert during.json()["detail"] == "session_busy"
    # Released: the session is just not retryable (nothing pending with a
    # transcript), no longer busy.
    assert after.status_code == 409
    assert after.json()["detail"] == "session_not_retryable"


@pytest.mark.parametrize("bg_crashes", [False, True])
def test_original_ingest_releases_guard_on_success_and_failure(monkeypatch, tmp_path, bg_crashes):
    _setup(monkeypatch)
    monkeypatch.setenv("DATA_DIR", str(tmp_path))
    session_id = f"sess-bg-release-{bg_crashes}"

    async def fake_whisper_reachable() -> bool:
        return True

    async def fake_create_session_status(session_id, received_at, state, segments) -> None:
        return None

    async def fake_mark_session_failed(session_id) -> None:
        return None

    async def fake_process_session(parsed, session_dir):
        if bg_crashes:
            raise RuntimeError("boom")
        return []

    monkeypatch.setattr(sessions_router, "_whisper_reachable", fake_whisper_reachable)
    monkeypatch.setattr(db, "create_session_status", fake_create_session_status)
    monkeypatch.setattr(db, "mark_session_failed", fake_mark_session_failed)
    monkeypatch.setattr(sessions_router, "_process_session", fake_process_session)

    async def scenario():
        async with _async_client() as client:
            await client.post("/api/sessions", files=_bundle(session_id), headers=_auth())
            return await client.post(
                f"/api/sessions/{session_id}/retry-analysis", headers=_auth()
            )

    resp = asyncio.run(scenario())

    assert resp.status_code == 409
    assert resp.json()["detail"] == "session_not_retryable"


def test_retry_analysis_releases_guard_after_success(monkeypatch, tmp_path):
    _setup(monkeypatch)
    session_id = "sess-retry-release-ok"
    _stub_pending_session_for_retry(monkeypatch, tmp_path, session_id)
    _no_saved_document(monkeypatch)

    async def ok_run_processor(**kwargs):
        return None

    monkeypatch.setattr(sessions_router, "_run_session_document_processor", ok_run_processor)

    async def scenario():
        url = f"/api/sessions/{session_id}/retry-analysis"
        async with _async_client() as client:
            first = await client.post(url, headers=_auth())
            second = await client.post(url, headers=_auth())
        return first, second

    first, second = asyncio.run(scenario())

    assert first.status_code == 200
    # Processed now: not retryable, but crucially not "busy".
    assert second.status_code == 409
    assert second.json()["detail"] == "session_not_retryable"


def test_retry_analysis_releases_guard_after_failure(monkeypatch, tmp_path):
    """Both a narrative failure (200 with pending segments) and an exception
    escaping the retry (missing manifest -> 404) must release the guard."""
    _setup(monkeypatch)
    session_id = "sess-retry-release-fail"
    _stub_pending_session_for_retry(monkeypatch, tmp_path, session_id)
    _no_saved_document(monkeypatch)

    async def failing_run_processor(**kwargs):
        raise RuntimeError("ollama unreachable")

    monkeypatch.setattr(sessions_router, "_run_session_document_processor", failing_run_processor)

    manifest_path = (
        sessions_router._sessions_data_dir()
        / sessions_router._slug_session_id(session_id)
        / "manifest.json"
    )

    async def scenario():
        url = f"/api/sessions/{session_id}/retry-analysis"
        async with _async_client() as client:
            first = await client.post(url, headers=_auth())
            second = await client.post(url, headers=_auth())
            manifest_text = manifest_path.read_text()
            manifest_path.unlink()
            missing = await client.post(url, headers=_auth())
            manifest_path.write_text(manifest_text)
            third = await client.post(url, headers=_auth())
        return first, second, missing, third

    first, second, missing, third = asyncio.run(scenario())

    assert first.status_code == 200
    assert second.status_code == 200
    assert missing.status_code == 404
    assert missing.json()["detail"] == "session_manifest_missing"
    assert third.status_code == 200


def test_startup_sweep_skips_session_with_retry_in_flight(monkeypatch, tmp_path, caplog):
    """The sweep must not start a second narrative run for a session that is
    already busy (here: a manual retry holding the latch)."""
    import logging

    _setup(monkeypatch)
    session_id = "sess-sweep-busy"
    _stub_pending_session_for_retry(monkeypatch, tmp_path, session_id)
    _no_saved_document(monkeypatch)

    async def fake_list_pending_analysis_session_ids():
        return [session_id]

    monkeypatch.setattr(db, "list_pending_analysis_session_ids", fake_list_pending_analysis_session_ids)

    async def scenario():
        calls, started, release = _latched_processor(monkeypatch)
        async with _async_client() as client:
            retry = asyncio.create_task(
                client.post(f"/api/sessions/{session_id}/retry-analysis", headers=_auth())
            )
            try:
                await asyncio.wait_for(started.wait(), 5)
                await asyncio.wait_for(sessions_router.retry_stuck_sessions_on_startup(), 2)
            finally:
                release.set()
            retry_resp = await retry
        return calls, retry_resp

    with caplog.at_level(logging.INFO, logger=sessions_router.logger.name):
        calls, retry_resp = asyncio.run(scenario())

    assert retry_resp.status_code == 200
    assert len(calls) == 1
    assert any(
        "busy" in r.getMessage() and session_id in r.getMessage() for r in caplog.records
    )


def test_startup_sweep_releases_guard_after_success_and_failure(monkeypatch):
    _setup(monkeypatch)

    async def fake_list_pending_analysis_session_ids():
        return ["sess-ok", "sess-boom"]

    monkeypatch.setattr(db, "list_pending_analysis_session_ids", fake_list_pending_analysis_session_ids)

    async def fake_lookup(session_id):
        return SessionStatus(
            session_id=session_id, received_at="2026-07-01T10:00:00Z",
            state="partial", segments=[],
        )

    async def fake_retry_session_analysis(session_id, status_obj):
        if session_id == "sess-boom":
            raise RuntimeError("lightrag unreachable")
        return status_obj

    monkeypatch.setattr(sessions_router, "_lookup_session_status", fake_lookup)
    monkeypatch.setattr(sessions_router, "_retry_session_analysis", fake_retry_session_analysis)

    async def scenario():
        await sessions_router.retry_stuck_sessions_on_startup()
        # A second sweep reaches both sessions again only if neither stayed claimed.
        attempted: list[str] = []

        async def recording_retry(session_id, status_obj):
            attempted.append(session_id)
            return status_obj

        monkeypatch.setattr(sessions_router, "_retry_session_analysis", recording_retry)
        await sessions_router.retry_stuck_sessions_on_startup()
        return attempted

    assert asyncio.run(scenario()) == ["sess-ok", "sess-boom"]


# --- BUG-53/#53: persist segment transcript IDs as phase 1 finishes -------


def _two_segment_manifest(session_id: str) -> dict:
    manifest = _manifest(session_id)
    manifest["segments"].append(
        {
            "segment_id": "s02",
            "segment_type": "drive_by",
            "audio_file": "segments/s02.m4a",
            "captured_at": "2026-07-01T11:00:00Z",
        }
    )
    return manifest


class _FakeSessionIngests:
    """In-memory stand-in for the `session_ingests` row of one session."""

    def __init__(self, session_id: str, state: str, segments: list[dict]):
        self.session_id = session_id
        self.row = {
            "session_id": session_id,
            "received_at": "2026-07-01T10:00:00Z",
            "state": state,
            "segments": segments,
        }
        self.updates: list[tuple[str, list[dict]]] = []

    def install(self, monkeypatch) -> None:
        async def get_session_status(sid: str) -> dict | None:
            return self.row if sid == self.session_id else None

        async def update_session_status(session_id: str, state: str, segments: list[dict]) -> None:
            self.row = {**self.row, "state": state, "segments": segments}
            self.updates.append((state, segments))

        monkeypatch.setattr(db, "get_session_status", get_session_status)
        monkeypatch.setattr(db, "update_session_status", update_session_status)


def _write_manifest(monkeypatch, tmp_path, session_id: str, manifest: dict):
    monkeypatch.setenv("DATA_DIR", str(tmp_path))
    session_dir = sessions_router._sessions_data_dir() / sessions_router._slug_session_id(session_id)
    session_dir.mkdir(parents=True)
    (session_dir / "manifest.json").write_text(jsonlib.dumps(manifest))
    return session_dir


def _stub_sweep_dependencies(monkeypatch, *, transcript_ids: set[int], sweep_ids: list[str]):
    """Persisted transcript rows for `transcript_ids`, no saved documents, a
    sweep that lists `sweep_ids`, and a recording narrative stage; returns
    the list it records each run's transcript IDs into."""

    async def fake_get_transcript(transcript_id: int) -> dict | None:
        if transcript_id not in transcript_ids:
            return None
        return {"id": transcript_id, "raw_text": "hallo", "corrected_text": "Hallo", "entities_json": None}

    async def fake_get_latest_processed_document(transcript_id: int) -> dict | None:
        return None

    async def fake_list_pending_analysis_session_ids() -> list[str]:
        return list(sweep_ids)

    processed: list[list[int]] = []

    async def fake_run_processor(*, manifest, artifacts, todos_by_segment):
        processed.append([a.transcript_id for a in artifacts])

    monkeypatch.setattr(db, "get_transcript", fake_get_transcript)
    monkeypatch.setattr(db, "get_latest_processed_document", fake_get_latest_processed_document)
    monkeypatch.setattr(db, "list_pending_analysis_session_ids", fake_list_pending_analysis_session_ids)
    monkeypatch.setattr(sessions_router, "_run_session_document_processor", fake_run_processor)
    return processed


def _segment_row(segment_id: str, status: str, transcript_id: int | None = None, error: str | None = None):
    return {"segment_id": segment_id, "status": status, "transcript_id": transcript_id, "error": error}


def test_process_session_persists_each_segment_as_phase_1_finishes(monkeypatch, tmp_path):
    """BUG-53/#53: a transcribed segment's `pending_analysis` + transcript_id
    (or a failed segment's `failed` + error) must hit `session_ingests` as
    soon as phase 1 is done with it — not only at the end of the session."""
    from models import Manifest

    _setup(monkeypatch)
    session_id = "sess-phase1-persist"
    parsed = Manifest.model_validate(_two_segment_manifest(session_id))
    ingests = _FakeSessionIngests(
        session_id, "processing", [_segment_row("s01", "pending_analysis"), _segment_row("s02", "pending_analysis")]
    )
    ingests.install(monkeypatch)

    async def fake_process_segment(*, manifest, segment, session_dir):
        if segment.segment_id == "s02":
            raise RuntimeError("whisper exploded")
        return sessions_router._SegmentArtifact(
            segment=segment, transcript_id=11, raw_text="hallo", corrected_text="hallo",
        )

    seen_at_phase_2: list[list[tuple]] = []

    async def fake_run_processor(*, manifest, artifacts, todos_by_segment):
        seen_at_phase_2.append(list(ingests.updates))

    monkeypatch.setattr(sessions_router, "_process_segment", fake_process_segment)
    monkeypatch.setattr(sessions_router, "_run_session_document_processor", fake_run_processor)

    asyncio.run(sessions_router._process_session(parsed, tmp_path))

    after_s01 = (
        "processing",
        [_segment_row("s01", "pending_analysis", 11), _segment_row("s02", "pending_analysis")],
    )
    after_s02 = (
        "processing",
        [_segment_row("s01", "pending_analysis", 11), _segment_row("s02", "failed", error="whisper exploded")],
    )
    # Both segment writes had already happened when phase 2 started.
    assert seen_at_phase_2 == [[after_s01, after_s02]]
    # …and the final write still lands, with the usual derived state.
    assert ingests.updates[-1] == (
        "partial",
        [_segment_row("s01", "processed", 11), _segment_row("s02", "failed", error="whisper exploded")],
    )


def test_process_session_updates_status_cache_per_segment(monkeypatch, tmp_path):
    from models import Manifest

    _setup(monkeypatch)
    session_id = "sess-phase1-cache"
    parsed = Manifest.model_validate(_two_segment_manifest(session_id))
    sessions_router._session_status[session_id] = SessionStatus(
        session_id=session_id, received_at="2026-07-01T10:00:00Z", state="processing",
        segments=[SegmentResult(segment_id=s.segment_id, status="pending_analysis") for s in parsed.segments],
    )
    _FakeSessionIngests(session_id, "processing", []).install(monkeypatch)

    async def fake_process_segment(*, manifest, segment, session_dir):
        return sessions_router._SegmentArtifact(
            segment=segment, transcript_id=21, raw_text="hallo", corrected_text="hallo",
        )

    cache_at_phase_2: list[list[SegmentResult]] = []

    async def fake_run_processor(*, manifest, artifacts, todos_by_segment):
        cache_at_phase_2.append(list(sessions_router._session_status[session_id].segments))

    monkeypatch.setattr(sessions_router, "_process_segment", fake_process_segment)
    monkeypatch.setattr(sessions_router, "_run_session_document_processor", fake_run_processor)

    asyncio.run(sessions_router._process_session(parsed, tmp_path))

    assert cache_at_phase_2 == [
        [
            SegmentResult(segment_id="s01", status="pending_analysis", transcript_id=21),
            SegmentResult(segment_id="s02", status="pending_analysis", transcript_id=21),
        ]
    ]


def test_sweep_recovers_session_after_crash_between_phase_1_and_phase_2(monkeypatch, tmp_path):
    """BUG-53/#53: the process dying during phase 2 used to strand the row as
    `processing` with null transcript IDs. With the IDs persisted per segment,
    the next startup's sweep finds the session and finishes the narrative."""
    from models import Manifest

    _setup(monkeypatch)
    session_id = "sess-crash-phase-2"
    manifest = _two_segment_manifest(session_id)
    parsed = Manifest.model_validate(manifest)
    session_dir = _write_manifest(monkeypatch, tmp_path, session_id, manifest)
    ingests = _FakeSessionIngests(
        session_id, "processing", [_segment_row("s01", "pending_analysis"), _segment_row("s02", "pending_analysis")]
    )
    ingests.install(monkeypatch)

    class _ProcessDied(BaseException):
        """Escapes `except Exception`, like the process being killed."""

    transcript_ids = {"s01": 31, "s02": 32}

    async def fake_process_segment(*, manifest, segment, session_dir):
        return sessions_router._SegmentArtifact(
            segment=segment, transcript_id=transcript_ids[segment.segment_id],
            raw_text="hallo", corrected_text="hallo",
        )

    async def dying_run_processor(*, manifest, artifacts, todos_by_segment):
        raise _ProcessDied()

    monkeypatch.setattr(sessions_router, "_process_segment", fake_process_segment)
    monkeypatch.setattr(sessions_router, "_run_session_document_processor", dying_run_processor)
    with pytest.raises(_ProcessDied):
        asyncio.run(sessions_router._process_session(parsed, session_dir))
    assert ingests.row["state"] == "processing"

    # "Restart": empty cache and in-flight set, a healthy narrative stage.
    _setup(monkeypatch)
    processed = _stub_sweep_dependencies(monkeypatch, transcript_ids={31, 32}, sweep_ids=[session_id])

    asyncio.run(sessions_router.retry_stuck_sessions_on_startup())

    assert processed == [[31, 32]]
    assert ingests.row["state"] == "done"
    assert ingests.row["segments"] == [_segment_row("s01", "processed", 31), _segment_row("s02", "processed", 32)]


def test_sweep_fails_untranscribed_segments_of_interrupted_session_and_retries_the_rest(
    monkeypatch, tmp_path
):
    """BUG-53/#53: crash mid phase 1 — s01 was transcribed (id persisted), s02
    never got one. s02 becomes `failed` with a clear error; s01 is retried."""
    _setup(monkeypatch)
    session_id = "sess-crash-phase-1"
    _write_manifest(monkeypatch, tmp_path, session_id, _two_segment_manifest(session_id))
    ingests = _FakeSessionIngests(
        session_id, "processing", [_segment_row("s01", "pending_analysis", 41), _segment_row("s02", "pending_analysis")]
    )
    ingests.install(monkeypatch)
    processed = _stub_sweep_dependencies(monkeypatch, transcript_ids={41}, sweep_ids=[session_id])

    asyncio.run(sessions_router.retry_stuck_sessions_on_startup())

    assert processed == [[41]]
    final_state, final_segments = ingests.updates[-1]
    assert final_state == "partial"
    assert final_segments[0] == _segment_row("s01", "processed", 41)
    assert final_segments[1]["segment_id"] == "s02"
    assert final_segments[1]["status"] == "failed"
    assert final_segments[1]["transcript_id"] is None
    assert "interrupted" in final_segments[1]["error"]
    assert "no transcript" in final_segments[1]["error"]


def test_sweep_skips_processing_session_active_in_this_process(monkeypatch, tmp_path):
    """BUG-53/#53: a `processing` row with null transcript IDs is normal while
    this process is still working on it — the sweep must neither fail its
    segments nor start a second run."""
    _setup(monkeypatch)
    session_id = "sess-active-here"
    _write_manifest(monkeypatch, tmp_path, session_id, _two_segment_manifest(session_id))
    ingests = _FakeSessionIngests(
        session_id, "processing", [_segment_row("s01", "pending_analysis"), _segment_row("s02", "pending_analysis")]
    )
    ingests.install(monkeypatch)
    processed = _stub_sweep_dependencies(monkeypatch, transcript_ids=set(), sweep_ids=[session_id])

    async def scenario():
        assert await sessions_router._try_begin_session_run(session_id)
        await sessions_router.retry_stuck_sessions_on_startup()
        # The sweep must not have released a claim it never took.
        assert session_id in sessions_router._sessions_in_flight

    asyncio.run(scenario())

    assert ingests.updates == []
    assert ingests.row["state"] == "processing"
    assert processed == []


def test_post_session_claims_the_session_before_its_processing_row_exists(monkeypatch, tmp_path):
    """BUG-53/#53: the sweep treats an unclaimed `processing` row as an orphan,
    so a fresh upload must hold its in-flight claim from the moment the row is
    created — otherwise the sweep could fail the segments of a live session."""
    _setup(monkeypatch)
    monkeypatch.setenv("DATA_DIR", str(tmp_path))
    claimed_when_row_created: list[bool] = []

    async def fake_create_session_status(session_id, received_at, state, segments) -> None:
        claimed_when_row_created.append(session_id in sessions_router._sessions_in_flight)

    async def fake_whisper_reachable() -> bool:
        return True

    async def fake_process_session_bg(parsed, session_dir) -> None:
        await sessions_router._end_session_run(parsed.session_id)

    monkeypatch.setattr(db, "create_session_status", fake_create_session_status)
    monkeypatch.setattr(sessions_router, "_whisper_reachable", fake_whisper_reachable)
    monkeypatch.setattr(sessions_router, "_process_session_bg", fake_process_session_bg)

    resp = _client().post("/api/sessions", headers=_auth(), files=_bundle("sess-claim-first"))

    assert resp.status_code == 200
    assert claimed_when_row_created == [True]


def test_post_session_releases_claim_when_whisper_is_unreachable(monkeypatch, tmp_path):
    _setup(monkeypatch)
    monkeypatch.setenv("DATA_DIR", str(tmp_path))

    async def fake_create_session_status(session_id, received_at, state, segments) -> None:
        return None

    async def fake_delete_session_status(session_id) -> None:
        return None

    async def fake_whisper_reachable() -> bool:
        return False

    monkeypatch.setattr(db, "create_session_status", fake_create_session_status)
    monkeypatch.setattr(db, "delete_session_status", fake_delete_session_status)
    monkeypatch.setattr(sessions_router, "_whisper_reachable", fake_whisper_reachable)

    resp = _client().post("/api/sessions", headers=_auth(), files=_bundle("sess-claim-release"))

    assert resp.status_code == 503
    assert sessions_router._sessions_in_flight == set()


def test_sweep_logs_one_line_without_traceback_for_non_retryable_session(
    monkeypatch, tmp_path, caplog
):
    """BUG-53/#53: an interrupted session where no segment ever got a
    transcript can't be retried. The sweep marks it failed and says so in one
    warning line — no traceback."""
    import logging

    _setup(monkeypatch)
    session_id = "sess-nothing-transcribed"
    _write_manifest(monkeypatch, tmp_path, session_id, _two_segment_manifest(session_id))
    ingests = _FakeSessionIngests(
        session_id, "processing", [_segment_row("s01", "pending_analysis"), _segment_row("s02", "pending_analysis")]
    )
    ingests.install(monkeypatch)
    processed = _stub_sweep_dependencies(monkeypatch, transcript_ids=set(), sweep_ids=[session_id])

    with caplog.at_level(logging.INFO, logger=sessions_router.logger.name):
        asyncio.run(sessions_router.retry_stuck_sessions_on_startup())

    assert processed == []
    assert ingests.row["state"] == "failed"
    assert [s["status"] for s in ingests.row["segments"]] == ["failed", "failed"]
    sweep_lines = [r for r in caplog.records if "startup retry sweep" in r.getMessage()]
    assert len(sweep_lines) == 1
    assert session_id in sweep_lines[0].getMessage()
    assert "not retryable" in sweep_lines[0].getMessage()
    assert sweep_lines[0].exc_info is None


def test_sweep_logs_one_line_without_traceback_when_manifest_is_missing(monkeypatch, tmp_path, caplog):
    import logging

    _setup(monkeypatch)
    monkeypatch.setenv("DATA_DIR", str(tmp_path))
    session_id = "sess-no-manifest"
    ingests = _FakeSessionIngests(
        session_id, "done", [_segment_row("s01", "pending_analysis", 51, "analysis_pending: boom")]
    )
    ingests.install(monkeypatch)
    _stub_sweep_dependencies(monkeypatch, transcript_ids={51}, sweep_ids=[session_id])

    with caplog.at_level(logging.INFO, logger=sessions_router.logger.name):
        asyncio.run(sessions_router.retry_stuck_sessions_on_startup())

    sweep_lines = [r for r in caplog.records if "startup retry sweep" in r.getMessage()]
    assert len(sweep_lines) == 1
    assert session_id in sweep_lines[0].getMessage()
    assert "not retryable" in sweep_lines[0].getMessage()
    assert sweep_lines[0].exc_info is None


def test_run_session_document_processor_leaves_documents_unmarked_on_ingest_failure(monkeypatch):
    """T1/#49: a failed LightRAG ingest must not mark the already-saved rows
    ingested — they stay retryable (existing `pending_analysis` behaviour in
    the caller)."""
    from models import Manifest

    async def fake_ingest_that_fails(markdown, metadata, *, client=None):
        raise RuntimeError("lightrag unreachable")

    _fake_document_processor_pipeline(monkeypatch, ingest=fake_ingest_that_fails)

    async def fake_save_processed_document(*, transcript_id, document_markdown, analysis_json, context_summary, metadata):
        return {"id": 100 + transcript_id, "version": 1, "created_at": None}

    marked_ids = []

    async def fake_mark_document_ingested(doc_id):
        marked_ids.append(doc_id)
        return {"id": doc_id, "lightrag_ingested_at": None}

    monkeypatch.setattr(db, "save_processed_document", fake_save_processed_document)
    monkeypatch.setattr(db, "mark_document_ingested", fake_mark_document_ingested)

    manifest = Manifest.model_validate(_manifest("sess-mark-fail"))
    segment = manifest.segments[0]
    artifacts = [
        sessions_router._SegmentArtifact(
            segment=segment, transcript_id=1, raw_text="hallo", corrected_text="hallo",
        ),
    ]

    with pytest.raises(RuntimeError, match="lightrag unreachable"):
        asyncio.run(
            sessions_router._run_session_document_processor(
                manifest=manifest, artifacts=artifacts, todos_by_segment={},
            )
        )

    assert marked_ids == []
