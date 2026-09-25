"""SRV-A8: raw SQL must not leak out of db.py into route handlers in main.py.

`docs/REVIEW-2026-07-04.md` §2 SRV-A8 — main.py was calling `db.get_pool()`
directly and building ad hoc `pool.fetch(...)`/`pool.execute(...)` queries
inline in several handlers instead of going through a named function in
db.py. These tests pin the replacement named functions' behavior and guard
against the raw-SQL pattern creeping back into main.py.

No live Postgres in this environment: `db` calls are monkeypatched, and
`TestClient(main.app)` is used without the `with` context manager so the
app's lifespan (which does touch a real pool) never runs.
"""

from __future__ import annotations

import re
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

import db
import main

client = TestClient(main.app)

BEARER_TOKEN = "test-bearer-token"

MAIN_PY = Path(__file__).resolve().parent.parent / "main.py"

_RAW_SQL_CALL = re.compile(r"\bpool\.(fetch|fetchrow|fetchval|execute)\(")


@pytest.fixture(autouse=True)
def _bearer_token(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("IOS_BEARER_TOKEN", BEARER_TOKEN)


def _auth() -> dict:
    return {"Authorization": f"Bearer {BEARER_TOKEN}"}


def test_main_py_has_no_raw_pool_queries():
    source = MAIN_PY.read_text()
    assert not _RAW_SQL_CALL.search(source), (
        "main.py should call named db.py functions instead of building "
        "pool.fetch/execute queries inline (SRV-A8)"
    )


def test_transcripts_status_route_uses_named_db_function(monkeypatch):
    async def fake_list_recent_transcript_statuses():
        return [
            {
                "id": 7,
                "status": "processed",
                "submitted_at": None,
                "processed_at": None,
                "processing_error": None,
            }
        ]

    monkeypatch.setattr(
        db, "list_recent_transcript_statuses", fake_list_recent_transcript_statuses
    )

    response = client.get("/api/transcripts/status", headers=_auth())

    assert response.status_code == 200
    assert response.json() == [
        {
            "id": 7,
            "status": "processed",
            "processing_seconds": None,
            "processing_error": None,
        }
    ]


def test_transcript_retry_route_uses_named_db_function(monkeypatch):
    calls = []

    async def fake_get_transcript(transcript_id):
        return {"id": transcript_id, "status": "failed"}

    async def fake_mark_transcript_resubmitted(transcript_id):
        calls.append(transcript_id)

    monkeypatch.setattr(db, "get_transcript", fake_get_transcript)
    monkeypatch.setattr(
        db, "mark_transcript_resubmitted", fake_mark_transcript_resubmitted
    )

    response = client.post("/api/transcripts/42/retry", headers=_auth())

    assert response.status_code == 200
    assert response.json() == {"status": "submitted", "process_url": "/process/42"}
    assert calls == [42]


def test_ingest_retry_route_resets_status_via_named_db_function(monkeypatch):
    calls = []

    async def fake_reset_ingest_upload_for_retry(upload_id):
        calls.append(upload_id)

    async def fake_ingest_audio(content, filename):
        return 99, "/review/99", "hello"

    async def fake_mark_ingest_success(upload_id, transcript_id, review_url):
        return None

    monkeypatch.setattr(
        db, "reset_ingest_upload_for_retry", fake_reset_ingest_upload_for_retry
    )
    monkeypatch.setattr(main, "_ingest_audio_to_transcript", fake_ingest_audio)
    monkeypatch.setattr(db, "mark_ingest_success", fake_mark_ingest_success)

    response = client.post(
        "/api/ingest/5/retry",
        headers=_auth(),
        files={"file": ("upload.mp3", b"fake-audio", "audio/mpeg")},
    )

    assert response.status_code == 200
    assert calls == [5]


def test_index_route_uses_named_db_function_for_doc_map(monkeypatch):
    async def fake_list_transcripts(status=None):
        return [
            {
                "id": 1,
                "filename": "a.m4a",
                "author": "Florian Wolf",
                "status": "processed",
                "word_count": 10,
                "date": None,
                "created_at": None,
                "submitted_at": None,
                "processed_at": None,
                "processing_error": None,
            }
        ]

    async def fake_get_latest_document_ids_by_transcript():
        return {1: 55}

    monkeypatch.setattr(db, "list_transcripts", fake_list_transcripts)
    monkeypatch.setattr(
        db,
        "get_latest_document_ids_by_transcript",
        fake_get_latest_document_ids_by_transcript,
    )

    response = client.get("/", headers=_auth())

    assert response.status_code == 200
    assert '"doc_id": 55' in response.text
