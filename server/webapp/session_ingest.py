"""Session ingest (ARCH-2, REF-126): the lifecycle of an uploaded session
bundle, see "Session ingest" in CONTEXT.md.

The one server seam behind the ways a session gets processed. Its interface
is `SessionIngest`:

* **accept** — `accept()` claims the session and persists its `processing`
  row; `process()` then runs the two-phase pipeline in the background;
* **retry** — `retry()` re-runs the narrative stage for the segments left
  `pending_analysis`, resuming the ones that never got a transcript;
* **sweep** — `sweep()` retries every stranded session once after a restart;
* **status** — `status()` reads a session's status;
* **date coordination** — `narrative_date()` is the one-writer-at-a-time hold
  on a date's diary document, taken by every narrative writer here and by the
  review UI's manual ingest.

`routers/sessions.py` only parses HTTP and maps this module's results and
`SessionError`s to responses; `main.py`'s lifespan only calls `sweep()`. This
module never raises `HTTPException`. Everything else lives here: the status
transitions and which sessions and segments are eligible for a retry or the
sweep (persisted through a `SessionIngestRepository`, REF-122, which owns the
status cache and the `session_ingests` table, SRV-A6), the per-session
in-flight claim that keeps two runs from saving two narratives for one session
(BUG-54), interrupted-session resume (BUG-112), where a session bundle lives on
disk and reading its manifest back, the per-segment pipeline, and the
narrative persistence.

Pipeline for one segment:

    AAC-LC m4a  →  ffmpeg → 16 kHz mono WAV
                →  Whisper sidecar
                →  correction (dictionary + few-shot LLM correction, shared
                   with the HTMX review flow — #51)
                →  entity_detector (4-pass with calendar_ref shortcut) +
                   dismissal filtering
                →  day narrative (LightRAG context + analysis + ingest), once
                   per run, over every transcribed segment of every session
                   of the date (ADR 0006)

A failure on one segment does not fail the session; each segment's status is
recorded individually. The narrative stage is the one step shared between
sessions: it runs one writer at a time per date and gathers its input only
once it holds the date, so a late writer never publishes a stale view. A run
changes the status of its own session's segments only.

State lives on a `SessionIngest`; the app uses the process-wide one from
`get_session_ingest()` (Postgres-backed), tests build their own over an
in-memory repository.
"""

from __future__ import annotations

import asyncio
import json
import logging
import re
import shutil
from contextlib import asynccontextmanager
from dataclasses import dataclass, field, replace
from datetime import datetime, timezone
from pathlib import Path
from typing import AsyncIterator, Awaitable, Callable

import asr_client
import correction
import db
import dictionary
import narrative
import transcript_ingest
import upstream_failure
from logging_setup import bind_session_id
from models import (
    CalendarEventSegment,
    DriveBySegment,
    EmptyBlockSegment,
    FreeReflectionSegment,
    Manifest,
    Segment,
    SegmentResult,
    SessionStatus,
    Todo,
    utcnow_iso,
)
from paths import sessions_dir
from session_repository import PostgresSessionIngests, SessionIngestRepository

logger = logging.getLogger(__name__)


# --- errors ---------------------------------------------------------------


class SessionError(Exception):
    """A session request the lifecycle refuses. `code` is the stable reason
    the HTTP layer reports and the sweep logs."""

    code = "session_error"

    def __init__(self) -> None:
        super().__init__(self.code)


class SessionNotFound(SessionError):
    """Neither the status cache nor `session_ingests` knows the session."""

    code = "session_not_found"


class SessionBusy(SessionError):
    """A run for the session (ingest, retry or sweep) is already in flight."""

    code = "session_busy"


class SessionNotRetryable(SessionError):
    """Nothing to retry: no segment is `pending_analysis`, or the pending ones
    have no transcript row left to narrate and nothing was resumed."""

    code = "session_not_retryable"


class SessionManifestMissing(SessionError):
    """The bundle's `manifest.json` is gone from disk, so the narrative input
    can't be rebuilt."""

    code = "session_manifest_missing"


# --- storage layout -------------------------------------------------------


def slug_session_id(session_id: str) -> str:
    """Filesystem-safe slug for the session directory."""
    return re.sub(r"[^A-Za-z0-9._-]+", "_", session_id)


def session_dir_for(session_id: str) -> Path:
    """Where `session_id`'s bundle (`manifest.json`, audio) lives on disk."""
    return sessions_dir() / slug_session_id(session_id)


def load_manifest(session_id: str) -> Manifest:
    """Read back the manifest stored with `session_id`'s bundle. Raises
    `SessionManifestMissing` if the bundle is gone."""
    manifest_path = session_dir_for(session_id) / "manifest.json"
    if not manifest_path.exists():
        raise SessionManifestMissing()
    return Manifest.model_validate(json.loads(manifest_path.read_bytes()))


async def _finish_despite_cancellation(work: asyncio.Future) -> None:
    """Wait for `work` to finish even if the caller is cancelled meanwhile,
    then re-raise the cancellation (or `work`'s own error). The deletion of
    the sessions can't be stopped halfway — its thread keeps running — so the
    upload gate must stay closed until it is done."""
    cancelled = False
    while not work.done():
        try:
            await asyncio.shield(work)
        except asyncio.CancelledError:
            cancelled = True
        except Exception:
            pass  # surfaced by work.result() below
    work.result()
    if cancelled:
        raise asyncio.CancelledError


def _remove_all_bundles() -> None:
    root = sessions_dir()
    if not root.is_dir():
        return
    for entry in root.iterdir():
        if entry.is_dir() and not entry.is_symlink():
            shutil.rmtree(entry)
        else:
            entry.unlink()


async def _asr_reachable() -> bool:
    return await asr_client.get_default_client().reachable()


def derive_session_state(results: list[SegmentResult]) -> str:
    """`done` only when every segment is `processed`, `failed` when every one
    failed, otherwise `partial` — including any `pending_analysis` segment
    (BUG-114/#114)."""
    if all(r.status == "processed" for r in results):
        return "done"
    if all(r.status == "failed" for r in results):
        return "failed"
    return "partial"


@dataclass
class _SegmentArtifact:
    """Per-segment outputs handed off to the session-level analysis stage."""

    segment: Segment
    transcript_id: int
    raw_text: str
    corrected_text: str
    entities: list[dict] = field(default_factory=list)


@dataclass
class _DaySession:
    """One session's contribution to a day narrative: its manifest (for the
    todos) and its transcribed segments in manifest order."""

    manifest: Manifest
    artifacts: list[_SegmentArtifact]


# --- lifecycle ------------------------------------------------------------


class SessionIngest:
    """Owns session status and runs the ingest lifecycle.

    `whisper_reachable` is the pre-flight used by `accept()`; Whisper is the
    one upstream a session can't work around. `repository` holds the status
    cache and the persisted `session_ingests` rows (SRV-A6, REF-122): the
    Postgres adapter unless a test passes another.
    """

    def __init__(
        self,
        *,
        whisper_reachable: Callable[[], Awaitable[bool]] = _asr_reachable,
        repository: SessionIngestRepository | None = None,
    ) -> None:
        self._whisper_reachable = whisper_reachable
        self.repository: SessionIngestRepository = (
            repository if repository is not None else PostgresSessionIngests()
        )
        self._lock = asyncio.Lock()
        # Sessions with a narrative run in flight (original background ingest,
        # a manual retry-analysis, or the startup sweep). A second run of the
        # same session would save another `processed_documents` version per
        # transcript and ingest `diary:{date}` into LightRAG twice. Guarded by
        # `_lock`; single-process app, so an in-process set is enough.
        self._in_flight: set[str] = set()
        # One lock per date for the narrative stage (`narrative_date`). Only
        # that stage takes it: transcription, uploads and other dates are not
        # held up. A date's lock is created on first use and kept (one small
        # object per recorded date).
        self._date_locks: dict[str, asyncio.Lock] = {}
        # Upload gate (see `upload_gate` / `reset_all_data`).
        self._gate = asyncio.Condition()
        self._uploads_inside = 0
        self._resetting = False

    # -- claims ------------------------------------------------------------

    async def _try_begin(self, session_id: str) -> bool:
        """Claim `session_id` for a run; False if one is already in flight."""
        async with self._lock:
            if session_id in self._in_flight:
                return False
            self._in_flight.add(session_id)
            return True

    async def _end(self, session_id: str) -> None:
        async with self._lock:
            self._in_flight.discard(session_id)

    @asynccontextmanager
    async def narrative_date(self, date: str) -> AsyncIterator[None]:
        """Hold `date` (an ISO date, the `diary:{date}` document's date) for a
        narrative write: gather the input, analyse, save, publish. Writers for
        one date run one at a time, in arrival order; writers for other dates
        do not wait. Whoever holds it must gather its input after taking it,
        from what is stored then. The review UI's manual ingest of a document
        takes it too."""
        lock = self._date_locks.setdefault(date, asyncio.Lock())
        async with lock:
            yield

    # -- status ------------------------------------------------------------

    async def status(self, session_id: str) -> SessionStatus | None:
        """Cache-then-row lookup; `None` for an unknown session. A cache miss
        (e.g. after a restart) falls back to the persisted row (SRV-A6) and
        repopulates the cache from it."""
        return await self.repository.get(session_id)

    async def _current_status(self, session_id: str) -> SessionStatus:
        """The session's status after a transition was persisted. Only a data
        reset that lands mid-run can make it vanish."""
        status_obj = await self.repository.get(session_id)
        if status_obj is None:
            raise SessionNotFound()
        return status_obj

    # -- upload gate / reset ----------------------------------------------

    @asynccontextmanager
    async def upload_gate(self) -> AsyncIterator[None]:
        """Held by an upload from writing its bundle until `accept()` has
        persisted the session. A reset waits for the uploads inside it and
        holds new ones back until it is done."""
        async with self._gate:
            await self._gate.wait_for(lambda: not self._resetting)
            self._uploads_inside += 1
        try:
            yield
        finally:
            self._uploads_inside -= 1
            await self._wake_gate_waiters()

    async def reset_all_data(self) -> None:
        """The admin "Reset All Data" (MIG-115/#115): `db.reset_all_data`,
        then forget every session — clear the repository (rows and status
        cache) and delete every bundle under `data/sessions/` (the directory
        itself stays). Runs with no upload inside the gate, so no upload can create a
        row or bundle between the database reset and the bundle removal.

        `_resetting` is cleared on every exit, including cancellation while
        waiting for the uploads to drain; otherwise every later upload and
        reset would wait forever."""
        async with self._gate:
            await self._gate.wait_for(lambda: not self._resetting)
            self._resetting = True
        try:
            async with self._gate:
                await self._gate.wait_for(lambda: self._uploads_inside == 0)
            await _finish_despite_cancellation(asyncio.ensure_future(self._clear_everything()))
        finally:
            self._resetting = False
            await self._wake_gate_waiters()

    async def _clear_everything(self) -> None:
        await db.reset_all_data()
        await self.repository.clear()
        await asyncio.to_thread(_remove_all_bundles)

    async def _wake_gate_waiters(self) -> None:
        """Wake the gate's waiters after its state changed. Shielded so a
        cancellation arriving while the gate lock is contended can't skip the
        wake-up; the state itself is already updated by the caller."""

        async def notify() -> None:
            async with self._gate:
                self._gate.notify_all()

        await asyncio.shield(notify())

    async def _persist_status(
        self, session_id: str, state: str, segments: list[SegmentResult]
    ) -> None:
        """Write-through: the repository updates the cached status (if
        present) and the persisted row (SRV-A6) so status survives a restart."""
        await self.repository.update(session_id, state, segments)

    async def _persist_phase_1_progress(
        self, parsed: Manifest, results_by_id: dict[str, SegmentResult]
    ) -> None:
        """Persist each segment's phase-1 outcome (transcript ID or failure)
        while the session is still `processing` (BUG-53/#53), so a crash before
        the final write doesn't strand `session_ingests` rows with null
        transcript IDs. Best-effort: the final write in `_process_session`
        still lands."""
        segments = [
            results_by_id.get(seg.segment_id)
            or SegmentResult(segment_id=seg.segment_id, status="pending_analysis")
            for seg in parsed.segments
        ]
        try:
            await self._persist_status(parsed.session_id, "processing", segments)
        except Exception as exc:  # noqa: BLE001
            logger.warning(
                "session %s: could not persist phase 1 progress: %s", parsed.session_id, exc,
            )

    # -- day narrative -----------------------------------------------------

    async def _narrate_day(
        self,
        manifest: Manifest,
        results: list[SegmentResult],
        known: dict[str, _SegmentArtifact],
        *,
        republish: bool,
    ) -> None:
        """The narrative stage every writer shares (ADR 0006): take the date,
        gather the day's input, publish. Raises when analysis or the LightRAG
        ingest fails; the caller then leaves its segments `pending_analysis`.

        `results` are the triggering session's segment results as the caller
        holds them (its latest, not necessarily persisted yet); `known` are
        the artifacts it just built, so they are not read back. `republish`
        lets a saved day narrative be re-ingested instead of re-analysed (a
        retry or the sweep); the original ingest has fresh transcripts with no
        saved document, so it never could.
        """
        async with self.narrative_date(manifest.date.isoformat()):
            day = await self._gather_day(manifest, results, known)
            artifacts = [art for session in day for art in session.artifacts]
            if not (republish and await _publish_saved_day(artifacts)):
                await _analyse_and_publish_day(manifest.date.isoformat(), day)

    async def _gather_day(
        self,
        manifest: Manifest,
        results: list[SegmentResult],
        known: dict[str, _SegmentArtifact],
    ) -> list[_DaySession]:
        """Every session whose manifest date is `manifest`'s, in session start
        order, each with its transcribed segments in manifest order. Called
        only while the date is held. A session whose manifest is missing or
        unreadable can't supply headers and todos: it is skipped with one log
        line."""
        trigger_id = manifest.session_id
        candidates: list[tuple[tuple, Manifest, list[SegmentResult], dict | None]] = []
        trigger_received = ""
        others: list[SessionStatus] = []
        for status in await self.repository.list_sessions():
            if status.session_id == trigger_id:
                trigger_received = status.received_at
            else:
                others.append(status)
        candidates.append(
            (_session_start_key(trigger_id, trigger_received), manifest, results, known)
        )
        for status in others:
            try:
                other = load_manifest(status.session_id)
            except Exception as exc:  # noqa: BLE001 — one bad bundle must not fail the run
                logger.warning(
                    "day narrative %s: skipping session %s, manifest unreadable: %s",
                    manifest.date, status.session_id, exc,
                )
                continue
            if other.date != manifest.date:
                continue
            candidates.append(
                (_session_start_key(status.session_id, status.received_at),
                 other, status.segments, None)
            )

        candidates.sort(key=lambda candidate: candidate[0])
        day: list[_DaySession] = []
        for _, session_manifest, session_results, session_known in candidates:
            artifacts = await _stored_artifacts(session_manifest, session_results, session_known)
            if artifacts:
                day.append(_DaySession(manifest=session_manifest, artifacts=artifacts))
        return day

    # -- original ingest ---------------------------------------------------

    async def accept(self, parsed: Manifest, session_dir: Path) -> SessionStatus:
        """Register a freshly uploaded bundle (already saved under
        `session_dir`) and return its `processing` status.

        Claims the session before its `processing` row exists, not when the
        background run starts: the startup sweep treats an unclaimed
        `processing` row as orphaned by a dead process, and a retry arriving
        before the run is scheduled must still see it busy. `process`
        releases the claim.

        Raises `upstream_failure.whisper_unavailable()` — after removing
        `session_dir` and rolling the status back — when Whisper is down:
        better to surface 503 early than persist a useless bundle.
        """
        session_id = parsed.session_id
        received_at = utcnow_iso()
        pending_results = [
            SegmentResult(segment_id=seg.segment_id, status="pending_analysis")
            for seg in parsed.segments
        ]

        await self._try_begin(session_id)
        try:
            accepted = SessionStatus(
                session_id=session_id,
                received_at=received_at,
                state="processing",
                segments=pending_results,
            )
            # Persist before we answer — the cache is not enough; the row is
            # what survives a restart (SRV-A6).
            await self.repository.create(accepted)

            if not await self._whisper_reachable():
                shutil.rmtree(session_dir, ignore_errors=True)
                await self.repository.delete(session_id)
                raise upstream_failure.whisper_unavailable()
        except BaseException:
            await self._end(session_id)
            raise
        return accepted

    async def process(self, parsed: Manifest, session_dir: Path) -> None:
        """Process a session `accept()` returned, in the background.
        `_process_session` persists status itself (memory cache + db row) on
        success; this only handles the crash path. Releases the claim
        `accept()` took, on success or failure."""
        try:
            await self._process_session(parsed, session_dir)
        except Exception:  # pragma: no cover — defensive
            logger.exception("session %s background processing crashed", parsed.session_id)
            await self.repository.mark_failed(parsed.session_id)
        finally:
            await self._end(parsed.session_id)

    async def _process_session(self, parsed: Manifest, session_dir: Path) -> list[SegmentResult]:
        """Two-phase pipeline.

        Phase 1: per-segment Whisper + correction + entity detection. Each
        segment's transcript and entities are persisted independently.

        Phase 2: a single day-level pass (`_narrate_day`) — one LightRAG
        context query, one Ollama analysis, one narrative, one LightRAG ingest
        under `diary:{date}`, over every transcribed segment of every session
        of the date. Only this session's segments become `processed`.
        """
        bind_session_id(parsed.session_id)
        results_by_id: dict[str, SegmentResult] = {}
        artifacts: list[_SegmentArtifact] = []

        # Phase 1 — per segment
        for seg in parsed.segments:
            try:
                artifact = await _process_segment(
                    manifest=parsed,
                    segment=seg,
                    session_dir=session_dir,
                )
                artifacts.append(artifact)
                # Provisional state until phase 2 confirms analysis succeeded.
                results_by_id[seg.segment_id] = SegmentResult(
                    segment_id=seg.segment_id,
                    status="pending_analysis",
                    transcript_id=artifact.transcript_id,
                )
            except Exception as exc:  # noqa: BLE001
                logger.exception(
                    "session %s segment %s failed: %s",
                    parsed.session_id, seg.segment_id, exc,
                )
                results_by_id[seg.segment_id] = SegmentResult(
                    segment_id=seg.segment_id, status="failed", error=str(exc),
                    **upstream_failure.failure_fields(exc),
                )
            await self._persist_phase_1_progress(parsed, results_by_id)

        # Phase 2 — day-level analysis + LightRAG ingest (only if anything
        # transcribed). The input is the whole day, this session included.
        if artifacts:
            try:
                await self._narrate_day(
                    parsed,
                    list(results_by_id.values()),
                    {art.segment.segment_id: art for art in artifacts},
                    republish=False,
                )
                for art in artifacts:
                    results_by_id[art.segment.segment_id] = SegmentResult(
                        segment_id=art.segment.segment_id,
                        status="processed",
                        transcript_id=art.transcript_id,
                    )
            except Exception as exc:  # noqa: BLE001
                logger.warning(
                    "session %s document_processor failed: %s — leaving segments pending",
                    parsed.session_id, exc,
                )
                # Transcripts are already in Postgres; analysis can be retried later.
                for art in artifacts:
                    results_by_id[art.segment.segment_id] = SegmentResult(
                        segment_id=art.segment.segment_id,
                        status="pending_analysis",
                        transcript_id=art.transcript_id,
                        error=f"analysis_pending: {exc}",
                        **upstream_failure.failure_fields(exc),
                    )

        # Preserve manifest segment order in the response.
        results = [results_by_id[seg.segment_id] for seg in parsed.segments]

        await self._persist_status(
            parsed.session_id, derive_session_state(results), results
        )
        return results

    # -- manual retry ------------------------------------------------------

    async def retry(self, session_id: str) -> SessionStatus:
        """Retry a session stuck in `pending_analysis` (issue #52).

        Rebuilds the day narrative input from what's persisted (every
        session's manifest on disk plus each transcribed segment's transcript
        row, not just this session's `pending_analysis` ones) and re-runs the
        shared narrative stage. Segments that never got a transcript are
        resumed from the stored audio (`_resume_untranscribed_segments`,
        BUG-112) and join that input. Only this session's `pending_analysis`
        segments change status. A narrative failure doesn't raise: it
        comes back as segments still `pending_analysis` with an
        `analysis_pending: …` error.

        Raises `SessionNotFound` if the session is unknown, `SessionBusy` if a
        run for it (original ingest, another retry, the startup sweep) is
        already in flight, `SessionNotRetryable` if none of its segments are
        `pending_analysis` or none has a transcript row to narrate, and
        `SessionManifestMissing` if the bundle's manifest is gone. A session
        whose resumed segments all fail is not an error: it is persisted and
        returned `failed`.
        """
        status_obj = await self.status(session_id)
        if status_obj is None:
            raise SessionNotFound()

        if not await self._try_begin(session_id):
            raise SessionBusy()
        try:
            if not _has_pending_analysis(status_obj):
                raise SessionNotRetryable()

            return await self._retry_session_analysis(session_id, status_obj)
        finally:
            await self._end(session_id)

    async def _retry_session_analysis(
        self, session_id: str, status_obj: SessionStatus
    ) -> SessionStatus:
        """Rebuild the day narrative input from what's persisted and re-run
        the narrative stage, completing this session's `pending_analysis`
        segments.

        The manifest (segment order, headers, todos) comes back from the
        on-disk `manifest.json` written at ingest. Each segment's transcript
        (corrected text where present, entities) comes back from its
        `transcripts` row. The narrative covers the whole day, so the
        session's `processed` segments and the other sessions of its date are
        in the input too (`_narrate_day`); only the `pending_analysis`
        segments of `session_id` change status. If analysis already completed
        and saved a document for every transcript of the day but the LightRAG
        ingest failed, we re-ingest that saved narrative instead of
        re-running analysis (`_publish_saved_day`).
        """
        parsed = load_manifest(session_id)

        pending = await _stored_artifacts(
            parsed, [r for r in status_obj.segments if r.status == "pending_analysis"]
        )

        # Decide retryability before any side effect: with no transcript row to
        # narrate and nothing untranscribed to resume, there is no work.
        if not pending and not any(_is_untranscribed(r) for r in status_obj.segments):
            raise SessionNotRetryable()

        segment_results, resumed = await self._resume_untranscribed_segments(
            session_id, parsed, status_obj
        )
        retried = pending + resumed

        if not retried:
            # Every segment that was resumed failed: nothing to narrate, but
            # the outcome is settled, not an error.
            await self._persist_status(
                session_id, derive_session_state(segment_results), segment_results
            )
            return await self._current_status(session_id)

        retried_ids = {art.segment.segment_id for art in retried}
        try:
            await self._narrate_day(
                parsed,
                segment_results,
                {art.segment.segment_id: art for art in retried},
                republish=True,
            )
        except Exception as exc:  # noqa: BLE001
            # Same handling as `_process_session`: the transcripts are safe in
            # Postgres, so keep the segments `pending_analysis` (retryable
            # again) and report that status rather than a 500. The sweep logs
            # it per session; the route returns it to the caller.
            updated_segments = [
                SegmentResult(
                    segment_id=r.segment_id,
                    status="pending_analysis",
                    transcript_id=r.transcript_id,
                    error=f"analysis_pending: {exc}",
                    **upstream_failure.failure_fields(exc),
                )
                if r.segment_id in retried_ids
                else r
                for r in segment_results
            ]
        else:
            updated_segments = [
                SegmentResult(segment_id=r.segment_id, status="processed", transcript_id=r.transcript_id)
                if r.segment_id in retried_ids
                else r
                for r in segment_results
            ]
        new_state = derive_session_state(updated_segments)
        await self._persist_status(session_id, new_state, updated_segments)
        return await self._current_status(session_id)

    async def _resume_untranscribed_segments(
        self, session_id: str, parsed: Manifest, status_obj: SessionStatus
    ) -> tuple[list[SegmentResult], list[_SegmentArtifact]]:
        """Run phase 1 from the stored bundle for every `pending_analysis`
        segment that has no transcript (BUG-112): the process died, or the
        upload was cut off, before its transcript was persisted.

        Returns the session's segment results with each resumed segment
        updated, plus the resumed segments' artifacts. A segment that can't be
        transcribed is `failed` with the reason (audio gone from disk, the
        segment missing from the manifest, an upstream error), as in the
        original ingest. Each outcome is persisted as it lands, so a second
        crash keeps the transcript IDs already saved.
        """
        bind_session_id(session_id)
        segments_by_id = {seg.segment_id: seg for seg in parsed.segments}
        session_dir = session_dir_for(session_id)
        results = list(status_obj.segments)
        artifacts: list[_SegmentArtifact] = []
        for index, current in enumerate(results):
            if not _is_untranscribed(current):
                continue
            segment = segments_by_id.get(current.segment_id)
            try:
                if segment is None:
                    raise LookupError(f"segment {current.segment_id} is not in manifest.json")
                artifact = await _process_segment(
                    manifest=parsed, segment=segment, session_dir=session_dir
                )
            except Exception as exc:  # noqa: BLE001
                logger.warning(
                    "session %s segment %s could not be resumed: %s",
                    session_id, current.segment_id, exc,
                )
                results[index] = SegmentResult(
                    segment_id=current.segment_id, status="failed", error=str(exc),
                    **upstream_failure.failure_fields(exc),
                )
            else:
                artifacts.append(artifact)
                results[index] = SegmentResult(
                    segment_id=current.segment_id,
                    status="pending_analysis",
                    transcript_id=artifact.transcript_id,
                )
            await self._persist_status(session_id, status_obj.state, list(results))
        return results, artifacts

    # -- startup sweep -----------------------------------------------------

    async def sweep(self) -> None:
        """Best-effort startup sweep (issue #52).

        Retries every non-`done` session with a `pending_analysis` segment
        (legacy `done` rows that still have one are first corrected to
        `partial`, BUG-114/#114), one at a time (bounded by the sessions table, sequential so a heavy analysis
        call doesn't pile up concurrently with others). Also picks up
        sessions left `processing` by a prior process (BUG-53/#53); sessions
        active in this process hold the in-flight claim and are skipped. A
        session's retry failing is logged and left `pending_analysis` — the
        manual retry route, or the next startup, can pick it up again. Must
        never raise, since `main.py`'s lifespan runs this without blocking app
        start.
        """
        try:
            corrected = await self.repository.correct_legacy_done_sessions()
            if corrected:
                logger.info(
                    "startup retry sweep: marked %d legacy done session(s) with pending segments partial",
                    corrected,
                )
        except Exception as exc:  # noqa: BLE001 — best-effort, never blocks the sweep
            logger.warning("startup retry sweep: legacy done-row correction failed: %s", exc)

        try:
            session_ids = await self.repository.list_sweep_candidates()
        except Exception:  # noqa: BLE001 — best-effort, never blocks startup
            logger.exception("startup retry sweep: failed to list pending_analysis sessions")
            return

        for session_id in session_ids:
            if not await self._try_begin(session_id):
                logger.info("startup retry sweep: session %s busy, skipping", session_id)
                continue
            try:
                status_obj = await self.status(session_id)
                if status_obj is None:
                    continue
                # We hold the in-flight claim, so no run in this process owns
                # a `processing` session: it was interrupted, and its segments
                # without a transcript are resumed from the stored audio.
                retried = await self._retry_session_analysis(session_id, status_obj)
            except SessionError as exc:
                # Nothing to retry (no transcripts, manifest gone): an expected
                # outcome for an interrupted session, so one line, no traceback.
                logger.warning(
                    "startup retry sweep: session %s not retryable: %s", session_id, exc.code,
                )
                continue
            except Exception as exc:  # noqa: BLE001 — one session's failure must not stop the rest
                logger.warning("startup retry sweep: session %s retry failed: %s", session_id, exc)
                continue
            finally:
                await self._end(session_id)
            # A narrative failure doesn't raise — it comes back as segments
            # still `pending_analysis` with an `analysis_pending: …` error.
            errors = [
                s.error for s in retried.segments
                if s.status == "pending_analysis" and s.error and s.error.startswith("analysis_pending:")
            ]
            if errors:
                logger.warning(
                    "startup retry sweep: session %s retry failed again, left pending_analysis: %s",
                    session_id, errors[0],
                )


_default: SessionIngest | None = None


def get_session_ingest() -> SessionIngest:
    """The process-wide session ingest the routes and the startup sweep share."""
    global _default
    if _default is None:
        _default = SessionIngest()
    return _default


# --- eligibility ----------------------------------------------------------


def _has_pending_analysis(status_obj: SessionStatus) -> bool:
    """A retry has something to do only for a session with a segment left
    `pending_analysis`."""
    return any(s.status == "pending_analysis" for s in status_obj.segments)


def _is_untranscribed(result: SegmentResult) -> bool:
    """A segment cut off before its transcript was persisted (BUG-112)."""
    return result.status == "pending_analysis" and result.transcript_id is None


# --- day assembly ---------------------------------------------------------


def _session_start_key(session_id: str, received_at: str) -> tuple:
    """Sort key for session start order. A `session_id` is the session start
    timestamp (SPEC §10.6); one that isn't (older or hand-made ids) sorts after
    the others, by upload time then id."""
    try:
        started = datetime.fromisoformat(session_id)
    except ValueError:
        return (1, received_at, session_id)
    if started.tzinfo is None:
        started = started.replace(tzinfo=timezone.utc)
    return (0, started.astimezone(timezone.utc), session_id)


async def _stored_artifacts(
    manifest: Manifest,
    results: list[SegmentResult],
    known: dict[str, _SegmentArtifact] | None = None,
) -> list[_SegmentArtifact]:
    """The transcribed segments among `results`, in manifest order: every
    segment that has a transcript and did not fail, read from its
    `transcripts` row unless `known` already holds its artifact. A segment
    whose row is gone, or that the manifest no longer lists, is left out."""
    by_id = {r.segment_id: r for r in results}
    artifacts: list[_SegmentArtifact] = []
    for segment in manifest.segments:
        result = by_id.get(segment.segment_id)
        if result is None or result.status == "failed" or result.transcript_id is None:
            continue
        artifact = (known or {}).get(segment.segment_id)
        if artifact is None:
            transcript = await db.get_transcript(result.transcript_id)
            if transcript is None:
                continue
            artifact = _SegmentArtifact(
                segment=segment,
                transcript_id=result.transcript_id,
                raw_text=transcript.get("raw_text") or "",
                corrected_text=(
                    transcript.get("corrected_text") or transcript.get("raw_text") or ""
                ),
                # Pre-BUG-55 rows have the pipeline's entities in `entities_json`.
                entities=_parse_entities_json(
                    transcript.get("detected_entities_json") or transcript.get("entities_json")
                ),
            )
        artifacts.append(artifact)
    return artifacts


# --- saved-document republish ---------------------------------------------


async def _publish_saved_day(artifacts: list[_SegmentArtifact]) -> bool:
    """Ingest-only shortcut, keyed by the date: `artifacts` are the whole
    day's transcribed segments.

    If analysis already completed and saved a `processed_documents` row for
    every artifact, the latest rows are all the same day narrative
    (`_analyse_and_publish_day` saves one combined document against every
    transcript of the day), and the LightRAG ingest itself failed (rows
    unmarked), re-ingest that saved narrative rather than re-running analysis.
    A transcript with no saved document yet is new content the saved narrative
    doesn't cover, so that falls through to a fresh analysis.

    Returns `False` (no-op, caller re-analyzes) if any artifact has no saved
    document yet, every document is already marked ingested, or the latest
    documents diverge (e.g. a newer single-segment document from the review
    UI) — ingesting `docs[0]` and marking every row would otherwise record a
    narrative that was never ingested.

    A mix of marked and unmarked rows of the same narrative means a previous
    run ingested it and died part-way through marking: just mark the
    remainder.
    """
    docs: list[dict] = []
    for art in artifacts:
        doc = await db.get_latest_processed_document(art.transcript_id)
        if doc is None:
            return False
        docs.append(doc)

    def _metadata(doc: dict) -> dict:
        metadata = doc["metadata"]
        return json.loads(metadata) if isinstance(metadata, str) else metadata

    narratives = {
        (doc["document_markdown"], json.dumps(_metadata(doc), sort_keys=True))
        for doc in docs
    }
    unmarked = [doc for doc in docs if not doc.get("lightrag_ingested")]
    if len(narratives) != 1 or not unmarked:
        return False

    if len(unmarked) == len(docs):
        await narrative.sync_and_ingest(docs[0]["document_markdown"], _metadata(docs[0]))
    for doc in unmarked:
        await db.mark_document_ingested(doc["id"])
    return True


def _parse_entities_json(raw: object) -> list[dict]:
    if not raw:
        return []
    if isinstance(raw, str):
        return json.loads(raw)
    return raw


# --- per-segment pipeline -------------------------------------------------


async def _process_segment(
    *,
    manifest: Manifest,
    segment: Segment,
    session_dir: Path,
) -> _SegmentArtifact:
    """Per-segment pipeline up to entity detection.

    Returns an artifact with the persisted transcript ID and detected
    entities. Document analysis + LightRAG ingest happen once per session
    in `_analyse_and_publish_day`.
    """
    audio_path = session_dir / segment.audio_file
    if not audio_path.exists():
        raise FileNotFoundError(f"segment audio missing on disk: {segment.audio_file}")
    audio_bytes = audio_path.read_bytes()
    language = (segment.language or "de").split("-")[0]

    # 1-2. ffmpeg → Whisper → persisted transcript row, via the core shared
    # with main.py's /api/ingest/upload (SRV-A7).
    suffix = Path(segment.audio_file).suffix
    transcribed = await transcript_ingest.transcribe_and_persist(
        audio_bytes,
        src_suffix=suffix or ".m4a",
        filename=f"{manifest.session_id}::{segment.segment_id}{suffix}",
        date=manifest.date.isoformat(),
        author="Lukas Brandt",
        language=language,
    )
    transcript_id = transcribed.transcript_id
    raw_transcript = transcribed.raw_text

    # 3-4. Dictionary corrections → vector few-shot LLM correction (falls
    # back to the pre-LLM text on failure) → entity detection → dismissal
    # filtering — the same non-interactive chain the HTMX review flow runs
    # (#51). For calendar_event segments we additionally seed the persons
    # dict with the manifest's canonical attendee names so the detector
    # resolves them deterministically (Graph already gave us the truth — no
    # need to fuzzy-match again).
    snapshot = await dictionary.load_dictionary_snapshot()
    if isinstance(segment, CalendarEventSegment):
        seed_persons = _attendees_to_canonical_names(segment.calendar_ref.attendees)
        if seed_persons:
            snapshot = replace(
                snapshot,
                persons=_seed_persons_into_dict(snapshot.persons, seed_persons),
            )

    result = await correction.correct_and_detect_entities(
        raw_transcript, snapshot=snapshot
    )
    corrected_text = result.corrected_text

    # Convert dataclass instances to dicts in the shape document_processor
    # expects (the HTMX review flow stores `text` for the canonical name).
    entities: list[dict] = []
    for d in result.entities:
        item = d.to_dict()
        item["text"] = d.canonical or d.original_text
        item["type"] = d.entity_type
        entities.append(item)

    # Always persist, even when correction left the text unchanged —
    # otherwise the detected entities are lost and a retry-analysis (#52)
    # rebuilding the session narrative from Postgres would see none. Goes to
    # `detected_entities_json`, not `save_draft`: status='saved' and
    # `entities_json` are reserved for human review (BUG-55), and the review
    # page skips SSE processing for transcripts that carry them.
    await db.save_detected_entities(transcript_id, corrected_text, json.dumps(entities))

    return _SegmentArtifact(
        segment=segment,
        transcript_id=transcript_id,
        raw_text=raw_transcript,
        corrected_text=corrected_text,
        entities=entities,
    )


def _attendees_to_canonical_names(attendees: list[str]) -> list[str]:
    """Strip emails to local-parts and Title-case for the entity seed list."""
    out: list[str] = []
    for entry in attendees:
        local = entry.split("@", 1)[0].strip()
        if not local:
            continue
        # `firstname.lastname` → `Firstname Lastname`
        cleaned = re.sub(r"[._]+", " ", local).strip()
        cleaned = " ".join(part.capitalize() for part in cleaned.split() if part)
        if cleaned:
            out.append(cleaned)
    return out


def _seed_persons_into_dict(
    persons_dict: list[dict], seed_names: list[str]
) -> list[dict]:
    """Ensure each calendar attendee appears in the persons dict so the
    detector resolves them on Pass 1 (exact match)."""
    existing = {(p.get("canonical_name") or "").lower() for p in persons_dict}
    augmented = list(persons_dict)
    for name in seed_names:
        if name.lower() in existing:
            continue
        first = name.split()[0] if name.split() else ""
        augmented.append({
            "id": None,
            "canonical_name": name,
            "first_name": first,
            "role": "",
            "department": "",
            "company": "",
            "context": "",
            "variations": [],
        })
        existing.add(name.lower())
    return augmented


# --- session narrative ----------------------------------------------------


def _todos_grouped_by_segment(manifest: Manifest) -> dict[str, list[Todo]]:
    grouped: dict[str, list[Todo]] = {}
    for seg in manifest.segments:
        if isinstance(seg, CalendarEventSegment):
            grouped.setdefault(seg.segment_id, []).extend(seg.todos_detected)
    for todo in manifest.todos_implicit_confirmed:
        if todo.source_segment_id:
            grouped.setdefault(todo.source_segment_id, []).append(todo)
    return grouped


def _session_todos(session: _DaySession) -> list[Todo]:
    """One session's todos for the day narrative: those of its transcribed
    segments, plus its implicit-confirmed todos that have no source segment
    (the day's narrative captures them too)."""
    todos: list[Todo] = []
    seen_ids = {art.segment.segment_id for art in session.artifacts}
    for segment_id, segment_todos in _todos_grouped_by_segment(session.manifest).items():
        if segment_id in seen_ids:
            todos.extend(segment_todos)
    for todo in session.manifest.todos_implicit_confirmed:
        if not todo.source_segment_id:
            todos.append(todo)
    return todos


def _format_todo_block(todos: list[Todo]) -> str:
    """Render todos as a German prose block appended to the narrative."""
    if not todos:
        return ""
    lines = ["", "## Offene Punkte"]
    for todo in todos:
        due = f" (fällig {todo.due})" if todo.due else ""
        lines.append(f"- {todo.text} — Status: {todo.status}{due}")
    return "\n".join(lines)


async def _analyse_and_publish_day(date_str: str, day: list[_DaySession]) -> None:
    """Run the shared narrative stage once for the whole day, then the
    day-specific parts around it. Called while the date is held.

    Concatenates every transcribed segment of the day (session start order,
    then manifest order, with per-segment headers so the analysis LLM can
    still reason about meeting boundaries), unions the detected entities, and
    delegates context → summary → analysis → narrative markdown → metadata to
    `narrative.build_day_narrative` (the same stage `main.py`'s SSE review
    flow uses — SRV-A1/#50). The todo block and the multi-transcript save stay
    day-specific, since the SSE path has neither.

    The day narrative is saved as a `processed_documents` row against every
    transcript it covers before it is published, so a failed LightRAG ingest
    leaves it saved and unpublished (`_publish_saved_day` re-ingests it
    later) and any transcript-id-keyed read path keeps working. Each of those
    rows is marked `lightrag_ingested` once the LightRAG ingest succeeds —
    mirroring `main.py`'s manual `/api/documents/{id}/ingest` route — so
    `/process/{id}` doesn't show an already-ingested day as pending and the
    re-ingest button doesn't re-post it. The ingest re-posts the fixed id
    `diary:{date}`, which LightRAG replaces (SPEC §10.6.1).
    """
    artifacts = [art for session in day for art in session.artifacts]
    combined_text = _build_combined_transcript(artifacts)
    merged_entities = _merge_entities([art.entities for art in artifacts])

    # Trust boundary: `combined_text` is transcribed speech (untrusted
    # input) flowing into Ollama, and `analysis`/`markdown` are its
    # unvalidated output — a prompt-injection surface into the
    # knowledge-graph narrative. Accepted risk for a single-user tool
    # (no other reader of the LightRAG-ingested markdown); see SEC-6 /
    # docs/REVIEW-2026-07-04.md. Unlike `harvest_llm.extract_work_activities`,
    # this path has no structured fields (category, hours, ...) to
    # allowlist or bound — it's freeform narrative markdown end to end.
    result = await narrative.build_day_narrative(combined_text, merged_entities, date_str)

    markdown = result.markdown
    todo_block = _format_todo_block([todo for session in day for todo in _session_todos(session)])
    if todo_block:
        markdown = f"{markdown.rstrip()}\n{todo_block}\n"

    # Save the combined document against every segment's transcript so any
    # transcript-id-keyed read path returns the canonical day narrative.
    doc_ids: list[int] = []
    for art in artifacts:
        saved = await db.save_processed_document(
            transcript_id=art.transcript_id,
            document_markdown=markdown,
            analysis_json=result.analysis,
            context_summary=result.context_summary,
            metadata=result.metadata,
        )
        doc_ids.append(saved["id"])

    await narrative.sync_and_ingest(markdown, result.metadata)

    # Only reached once ingest succeeds — a failure above propagates to the
    # caller, which leaves these rows unmarked and the segments
    # `pending_analysis` so they stay retryable.
    for doc_id in doc_ids:
        await db.mark_document_ingested(doc_id)


def _build_combined_transcript(artifacts: list[_SegmentArtifact]) -> str:
    """Concatenate all transcribed segments with German per-segment headers.

    The headers preserve enough context (meeting title, time range,
    attendees) for `analyze_transcript` to attribute relationships and
    decisions to the right block, even though the LLM now sees one combined
    text instead of one per call.
    """
    blocks: list[str] = []
    for art in artifacts:
        text = (art.corrected_text or "").strip()
        if not text:
            continue
        header = _segment_header(art.segment)
        blocks.append(f"{header}\n\n{text}")
    return "\n\n".join(blocks)


def _segment_header(segment: Segment) -> str:
    if isinstance(segment, CalendarEventSegment):
        ref = segment.calendar_ref
        title = (ref.title or "Termin").strip()
        time_range = _format_time_range(ref.start, ref.end)
        attendees = _attendees_to_canonical_names(ref.attendees)
        attendee_str = (
            f", Teilnehmer: {', '.join(attendees)}" if attendees else ""
        )
        return f"## Termin: {title}{time_range}{attendee_str}"
    if isinstance(segment, DriveBySegment):
        time_str = _extract_hhmm(segment.captured_at)
        return f"## Notiz unterwegs{(' um ' + time_str) if time_str else ''}"
    if isinstance(segment, FreeReflectionSegment):
        time_str = _extract_hhmm(segment.captured_at) if segment.captured_at else ""
        return f"## Freie Reflexion{(' um ' + time_str) if time_str else ''}"
    if isinstance(segment, EmptyBlockSegment):
        return f"## Zeitblock {segment.time_range.start}–{segment.time_range.end}"
    return f"## Abschnitt {segment.segment_id}"


def _format_time_range(start: str, end: str) -> str:
    s = _extract_hhmm(start)
    e = _extract_hhmm(end)
    if s and e:
        return f" ({s}–{e})"
    if s:
        return f" (ab {s})"
    return ""


_HHMM_RE = re.compile(r"\b(\d{2}):(\d{2})\b")


def _extract_hhmm(value: str | None) -> str:
    if not value:
        return ""
    m = _HHMM_RE.search(value)
    if not m:
        return ""
    return f"{m.group(1)}:{m.group(2)}"


def _merge_entities(per_segment: list[list[dict]]) -> list[dict]:
    """Union entities across segments, deduplicated by (type, lowercase name).

    First occurrence wins so we keep whatever role/company metadata the
    detector attached on first sight.
    """
    seen: set[tuple[str, str]] = set()
    merged: list[dict] = []
    for entities in per_segment:
        for ent in entities:
            ent_type = (ent.get("type") or ent.get("entity_type") or "").upper()
            name = (ent.get("text") or ent.get("canonical") or "").strip().lower()
            if not name:
                continue
            key = (ent_type, name)
            if key in seen:
                continue
            seen.add(key)
            merged.append(ent)
    return merged
