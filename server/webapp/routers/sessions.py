"""iOS session ingest router.

`POST /api/sessions` accepts the multipart bundle described in SPEC §10.2,
persists it under `data/sessions/{session_id}/`, and runs the per-segment
pipeline:

    AAC-LC m4a  →  ffmpeg → 16 kHz mono WAV
                →  Whisper sidecar
                →  transcript_corrector (Ollama)
                →  entity_detector (4-pass with calendar_ref shortcut)
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
import tempfile
from pathlib import Path
from typing import Any

import httpx
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

import db
import document_processor
import transcript_corrector
from entity_detector import detect_entities
from logging_setup import bind_session_id
from paths import sessions_dir
from models import (
    CalendarEventSegment,
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


def _whisper_url() -> str:
    import os as _os
    return _os.getenv("WHISPER_URL", "http://whisper:9000")

# In-memory status map. Per-process is fine — the iOS client polls within
# a single session; a restart loses status but the bundle on disk survives.
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

    # Cheap pre-flight: Whisper is the one upstream we cannot work around.
    # If it's down we surface 503 early rather than persisting a useless bundle.
    if not await _whisper_reachable():
        shutil.rmtree(session_dir, ignore_errors=True)
        async with _status_lock:
            _session_status.pop(session_id, None)
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


@router.get("/api/sessions/{session_id}/status", response_model=SessionStatus)
async def session_status(session_id: str) -> SessionStatus:
    async with _status_lock:
        status_obj = _session_status.get(session_id)
    if status_obj is None:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="session_not_found",
        )
    return status_obj


# --- per-segment pipeline -------------------------------------------------


async def _process_session_bg(parsed: Manifest, session_dir: Path) -> None:
    """Background-task wrapper that updates the in-memory status map."""
    try:
        results = await _process_session(parsed, session_dir)
        async with _status_lock:
            current = _session_status.get(parsed.session_id)
            if current is None:
                return
            failed = [r for r in results if r.status == "failed"]
            state = "done"
            if failed and len(failed) == len(results):
                state = "failed"
            elif failed:
                state = "partial"
            current.state = state
            current.segments = results
    except Exception:  # pragma: no cover — defensive
        logger.exception("session %s background processing crashed", parsed.session_id)
        async with _status_lock:
            current = _session_status.get(parsed.session_id)
            if current is not None:
                current.state = "failed"


async def _process_session(parsed: Manifest, session_dir: Path) -> list[SegmentResult]:
    """Walk all segments, returning a per-segment status list."""
    bind_session_id(parsed.session_id)
    todos_by_segment = _todos_grouped_by_segment(parsed)
    results: list[SegmentResult] = []
    for seg in parsed.segments:
        try:
            transcript_id = await _process_segment(
                manifest=parsed,
                segment=seg,
                session_dir=session_dir,
                segment_todos=todos_by_segment.get(seg.segment_id, []),
            )
            results.append(SegmentResult(
                segment_id=seg.segment_id,
                status="processed",
                transcript_id=transcript_id,
            ))
        except _PendingAnalysis as exc:
            # Upstream analysis (Ollama / LightRAG) was unreachable but we
            # have the raw transcript persisted. iOS treats this as success.
            results.append(SegmentResult(
                segment_id=seg.segment_id,
                status="pending_analysis",
                transcript_id=exc.transcript_id,
                error=str(exc),
            ))
        except Exception as exc:  # noqa: BLE001
            logger.exception(
                "session %s segment %s failed: %s",
                parsed.session_id, seg.segment_id, exc,
            )
            results.append(SegmentResult(
                segment_id=seg.segment_id, status="failed", error=str(exc),
            ))
    async with _status_lock:
        current = _session_status.get(parsed.session_id)
        if current is not None:
            failed_count = sum(1 for r in results if r.status == "failed")
            if failed_count == 0:
                current.state = "done"
            elif failed_count == len(results):
                current.state = "failed"
            else:
                current.state = "partial"
            current.segments = results
    return results


class _PendingAnalysis(Exception):
    def __init__(self, transcript_id: int, message: str) -> None:
        super().__init__(message)
        self.transcript_id = transcript_id


async def _process_segment(
    *,
    manifest: Manifest,
    segment: Segment,
    session_dir: Path,
    segment_todos: list[Todo],
) -> int:
    """Process a single segment end to end. Returns the transcript ID."""
    audio_path = session_dir / segment.audio_file
    if not audio_path.exists():
        raise FileNotFoundError(f"segment audio missing on disk: {segment.audio_file}")
    audio_bytes = audio_path.read_bytes()
    language = (segment.language or "de").split("-")[0]

    # 1. ffmpeg → WAV
    wav_bytes = await _ffmpeg_to_wav(audio_bytes, Path(segment.audio_file).suffix or ".m4a")

    # 2. Whisper
    raw_transcript = await _whisper(wav_bytes, language=language)
    if not raw_transcript:
        raise RuntimeError("whisper_empty_transcript")

    # 3. Transcript correction (Ollama). Fall back to raw on failure.
    try:
        corrected_text, _corrections = await transcript_corrector.correct_transcript(
            raw_text=raw_transcript,
        )
    except Exception as exc:  # noqa: BLE001
        logger.warning(
            "transcript_corrector failed for %s/%s: %s — using raw transcript",
            manifest.session_id, segment.segment_id, exc,
        )
        corrected_text = raw_transcript

    # 4. Insert transcript row so the rest of the pipeline can reference it.
    filename = f"{manifest.session_id}::{segment.segment_id}{Path(segment.audio_file).suffix}"
    transcript_id = await db.create_transcript(
        filename=filename,
        date=manifest.date.isoformat(),
        author="Florian Wolf",
        raw_text=raw_transcript,
    )
    if corrected_text != raw_transcript:
        await db.save_draft(transcript_id, corrected_text)

    # 5. Entity detection. The 4-pass detector already covers fuzzy + first-name
    # disambiguation. For calendar_event segments we additionally seed the
    # corrected text with the manifest's canonical attendee names so the
    # detector resolves them deterministically (Graph already gave us the
    # truth — no need to fuzzy-match again).
    persons_dict = await db.load_person_dictionary()
    terms_dict = await db.load_term_dictionary()
    if isinstance(segment, CalendarEventSegment):
        seed_persons = _attendees_to_canonical_names(segment.calendar_ref.attendees)
        if seed_persons:
            persons_dict = _seed_persons_into_dict(persons_dict, seed_persons)
    detected = detect_entities(
        text=corrected_text,
        persons=persons_dict,
        terms=terms_dict,
    )
    # Convert dataclass instances to dicts in the shape document_processor
    # expects (the HTMX review flow stores `text` for the canonical name).
    entities = []
    for d in detected:
        item = d.to_dict()
        item["text"] = d.canonical or d.original_text
        item["type"] = d.entity_type
        entities.append(item)

    # 6. Document processor → narrative + LightRAG ingest. Failures here
    # are recoverable: the raw + corrected transcripts are already on disk
    # and in Postgres; LightRAG/Ollama can be retried later.
    try:
        await _run_document_processor(
            transcript_id=transcript_id,
            transcript_record={
                "id": transcript_id,
                "raw_text": raw_transcript,
                "corrected_text": corrected_text,
                "date": manifest.date,
                "author": "Florian Wolf",
            },
            entities=entities,
            extra_todo_block=_format_todo_block(segment_todos),
        )
    except Exception as exc:  # noqa: BLE001
        logger.warning(
            "document_processor failed for %s/%s: %s",
            manifest.session_id, segment.segment_id, exc,
        )
        raise _PendingAnalysis(transcript_id, f"analysis_pending: {exc}") from exc

    return transcript_id


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


async def _run_document_processor(
    *,
    transcript_id: int,
    transcript_record: dict[str, Any],
    entities: list[dict],
    extra_todo_block: str,
) -> None:
    """Run the full document_processor pipeline in-process."""
    date_str = str(transcript_record.get("date", ""))
    person_names = [
        e.get("text") or e.get("canonical", "")
        for e in entities
        if (e.get("type") or e.get("entity_type", "")) == "PERSON"
    ]
    recent_ctx, entity_hist = await asyncio.gather(
        document_processor.query_lightrag_context(date_str),
        document_processor.query_lightrag_entity_history(person_names, date_str),
    )
    context_summary = await document_processor.summarize_context(
        recent_ctx, entity_hist, date_str
    )
    enriched = document_processor.build_enriched_context(
        transcript_record, entities, context_summary
    )
    analysis = await document_processor.analyze_transcript(enriched)
    markdown = document_processor.generate_narrative_document(enriched, analysis)
    if extra_todo_block:
        markdown = f"{markdown.rstrip()}\n{extra_todo_block}\n"
    metadata = document_processor.build_document_metadata(enriched)
    await db.save_processed_document(
        transcript_id=transcript_id,
        document_markdown=markdown,
        analysis_json=analysis,
        context_summary=context_summary,
        metadata=metadata,
    )
    await document_processor.ingest_to_lightrag(markdown, metadata)


# --- ffmpeg + Whisper helpers --------------------------------------------


async def _ffmpeg_to_wav(src_bytes: bytes, suffix: str) -> bytes:
    tmpdir = Path(tempfile.mkdtemp(prefix="seg-"))
    src_path = tmpdir / f"in{suffix}"
    wav_path = tmpdir / "out.wav"
    try:
        src_path.write_bytes(src_bytes)
        proc = await asyncio.create_subprocess_exec(
            "ffmpeg", "-y", "-i", str(src_path),
            "-ar", "16000", "-ac", "1", "-f", "wav", str(wav_path),
            stdout=asyncio.subprocess.DEVNULL,
            stderr=asyncio.subprocess.PIPE,
        )
        _, stderr = await proc.communicate()
        if proc.returncode != 0:
            raise RuntimeError(
                f"ffmpeg_failed: {stderr.decode('utf-8', 'replace')[-300:]}"
            )
        return wav_path.read_bytes()
    finally:
        shutil.rmtree(tmpdir, ignore_errors=True)


async def _whisper_reachable() -> bool:
    base = _whisper_url().rstrip("/")
    try:
        async with httpx.AsyncClient(timeout=2.5) as client:
            resp = await client.get(f"{base}/")
            return resp.status_code < 500
    except Exception:
        return False


async def _whisper(wav_bytes: bytes, *, language: str) -> str:
    base = _whisper_url().rstrip("/")
    async with httpx.AsyncClient(timeout=600.0) as client:
        try:
            resp = await client.post(
                f"{base}/asr",
                params={"task": "transcribe", "language": language, "output": "json"},
                files={"audio_file": ("seg.wav", wav_bytes, "audio/wav")},
            )
        except (httpx.NetworkError, httpx.TimeoutException) as exc:
            raise RuntimeError(f"whisper_unreachable: {exc}") from exc
        if resp.status_code >= 400:
            raise RuntimeError(f"whisper_status_{resp.status_code}")
        try:
            data = resp.json()
        except json.JSONDecodeError:
            return resp.text.strip()
        return (data.get("text") or "").strip()


def _slug_session_id(session_id: str) -> str:
    """Filesystem-safe slug for the session directory."""
    return re.sub(r"[^A-Za-z0-9._-]+", "_", session_id)


