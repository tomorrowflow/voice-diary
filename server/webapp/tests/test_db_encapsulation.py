"""SRV-A8 / REF-124: raw SQL must not leak out of db.py into route handlers
in main.py or routers/.

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
ROUTERS_DIR = Path(__file__).resolve().parent.parent / "routers"

_RAW_SQL_CALL = re.compile(r"\bpool\.(fetch|fetchrow|fetchval|execute)\(")


@pytest.fixture(autouse=True)
def _bearer_token(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("IOS_BEARER_TOKEN", BEARER_TOKEN)


def _auth() -> dict:
    return {"Authorization": f"Bearer {BEARER_TOKEN}"}


def _raw_sql_offenders(paths) -> list[str]:
    return [p.name for p in paths if _RAW_SQL_CALL.search(p.read_text())]


def test_main_py_has_no_raw_pool_queries():
    source = MAIN_PY.read_text()
    assert not _RAW_SQL_CALL.search(source), (
        "main.py should call named db.py functions instead of building "
        "pool.fetch/execute queries inline (SRV-A8)"
    )


def test_routers_have_no_raw_pool_queries():
    offenders = _raw_sql_offenders(sorted(ROUTERS_DIR.glob("*.py")))
    assert not offenders, (
        f"routers/ should call named db.py functions instead of building "
        f"pool.fetch/execute queries inline (REF-124): {offenders}"
    )


def test_router_guard_flags_a_planted_raw_query(tmp_path):
    planted = tmp_path / "planted.py"
    planted.write_text(
        "async def handler():\n"
        "    pool = await db.get_pool()\n"
        '    return await pool.fetch("SELECT 1")\n'
    )
    assert _raw_sql_offenders([planted]) == ["planted.py"]


def test_session_dates_route_passes_bounds_to_named_db_function(monkeypatch):
    from datetime import date

    calls = []

    async def fake_list_transcript_dates(date_from, date_to):
        calls.append((date_from, date_to))
        return [date(2026, 7, 1), date(2026, 7, 3)]

    monkeypatch.setattr(db, "list_transcript_dates", fake_list_transcript_dates)

    response = client.get(
        "/api/sessions/dates?date_from=2026-07-01&date_to=2026-07-31",
        headers=_auth(),
    )
    assert response.status_code == 200
    assert response.json() == {"dates": ["2026-07-01", "2026-07-03"]}
    assert calls == [(date(2026, 7, 1), date(2026, 7, 31))]

    calls.clear()
    response = client.get("/api/sessions/dates", headers=_auth())
    assert response.json() == {"dates": ["2026-07-01", "2026-07-03"]}
    assert calls == [(None, None)]


def test_session_dates_route_rejects_invalid_bound():
    response = client.get("/api/sessions/dates?date_from=nope", headers=_auth())
    assert response.status_code == 400
    assert response.json()["detail"] == "invalid_date_from"


@pytest.mark.parametrize(
    ("url", "db_name", "ids"),
    [
        (
            "/api/admin/persons/3/variations",
            "get_person_variation_id",
            (3, "Flo"),
        ),
        (
            "/api/admin/terms/4/variations",
            "get_term_variation_id",
            (4, "Flo"),
        ),
    ],
)
def test_add_variation_routes_return_id_from_named_db_function(
    monkeypatch, url, db_name, ids
):
    saved = []
    looked_up = []

    async def fake_save(*args):
        saved.append(args)

    async def fake_get_id(owner_id, variation):
        looked_up.append((owner_id, variation))
        return 77

    monkeypatch.setattr(db, "save_person_variation", fake_save)
    monkeypatch.setattr(db, "save_term_variation", fake_save)
    monkeypatch.setattr(db, db_name, fake_get_id)

    response = client.post(url, headers=_auth(), json={"text": "Flo"})

    assert response.status_code == 200
    assert response.json() == {"status": "ok", "id": 77}
    assert looked_up == [ids]

    async def fake_get_missing_id(owner_id, variation):
        return None

    monkeypatch.setattr(db, db_name, fake_get_missing_id)
    response = client.post(url, headers=_auth(), json={"text": "Flo"})
    assert response.json() == {"status": "ok", "id": None}


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
                "author": "Lukas Brandt",
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


@pytest.mark.parametrize(
    ("bounds", "fragment"),
    [
        (("lo", "hi"), "BETWEEN $1 AND $2"),
        (("lo", None), "date >= $1"),
        ((None, "hi"), "date <= $1"),
        ((None, None), "FROM transcripts ORDER BY date"),
    ],
)
async def test_list_transcript_dates_picks_query_variant(
    monkeypatch, bounds, fragment
):
    seen = []

    class FakePool:
        async def fetch(self, sql, *args):
            seen.append((sql, args))
            return [{"date": "d1"}]

    async def fake_get_pool():
        return FakePool()

    monkeypatch.setattr(db, "get_pool", fake_get_pool)

    assert await db.list_transcript_dates(*bounds) == ["d1"]
    sql, args = seen[0]
    assert fragment in sql
    assert args == tuple(b for b in bounds if b is not None)
