import asyncio
import csv
import io
import json
import logging
import os
import re
from collections.abc import Coroutine
from contextlib import asynccontextmanager
from datetime import date as date_module, datetime, timedelta
from typing import Any
from pathlib import Path

from dotenv import load_dotenv
load_dotenv(Path(__file__).resolve().parent.parent / ".env")

from logging_setup import CorrelationIdMiddleware, configure_logging  # noqa: E402
import upstream_failure  # noqa: E402

configure_logging()
logger = logging.getLogger(__name__)

import httpx  # noqa: E402
from fastapi import APIRouter, Depends, FastAPI, Form, Request, UploadFile, File  # noqa: E402
from fastapi.responses import HTMLResponse, JSONResponse, RedirectResponse, StreamingResponse  # noqa: E402
from fastapi.staticfiles import StaticFiles  # noqa: E402
from fastapi.templating import Jinja2Templates  # noqa: E402

import analysis_route  # noqa: E402
import asr_client  # noqa: E402
import bind_guard  # noqa: E402
import correction  # noqa: E402
import db  # noqa: E402
import dictionary  # noqa: E402
import document_processor  # noqa: E402
import llm_validator  # noqa: E402
import harvest  # noqa: E402
import narrative  # noqa: E402
import session_ingest  # noqa: E402
import transcript_ingest  # noqa: E402
import vector_store  # noqa: E402

WHISPER_URL = os.getenv("WHISPER_URL", "http://whisper:9000")
HARVEST_ACCESS_TOKEN = os.getenv("HARVEST_ACCESS_TOKEN", "")
HARVEST_ACCOUNT_ID = os.getenv("HARVEST_ACCOUNT_ID", "")
HARVEST_USER_ID = os.getenv("HARVEST_USER_ID", "")

BASE_DIR = Path(__file__).resolve().parent


@asynccontextmanager
async def lifespan(app: FastAPI):
    # SEC-1: refuse to come up unless TAILNET_IP is a real tailnet address —
    # before any other startup work, so a misconfigured deploy never reaches
    # the point of binding all interfaces.
    bind_guard.enforce_tailnet_bind()

    # BAR-01: validate ANALYSIS_ROUTE and its Blindfold settings before any
    # other startup work. A bad value refuses to start rather than quietly
    # running the analysis locally; routed, it logs the egress WARNING.
    analysis_route.configure()

    # Log configuration on startup
    logger.info("=== Diary Processor starting ===")
    logger.info("OLLAMA_BASE_URL    = %s", os.getenv("OLLAMA_BASE_URL", "(not set)"))
    logger.info("OLLAMA_MODEL       = %s", os.getenv("OLLAMA_MODEL", "(not set)"))
    logger.info("OLLAMA_TIMEOUT     = %s", os.getenv("OLLAMA_TIMEOUT", "(not set)"))
    logger.info("LLM_VALIDATION_ENABLED = %s", os.getenv("LLM_VALIDATION_ENABLED", "(not set)"))
    logger.info("LLM_CORRECTION_ENABLED = %s", os.getenv("LLM_CORRECTION_ENABLED", "(not set, falls back to LLM_VALIDATION_ENABLED)"))
    logger.info("FLUENCY_CHECK_ENABLED = %s", os.getenv("FLUENCY_CHECK_ENABLED", "(not set, defaults to true)"))
    logger.info("WHISPER_URL        = %s", WHISPER_URL)
    logger.info("DATABASE_URL       = %s", re.sub(r"://([^:@/]+):[^@]*@", r"://\1:***@", db.DATABASE_URL))
    logger.info("TZ                 = %s", os.getenv("TZ", "(not set)"))
    logger.info("HARVEST_ACCOUNT_ID = %s", HARVEST_ACCOUNT_ID or "(not set)")
    logger.info("HARVEST_ACCESS_TOKEN = %s", "***" + HARVEST_ACCESS_TOKEN[-4:] if len(HARVEST_ACCESS_TOKEN) > 4 else "(not set)")
    logger.info("QDRANT_URL         = %s", vector_store.QDRANT_URL)
    logger.info("LIGHTRAG_URL       = %s", document_processor.LIGHTRAG_URL)
    logger.info("LIGHTRAG_API_KEY   = %s", "***" if document_processor.LIGHTRAG_API_KEY else "(not set)")
    logger.info("OLLAMA_ANALYSIS_MODEL = %s", document_processor.OLLAMA_ANALYSIS_MODEL)
    logger.info("VECTOR_SEARCH_ENABLED = %s", vector_store.VECTOR_SEARCH_ENABLED)

    # Ensure the runtime data directories exist (gitignored, mounted as a
    # volume in production). data/sessions/ holds iOS session bundles;
    # data/msal_cache.bin is created by the bootstrap script.
    from paths import sessions_dir as _sessions_dir
    _sessions_dir().mkdir(parents=True, exist_ok=True)

    pool = await db.get_pool()
    # Auto-apply schema on startup (idempotent, uses IF NOT EXISTS)
    schema_file = BASE_DIR / "schema.sql"
    if schema_file.exists():
        async with pool.acquire() as conn:
            await conn.execute(schema_file.read_text())

    # Initialize Qdrant vector store
    if vector_store.VECTOR_SEARCH_ENABLED:
        logger.info("VECTOR_SEARCH_ENABLED = true, initializing Qdrant...")
        await vector_store.init_collections()
    else:
        logger.info("VECTOR_SEARCH_ENABLED = false, skipping Qdrant")

    # Best-effort startup sweep (#52): retry sessions left in
    # pending_analysis by a prior crash/restart. Fire-and-forget so a slow
    # LLM/LightRAG retry never delays the app coming up; kept on app.state
    # so the task isn't garbage-collected mid-flight.
    app.state.startup_retry_sweep_task = asyncio.create_task(
        session_ingest.get_session_ingest().sweep()
    )

    yield
    # Stop the sweep before the pool it queries goes away.
    sweep_task = app.state.startup_retry_sweep_task
    sweep_task.cancel()
    await asyncio.gather(sweep_task, return_exceptions=True)
    await vector_store.close()
    await db.close_pool()


app = FastAPI(title="Diary Transcript Review", lifespan=lifespan)
app.add_middleware(CorrelationIdMiddleware)
upstream_failure.install(app)
app.mount("/static", StaticFiles(directory=BASE_DIR / "static"), name="static")
templates = Jinja2Templates(directory=str(BASE_DIR / "templates"))

# iOS-facing routers (bearer-token auth applied per-router via Depends,
# except `/health` which is reachable pre-onboarding for the Tailscale probe).
from routers.auth import require_bearer  # noqa: E402
from routers.calendar import router as calendar_router  # noqa: E402
from routers.email import router as email_router  # noqa: E402
from routers.lightrag import router as lightrag_router  # noqa: E402
from routers.sessions import router as sessions_router  # noqa: E402
from routers.health import router as health_router  # noqa: E402
from routers.tts import router as tts_router  # noqa: E402
from routers.dictionary import router as dictionary_router  # noqa: E402
from routers.admin import router as admin_router  # noqa: E402
from routers.review_stream import router as review_stream_router  # noqa: E402

app.include_router(calendar_router)
app.include_router(email_router)
app.include_router(lightrag_router)
app.include_router(sessions_router)
app.include_router(health_router)
app.include_router(tts_router)
app.include_router(dictionary_router)
app.include_router(admin_router)
app.include_router(review_stream_router)

# Legacy review/admin/data routes (SEC-2, docs/REVIEW-2026-07-04.md §3).
# These share the same published port as the routers above, so the same
# bearer token gates them — `/health` is the only intentionally open route.
legacy_router = APIRouter(dependencies=[Depends(require_bearer)])


# ─── Pages ───────────────────────────────────────────────────────────


def _format_relative_time(dt):
    """Format a datetime as a relative time string."""
    if dt is None:
        return ""
    now = datetime.now(dt.tzinfo) if dt.tzinfo else datetime.now()
    delta = now - dt
    minutes = int(delta.total_seconds() / 60)
    if minutes < 1:
        return "just now"
    if minutes < 60:
        return f"{minutes} min ago"
    hours = minutes // 60
    if hours < 24:
        return f"{hours} hour{'s' if hours != 1 else ''} ago"
    days = hours // 24
    return f"{days} day{'s' if days != 1 else ''} ago"


WEEKDAYS = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
MONTHS = [
    "", "Jan", "Feb", "Mar", "Apr", "May", "Jun",
    "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
]


@legacy_router.get("/", response_class=HTMLResponse)
async def index(request: Request):
    """Transcript list page."""
    transcripts = await db.list_transcripts()
    # Batch-fetch which transcripts have processed documents
    doc_map = await db.get_latest_document_ids_by_transcript()
    rows = []
    for t in transcripts:
        d = t["date"]
        processing_seconds = None
        if t.get("submitted_at") and t.get("processed_at"):
            delta = t["processed_at"] - t["submitted_at"]
            processing_seconds = max(0, int(delta.total_seconds()))
        rows.append({
            "id": t["id"],
            "fn": t["filename"],
            "author": t["author"] or "Unknown",
            "status": t["status"],
            "words": t.get("word_count") or 0,
            "date": d.isoformat() if d else "",
            "dateDisplay": f"{d.day} {MONTHS[d.month]} {d.year}" if d else "",
            "day": WEEKDAYS[d.weekday()] if d else "",
            "uploaded": t["created_at"].isoformat() if t.get("created_at") else "",
            "uploadedDisplay": _format_relative_time(t.get("created_at")),
            "processing_seconds": processing_seconds,
            "processing_error": t.get("processing_error"),
            "doc_id": doc_map.get(t["id"]),
        })
    return templates.TemplateResponse(
        request,
        "index.html",
        {"transcripts_json": json.dumps(rows)},
    )


@legacy_router.get("/review/{transcript_id}", response_class=HTMLResponse)
async def review_page(request: Request, transcript_id: int):
    """Main review page. Uses saved entities if available, otherwise runs detection."""
    transcript = await db.get_transcript(transcript_id)
    if not transcript:
        return RedirectResponse("/")

    persons = await db.load_person_dictionary()
    terms = await db.load_term_dictionary()

    # Use saved entity states if available (from a previous Save)
    saved_entities = transcript.get("entities_json")
    applied_corrections = []
    raw_text = transcript["raw_text"]
    needs_processing = False

    if saved_entities:
        # Restore corrected text so entity positions (start/end) align
        if transcript.get("corrected_text"):
            raw_text = transcript["corrected_text"]
        if isinstance(saved_entities, str):
            entities_json = saved_entities
        else:
            # asyncpg returns JSONB as Python objects directly
            entities_json = json.dumps(saved_entities)
    else:
        # Pre-process: apply learned text corrections (fast, no LLM)
        text_corrections = await db.load_text_corrections()
        if text_corrections:
            raw_text, applied_corrections = correction.apply_text_corrections(
                raw_text, text_corrections
            )

        # Fresh transcript: return immediately, SSE will handle the rest
        entities_json = "[]"
        needs_processing = True

    return templates.TemplateResponse(
        request,
        "review.html",
        {
            "transcript": transcript,
            "entities_json": entities_json,
            "raw_text": raw_text,
            "person_count": len(persons),
            "term_count": len(terms),
            "llm_enabled": llm_validator.LLM_VALIDATION_ENABLED,
            "applied_corrections": json.dumps(applied_corrections),
            "needs_processing": needs_processing,
        },
    )


# ─── Document Processing ──────────────────────────────────────────────


@legacy_router.get("/process/{transcript_id}")
async def process_page(request: Request, transcript_id: int):
    """HTML page for document processing."""
    transcript = await db.get_transcript(transcript_id)
    if not transcript:
        return RedirectResponse("/", status_code=302)
    document = await db.get_latest_processed_document(transcript_id)
    # Pre-compute all document fields for the template to avoid passing
    # complex asyncpg dicts that can trip up Jinja's template cache
    doc_info = {
        "id": document["id"] if document else None,
        "version": document["version"] if document else 0,
        "lightrag_ingested": document["lightrag_ingested"] if document else False,
        "lightrag_ingested_at": (
            document["lightrag_ingested_at"].strftime("%Y-%m-%d %H:%M")
            if document and document.get("lightrag_ingested_at")
            else ""
        ),
    }
    doc_markdown = document["document_markdown"] if document else ""
    doc_analysis = document["analysis_json"] if document and document.get("analysis_json") else None
    return templates.TemplateResponse(
        request,
        "process.html",
        {
            "transcript": transcript,
            "doc": doc_info,
            "doc_markdown_json": json.dumps(doc_markdown or ""),
            "doc_analysis_json": json.dumps(doc_analysis) if doc_analysis else "null",
        },
    )


@legacy_router.get("/api/documents/{doc_id}")
async def get_document(doc_id: int):
    """Get a processed document."""
    doc = await db.get_processed_document(doc_id)
    if not doc:
        return JSONResponse({"error": "not found"}, 404)
    result = {
        "id": doc["id"],
        "transcript_id": doc["transcript_id"],
        "version": doc["version"],
        "document_markdown": doc["document_markdown"],
        "analysis_json": doc["analysis_json"],
        "context_summary": doc["context_summary"],
        "metadata": doc["metadata"],
        "lightrag_ingested": doc["lightrag_ingested"],
        "lightrag_ingested_at": doc["lightrag_ingested_at"].isoformat() if doc.get("lightrag_ingested_at") else None,
        "created_at": doc["created_at"].isoformat() if doc.get("created_at") else None,
    }
    return result


@legacy_router.post("/api/documents/{doc_id}/save")
async def save_document(doc_id: int, request: Request):
    """Save edited markdown for a processed document."""
    body = await request.json()
    markdown = body.get("markdown", "")
    if not markdown:
        return JSONResponse({"status": "error", "message": "No markdown provided"}, 400)
    result = await db.update_processed_document(doc_id, markdown)
    if not result:
        return JSONResponse({"status": "error", "message": "Document not found"}, 404)
    return {"status": "ok", "updated_at": result["updated_at"].isoformat()}


@legacy_router.post("/api/documents/{doc_id}/ingest")
async def ingest_document(doc_id: int):
    """Send a processed document to LightRAG."""
    doc = await db.get_processed_document(doc_id)
    if not doc:
        return JSONResponse({"status": "error", "message": "Document not found"}, 404)

    metadata = doc["metadata"] or {}
    try:
        await narrative.sync_and_ingest(doc["document_markdown"], metadata)
    except Exception as e:
        return JSONResponse({"status": "error", "message": str(e)}, 500)

    result = await db.mark_document_ingested(doc_id)
    return {
        "status": "ok",
        "ingested_at": result["lightrag_ingested_at"].isoformat() if result else None,
    }


# ─── Calendar ─────────────────────────────────────────────────────────


async def _fetch_calendar_events(date_str: str) -> list[dict]:
    """Fetch raw Graph-shaped calendar events for the given local date.

    Used by `/api/calendar/{date}` (HTMX review widget) and
    `/api/harvest/suggest`. Returns events in Graph's native shape
    (`start.dateTime`, `attendees[i].emailAddress.name`, …) so the
    existing UI layers don't need to change.
    """
    import fixtures
    from msgraph_client import (
        MSGraphError,
        MSGraphNotBootstrapped,
        get_client,
    )

    try:
        d = date_module.fromisoformat(date_str)
    except ValueError:
        return []

    if fixtures.fixture_mode():
        return fixtures.load_calendar_events(date_str)

    try:
        client = await get_client()
        return await client.events_for_day(d)
    except (MSGraphNotBootstrapped, MSGraphError) as exc:
        logger.warning("calendar fetch failed for %s: %s", date_str, exc)
        return []


@legacy_router.get("/api/calendar/{date_str}")
async def get_calendar_events(date_str: str):
    """Calendar events for a specific date.

    Stub for Server S1 — returns an empty list. Server S2 wires this to
    `webapp/msgraph_client.py` for direct MS Graph access.
    """
    events = await _fetch_calendar_events(date_str)
    return {"date": date_str, "events": events}


# ─── API ─────────────────────────────────────────────────────────────


@legacy_router.get("/api/dictionary")
async def get_dictionary():
    """Full entity dictionary."""
    persons = await db.load_person_dictionary()
    terms = await db.load_term_dictionary()
    return {"persons": persons, "terms": terms}


@legacy_router.post("/api/transcripts")
async def upload_transcript(
    filename: str = Form(...),
    date_str: str = Form(..., alias="date"),
    author: str = Form("Florian Wolf"),
    raw_text: str = Form(...),
):
    """Manually add a transcript to the review queue."""
    tid = await db.create_transcript(filename, date_str, author, raw_text)
    return {"id": tid, "status": "pending"}


@legacy_router.post("/api/transcripts/delete")
async def delete_transcripts(request: Request):
    """Delete selected transcripts by IDs."""
    body = await request.json()
    ids = body.get("ids", [])
    if ids:
        await db.delete_transcripts(ids)
    return {"status": "ok", "deleted": len(ids)}


@legacy_router.get("/api/transcripts/status")
async def transcripts_status():
    """Return current status for recently submitted transcripts (last 24h)."""
    rows = await db.list_recent_transcript_statuses()
    result = []
    for r in rows:
        processing_seconds = None
        if r["submitted_at"] and r["processed_at"]:
            delta = r["processed_at"] - r["submitted_at"]
            processing_seconds = max(0, int(delta.total_seconds()))
        result.append({
            "id": r["id"],
            "status": r["status"],
            "processing_seconds": processing_seconds,
            "processing_error": r["processing_error"],
        })
    return result


@legacy_router.post("/api/transcripts/{transcript_id}/retry")
async def retry_transcript(transcript_id: int):
    """Reset a failed transcript so it can be re-processed.

    The user re-runs the SSE pipeline at /process/{id} after this call
    resets state.
    """
    transcript = await db.get_transcript(transcript_id)
    if not transcript:
        return JSONResponse({"error": "not found"}, 404)
    if transcript["status"] != "failed":
        return JSONResponse({"error": "transcript is not in failed state"}, 400)

    await db.mark_transcript_resubmitted(transcript_id)
    return {"status": "submitted", "process_url": f"/process/{transcript_id}"}


@legacy_router.post("/api/transcripts/{transcript_id}/reset")
async def reset_transcript(transcript_id: int):
    """Reset a transcript's saved data so it can be reprocessed."""
    transcript = await db.get_transcript(transcript_id)
    if not transcript:
        return JSONResponse({"error": "not found"}, 404)
    await db.reset_transcript(transcript_id)
    return {"status": "reset"}


@legacy_router.post("/api/transcripts/{transcript_id}/save")
async def save_draft(transcript_id: int, request: Request):
    """Save corrected transcript and entity changes (draft save, no processing)."""
    body = await request.json()
    entities_json = json.dumps(body["entities"]) if "entities" in body else None
    await db.save_draft(
        transcript_id,
        body["corrected_transcript"],
        body.get("raw_text"),
        entities_json,
    )

    learning = await dictionary.learn_from_review(transcript_id, body)

    return {"status": "saved", "new_dictionary_entries": learning.new_entries}


# Strong references to in-flight review vector-store writes: the event loop
# only keeps weak references to tasks, so an unreferenced one can be
# garbage-collected mid-flight and its failure would never be observed.
_review_vector_tasks: set[asyncio.Task] = set()


def _retain_review_vector_task(coro: Coroutine[Any, Any, None], transcript_id: int) -> asyncio.Task:
    task = asyncio.create_task(coro)
    _review_vector_tasks.add(task)

    def _finished(done: asyncio.Task) -> None:
        _review_vector_tasks.discard(done)
        if done.cancelled():
            logger.warning("Vector store task for transcript %s was cancelled", transcript_id)
        elif done.exception() is not None:
            logger.warning(
                "Failed to store vectors for transcript %s: %s",
                transcript_id,
                done.exception(),
                exc_info=done.exception(),
            )

    task.add_done_callback(_finished)
    return task


@legacy_router.post("/api/transcripts/{transcript_id}/submit")
async def submit_review(transcript_id: int, request: Request):
    """
    Submit reviewed transcript. Saves corrections to the dictionary
    and stores the corrected text + entities so the SSE pipeline at
    /process/{id} can run the local document processor.
    """
    body = await request.json()

    # 1. Save corrected transcript and entities (local pipeline picks
    # this up at /api/transcripts/{id}/process-document).
    entities = body.get("entities", [])
    await db.save_draft(
        transcript_id,
        body["corrected_transcript"],
        entities_json=json.dumps(entities) if entities else None,
    )

    # 2. Grow the dictionary, log the review and store vectors for contextual
    # learning. The vector write is fire-and-forget through the tracked task.
    await dictionary.learn_from_review(
        transcript_id,
        body,
        submit=True,
        run_vector_task=lambda coro: _retain_review_vector_task(coro, transcript_id),
    )

    return {"status": "submitted"}


# ─── Data Management ──────────────────────────────────────────────────


@legacy_router.get("/settings", response_class=HTMLResponse)
async def settings_page(request: Request):
    counts = await db.get_data_counts()
    return templates.TemplateResponse(
        request,
        "data.html",
        {"counts_json": json.dumps(dict(counts))},
    )


@legacy_router.get("/data", response_class=HTMLResponse)
async def data_page_redirect():
    return RedirectResponse("/settings", status_code=301)


@legacy_router.get("/api/data/backup")
async def data_backup(transcripts: bool = True, review_log: bool = True):
    backup = await db.export_backup(
        include_transcripts=transcripts, include_review_log=review_log
    )
    content = json.dumps(backup, indent=2, ensure_ascii=False)
    date_str = date_module.today().isoformat()
    return StreamingResponse(
        io.BytesIO(content.encode("utf-8")),
        media_type="application/json",
        headers={
            "Content-Disposition": f'attachment; filename="diary-processor-backup-{date_str}.json"'
        },
    )


@legacy_router.post("/api/data/restore")
async def data_restore(file: UploadFile = File(...)):
    try:
        content = await file.read()
        data = json.loads(content)
    except (json.JSONDecodeError, UnicodeDecodeError) as e:
        return JSONResponse({"status": "error", "message": f"Invalid JSON: {e}"}, 400)

    if data.get("format") != "diary-processor-backup":
        return JSONResponse(
            {"status": "error", "message": "Not a valid diary-processor backup file"},
            400,
        )

    await db.restore_backup(data)

    # Rebuild vector store from restored data
    vector_result = None
    if vector_store.VECTOR_SEARCH_ENABLED:
        try:
            await vector_store.init_collections(recreate=True)
            pool = await db.get_pool()
            vector_result = await vector_store.backfill_from_review_log(pool)
        except Exception as e:
            logger.warning("Post-restore vector backfill failed: %s", e)
            vector_result = {"status": "error", "error": str(e)}

    counts = await db.get_data_counts()
    result = {"status": "ok", "counts": dict(counts)}
    if vector_result:
        result["vector_backfill"] = vector_result
    return result


def _parse_csv_text(text: str) -> list[dict]:
    """Parse CSV text, handling NocoDB double-encoding."""
    reader = csv.reader(io.StringIO(text))
    header = next(reader)
    rows = []
    for row in reader:
        if len(row) == 1:
            inner = next(csv.reader(io.StringIO(row[0])))
            rows.append(dict(zip(header, inner)))
        else:
            rows.append(dict(zip(header, row)))
    return rows


@legacy_router.post("/api/data/import-csv")
async def data_import_csv(
    request: Request,
    mode: str = Form("upsert"),
    team_roster: UploadFile = File(None),
    person_variations: UploadFile = File(None),
    terms_roster: UploadFile = File(None),
    term_variations: UploadFile = File(None),
):
    persons, person_vars, terms_list, term_vars = [], [], [], []

    if team_roster and team_roster.filename:
        text = (await team_roster.read()).decode("utf-8-sig")
        persons = _parse_csv_text(text)

    if person_variations and person_variations.filename:
        text = (await person_variations.read()).decode("utf-8-sig")
        person_vars = _parse_csv_text(text)

    if terms_roster and terms_roster.filename:
        text = (await terms_roster.read()).decode("utf-8-sig")
        terms_list = _parse_csv_text(text)

    if term_variations and term_variations.filename:
        text = (await term_variations.read()).decode("utf-8-sig")
        term_vars = _parse_csv_text(text)

    counts = await db.import_csv_data(
        persons, person_vars, terms_list, term_vars, replace=(mode == "replace")
    )
    return {"status": "ok", **counts}


@legacy_router.post("/api/data/clear-dictionary")
async def data_clear_dictionary():
    await db.clear_dictionary()
    return {"status": "ok"}


@legacy_router.post("/api/data/reset")
async def data_reset():
    await session_ingest.get_session_ingest().reset_all_data()
    return {"status": "ok"}


# ─── Admin ────────────────────────────────────────────────────────────


@legacy_router.get("/admin", response_class=HTMLResponse)
async def admin_page(request: Request):
    """Dictionary admin page."""
    persons = await db.load_all_persons()
    terms = await db.load_all_terms()
    # asyncpg returns json columns as raw strings; parse to Python lists
    for p in persons:
        if isinstance(p["variations"], str):
            p["variations"] = json.loads(p["variations"])
    for t in terms:
        if isinstance(t["variations"], str):
            t["variations"] = json.loads(t["variations"])
    return templates.TemplateResponse(
        request,
        "admin.html",
        {
            "persons_json": json.dumps(persons),
            "terms_json": json.dumps(terms),
        },
    )


# Persons/terms/variations/vector-store CRUD routes live in
# routers/dictionary.py (SRV-A5).


# ─── Harvest ─────────────────────────────────────────────────────────

# In-memory cache of the Harvest project list. The pattern cache and the
# suggestion flow live in harvest.py.
_harvest_projects_cache: dict | None = None


def _harvest_headers() -> dict:
    return {
        "Authorization": f"Bearer {HARVEST_ACCESS_TOKEN}",
        "Harvest-Account-Id": HARVEST_ACCOUNT_ID,
        "User-Agent": "DiaryProcessor",
        "Content-Type": "application/json",
    }


@legacy_router.get("/api/harvest/pattern-status")
async def harvest_pattern_status():
    """Return status of stored Harvest entries and pattern DB."""
    return {**await harvest.status(), "has_token": bool(HARVEST_ACCESS_TOKEN)}


@legacy_router.post("/api/harvest/load-patterns")
async def harvest_load_patterns(days: int = 90):
    """Fetch Harvest time entries and store them for pattern analysis."""
    if not HARVEST_ACCESS_TOKEN:
        return JSONResponse({"error": "HARVEST_ACCESS_TOKEN not set"}, 500)

    from_date = (date_module.today() - timedelta(days=days)).isoformat()

    entries = []
    url = f"https://api.harvestapp.com/v2/time_entries?from={from_date}"
    if HARVEST_USER_ID:
        url += f"&user_id={HARVEST_USER_ID}"
    async with httpx.AsyncClient(timeout=60.0) as client:
        while url:
            resp = await client.get(url, headers=_harvest_headers())
            resp.raise_for_status()
            data = resp.json()
            entries.extend(data.get("time_entries", []))
            url = data.get("links", {}).get("next")

    # Replace the stored entries and rebuild the pattern DB
    pattern_db = await harvest.refresh(entries)

    stats = await db.get_harvest_entry_stats()
    return {
        "status": "ok",
        "entries_fetched": len(entries),
        "entries": stats,
        "pattern_keywords": len(pattern_db.get("keyword_patterns", {})),
    }


@legacy_router.post("/api/harvest/clear-patterns")
async def harvest_clear_patterns():
    """Clear stored Harvest entries and pattern DB."""
    await harvest.invalidate()
    return {"status": "ok"}


@legacy_router.get("/harvest", response_class=HTMLResponse)
async def harvest_page(request: Request, date: str = ""):
    """Harvest time tracking suggestion page."""
    if not date:
        date = str(date_module.today())
    return templates.TemplateResponse(
        request,
        "harvest.html",
        {"date": date},
    )


@legacy_router.get("/api/harvest/projects")
async def harvest_projects():
    """Fetch active Harvest projects with task assignments."""
    global _harvest_projects_cache
    if _harvest_projects_cache:
        return _harvest_projects_cache

    if not HARVEST_ACCESS_TOKEN:
        return JSONResponse({"error": "HARVEST_ACCESS_TOKEN not set"}, 500)

    try:
        projects = []
        url = "https://api.harvestapp.com/v2/users/me/project_assignments?is_active=true"
        async with httpx.AsyncClient(timeout=30.0) as client:
            while url:
                resp = await client.get(url, headers=_harvest_headers())
                resp.raise_for_status()
                data = resp.json()
                for pa in data.get("project_assignments", []):
                    proj = pa.get("project", {})
                    tasks = [
                        {"id": ta["task"]["id"], "name": ta["task"]["name"]}
                        for ta in pa.get("task_assignments", [])
                        if ta.get("is_active", True)
                    ]
                    projects.append({
                        "id": proj.get("id"),
                        "name": proj.get("name", ""),
                        "code": proj.get("code", ""),
                        "client": pa.get("client", {}).get("name", ""),
                        "tasks": tasks,
                    })
                url = data.get("links", {}).get("next")

        _harvest_projects_cache = {"projects": projects}
        return _harvest_projects_cache
    except Exception as e:
        return JSONResponse({"error": str(e)}, 502)


@legacy_router.get("/api/harvest/recent-entries")
async def harvest_recent_entries(days: int = 30):
    """Fetch recent Harvest time entries for pattern analysis."""
    if not HARVEST_ACCESS_TOKEN:
        return JSONResponse({"error": "HARVEST_ACCESS_TOKEN not set"}, 500)

    from_date = (date_module.today() - timedelta(days=days)).isoformat()

    try:
        entries = []
        url = f"https://api.harvestapp.com/v2/time_entries?from={from_date}"
        if HARVEST_USER_ID:
            url += f"&user_id={HARVEST_USER_ID}"
        async with httpx.AsyncClient(timeout=30.0) as client:
            while url:
                resp = await client.get(url, headers=_harvest_headers())
                resp.raise_for_status()
                data = resp.json()
                entries.extend(data.get("time_entries", []))
                url = data.get("links", {}).get("next")

        return {"entries": entries, "count": len(entries), "from_date": from_date}
    except Exception as e:
        return JSONResponse({"error": str(e)}, 502)


@legacy_router.get("/api/harvest/suggest")
async def harvest_suggest(date: str):
    """Generate Harvest booking suggestions for a given date."""
    return await harvest.suggest(date, fetch_events=_fetch_calendar_events)


# ─── Settings ─────────────────────────────────────────────────────────


SETTING_DEFAULTS = {
    "lightrag_url": "http://192.168.2.16:9621",
    "lightrag_api_key": "",
}


@legacy_router.get("/api/settings")
async def get_settings():
    """Return all app settings with defaults filled in."""
    stored = await db.get_all_settings()
    result = {**SETTING_DEFAULTS, **stored}
    return result


@legacy_router.put("/api/settings")
async def update_settings(request: Request):
    """Update one or more settings."""
    body = await request.json()
    for key, value in body.items():
        await db.set_setting(key, str(value))
    return {"status": "ok"}


# ─── Ingest ──────────────────────────────────────────────────────────


@legacy_router.get("/ingest", response_class=HTMLResponse)
async def ingest_page(request: Request):
    """Audio file ingestion page."""
    return templates.TemplateResponse(
        request,
        "ingest.html",
        {"ingest_url": WHISPER_URL},
    )


@legacy_router.get("/api/ingest/history")
async def ingest_history(limit: int = 100):
    """Return recent upload history."""
    uploads = await db.list_ingest_uploads(limit)
    rows = []
    for u in uploads:
        rows.append({
            "id": u["id"],
            "filename": u["filename"],
            "file_size": u["file_size"],
            "status": u["status"],
            "error": u["error_message"],
            "transcript_id": u["transcript_id"],
            "review_url": u["review_url"],
            "created_at": u["created_at"].isoformat() if u.get("created_at") else None,
            "completed_at": u["completed_at"].isoformat() if u.get("completed_at") else None,
        })
    return {"uploads": rows}


@legacy_router.post("/api/ingest/clear-history")
async def ingest_clear_history():
    """Clear all upload history."""
    await db.clear_ingest_history()
    return {"status": "ok"}


async def _ingest_audio_to_transcript(
    content: bytes, filename: str
) -> tuple[int, str, str]:
    """Pipeline: ffmpeg → Whisper → persist. Returns (transcript_id, review_url, text).

    Delegates the shared transcribe+persist core to `transcript_ingest`
    (SRV-A7) — the same core `session_ingest` drives per segment.
    """
    src_suffix = Path(filename).suffix.lower() or ".mp3"
    result = await transcript_ingest.transcribe_and_persist(
        content,
        src_suffix=src_suffix,
        filename=filename,
        date=filename,
        author="Florian Wolf",
    )
    review_url = f"/review/{result.transcript_id}"
    return result.transcript_id, review_url, result.raw_text


@legacy_router.post("/api/ingest/upload")
async def ingest_upload(file: UploadFile = File(...)):
    """Accept an audio upload, run ffmpeg + Whisper locally, persist transcript."""
    content = await file.read()
    filename = file.filename or "upload.mp3"
    file_size = len(content)

    upload_id = await db.create_ingest_upload(filename, file_size)
    try:
        transcript_id, review_url, text = await _ingest_audio_to_transcript(
            content, filename
        )
        await db.mark_ingest_success(upload_id, transcript_id, review_url)
        return {
            "status": "ok",
            "upload_id": upload_id,
            "filename": filename,
            "result": {
                "id": transcript_id,
                "review_url": review_url,
                "preview": text[:500],
            },
        }
    except asr_client.AsrTimeoutError:
        await db.mark_ingest_failed(upload_id, "Whisper request timed out")
        return JSONResponse(
            {"status": "error", "message": "Whisper request timed out", "upload_id": upload_id, "filename": filename},
            504,
        )
    except (asr_client.AsrUnavailableError, asr_client.AsrEngineError) as e:
        msg = str(e)
        await db.mark_ingest_failed(upload_id, msg)
        return JSONResponse(
            {"status": "error", "message": msg, "upload_id": upload_id, "filename": filename},
            502,
        )
    except Exception as e:
        logger.exception("ingest upload failed for %s", filename)
        await db.mark_ingest_failed(upload_id, str(e))
        return JSONResponse(
            {"status": "error", "message": str(e), "upload_id": upload_id, "filename": filename},
            502,
        )


@legacy_router.post("/api/ingest/{upload_id}/retry")
async def ingest_retry(upload_id: int, file: UploadFile = File(...)):
    """Retry a failed upload by re-running the local ASR pipeline."""
    content = await file.read()
    filename = file.filename or "upload.mp3"

    await db.reset_ingest_upload_for_retry(upload_id)

    try:
        transcript_id, review_url, text = await _ingest_audio_to_transcript(
            content, filename
        )
        await db.mark_ingest_success(upload_id, transcript_id, review_url)
        return {
            "status": "ok",
            "upload_id": upload_id,
            "filename": filename,
            "result": {
                "id": transcript_id,
                "review_url": review_url,
                "preview": text[:500],
            },
        }
    except Exception as e:
        logger.exception("ingest retry failed for %s", filename)
        await db.mark_ingest_failed(upload_id, str(e))
        return JSONResponse(
            {"status": "error", "message": str(e), "upload_id": upload_id, "filename": filename},
            502,
        )


# ─── Skeleton Sync ──────────────────────────────────────────────────


@legacy_router.get("/api/skeleton/status")
async def skeleton_status():
    import skeleton_sync
    return await skeleton_sync.get_sync_status()


@legacy_router.get("/api/skeleton/diff")
async def skeleton_diff():
    import skeleton_sync
    return await skeleton_sync.get_sync_diff()


@legacy_router.get("/api/skeleton/bones")
async def skeleton_bones():
    import skeleton_sync
    return await skeleton_sync.list_bones()


@legacy_router.get("/api/skeleton/log")
async def skeleton_log(limit: int = 20):
    import skeleton_sync
    return await skeleton_sync.get_sync_log(limit)


@legacy_router.post("/api/skeleton/sync")
async def skeleton_sync_trigger(request: Request):
    import skeleton_sync
    body = await request.json()
    mode = body.get("mode", "incremental")
    force = body.get("force", False)
    if mode == "full":
        stats = await skeleton_sync.sync_full(triggered_by="api", force=force)
    else:
        stats = await skeleton_sync.sync_incremental(triggered_by="api")
    return {"status": "ok", "stats": stats.to_dict()}


@legacy_router.post("/api/skeleton/sync/{bone_id:path}")
async def skeleton_sync_single(bone_id: str):
    import skeleton_sync
    result = await skeleton_sync.sync_single_bone(bone_id)
    return {"status": "ok", "result": result, "bone_id": bone_id}


@legacy_router.get("/api/skeleton/render/{bone_id:path}")
async def skeleton_render(bone_id: str):
    import skeleton_sync
    content = await skeleton_sync.render_bone(bone_id)
    if content is None:
        return JSONResponse({"error": "Bone not found"}, 404)
    return {"bone_id": bone_id, "content": content}


# Org-units/relationships/role-assignments/static-entities/initiatives CRUD
# routes live in routers/admin.py (SRV-A5).


# Must stay last: include_router copies routes at call time, so any
# legacy route declared below this line would never be registered.
app.include_router(legacy_router)
