"""iOS session ingest router.

`POST /api/sessions` accepts the multipart bundle described in SPEC §10.2,
persists it under `data/sessions/{session_id}/`, and runs the per-segment
pipeline:

    AAC-LC m4a  →  ffmpeg → 16 kHz mono WAV
                →  Whisper sidecar
                →  correction (dictionary + few-shot LLM correction, shared
                   with the HTMX review flow — #51)
                →  entity_detector (4-pass with calendar_ref shortcut) +
                   dismissal filtering
                →  document_processor (LightRAG context + analysis + ingest)

For ≤ 5 segments we process synchronously and return the per-segment
results. Larger sessions are kicked into a `BackgroundTasks` queue and
poll-able via `GET /api/sessions/{id}/status`.

Failures on a single segment do not fail the whole session; the response
records each segment's status individually.
"""

from __future__ import annotations

import asyncio
import json
import logging
import re
import shutil
from dataclasses import dataclass, field
from pathlib import Path

from fastapi import (
    APIRouter,
    BackgroundTasks,
    Depends,
    HTTPException,
    Request,
    status,
)
# IMPORTANT: import from starlette, not fastapi. `fastapi.UploadFile` is a
# subclass; instances coming back from `request.form()` are Starlette's
# parent class, so `isinstance(part, fastapi.UploadFile)` is always False.
from starlette.datastructures import UploadFile

import asr_client
import correction
import db
import narrative
import transcript_ingest
from logging_setup import bind_session_id
from paths import sessions_dir
from models import (
    CalendarEventSegment,
    DriveBySegment,
    EmptyBlockSegment,
    FreeReflectionSegment,
    Manifest,
    Segment,
    SegmentResult,
    SessionAccepted,
    SessionStatus,
    Todo,
    utcnow_iso,
)
from routers.auth import require_bearer

logger = logging.getLogger(__name__)


router = APIRouter(dependencies=[Depends(require_bearer)])


def _sessions_data_dir() -> Path:
    return sessions_dir()


async def _whisper_reachable() -> bool:
    return await asr_client.get_default_client().reachable()


# In-memory cache over the `session_ingests` table (SRV-A6). Fast path for
# same-process polling; `db.get_session_status` backs a cache miss (e.g.
# after a restart) so status and pending_analysis retryability survive.
_session_status: dict[str, SessionStatus] = {}
_status_lock = asyncio.Lock()


# --- multipart parsing ----------------------------------------------------


def _safe_relative_path(name: str) -> Path:
    """Reject any part name that escapes the session directory."""
    p = Path(name)
    if p.is_absolute() or any(part in ("..", "") for part in p.parts):
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail=f"unsafe_part_name: {name}",
        )
    return p


@router.post("/api/sessions", response_model=SessionAccepted)
async def post_session(
    request: Request,
    background_tasks: BackgroundTasks,
) -> SessionAccepted:
    """Accept and process an iOS session bundle.

    Multipart layout:
        manifest=@manifest.json
        segments/s01.m4a=@s01.m4a
        segments/s02.m4a=@s02.m4a
        ...
        raw/session.m4a=@session.m4a

    All parts are read from one `request.form()` call. We do *not* declare
    `manifest` as a `File(...)` parameter — doing so causes FastAPI to
    consume the body for that field alone and the subsequent `form()` then
    sees only the manifest, dropping the audio parts.
    """
    form = await request.form()

    manifest_file = form.get("manifest")
    if not isinstance(manifest_file, UploadFile):
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="manifest_part_missing",
        )
    raw_manifest = await manifest_file.read()
    try:
        manifest_dict = json.loads(raw_manifest)
        parsed = Manifest.model_validate(manifest_dict)
    except (json.JSONDecodeError, ValueError) as exc:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail=f"manifest_invalid: {exc}",
        ) from exc

    session_id = parsed.session_id
    session_dir = _sessions_data_dir() / _slug_session_id(session_id)
    if session_dir.exists():
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail=f"session_exists: {session_id}",
        )
    session_dir.mkdir(parents=True, exist_ok=True)
    (session_dir / "manifest.json").write_bytes(raw_manifest)

    expected_paths = {seg.audio_file for seg in parsed.segments}
    if parsed.raw_session_audio:
        expected_paths.add(parsed.raw_session_audio)

    received_field_names: list[str] = []
    saved: dict[str, Path] = {}
    for field_name, field_value in form.multi_items():
        received_field_names.append(field_name)
        if field_name == "manifest":
            continue
        if not isinstance(field_value, UploadFile):
            logger.warning(
                "session %s: non-file form field %s (type=%s) — skipping",
                session_id, field_name, type(field_value).__name__,
            )
            continue
        if field_name not in expected_paths:
            logger.warning(
                "session %s: unexpected part %s — skipping (expected: %s)",
                session_id, field_name, sorted(expected_paths),
            )
            continue
        rel = _safe_relative_path(field_name)
        dest = session_dir / rel
        dest.parent.mkdir(parents=True, exist_ok=True)
        with dest.open("wb") as out:
            while chunk := await field_value.read(1024 * 1024):
                out.write(chunk)
        saved[field_name] = dest

    missing = expected_paths - saved.keys()
    if missing:
        # Clean up the partial bundle.
        shutil.rmtree(session_dir, ignore_errors=True)
        logger.warning(
            "session %s rejected — received parts: %s; expected audio: %s",
            session_id, received_field_names, sorted(expected_paths),
        )
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail=f"missing_parts: {sorted(missing)}; received: {received_field_names}",
        )

    received_at = utcnow_iso()
    pending_results = [
        SegmentResult(segment_id=seg.segment_id, status="pending_analysis")
        for seg in parsed.segments
    ]

    async with _status_lock:
        _session_status[session_id] = SessionStatus(
            session_id=session_id,
            received_at=received_at,
            state="processing",
            segments=pending_results,
        )
    # Persist before we answer 200 — the in-memory map above is a cache;
    # this row is what survives a restart (SRV-A6).
    await db.create_session_status(
        session_id=session_id,
        received_at=received_at,
        state="processing",
        segments=[r.model_dump() for r in pending_results],
    )

    # Cheap pre-flight: Whisper is the one upstream we cannot work around.
    # If it's down we surface 503 early rather than persisting a useless bundle.
    if not await _whisper_reachable():
        shutil.rmtree(session_dir, ignore_errors=True)
        async with _status_lock:
            _session_status.pop(session_id, None)
        await db.delete_session_status(session_id)
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="whisper_unavailable",
        )

    # Always process asynchronously. iOS polls /api/sessions/{id}/status
    # if it wants per-segment results; the upload itself returns immediately
    # so URLSession's idle timeout doesn't fire on long Ollama/LightRAG
    # passes (SPEC §10.5).
    background_tasks.add_task(_process_session_bg, parsed, session_dir)

    return SessionAccepted(
        session_id=session_id,
        received_at=received_at,
        processing_status_url=f"/api/sessions/{session_id}/status",
        segments=pending_results,
    )


async def _lookup_session_status(session_id: str) -> SessionStatus | None:
    """Cache-then-db lookup shared by the status and retry-analysis routes.

    A cache miss (e.g. after a restart) falls back to the persisted row
    (SRV-A6) and repopulates the cache from it.
    """
    async with _status_lock:
        status_obj = _session_status.get(session_id)
    if status_obj is not None:
        return status_obj

    persisted = await db.get_session_status(session_id)
    if persisted is None:
        return None
    # `get_session_status` returns exactly SessionStatus's fields (segments as
    # dicts), so model_validate reconstructs it without restating each field.
    status_obj = SessionStatus.model_validate(persisted)
    async with _status_lock:
        _session_status.setdefault(session_id, status_obj)
    return status_obj


@router.get("/api/sessions/{session_id}/status", response_model=SessionStatus)
async def session_status(session_id: str) -> SessionStatus:
    status_obj = await _lookup_session_status(session_id)
    if status_obj is None:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="session_not_found",
        )
    return status_obj


@router.post("/api/sessions/{session_id}/retry-analysis", response_model=SessionStatus)
async def retry_analysis(session_id: str) -> SessionStatus:
    """Retry a session stuck in `pending_analysis` (issue #52).

    Rebuilds the session-level narrative input from what's persisted (the
    manifest on disk plus each segment's transcript row) and re-runs the
    shared narrative stage. 404 if the session is unknown; 409 if none of
    its segments are actually `pending_analysis`.
    """
    status_obj = await _lookup_session_status(session_id)
    if status_obj is None:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="session_not_found",
        )

    if not any(s.status == "pending_analysis" for s in status_obj.segments):
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail="session_not_retryable",
        )

    return await _retry_session_analysis(session_id, status_obj)


async def retry_stuck_sessions_on_startup() -> None:
    """Best-effort startup sweep (issue #52).

    Retries every session with a `pending_analysis` segment, one at a
    time (bounded by the sessions table, sequential so a heavy analysis
    call doesn't pile up concurrently with others). A session's retry
    failing is logged and left `pending_analysis` — the manual retry route,
    or the next startup, can pick it up again. Must never raise, since
    `main.py`'s lifespan runs this without blocking app start.
    """
    try:
        session_ids = await db.list_pending_analysis_session_ids()
    except Exception:  # noqa: BLE001 — best-effort, never blocks startup
        logger.exception("startup retry sweep: failed to list pending_analysis sessions")
        return

    for session_id in session_ids:
        try:
            status_obj = await _lookup_session_status(session_id)
            if status_obj is None:
                continue
            await _retry_session_analysis(session_id, status_obj)
        except Exception:  # noqa: BLE001 — one session's failure must not stop the rest
            logger.exception("startup retry sweep: session %s retry failed", session_id)


async def _retry_session_analysis(session_id: str, status_obj: SessionStatus) -> SessionStatus:
    """Rebuild the session-level narrative input from what's persisted and
    re-run the narrative stage for every `pending_analysis` segment.

    The manifest (segment order, headers, todos) comes back from the
    on-disk `manifest.json` written by `post_session`. Each segment's
    transcript (corrected text where present, entities) comes back from its
    `transcripts` row. If analysis already completed and saved a document
    for every pending segment but the LightRAG ingest failed, we re-ingest
    that saved narrative instead of re-running analysis
    (`_retry_via_saved_document`).
    """
    session_dir = _sessions_data_dir() / _slug_session_id(session_id)
    manifest_path = session_dir / "manifest.json"
    if not manifest_path.exists():
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="session_manifest_missing",
        )
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
                entities=_parse_entities_json(transcript.get("entities_json")),
            )
        )

    if not artifacts:
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail="session_not_retryable",
        )

    if not await _retry_via_saved_document(artifacts):
        todos_by_segment = _todos_grouped_by_segment(parsed)
        await _run_session_document_processor(
            manifest=parsed, artifacts=artifacts, todos_by_segment=todos_by_segment,
        )

    retried_ids = {art.segment.segment_id for art in artifacts}
    updated_segments = [
        SegmentResult(segment_id=r.segment_id, status="processed", transcript_id=r.transcript_id)
        if r.segment_id in retried_ids
        else r
        for r in status_obj.segments
    ]
    new_state = _derive_session_state(updated_segments)
    await _persist_session_status(session_id, new_state, updated_segments)

    async with _status_lock:
        return _session_status[session_id]


async def _retry_via_saved_document(artifacts: list[_SegmentArtifact]) -> bool:
    """Ingest-only retry shortcut.

    If analysis already completed and saved a `processed_documents` row for
    every artifact but the LightRAG ingest itself failed (rows exist,
    unmarked), re-ingest that saved narrative rather than re-running
    analysis. Returns `False` (no-op) if any artifact has no saved document
    yet, or already has one marked ingested.
    """
    docs: list[dict] = []
    for art in artifacts:
        doc = await db.get_latest_processed_document(art.transcript_id)
        if doc is None or doc.get("lightrag_ingested"):
            return False
        docs.append(doc)

    metadata = docs[0]["metadata"]
    if isinstance(metadata, str):
        metadata = json.loads(metadata)
    await narrative.sync_and_ingest(docs[0]["document_markdown"], metadata)
    for doc in docs:
        await db.mark_document_ingested(doc["id"])
    return True


def _parse_entities_json(raw: object) -> list[dict]:
    if not raw:
        return []
    if isinstance(raw, str):
        return json.loads(raw)
    return raw


@router.get("/api/sessions/dates")
async def session_dates(
    date_from: str | None = None,
    date_to: str | None = None,
) -> dict[str, list[str]]:
    """Distinct calendar dates that already have at least one transcript.

    `date_from` and `date_to` are inclusive ISO yyyy-MM-dd bounds; both are
    optional (omit to query all-time). Used by the iOS walkthrough date
    picker to mark which days have already been recorded *for*.
    Note these are recording target dates (`manifest.date`), not upload
    timestamps.
    """
    from datetime import date as _date

    def _parse(label: str, value: str | None) -> _date | None:
        if value is None:
            return None
        try:
            return _date.fromisoformat(value)
        except ValueError as exc:
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST,
                detail=f"invalid_{label}",
            ) from exc

    lo = _parse("date_from", date_from)
    hi = _parse("date_to", date_to)

    pool = await db.get_pool()
    if lo is not None and hi is not None:
        rows = await pool.fetch(
            "SELECT DISTINCT date FROM transcripts WHERE date BETWEEN $1 AND $2 ORDER BY date",
            lo, hi,
        )
    elif lo is not None:
        rows = await pool.fetch(
            "SELECT DISTINCT date FROM transcripts WHERE date >= $1 ORDER BY date",
            lo,
        )
    elif hi is not None:
        rows = await pool.fetch(
            "SELECT DISTINCT date FROM transcripts WHERE date <= $1 ORDER BY date",
            hi,
        )
    else:
        rows = await pool.fetch(
            "SELECT DISTINCT date FROM transcripts ORDER BY date"
        )
    return {"dates": [r["date"].isoformat() for r in rows]}


# --- per-segment pipeline -------------------------------------------------


def _derive_session_state(results: list[SegmentResult]) -> str:
    failed_count = sum(1 for r in results if r.status == "failed")
    if failed_count == 0:
        return "done"
    if failed_count == len(results):
        return "failed"
    return "partial"


async def _persist_session_status(
    session_id: str, state: str, segments: list[SegmentResult]
) -> None:
    """Write-through: update the in-memory cache (if present) and the
    persisted row (SRV-A6) so status survives a restart."""
    async with _status_lock:
        current = _session_status.get(session_id)
        if current is not None:
            current.state = state
            current.segments = segments
    await db.update_session_status(
        session_id=session_id,
        state=state,
        segments=[s.model_dump() for s in segments],
    )


async def _process_session_bg(parsed: Manifest, session_dir: Path) -> None:
    """Background-task wrapper. `_process_session` persists status itself
    (memory cache + db row) on success; this only handles the crash path."""
    try:
        await _process_session(parsed, session_dir)
    except Exception:  # pragma: no cover — defensive
        logger.exception("session %s background processing crashed", parsed.session_id)
        async with _status_lock:
            current = _session_status.get(parsed.session_id)
            if current is not None:
                current.state = "failed"
        await db.mark_session_failed(parsed.session_id)


@dataclass
class _SegmentArtifact:
    """Per-segment outputs handed off to the session-level analysis stage."""

    segment: Segment
    transcript_id: int
    raw_text: str
    corrected_text: str
    entities: list[dict] = field(default_factory=list)


async def _process_session(parsed: Manifest, session_dir: Path) -> list[SegmentResult]:
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
            )

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
                )

    # Preserve manifest segment order in the response.
    results = [results_by_id[seg.segment_id] for seg in parsed.segments]

    await _persist_session_status(
        parsed.session_id, _derive_session_state(results), results
    )
    return results


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
    # rebuilding the session narrative from Postgres would see none.
    await db.save_draft(transcript_id, corrected_text, entities_json=json.dumps(entities))

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


def _slug_session_id(session_id: str) -> str:
    """Filesystem-safe slug for the session directory."""
    return re.sub(r"[^A-Za-z0-9._-]+", "_", session_id)


