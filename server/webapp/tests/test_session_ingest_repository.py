"""Contract of the session-ingest repository (REF-122/#122).

The same cases run against both adapters: `InMemorySessionIngests` always, and
`PostgresSessionIngests` when `SESSION_INGEST_TEST_DATABASE_URL` points at a
Postgres with the `session_ingests` table (skipped otherwise). Below the
contract, a few cases pin the SQL the Postgres adapter sends — they use a fake
pool and need no database.

This file also carries the startup-sweep selection cases (#52, BUG-53/#53,
BUG-114/#114) that used to test `db.list_pending_analysis_session_ids`.
"""

from __future__ import annotations

import asyncio
import json
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

import asyncpg
import pytest

import db
from models import SegmentResult, SessionStatus
from session_repository import InMemorySessionIngests, PostgresSessionIngests
from tests.session_helpers import segment_row

TEST_DATABASE_ENV = "SESSION_INGEST_TEST_DATABASE_URL"


@pytest.fixture(params=["in-memory", "postgres"])
def run(request, monkeypatch):
    """`run(scenario)` runs `await scenario(repository)` against one adapter and
    returns its result."""
    if request.param == "in-memory":
        return lambda scenario: asyncio.run(scenario(InMemorySessionIngests()))

    url = os.environ.get(TEST_DATABASE_ENV)
    if not url:
        pytest.skip(f"{TEST_DATABASE_ENV} not set")

    def run_on_postgres(scenario):
        async def with_pool():
            pool = await asyncpg.create_pool(url, min_size=1, max_size=2)

            async def get_pool():
                return pool

            monkeypatch.setattr(db, "get_pool", get_pool)
            try:
                await pool.execute("DELETE FROM session_ingests")
                return await scenario(PostgresSessionIngests())
            finally:
                await pool.execute("DELETE FROM session_ingests")
                await pool.close()

        return asyncio.run(with_pool())

    return run_on_postgres


def _status(session_id: str, state: str, *segments: dict) -> SessionStatus:
    return SessionStatus(
        session_id=session_id,
        received_at="2026-07-01T10:00:00Z",
        state=state,
        segments=[SegmentResult(**s) for s in segments],
    )


PENDING = segment_row("s01", "pending_analysis", 3, "analysis_pending: boom")
PROCESSED = segment_row("s01", "processed", 3)
FAILED = segment_row("s01", "failed", None, "whisper down")


# --- contract: status -----------------------------------------------------


def test_an_unknown_session_has_no_status(run):
    async def scenario(repo):
        return await repo.get("nope")

    assert run(scenario) is None


def test_create_caches_the_status_object_and_persists_its_row(run):
    async def scenario(repo):
        status = _status("sess-1", "processing", PENDING)
        await repo.create(status)
        cached = await repo.get("sess-1")
        repo.restart()
        reread = await repo.get("sess-1")
        return status, cached, reread

    status, cached, reread = run(scenario)

    assert cached is status
    assert reread is not status
    assert reread == status


def test_create_replaces_an_existing_row_for_the_session(run):
    async def scenario(repo):
        await repo.create(_status("sess-1", "processing", PENDING))
        await repo.create(_status("sess-1", "done", PROCESSED))
        repo.restart()
        return await repo.get("sess-1")

    assert run(scenario).state == "done"


def test_update_writes_through_to_the_cached_status_and_the_row(run):
    async def scenario(repo):
        status = _status("sess-1", "processing", PENDING)
        await repo.create(status)
        await repo.update("sess-1", "done", [SegmentResult(**PROCESSED)])
        repo.restart()
        return status, await repo.get("sess-1")

    cached, reread = run(scenario)

    assert (cached.state, [s.status for s in cached.segments]) == ("done", ["processed"])
    assert (reread.state, [s.model_dump() for s in reread.segments]) == ("done", [PROCESSED])


def test_update_of_an_uncached_session_still_updates_its_row(run):
    async def scenario(repo):
        await repo.create(_status("sess-1", "processing", PENDING))
        repo.restart()
        await repo.update("sess-1", "partial", [SegmentResult(**FAILED)])
        repo.restart()
        return await repo.get("sess-1")

    status = run(scenario)

    assert (status.state, status.segments[0].error) == ("partial", "whisper down")


def test_mark_failed_sets_the_state_and_keeps_the_segments(run):
    async def scenario(repo):
        status = _status("sess-1", "processing", PENDING)
        await repo.create(status)
        await repo.mark_failed("sess-1")
        cached_state = status.state
        repo.restart()
        return cached_state, await repo.get("sess-1")

    cached_state, reread = run(scenario)

    assert cached_state == "failed"
    assert (reread.state, [s.model_dump() for s in reread.segments]) == ("failed", [PENDING])


def test_delete_forgets_the_session_in_the_cache_and_the_rows(run):
    async def scenario(repo):
        await repo.create(_status("sess-1", "processing", PENDING))
        await repo.create(_status("sess-2", "processing", PENDING))
        await repo.delete("sess-1")
        gone = await repo.get("sess-1")
        repo.restart()
        return gone, await repo.get("sess-1"), await repo.get("sess-2")

    gone, gone_after_restart, kept = run(scenario)

    assert gone is None and gone_after_restart is None
    assert kept.session_id == "sess-2"


def test_clear_forgets_every_session(run):
    async def scenario(repo):
        await repo.create(_status("sess-1", "processing", PENDING))
        await repo.create(_status("sess-2", "done", PROCESSED))
        repo.restart()
        await repo.get("sess-1")  # cached again
        await repo.clear()
        return await repo.get("sess-1"), await repo.get("sess-2")

    assert run(scenario) == (None, None)


def test_list_sessions_returns_every_persisted_session_with_its_current_segments(run):
    """The day narrative reads every session of a date (FTR-01); a session that
    moved on after `create` is listed as it is now, cached or not."""

    async def scenario(repo):
        assert await repo.list_sessions() == []
        await repo.create(_status("sess-1", "processing", PENDING))
        await repo.create(_status("sess-2", "done", PROCESSED))
        await repo.update("sess-1", "done", [SegmentResult(**PROCESSED)])
        repo.restart()
        listed = await repo.list_sessions()
        return sorted((s.session_id, s.state, s.segments[0].status) for s in listed)

    assert run(scenario) == [("sess-1", "done", "processed"), ("sess-2", "done", "processed")]


# --- contract: startup sweep ----------------------------------------------


def test_sweep_candidates_are_processing_sessions_and_non_done_ones_with_a_pending_segment(run):
    """BUG-53/#53: a `processing` row was left behind by a dead process, so it
    is a candidate even with nothing pending yet. #52: a non-`done` session
    with a `pending_analysis` segment is. A `failed` segment alone is not."""

    async def scenario(repo):
        await repo.create(_status("sess-interrupted", "processing", PENDING))
        await repo.create(_status("sess-processing-nothing-pending", "processing", FAILED))
        await repo.create(_status("sess-partial", "partial", PROCESSED, {**PENDING, "segment_id": "s02"}))
        await repo.create(_status("sess-all-failed", "failed", FAILED))
        await repo.create(_status("sess-done", "done", PROCESSED))
        return await repo.list_sweep_candidates()

    assert sorted(run(scenario)) == [
        "sess-interrupted",
        "sess-partial",
        "sess-processing-nothing-pending",
    ]


def test_a_done_row_with_a_pending_segment_is_not_a_candidate_until_corrected_to_partial(run):
    """BUG-114/#114: `done` means every segment is `processed`; legacy `done`
    rows with a pending segment are marked `partial` once, then swept."""

    async def scenario(repo):
        await repo.create(_status("sess-legacy-done", "done", PENDING))
        await repo.create(_status("sess-done", "done", PROCESSED))
        before = await repo.list_sweep_candidates()
        corrected = await repo.correct_legacy_done_sessions()
        again = await repo.correct_legacy_done_sessions()
        after = await repo.list_sweep_candidates()
        repo.restart()
        return before, corrected, again, after, await repo.get("sess-legacy-done"), await repo.get(
            "sess-done"
        )

    before, corrected, again, after, legacy, done = run(scenario)

    assert before == []
    assert (corrected, again) == (1, 0)
    assert after == ["sess-legacy-done"]
    assert (legacy.state, done.state) == ("partial", "done")


def test_a_failed_retry_stays_persisted_and_swept_as_pending_analysis(run):
    """BUG-56/#56: a retry that fails again persists the segments as
    `pending_analysis` with an `analysis_pending: …` error."""
    segments = [
        SegmentResult(**segment_row("s01", "pending_analysis", 3, "analysis_pending: lightrag unreachable"))
    ]

    async def scenario(repo):
        await repo.create(_status("sess-retry-failed", "processing", PROCESSED))
        await repo.update("sess-retry-failed", "partial", segments)
        repo.restart()
        return await repo.list_sweep_candidates(), await repo.get("sess-retry-failed")

    candidates, status = run(scenario)

    assert candidates == ["sess-retry-failed"]
    assert status.segments == segments


# --- the SQL the Postgres adapter sends -----------------------------------


class _FakePool:
    def __init__(self, rows=(), execute_result="UPDATE 0"):
        self.rows = list(rows)
        self.execute_result = execute_result
        self.executed: list[tuple[str, tuple]] = []

    async def fetch(self, query, *args):
        return self.rows

    async def execute(self, query, *args):
        self.executed.append((" ".join(query.split()), args))
        return self.execute_result


def _use_pool(monkeypatch, pool) -> PostgresSessionIngests:
    async def fake_get_pool():
        return pool

    monkeypatch.setattr(db, "get_pool", fake_get_pool)
    return PostgresSessionIngests()


def test_postgres_sweep_reads_segments_stored_as_json_text(monkeypatch):
    pool = _FakePool(
        [
            {"session_id": "sess-partial", "state": "partial", "segments": json.dumps([PENDING])},
            {"session_id": "sess-failed", "state": "failed", "segments": json.dumps([FAILED])},
            {"session_id": "sess-list", "state": "partial", "segments": [PENDING]},
        ]
    )
    repo = _use_pool(monkeypatch, pool)

    assert asyncio.run(repo.list_sweep_candidates()) == ["sess-partial", "sess-list"]


def test_postgres_lists_sessions_whose_segments_are_stored_as_json_text(monkeypatch):
    received = "2026-07-01T10:00:00Z"
    pool = _FakePool(
        [
            {"session_id": "sess-text", "received_at": received, "state": "partial", "segments": json.dumps([PENDING])},
            {"session_id": "sess-list", "received_at": received, "state": "done", "segments": [PROCESSED]},
        ]
    )
    repo = _use_pool(monkeypatch, pool)

    listed = asyncio.run(repo.list_sessions())

    assert [(s.session_id, s.segments[0].status) for s in listed] == [
        ("sess-text", "pending_analysis"), ("sess-list", "processed"),
    ]


def test_postgres_legacy_correction_is_one_idempotent_update(monkeypatch):
    pool = _FakePool(execute_result="UPDATE 2")
    repo = _use_pool(monkeypatch, pool)

    assert asyncio.run(repo.correct_legacy_done_sessions()) == 2

    query, args = pool.executed[0]
    assert "UPDATE session_ingests" in query
    assert "SET state = 'partial'" in query
    assert "state = 'done'" in query
    assert "pending_analysis" in query
    assert args == ()


def test_postgres_update_stores_the_segments_as_json(monkeypatch):
    pool = _FakePool()
    repo = _use_pool(monkeypatch, pool)

    asyncio.run(repo.update("sess-1", "partial", [SegmentResult(**PENDING)]))

    query, args = pool.executed[0]
    assert "UPDATE session_ingests" in query
    assert args[:2] == ("sess-1", "partial")
    assert json.loads(args[2]) == [PENDING]
