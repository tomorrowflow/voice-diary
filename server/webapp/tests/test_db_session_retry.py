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


def test_list_pending_analysis_session_ids_includes_sessions_persisted_as_done(monkeypatch):
    """`_derive_session_state` only counts `failed` segments, so a session
    whose analysis failed is persisted as `done` with every segment still
    `pending_analysis` — the most common stuck case. The query must not
    exclude it by filtering on `state`."""
    pool = _FakePool(
        [
            {
                "session_id": "sess-analysis-failed",
                "segments": json.dumps(
                    [{"segment_id": "s01", "status": "pending_analysis", "transcript_id": 3, "error": "boom"}]
                ),
            }
        ]
    )

    async def fake_get_pool():
        return pool

    monkeypatch.setattr(db, "get_pool", fake_get_pool)

    result = asyncio.run(db.list_pending_analysis_session_ids())

    assert result == ["sess-analysis-failed"]
    assert "state" not in pool.queries[0]
