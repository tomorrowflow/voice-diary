"""Tests for `db.list_pending_analysis_session_ids` (#52).

Backs the startup retry sweep: it needs to find every session with at
least one `pending_analysis` segment without scanning the whole table in
SQL (jsonb array containment on partially-keyed objects is easy to get
wrong), so the filter happens in Python over the persisted `segments` blob.
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

    async def fetch(self, query, *args):
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
