"""iOS session ingest router.

`POST /api/sessions` accepts the multipart bundle described in SPEC §10.2,
persists it under `data/sessions/{session_id}/` and hands it to
`session_processing` (ARCH-2), which runs the per-segment pipeline in a
`BackgroundTasks` task; progress is poll-able via
`GET /api/sessions/{id}/status`. `POST /api/sessions/{id}/retry-analysis` is
the manual retry entry. Both, and the startup sweep `main.py` runs, go through
`session_processing.get_processor()`.

This module is HTTP only: multipart parsing, bundle storage, and mapping the
lifecycle's results and `SessionError`s to responses. Failures on a single
segment do not fail the whole session; the status records each segment
individually.
"""

from __future__ import annotations

import json
import logging
import shutil
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

import db
import session_processing
from models import Manifest, SessionAccepted, SessionStatus
from routers.auth import require_bearer

logger = logging.getLogger(__name__)


router = APIRouter(dependencies=[Depends(require_bearer)])

# How the lifecycle's refusals surface over HTTP; the detail is the error code.
_ERROR_STATUS: dict[type[session_processing.SessionError], int] = {
    session_processing.SessionNotFound: status.HTTP_404_NOT_FOUND,
    session_processing.SessionManifestMissing: status.HTTP_404_NOT_FOUND,
    session_processing.SessionBusy: status.HTTP_409_CONFLICT,
    session_processing.SessionNotRetryable: status.HTTP_409_CONFLICT,
}


def _http_error(exc: session_processing.SessionError) -> HTTPException:
    return HTTPException(status_code=_ERROR_STATUS[type(exc)], detail=exc.code)


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
    session_dir = session_processing.session_dir_for(session_id)
    processor = session_processing.get_processor()
    # Storing the bundle and persisting its row happen under the upload gate,
    # so a data reset (MIG-115/#115) never runs between the two and leaves a
    # session behind.
    async with processor.upload_gate():
        accepted = await _store_bundle_and_accept(processor, form, raw_manifest, parsed, session_dir)

    # Always process asynchronously. iOS polls /api/sessions/{id}/status
    # if it wants per-segment results; the upload itself returns immediately
    # so URLSession's idle timeout doesn't fire on long Ollama/LightRAG
    # passes (SPEC §10.5).
    background_tasks.add_task(processor.run_accepted, parsed, session_dir)

    return SessionAccepted(
        session_id=session_id,
        received_at=accepted.received_at,
        processing_status_url=f"/api/sessions/{session_id}/status",
        segments=accepted.segments,
    )


async def _store_bundle_and_accept(
    processor: session_processing.SessionProcessor,
    form,
    raw_manifest: bytes,
    parsed: Manifest,
    session_dir: Path,
) -> SessionStatus:
    """Write the bundle under `session_dir` and have `processor` persist and
    claim the session; 409 if the bundle already exists, 400 if parts are
    missing (the partial bundle is removed)."""
    session_id = parsed.session_id
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

    return await processor.accept(parsed, session_dir)


@router.get("/api/sessions/{session_id}/status", response_model=SessionStatus)
async def session_status(session_id: str) -> SessionStatus:
    status_obj = await session_processing.get_processor().get_status(session_id)
    if status_obj is None:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="session_not_found",
        )
    return status_obj


@router.post("/api/sessions/{session_id}/retry-analysis", response_model=SessionStatus)
async def retry_analysis(session_id: str) -> SessionStatus:
    """Retry a session stuck in `pending_analysis` (issue #52).

    404 if the session is unknown or its manifest is gone; 409 if none of its
    segments are actually `pending_analysis`; 409 `session_busy` if a run for
    the session (original ingest, another retry, the startup sweep) is
    already in flight.
    """
    try:
        return await session_processing.get_processor().retry_analysis(session_id)
    except session_processing.SessionError as exc:
        raise _http_error(exc) from exc


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

    dates = await db.list_transcript_dates(lo, hi)
    return {"dates": [d.isoformat() for d in dates]}
