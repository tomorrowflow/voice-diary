"""Tests for settling interrupted recoveries at startup (FTR-03, ADR 0005 and
0007): a restart in the middle of a transcription recovery leaves the segment
`transcribing`; before the sweep it is settled from what is stored, and nothing
ever asks Whisper again.

Driven through `SessionIngest.sweep` (the startup entry point) and the status
read, with the shared fakes from `session_helpers`: the in-memory repository's
restart (`fresh_ingest(repository=...)`), the segment pipeline whose Whisper
fake records every call, and the narrative stage. Run inside the webapp
container, see DEVELOPMENT.md §7.4.
"""

from __future__ import annotations

import asyncio
import logging
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

import db
import session_ingest
from models import SegmentResult
from tests.session_helpers import fresh_ingest, segment_row, stage_bundle, stub_transcripts
from tests.test_session_recovery import SESSION, World, _failed, _manifest, _pending, _processed

OTHER = "2026-07-01T14:00:00+02:00"


def _transcribing(segment_id: str) -> dict:
    return segment_row(segment_id, "transcribing")


def _save_transcript(
    monkeypatch, world: World, segment_id: str, transcript_id: int, session_id: str = SESSION
) -> None:
    """The row an interrupted recovery's one-statement save had committed,
    with its entities, before the process died."""
    filename = f"{session_id}::{segment_id}.m4a"
    world.pipeline.transcript_rows[filename] = transcript_id
    world.pipeline.recovered_values[filename] = ("hallo welt", "hallo welt", "[]")
    stub_transcripts(monkeypatch, [transcript_id])


def _restart(monkeypatch, world: World) -> session_ingest.SessionIngest:
    """A new process over the rows the old one left."""
    return fresh_ingest(monkeypatch, repository=world.ingests.repository)


def _stored(world: World, session_id: str = SESSION) -> tuple[str, list[SegmentResult]]:
    row = world.ingests.rows[session_id]
    return row["state"], [SegmentResult.model_validate(s) for s in row["segments"]]


def test_a_transcribing_segment_with_a_saved_transcript_becomes_pending_and_the_sweep_completes_it(
    monkeypatch, tmp_path,
):
    world = World(monkeypatch, tmp_path, [_transcribing("s01")], state="processing")
    _save_transcript(monkeypatch, world, "s01", 10)
    restarted = _restart(monkeypatch, world)

    asyncio.run(restarted.sweep())

    state, (segment,) = _stored(world)
    assert (state, segment) == (
        "done", SegmentResult(segment_id="s01", status="processed", transcript_id=10),
    )
    assert world.pipeline.transcribe_calls == []
    assert len(world.narrative.runs) == 1


def test_the_settled_segment_is_pending_analysis_with_its_transcript_when_analysis_fails(
    monkeypatch, tmp_path,
):
    world = World(monkeypatch, tmp_path, [_transcribing("s01")], state="processing")
    _save_transcript(monkeypatch, world, "s01", 10)
    world.narrative.analysis_error = RuntimeError("ollama unreachable")
    restarted = _restart(monkeypatch, world)

    asyncio.run(restarted.sweep())

    state, (segment,) = _stored(world)
    assert (segment.status, segment.transcript_id) == ("pending_analysis", 10)
    assert state == "partial"
    assert world.pipeline.transcribe_calls == []


def test_a_transcribing_segment_without_a_saved_transcript_fails_as_interrupted_and_keeps_its_audio(
    monkeypatch, tmp_path,
):
    world = World(monkeypatch, tmp_path, [_transcribing("s01")], state="processing")
    audio = world.audio("s01").read_bytes()
    restarted = _restart(monkeypatch, world)

    asyncio.run(restarted.sweep())

    state, (segment,) = _stored(world)
    assert state == "failed"
    assert (segment.status, segment.code, segment.upstream, segment.transcript_id) == (
        "failed", "recovery_interrupted", None, None,
    )
    assert segment.error
    assert world.audio("s01").read_bytes() == audio
    assert world.pipeline.transcribe_calls == []
    assert world.narrative.runs == []

    status = asyncio.run(restarted.status(SESSION))
    assert status.segments[0].recoverable is True


def test_a_transcript_row_without_entities_is_not_a_saved_transcript(monkeypatch, tmp_path):
    """The original ingest saves its row first and the entities after: a row
    that an earlier failed ingest left is not what a recovery saved."""
    world = World(monkeypatch, tmp_path, [_transcribing("s01")], state="processing")
    world.pipeline.transcript_rows[f"{SESSION}::s01.m4a"] = 10
    restarted = _restart(monkeypatch, world)

    asyncio.run(restarted.sweep())

    _, (segment,) = _stored(world)
    assert (segment.status, segment.code) == ("failed", "recovery_interrupted")


def test_the_interrupted_segment_waits_for_the_next_tap_and_can_be_recovered(monkeypatch, tmp_path):
    world = World(
        monkeypatch, tmp_path, [_transcribing("s01")], state="processing",
        transcript_ids={"s01": 10},
    )
    restarted = _restart(monkeypatch, world)

    async def run():
        await restarted.sweep()
        assert world.pipeline.transcribe_calls == []
        await restarted.recover(SESSION, "s01")
        await restarted.settled()

    asyncio.run(run())

    _, (segment,) = _stored(world)
    assert segment == SegmentResult(segment_id="s01", status="processed", transcript_id=10)
    assert len(world.pipeline.transcribe_calls) == 1  # the tap, not the restart


def test_settling_is_idempotent_and_never_settles_a_segment_twice(monkeypatch, tmp_path):
    world = World(monkeypatch, tmp_path, [_transcribing("s01")], state="processing")
    restarted = _restart(monkeypatch, world)

    async def run():
        await restarted.sweep()
        first = _stored(world)
        updates = len(world.ingests.updates)
        await restarted.sweep()
        return first, updates

    first, updates = asyncio.run(run())

    assert _stored(world) == first
    assert len(world.ingests.updates) == updates
    assert world.pipeline.transcribe_calls == []


def test_the_session_state_is_re_derived_from_the_other_segments(monkeypatch, tmp_path):
    world = World(
        monkeypatch, tmp_path,
        [_processed("s01", 5), _transcribing("s02"), _failed("s03")],
        state="processing",
    )
    restarted = _restart(monkeypatch, world)

    asyncio.run(restarted.sweep())

    state, segments = _stored(world)
    assert state == "partial"
    assert [s.status for s in segments] == ["processed", "failed", "failed"]
    assert segments[1].code == "recovery_interrupted"
    assert segments[2].code == "whisper_timeout"  # an untouched failed segment keeps its reason
    assert world.pipeline.transcribe_calls == []


def test_a_session_genuinely_processing_for_its_ingest_is_still_resumed_as_before(
    monkeypatch, tmp_path,
):
    """Another session's original ingest the process died in: its segment
    without a transcript is resumed from the stored audio by the sweep, while
    the interrupted recovery is only settled."""
    world = World(
        monkeypatch, tmp_path, [_transcribing("s01")], state="processing",
        transcript_ids={"s01": 11},
    )
    stage_bundle(monkeypatch, tmp_path, OTHER, _manifest(OTHER, ["s01"]))
    world.ingests.add(OTHER, "processing", [segment_row("s01", "pending_analysis")])
    restarted = _restart(monkeypatch, world)

    asyncio.run(restarted.sweep())

    assert [call["filename"] for call in world.pipeline.transcribe_calls] == [f"{OTHER}::s01.m4a"]
    other_state, (other,) = _stored(world, OTHER)
    assert (other_state, other.status, other.transcript_id) == ("done", "processed", 11)
    state, (segment,) = _stored(world)
    assert (state, segment.status, segment.code) == ("failed", "failed", "recovery_interrupted")


def test_the_resume_of_untranscribed_segments_does_not_see_a_recovery_segment(monkeypatch, tmp_path):
    """The crash-orphan resume stays keyed on `pending_analysis` without a
    transcript; a segment the reconciliation settled is never that."""
    world = World(
        monkeypatch, tmp_path, [_transcribing("s01"), _transcribing("s02")], state="processing",
    )
    _save_transcript(monkeypatch, world, "s01", 10)
    restarted = _restart(monkeypatch, world)

    asyncio.run(restarted.sweep())

    assert world.pipeline.transcribe_calls == []
    _, segments = _stored(world)
    assert not any(s.status == "pending_analysis" and s.transcript_id is None for s in segments)
    assert [(s.status, s.code) for s in segments] == [
        ("processed", None), ("failed", "recovery_interrupted"),
    ]


def test_one_sessions_failure_to_settle_is_logged_and_does_not_stop_the_others(
    monkeypatch, tmp_path, caplog,
):
    world = World(monkeypatch, tmp_path, [_transcribing("s01")], state="processing")
    stage_bundle(monkeypatch, tmp_path, OTHER, _manifest(OTHER, ["s01"]))
    world.ingests.add(OTHER, "processing", [_transcribing("s01")])
    working = db.find_recovered_transcript

    async def broken_for_the_first_session(*, filename, date):
        if filename.startswith(SESSION):
            raise ConnectionError("database went away")
        return await working(filename=filename, date=date)

    monkeypatch.setattr(db, "find_recovered_transcript", broken_for_the_first_session)
    restarted = _restart(monkeypatch, world)

    with caplog.at_level(logging.WARNING):
        asyncio.run(restarted.sweep())

    assert world.ingests.rows[SESSION]["segments"][0]["status"] == "transcribing"
    assert world.ingests.rows[OTHER]["segments"][0]["code"] == "recovery_interrupted"
    assert any(SESSION in record.getMessage() for record in caplog.records)
    assert world.pipeline.transcribe_calls == []


def test_a_session_whose_run_is_active_in_this_process_is_left_alone(monkeypatch, tmp_path):
    world = World(monkeypatch, tmp_path, [_transcribing("s01")], state="processing")
    restarted = _restart(monkeypatch, world)

    async def run():
        assert await restarted._try_begin(SESSION)  # a live recovery holds the claim
        await restarted.sweep()

    asyncio.run(run())

    assert world.ingests.rows[SESSION]["segments"][0]["status"] == "transcribing"


def test_sessions_with_nothing_transcribing_are_not_touched(monkeypatch, tmp_path):
    world = World(
        monkeypatch, tmp_path, [_processed("s01", 5), _failed("s02")], state="partial",
    )
    restarted = _restart(monkeypatch, world)
    before = [dict(s) for s in world.ingests.rows[SESSION]["segments"]]

    asyncio.run(restarted.sweep())

    assert world.ingests.rows[SESSION]["segments"] == before
    assert world.ingests.updates == []


def test_a_missing_manifest_settles_as_interrupted(monkeypatch, tmp_path):
    """Without its manifest there is no saved transcript to find and nothing to
    transcribe again: the segment fails as interrupted, and is not
    `recoverable`."""
    world = World(monkeypatch, tmp_path, [_transcribing("s01")], state="processing")
    (world.session_dir / "manifest.json").unlink()
    restarted = _restart(monkeypatch, world)

    asyncio.run(restarted.sweep())

    _, (segment,) = _stored(world)
    assert (segment.status, segment.code) == ("failed", "recovery_interrupted")
    assert asyncio.run(restarted.status(SESSION)).segments[0].recoverable is False


def test_pending_segments_of_other_sessions_with_transcripts_still_get_the_sweep(
    monkeypatch, tmp_path,
):
    world = World(monkeypatch, tmp_path, [_transcribing("s01")], state="processing")
    _save_transcript(monkeypatch, world, "s01", 10)
    stage_bundle(monkeypatch, tmp_path, OTHER, _manifest(OTHER, ["s01"]))
    world.ingests.add(OTHER, "partial", [_pending("s01", 5)])
    stub_transcripts(monkeypatch, [5, 10])
    restarted = _restart(monkeypatch, world)

    asyncio.run(restarted.sweep())

    assert _stored(world)[1][0].status == "processed"
    assert _stored(world, OTHER)[1][0].status == "processed"
    assert world.pipeline.transcribe_calls == []
