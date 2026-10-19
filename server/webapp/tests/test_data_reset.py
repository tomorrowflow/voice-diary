"""MIG-115/#115: the admin "Reset All Data" action also clears iOS session state.

Before the fix it emptied the transcript tables but left `session_ingests`
rows, the bundles under `data/sessions/` and the in-memory status cache. The
startup sweep then tripped over rows whose transcripts were gone, and
re-uploading a session id answered 409 because its bundle directory was still
on disk.

The reset runs through the real `main.app` routes with `db`, `transcript_ingest`,
`correction` and `narrative` stubbed (`session_helpers`); no live Postgres.
"""

from __future__ import annotations

import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

import asyncio

from fastapi.testclient import TestClient

import db
import main
import session_processing
from tests.session_helpers import (
    FakeSessionIngests,
    NarrativeStage,
    SegmentPipeline,
    auth,
    bundle,
    fresh_processor,
    segment_row,
)


class _RecordingPool:
    def __init__(self) -> None:
        self.executed: list[str] = []

    async def execute(self, query, *args):
        self.executed.append(" ".join(query.split()))


def test_reset_all_data_deletes_the_session_ingests_rows(monkeypatch):
    pool = _RecordingPool()

    async def fake_get_pool():
        return pool

    monkeypatch.setattr(db, "get_pool", fake_get_pool)

    asyncio.run(db.reset_all_data())

    assert "DELETE FROM session_ingests" in pool.executed


def test_reset_clears_session_rows_bundles_and_cache_so_the_session_id_can_be_reposted(
    monkeypatch, tmp_path
):
    monkeypatch.setenv("DATA_DIR", str(tmp_path))
    fresh_processor(monkeypatch)
    ingests = FakeSessionIngests.empty("sess-reset").install(monkeypatch)
    SegmentPipeline(monkeypatch, transcript_ids={"s01": 7})
    NarrativeStage(monkeypatch)
    client = TestClient(main.app)

    first = client.post("/api/sessions", files=bundle("sess-reset"), headers=auth())
    assert first.status_code == 200
    assert client.get("/api/sessions/sess-reset/status", headers=auth()).status_code == 200
    assert ingests.rows
    assert session_processing.session_dir_for("sess-reset").exists()
    # A stray file next to the bundles goes too.
    (session_processing.sessions_dir() / "stray.txt").write_text("x")

    resp = client.post("/api/data/reset", headers=auth())

    assert resp.status_code == 200
    assert resp.json() == {"status": "ok"}
    assert ingests.rows == {}
    sessions_root = session_processing.sessions_dir()
    assert sessions_root.is_dir()
    assert list(sessions_root.iterdir()) == []
    status = client.get("/api/sessions/sess-reset/status", headers=auth())
    assert status.status_code == 404
    assert status.json()["detail"] == "session_not_found"

    # The session id is free again. (The upload route answers 200, not 409.)
    again = client.post("/api/sessions", files=bundle("sess-reset"), headers=auth())
    assert again.status_code == 200
    assert again.json()["session_id"] == "sess-reset"


def test_reset_clears_the_status_cache_even_when_the_row_is_already_gone(monkeypatch, tmp_path):
    """The cache is its own layer: a cached status must not outlive the reset."""
    monkeypatch.setenv("DATA_DIR", str(tmp_path))
    processor = fresh_processor(monkeypatch)
    FakeSessionIngests("sess-cached", "done", [segment_row("s01", "processed", 3)]).install(
        monkeypatch
    )
    client = TestClient(main.app)
    assert client.get("/api/sessions/sess-cached/status", headers=auth()).status_code == 200
    assert "sess-cached" in processor._status

    assert client.post("/api/data/reset", headers=auth()).status_code == 200

    assert processor._status == {}
    assert client.get("/api/sessions/sess-cached/status", headers=auth()).status_code == 404


def test_reset_works_when_there_is_no_sessions_directory(monkeypatch, tmp_path):
    monkeypatch.setenv("DATA_DIR", str(tmp_path / "missing"))
    fresh_processor(monkeypatch)
    FakeSessionIngests.empty("sess-none").install(monkeypatch)

    resp = TestClient(main.app).post("/api/data/reset", headers=auth())

    assert resp.status_code == 200


def test_reset_requires_the_bearer_token(monkeypatch, tmp_path):
    monkeypatch.setenv("DATA_DIR", str(tmp_path))
    fresh_processor(monkeypatch)

    resp = TestClient(main.app).post("/api/data/reset")

    assert resp.status_code == 401
