"""Tests for the segment seam of `SessionIngest` (ARCH-3): each instance runs
the segment operation it was given, for the original ingest and for the resume
of a stored bundle, and persists only the outcomes of that operation.

Two `SessionIngest`s over their own in-memory repositories and their own
`RecordingSegmentOperation` run in one scenario, through `process` and `retry`.
Nothing the segment operation coordinates (`transcript_ingest`, `correction`,
`dictionary`, `db.save_detected_entities`) is replaced: a session that
reached the shared modules instead of its own operation could not transcribe.
The real operation is covered in `test_segment_ingest.py`, and through the
default wiring in `test_session_ingest.py`.
"""

from __future__ import annotations

import asyncio
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from models import Manifest
from tests.session_helpers import (
    FakeSessionIngests,
    NarrativeStage,
    RecordingSegmentOperation,
    fresh_ingest,
    segment_row,
    stage_bundle,
    stub_transcripts,
    two_segment_manifest,
)


def _pending(session_id: str, *rows: dict) -> FakeSessionIngests:
    return FakeSessionIngests(session_id, "processing", list(rows or [
        segment_row("s01", "pending_analysis"), segment_row("s02", "pending_analysis"),
    ]))


def _stage_two(monkeypatch, tmp_path, *session_ids: str) -> list[tuple[Manifest, object]]:
    return [
        stage_bundle(monkeypatch, tmp_path, session_id, two_segment_manifest(session_id))
        for session_id in session_ids
    ]


def test_each_instance_ingests_with_its_own_segment_operation(monkeypatch, tmp_path):
    (parsed_a, dir_a), (parsed_b, dir_b) = _stage_two(monkeypatch, tmp_path, "sess-a", "sess-b")
    rows_a, rows_b = _pending("sess-a"), _pending("sess-b")
    op_a = RecordingSegmentOperation({"s01": 1, "s02": 2})
    op_b = RecordingSegmentOperation({"s02": 7}, failing={"s01": RuntimeError("b-boom")})
    ingest_a = fresh_ingest(monkeypatch, repository=rows_a.repository, segment_operation=op_a)
    ingest_b = fresh_ingest(monkeypatch, repository=rows_b.repository, segment_operation=op_b)
    stage = NarrativeStage(monkeypatch)

    async def scenario():
        await asyncio.gather(
            ingest_a.process(parsed_a, dir_a), ingest_b.process(parsed_b, dir_b)
        )
        return await ingest_a.status("sess-a"), await ingest_b.status("sess-b")

    status_a, status_b = asyncio.run(scenario())

    assert op_a.calls == [("sess-a", "s01"), ("sess-a", "s02")]
    assert op_b.calls == [("sess-b", "s01"), ("sess-b", "s02")]
    assert rows_a.row == {
        **rows_a.row, "state": "done",
        "segments": [segment_row("s01", "processed", 1), segment_row("s02", "processed", 2)],
    }
    assert rows_b.row == {
        **rows_b.row, "state": "partial",
        "segments": [segment_row("s01", "failed", error="b-boom"), segment_row("s02", "processed", 7)],
    }
    assert (status_a.state, status_b.state) == ("done", "partial")
    # Each repository took only its own session's progress, one write per segment
    # and the settled status.
    assert [segments for _, segments in rows_a.updates[:2]] == [
        [segment_row("s01", "pending_analysis", 1), segment_row("s02", "pending_analysis")],
        [segment_row("s01", "pending_analysis", 1), segment_row("s02", "pending_analysis", 2)],
    ]
    assert [segments for _, segments in rows_b.updates[:2]] == [
        [segment_row("s01", "failed", error="b-boom"), segment_row("s02", "pending_analysis")],
        [segment_row("s01", "failed", error="b-boom"), segment_row("s02", "pending_analysis", 7)],
    ]
    assert len(rows_a.updates) == len(rows_b.updates) == 3
    # One narrative per session, over the transcripts its own operation made.
    texts = [run["text"] for run in stage.runs]
    assert len(texts) == 2
    assert sum("text-1" in t and "text-2" in t and "text-7" not in t for t in texts) == 1
    assert sum("text-7" in t and "text-1" not in t and "text-2" not in t for t in texts) == 1
    assert sorted(stage.documents) == [1, 2, 7]


def test_each_instance_resumes_a_stored_bundle_with_its_own_segment_operation(monkeypatch, tmp_path):
    _stage_two(monkeypatch, tmp_path, "sess-a", "sess-b")
    # A has nothing transcribed; B has s01 transcribed (transcript 5) already.
    rows_a = _pending("sess-a")
    rows_b = _pending(
        "sess-b", segment_row("s01", "pending_analysis", 5), segment_row("s02", "pending_analysis")
    )
    op_a = RecordingSegmentOperation({"s01": 31}, failing={"s02": FileNotFoundError("a-gone")})
    op_b = RecordingSegmentOperation({"s02": 41})
    ingest_a = fresh_ingest(monkeypatch, repository=rows_a.repository, segment_operation=op_a)
    ingest_b = fresh_ingest(monkeypatch, repository=rows_b.repository, segment_operation=op_b)
    stub_transcripts(monkeypatch, [5])
    stage = NarrativeStage(monkeypatch)

    async def scenario():
        return await asyncio.gather(ingest_a.retry("sess-a"), ingest_b.retry("sess-b"))

    result_a, result_b = asyncio.run(scenario())

    assert op_a.calls == [("sess-a", "s01"), ("sess-a", "s02")]
    # The transcript B already had is reused: only the untranscribed segment ran.
    assert op_b.calls == [("sess-b", "s02")]
    assert (result_a.state, result_b.state) == ("partial", "done")
    assert rows_a.row["segments"] == [
        segment_row("s01", "processed", 31),
        segment_row("s02", "failed", error="a-gone"),
    ]
    assert rows_b.row["segments"] == [
        segment_row("s01", "processed", 5), segment_row("s02", "processed", 41),
    ]
    # Progress was durable per resumed segment before the narrative settled it.
    assert [segments for _, segments in rows_a.updates[:2]] == [
        [segment_row("s01", "pending_analysis", 31), segment_row("s02", "pending_analysis")],
        [segment_row("s01", "pending_analysis", 31), segment_row("s02", "failed", error="a-gone")],
    ]
    assert [segments for _, segments in rows_b.updates[:1]] == [
        [segment_row("s01", "pending_analysis", 5), segment_row("s02", "pending_analysis", 41)],
    ]
    assert sorted(stage.documents) == [5, 31, 41]
