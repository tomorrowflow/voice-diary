"""Tests for `session_processing` (ARCH-2): the session processing lifecycle
behind the HTTP routes, driven through `SessionProcessor`'s public interface —
`accept` / `run_accepted` (original ingest), `retry_analysis` (manual retry),
`retry_stuck_sessions_on_startup` (startup sweep), `get_status`.

Run inside the webapp container so deps + env match prod:

    docker compose run --rm webapp pytest webapp/tests/test_session_processing.py

No live Postgres, Whisper, Ollama or LightRAG: `session_helpers` stubs `db`,
`transcript_ingest`, `correction` and `narrative`. The routes' side of the same
paths is covered in `test_sessions.py`.
"""

from __future__ import annotations

import asyncio
import json
import logging
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

import pytest

import correction
import db
import session_processing
import upstream_failure
from entity_detector import DetectedEntity
from models import SegmentResult
from session_processing import (
    SessionBusy,
    SessionManifestMissing,
    SessionNotFound,
    SessionNotRetryable,
)
from tests.session_helpers import (
    FakeSessionIngests,
    NarrativeStage,
    SegmentPipeline,
    fake_document_processor_pipeline,
    fresh_processor,
    manifest_dict,
    segment_row,
    stage_bundle,
    stage_pending_session,
    stub_transcripts,
    two_segment_manifest,
)


def _sweep_lines(caplog) -> list[logging.LogRecord]:
    return [r for r in caplog.records if "startup retry sweep" in r.getMessage()]


# --- status ---------------------------------------------------------------


def test_status_falls_back_to_persisted_row_and_caches_it(monkeypatch):
    """A restart clears the in-memory cache; a previously-completed session's
    status must still come back from the db (SRV-A6)."""
    processor = fresh_processor(monkeypatch)
    lookups: list[str] = []

    async def fake_get_session_status(session_id: str) -> dict | None:
        lookups.append(session_id)
        return {
            "session_id": "sess-1",
            "received_at": "2026-07-01T10:00:00Z",
            "state": "done",
            "segments": [segment_row("s01", "processed", 42)],
        }

    monkeypatch.setattr(db, "get_session_status", fake_get_session_status)

    async def scenario():
        return await processor.get_status("sess-1"), await processor.get_status("sess-1")

    first, second = asyncio.run(scenario())

    assert first.state == "done"
    assert first.segments[0].transcript_id == 42
    assert second is first
    assert lookups == ["sess-1"]


def test_status_is_none_when_neither_cache_nor_db_has_the_session(monkeypatch):
    processor = fresh_processor(monkeypatch)

    async def fake_get_session_status(session_id: str) -> dict | None:
        return None

    monkeypatch.setattr(db, "get_session_status", fake_get_session_status)

    assert asyncio.run(processor.get_status("unknown")) is None


# --- original ingest: accept ----------------------------------------------


def test_accept_persists_the_processing_row_before_returning(monkeypatch, tmp_path):
    """The accepted status must already be durable — not just in the
    process-local cache — before the caller answers 200."""
    processor = fresh_processor(monkeypatch)
    parsed, session_dir = stage_bundle(monkeypatch, tmp_path, "sess-accept")
    ingests = FakeSessionIngests.empty("sess-accept").install(monkeypatch)

    accepted = asyncio.run(processor.accept(parsed, session_dir))

    assert accepted.state == "processing"
    assert len(ingests.created) == 1
    session_id, received_at, state, segments = ingests.created[0]
    assert (session_id, received_at, state) == ("sess-accept", accepted.received_at, "processing")
    assert segments == [segment_row("s01", "pending_analysis")]
    assert accepted.segments == [SegmentResult(segment_id="s01", status="pending_analysis")]


def test_accept_rolls_everything_back_when_whisper_is_unreachable(monkeypatch, tmp_path):
    """The row written before the Whisper pre-flight must not linger as a
    permanently 'processing' ghost, the bundle must be removed, and the claim
    released so the upload can be retried."""
    whisper_up = [False]
    processor = fresh_processor(monkeypatch, whisper_up=lambda: whisper_up[0])
    parsed, session_dir = stage_bundle(monkeypatch, tmp_path, "sess-rollback")
    ingests = FakeSessionIngests.empty("sess-rollback").install(monkeypatch)

    async def scenario():
        with pytest.raises(upstream_failure.UpstreamFailure) as exc_info:
            await processor.accept(parsed, session_dir)
        rolled_back = (await processor.get_status("sess-rollback"), session_dir.exists())
        # Claim released: a second accept (Whisper back up) goes through.
        whisper_up[0] = True
        return exc_info.value, rolled_back, await processor.accept(parsed, session_dir)

    failure, rolled_back, accepted = asyncio.run(scenario())

    assert failure.code == "whisper_unavailable"
    assert rolled_back == (None, False)
    assert ingests.deleted == ["sess-rollback"]
    assert [c[0] for c in ingests.created] == ["sess-rollback"] * 2
    assert accepted.state == "processing"


def test_accept_claims_the_session_before_its_processing_row_exists(monkeypatch, tmp_path):
    """BUG-53/#53: the sweep treats an unclaimed `processing` row as an orphan,
    so a fresh upload must hold its in-flight claim from the moment the row is
    created — otherwise the sweep could fail the segments of a live session."""
    processor = fresh_processor(monkeypatch)
    parsed, session_dir = stage_bundle(monkeypatch, tmp_path, "sess-claim-first")
    FakeSessionIngests.empty("sess-claim-first").install(monkeypatch)
    busy_when_row_created: list[bool] = []

    async def create_session_status(session_id, received_at, state, segments) -> None:
        try:
            await processor.retry_analysis(session_id)
        except SessionBusy:
            busy_when_row_created.append(True)
        else:  # pragma: no cover
            busy_when_row_created.append(False)

    monkeypatch.setattr(db, "create_session_status", create_session_status)

    asyncio.run(processor.accept(parsed, session_dir))

    assert busy_when_row_created == [True]


# --- original ingest: run_accepted ----------------------------------------


@pytest.mark.parametrize(
    ("failing", "state"),
    [([], "done"), (["s01", "s02"], "failed"), (["s02"], "partial")],
)
def test_run_accepted_derives_the_final_state_from_the_segment_outcomes(
    monkeypatch, tmp_path, failing, state
):
    processor = fresh_processor(monkeypatch)
    session_id = f"sess-state-{state}"
    parsed, session_dir = stage_bundle(monkeypatch, tmp_path, session_id, two_segment_manifest(session_id))
    ingests = FakeSessionIngests(
        session_id, "processing", [segment_row("s01", "pending_analysis"), segment_row("s02", "pending_analysis")]
    ).install(monkeypatch)
    SegmentPipeline(monkeypatch, failing={seg: RuntimeError("boom") for seg in failing})
    stage = NarrativeStage(monkeypatch)

    async def scenario():
        await processor.run_accepted(parsed, session_dir)
        return await processor.get_status(session_id)

    cached = asyncio.run(scenario())

    assert ingests.row["state"] == cached.state == state
    # Write-through: the cache holds exactly what was persisted.
    assert [s.model_dump() for s in cached.segments] == ingests.row["segments"]
    # Narrative runs only when something was transcribed.
    assert len(stage.runs) == (0 if state == "failed" else 1)


def test_run_accepted_marks_the_session_failed_when_processing_crashes(monkeypatch, tmp_path):
    processor = fresh_processor(monkeypatch)
    session_id = "sess-crash"
    parsed, session_dir = stage_bundle(monkeypatch, tmp_path, session_id)
    ingests = FakeSessionIngests(
        session_id, "processing", [segment_row("s01", "pending_analysis")]
    ).install(monkeypatch)
    SegmentPipeline(monkeypatch)
    NarrativeStage(monkeypatch)

    async def update_session_status(session_id, state, segments) -> None:
        raise RuntimeError("db down")

    monkeypatch.setattr(db, "update_session_status", update_session_status)

    async def scenario():
        await processor.accept(parsed, session_dir)
        await processor.run_accepted(parsed, session_dir)
        return await processor.get_status(session_id)

    cached = asyncio.run(scenario())

    assert ingests.failed == [session_id]
    assert cached.state == "failed"


@pytest.mark.parametrize("crashes", [False, True])
def test_original_ingest_releases_its_claim_on_success_and_failure(monkeypatch, tmp_path, crashes):
    processor = fresh_processor(monkeypatch)
    session_id = f"sess-release-{crashes}"
    parsed, session_dir = stage_bundle(monkeypatch, tmp_path, session_id)
    FakeSessionIngests.empty(session_id).install(monkeypatch)
    SegmentPipeline(monkeypatch)
    NarrativeStage(monkeypatch)
    if crashes:
        async def update_session_status(session_id, state, segments) -> None:
            raise RuntimeError("db down")

        monkeypatch.setattr(db, "update_session_status", update_session_status)

    async def scenario():
        await processor.accept(parsed, session_dir)
        await processor.run_accepted(parsed, session_dir)
        # Released: the session is not busy, just has nothing left to retry.
        with pytest.raises(SessionNotRetryable):
            await processor.retry_analysis(session_id)

    asyncio.run(scenario())


def test_phase_1_persists_each_segment_as_it_finishes(monkeypatch, tmp_path):
    """BUG-53/#53: a transcribed segment's `pending_analysis` + transcript_id
    (or a failed segment's `failed` + error) must hit `session_ingests` as
    soon as phase 1 is done with it — not only at the end of the session."""
    processor = fresh_processor(monkeypatch)
    session_id = "sess-phase1-persist"
    parsed, session_dir = stage_bundle(monkeypatch, tmp_path, session_id, two_segment_manifest(session_id))
    ingests = FakeSessionIngests(
        session_id, "processing", [segment_row("s01", "pending_analysis"), segment_row("s02", "pending_analysis")]
    ).install(monkeypatch)
    SegmentPipeline(
        monkeypatch, transcript_ids={"s01": 11}, failing={"s02": RuntimeError("whisper exploded")},
    )
    stage = NarrativeStage(monkeypatch)
    seen_at_phase_2: list[list[tuple]] = []

    async def at_phase_2(run):
        seen_at_phase_2.append(list(ingests.updates))

    stage.before_analysis = at_phase_2

    asyncio.run(processor.run_accepted(parsed, session_dir))

    after_s01 = (
        "processing",
        [segment_row("s01", "pending_analysis", 11), segment_row("s02", "pending_analysis")],
    )
    after_s02 = (
        "processing",
        [segment_row("s01", "pending_analysis", 11), segment_row("s02", "failed", error="whisper exploded")],
    )
    # Both segment writes had already happened when phase 2 started.
    assert seen_at_phase_2 == [[after_s01, after_s02]]
    # …and the final write still lands, with the usual derived state.
    assert ingests.updates[-1] == (
        "partial",
        [segment_row("s01", "processed", 11), segment_row("s02", "failed", error="whisper exploded")],
    )


def test_phase_1_updates_the_status_cache_per_segment(monkeypatch, tmp_path):
    processor = fresh_processor(monkeypatch)
    session_id = "sess-phase1-cache"
    parsed, session_dir = stage_bundle(monkeypatch, tmp_path, session_id, two_segment_manifest(session_id))
    FakeSessionIngests.empty(session_id).install(monkeypatch)
    SegmentPipeline(monkeypatch, transcript_ids={"s01": 21, "s02": 22})
    stage = NarrativeStage(monkeypatch)
    cache_at_phase_2: list[list[SegmentResult]] = []

    async def at_phase_2(run):
        status = await processor.get_status(session_id)
        cache_at_phase_2.append(list(status.segments))

    stage.before_analysis = at_phase_2

    async def scenario():
        await processor.accept(parsed, session_dir)
        await processor.run_accepted(parsed, session_dir)

    asyncio.run(scenario())

    assert cache_at_phase_2 == [
        [
            SegmentResult(segment_id="s01", status="pending_analysis", transcript_id=21),
            SegmentResult(segment_id="s02", status="pending_analysis", transcript_id=22),
        ]
    ]


# --- per-segment pipeline -------------------------------------------------


def _single_segment_bundle(monkeypatch, tmp_path, session_id: str, **overrides):
    manifest = manifest_dict(session_id)
    manifest["segments"][0]["audio_file"] = "s01.m4a"
    manifest.update(overrides)
    return stage_bundle(monkeypatch, tmp_path, session_id, manifest)


def test_segments_go_through_the_shared_transcribe_and_persist_core(monkeypatch, tmp_path):
    """SRV-A7: the ffmpeg/Whisper/persist steps must go through
    `transcript_ingest.transcribe_and_persist` (the same core `main.py`'s
    `/api/ingest/upload` uses) instead of driving `asr_client` and
    `db.create_transcript` inline."""
    processor = fresh_processor(monkeypatch)
    parsed, session_dir = _single_segment_bundle(monkeypatch, tmp_path, "sess-seg", date="2026-07-04")
    FakeSessionIngests(
        "sess-seg", "processing", [segment_row("s01", "pending_analysis")]
    ).install(monkeypatch)
    pipeline = SegmentPipeline(monkeypatch, transcript_ids={"s01": 7})
    stage = NarrativeStage(monkeypatch)

    asyncio.run(processor.run_accepted(parsed, session_dir))

    assert len(pipeline.transcribe_calls) == 1
    call = pipeline.transcribe_calls[0]
    assert call["audio_bytes"] == b"fake-audio"
    assert call["filename"] == "sess-seg::s01.m4a"
    assert call["date"] == "2026-07-04"
    assert call["author"] == "Florian Wolf"
    assert call["src_suffix"] == ".m4a"
    assert call["language"] == "de"
    assert pipeline.correct_calls[0]["raw_text"] == "hallo welt"
    assert [doc["id"] for doc in stage.documents.values()] == [107]


def test_segments_use_the_shared_correction_module(monkeypatch, tmp_path):
    """#51: dictionary corrections, LLM correction and entity
    detection/dismissal filtering must come from
    `correction.correct_and_detect_entities` — the same chain the HTMX review
    flow runs — and the entities it detects reach both the persisted
    transcript and the narrative stage."""
    processor = fresh_processor(monkeypatch)
    parsed, session_dir = _single_segment_bundle(monkeypatch, tmp_path, "sess-corr")
    FakeSessionIngests(
        "sess-corr", "processing", [segment_row("s01", "pending_analysis")]
    ).install(monkeypatch)
    text_corrections = [{"original_text": "welt", "corrected_text": "Welt"}]
    dismissals = ["Baumarkt"]
    persons = [{"canonical_name": "Anna"}]
    terms = [{"canonical_name": "Sprint"}]

    async def correct(raw_text):
        entity = DetectedEntity(
            start=0, end=4, original_text="Anna", canonical="Anna",
            entity_type="PERSON", match_type="exact", confidence="high",
            status="auto-matched",
        )
        return correction.CorrectionResult(corrected_text="hallo Welt", entities=[entity])

    pipeline = SegmentPipeline(
        monkeypatch, transcript_ids={"s01": 9}, correct=correct,
        persons=persons, terms=terms, text_corrections=text_corrections, dismissals=dismissals,
    )
    stage = NarrativeStage(monkeypatch)

    asyncio.run(processor.run_accepted(parsed, session_dir))

    assert len(pipeline.correct_calls) == 1
    assert pipeline.correct_calls[0] == {
        "raw_text": "hallo welt", "persons": persons, "terms": terms,
        "text_corrections": text_corrections, "dismissals": dismissals,
    }
    expected_entities = [
        {
            "start": 0, "end": 4, "original_text": "Anna", "canonical": "Anna",
            "entity_type": "PERSON", "match_type": "exact", "confidence": "high",
            "status": "auto-matched", "dictionary_id": None, "source": "term",
            "role": "", "candidates": [], "llm_validated": False, "llm_reason": "",
            "llm_suggested": False, "text": "Anna", "type": "PERSON",
        }
    ]
    assert len(pipeline.saved_entities) == 1
    transcript_id, text, entities_json = pipeline.saved_entities[0]
    assert (transcript_id, text) == (9, "hallo Welt")
    assert json.loads(entities_json) == expected_entities
    assert stage.runs[0]["entities"] == expected_entities
    assert stage.runs[0]["text"].endswith("hallo Welt")


def test_segment_entities_are_persisted_even_when_correction_leaves_the_text_unchanged(
    monkeypatch, tmp_path
):
    """#52: entities used to be saved only when correction changed the text, so
    a retry rebuilding the narrative from Postgres always saw none. They must
    always be persisted so a later retry can reload what was detected."""
    processor = fresh_processor(monkeypatch)
    parsed, session_dir = _single_segment_bundle(monkeypatch, tmp_path, "sess-entities")
    FakeSessionIngests(
        "sess-entities", "processing", [segment_row("s01", "pending_analysis")]
    ).install(monkeypatch)

    async def correct(raw_text):
        entity = DetectedEntity(
            start=6, end=10, original_text="Anna", canonical="Anna",
            entity_type="PERSON", match_type="exact", confidence="high",
            status="auto-matched",
        )
        # Correction leaves the text unchanged — only entity detection ran.
        return correction.CorrectionResult(corrected_text=raw_text, entities=[entity])

    pipeline = SegmentPipeline(monkeypatch, transcript_ids={"s01": 11}, correct=correct)
    stage = NarrativeStage(monkeypatch)

    asyncio.run(processor.run_accepted(parsed, session_dir))

    assert len(pipeline.saved_entities) == 1
    transcript_id, text, entities_json = pipeline.saved_entities[0]
    assert (transcript_id, text) == (11, "hallo welt")
    assert json.loads(entities_json) == stage.runs[0]["entities"]
    assert stage.runs[0]["entities"][0]["text"] == "Anna"


def test_a_missing_audio_file_fails_only_its_segment(monkeypatch, tmp_path):
    processor = fresh_processor(monkeypatch)
    session_id = "sess-no-audio"
    parsed, session_dir = stage_bundle(monkeypatch, tmp_path, session_id, two_segment_manifest(session_id))
    (session_dir / "segments" / "s02.m4a").unlink()
    ingests = FakeSessionIngests(
        session_id, "processing", [segment_row("s01", "pending_analysis"), segment_row("s02", "pending_analysis")]
    ).install(monkeypatch)
    SegmentPipeline(monkeypatch, transcript_ids={"s01": 11})
    NarrativeStage(monkeypatch)

    asyncio.run(processor.run_accepted(parsed, session_dir))

    assert ingests.row["state"] == "partial"
    assert ingests.row["segments"][0] == segment_row("s01", "processed", 11)
    assert ingests.row["segments"][1]["status"] == "failed"
    assert "segment audio missing on disk: segments/s02.m4a" in ingests.row["segments"][1]["error"]


# --- narrative persistence ------------------------------------------------


def _run_with_real_narrative_stage(monkeypatch, tmp_path, session_id, *, ingest):
    """Two transcribed segments through the real `narrative` stage (only its
    `document_processor` steps stubbed); returns `(saved_ids, marked_ids)`."""
    processor = fresh_processor(monkeypatch)
    parsed, session_dir = stage_bundle(monkeypatch, tmp_path, session_id, two_segment_manifest(session_id))
    FakeSessionIngests(
        session_id, "processing", [segment_row("s01", "pending_analysis"), segment_row("s02", "pending_analysis")]
    ).install(monkeypatch)
    SegmentPipeline(monkeypatch, transcript_ids={"s01": 1, "s02": 2})
    fake_document_processor_pipeline(monkeypatch, ingest=ingest)
    saved_ids: list[int] = []
    marked_ids: list[int] = []

    async def fake_save_processed_document(*, transcript_id, document_markdown, analysis_json, context_summary, metadata):
        doc_id = 100 + transcript_id
        saved_ids.append(doc_id)
        return {"id": doc_id, "version": 1, "created_at": None}

    async def fake_mark_document_ingested(doc_id):
        marked_ids.append(doc_id)
        return {"id": doc_id, "lightrag_ingested_at": None}

    monkeypatch.setattr(db, "save_processed_document", fake_save_processed_document)
    monkeypatch.setattr(db, "mark_document_ingested", fake_mark_document_ingested)

    asyncio.run(processor.run_accepted(parsed, session_dir))
    return saved_ids, marked_ids


def test_each_saved_document_is_marked_ingested_on_success(monkeypatch, tmp_path):
    """T1/#49: after a successful LightRAG ingest, every `processed_documents`
    row saved for the session must be marked ingested — otherwise the day
    shows as "not ingested" on `/process/{id}` forever."""

    async def fake_ingest(markdown, metadata, *, client=None):
        return None

    saved_ids, marked_ids = _run_with_real_narrative_stage(
        monkeypatch, tmp_path, "sess-mark", ingest=fake_ingest
    )

    assert marked_ids == saved_ids == [101, 102]


def test_saved_documents_stay_unmarked_when_the_ingest_fails(monkeypatch, tmp_path):
    """T1/#49: a failed LightRAG ingest must not mark the already-saved rows
    ingested — they stay retryable."""

    async def fake_ingest_that_fails(markdown, metadata, *, client=None):
        raise RuntimeError("lightrag unreachable")

    saved_ids, marked_ids = _run_with_real_narrative_stage(
        monkeypatch, tmp_path, "sess-mark-fail", ingest=fake_ingest_that_fails
    )

    assert saved_ids == [101, 102]
    assert marked_ids == []


# --- manual retry ---------------------------------------------------------


def test_retry_raises_session_not_found_for_an_unknown_session(monkeypatch):
    """#52: neither cache nor persisted row knows the session."""
    processor = fresh_processor(monkeypatch)

    async def fake_get_session_status(session_id: str) -> dict | None:
        return None

    monkeypatch.setattr(db, "get_session_status", fake_get_session_status)

    with pytest.raises(SessionNotFound):
        asyncio.run(processor.retry_analysis("unknown"))


def test_retry_raises_not_retryable_when_no_segment_is_pending_analysis(monkeypatch):
    """#52: a session with no `pending_analysis` segment (e.g. fully `done`,
    or still `processing`) is not in a retryable state."""
    processor = fresh_processor(monkeypatch)
    FakeSessionIngests(
        "sess-done", "done", [segment_row("s01", "processed", 1)]
    ).install(monkeypatch)

    with pytest.raises(SessionNotRetryable):
        asyncio.run(processor.retry_analysis("sess-done"))


def test_retry_raises_not_retryable_when_no_pending_segment_has_a_transcript_row(monkeypatch, tmp_path):
    processor = fresh_processor(monkeypatch)
    stage_bundle(monkeypatch, tmp_path, "sess-no-transcript")
    FakeSessionIngests(
        "sess-no-transcript", "done", [segment_row("s01", "pending_analysis", 9, "analysis_pending: boom")]
    ).install(monkeypatch)
    stub_transcripts(monkeypatch, [])

    with pytest.raises(SessionNotRetryable):
        asyncio.run(processor.retry_analysis("sess-no-transcript"))


# --- resuming sessions that never reached transcription (BUG-112) ---------


def _stage_untranscribed_session(monkeypatch, tmp_path, session_id, segments):
    """A two-segment bundle on disk whose persisted `processing` row holds
    `segments`; returns the session directory and the fake table."""
    _, session_dir = stage_bundle(monkeypatch, tmp_path, session_id, two_segment_manifest(session_id))
    ingests = FakeSessionIngests(session_id, "processing", segments).install(monkeypatch)
    return session_dir, ingests


def test_retry_resumes_untranscribed_segments_from_the_stored_audio(monkeypatch, tmp_path):
    processor = fresh_processor(monkeypatch)
    session_id = "sess-resume"
    _, ingests = _stage_untranscribed_session(
        monkeypatch, tmp_path, session_id,
        [segment_row("s01", "pending_analysis"), segment_row("s02", "pending_analysis")],
    )
    pipeline = SegmentPipeline(monkeypatch, transcript_ids={"s01": 11, "s02": 12})
    stage = NarrativeStage(monkeypatch)

    result = asyncio.run(processor.retry_analysis(session_id))

    assert [c["filename"] for c in pipeline.transcribe_calls] == [
        f"{session_id}::s01.m4a", f"{session_id}::s02.m4a",
    ]
    assert all(c["audio_bytes"] == b"fake-audio" for c in pipeline.transcribe_calls)
    assert [t[0] for t in pipeline.saved_entities] == [11, 12]
    assert len(stage.runs) == 1
    assert [doc["id"] for doc in stage.documents.values()] == [111, 112]
    assert result.state == "done"
    assert ingests.row["state"] == "done"
    assert ingests.row["segments"] == [segment_row("s01", "processed", 11), segment_row("s02", "processed", 12)]


def test_retry_persists_each_resumed_transcript_id_before_the_narrative_runs(monkeypatch, tmp_path):
    processor = fresh_processor(monkeypatch)
    session_id = "sess-resume-progress"
    _, ingests = _stage_untranscribed_session(
        monkeypatch, tmp_path, session_id,
        [segment_row("s01", "pending_analysis"), segment_row("s02", "pending_analysis")],
    )
    SegmentPipeline(monkeypatch, transcript_ids={"s01": 11, "s02": 12})
    stage = NarrativeStage(monkeypatch)
    seen: list[list[dict]] = []

    async def before_analysis(run):
        seen.append(ingests.row["segments"])

    stage.before_analysis = before_analysis

    asyncio.run(processor.retry_analysis(session_id))

    assert seen == [[segment_row("s01", "pending_analysis", 11), segment_row("s02", "pending_analysis", 12)]]


def test_retry_fails_a_segment_whose_audio_is_missing_and_derives_the_session_state(monkeypatch, tmp_path):
    processor = fresh_processor(monkeypatch)
    session_id = "sess-resume-no-audio"
    session_dir, ingests = _stage_untranscribed_session(
        monkeypatch, tmp_path, session_id,
        [segment_row("s01", "pending_analysis"), segment_row("s02", "pending_analysis")],
    )
    (session_dir / "segments" / "s02.m4a").unlink()
    SegmentPipeline(monkeypatch, transcript_ids={"s01": 11})
    stage = NarrativeStage(monkeypatch)

    result = asyncio.run(processor.retry_analysis(session_id))

    assert result.state == "partial"
    assert ingests.row["state"] == "partial"
    assert ingests.row["segments"][0] == segment_row("s01", "processed", 11)
    assert ingests.row["segments"][1]["status"] == "failed"
    assert ingests.row["segments"][1]["transcript_id"] is None
    assert "segment audio missing on disk: segments/s02.m4a" in ingests.row["segments"][1]["error"]
    assert len(stage.runs) == 1


def test_retry_of_a_session_with_no_audio_left_ends_failed_without_raising(monkeypatch, tmp_path):
    processor = fresh_processor(monkeypatch)
    session_id = "sess-resume-all-gone"
    session_dir, ingests = _stage_untranscribed_session(
        monkeypatch, tmp_path, session_id,
        [segment_row("s01", "pending_analysis"), segment_row("s02", "pending_analysis")],
    )
    for audio in (session_dir / "segments").iterdir():
        audio.unlink()
    pipeline = SegmentPipeline(monkeypatch)
    stage = NarrativeStage(monkeypatch)

    result = asyncio.run(processor.retry_analysis(session_id))

    assert result.state == "failed"
    assert [s.status for s in result.segments] == ["failed", "failed"]
    assert ingests.row["state"] == "failed"
    assert all("audio missing on disk" in s["error"] for s in ingests.row["segments"])
    assert pipeline.transcribe_calls == []
    assert stage.runs == []


def test_retry_resumes_only_the_untranscribed_segments_of_a_mixed_session(monkeypatch, tmp_path):
    processor = fresh_processor(monkeypatch)
    session_id = "sess-resume-mixed"
    _, ingests = _stage_untranscribed_session(
        monkeypatch, tmp_path, session_id,
        [segment_row("s01", "pending_analysis", 41), segment_row("s02", "pending_analysis")],
    )
    pipeline = SegmentPipeline(monkeypatch, transcript_ids={"s02": 42})
    stub_transcripts(monkeypatch, [41])
    stage = NarrativeStage(monkeypatch)

    asyncio.run(processor.retry_analysis(session_id))

    assert [c["filename"] for c in pipeline.transcribe_calls] == [f"{session_id}::s02.m4a"]
    assert len(stage.runs) == 1
    assert stage.runs[0]["text"].index("text-41") < stage.runs[0]["text"].index("hallo welt")
    assert ingests.row["state"] == "done"
    assert ingests.row["segments"] == [segment_row("s01", "processed", 41), segment_row("s02", "processed", 42)]


def test_retry_resumes_an_untranscribed_segment_even_when_another_ones_transcript_row_is_gone(monkeypatch, tmp_path):
    processor = fresh_processor(monkeypatch)
    session_id = "sess-resume-row-gone"
    _, ingests = _stage_untranscribed_session(
        monkeypatch, tmp_path, session_id,
        [segment_row("s01", "pending_analysis", 9, "analysis_pending: boom"), segment_row("s02", "pending_analysis")],
    )
    pipeline = SegmentPipeline(monkeypatch, transcript_ids={"s02": 12})
    stub_transcripts(monkeypatch, [])
    stage = NarrativeStage(monkeypatch)

    asyncio.run(processor.retry_analysis(session_id))

    assert [c["filename"] for c in pipeline.transcribe_calls] == [f"{session_id}::s02.m4a"]
    assert len(stage.runs) == 1
    assert ingests.row["segments"][1] == segment_row("s02", "processed", 12)


def test_retry_that_is_not_retryable_resumes_nothing(monkeypatch, tmp_path):
    processor = fresh_processor(monkeypatch)
    session_id = "sess-nothing-to-resume"
    stage_bundle(monkeypatch, tmp_path, session_id)
    ingests = FakeSessionIngests(
        session_id, "done", [segment_row("s01", "pending_analysis", 9, "analysis_pending: boom")]
    ).install(monkeypatch)
    pipeline = SegmentPipeline(monkeypatch)
    stub_transcripts(monkeypatch, [])

    with pytest.raises(SessionNotRetryable):
        asyncio.run(processor.retry_analysis(session_id))

    assert pipeline.transcribe_calls == []
    assert ingests.updates == []


def test_retry_fails_a_resumed_segment_when_transcription_fails_and_continues_with_the_rest(monkeypatch, tmp_path):
    processor = fresh_processor(monkeypatch)
    session_id = "sess-resume-whisper-fails"
    _, ingests = _stage_untranscribed_session(
        monkeypatch, tmp_path, session_id,
        [segment_row("s01", "pending_analysis"), segment_row("s02", "pending_analysis")],
    )
    SegmentPipeline(monkeypatch, transcript_ids={"s02": 12}, failing={"s01": RuntimeError("whisper boom")})
    NarrativeStage(monkeypatch)

    asyncio.run(processor.retry_analysis(session_id))

    assert ingests.row["state"] == "partial"
    assert ingests.row["segments"][0]["status"] == "failed"
    assert "whisper boom" in ingests.row["segments"][0]["error"]
    assert ingests.row["segments"][1] == segment_row("s02", "processed", 12)


def test_retry_fails_an_untranscribed_segment_missing_from_the_manifest(monkeypatch, tmp_path):
    processor = fresh_processor(monkeypatch)
    session_id = "sess-resume-unknown-segment"
    _, ingests = _stage_untranscribed_session(
        monkeypatch, tmp_path, session_id,
        [segment_row("s01", "pending_analysis"), segment_row("s09", "pending_analysis")],
    )
    SegmentPipeline(monkeypatch, transcript_ids={"s01": 11})
    NarrativeStage(monkeypatch)

    asyncio.run(processor.retry_analysis(session_id))

    assert ingests.row["state"] == "partial"
    assert ingests.row["segments"][1]["status"] == "failed"
    assert "not in manifest.json" in ingests.row["segments"][1]["error"]


def test_retry_ingest_only_failure_reingests_without_rerunning_analysis(monkeypatch, tmp_path):
    """#52 acceptance: when analysis already succeeded and saved a document
    (only the LightRAG ingest failed), retry must re-ingest that saved
    narrative and mark it ingested — not re-run the LLM analysis."""
    processor = fresh_processor(monkeypatch)
    session_id = "sess-retry-ingest-only"
    ingests = stage_pending_session(monkeypatch, tmp_path, session_id)
    stage = NarrativeStage(monkeypatch)
    metadata = {"date": "2026-07-01", "author": "Florian Wolf"}
    stage.save_document(5, "# already analyzed narrative", metadata)

    result = asyncio.run(processor.retry_analysis(session_id))

    assert result.state == "done"
    assert result.segments[0].status == "processed"
    assert stage.runs == []
    assert stage.ingested == [("# already analyzed narrative", metadata)]
    assert stage.marked == [105]
    assert ingests.updates == [("done", [segment_row("s01", "processed", 5)])]


def test_retry_rebuilds_the_narrative_from_persisted_transcripts_and_marks_done(monkeypatch, tmp_path):
    """#52: the happy path — analysis never completed (no saved document yet),
    so retry must reload the manifest from disk, reload each pending segment's
    transcript + entities from Postgres, re-run the full narrative stage, and
    flip the segment (and session) to done."""
    processor = fresh_processor(monkeypatch)
    session_id = "sess-retry-full"
    ingests = stage_pending_session(monkeypatch, tmp_path, session_id)
    entities = [{"type": "PERSON", "text": "Anna"}]
    stub_transcripts(monkeypatch, [5], entities_json=json.dumps(entities))
    stage = NarrativeStage(monkeypatch)

    result = asyncio.run(processor.retry_analysis(session_id))

    assert result.state == "done"
    assert [s.model_dump() for s in result.segments] == [segment_row("s01", "processed", 5)]
    assert len(stage.runs) == 1
    assert stage.runs[0]["entities"] == entities
    assert stage.runs[0]["text"].endswith("text-5")
    assert stage.runs[0]["date"] == "2026-07-01"
    assert [doc["id"] for doc in stage.documents.values()] == [105]
    assert stage.marked == [105]
    assert ingests.updates == [("done", [segment_row("s01", "processed", 5)])]


def test_retry_leaves_the_segment_pending_when_analysis_fails_again(monkeypatch, tmp_path):
    """BUG-56/#56: the narrative stage failing again on retry must not raise —
    the segments stay `pending_analysis` with an `analysis_pending: …` error
    (same shape as the original ingest) and the status is persisted."""
    processor = fresh_processor(monkeypatch)
    session_id = "sess-retry-analysis-fails"
    ingests = stage_pending_session(monkeypatch, tmp_path, session_id)
    stage = NarrativeStage(monkeypatch)
    stage.analysis_error = RuntimeError("ollama unreachable")

    async def scenario():
        result = await processor.retry_analysis(session_id)
        return result, await processor.get_status(session_id)

    result, cached = asyncio.run(scenario())

    expected = [segment_row("s01", "pending_analysis", 5, "analysis_pending: ollama unreachable")]
    assert [s.model_dump() for s in result.segments] == expected
    assert ingests.updates == [(result.state, expected)]
    # Still retryable afterwards: the cached status is the updated one.
    assert [s.model_dump() for s in cached.segments] == expected


def test_retry_leaves_the_segment_pending_when_the_reingest_fails_again(monkeypatch, tmp_path):
    """BUG-56/#56: same for the ingest-only shortcut — a saved document whose
    LightRAG re-ingest fails again stays unmarked and the segment stays
    `pending_analysis` with the new error."""
    processor = fresh_processor(monkeypatch)
    session_id = "sess-retry-ingest-fails"
    ingests = stage_pending_session(monkeypatch, tmp_path, session_id)
    stage = NarrativeStage(monkeypatch)
    stage.save_document(5, "# already analyzed narrative", {"date": "2026-07-01"})
    stage.ingest_error = RuntimeError("lightrag unreachable")

    result = asyncio.run(processor.retry_analysis(session_id))

    expected = [segment_row("s01", "pending_analysis", 5, "analysis_pending: lightrag unreachable")]
    assert [s.model_dump() for s in result.segments] == expected
    assert stage.marked == []
    assert stage.runs == []
    assert ingests.updates == [(result.state, expected)]


# --- manual retry: ingest-only shortcut -----------------------------------


def _retry_with_saved_documents(monkeypatch, tmp_path, documents: dict[int, dict | None]):
    """A pending session with one segment per transcript id in `documents`
    (`{markdown, ingested, metadata}` of the latest saved document, or `None`
    for none yet), retried once; returns the narrative stage for inspection.
    A re-analysis shows up as `stage.runs`; a re-ingest of the saved narrative
    as `stage.ingested`."""
    processor = fresh_processor(monkeypatch)
    session_id = "sess-retry-shortcut"
    manifest = manifest_dict(session_id)
    manifest["segments"] = [
        {**manifest["segments"][0], "segment_id": f"s{tid:02d}", "audio_file": f"segments/s{tid:02d}.m4a"}
        for tid in documents
    ]
    stage_bundle(monkeypatch, tmp_path, session_id, manifest)
    FakeSessionIngests(
        session_id, "done",
        [segment_row(f"s{tid:02d}", "pending_analysis", tid, "analysis_pending: boom") for tid in documents],
    ).install(monkeypatch)
    stub_transcripts(monkeypatch, documents)
    stage = NarrativeStage(monkeypatch)
    for tid, doc in documents.items():
        if doc is not None:
            stage.save_document(tid, doc["markdown"], doc.get("metadata", {"date": "2026-07-01"}), ingested=doc["ingested"])

    asyncio.run(processor.retry_analysis(session_id))
    return stage


def test_retry_reanalyzes_when_a_latest_document_diverges(monkeypatch, tmp_path):
    """One segment's latest document is a different (single-segment) narrative
    than the whole-session one: must re-analyze, not ingest docs[0] and mark
    both rows ingested."""
    stage = _retry_with_saved_documents(
        monkeypatch, tmp_path,
        {
            1: {"markdown": "# whole session", "ingested": False},
            2: {"markdown": "# single segment only", "ingested": False},
        },
    )

    assert len(stage.runs) == 1
    # Re-analysis saved and ingested a fresh narrative, rather than re-ingesting docs[0].
    assert stage.ingested == [("# narrative", {"date": "2026-07-01"})]


def test_retry_reanalyzes_when_the_document_metadata_diverges(monkeypatch, tmp_path):
    stage = _retry_with_saved_documents(
        monkeypatch, tmp_path,
        {
            1: {"markdown": "# same", "ingested": False, "metadata": {"date": "2026-07-01"}},
            2: {"markdown": "# same", "ingested": False, "metadata": {"date": "2026-07-02"}},
        },
    )

    assert len(stage.runs) == 1
    assert ("# same", {"date": "2026-07-01"}) not in stage.ingested


def test_retry_reingests_identical_unmarked_documents_once(monkeypatch, tmp_path):
    stage = _retry_with_saved_documents(
        monkeypatch, tmp_path,
        {
            1: {"markdown": "# whole session", "ingested": False, "metadata": '{"date": "2026-07-01"}'},
            2: {"markdown": "# whole session", "ingested": False},
        },
    )

    assert stage.runs == []
    assert stage.ingested == [("# whole session", {"date": "2026-07-01"})]
    assert stage.marked == [101, 102]


def test_retry_marks_only_the_remainder_when_some_rows_were_already_marked(monkeypatch, tmp_path):
    """A previous run ingested the narrative then died part-way through
    marking: the marked rows prove the ingest happened, so mark the rest
    without re-ingesting."""
    stage = _retry_with_saved_documents(
        monkeypatch, tmp_path,
        {
            1: {"markdown": "# whole session", "ingested": True},
            2: {"markdown": "# whole session", "ingested": False},
            3: {"markdown": "# whole session", "ingested": False},
        },
    )

    assert stage.runs == []
    assert stage.ingested == []
    assert stage.marked == [102, 103]


def test_retry_reanalyzes_when_every_document_is_marked_or_one_is_missing(monkeypatch, tmp_path):
    all_marked = _retry_with_saved_documents(
        monkeypatch, tmp_path / "a",
        {1: {"markdown": "# a", "ingested": True}, 2: {"markdown": "# a", "ingested": True}},
    )
    one_missing = _retry_with_saved_documents(
        monkeypatch, tmp_path / "b", {1: {"markdown": "# a", "ingested": False}, 2: None},
    )

    assert len(all_marked.runs) == 1
    assert len(one_missing.runs) == 1


def test_retry_releases_its_claim_after_success_and_after_failure(monkeypatch, tmp_path):
    """Both a narrative failure (pending segments) and an exception escaping
    the retry (missing manifest) must release the claim."""
    processor = fresh_processor(monkeypatch)
    session_id = "sess-retry-release"
    stage_pending_session(monkeypatch, tmp_path, session_id)
    stage = NarrativeStage(monkeypatch)
    manifest_path = session_processing.session_dir_for(session_id) / "manifest.json"

    async def scenario():
        stage.analysis_error = RuntimeError("ollama unreachable")
        # The cached status object is updated in place, so snapshot each result.
        first = (await processor.retry_analysis(session_id)).model_copy(deep=True)
        second = (await processor.retry_analysis(session_id)).model_copy(deep=True)
        manifest_text = manifest_path.read_text()
        manifest_path.unlink()
        with pytest.raises(SessionManifestMissing):
            await processor.retry_analysis(session_id)
        manifest_path.write_text(manifest_text)
        stage.analysis_error = None
        third = (await processor.retry_analysis(session_id)).model_copy(deep=True)
        with pytest.raises(SessionNotRetryable):
            await processor.retry_analysis(session_id)
        return first, second, third

    first, second, third = asyncio.run(scenario())

    assert first.segments[0].status == second.segments[0].status == "pending_analysis"
    assert third.segments[0].status == "processed"


def test_concurrent_retries_run_the_narrative_once_and_the_other_is_busy(monkeypatch, tmp_path):
    """A double tap: while the first retry is in flight, the second is refused
    as busy, and the narrative stage ran exactly once."""
    processor = fresh_processor(monkeypatch)
    session_id = "sess-retry-double-tap"
    stage_pending_session(monkeypatch, tmp_path, session_id)
    stage = NarrativeStage(monkeypatch)

    async def scenario():
        started, release = stage.latch()
        first = asyncio.create_task(processor.retry_analysis(session_id))
        try:
            await asyncio.wait_for(started.wait(), 5)
            with pytest.raises(SessionBusy):
                await asyncio.wait_for(processor.retry_analysis(session_id), 2)
        finally:
            release.set()
        return await first

    result = asyncio.run(scenario())

    assert result.segments[0].status == "processed"
    assert len(stage.runs) == 1


def test_retry_is_busy_during_the_original_ingest_and_free_once_it_ends(monkeypatch, tmp_path):
    processor = fresh_processor(monkeypatch)
    session_id = "sess-retry-vs-ingest"
    parsed, session_dir = stage_bundle(monkeypatch, tmp_path, session_id)
    FakeSessionIngests.empty(session_id).install(monkeypatch)
    SegmentPipeline(monkeypatch)
    stage = NarrativeStage(monkeypatch)

    async def scenario():
        started, release = stage.latch()
        await processor.accept(parsed, session_dir)
        run = asyncio.create_task(processor.run_accepted(parsed, session_dir))
        try:
            await asyncio.wait_for(started.wait(), 5)
            with pytest.raises(SessionBusy):
                await processor.retry_analysis(session_id)
        finally:
            release.set()
        await run
        # Released: the session is just not retryable any more, no longer busy.
        with pytest.raises(SessionNotRetryable):
            await processor.retry_analysis(session_id)

    asyncio.run(scenario())

    assert len(stage.runs) == 1


# --- startup sweep --------------------------------------------------------


def _stage_stuck_sessions(monkeypatch, tmp_path, sessions: dict[str, int]) -> FakeSessionIngests:
    """One persisted `pending_analysis` session per `session_id -> transcript
    id`, each with its bundle on disk."""
    ingests = None
    for session_id, transcript_id in sessions.items():
        stage_bundle(monkeypatch, tmp_path, session_id)
        segments = [segment_row("s01", "pending_analysis", transcript_id, "analysis_pending: boom")]
        if ingests is None:
            ingests = FakeSessionIngests(session_id, "done", segments)
        else:
            ingests.add(session_id, "done", segments)
    ingests.install(monkeypatch)
    stub_transcripts(monkeypatch, sessions.values())
    return ingests


def test_sweep_retries_every_stuck_session(monkeypatch, tmp_path):
    processor = fresh_processor(monkeypatch)
    ingests = _stage_stuck_sessions(monkeypatch, tmp_path, {"sess-a": 5, "sess-b": 6})
    stage = NarrativeStage(monkeypatch)

    asyncio.run(processor.retry_stuck_sessions_on_startup())

    assert [run["text"].endswith(f"text-{tid}") for run, tid in zip(stage.runs, (5, 6))] == [True, True]
    assert {sid: row["segments"][0]["status"] for sid, row in ingests.rows.items()} == {
        "sess-a": "processed", "sess-b": "processed",
    }


def test_sweep_logs_one_line_per_session_whose_retry_fails_again(monkeypatch, tmp_path, caplog):
    """BUG-56/#56: a narrative failure doesn't raise out of the retry, so the
    sweep must notice the still-pending segments itself and log exactly one
    line per such session (and none for sessions that recovered)."""
    processor = fresh_processor(monkeypatch)
    ingests = _stage_stuck_sessions(monkeypatch, tmp_path, {"sess-recovers": 5, "sess-fails": 6})
    stage = NarrativeStage(monkeypatch)
    stage.analysis_error = lambda run: RuntimeError("ollama unreachable") if "text-6" in run["text"] else None

    with caplog.at_level(logging.INFO, logger=session_processing.logger.name):
        asyncio.run(processor.retry_stuck_sessions_on_startup())

    lines = _sweep_lines(caplog)
    assert len(lines) == 1
    assert "sess-fails" in lines[0].getMessage()
    assert "ollama unreachable" in lines[0].getMessage()
    assert lines[0].exc_info is None
    assert ingests.rows["sess-recovers"]["segments"][0]["status"] == "processed"
    assert ingests.rows["sess-fails"]["segments"][0]["status"] == "pending_analysis"


def test_sweep_keeps_going_when_one_sessions_retry_blows_up(monkeypatch, tmp_path, caplog):
    """#52: the sweep must be bounded/sequential/best-effort — one session's
    retry blowing up must not stop the rest from being tried, and the failure
    is logged, not re-raised."""
    processor = fresh_processor(monkeypatch)
    _stage_stuck_sessions(monkeypatch, tmp_path, {"sess-a": 5, "sess-b": 6, "sess-c": 7})
    stage = NarrativeStage(monkeypatch)
    healthy_get_transcript = db.get_transcript

    async def get_transcript(transcript_id: int) -> dict | None:
        if transcript_id == 6:
            raise RuntimeError("db unreachable")
        return await healthy_get_transcript(transcript_id)

    monkeypatch.setattr(db, "get_transcript", get_transcript)

    with caplog.at_level(logging.INFO, logger=session_processing.logger.name):
        asyncio.run(processor.retry_stuck_sessions_on_startup())

    assert [run["text"].rsplit("text-", 1)[1] for run in stage.runs] == ["5", "7"]
    lines = _sweep_lines(caplog)
    assert len(lines) == 1
    assert "sess-b" in lines[0].getMessage() and "db unreachable" in lines[0].getMessage()


def test_sweep_releases_its_claims_after_success_and_failure(monkeypatch, tmp_path):
    processor = fresh_processor(monkeypatch)
    ingests = _stage_stuck_sessions(monkeypatch, tmp_path, {"sess-ok": 5, "sess-boom": 6})
    NarrativeStage(monkeypatch)
    healthy_get_transcript = db.get_transcript
    broken = [True]

    async def get_transcript(transcript_id: int) -> dict | None:
        if transcript_id == 6 and broken[0]:
            raise RuntimeError("db unreachable")
        return await healthy_get_transcript(transcript_id)

    monkeypatch.setattr(db, "get_transcript", get_transcript)

    async def scenario():
        await processor.retry_stuck_sessions_on_startup()
        # A second sweep reaches the failed session again only if it stayed unclaimed.
        broken[0] = False
        await processor.retry_stuck_sessions_on_startup()

    asyncio.run(scenario())

    assert ingests.rows["sess-boom"]["segments"][0]["status"] == "processed"


def test_sweep_skips_a_session_with_a_retry_in_flight(monkeypatch, tmp_path, caplog):
    """The sweep must not start a second narrative run for a session that is
    already busy (here: a manual retry holding the claim)."""
    processor = fresh_processor(monkeypatch)
    session_id = "sess-sweep-busy"
    stage_pending_session(monkeypatch, tmp_path, session_id)
    stage = NarrativeStage(monkeypatch)

    async def list_pending_analysis_session_ids():
        return [session_id]

    monkeypatch.setattr(db, "list_pending_analysis_session_ids", list_pending_analysis_session_ids)

    async def scenario():
        started, release = stage.latch()
        retry = asyncio.create_task(processor.retry_analysis(session_id))
        try:
            await asyncio.wait_for(started.wait(), 5)
            await asyncio.wait_for(processor.retry_stuck_sessions_on_startup(), 2)
        finally:
            release.set()
        return await retry

    with caplog.at_level(logging.INFO, logger=session_processing.logger.name):
        result = asyncio.run(scenario())

    assert result.segments[0].status == "processed"
    assert len(stage.runs) == 1
    assert any("busy" in r.getMessage() and session_id in r.getMessage() for r in caplog.records)


def test_sweep_skips_a_processing_session_active_in_this_process(monkeypatch, tmp_path):
    """BUG-53/#53: a `processing` row with null transcript IDs is normal while
    this process is still working on it — the sweep must neither fail its
    segments nor start a second run, nor release a claim it never took."""
    processor = fresh_processor(monkeypatch)
    session_id = "sess-active-here"
    parsed, session_dir = stage_bundle(monkeypatch, tmp_path, session_id, two_segment_manifest(session_id))
    ingests = FakeSessionIngests.empty(session_id).install(monkeypatch)
    stub_transcripts(monkeypatch, [])
    stage = NarrativeStage(monkeypatch)

    async def scenario():
        await processor.accept(parsed, session_dir)
        await processor.retry_stuck_sessions_on_startup()
        with pytest.raises(SessionBusy):
            await processor.retry_analysis(session_id)

    asyncio.run(scenario())

    assert ingests.updates == []
    assert ingests.row["state"] == "processing"
    assert stage.runs == []


class _ProcessDied(BaseException):
    """Escapes `except Exception`, like the process being killed."""


def test_sweep_recovers_a_session_after_a_crash_between_phase_1_and_phase_2(monkeypatch, tmp_path):
    """BUG-53/#53: the process dying during phase 2 used to strand the row as
    `processing` with null transcript IDs. With the IDs persisted per segment,
    the next startup's sweep finds the session and finishes the narrative."""
    session_id = "sess-crash-phase-2"
    manifest = two_segment_manifest(session_id)
    parsed, session_dir = stage_bundle(monkeypatch, tmp_path, session_id, manifest)
    ingests = FakeSessionIngests(
        session_id, "processing", [segment_row("s01", "pending_analysis"), segment_row("s02", "pending_analysis")]
    ).install(monkeypatch)
    SegmentPipeline(monkeypatch, transcript_ids={"s01": 31, "s02": 32})
    dying_stage = NarrativeStage(monkeypatch)
    dying_stage.analysis_error = _ProcessDied()

    with pytest.raises(_ProcessDied):
        asyncio.run(fresh_processor(monkeypatch).run_accepted(parsed, session_dir))
    assert ingests.row["state"] == "processing"
    assert ingests.row["segments"] == [
        segment_row("s01", "pending_analysis", 31), segment_row("s02", "pending_analysis", 32),
    ]

    # "Restart": a fresh processor (empty cache and claims), a healthy narrative stage.
    restarted = fresh_processor(monkeypatch)
    stage = NarrativeStage(monkeypatch)
    stub_transcripts(monkeypatch, [31, 32])

    asyncio.run(restarted.retry_stuck_sessions_on_startup())

    assert len(stage.runs) == 1
    assert [doc["id"] for doc in stage.documents.values()] == [131, 132]
    assert ingests.row["state"] == "done"
    assert ingests.row["segments"] == [segment_row("s01", "processed", 31), segment_row("s02", "processed", 32)]


def test_sweep_resumes_the_untranscribed_segments_of_an_interrupted_session(monkeypatch, tmp_path):
    """BUG-112: crash mid phase 1 — s01 was transcribed (id persisted), s02
    never got one. The sweep transcribes s02 from the stored audio and
    finishes the narrative for both."""
    processor = fresh_processor(monkeypatch)
    session_id = "sess-crash-phase-1"
    stage_bundle(monkeypatch, tmp_path, session_id, two_segment_manifest(session_id))
    ingests = FakeSessionIngests(
        session_id, "processing", [segment_row("s01", "pending_analysis", 41), segment_row("s02", "pending_analysis")]
    ).install(monkeypatch)
    pipeline = SegmentPipeline(monkeypatch, transcript_ids={"s02": 42})
    stub_transcripts(monkeypatch, [41])
    stage = NarrativeStage(monkeypatch)

    asyncio.run(processor.retry_stuck_sessions_on_startup())

    assert [c["filename"] for c in pipeline.transcribe_calls] == [f"{session_id}::s02.m4a"]
    assert [doc["id"] for doc in stage.documents.values()] == [141, 142]
    final_state, final_segments = ingests.updates[-1]
    assert final_state == "done"
    assert final_segments == [segment_row("s01", "processed", 41), segment_row("s02", "processed", 42)]


def test_sweep_reaches_done_for_a_session_nothing_of_which_was_transcribed(monkeypatch, tmp_path):
    processor = fresh_processor(monkeypatch)
    session_id = "sess-nothing-transcribed"
    stage_bundle(monkeypatch, tmp_path, session_id, two_segment_manifest(session_id))
    ingests = FakeSessionIngests(
        session_id, "processing", [segment_row("s01", "pending_analysis"), segment_row("s02", "pending_analysis")]
    ).install(monkeypatch)
    SegmentPipeline(monkeypatch, transcript_ids={"s01": 11, "s02": 12})
    stage = NarrativeStage(monkeypatch)

    asyncio.run(processor.retry_stuck_sessions_on_startup())

    assert len(stage.runs) == 1
    assert ingests.row["state"] == "done"
    assert [s["status"] for s in ingests.row["segments"]] == ["processed", "processed"]


def test_sweep_fails_the_segment_whose_audio_is_missing_and_finishes_the_rest(monkeypatch, tmp_path):
    processor = fresh_processor(monkeypatch)
    session_id = "sess-crash-no-audio"
    _, session_dir = stage_bundle(monkeypatch, tmp_path, session_id, two_segment_manifest(session_id))
    (session_dir / "segments" / "s02.m4a").unlink()
    ingests = FakeSessionIngests(
        session_id, "processing", [segment_row("s01", "pending_analysis", 41), segment_row("s02", "pending_analysis")]
    ).install(monkeypatch)
    SegmentPipeline(monkeypatch)
    stub_transcripts(monkeypatch, [41])
    stage = NarrativeStage(monkeypatch)

    asyncio.run(processor.retry_stuck_sessions_on_startup())

    assert len(stage.runs) == 1
    assert ingests.row["state"] == "partial"
    assert ingests.row["segments"][0] == segment_row("s01", "processed", 41)
    assert ingests.row["segments"][1]["status"] == "failed"
    assert "segment audio missing on disk: segments/s02.m4a" in ingests.row["segments"][1]["error"]


def test_sweep_marks_a_session_failed_when_none_of_its_audio_is_left(monkeypatch, tmp_path):
    """No audio and no transcript for any segment: the sweep settles the
    session `failed` with an explicit error per segment; nothing to narrate."""
    processor = fresh_processor(monkeypatch)
    session_id = "sess-nothing-left"
    _, session_dir = stage_bundle(monkeypatch, tmp_path, session_id, two_segment_manifest(session_id))
    for audio in (session_dir / "segments").iterdir():
        audio.unlink()
    ingests = FakeSessionIngests(
        session_id, "processing", [segment_row("s01", "pending_analysis"), segment_row("s02", "pending_analysis")]
    ).install(monkeypatch)
    SegmentPipeline(monkeypatch)
    stage = NarrativeStage(monkeypatch)

    asyncio.run(processor.retry_stuck_sessions_on_startup())

    assert stage.runs == []
    assert ingests.row["state"] == "failed"
    assert [s["status"] for s in ingests.row["segments"]] == ["failed", "failed"]
    assert all("audio missing on disk" in s["error"] for s in ingests.row["segments"])


def test_sweep_logs_one_line_without_traceback_for_a_non_retryable_session(monkeypatch, tmp_path, caplog):
    """BUG-53/#53: a session whose pending segments point at transcript rows
    that are gone can't be retried. The sweep says so in one warning line —
    no traceback."""
    processor = fresh_processor(monkeypatch)
    session_id = "sess-transcripts-gone"
    stage_bundle(monkeypatch, tmp_path, session_id, two_segment_manifest(session_id))
    FakeSessionIngests(
        session_id, "done",
        [segment_row("s01", "pending_analysis", 61, "analysis_pending: boom"),
         segment_row("s02", "pending_analysis", 62, "analysis_pending: boom")],
    ).install(monkeypatch)
    stub_transcripts(monkeypatch, [])
    stage = NarrativeStage(monkeypatch)

    with caplog.at_level(logging.INFO, logger=session_processing.logger.name):
        asyncio.run(processor.retry_stuck_sessions_on_startup())

    assert stage.runs == []
    lines = _sweep_lines(caplog)
    assert len(lines) == 1
    assert session_id in lines[0].getMessage()
    assert "not retryable" in lines[0].getMessage()
    assert lines[0].exc_info is None


def test_sweep_logs_one_line_without_traceback_when_the_manifest_is_missing(monkeypatch, tmp_path, caplog):
    processor = fresh_processor(monkeypatch)
    monkeypatch.setenv("DATA_DIR", str(tmp_path))
    session_id = "sess-no-manifest"
    FakeSessionIngests(
        session_id, "done", [segment_row("s01", "pending_analysis", 51, "analysis_pending: boom")]
    ).install(monkeypatch)
    stub_transcripts(monkeypatch, [51])
    NarrativeStage(monkeypatch)

    with caplog.at_level(logging.INFO, logger=session_processing.logger.name):
        asyncio.run(processor.retry_stuck_sessions_on_startup())

    lines = _sweep_lines(caplog)
    assert len(lines) == 1
    assert session_id in lines[0].getMessage()
    assert "not retryable" in lines[0].getMessage()
    assert lines[0].exc_info is None


def test_sweep_never_raises_when_listing_the_stuck_sessions_fails(monkeypatch):
    processor = fresh_processor(monkeypatch)

    async def list_pending_analysis_session_ids():
        raise RuntimeError("db unreachable")

    monkeypatch.setattr(db, "list_pending_analysis_session_ids", list_pending_analysis_session_ids)

    asyncio.run(processor.retry_stuck_sessions_on_startup())
