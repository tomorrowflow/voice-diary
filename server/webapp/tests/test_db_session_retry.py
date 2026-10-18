"""Tests for `db.list_pending_analysis_session_ids` (#52).

Backs the startup retry sweep: it needs to find every session with at
least one `pending_analysis` segment. The filter happens in Python over
the persisted `segments` blob.
"""

from __future__ import annotations

import json
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

import asyncio

import db


class _FakePool:
    def __init__(self, rows):
        self._rows = rows
        self.queries: list[str] = []

    async def fetch(self, query, *args):
        self.queries.append(query)
        return self._rows


def test_list_pending_analysis_session_ids_filters_by_segment_status(monkeypatch):
    rows = [
        {
            "session_id": "sess-partial",
            "segments": json.dumps(
                [
                    {"segment_id": "s01", "status": "processed", "transcript_id": 1, "error": None},
                    {"segment_id": "s02", "status": "pending_analysis", "transcript_id": 2, "error": "boom"},
                ]
            ),
        },
        {
            "session_id": "sess-all-failed",
            "segments": json.dumps(
                [{"segment_id": "s01", "status": "failed", "transcript_id": None, "error": "whisper down"}]
            ),
        },
    ]

    async def fake_get_pool():
        return _FakePool(rows)

    monkeypatch.setattr(db, "get_pool", fake_get_pool)

    result = asyncio.run(db.list_pending_analysis_session_ids())

    assert result == ["sess-partial"]


def test_list_pending_analysis_session_ids_excludes_done_sessions(monkeypatch):
    """BUG-114/#114: `done` means every segment is `processed`, so a `done` row
    is never a sweep candidate — even a legacy one that still has a
    `pending_analysis` segment (`correct_legacy_done_sessions` fixes those
    first). A session whose analysis failed is `partial`."""
    pending = json.dumps(
        [{"segment_id": "s01", "status": "pending_analysis", "transcript_id": 3, "error": "boom"}]
    )
    rows = [
        {"session_id": "sess-analysis-failed", "state": "partial", "segments": pending},
        {"session_id": "sess-legacy-done", "state": "done", "segments": pending},
    ]

    async def fake_get_pool():
        return _FakePool(rows)

    monkeypatch.setattr(db, "get_pool", fake_get_pool)

    assert asyncio.run(db.list_pending_analysis_session_ids()) == ["sess-analysis-failed"]


def test_correct_legacy_done_sessions_marks_done_rows_with_pending_segments_partial(monkeypatch):
    """BUG-114/#114: one idempotent UPDATE; it only matches `done` rows with a
    `pending_analysis` segment, so after the first run it matches nothing."""
    executed: list[tuple] = []

    class _Pool:
        async def execute(self, query, *args):
            executed.append((query, args))
            return "UPDATE 2"

    async def fake_get_pool():
        return _Pool()

    monkeypatch.setattr(db, "get_pool", fake_get_pool)

    assert asyncio.run(db.correct_legacy_done_sessions()) == 2

    query, args = executed[0]
    assert "UPDATE session_ingests" in query
    assert "SET state = 'partial'" in query
    assert "state = 'done'" in query
    assert "pending_analysis" in query
    assert args == ()


def test_list_pending_analysis_session_ids_includes_processing_sessions(monkeypatch):
    """BUG-53/#53: a session still `processing` in the table was left behind by
    a prior process (the sweep skips ones active in this process), so it is a
    sweep candidate even when no segment is `pending_analysis` yet."""
    rows = [
        {
            "session_id": "sess-interrupted",
            "state": "processing",
            "segments": json.dumps(
                [{"segment_id": "s01", "status": "pending_analysis", "transcript_id": None, "error": None}]
            ),
        },
        {
            "session_id": "sess-processing-nothing-pending",
            "state": "processing",
            "segments": json.dumps(
                [{"segment_id": "s01", "status": "failed", "transcript_id": None, "error": "boom"}]
            ),
        },
        {
            "session_id": "sess-done",
            "state": "done",
            "segments": json.dumps(
                [{"segment_id": "s01", "status": "processed", "transcript_id": 1, "error": None}]
            ),
        },
    ]

    async def fake_get_pool():
        return _FakePool(rows)

    monkeypatch.setattr(db, "get_pool", fake_get_pool)

    result = asyncio.run(db.list_pending_analysis_session_ids())

    assert result == ["sess-interrupted", "sess-processing-nothing-pending"]


def test_failed_retry_status_stays_persisted_and_swept_as_pending_analysis(monkeypatch):
    """BUG-56/#56: a retry that fails again persists the segments as
    `pending_analysis` with an `analysis_pending: …` error to `session_ingests`
    — and the startup sweep's query must keep finding that session."""
    segments = [
        {
            "segment_id": "s01",
            "status": "pending_analysis",
            "transcript_id": 3,
            "error": "analysis_pending: lightrag unreachable",
        }
    ]
    executed: list[tuple] = []

    class _Pool(_FakePool):
        async def execute(self, query, *args):
            executed.append((query, args))

    pool = _Pool(
        [{"session_id": "sess-retry-failed", "state": "partial", "segments": json.dumps(segments)}]
    )

    async def fake_get_pool():
        return pool

    monkeypatch.setattr(db, "get_pool", fake_get_pool)

    asyncio.run(db.update_session_status("sess-retry-failed", "partial", segments))

    query, args = executed[0]
    assert "UPDATE session_ingests" in query
    assert args[0] == "sess-retry-failed"
    assert args[1] == "partial"
    assert json.loads(args[2]) == segments
    assert asyncio.run(db.list_pending_analysis_session_ids()) == ["sess-retry-failed"]
