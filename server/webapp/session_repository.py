"""Session-ingest repository (REF-122/#122).

The one seam over everything the session lifecycle persists about a session's
status: the `session_ingests` table and the process-local status cache in front
of it (SRV-A6). `session_processing.SessionProcessor` talks only to a
`SessionIngestRepository`; no other module touches `session_ingests`.

Two adapters share the cache and differ only in where rows live:

* `PostgresSessionIngests` — the app's adapter, backed by `session_ingests`;
* `InMemorySessionIngests` — a dict of rows, for tests and tooling.

`tests/test_session_ingest_repository.py` runs the same contract cases against
both. The cache is write-through: a transition updates the cached
`SessionStatus` (when present) and the stored row, so same-process polling is
fast and a restart (an empty cache) reads the row back.
"""

from __future__ import annotations

import asyncio
import json
from abc import ABC, abstractmethod

import db
from models import SegmentResult, SessionStatus


def is_sweep_candidate(state: str | None, segments: list[dict]) -> bool:
    """Whether the startup retry sweep should look at a session: every
    `processing` one (BUG-53/#53, the process that ran it died) and every
    non-`done` one with a `pending_analysis` segment (#52). `done` sessions
    are never candidates (BUG-114/#114)."""
    return state == "processing" or (
        state != "done" and any(s.get("status") == "pending_analysis" for s in segments)
    )


def has_pending_segment(segments: list[dict]) -> bool:
    return any(s.get("status") == "pending_analysis" for s in segments)


class SessionIngestRepository(ABC):
    """Status cache plus persisted rows for session ingests.

    The public methods keep the cache and the rows in step; an adapter only
    implements the `_`-prefixed row operations. Rows are dicts with
    `session_id`, `received_at`, `state` and `segments` (a list of
    `SegmentResult` dumps) — exactly `SessionStatus`'s fields.
    """

    def __init__(self) -> None:
        self._cache: dict[str, SessionStatus] = {}
        self._lock = asyncio.Lock()

    # -- adapter operations -------------------------------------------------

    @abstractmethod
    async def _insert(
        self, session_id: str, received_at: str, state: str, segments: list[dict]
    ) -> None:
        """Insert the row, replacing an existing one for the session."""

    @abstractmethod
    async def _update(self, session_id: str, state: str, segments: list[dict]) -> None:
        """Set state and segments of the session's row; no-op if there is none."""

    @abstractmethod
    async def _set_failed(self, session_id: str) -> None:
        """Set the row's state to `failed`, keeping its segments."""

    @abstractmethod
    async def _fetch(self, session_id: str) -> dict | None:
        ...

    @abstractmethod
    async def _delete(self, session_id: str) -> None:
        ...

    @abstractmethod
    async def _delete_all(self) -> None:
        ...

    @abstractmethod
    async def _list_sweep_candidates(self) -> list[str]:
        ...

    @abstractmethod
    async def _correct_legacy_done(self) -> int:
        ...

    # -- status -------------------------------------------------------------

    async def get(self, session_id: str) -> SessionStatus | None:
        """Cache-then-row lookup. A cache miss (e.g. after a restart) reads the
        row and repopulates the cache from it; `None` if neither knows the
        session."""
        async with self._lock:
            cached = self._cache.get(session_id)
        if cached is not None:
            return cached

        row = await self._fetch(session_id)
        if row is None:
            return None
        status = SessionStatus.model_validate(row)
        async with self._lock:
            return self._cache.setdefault(session_id, status)

    async def create(self, status: SessionStatus) -> None:
        """Cache `status`, then persist its row (replacing a previous row for
        the session). The cached object is the one callers keep and later
        transitions update in place."""
        async with self._lock:
            self._cache[status.session_id] = status
        await self._insert(
            status.session_id,
            status.received_at,
            status.state,
            [s.model_dump() for s in status.segments],
        )

    async def update(self, session_id: str, state: str, segments: list[SegmentResult]) -> None:
        """Write-through transition: update the cached status (if present) and
        the persisted row."""
        async with self._lock:
            current = self._cache.get(session_id)
            if current is not None:
                current.state = state
                current.segments = segments
        await self._update(session_id, state, [s.model_dump() for s in segments])

    async def mark_failed(self, session_id: str) -> None:
        """The session's run crashed: `failed` in the cache (if present) and
        the row; the segments stay as they were."""
        async with self._lock:
            current = self._cache.get(session_id)
            if current is not None:
                current.state = "failed"
        await self._set_failed(session_id)

    async def delete(self, session_id: str) -> None:
        """Forget the session in the cache and the table."""
        async with self._lock:
            self._cache.pop(session_id, None)
        await self._delete(session_id)

    async def clear(self) -> None:
        """Forget every session: all rows, then the whole cache."""
        await self._delete_all()
        async with self._lock:
            self._cache.clear()

    def restart(self) -> None:
        """Drop the cache, as a process restart does; the rows stay."""
        self._cache.clear()

    # -- startup sweep ------------------------------------------------------

    async def list_sweep_candidates(self) -> list[str]:
        """Session ids the startup retry sweep should look at
        (`is_sweep_candidate`)."""
        return await self._list_sweep_candidates()

    async def correct_legacy_done_sessions(self) -> int:
        """Mark `done` rows that still have a `pending_analysis` segment
        `partial` (BUG-114/#114): before the fix a session whose analysis
        failed was persisted as `done`, and the sweep no longer lists `done`
        rows. Idempotent; returns the number of rows corrected. Runs before the
        sweep lists its candidates, so it leaves the cache alone."""
        return await self._correct_legacy_done()


class PostgresSessionIngests(SessionIngestRepository):
    """`session_ingests` rows in Postgres."""

    async def _insert(
        self, session_id: str, received_at: str, state: str, segments: list[dict]
    ) -> None:
        pool = await db.get_pool()
        await pool.execute(
            """
            INSERT INTO session_ingests (session_id, received_at, state, segments)
            VALUES ($1, $2, $3, $4::jsonb)
            ON CONFLICT (session_id) DO UPDATE
            SET received_at = $2, state = $3, segments = $4::jsonb, updated_at = NOW()
            """,
            session_id,
            received_at,
            state,
            json.dumps(segments),
        )

    async def _update(self, session_id: str, state: str, segments: list[dict]) -> None:
        pool = await db.get_pool()
        await pool.execute(
            """
            UPDATE session_ingests
            SET state = $2, segments = $3::jsonb, updated_at = NOW()
            WHERE session_id = $1
            """,
            session_id,
            state,
            json.dumps(segments),
        )

    async def _set_failed(self, session_id: str) -> None:
        pool = await db.get_pool()
        await pool.execute(
            "UPDATE session_ingests SET state = 'failed', updated_at = NOW() WHERE session_id = $1",
            session_id,
        )

    async def _fetch(self, session_id: str) -> dict | None:
        pool = await db.get_pool()
        row = await pool.fetchrow(
            """
            SELECT session_id, received_at, state, segments
            FROM session_ingests
            WHERE session_id = $1
            """,
            session_id,
        )
        if row is None:
            return None
        result = dict(row)
        if isinstance(result["segments"], str):
            result["segments"] = json.loads(result["segments"])
        return result

    async def _delete(self, session_id: str) -> None:
        pool = await db.get_pool()
        await pool.execute("DELETE FROM session_ingests WHERE session_id = $1", session_id)

    async def _delete_all(self) -> None:
        pool = await db.get_pool()
        await pool.execute("DELETE FROM session_ingests")

    async def _list_sweep_candidates(self) -> list[str]:
        # The filter runs in Python — this table is small (one row per session).
        pool = await db.get_pool()
        rows = await pool.fetch("SELECT session_id, state, segments FROM session_ingests")
        result = []
        for row in rows:
            segments = row["segments"]
            if isinstance(segments, str):
                segments = json.loads(segments)
            if is_sweep_candidate(row.get("state"), segments):
                result.append(row["session_id"])
        return result

    async def _correct_legacy_done(self) -> int:
        pool = await db.get_pool()
        result = await pool.execute(
            """
            UPDATE session_ingests
            SET state = 'partial', updated_at = NOW()
            WHERE state = 'done' AND segments @> '[{"status": "pending_analysis"}]'::jsonb
            """
        )
        return int(result.rsplit(" ", 1)[-1])


class InMemorySessionIngests(SessionIngestRepository):
    """Rows in a dict (`rows`, by session id), no database."""

    def __init__(self) -> None:
        super().__init__()
        self.rows: dict[str, dict] = {}

    async def _insert(
        self, session_id: str, received_at: str, state: str, segments: list[dict]
    ) -> None:
        self.rows[session_id] = {
            "session_id": session_id,
            "received_at": received_at,
            "state": state,
            "segments": segments,
        }

    async def _update(self, session_id: str, state: str, segments: list[dict]) -> None:
        row = self.rows.get(session_id)
        if row is not None:
            row["state"] = state
            row["segments"] = segments

    async def _set_failed(self, session_id: str) -> None:
        row = self.rows.get(session_id)
        if row is not None:
            row["state"] = "failed"

    async def _fetch(self, session_id: str) -> dict | None:
        return self.rows.get(session_id)

    async def _delete(self, session_id: str) -> None:
        self.rows.pop(session_id, None)

    async def _delete_all(self) -> None:
        self.rows.clear()

    async def _list_sweep_candidates(self) -> list[str]:
        return [
            session_id
            for session_id, row in self.rows.items()
            if is_sweep_candidate(row["state"], row["segments"])
        ]

    async def _correct_legacy_done(self) -> int:
        legacy = [
            row
            for row in self.rows.values()
            if row["state"] == "done" and has_pending_segment(row["segments"])
        ]
        for row in legacy:
            row["state"] = "partial"
        return len(legacy)
