"""Tests for the day narrative (FTR-01, ADR 0006): every narrative writer —
original ingest, `retry-analysis`, the startup sweep and the review UI's manual
ingest — works on the whole date, across sessions, one writer per date at a
time.

Driven through `SessionIngest`'s public interface (and the manual-ingest
route) with the shared fakes from `session_helpers`: the segment pipeline, the
narrative stage and the in-memory session repository. Run inside the webapp
container, see DEVELOPMENT.md §7.4.
"""

from __future__ import annotations

import asyncio
import copy
import json
import logging
import os
import sys
from datetime import datetime, timezone

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

import httpx
import pytest

import db
import main
import session_ingest
from tests.session_helpers import (
    BEARER,
    FakeSessionIngests,
    NarrativeStage,
    SegmentPipeline,
    auth,
    fresh_ingest,
    manifest_dict,
    segment_row,
    stage_bundle,
    stub_transcripts,
)

DAY = "2026-07-01"
MORNING = "2026-07-01T09:00:00+02:00"
EVENING = "2026-07-01T18:00:00+02:00"
NIGHT = "2026-07-01T21:00:00+02:00"
PENDING = "analysis_pending: first failure"


def _manifest(session_id: str, segments: list[tuple[str, str]], *, date: str = DAY, todos=()) -> dict:
    """A manifest of drive-by segments `(segment_id, "HH:MM")`; `todos` are
    `(source_segment_id, text)` implicit-confirmed todos."""
    manifest = manifest_dict(session_id)
    manifest["date"] = date
    manifest["segments"] = [
        {
            "segment_id": segment_id,
            "segment_type": "drive_by",
            "audio_file": f"segments/{segment_id}.m4a",
            # The segment header reads the time from this text.
            "captured_at": f"{date} {hhmm}:00",
        }
        for segment_id, hhmm in segments
    ]
    manifest["todos_implicit_confirmed"] = [
        {"text": text, "type": "implicit", "source_segment_id": segment_id}
        for segment_id, text in todos
    ]
    return manifest


def _stage_sessions(monkeypatch, tmp_path, sessions: dict) -> FakeSessionIngests:
    """Persisted sessions `session_id -> (manifest or None, state, rows)`
    installed into the session ingest `fresh_ingest` made; a manifest of `None`
    leaves the bundle off the disk. Every transcript named by a row exists."""
    ingests = FakeSessionIngests.empty(next(iter(sessions)))
    transcript_ids: list[int] = []
    for session_id, (manifest, state, rows) in sessions.items():
        if manifest is not None:
            stage_bundle(monkeypatch, tmp_path, session_id, manifest)
        ingests.add(session_id, state, rows)
        transcript_ids += [row["transcript_id"] for row in rows if row["transcript_id"] is not None]
    ingests.install()
    stub_transcripts(monkeypatch, transcript_ids)
    return ingests


def _segments(ingests: FakeSessionIngests, session_id: str) -> dict[str, str]:
    return {row["segment_id"]: row["status"] for row in ingests.rows[session_id]["segments"]}


def _morning_session(rows=None, *, state="partial") -> tuple:
    """Two segments, 10:00 and 11:00, with a todo on the first."""
    manifest = _manifest(MORNING, [("s01", "10:00"), ("s02", "11:00")], todos=[("s01", "Anna anrufen")])
    return manifest, state, rows or [segment_row("s01", "processed", 5), segment_row("s02", "processed", 6)]


# --- whole day for every writer -------------------------------------------


def test_a_session_recorded_after_another_narrates_both_in_start_then_manifest_order(monkeypatch, tmp_path):
    processor = fresh_ingest(monkeypatch)
    # The morning session is persisted last on purpose: start order, not
    # storage order, decides.
    ingests = _stage_sessions(monkeypatch, tmp_path, {
        "2026-07-02T08:00:00+02:00": (
            _manifest("2026-07-02T08:00:00+02:00", [("s01", "08:00")], date="2026-07-02"),
            "done", [segment_row("s01", "processed", 9)],
        ),
        MORNING: _morning_session(state="done"),
    })
    parsed, session_dir = stage_bundle(
        monkeypatch, tmp_path, EVENING, _manifest(EVENING, [("s01", "19:00")], todos=[("s01", "Bericht senden")])
    )
    SegmentPipeline(monkeypatch, transcript_ids={"s01": 7})
    stage = NarrativeStage(monkeypatch)

    async def scenario():
        await processor.accept(parsed, session_dir)
        await processor.process(parsed, session_dir)

    asyncio.run(scenario())

    assert len(stage.runs) == 1
    assert stage.runs[0]["date"] == DAY
    assert stage.runs[0]["text"] == (
        "## Notiz unterwegs um 10:00\n\ntext-5\n\n"
        "## Notiz unterwegs um 11:00\n\ntext-6\n\n"
        "## Notiz unterwegs um 19:00\n\nhallo welt"
    )
    # Each session's own todos, though both sessions call their segment "s01".
    expected_todos = (
        "# narrative\n\n## Offene Punkte\n"
        "- Anna anrufen — Status: Offen\n- Bericht senden — Status: Offen\n"
    )
    assert {tid: doc["document_markdown"] for tid, doc in stage.documents.items()} == {
        5: expected_todos, 6: expected_todos, 7: expected_todos,
    }
    assert _segments(ingests, EVENING) == {"s01": "processed"}


def test_start_order_follows_the_session_start_timestamp_across_utc_offsets(monkeypatch, tmp_path):
    processor = fresh_ingest(monkeypatch)
    # 10:00+02:00 is 08:00 UTC, before 09:00+00:00, though it sorts after it as text.
    early, late = "2026-07-01T10:00:00+02:00", "2026-07-01T09:00:00+00:00"
    _stage_sessions(monkeypatch, tmp_path, {
        late: (_manifest(late, [("s01", "09:00")]), "partial", [segment_row("s01", "pending_analysis", 6, PENDING)]),
        early: (_manifest(early, [("s01", "10:00")]), "done", [segment_row("s01", "processed", 5)]),
    })
    stage = NarrativeStage(monkeypatch)

    asyncio.run(processor.retry(late))

    assert stage.runs[0]["text"].index("text-5") < stage.runs[0]["text"].index("text-6")


@pytest.mark.parametrize("writer", ["retry", "sweep"])
def test_retry_and_sweep_narrate_the_processed_segments_and_other_sessions_too(monkeypatch, tmp_path, writer):
    processor = fresh_ingest(monkeypatch)
    ingests = _stage_sessions(monkeypatch, tmp_path, {
        MORNING: _morning_session([
            segment_row("s01", "processed", 5),
            segment_row("s02", "pending_analysis", 6, PENDING),
        ]),
        EVENING: (_manifest(EVENING, [("s01", "19:00")]), "done", [segment_row("s01", "processed", 7)]),
    })
    stage = NarrativeStage(monkeypatch)

    if writer == "retry":
        asyncio.run(processor.retry(MORNING))
    else:
        asyncio.run(processor.sweep())

    assert len(stage.runs) == 1
    text = stage.runs[0]["text"]
    assert [text.index(f"text-{tid}") for tid in (5, 6, 7)] == sorted(text.index(f"text-{tid}") for tid in (5, 6, 7))
    assert _segments(ingests, MORNING) == {"s01": "processed", "s02": "processed"}
    assert ingests.rows[MORNING]["state"] == "done"


def test_retry_changes_only_its_own_sessions_segments(monkeypatch, tmp_path):
    processor = fresh_ingest(monkeypatch)
    other_rows = [segment_row("s01", "pending_analysis", 7, PENDING)]
    ingests = _stage_sessions(monkeypatch, tmp_path, {
        MORNING: _morning_session([
            segment_row("s01", "processed", 5),
            segment_row("s02", "pending_analysis", 6, PENDING),
        ]),
        EVENING: (_manifest(EVENING, [("s01", "19:00")]), "partial", copy.deepcopy(other_rows)),
    })
    stage = NarrativeStage(monkeypatch)

    asyncio.run(processor.retry(MORNING))

    assert "text-7" in stage.runs[0]["text"]
    assert ingests.rows[EVENING] == {
        "session_id": EVENING, "received_at": "2026-07-01T10:00:00Z", "state": "partial",
        "segments": other_rows,
    }


def test_a_session_of_another_date_is_not_part_of_the_day(monkeypatch, tmp_path):
    processor = fresh_ingest(monkeypatch)
    _stage_sessions(monkeypatch, tmp_path, {
        MORNING: _morning_session([segment_row("s01", "pending_analysis", 5, PENDING)]),
        "2026-07-02T08:00:00+02:00": (
            _manifest("2026-07-02T08:00:00+02:00", [("s01", "08:00")], date="2026-07-02"),
            "done", [segment_row("s01", "processed", 9)],
        ),
    })
    stage = NarrativeStage(monkeypatch)

    asyncio.run(processor.retry(MORNING))

    assert "text-9" not in stage.runs[0]["text"]


def test_failed_segments_add_nothing_to_the_day(monkeypatch, tmp_path):
    processor = fresh_ingest(monkeypatch)
    _stage_sessions(monkeypatch, tmp_path, {
        MORNING: _morning_session([
            segment_row("s01", "failed", None, "whisper down", "whisper_unavailable", "whisper"),
            segment_row("s02", "pending_analysis", 6, PENDING),
        ]),
    })
    stage = NarrativeStage(monkeypatch)

    asyncio.run(processor.retry(MORNING))

    assert stage.runs[0]["text"] == "## Notiz unterwegs um 11:00\n\ntext-6"


# --- sessions whose manifest cannot be read -------------------------------


@pytest.mark.parametrize("damage", ["missing", "corrupt"])
def test_a_session_without_a_readable_manifest_is_skipped_with_one_log_line(
    monkeypatch, tmp_path, caplog, damage
):
    processor = fresh_ingest(monkeypatch)
    ingests = _stage_sessions(monkeypatch, tmp_path, {
        MORNING: _morning_session([segment_row("s01", "pending_analysis", 5, PENDING)]),
        EVENING: (
            _manifest(EVENING, [("s01", "19:00")]) if damage == "corrupt" else None,
            "done", [segment_row("s01", "processed", 7)],
        ),
    })
    if damage == "corrupt":
        (session_ingest.session_dir_for(EVENING) / "manifest.json").write_text("{not json")
    stage = NarrativeStage(monkeypatch)

    with caplog.at_level(logging.INFO, logger=session_ingest.logger.name):
        result = asyncio.run(processor.retry(MORNING))

    assert result.segments[0].status == "processed"
    assert stage.runs[0]["text"] == "## Notiz unterwegs um 10:00\n\ntext-5"
    lines = [r for r in caplog.records if EVENING in r.getMessage()]
    assert len(lines) == 1
    assert lines[0].levelno == logging.WARNING and lines[0].exc_info is None
    assert ingests.rows[EVENING]["segments"] == [segment_row("s01", "processed", 7)]


# --- one writer per date --------------------------------------------------


def test_writers_for_one_date_run_one_at_a_time_and_the_later_gathers_after_the_earlier(monkeypatch, tmp_path):
    processor = fresh_ingest(monkeypatch)
    ingests = _stage_sessions(monkeypatch, tmp_path, {
        MORNING: _morning_session([segment_row("s01", "pending_analysis", 5, PENDING)]),
        EVENING: (_manifest(EVENING, [("s01", "19:00")]), "partial", [segment_row("s01", "pending_analysis", 7, PENDING)]),
        NIGHT: (_manifest(NIGHT, [("s01", "22:00")]), "done", []),
    })
    stage = NarrativeStage(monkeypatch)
    stub_transcripts(monkeypatch, [5, 7, 8])

    async def scenario():
        started, release = stage.latch()
        first = asyncio.create_task(processor.retry(MORNING))
        await asyncio.wait_for(started.wait(), 1)
        second =asyncio.create_task(processor.retry(EVENING))
        await asyncio.sleep(0.05)
        assert len(stage.runs) == 1, "the second writer must wait for the date"
        # Content the first writer's run stores while it holds the date.
        ingests.rows[NIGHT]["segments"] = [segment_row("s01", "processed", 8)]
        release.set()
        await asyncio.gather(first, second)

    asyncio.run(scenario())

    assert len(stage.runs) == 2
    assert "text-8" not in stage.runs[0]["text"]
    assert all(f"text-{tid}" in stage.runs[1]["text"] for tid in (5, 7, 8))


def test_writers_for_different_dates_do_not_wait_for_each_other(monkeypatch, tmp_path):
    processor = fresh_ingest(monkeypatch)
    _stage_sessions(monkeypatch, tmp_path, {
        MORNING: _morning_session([segment_row("s01", "pending_analysis", 5, PENDING)]),
        "2026-07-02T08:00:00+02:00": (
            _manifest("2026-07-02T08:00:00+02:00", [("s01", "08:00")], date="2026-07-02"),
            "partial", [segment_row("s01", "pending_analysis", 9, PENDING)],
        ),
    })
    stage = NarrativeStage(monkeypatch)

    async def scenario():
        both_running = asyncio.Barrier(2)

        async def before_analysis(run):
            await asyncio.wait_for(both_running.wait(), 1)

        stage.before_analysis = before_analysis
        return await asyncio.gather(
            processor.retry(MORNING), processor.retry("2026-07-02T08:00:00+02:00")
        )

    results = asyncio.run(scenario())

    assert [r.segments[0].status for r in results] == ["processed", "processed"]


def test_an_upload_and_a_transcription_proceed_while_a_narrative_stage_holds_the_date(monkeypatch, tmp_path):
    processor = fresh_ingest(monkeypatch)
    ingests = _stage_sessions(monkeypatch, tmp_path, {
        MORNING: _morning_session([segment_row("s01", "pending_analysis", 5, PENDING)]),
    })
    parsed, session_dir = stage_bundle(monkeypatch, tmp_path, EVENING, _manifest(EVENING, [("s01", "19:00")]))
    pipeline = SegmentPipeline(monkeypatch, transcript_ids={"s01": 7})
    stage = NarrativeStage(monkeypatch)

    async def scenario():
        persisted = asyncio.Event()
        write_row = ingests.repository._update

        async def update(session_id, state, segments):
            await write_row(session_id, state, segments)
            if session_id == EVENING and segments[0]["transcript_id"] == 7:
                persisted.set()

        ingests.repository._update = update
        started, release = stage.latch()
        holder = asyncio.create_task(processor.retry(MORNING))
        await asyncio.wait_for(started.wait(), 1)

        async with processor.upload_gate():
            await asyncio.wait_for(processor.accept(parsed, session_dir), 1)
        ingest = asyncio.create_task(processor.process(parsed, session_dir))
        await asyncio.wait_for(persisted.wait(), 1)
        transcribed_meanwhile = len(pipeline.transcribe_calls)
        narrated_meanwhile = len(stage.runs)
        persisted_meanwhile = (await processor.status(EVENING)).segments[0].transcript_id

        release.set()
        await asyncio.gather(holder, ingest)
        return transcribed_meanwhile, narrated_meanwhile, persisted_meanwhile

    transcribed, narrated, persisted = asyncio.run(scenario())

    assert (transcribed, narrated, persisted) == (1, 1, 7)
    assert len(stage.runs) == 2
    assert "text-5" in stage.runs[1]["text"] and "hallo welt" in stage.runs[1]["text"]
    assert _segments(ingests, EVENING) == {"s01": "processed"}


# --- publication ----------------------------------------------------------


@pytest.mark.parametrize("writer", ["retry", "sweep"])
def test_a_failed_publication_stays_saved_and_is_republished_without_new_analysis(
    monkeypatch, tmp_path, writer
):
    processor = fresh_ingest(monkeypatch)
    ingests = _stage_sessions(monkeypatch, tmp_path, {
        MORNING: _morning_session(state="done"),
    })
    parsed, session_dir = stage_bundle(monkeypatch, tmp_path, EVENING, _manifest(EVENING, [("s01", "19:00")]))
    SegmentPipeline(monkeypatch, transcript_ids={"s01": 7})
    stage = NarrativeStage(monkeypatch)
    stub_transcripts(monkeypatch, [5, 6, 7])
    stage.ingest_error = RuntimeError("lightrag down")

    async def original_ingest():
        await processor.accept(parsed, session_dir)
        await processor.process(parsed, session_dir)

    asyncio.run(original_ingest())

    # Saved against every transcript of the day, published nowhere.
    assert sorted(stage.documents) == [5, 6, 7]
    assert not any(doc["lightrag_ingested"] for doc in stage.documents.values())
    assert stage.ingested == [] and stage.marked == []
    assert _segments(ingests, EVENING) == {"s01": "pending_analysis"}
    assert ingests.rows[EVENING]["segments"][0]["error"] == "analysis_pending: lightrag down"
    assert _segments(ingests, MORNING) == {"s01": "processed", "s02": "processed"}

    stage.ingest_error = None
    if writer == "retry":
        asyncio.run(processor.retry(EVENING))
    else:
        asyncio.run(processor.sweep())

    assert len(stage.runs) == 1, "republishing must not run the analysis again"
    assert len(stage.ingested) == 1, "the day ends with one document"
    assert stage.ingested[0][0] == stage.documents[7]["document_markdown"]
    assert stage.ingested[0][1]["date"] == DAY
    assert sorted(stage.marked) == [105, 106, 107]
    assert _segments(ingests, EVENING) == {"s01": "processed"}
    assert ingests.rows[EVENING]["state"] == "done"


def test_a_new_transcript_in_the_day_is_analysed_not_just_republished(monkeypatch, tmp_path):
    processor = fresh_ingest(monkeypatch)
    _stage_sessions(monkeypatch, tmp_path, {
        MORNING: _morning_session([segment_row("s01", "pending_analysis", 5, PENDING)]),
        EVENING: (_manifest(EVENING, [("s01", "19:00")]), "partial", [segment_row("s01", "pending_analysis", 7, PENDING)]),
    })
    stage = NarrativeStage(monkeypatch)
    # The saved narrative covers the morning only: the evening is new content.
    stage.save_document(5, "# morning only", {"date": DAY})

    asyncio.run(processor.retry(MORNING))

    assert len(stage.runs) == 1
    assert "text-7" in stage.runs[0]["text"]
    assert [markdown.split("\n")[0] for markdown, _ in stage.ingested] == ["# narrative"]


# --- review UI's manual ingest --------------------------------------------


class _SavedDocuments:
    """`processed_documents` as the review UI's manual ingest sees them:
    document `DD` is saved for transcript `DD` and date `2026-07-DD`, with the
    text `# manual 2026-07-DD` unless `markdown[DD]` says otherwise. It is the
    latest version of its transcript unless `latest[DD]` names a newer one."""

    def __init__(self, monkeypatch, stage: NarrativeStage):
        self.markdown: dict[int, str] = {}
        self.latest: dict[int, int] = {}
        self.ingested: set[int] = set()  # documents asked for so far

        async def get_processed_document(doc_id: int) -> dict:
            day = f"2026-07-{doc_id:02d}"
            return {
                "id": doc_id, "transcript_id": doc_id,
                "document_markdown": self.markdown.get(doc_id, f"# manual {day}"),
                # asyncpg hands jsonb columns back as text.
                "metadata": json.dumps({"date": day}),
            }

        narrative_stage_documents = db.get_latest_processed_document

        async def get_latest_processed_document(transcript_id: int) -> dict | None:
            if transcript_id not in self.ingested:  # a session writer's transcript
                return await narrative_stage_documents(transcript_id)
            return {"id": self.latest.get(transcript_id, transcript_id)}

        async def mark_document_ingested(doc_id: int) -> dict:
            stage.marked.append(doc_id)
            return {"id": doc_id, "lightrag_ingested_at": datetime(2026, 7, 1, tzinfo=timezone.utc)}

        monkeypatch.setattr(db, "get_processed_document", get_processed_document)
        monkeypatch.setattr(db, "get_latest_processed_document", get_latest_processed_document)
        monkeypatch.setattr(db, "mark_document_ingested", mark_document_ingested)

    async def ingest(self, doc_id: int) -> httpx.Response:
        """`POST /api/documents/{doc_id}/ingest` over `main.app`."""
        self.ingested.add(doc_id)
        async with httpx.AsyncClient(
            transport=httpx.ASGITransport(app=main.app), base_url="http://test"
        ) as client:
            return await client.post(f"/api/documents/{doc_id}/ingest", headers=auth())


def test_the_manual_ingest_waits_for_a_narrative_writer_holding_its_date(monkeypatch, tmp_path):
    processor = fresh_ingest(monkeypatch)
    _stage_sessions(monkeypatch, tmp_path, {
        MORNING: _morning_session([segment_row("s01", "pending_analysis", 5, PENDING)]),
    })
    stage = NarrativeStage(monkeypatch)
    documents = _SavedDocuments(monkeypatch, stage)

    async def scenario():
        started, release = stage.latch()
        writer = asyncio.create_task(processor.retry(MORNING))
        await asyncio.wait_for(started.wait(), 1)
        manual = asyncio.create_task(documents.ingest(1))
        other_date = await asyncio.wait_for(documents.ingest(2), 1)
        await asyncio.sleep(0.05)
        waiting = not manual.done()
        release.set()
        await writer
        return waiting, other_date, await manual

    waiting, other_date, same_date = asyncio.run(scenario())

    assert waiting, "the manual ingest must wait for the date"
    assert other_date.status_code == 200 and same_date.status_code == 200
    assert [markdown.split("\n")[0] for markdown, _ in stage.ingested] == [
        "# manual 2026-07-02", "# narrative", f"# manual {DAY}",
    ]
    assert stage.ingested[0][1] == {"date": "2026-07-02"}


def test_the_manual_ingest_sends_the_document_as_saved_once_it_holds_the_date(monkeypatch, tmp_path):
    processor = fresh_ingest(monkeypatch)
    _stage_sessions(monkeypatch, tmp_path, {
        MORNING: _morning_session([segment_row("s01", "pending_analysis", 5, PENDING)]),
    })
    stage = NarrativeStage(monkeypatch)
    documents = _SavedDocuments(monkeypatch, stage)
    documents.markdown[1] = "# before the wait"

    async def scenario():
        started, release = stage.latch()
        writer = asyncio.create_task(processor.retry(MORNING))
        await asyncio.wait_for(started.wait(), 1)
        manual = asyncio.create_task(documents.ingest(1))
        await asyncio.sleep(0.05)
        documents.markdown[1] = "# edited while waiting"
        release.set()
        await writer
        return await manual

    response = asyncio.run(scenario())

    assert response.status_code == 200
    assert stage.ingested[-1][0] == "# edited while waiting"


def test_the_manual_ingest_refuses_a_document_a_writer_superseded_while_it_waited(monkeypatch, tmp_path):
    """The writer that held the date saved a newer version for the transcript
    (the day narrative, published). Sending the older document afterwards would
    replace `diary:{date}` with stale text."""
    processor = fresh_ingest(monkeypatch)
    _stage_sessions(monkeypatch, tmp_path, {
        MORNING: _morning_session([segment_row("s01", "pending_analysis", 5, PENDING)]),
    })
    stage = NarrativeStage(monkeypatch)
    documents = _SavedDocuments(monkeypatch, stage)

    async def scenario():
        started, release = stage.latch()
        writer = asyncio.create_task(processor.retry(MORNING))
        await asyncio.wait_for(started.wait(), 1)
        manual = asyncio.create_task(documents.ingest(1))
        await asyncio.sleep(0.05)
        documents.latest[1] = 101  # the day narrative's version of transcript 1
        release.set()
        await writer
        return await manual

    response = asyncio.run(scenario())

    assert response.status_code == 409
    assert response.json() == {"status": "error", "message": "Document is outdated: a newer version exists"}
    assert [markdown.split("\n")[0] for markdown, _ in stage.ingested] == ["# narrative"]
    assert stage.marked == [105]


def test_the_manual_ingest_reports_a_failed_publication_and_releases_the_date(monkeypatch, tmp_path):
    processor = fresh_ingest(monkeypatch)
    _stage_sessions(monkeypatch, tmp_path, {
        MORNING: _morning_session([segment_row("s01", "pending_analysis", 5, PENDING)]),
    })
    stage = NarrativeStage(monkeypatch)
    stage.ingest_error = RuntimeError("lightrag down")
    documents = _SavedDocuments(monkeypatch, stage)

    async def scenario():
        failed = await documents.ingest(1)
        stage.ingest_error = None
        retried = await asyncio.wait_for(processor.retry(MORNING), 1)
        return failed, retried

    failed, retried = asyncio.run(scenario())

    assert failed.status_code == 500
    assert failed.json() == {"status": "error", "message": "lightrag down"}
    assert retried.segments[0].status == "processed"


def test_the_bearer_token_gates_the_manual_ingest(monkeypatch):
    fresh_ingest(monkeypatch)

    async def post() -> httpx.Response:
        async with httpx.AsyncClient(
            transport=httpx.ASGITransport(app=main.app), base_url="http://test"
        ) as client:
            return await client.post("/api/documents/42/ingest", headers={"Authorization": f"Bearer not-{BEARER}"})

    assert asyncio.run(post()).status_code == 401
