"""Session ingest (ARCH-2, REF-126): the lifecycle of an uploaded session
bundle, see "Session ingest" in CONTEXT.md.

The one server seam behind the ways a session gets processed. Its interface
is `SessionIngest`:

* **accept** — `accept()` claims the session and persists its `processing`
  row; `process()` then runs the two-phase pipeline in the background;
* **retry** — `retry()` re-runs the narrative stage for the segments left
  `pending_analysis`, resuming the ones that never got a transcript;
* **recovery** — `recover()` transcribes one `failed` segment again from its
  retained audio, on request only (FTR-02, ADR 0005, 0007): it validates,
  claims the session, persists the segment `transcribing` and runs the attempt
  on its own, `settled()` waiting for it;
* **sweep** — `sweep()` first settles the recoveries a restart interrupted
  (FTR-03: a saved transcript makes the segment `pending_analysis`, none makes
  it `failed` as `recovery_interrupted`; Whisper is never called), removes the
  session transcripts no segment references (FTR-06), then retries every
  stranded session once after a restart;
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
disk and reading its manifest back, and the narrative persistence. The
per-segment operation is `segment_ingest.SegmentIngest` (ARCH-3), supplied to
each `SessionIngest` and run for both the original ingest and the resume of a
stored bundle.

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
in-memory repository and their own segment operation.
"""

from __future__ import annotations

import asyncio
import json
import logging
import re
import shutil
from contextlib import asynccontextmanager
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import AsyncIterator, Awaitable, Callable

import asr_client
import db
import narrative
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
from segment_ingest import (
    SegmentArtifact,
    SegmentIngest,
    SegmentOperation,
    attendees_to_canonical_names,
    transcript_filename,
)
from session_repository import PostgresSessionIngests, SessionIngestRepository

logger = logging.getLogger(__name__)

# The failure code of a recovery a restart interrupted before it saved a transcript.
RECOVERY_INTERRUPTED = "recovery_interrupted"


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


class SegmentNotFound(SessionError):
    """The session has no segment with that id."""

    code = "segment_not_found"


class SegmentNotFailed(SessionError):
    """Only a `failed` segment is recovered: a `processed`, `pending_analysis`
    or already `transcribing` one is left alone."""

    code = "segment_not_failed"


class SegmentAudioMissing(SessionError):
    """The segment's manifest entry or its retained audio is gone, so it can't
    be transcribed again."""

    code = "segment_audio_missing"


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
    """`processing` while any segment is `transcribing` (a recovery runs),
    `done` only when every segment is `processed`, `failed` when every one
    failed, otherwise `partial` — including any `pending_analysis` segment
    (BUG-114/#114)."""
    if any(r.status == "transcribing" for r in results):
        return "processing"
    if all(r.status == "processed" for r in results):
        return "done"
    if all(r.status == "failed" for r in results):
        return "failed"
    return "partial"


@dataclass
class _DaySession:
    """One session's contribution to a day narrative: its manifest (for the
    todos) and its transcribed segments in manifest order."""

    manifest: Manifest
    artifacts: list[SegmentArtifact]


# --- lifecycle ------------------------------------------------------------


class SessionIngest:
    """Owns session status and runs the ingest lifecycle.

    `whisper_reachable` is the pre-flight used by `accept()`; Whisper is the
    one upstream a session can't work around. `repository` holds the status
    cache and the persisted `session_ingests` rows (SRV-A6, REF-122): the
    Postgres adapter unless a test passes another. `segment_operation` is
    what runs for each segment, in the original ingest and when a retry
    resumes a stored bundle (ARCH-3): a `SegmentIngest` over the shared
    modules unless a test passes another, which then also serves a
    transcription recovery (`SegmentIngest.recover` otherwise).
    """

    def __init__(
        self,
        *,
        whisper_reachable: Callable[[], Awaitable[bool]] = _asr_reachable,
        repository: SessionIngestRepository | None = None,
        segment_operation: SegmentOperation | None = None,
    ) -> None:
        self._whisper_reachable = whisper_reachable
        segment_ingest = SegmentIngest()
        self._segment_operation: SegmentOperation = (
            segment_operation if segment_operation is not None else segment_ingest.ingest
        )
        self._recovery_operation: SegmentOperation = (
            segment_operation if segment_operation is not None else segment_ingest.recover
        )
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
        # Running recovery attempts. They belong to the server, not to the
        # request that started them, so a client leaving never stops one.
        self._recoveries: set[asyncio.Task] = set()
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
        repopulates the cache from it. Failed segments carry `recoverable`."""
        stored = await self.repository.get(session_id)
        return None if stored is None else _with_recoverable(session_id, stored)

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

        Recoveries are stopped first, so none can save a transcript after the
        tables were cleared; a recovery requested meanwhile waits at the gate
        until the reset is done and then finds no session.

        `_resetting` is cleared on every exit, including cancellation while
        waiting for the uploads to drain; otherwise every later upload and
        reset would wait forever."""
        async with self._gate:
            await self._gate.wait_for(lambda: not self._resetting)
            self._resetting = True
        try:
            async with self._gate:
                await self._gate.wait_for(lambda: self._uploads_inside == 0)
            await _finish_despite_cancellation(
                asyncio.ensure_future(self._stop_recoveries_and_clear())
            )
        finally:
            self._resetting = False
            await self._wake_gate_waiters()

    async def _stop_recoveries_and_clear(self) -> None:
        """Both steps as one unit the caller's cancellation cannot split:
        stopping recoveries and then not clearing would leave their segments
        `transcribing` with no attempt."""
        await self._stop_recoveries()
        await self._clear_everything()

    async def _stop_recoveries(self) -> None:
        """Cancel every recovery being accepted or attempted and wait until
        none is left. Called with `_resetting` set, so no new one can pass the
        gate while this runs."""
        while self._recoveries:
            stopping = list(self._recoveries)
            for task in stopping:
                task.cancel()
            await asyncio.gather(*stopping, return_exceptions=True)

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
        known: dict[str, SegmentArtifact],
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
        known: dict[str, SegmentArtifact],
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
        artifacts: list[SegmentArtifact] = []

        # Phase 1 — per segment
        for seg in parsed.segments:
            try:
                artifact = await self._segment_operation(
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
        status_obj = await self.repository.get(session_id)
        if status_obj is None:
            raise SessionNotFound()

        if not await self._try_begin(session_id):
            raise SessionBusy()
        try:
            if not _has_pending_analysis(status_obj):
                raise SessionNotRetryable()

            retried = await self._retry_session_analysis(session_id, status_obj)
            return _with_recoverable(session_id, retried)
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
    ) -> tuple[list[SegmentResult], list[SegmentArtifact]]:
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
        artifacts: list[SegmentArtifact] = []
        for index, current in enumerate(results):
            if not _is_untranscribed(current):
                continue
            segment = segments_by_id.get(current.segment_id)
            try:
                if segment is None:
                    raise LookupError(f"segment {current.segment_id} is not in manifest.json")
                artifact = await self._segment_operation(
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

    # -- transcription recovery --------------------------------------------

    async def recover(self, session_id: str, segment_id: str) -> SessionStatus:
        """Start the transcription recovery of a `failed` segment (FTR-02,
        ADR 0005 and 0007) and return the status with the segment
        `transcribing`. The attempt then runs on its own, whether or not the
        caller stays: transcript and entities, then the day narrative.

        The checks run in order and change nothing until all pass: `404` for an
        unknown session (`SessionNotFound`) or segment (`SegmentNotFound`),
        `SegmentNotFailed` for any other status, `SegmentAudioMissing` without
        its manifest entry or audio, `upstream_failure.whisper_unavailable()`
        when Whisper is down, `SessionBusy` when another run holds the session.
        The state-dependent checks are repeated under the claim.

        The attempt reuses the per-segment operation for this one segment and
        changes no other segment. Its outcome is the segment's status:
        `pending_analysis` once its transcript and entities are saved, then
        `processed`; `failed` with the latest error when transcription fails;
        still `pending_analysis` with an `analysis_pending: …` error when only
        the narrative fails, which the analysis retry then finishes.
        """
        stored = await self.repository.get(session_id)
        if stored is None:
            raise SessionNotFound()
        _check_recoverable(session_id, stored, segment_id)
        if not await self._whisper_reachable():
            raise upstream_failure.whisper_unavailable()
        # From the claim on, accepting is its own task: a caller that is
        # cancelled meanwhile (a client leaving) cannot interrupt it between
        # persisting `transcribing` and starting the attempt, which would
        # strand the segment. It then either completes, or fails and rolls
        # back; either way the claim is released or handed to the attempt.
        accepting = asyncio.ensure_future(self._accept_recovery(session_id, segment_id))
        self._track_recovery(accepting)
        try:
            accepted = await asyncio.shield(accepting)
        except asyncio.CancelledError:
            # Cancelled by a data reset that is clearing the sessions (not by
            # this caller leaving): the session is gone as far as it is concerned.
            current = asyncio.current_task()
            if accepting.cancelled() and current is not None and not current.cancelling():
                raise SessionNotFound() from None
            raise
        return _with_recoverable(session_id, accepted)

    async def _accept_recovery(self, session_id: str, segment_id: str) -> SessionStatus:
        """Claim the session, repeat the state checks under the claim, persist
        the segment `transcribing` and start the attempt, which then owns the
        claim. Without an attempt started the claim is released. Waits first
        while a data reset runs, then finds the session gone."""
        async with self._gate:
            await self._gate.wait_for(lambda: not self._resetting)
        if not await self._try_begin(session_id):
            raise SessionBusy()
        previous: tuple[str, list[SegmentResult]] | None = None
        try:
            stored = await self.repository.get(session_id)
            if stored is None:
                raise SessionNotFound()
            _check_recoverable(session_id, stored, segment_id)
            previous = (stored.state, list(stored.segments))
            segments = [
                SegmentResult(segment_id=segment_id, status="transcribing")
                if r.segment_id == segment_id
                else r
                for r in stored.segments
            ]
            await self._persist_status(session_id, derive_session_state(segments), segments)
            # A copy: the attempt starts changing the cached status at once.
            accepted = (await self._current_status(session_id)).model_copy(deep=True)
        except BaseException:
            if previous is not None:
                # The write-through may have reached the cache or the row
                # before failing: put the stored status back, so no segment is
                # left `transcribing` without an attempt.
                try:
                    await self._persist_status(session_id, *previous)
                except Exception:  # noqa: BLE001
                    logger.exception(
                        "session %s: could not restore the status after a refused recovery",
                        session_id,
                    )
            await self._end(session_id)
            raise
        started: list[bool] = []

        async def attempt() -> None:
            started.append(True)
            await self._run_recovery(session_id, segment_id)

        task = asyncio.create_task(attempt())
        # A started attempt releases the claim itself when it ends. One that is
        # cancelled before its first step never runs that, so the claim is
        # released here; only then, or it could release a later run's claim.
        task.add_done_callback(
            lambda _task: None if started else self._in_flight.discard(session_id)
        )
        self._track_recovery(task)
        return accepted

    def _track_recovery(self, task: asyncio.Task) -> None:
        self._recoveries.add(task)
        task.add_done_callback(self._forget_recovery)

    def _forget_recovery(self, task: asyncio.Task) -> None:
        self._recoveries.discard(task)
        if not task.cancelled():
            task.exception()  # mark it retrieved; a caller that stayed got it already

    async def settled(self) -> None:
        """Wait until no recovery is being accepted or attempted."""
        while self._recoveries:
            await asyncio.gather(*self._recoveries, return_exceptions=True)

    async def _run_recovery(self, session_id: str, segment_id: str) -> None:
        """The background attempt `recover()` started: releases the claim it
        holds on every exit and settles the segment even if the attempt
        itself breaks, so a segment never stays `transcribing`."""
        bind_session_id(session_id)
        try:
            await self._recover_segment(session_id, segment_id)
        except Exception as exc:  # noqa: BLE001
            logger.exception("session %s segment %s recovery crashed", session_id, segment_id)
            try:
                await self._settle_segment(session_id, _failed_result(segment_id, exc))
            except Exception:  # noqa: BLE001
                logger.exception(
                    "session %s segment %s could not be settled", session_id, segment_id
                )
        finally:
            await self._end(session_id)

    async def _recover_segment(self, session_id: str, segment_id: str) -> None:
        try:
            manifest = load_manifest(session_id)
            segment = next((s for s in manifest.segments if s.segment_id == segment_id), None)
            if segment is None:
                raise LookupError(f"segment {segment_id} is not in manifest.json")
            artifact = await self._recovery_operation(
                manifest=manifest, segment=segment, session_dir=session_dir_for(session_id)
            )
        except Exception as exc:  # noqa: BLE001
            logger.warning("session %s segment %s recovery failed: %s", session_id, segment_id, exc)
            await self._settle_segment(session_id, _failed_result(segment_id, exc))
            return

        linked = SegmentResult(
            segment_id=segment_id, status="pending_analysis", transcript_id=artifact.transcript_id
        )
        try:
            results = await self._settle_segment(session_id, linked)
        except BaseException:
            # The transcript is saved but the segment cannot be linked to it:
            # drop the row rather than leave one nothing refers to.
            await self._discard_transcript(session_id, segment_id, artifact.transcript_id)
            raise
        if results is None:
            # The session is gone (forgotten while the attempt ran): there is
            # nothing to link the saved transcript to.
            await self._discard_transcript(session_id, segment_id, artifact.transcript_id)
            return

        # From here the segment is linked to its saved transcript. Nothing that
        # goes wrong may turn it back into `failed` (its row would be an
        # orphan): the worst outcome is that it stays `pending_analysis`, which
        # the existing retry finishes.
        try:
            final = await self._narrate_recovered(manifest, results, artifact)
            await self._settle_segment(session_id, final)
        except Exception:  # noqa: BLE001
            logger.exception(
                "session %s segment %s: its outcome could not be saved; leaving it "
                "pending_analysis with transcript %s",
                session_id, segment_id, artifact.transcript_id,
            )
            try:
                await self._settle_segment(session_id, linked)
            except Exception:  # noqa: BLE001
                logger.exception(
                    "session %s segment %s: the stored status may be out of date; the "
                    "persisted row still links transcript %s",
                    session_id, segment_id, artifact.transcript_id,
                )

    async def _narrate_recovered(
        self, manifest: Manifest, results: list[SegmentResult], artifact: SegmentArtifact
    ) -> SegmentResult:
        """Run the day narrative for a recovered segment and return its outcome:
        `processed`, or `pending_analysis` with the `analysis_pending: …` error
        when the narrative or the LightRAG ingest fails."""
        segment_id = artifact.segment.segment_id
        try:
            await self._narrate_day(manifest, results, {segment_id: artifact}, republish=False)
        except Exception as exc:  # noqa: BLE001
            logger.warning(
                "session %s segment %s recovered but analysis failed: %s — leaving it pending",
                manifest.session_id, segment_id, exc,
            )
            return SegmentResult(
                segment_id=segment_id,
                status="pending_analysis",
                transcript_id=artifact.transcript_id,
                error=f"analysis_pending: {exc}",
                **upstream_failure.failure_fields(exc),
            )
        return SegmentResult(
            segment_id=segment_id, status="processed", transcript_id=artifact.transcript_id
        )

    async def _discard_transcript(
        self, session_id: str, segment_id: str, transcript_id: int
    ) -> None:
        """Best effort, and shielded so a cancellation cannot cut it short. A
        row that stays (the database is down) is logged by id and replaced in
        place by the next recovery attempt, never duplicated."""
        try:
            await asyncio.shield(db.delete_transcripts([transcript_id]))
        except Exception:  # noqa: BLE001
            logger.error(
                "session %s segment %s: transcript %s could not be deleted after a failed "
                "recovery; the next attempt replaces it",
                session_id, segment_id, transcript_id,
            )

    async def _settle_segment(
        self, session_id: str, result: SegmentResult
    ) -> list[SegmentResult] | None:
        """Persist `result` as its segment's status, leave every other segment
        as stored, and re-derive the session state. `None` when the session is
        gone (a data reset landed mid-run)."""
        current = await self.repository.get(session_id)
        if current is None:
            return None
        segments = [result if r.segment_id == result.segment_id else r for r in current.segments]
        await self._persist_status(session_id, derive_session_state(segments), segments)
        return segments

    # -- interrupted recoveries --------------------------------------------

    async def settle_interrupted_recoveries(self) -> None:
        """Settle every segment left `transcribing` by a process that died
        mid-recovery (FTR-03, ADR 0005 and 0007), from what is stored and
        without calling Whisper: with a transcript and its entities saved the
        segment becomes `pending_analysis` with its `transcript_id` (the sweep
        then analyses it); without one it is `failed` with
        `recovery_interrupted` and waits for the user's next request. The
        session `state` is re-derived. A session whose run is active in this
        process holds the claim and is skipped, since its attempt is alive.

        A session that cannot be settled is logged and left as it is for the
        next startup; the others still are. Never raises, and runs before the
        sweep lists its candidates.
        """
        try:
            sessions = await self.repository.list_sessions()
        except Exception:  # noqa: BLE001 — best-effort, never blocks startup
            logger.exception("startup recovery reconciliation: failed to list sessions")
            return
        for session in sessions:
            if not any(s.status == "transcribing" for s in session.segments):
                continue
            try:
                await self._settle_interrupted_session(session.session_id)
            except Exception as exc:  # noqa: BLE001 — one session must not stop the rest
                logger.warning(
                    "startup recovery reconciliation: session %s could not be settled: %s",
                    session.session_id, exc,
                )

    async def _settle_interrupted_session(self, session_id: str) -> None:
        if not await self._try_begin(session_id):
            logger.info(
                "startup recovery reconciliation: session %s busy, skipping", session_id
            )
            return
        try:
            bind_session_id(session_id)
            stored = await self.repository.get(session_id)
            if stored is None:
                return
            segments = list(stored.segments)
            for index, current in enumerate(segments):
                if current.status != "transcribing":
                    continue
                transcript_id = await _saved_recovery_transcript(session_id, current.segment_id)
                segments[index] = _interrupted_result(current.segment_id, transcript_id)
                logger.info(
                    "startup recovery reconciliation: session %s segment %s -> %s",
                    session_id, current.segment_id, segments[index].status,
                )
            await self._persist_status(session_id, derive_session_state(segments), segments)
        finally:
            await self._end(session_id)

    # -- orphan transcripts ------------------------------------------------

    async def remove_orphan_transcripts(self) -> None:
        """Delete the transcript rows of session segments that no segment
        references (FTR-06, SPEC §10.6.1): what an ingest or a recovery saved
        before its process died and before the segment was linked to it. Logs
        each deleted id and the count; a pass with no orphans changes nothing.

        Only a row named for a session's segment
        (`{session_id}::{segment}.m4a`) can be an orphan: transcripts the
        review UI or a manual upload created belong to no session and are
        never touched. A row is referenced when any session's segment holds
        its id, whichever session the row is named for. A row named for a
        session that has no row any more is an orphan too, since no segment can
        reference it. A persisted session is looked at under its in-flight
        claim, so a run that is saving a transcript meanwhile is never raced;
        a busy session is skipped, and so is one that still has a
        `transcribing` segment (the reconciliation could not settle it, its
        saved row may be the one to link next startup). A failing delete or
        session is logged, the others still run. Never raises, and runs after
        `settle_interrupted_recoveries`.
        """
        try:
            # Transcripts first: a run saves its session's row before any
            # transcript, so every listed transcript's session is listed below.
            transcripts = await db.list_transcripts()
            sessions = await self.repository.list_sessions()
        except Exception:  # noqa: BLE001 — best-effort, never blocks startup
            logger.exception("startup recovery reconciliation: failed to list transcripts")
            return
        referenced = {
            s.transcript_id for session in sessions for s in session.segments
            if s.transcript_id is not None
        }
        persisted = {session.session_id for session in sessions}
        by_session: dict[str, list[dict]] = {}
        for transcript in transcripts:
            owner = _segment_transcript_session(transcript["filename"])
            if owner is not None and transcript["id"] not in referenced:
                by_session.setdefault(owner, []).append(transcript)
        removed = 0
        for owner, candidates in by_session.items():
            try:
                if owner in persisted:
                    removed += await self._remove_orphans_of_session(owner, candidates, referenced)
                else:
                    removed += await _delete_orphans(candidates)
            except Exception as exc:  # noqa: BLE001 — one session must not stop the rest
                logger.warning(
                    "startup recovery reconciliation: session %s orphan transcripts "
                    "could not be removed: %s", owner, exc,
                )
        if removed:
            logger.info("startup recovery reconciliation: removed %d orphan transcript(s)", removed)

    async def _remove_orphans_of_session(
        self, session_id: str, candidates: list[dict], referenced: set[int]
    ) -> int:
        """The number of rows removed from `candidates`, the session's
        unreferenced transcript rows as listed before its claim was taken and
        re-checked against what the session holds now."""
        if not await self._try_begin(session_id):
            logger.info(
                "startup recovery reconciliation: session %s busy, orphan transcripts kept",
                session_id,
            )
            return 0
        try:
            stored = await self.repository.get(session_id)
            if stored is None:
                return 0
            if any(s.status == "transcribing" for s in stored.segments):
                logger.info(
                    "startup recovery reconciliation: session %s not settled, "
                    "orphan transcripts kept", session_id,
                )
                return 0
            current = referenced | {s.transcript_id for s in stored.segments}
            return await _delete_orphans([t for t in candidates if t["id"] not in current])
        finally:
            await self._end(session_id)

    # -- startup sweep -----------------------------------------------------

    async def sweep(self) -> None:
        """Best-effort startup sweep (issue #52).

        First settles the recoveries a restart interrupted
        (`settle_interrupted_recoveries`, FTR-03), so the sweep never sees a
        `transcribing` segment and never calls Whisper for one, then removes
        the session transcripts no segment references
        (`remove_orphan_transcripts`, FTR-06).

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
        await self.settle_interrupted_recoveries()
        await self.remove_orphan_transcripts()

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
                status_obj = await self.repository.get(session_id)
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


def _failed_result(segment_id: str, exc: BaseException) -> SegmentResult:
    return SegmentResult(
        segment_id=segment_id, status="failed", error=str(exc),
        **upstream_failure.failure_fields(exc),
    )


def _segment_transcript_session(filename: str) -> str | None:
    """The session a transcript row is named for, when its file name is a
    session segment's (`segment_ingest.transcript_filename`); None for any
    other transcript."""
    session_id, separator, segment = filename.partition("::")
    return session_id if session_id and separator and segment else None


async def _delete_orphans(orphans: list[dict]) -> int:
    """Delete these transcript rows one by one, logging each id; a row that
    cannot be deleted is logged and the others still are. Returns how many
    were deleted."""
    removed = 0
    for transcript in orphans:
        try:
            await db.delete_transcripts([transcript["id"]])
        except Exception as exc:  # noqa: BLE001 — one row must not stop the rest
            logger.warning(
                "startup recovery reconciliation: orphan transcript %s could not be "
                "removed: %s", transcript["id"], exc,
            )
            continue
        removed += 1
        logger.info(
            "startup recovery reconciliation: removed orphan transcript %s (%s)",
            transcript["id"], transcript["filename"],
        )
    return removed


async def _saved_recovery_transcript(session_id: str, segment_id: str) -> int | None:
    """The id of the transcript (with its entities) a recovery of this segment
    saved before it was interrupted, or None. Without a readable manifest
    entry there is nothing it could have been saved under. A failing database
    lookup raises: the segment is then not settled, never guessed."""
    try:
        manifest = load_manifest(session_id)
    except Exception as exc:  # noqa: BLE001 — nothing to look up without it
        logger.warning(
            "session %s: manifest unreadable, no saved transcript to look for: %s", session_id, exc
        )
        return None
    segment = next((s for s in manifest.segments if s.segment_id == segment_id), None)
    if segment is None:
        return None
    return await db.find_recovered_transcript(
        filename=transcript_filename(manifest, segment), date=manifest.date.isoformat()
    )


def _interrupted_result(segment_id: str, transcript_id: int | None) -> SegmentResult:
    """A `transcribing` segment's settled status after a restart: linked to
    its saved transcript, or `failed` as `recovery_interrupted` (no upstream,
    retryable, SPEC §10.6.1)."""
    if transcript_id is not None:
        return SegmentResult(
            segment_id=segment_id, status="pending_analysis", transcript_id=transcript_id
        )
    return SegmentResult(
        segment_id=segment_id,
        status="failed",
        error="transcription was interrupted by a server restart; request it again",
        code=RECOVERY_INTERRUPTED,
    )


def _segments_with_retained_audio(session_id: str) -> set[str]:
    """Ids of the segments whose manifest entry and audio file both exist. A
    missing or unreadable manifest leaves none."""
    try:
        manifest = load_manifest(session_id)
    except Exception:  # noqa: BLE001 — nothing to recover from without it
        return set()
    session_dir = session_dir_for(session_id)
    return {
        segment.segment_id
        for segment in manifest.segments
        if (session_dir / segment.audio_file).is_file()
    }


def _check_recoverable(session_id: str, status_obj: SessionStatus, segment_id: str) -> None:
    """The request checks of a recovery that depend on state, in order."""
    result = next((r for r in status_obj.segments if r.segment_id == segment_id), None)
    if result is None:
        raise SegmentNotFound()
    if result.status != "failed":
        raise SegmentNotFailed()
    if segment_id not in _segments_with_retained_audio(session_id):
        raise SegmentAudioMissing()


def _with_recoverable(session_id: str, status_obj: SessionStatus) -> SessionStatus:
    """`status_obj` with `recoverable` on its failed segments (SPEC §10.5),
    computed now and never stored; the object itself when none failed."""
    if not any(r.status == "failed" for r in status_obj.segments):
        return status_obj
    retained = _segments_with_retained_audio(session_id)
    return status_obj.model_copy(update={"segments": [
        r.model_copy(update={"recoverable": r.segment_id in retained}) if r.status == "failed" else r
        for r in status_obj.segments
    ]})


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
    known: dict[str, SegmentArtifact] | None = None,
) -> list[SegmentArtifact]:
    """The transcribed segments among `results`, in manifest order: every
    segment that has a transcript and did not fail, read from its
    `transcripts` row unless `known` already holds its artifact. A segment
    whose row is gone, or that the manifest no longer lists, is left out."""
    by_id = {r.segment_id: r for r in results}
    artifacts: list[SegmentArtifact] = []
    for segment in manifest.segments:
        result = by_id.get(segment.segment_id)
        if result is None or result.status == "failed" or result.transcript_id is None:
            continue
        artifact = (known or {}).get(segment.segment_id)
        if artifact is None:
            transcript = await db.get_transcript(result.transcript_id)
            if transcript is None:
                continue
            artifact = SegmentArtifact(
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


async def _publish_saved_day(artifacts: list[SegmentArtifact]) -> bool:
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
    `diary:{date}` and relies on LightRAG replacing it (operator decision,
    live check pending, SPEC §10.6.1).
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


def _build_combined_transcript(artifacts: list[SegmentArtifact]) -> str:
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
        attendees = attendees_to_canonical_names(ref.attendees)
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
