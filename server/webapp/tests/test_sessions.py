"""Tests for `routers/sessions.py` session-ingest status persistence (SRV-A6).

Run inside the webapp container so deps + env match prod:

    docker compose run --rm webapp pytest tests/test_sessions.py

No live Postgres is needed: `db` calls are monkeypatched at the module
level, so these exercise the router's caching/fallback logic in isolation.
"""

from __future__ import annotations

import json as jsonlib
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from fastapi import FastAPI
from fastapi.testclient import TestClient

import db
import routers.sessions as sessions_router


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
    from models import SegmentResult

    results = [SegmentResult(segment_id="s01", status="processed", transcript_id=1)]
    assert sessions_router._derive_session_state(results) == "done"


def test_derive_session_state_all_failed_is_failed():
    from models import SegmentResult

    results = [SegmentResult(segment_id="s01", status="failed", error="boom")]
    assert sessions_router._derive_session_state(results) == "failed"


def test_derive_session_state_mixed_is_partial():
    from models import SegmentResult

    results = [
        SegmentResult(segment_id="s01", status="processed", transcript_id=1),
        SegmentResult(segment_id="s02", status="failed", error="boom"),
    ]
    assert sessions_router._derive_session_state(results) == "partial"


def test_persist_session_status_updates_cache_and_writes_through_to_db(monkeypatch):
    from models import SegmentResult, SessionStatus

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
    import asyncio

    asyncio.run(
        sessions_router._persist_session_status("sess-x", "done", new_results)
    )

    assert sessions_router._session_status["sess-x"].state == "done"
    assert sessions_router._session_status["sess-x"].segments == new_results
    assert updated == [
        ("sess-x", "done", [{"segment_id": "s01", "status": "processed", "transcript_id": 7, "error": None}])
    ]


def test_process_session_bg_marks_failed_in_db_on_crash(monkeypatch):
    from dataclasses import dataclass
    from models import SegmentResult, SessionStatus

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

    import asyncio

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

    manifest = _manifest("sess-post-1")
    files = [
        ("manifest", ("manifest.json", jsonlib.dumps(manifest).encode(), "application/json")),
        ("segments/s01.m4a", ("s01.m4a", b"fake-audio-bytes", "audio/mp4")),
    ]

    resp = _client().post("/api/sessions", files=files, headers=_auth())

    assert resp.status_code == 200
    assert len(created) == 1
    session_id, received_at, state, segments = created[0]
    assert session_id == "sess-post-1"
    assert state == "processing"
    assert segments == [
        {"segment_id": "s01", "status": "pending_analysis", "transcript_id": None, "error": None}
    ]
