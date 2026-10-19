"""Session processing lifecycle (ARCH-2).

The one server seam behind the three ways a session gets processed:

* **original ingest** — `accept()` claims the session and persists its
  `processing` row, then `run_accepted()` runs the two-phase pipeline in the
  background;
* **manual retry** — `retry_analysis()` re-runs the narrative stage for the
  segments left `pending_analysis`;
* **startup sweep** — `retry_stuck_sessions_on_startup()` retries every
  stranded session once after a restart.

`routers/sessions.py` only parses HTTP and maps this module's results and
`SessionError`s to responses. Everything else lives here: the in-memory status
cache over the `session_ingests` table (SRV-A6), the per-session in-flight
claim that keeps two runs from saving two narratives for one session (BUG-54),
the per-segment pipeline, and the narrative persistence.

Pipeline for one segment:

    AAC-LC m4a  →  ffmpeg → 16 kHz mono WAV
                →  Whisper sidecar
                →  correction (dictionary + few-shot LLM correction, shared
                   with the HTMX review flow — #51)
                →  entity_detector (4-pass with calendar_ref shortcut) +
                   dismissal filtering
                →  narrative (LightRAG context + analysis + ingest), once per
                   session

A failure on one segment does not fail the session; each segment's status is
recorded individually.

State lives on a `SessionProcessor`; the app uses the process-wide one from
`get_processor()`, tests build their own.
"""

from __future__ import annotations

import asyncio
import json
import logging
import re
import shutil
from dataclasses import dataclass, field
from pathlib import Path
from typing import Awaitable, Callable

import asr_client
import correction
import db
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


# --- lifecycle ------------------------------------------------------------


class SessionProcessor:
    """Owns session status and runs the processing lifecycle.

    `whisper_reachable` is the pre-flight used by `accept()`; Whisper is the
    one upstream a session can't work around.
    """

    def __init__(
        self, *, whisper_reachable: Callable[[], Awaitable[bool]] = _asr_reachable
    ) -> None:
        self._whisper_reachable = whisper_reachable
        # In-memory cache over the `session_ingests` table (SRV-A6). Fast path
        # for same-process polling; `db.get_session_status` backs a cache miss
        # (e.g. after a restart) so status and pending_analysis retryability
        # survive.
        self._status: dict[str, SessionStatus] = {}
        self._lock = asyncio.Lock()
        # Sessions with a narrative run in flight (original background ingest,
        # a manual retry-analysis, or the startup sweep). A second run of the
        # same session would save another `processed_documents` version per
        # transcript and ingest `diary:{date}` into LightRAG twice. Guarded by
        # `_lock`; single-process app, so an in-process set is enough.
        self._in_flight: set[str] = set()

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

    # -- status ------------------------------------------------------------

    async def get_status(self, session_id: str) -> SessionStatus | None:
        """Cache-then-db lookup. A cache miss (e.g. after a restart) falls
        back to the persisted row (SRV-A6) and repopulates the cache from it."""
        async with self._lock:
            status_obj = self._status.get(session_id)
        if status_obj is not None:
            return status_obj

        persisted = await db.get_session_status(session_id)
        if persisted is None:
            return None
        # `get_session_status` returns exactly SessionStatus's fields (segments
        # as dicts), so model_validate reconstructs it without restating each
        # field.
        status_obj = SessionStatus.model_validate(persisted)
        async with self._lock:
            self._status.setdefault(session_id, status_obj)
        return status_obj

    async def clear_all(self) -> None:
        """Forget every session in this process: empty the status cache and
        delete every bundle under `data/sessions/` (MIG-115/#115). The admin
        reset calls it after `db.reset_all_data` has dropped the
        `session_ingests` rows. The sessions directory itself stays."""
        async with self._lock:
            self._status.clear()
        await asyncio.to_thread(_remove_all_bundles)

    async def _persist_status(
        self, session_id: str, state: str, segments: list[SegmentResult]
    ) -> None:
        """Write-through: update the in-memory cache (if present) and the
        persisted row (SRV-A6) so status survives a restart."""
        async with self._lock:
            current = self._status.get(session_id)
            if current is not None:
                current.state = state
                current.segments = segments
        await db.update_session_status(
            session_id=session_id,
            state=state,
            segments=[s.model_dump() for s in segments],
        )

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

    # -- original ingest ---------------------------------------------------

    async def accept(self, parsed: Manifest, session_dir: Path) -> SessionStatus:
        """Register a freshly uploaded bundle (already saved under
        `session_dir`) and return its `processing` status.

        Claims the session before its `processing` row exists, not when the
        background run starts: the startup sweep treats an unclaimed
        `processing` row as orphaned by a dead process, and a retry arriving
        before the run is scheduled must still see it busy. `run_accepted`
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
            async with self._lock:
                self._status[session_id] = accepted
            # Persist before we answer — the in-memory map above is a cache;
            # this row is what survives a restart (SRV-A6).
            await db.create_session_status(
                session_id=session_id,
                received_at=received_at,
                state="processing",
                segments=[r.model_dump() for r in pending_results],
            )

            if not await self._whisper_reachable():
                shutil.rmtree(session_dir, ignore_errors=True)
                async with self._lock:
                    self._status.pop(session_id, None)
                await db.delete_session_status(session_id)
                raise upstream_failure.whisper_unavailable()
        except BaseException:
            await self._end(session_id)
            raise
        return accepted

    async def run_accepted(self, parsed: Manifest, session_dir: Path) -> None:
        """Process a session `accept()` returned, in the background.
        `_process_session` persists status itself (memory cache + db row) on
        success; this only handles the crash path. Releases the claim
        `accept()` took, on success or failure."""
        try:
            await self._process_session(parsed, session_dir)
        except Exception:  # pragma: no cover — defensive
            logger.exception("session %s background processing crashed", parsed.session_id)
            async with self._lock:
                current = self._status.get(parsed.session_id)
                if current is not None:
                    current.state = "failed"
            await db.mark_session_failed(parsed.session_id)
        finally:
            await self._end(parsed.session_id)

    async def _process_session(self, parsed: Manifest, session_dir: Path) -> list[SegmentResult]:
        """Two-phase pipeline.

        Phase 1: per-segment Whisper + correction + entity detection. Each
        segment's transcript and entities are persisted independently.

        Phase 2: a single session-level pass — one LightRAG context query, one
        Ollama analysis, one narrative, one LightRAG ingest under
        `diary:{date}`. This replaces the previous per-segment ingest (which
        accidentally collapsed to one document per day anyway, since every
        segment shared the `diary:{date}` ID and the last writer won).
        """
        bind_session_id(parsed.session_id)
        todos_by_segment = _todos_grouped_by_segment(parsed)
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

        # Phase 2 — session-level analysis + LightRAG ingest (only if anything transcribed)
        if artifacts:
            try:
                await _run_session_document_processor(
                    manifest=parsed,
                    artifacts=artifacts,
                    todos_by_segment=todos_by_segment,
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

    async def retry_analysis(self, session_id: str) -> SessionStatus:
        """Retry a session stuck in `pending_analysis` (issue #52).

        Rebuilds the session-level narrative input from what's persisted (the
        manifest on disk plus each segment's transcript row) and re-runs the
        shared narrative stage. Segments that never got a transcript are
        resumed from the stored audio (`_resume_untranscribed_segments`,
        BUG-112) and join that input. A narrative failure doesn't raise: it
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
        status_obj = await self.get_status(session_id)
        if status_obj is None:
            raise SessionNotFound()

        if not await self._try_begin(session_id):
            raise SessionBusy()
        try:
            if not any(s.status == "pending_analysis" for s in status_obj.segments):
                raise SessionNotRetryable()

            return await self._retry_session_analysis(session_id, status_obj)
        finally:
            await self._end(session_id)

    async def _retry_session_analysis(
        self, session_id: str, status_obj: SessionStatus
    ) -> SessionStatus:
        """Rebuild the session-level narrative input from what's persisted and
        re-run the narrative stage for every `pending_analysis` segment.

        The manifest (segment order, headers, todos) comes back from the
        on-disk `manifest.json` written at ingest. Each segment's transcript
        (corrected text where present, entities) comes back from its
        `transcripts` row. If analysis already completed and saved a document
        for every pending segment but the LightRAG ingest failed, we re-ingest
        that saved narrative instead of re-running analysis
        (`_retry_via_saved_document`).
        """
        manifest_path = session_dir_for(session_id) / "manifest.json"
        if not manifest_path.exists():
            raise SessionManifestMissing()
        parsed = Manifest.model_validate(json.loads(manifest_path.read_bytes()))
        segments_by_id = {seg.segment_id: seg for seg in parsed.segments}

        artifacts: list[_SegmentArtifact] = []
        for seg_result in status_obj.segments:
            if seg_result.status != "pending_analysis" or seg_result.transcript_id is None:
                continue
            segment = segments_by_id.get(seg_result.segment_id)
            if segment is None:
                continue
            transcript = await db.get_transcript(seg_result.transcript_id)
            if transcript is None:
                continue
            artifacts.append(
                _SegmentArtifact(
                    segment=segment,
                    transcript_id=seg_result.transcript_id,
                    raw_text=transcript.get("raw_text") or "",
                    corrected_text=(
                        transcript.get("corrected_text") or transcript.get("raw_text") or ""
                    ),
                    # Pre-BUG-55 rows have the pipeline's entities in `entities_json`.
                    entities=_parse_entities_json(
                        transcript.get("detected_entities_json")
                        or transcript.get("entities_json")
                    ),
                )
            )

        # Decide retryability before any side effect: with no transcript row to
        # narrate and nothing untranscribed to resume, there is no work.
        if not artifacts and not any(_is_untranscribed(r) for r in status_obj.segments):
            raise SessionNotRetryable()

        segment_results, resumed = await self._resume_untranscribed_segments(
            session_id, parsed, status_obj
        )
        artifacts.extend(resumed)
        # Narrative order is manifest order, whether a segment was resumed or
        # rebuilt from its transcript row.
        order = {seg.segment_id: i for i, seg in enumerate(parsed.segments)}
        artifacts.sort(key=lambda art: order[art.segment.segment_id])

        if not artifacts:
            # Every segment that was resumed failed: nothing to narrate, but
            # the outcome is settled, not an error.
            await self._persist_status(
                session_id, derive_session_state(segment_results), segment_results
            )
            async with self._lock:
                return self._status[session_id]

        retried_ids = {art.segment.segment_id for art in artifacts}
        try:
            if not await _retry_via_saved_document(artifacts):
                todos_by_segment = _todos_grouped_by_segment(parsed)
                await _run_session_document_processor(
                    manifest=parsed, artifacts=artifacts, todos_by_segment=todos_by_segment,
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

        async with self._lock:
            return self._status[session_id]

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

    async def retry_stuck_sessions_on_startup(self) -> None:
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
            corrected = await db.correct_legacy_done_sessions()
            if corrected:
                logger.info(
                    "startup retry sweep: marked %d legacy done session(s) with pending segments partial",
                    corrected,
                )
        except Exception as exc:  # noqa: BLE001 — best-effort, never blocks the sweep
            logger.warning("startup retry sweep: legacy done-row correction failed: %s", exc)

        try:
            session_ids = await db.list_pending_analysis_session_ids()
        except Exception:  # noqa: BLE001 — best-effort, never blocks startup
            logger.exception("startup retry sweep: failed to list pending_analysis sessions")
            return

        for session_id in session_ids:
            if not await self._try_begin(session_id):
                logger.info("startup retry sweep: session %s busy, skipping", session_id)
                continue
            try:
                status_obj = await self.get_status(session_id)
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


_default: SessionProcessor | None = None


def get_processor() -> SessionProcessor:
    """The process-wide processor the routes and the startup sweep share."""
    global _default
    if _default is None:
        _default = SessionProcessor()
    return _default


def _is_untranscribed(result: SegmentResult) -> bool:
    """A segment cut off before its transcript was persisted (BUG-112)."""
    return result.status == "pending_analysis" and result.transcript_id is None


# --- saved-document retry -------------------------------------------------


async def _retry_via_saved_document(artifacts: list[_SegmentArtifact]) -> bool:
    """Ingest-only retry shortcut.

    If analysis already completed and saved a `processed_documents` row for
    every artifact, the latest rows are all the same whole-session narrative
    (`_run_session_document_processor` saves one combined document against
    every segment), and the LightRAG ingest itself failed (rows unmarked),
    re-ingest that saved narrative rather than re-running analysis.

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
    in `_run_session_document_processor`.
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
        author="Florian Wolf",
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
    persons_dict = await db.load_person_dictionary()
    terms_dict = await db.load_term_dictionary()
    if isinstance(segment, CalendarEventSegment):
        seed_persons = _attendees_to_canonical_names(segment.calendar_ref.attendees)
        if seed_persons:
            persons_dict = _seed_persons_into_dict(persons_dict, seed_persons)
    text_corrections = await db.load_text_corrections()
    dismissals = await db.load_entity_dismissals()

    result = await correction.correct_and_detect_entities(
        raw_transcript,
        persons=persons_dict,
        terms=terms_dict,
        text_corrections=text_corrections,
        dismissals=dismissals,
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


def _format_todo_block(todos: list[Todo]) -> str:
    """Render todos as a German prose block appended to the narrative."""
    if not todos:
        return ""
    lines = ["", "## Offene Punkte"]
    for todo in todos:
        due = f" (fällig {todo.due})" if todo.due else ""
        lines.append(f"- {todo.text} — Status: {todo.status}{due}")
    return "\n".join(lines)


async def _run_session_document_processor(
    *,
    manifest: Manifest,
    artifacts: list[_SegmentArtifact],
    todos_by_segment: dict[str, list[Todo]],
) -> None:
    """Run the shared narrative stage once per session, then the
    session-specific parts around it.

    Concatenates all transcribed segments (with per-segment headers so the
    analysis LLM can still reason about meeting boundaries), unions the
    detected entities, and delegates context → summary → analysis →
    narrative markdown → metadata to `narrative.build_day_narrative` (the
    same stage `main.py`'s SSE review flow uses — SRV-A1/#50). The todo
    block and the multi-transcript save stay session-specific, since the
    SSE path has neither.

    The combined narrative is saved as a `processed_documents` row against
    every segment's transcript_id so any segment-level read path keeps
    working. Each of those rows is marked `lightrag_ingested` once the
    LightRAG ingest succeeds — mirroring `main.py`'s manual
    `/api/documents/{id}/ingest` route — so `/process/{id}` doesn't show an
    already-ingested day as pending and the re-ingest button doesn't re-post
    it.
    """
    date_str = manifest.date.isoformat()
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
    todo_block = _format_session_todo_block(manifest, artifacts, todos_by_segment)
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


def _format_session_todo_block(
    manifest: Manifest,
    artifacts: list[_SegmentArtifact],
    todos_by_segment: dict[str, list[Todo]],
) -> str:
    """Aggregate every segment's todos plus any unattached implicit todos."""
    todos: list[Todo] = []
    seen_ids = {art.segment.segment_id for art in artifacts}
    for segment_id, segment_todos in todos_by_segment.items():
        if segment_id in seen_ids:
            todos.extend(segment_todos)
    # Implicit-confirmed todos without a source segment are not in
    # `todos_by_segment`; include them so the day's narrative captures them.
    for todo in manifest.todos_implicit_confirmed:
        if not todo.source_segment_id:
            todos.append(todo)
    return _format_todo_block(todos)
