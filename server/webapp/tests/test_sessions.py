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

    async def fake_correct_transcript(*, raw_text):
        return raw_text, []

    async def fake_load_person_dictionary():
        return []

    async def fake_load_term_dictionary():
        return []

    def fake_detect_entities(*, text, persons, terms):
        return []

    monkeypatch.setattr(sessions_router.transcript_ingest, "transcribe_and_persist", fake_transcribe_and_persist)
    monkeypatch.setattr(sessions_router.transcript_corrector, "correct_transcript", fake_correct_transcript)
    monkeypatch.setattr(db, "load_person_dictionary", fake_load_person_dictionary)
    monkeypatch.setattr(db, "load_term_dictionary", fake_load_term_dictionary)
    monkeypatch.setattr(sessions_router, "detect_entities", fake_detect_entities)

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
