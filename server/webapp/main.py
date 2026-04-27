import asyncio
import csv
import io
import json
import logging
import os
import re
import tempfile
from contextlib import asynccontextmanager
from dataclasses import asdict
from datetime import date as date_module, datetime, timedelta
from zoneinfo import ZoneInfo
from pathlib import Path

from dotenv import load_dotenv
load_dotenv(Path(__file__).resolve().parent.parent / ".env")

logging.basicConfig(level=logging.INFO, format="%(levelname)s:     %(name)s - %(message)s")
logger = logging.getLogger(__name__)

import httpx
from fastapi import FastAPI, Form, Request, UploadFile, File
from fastapi.responses import HTMLResponse, JSONResponse, RedirectResponse, StreamingResponse
from sse_starlette.sse import EventSourceResponse
from fastapi.staticfiles import StaticFiles
from fastapi.templating import Jinja2Templates

import db
import document_processor
import llm_validator
import harvest_patterns
import harvest_llm
import fluency_checker
import transcript_corrector
import vector_store
from entity_detector import detect_entities
from llm_validator import validate_entities_stream

WHISPER_URL = os.getenv("WHISPER_URL", "http://whisper:9000")
HARVEST_ACCESS_TOKEN = os.getenv("HARVEST_ACCESS_TOKEN", "")
HARVEST_ACCOUNT_ID = os.getenv("HARVEST_ACCOUNT_ID", "")
HARVEST_USER_ID = os.getenv("HARVEST_USER_ID", "")

BASE_DIR = Path(__file__).resolve().parent


@asynccontextmanager
async def lifespan(app: FastAPI):
    # Log configuration on startup
    logger.info("=== Diary Processor starting ===")
    logger.info("OLLAMA_BASE_URL    = %s", os.getenv("OLLAMA_BASE_URL", "(not set)"))
    logger.info("OLLAMA_MODEL       = %s", os.getenv("OLLAMA_MODEL", "(not set)"))
    logger.info("OLLAMA_TIMEOUT     = %s", os.getenv("OLLAMA_TIMEOUT", "(not set)"))
    logger.info("LLM_VALIDATION_ENABLED = %s", os.getenv("LLM_VALIDATION_ENABLED", "(not set)"))
    logger.info("LLM_CORRECTION_ENABLED = %s", os.getenv("LLM_CORRECTION_ENABLED", "(not set, falls back to LLM_VALIDATION_ENABLED)"))
    logger.info("FLUENCY_CHECK_ENABLED = %s", os.getenv("FLUENCY_CHECK_ENABLED", "(not set, defaults to true)"))
    logger.info("WHISPER_URL        = %s", WHISPER_URL)
    logger.info("DATABASE_URL       = %s", os.getenv("DATABASE_URL", "(not set)"))
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

    yield
    await vector_store.close()
    await db.close_pool()


app = FastAPI(title="Diary Transcript Review", lifespan=lifespan)
app.mount("/static", StaticFiles(directory=BASE_DIR / "static"), name="static")
templates = Jinja2Templates(directory=str(BASE_DIR / "templates"))

# iOS-facing routers (bearer-token auth applied per-router via Depends,
# except `/health` which is reachable pre-onboarding for the Tailscale probe).
from routers.calendar import router as calendar_router  # noqa: E402
from routers.email import router as email_router  # noqa: E402
from routers.lightrag import router as lightrag_router  # noqa: E402
from routers.sessions import router as sessions_router  # noqa: E402
from routers.health import router as health_router  # noqa: E402

app.include_router(calendar_router)
app.include_router(email_router)
app.include_router(lightrag_router)
app.include_router(sessions_router)
app.include_router(health_router)


# ─── Text correction pre-processing ──────────────────────────────────


def apply_text_corrections(
    raw_text: str, corrections: list[dict]
) -> tuple[str, list[dict]]:
    """Apply learned word corrections to raw transcript text.

    Returns (corrected_text, list_of_applied_corrections).
    Corrections are sorted longest-first and matched with word boundaries.
    """
    applied = []
    result = raw_text
    # corrections already sorted longest-first from DB query
    for corr in corrections:
        original = corr["original_text"]
        replacement = corr["corrected_text"]
        case_sensitive = corr.get("case_sensitive", False)
        flags = 0 if case_sensitive else re.IGNORECASE
        pattern = r"\b" + re.escape(original) + r"\b"
        new_result, count = re.subn(pattern, replacement, result, flags=flags)
        if count > 0:
            applied.append(
                {
                    "original": original,
                    "corrected": replacement,
                    "count": count,
                }
            )
            result = new_result
    return result, applied


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


@app.get("/", response_class=HTMLResponse)
async def index(request: Request):
    """Transcript list page."""
    transcripts = await db.list_transcripts()
    # Batch-fetch which transcripts have processed documents
    pool = await db.get_pool()
    doc_rows = await pool.fetch(
        "SELECT transcript_id, MAX(id) AS latest_doc_id "
        "FROM processed_documents GROUP BY transcript_id"
    )
    doc_map = {r["transcript_id"]: r["latest_doc_id"] for r in doc_rows}
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


@app.get("/review/{transcript_id}", response_class=HTMLResponse)
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
            raw_text, applied_corrections = apply_text_corrections(
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


@app.get("/api/transcripts/{transcript_id}/process")
async def process_transcript_stream(transcript_id: int):
    """SSE endpoint: combined pipeline — LLM correction, entity detection, LLM validation."""
    transcript = await db.get_transcript(transcript_id)
    if not transcript:
        return JSONResponse({"error": "not found"}, 404)

    # Pre-load all data needed for the pipeline
    persons = await db.load_person_dictionary()
    terms = await db.load_term_dictionary()
    text_corrections = await db.load_text_corrections()
    dismissals = await db.load_entity_dismissals()

    raw_text = transcript["raw_text"]

    async def event_generator():
        nonlocal raw_text

        yield {"event": "log", "data": json.dumps({"message": "Applying dictionary corrections...", "level": "info"})}

        # Phase 0: Apply dictionary text corrections (fast)
        applied_corrections = []
        if text_corrections:
            raw_text, applied_corrections = apply_text_corrections(
                raw_text, text_corrections
            )

        # Phase 1: LLM transcript correction
        llm_corrections = []
        if transcript_corrector.LLM_CORRECTION_ENABLED:
            # Query vector store for similar past corrections
            correction_examples = []
            if vector_store.VECTOR_SEARCH_ENABLED:
                yield {"event": "log", "data": json.dumps({"message": "Querying vector store for similar corrections...", "level": "info"})}
                # Sample up to 5 passages (~200 chars each) from the transcript
                passage_len = 200
                passages = [
                    raw_text[i : i + passage_len]
                    for i in range(0, len(raw_text), passage_len)
                ][:5]
                seen = set()
                for passage in passages:
                    results = await vector_store.find_similar_corrections(passage, limit=3)
                    for r in results:
                        key = f"{r['original_text']}|{r['corrected_text']}"
                        if key not in seen:
                            seen.add(key)
                            correction_examples.append(r)
                correction_examples = correction_examples[:10]
                if correction_examples:
                    yield {"event": "log", "data": json.dumps({"message": f"Found {len(correction_examples)} similar past corrections", "level": "ok"})}

            yield {"event": "log", "data": json.dumps({"message": "Calling Ollama for transcript correction...", "level": "info"})}
            raw_text, llm_corrections = await transcript_corrector.correct_transcript(
                raw_text, correction_examples=correction_examples or None
            )
            if llm_corrections:
                yield {"event": "log", "data": json.dumps({"message": f"Applied {len(llm_corrections)} LLM correction(s)", "level": "ok"})}
            else:
                yield {"event": "log", "data": json.dumps({"message": "No LLM corrections needed", "level": "info"})}
        else:
            yield {"event": "log", "data": json.dumps({"message": "LLM transcript correction disabled", "level": "info"})}

        # Send corrected text + corrections to client
        yield {
            "event": "correction",
            "data": json.dumps({
                "text": raw_text,
                "corrections": llm_corrections,
                "applied_corrections": applied_corrections,
            }),
        }

        # Phase 1.5: Fluency check
        fluency_issues = []
        if fluency_checker.FLUENCY_CHECK_ENABLED:
            yield {"event": "log", "data": json.dumps({"message": "Checking transcript fluency...", "level": "info"})}
            fluency_issues = await fluency_checker.check_fluency(raw_text)
            if fluency_issues:
                yield {"event": "log", "data": json.dumps({"message": f"Found {len(fluency_issues)} fluency issue(s)", "level": "warn"})}
            else:
                yield {"event": "log", "data": json.dumps({"message": "No fluency issues found", "level": "info"})}
        else:
            yield {"event": "log", "data": json.dumps({"message": "Fluency check disabled", "level": "info"})}

        yield {
            "event": "fluency",
            "data": json.dumps({"issues": fluency_issues}),
        }

        # Phase 2: Entity detection on corrected text
        yield {"event": "log", "data": json.dumps({"message": "Detecting entities...", "level": "info"})}
        entities = detect_entities(raw_text, persons, terms)

        # Filter out dismissed entity patterns
        if dismissals:
            dismissals_lower = {d.lower() for d in dismissals}
            entities = [
                e
                for e in entities
                if e.original_text.lower() not in dismissals_lower
            ]

        yield {"event": "log", "data": json.dumps({"message": f"Found {len(entities)} entities", "level": "ok"})}

        # Send entities to client
        yield {
            "event": "entities",
            "data": json.dumps([asdict(e) for e in entities]),
        }

        # Phase 3: LLM entity validation
        entity_usage_samples = None
        if vector_store.VECTOR_SEARCH_ENABLED and llm_validator.LLM_VALIDATION_ENABLED:
            yield {"event": "log", "data": json.dumps({"message": "Querying vector store for entity usage samples...", "level": "info"})}
            entity_usage_samples = {}
            for ent in entities:
                if ent.status in ("suggested", "ambiguous") or ent.confidence in ("medium", "low"):
                    # Get context snippet for this entity
                    ctx = raw_text[max(0, ent.start - 50) : min(len(raw_text), ent.end + 50)]
                    key = f"{ent.canonical}|{ent.entity_type}"
                    if key not in entity_usage_samples:
                        samples = await vector_store.find_entity_usage_samples(
                            ent.canonical, ent.entity_type, context=ctx, limit=5
                        )
                        if samples:
                            entity_usage_samples[key] = samples
                    # For ambiguous entities, also fetch samples for each candidate
                    if ent.status == "ambiguous" and ent.candidates:
                        for cand in ent.candidates:
                            cand_key = f"{cand['canonical']}|{ent.entity_type}"
                            if cand_key not in entity_usage_samples:
                                cand_samples = await vector_store.find_entity_usage_samples(
                                    cand["canonical"], ent.entity_type, context=ctx, limit=3
                                )
                                if cand_samples:
                                    entity_usage_samples[cand_key] = cand_samples

            total_samples = sum(len(v) for v in entity_usage_samples.values())
            if total_samples:
                yield {"event": "log", "data": json.dumps({"message": f"Retrieved {total_samples} entity usage samples for {len(entity_usage_samples)} entities", "level": "ok"})}
            else:
                entity_usage_samples = None

        yield {"event": "log", "data": json.dumps({"message": "Validating entities with LLM...", "level": "info"})}
        async for event in validate_entities_stream(raw_text, entities, entity_usage_samples=entity_usage_samples):
            yield event

    return EventSourceResponse(event_generator())


# ─── Document Processing ──────────────────────────────────────────────


@app.get("/process/{transcript_id}")
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


@app.get("/api/transcripts/{transcript_id}/process-document")
async def process_document_stream(transcript_id: int):
    """SSE endpoint: runs the full document processing pipeline."""
    transcript = await db.get_transcript(transcript_id)
    if not transcript:
        return JSONResponse({"error": "not found"}, 404)

    # Pre-extract entity data from transcript
    entities_raw = transcript.get("entities_json")
    entities = []
    if entities_raw:
        if isinstance(entities_raw, str):
            try:
                entities = json.loads(entities_raw)
            except json.JSONDecodeError:
                pass
        elif isinstance(entities_raw, list):
            entities = entities_raw

    date_str = str(transcript["date"]) if transcript.get("date") else ""
    person_names = [
        e.get("text") or e.get("canonical", "")
        for e in entities
        if (e.get("type") or e.get("entity_type", "")) == "PERSON"
    ]

    async def event_generator():
        # Step 1: Query LightRAG context (parallel)
        yield {"event": "step", "data": json.dumps({"step": "context", "state": "active"})}
        yield {"event": "log", "data": json.dumps({"message": "Querying LightRAG for context...", "level": "info"})}

        try:
            recent_ctx, entity_hist = await asyncio.gather(
                document_processor.query_lightrag_context(date_str),
                document_processor.query_lightrag_entity_history(person_names, date_str),
            )
        except Exception as e:
            recent_ctx, entity_hist = "", ""
            yield {"event": "log", "data": json.dumps({"message": f"LightRAG query failed: {e}", "level": "error"})}

        yield {"event": "context", "data": json.dumps({"recent": recent_ctx[:200], "entities": entity_hist[:200]})}
        yield {"event": "step", "data": json.dumps({"step": "context", "state": "done"})}

        # Step 2: Summarize context
        yield {"event": "step", "data": json.dumps({"step": "summary", "state": "active"})}
        yield {"event": "log", "data": json.dumps({"message": "Summarizing context via LLM...", "level": "info"})}

        try:
            context_summary = await document_processor.summarize_context(
                recent_ctx, entity_hist, date_str
            )
        except Exception as e:
            context_summary = "Keine historischen Daten verfügbar."
            yield {"event": "log", "data": json.dumps({"message": f"Summarization failed: {e}", "level": "error"})}

        yield {"event": "summary", "data": json.dumps({"summary": context_summary})}
        yield {"event": "step", "data": json.dumps({"step": "summary", "state": "done"})}

        # Build enriched context
        enriched = document_processor.build_enriched_context(
            transcript, entities, context_summary
        )

        # Step 3: Analyze transcript
        yield {"event": "step", "data": json.dumps({"step": "analysis", "state": "active"})}
        yield {"event": "log", "data": json.dumps({"message": "Analyzing transcript via LLM (this may take a while)...", "level": "info"})}

        try:
            analysis = await document_processor.analyze_transcript(enriched)
        except Exception as e:
            error_msg = str(e) or type(e).__name__
            logger.error("Document analysis failed for transcript %s: %s", transcript_id, error_msg)
            yield {"event": "step", "data": json.dumps({"step": "analysis", "state": "error"})}
            yield {"event": "log", "data": json.dumps({"message": f"Analysis failed: {error_msg}", "level": "error"})}
            yield {"event": "error", "data": json.dumps({"message": f"Analysis failed: {error_msg}"})}
            return

        yield {"event": "analysis", "data": json.dumps({"analysis": analysis})}
        yield {"event": "step", "data": json.dumps({"step": "analysis", "state": "done"})}

        # Step 4: Generate document
        yield {"event": "step", "data": json.dumps({"step": "document", "state": "active"})}
        yield {"event": "log", "data": json.dumps({"message": "Generating narrative document...", "level": "info"})}

        markdown = document_processor.generate_narrative_document(enriched, analysis)
        metadata = document_processor.build_document_metadata(enriched)

        # Save to database
        try:
            doc_row = await db.save_processed_document(
                transcript_id=transcript_id,
                document_markdown=markdown,
                analysis_json=analysis,
                context_summary=context_summary,
                metadata=metadata,
            )
            doc_id = doc_row["id"]
            version = doc_row["version"]
        except Exception as e:
            yield {"event": "step", "data": json.dumps({"step": "document", "state": "error"})}
            yield {"event": "error", "data": json.dumps({"message": f"Failed to save document: {e}"})}
            return

        yield {
            "event": "document",
            "data": json.dumps({
                "doc_id": doc_id,
                "version": version,
                "markdown": markdown,
                "metadata": metadata,
            }),
        }
        yield {"event": "step", "data": json.dumps({"step": "document", "state": "done"})}
        yield {"event": "done", "data": json.dumps({"doc_id": doc_id})}

    return EventSourceResponse(event_generator())


@app.get("/api/documents/{doc_id}")
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


@app.post("/api/documents/{doc_id}/save")
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


@app.post("/api/documents/{doc_id}/ingest")
async def ingest_document(doc_id: int):
    """Send a processed document to LightRAG."""
    doc = await db.get_processed_document(doc_id)
    if not doc:
        return JSONResponse({"status": "error", "message": "Document not found"}, 404)

    metadata = doc["metadata"] or {}
    try:
        await document_processor.ingest_to_lightrag(doc["document_markdown"], metadata)
    except Exception as e:
        return JSONResponse({"status": "error", "message": str(e)}, 500)

    result = await db.mark_document_ingested(doc_id)
    return {
        "status": "ok",
        "ingested_at": result["lightrag_ingested_at"].isoformat() if result else None,
    }


# ─── Calendar ─────────────────────────────────────────────────────────


LOCAL_TZ = ZoneInfo(os.getenv("TZ", "Europe/Berlin"))

def _to_local_iso(iso_str: str) -> str:
    """Convert an ISO datetime string (possibly UTC) to local timezone."""
    if not iso_str:
        return iso_str
    # Remove trailing 'Z' and parse
    clean = iso_str.replace("Z", "+00:00")
    try:
        dt = datetime.fromisoformat(clean)
        if dt.tzinfo is None:
            # Naive datetimes from Microsoft Graph are UTC
            dt = dt.replace(tzinfo=ZoneInfo("UTC"))
        dt = dt.astimezone(LOCAL_TZ)
        return dt.isoformat()
    except (ValueError, TypeError):
        return iso_str


async def _fetch_calendar_events(date_str: str) -> list[dict]:
    """Fetch raw Graph-shaped calendar events for the given local date.

    Used by `/api/calendar/{date}` (HTMX review widget) and
    `/api/harvest/suggest`. Returns events in Graph's native shape
    (`start.dateTime`, `attendees[i].emailAddress.name`, …) so the
    existing UI layers don't need to change.
    """
    from datetime import time as _time
    from msgraph_client import (
        MSGraphError,
        MSGraphNotBootstrapped,
        get_client,
    )

    try:
        d = date_module.fromisoformat(date_str)
    except ValueError:
        return []

    start_local = datetime.combine(d, _time.min, tzinfo=LOCAL_TZ)
    end_local = start_local + timedelta(days=1)
    start_utc = start_local.astimezone(ZoneInfo("UTC")).strftime("%Y-%m-%dT%H:%M:%S.0000000")
    end_utc = end_local.astimezone(ZoneInfo("UTC")).strftime("%Y-%m-%dT%H:%M:%S.0000000")

    try:
        client = await get_client()
        data = await client.get_json(
            "/me/calendarView",
            params={
                "startDateTime": start_utc,
                "endDateTime": end_utc,
                "$top": 100,
                "$orderby": "start/dateTime",
                "$select": (
                    "id,subject,start,end,isAllDay,showAs,bodyPreview,"
                    "responseStatus,organizer,attendees,recurrence,webLink"
                ),
            },
        )
    except (MSGraphNotBootstrapped, MSGraphError) as exc:
        logger.warning("calendar fetch failed for %s: %s", date_str, exc)
        return []

    return data.get("value", []) or []


@app.get("/api/calendar/{date_str}")
async def get_calendar_events(date_str: str):
    """Calendar events for a specific date.

    Stub for Server S1 — returns an empty list. Server S2 wires this to
    `webapp/msgraph_client.py` for direct MS Graph access.
    """
    events = await _fetch_calendar_events(date_str)
    return {"date": date_str, "events": events}


# ─── API ─────────────────────────────────────────────────────────────


@app.get("/api/dictionary")
async def get_dictionary():
    """Full entity dictionary."""
    persons = await db.load_person_dictionary()
    terms = await db.load_term_dictionary()
    return {"persons": persons, "terms": terms}


@app.post("/api/transcripts")
async def upload_transcript(
    filename: str = Form(...),
    date_str: str = Form(..., alias="date"),
    author: str = Form("Florian Wolf"),
    raw_text: str = Form(...),
):
    """Manually add a transcript to the review queue."""
    tid = await db.create_transcript(filename, date_str, author, raw_text)
    return {"id": tid, "status": "pending"}


@app.post("/api/transcripts/delete")
async def delete_transcripts(request: Request):
    """Delete selected transcripts by IDs."""
    body = await request.json()
    ids = body.get("ids", [])
    if ids:
        await db.delete_transcripts(ids)
    return {"status": "ok", "deleted": len(ids)}


@app.get("/api/transcripts/status")
async def transcripts_status():
    """Return current status for recently submitted transcripts (last 24h)."""
    pool = await db.get_pool()
    rows = await pool.fetch("""
        SELECT id, status, submitted_at, processed_at, processing_error
        FROM transcripts
        WHERE status IN ('submitted', 'failed', 'processed')
          AND submitted_at > NOW() - INTERVAL '24 hours'
        ORDER BY id
    """)
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


@app.post("/api/transcripts/{transcript_id}/retry")
async def retry_transcript(transcript_id: int):
    """Reset a failed transcript so it can be re-processed.

    Local pipeline replaces the old n8n forward: the user re-runs the
    SSE pipeline at /process/{id} after this call resets state.
    """
    transcript = await db.get_transcript(transcript_id)
    if not transcript:
        return JSONResponse({"error": "not found"}, 404)
    if transcript["status"] != "failed":
        return JSONResponse({"error": "transcript is not in failed state"}, 400)

    pool = await db.get_pool()
    await pool.execute(
        """
        UPDATE transcripts
        SET status = 'submitted', processing_error = NULL,
            processed_at = NULL, submitted_at = NOW()
        WHERE id = $1
        """,
        transcript_id,
    )
    return {"status": "submitted", "process_url": f"/process/{transcript_id}"}


@app.post("/api/transcripts/{transcript_id}/reset")
async def reset_transcript(transcript_id: int):
    """Reset a transcript's saved data so it can be reprocessed."""
    transcript = await db.get_transcript(transcript_id)
    if not transcript:
        return JSONResponse({"error": "not found"}, 404)
    await db.reset_transcript(transcript_id)
    return {"status": "reset"}


@app.post("/api/transcripts/{transcript_id}/save")
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

    # Create new dictionary entries so they're available for other transcripts
    new_entries = 0
    for ent in body.get("entities", []):
        if ent.get("status") != "new-entity":
            continue
        canonical = ent.get("canonical", "")
        if not canonical:
            continue
        etype = ent.get("entity_type", "")
        source = ent.get("source", "")
        if source == "person" or etype == "PERSON":
            await db.create_person(canonical_name=canonical)
        else:
            category = etype.lower() if etype else "term"
            await db.create_term(canonical_term=canonical, category=category)
        new_entries += 1

    # Save new variations (corrections to existing dictionary entries)
    for ent in body.get("entities", []):
        did = ent.get("dictionary_id")
        if not did:
            continue
        original = ent.get("original_text", "")
        canonical = ent.get("canonical", "")
        if not original or not canonical or original == canonical:
            continue
        source = ent.get("source", "")
        if source == "person":
            await db.save_person_variation(did, original, "asr_correction")
        else:
            await db.save_term_variation(did, original)

    # Save inline text edits as text corrections
    for edit in body.get("text_edits", []):
        old_word = edit.get("oldWord", "").strip()
        new_word = edit.get("newWord", "").strip()
        if old_word and new_word and old_word != new_word:
            await db.save_text_correction(old_word, new_word, "word")

    return {"status": "saved", "new_dictionary_entries": new_entries}


@app.post("/api/transcripts/{transcript_id}/submit")
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

    # 2. Save new variations (dictionary growth)
    for var in body.get("new_variations", []):
        if var.get("dictionary_id"):
            if var["source"] == "person":
                await db.save_person_variation(
                    var["dictionary_id"], var["original"], "asr_correction"
                )
            else:
                await db.save_term_variation(
                    var["dictionary_id"], var["original"]
                )

    # 3. Save disambiguated first-name matches as variations
    for dis in body.get("disambiguated", []):
        if dis.get("chosen_id") and dis.get("original"):
            await db.save_person_variation(
                dis["chosen_id"], dis["original"], "nickname"
            )

    # 4. Create new dictionary entries for manually added entities
    for new_ent in body.get("new_entities", []):
        if new_ent.get("source") == "person":
            await db.create_person(canonical_name=new_ent["text"])
        else:
            await db.create_term(
                canonical_term=new_ent["text"],
                category=new_ent.get("category", new_ent["type"].lower()),
            )

    # 5. Save inline text edits as text corrections
    for edit in body.get("text_edits", []):
        old_word = edit.get("oldWord", "").strip()
        new_word = edit.get("newWord", "").strip()
        if old_word and new_word and old_word != new_word:
            await db.save_text_correction(old_word, new_word, "word")

    # 5b. Save dismissed entities as entity_dismissal corrections
    for dismissed in body.get("dismissed", []):
        original = dismissed.get("original", "").strip()
        if original:
            await db.save_text_correction(original, original, "entity_dismissal")

    # 6. Log all review actions
    for ent in body.get("entities", []):
        action = "corrected" if ent.get("is_correction") else "confirmed"
        await db.log_review_action(
            transcript_id,
            ent.get("original", ent["text"]),
            ent["text"],
            ent["type"],
            ent.get("match_type", "auto-matched"),
            action,
        )
    for dismissed in body.get("dismissed", []):
        await db.log_review_action(
            transcript_id,
            dismissed["original"],
            dismissed["canonical"],
            dismissed["type"],
            "auto-matched",
            "dismissed",
        )

    # 7. Store vectors for contextual learning (fire-and-forget)
    if vector_store.VECTOR_SEARCH_ENABLED:
        corrected_text = body["corrected_transcript"]
        transcript_date = body.get("date", str(date_module.today()))

        async def _store_vectors():
            try:
                # Remove existing vectors for this transcript to prevent duplicates
                await vector_store.delete_transcript_vectors(transcript_id)

                # Store text edits as correction contexts
                for edit in body.get("text_edits", []):
                    old_word = edit.get("oldWord", "").strip()
                    new_word = edit.get("newWord", "").strip()
                    if old_word and new_word and old_word != new_word:
                        # Find position in corrected text
                        match = re.search(re.escape(new_word), corrected_text)
                        if match:
                            await vector_store.store_correction_context(
                                original_text=old_word,
                                corrected_text=new_word,
                                full_text=corrected_text,
                                start=match.start(),
                                end=match.end(),
                                correction_type="text_edit",
                                transcript_id=transcript_id,
                                transcript_date=transcript_date,
                            )

                # Store entity corrections and confirmed entities
                for ent in body.get("entities", []):
                    start = ent.get("start", 0)
                    end = ent.get("end", 0)
                    original = ent.get("original", ent.get("text", ""))
                    canonical = ent.get("text", "")

                    # Store entity correction context if original differs from canonical
                    if ent.get("is_correction") and original.lower() != canonical.lower():
                        await vector_store.store_correction_context(
                            original_text=original,
                            corrected_text=canonical,
                            full_text=corrected_text,
                            start=start,
                            end=end,
                            correction_type="entity_correction",
                            transcript_id=transcript_id,
                            transcript_date=transcript_date,
                        )

                    # Store confirmed/corrected entity as usage sample
                    await vector_store.store_entity_sample(
                        entity_canonical=canonical,
                        entity_type=ent.get("type", ""),
                        entity_id=ent.get("dictionary_id") or ent.get("dictionaryId"),
                        source=ent.get("source", ""),
                        original_text=original,
                        full_text=corrected_text,
                        start=start,
                        end=end,
                        match_type=ent.get("match_type", ""),
                        action="corrected" if ent.get("is_correction") else "confirmed",
                        transcript_id=transcript_id,
                        transcript_date=transcript_date,
                    )

                logger.info("Stored vectors for transcript %s", transcript_id)
            except Exception as e:
                logger.warning("Failed to store vectors for transcript %s: %s", transcript_id, e)

        asyncio.create_task(_store_vectors())

    return {"status": "submitted"}


# ─── Data Management ──────────────────────────────────────────────────


@app.get("/settings", response_class=HTMLResponse)
async def settings_page(request: Request):
    counts = await db.get_data_counts()
    return templates.TemplateResponse(
        request,
        "data.html",
        {"counts_json": json.dumps(dict(counts))},
    )


@app.get("/data", response_class=HTMLResponse)
async def data_page_redirect():
    return RedirectResponse("/settings", status_code=301)


@app.get("/api/data/backup")
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


@app.post("/api/data/restore")
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


@app.post("/api/data/import-csv")
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


@app.post("/api/data/clear-dictionary")
async def data_clear_dictionary():
    await db.clear_dictionary()
    return {"status": "ok"}


@app.post("/api/data/reset")
async def data_reset():
    await db.reset_all_data()
    return {"status": "ok"}


# ─── Admin ────────────────────────────────────────────────────────────


@app.get("/admin", response_class=HTMLResponse)
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


@app.put("/api/admin/persons/{person_id}")
async def admin_update_person(person_id: int, request: Request):
    body = await request.json()
    await db.update_person(
        person_id,
        first_name=body.get("first_name", ""),
        last_name=body.get("last_name", ""),
        role=body.get("role", ""),
        department=body.get("department", ""),
        company=body.get("company", ""),
        context=body.get("context", ""),
        status=body.get("status", "active"),
    )
    return {"status": "ok"}


@app.delete("/api/admin/persons/{person_id}")
async def admin_delete_person(person_id: int):
    await db.delete_person(person_id)
    return {"status": "ok"}


@app.post("/api/admin/persons")
async def admin_create_person(request: Request):
    body = await request.json()
    first = body.get("first_name", "").strip()
    last = body.get("last_name", "").strip()
    canonical = f"{first} {last}".strip()
    pid = await db.create_person(
        canonical_name=canonical,
        first_name=first,
        last_name=last,
        role=body.get("role", ""),
        company=body.get("company", ""),
        context=body.get("context", ""),
    )
    return {"status": "ok", "id": pid, "canonical_name": canonical}


@app.post("/api/admin/persons/{person_id}/variations")
async def admin_add_person_variation(person_id: int, request: Request):
    body = await request.json()
    await db.save_person_variation(
        person_id, body["text"], body.get("type", "asr_correction")
    )
    # Return the newly created variation's ID
    pool = await db.get_pool()
    row = await pool.fetchrow(
        "SELECT id FROM person_variations WHERE person_id = $1 AND variation = $2",
        person_id,
        body["text"],
    )
    return {"status": "ok", "id": row["id"] if row else None}


@app.delete("/api/admin/persons/{person_id}/variations/{variation_id}")
async def admin_delete_person_variation(person_id: int, variation_id: int):
    await db.delete_person_variation(variation_id)
    return {"status": "ok"}


@app.put("/api/admin/terms/{term_id}")
async def admin_update_term(term_id: int, request: Request):
    body = await request.json()
    await db.update_term(
        term_id,
        canonical_term=body.get("canonical_term", ""),
        category=body.get("category", ""),
        context=body.get("context", ""),
        status=body.get("status", "active"),
    )
    return {"status": "ok"}


@app.delete("/api/admin/terms/{term_id}")
async def admin_delete_term(term_id: int):
    await db.delete_term(term_id)
    return {"status": "ok"}


@app.post("/api/admin/terms")
async def admin_create_term(request: Request):
    body = await request.json()
    name = body.get("canonical_term", "").strip()
    tid = await db.create_term(
        canonical_term=name,
        category=body.get("category", "term"),
        context=body.get("context", ""),
    )
    return {"status": "ok", "id": tid, "canonical_term": name}


@app.post("/api/admin/terms/{term_id}/variations")
async def admin_add_term_variation(term_id: int, request: Request):
    body = await request.json()
    await db.save_term_variation(term_id, body["text"])
    pool = await db.get_pool()
    row = await pool.fetchrow(
        "SELECT id FROM term_variations WHERE term_id = $1 AND variation = $2",
        term_id,
        body["text"],
    )
    return {"status": "ok", "id": row["id"] if row else None}


@app.delete("/api/admin/terms/{term_id}/variations/{variation_id}")
async def admin_delete_term_variation(term_id: int, variation_id: int):
    await db.delete_term_variation(variation_id)
    return {"status": "ok"}


# ─── Vector Store Admin ────────────────────────────────────────────────


@app.get("/api/admin/vector-status")
async def vector_status():
    """Return Qdrant collection stats and connection status."""
    return await vector_store.get_collection_stats()


@app.post("/api/admin/backfill-vectors")
async def backfill_vectors(recreate: bool = False):
    """Backfill vector store from existing review_log and text_corrections.

    Args:
        recreate: If true, delete and recreate collections before backfill
                  (needed after embedding model/pooling changes).
    """
    if recreate:
        await vector_store.init_collections(recreate=True)
    pool = await db.get_pool()
    result = await vector_store.backfill_from_review_log(pool)
    return result


# ─── Harvest ─────────────────────────────────────────────────────────

# In-memory caches for Harvest data
_harvest_projects_cache: dict | None = None
_harvest_pattern_db: dict | None = None


def _harvest_headers() -> dict:
    return {
        "Authorization": f"Bearer {HARVEST_ACCESS_TOKEN}",
        "Harvest-Account-Id": HARVEST_ACCOUNT_ID,
        "User-Agent": "DiaryProcessor",
        "Content-Type": "application/json",
    }


@app.get("/api/harvest/pattern-status")
async def harvest_pattern_status():
    """Return status of stored Harvest entries and pattern DB."""
    await db.ensure_harvest_table()
    stats = await db.get_harvest_entry_stats()
    return {
        "entries": stats,
        "pattern_db_loaded": _harvest_pattern_db is not None,
        "pattern_keywords": len(_harvest_pattern_db["keyword_patterns"]) if _harvest_pattern_db else 0,
        "has_token": bool(HARVEST_ACCESS_TOKEN),
    }


@app.post("/api/harvest/load-patterns")
async def harvest_load_patterns(days: int = 90):
    """Fetch Harvest time entries and store them for pattern analysis."""
    global _harvest_pattern_db

    if not HARVEST_ACCESS_TOKEN:
        return JSONResponse({"error": "HARVEST_ACCESS_TOKEN not set"}, 500)

    await db.ensure_harvest_table()

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

    # Clear old and store new
    await db.clear_harvest_entries()
    await db.save_harvest_entries(entries)

    # Rebuild pattern DB
    _harvest_pattern_db = harvest_patterns.build_pattern_db(entries)

    stats = await db.get_harvest_entry_stats()
    return {
        "status": "ok",
        "entries_fetched": len(entries),
        "entries": stats,
        "pattern_keywords": len(_harvest_pattern_db.get("keyword_patterns", {})),
    }


@app.post("/api/harvest/clear-patterns")
async def harvest_clear_patterns():
    """Clear stored Harvest entries and pattern DB."""
    global _harvest_pattern_db
    await db.ensure_harvest_table()
    await db.clear_harvest_entries()
    _harvest_pattern_db = None
    return {"status": "ok"}


@app.get("/harvest", response_class=HTMLResponse)
async def harvest_page(request: Request, date: str = ""):
    """Harvest time tracking suggestion page."""
    if not date:
        date = str(date_module.today())
    return templates.TemplateResponse(
        request,
        "harvest.html",
        {"date": date},
    )


@app.get("/api/harvest/projects")
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


@app.get("/api/harvest/recent-entries")
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


@app.get("/api/harvest/suggest")
async def harvest_suggest(date: str):
    """Generate Harvest booking suggestions for a given date."""
    global _harvest_pattern_db

    suggestions = []
    errors = []

    # 1. Fetch calendar events. Stubbed in S1 — Server S2 will wire this
    # to MS Graph via the same _fetch_calendar_events helper.
    calendar_events = []
    for ev in await _fetch_calendar_events(date):
        start = _to_local_iso(ev.get("start", {}).get("dateTime", ""))
        end = _to_local_iso(ev.get("end", {}).get("dateTime", ""))
        if not start or "T" not in start:
            continue
        if ev.get("showAs") in ("free", "tentative"):
            continue
        calendar_events.append({
            "subject": ev.get("subject", ""),
            "start": start,
            "end": end,
            "showAs": ev.get("showAs", ""),
        })
    calendar_events.sort(key=lambda e: e["start"])
    calendar_data = {"events": calendar_events}

    # 2. Build or reuse pattern DB from stored Harvest entries
    if not _harvest_pattern_db:
        try:
            await db.ensure_harvest_table()
            stored_entries = await db.get_harvest_entries()
            if stored_entries:
                _harvest_pattern_db = harvest_patterns.build_pattern_db(stored_entries)
            else:
                _harvest_pattern_db = harvest_patterns.build_pattern_db([])
        except Exception as e:
            errors.append(f"Harvest patterns: {e}")
            _harvest_pattern_db = harvest_patterns.build_pattern_db([])

    pattern_db = _harvest_pattern_db or harvest_patterns.build_pattern_db([])

    # 3. Map calendar events to suggestions
    for ev in calendar_data.get("events", []):
        hours = harvest_patterns.calculate_event_hours(
            ev["start"], ev["end"], pattern_db.get("speedy_meeting_rounding", True)
        )
        pattern = harvest_patterns.match_calendar_to_pattern(ev["subject"], pattern_db)

        if pattern:
            suggestions.append({
                "project": {"id": pattern["project_id"], "name": pattern["project_name"]},
                "task": {"id": pattern["task_id"], "name": pattern["task_name"]},
                "hours": hours,
                "notes": ev["subject"],
                "source": "calendar+pattern",
                "confidence": "high",
                "start": ev["start"],
                "end": ev["end"],
            })
        elif pattern_db.get("default_project"):
            dp = pattern_db["default_project"]
            suggestions.append({
                "project": {"id": dp["project_id"], "name": dp["project_name"]},
                "task": {"id": dp["task_id"], "name": dp["task_name"]},
                "hours": hours,
                "notes": ev["subject"],
                "source": "calendar",
                "confidence": "low",
                "start": ev["start"],
                "end": ev["end"],
            })
        else:
            suggestions.append({
                "project": None,
                "task": None,
                "hours": hours,
                "notes": ev["subject"],
                "source": "calendar",
                "confidence": "low",
                "start": ev["start"],
                "end": ev["end"],
            })

    # 4. Get diary transcript for LLM processing
    transcript = await db.get_transcript_by_date(date)
    diary_activities = []
    if transcript:
        text = transcript.get("corrected_text") or transcript.get("raw_text", "")
        if text:
            diary_activities = await harvest_llm.extract_work_activities(text, date)

    # 5. Create gap-fill "Selbstorganisation" entries from diary
    if diary_activities and pattern_db.get("selbstorganisation"):
        so = pattern_db["selbstorganisation"]
        for activity in diary_activities:
            suggestions.append({
                "project": {"id": so["project_id"], "name": so["project_name"]},
                "task": {"id": so["task_id"], "name": so["task_name"]},
                "hours": activity["estimated_hours"],
                "notes": activity["description"],
                "source": "diary+llm",
                "confidence": "medium",
                "category": activity["category"],
            })
    elif diary_activities:
        for activity in diary_activities:
            suggestions.append({
                "project": None,
                "task": None,
                "hours": activity["estimated_hours"],
                "notes": activity["description"],
                "source": "diary+llm",
                "confidence": "medium",
                "category": activity["category"],
            })

    # 6. Calculate totals
    total_hours = sum(s["hours"] for s in suggestions)

    return {
        "date": date,
        "suggestions": suggestions,
        "total_hours": total_hours,
        "transcript_id": transcript["id"] if transcript else None,
        "pattern_db_loaded": bool(pattern_db.get("keyword_patterns")),
        "errors": errors,
    }


# ─── Settings ─────────────────────────────────────────────────────────


SETTING_DEFAULTS = {
    "lightrag_url": "http://192.168.2.16:9621",
    "lightrag_api_key": "",
}


@app.get("/api/settings")
async def get_settings():
    """Return all app settings with defaults filled in."""
    stored = await db.get_all_settings()
    result = {**SETTING_DEFAULTS, **stored}
    return result


@app.put("/api/settings")
async def update_settings(request: Request):
    """Update one or more settings."""
    body = await request.json()
    for key, value in body.items():
        await db.set_setting(key, str(value))
    return {"status": "ok"}


# ─── Ingest ──────────────────────────────────────────────────────────


@app.get("/ingest", response_class=HTMLResponse)
async def ingest_page(request: Request):
    """Audio file ingestion page."""
    return templates.TemplateResponse(
        request,
        "ingest.html",
        {"ingest_url": WHISPER_URL},
    )


@app.get("/api/ingest/history")
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


@app.post("/api/ingest/clear-history")
async def ingest_clear_history():
    """Clear all upload history."""
    await db.clear_ingest_history()
    return {"status": "ok"}


async def _ffmpeg_to_wav_16k_mono(src_bytes: bytes, src_suffix: str) -> bytes:
    """Run ffmpeg to convert arbitrary input audio to 16 kHz mono PCM WAV.

    Whisper's ASR webservice handles many formats directly, but normalising
    here keeps the contract narrow and matches the audio constants in
    `.planning/codebase/CONVENTIONS.md`.
    """
    tmpdir = Path(tempfile.mkdtemp(prefix="ingest-"))
    src_path = tmpdir / f"in{src_suffix or '.bin'}"
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
            tail = stderr.decode("utf-8", errors="replace")[-500:]
            raise RuntimeError(f"ffmpeg failed (exit {proc.returncode}): {tail}")
        return wav_path.read_bytes()
    finally:
        for p in (src_path, wav_path):
            try:
                p.unlink()
            except OSError:
                pass
        try:
            tmpdir.rmdir()
        except OSError:
            pass


async def _whisper_transcribe(wav_bytes: bytes, language: str = "de") -> str:
    """POST WAV bytes to the Whisper sidecar and return the transcript text."""
    async with httpx.AsyncClient(timeout=600.0) as client:
        resp = await client.post(
            f"{WHISPER_URL.rstrip('/')}/asr",
            params={"task": "transcribe", "language": language, "output": "json"},
            files={"audio_file": ("audio.wav", wav_bytes, "audio/wav")},
        )
        resp.raise_for_status()
        try:
            data = resp.json()
        except json.JSONDecodeError:
            return resp.text.strip()
        return (data.get("text") or "").strip()


async def _ingest_audio_to_transcript(
    content: bytes, filename: str
) -> tuple[int, str, str]:
    """Pipeline: ffmpeg → Whisper → persist. Returns (transcript_id, review_url, text)."""
    src_suffix = Path(filename).suffix.lower() or ".mp3"
    wav_bytes = await _ffmpeg_to_wav_16k_mono(content, src_suffix)
    text = await _whisper_transcribe(wav_bytes)
    if not text:
        raise RuntimeError("Whisper returned an empty transcript")
    transcript_id = await db.create_transcript(
        filename=filename,
        date=filename,
        author="Florian Wolf",
        raw_text=text,
    )
    review_url = f"/review/{transcript_id}"
    return transcript_id, review_url, text


@app.post("/api/ingest/upload")
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
    except httpx.TimeoutException:
        await db.mark_ingest_failed(upload_id, "Whisper request timed out")
        return JSONResponse(
            {"status": "error", "message": "Whisper request timed out", "upload_id": upload_id, "filename": filename},
            504,
        )
    except httpx.HTTPStatusError as e:
        msg = f"Whisper returned {e.response.status_code}"
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


@app.post("/api/ingest/{upload_id}/retry")
async def ingest_retry(upload_id: int, file: UploadFile = File(...)):
    """Retry a failed upload by re-running the local ASR pipeline."""
    content = await file.read()
    filename = file.filename or "upload.mp3"

    pool = await db.get_pool()
    await pool.execute(
        "UPDATE ingest_uploads SET status = 'uploading', error_message = NULL, completed_at = NULL WHERE id = $1",
        upload_id,
    )

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


@app.get("/api/skeleton/status")
async def skeleton_status():
    import skeleton_sync
    return await skeleton_sync.get_sync_status()


@app.get("/api/skeleton/diff")
async def skeleton_diff():
    import skeleton_sync
    return await skeleton_sync.get_sync_diff()


@app.get("/api/skeleton/bones")
async def skeleton_bones():
    import skeleton_sync
    return await skeleton_sync.list_bones()


@app.get("/api/skeleton/log")
async def skeleton_log(limit: int = 20):
    import skeleton_sync
    return await skeleton_sync.get_sync_log(limit)


@app.post("/api/skeleton/sync")
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


@app.post("/api/skeleton/sync/{bone_id:path}")
async def skeleton_sync_single(bone_id: str):
    import skeleton_sync
    result = await skeleton_sync.sync_single_bone(bone_id)
    return {"status": "ok", "result": result, "bone_id": bone_id}


@app.get("/api/skeleton/render/{bone_id:path}")
async def skeleton_render(bone_id: str):
    import skeleton_sync
    content = await skeleton_sync.render_bone(bone_id)
    if content is None:
        return JSONResponse({"error": "Bone not found"}, 404)
    return {"bone_id": bone_id, "content": content}


# ─── Org Units CRUD ────────────────────────────────────────────────


@app.get("/api/admin/org-units")
async def admin_list_org_units():
    return await db.list_org_units()


@app.post("/api/admin/org-units")
async def admin_create_org_unit(request: Request):
    body = await request.json()
    oid = await db.create_org_unit(
        name=body["name"],
        entity_type=body["entity_type"],
        parent_id=body.get("parent_id"),
        description=body.get("description", ""),
        properties=body.get("properties"),
        aliases=body.get("aliases", []),
    )
    return {"status": "ok", "id": oid}


@app.put("/api/admin/org-units/{org_id}")
async def admin_update_org_unit(org_id: int, request: Request):
    body = await request.json()
    await db.update_org_unit(org_id, **body)
    return {"status": "ok"}


@app.delete("/api/admin/org-units/{org_id}")
async def admin_delete_org_unit(org_id: int):
    await db.delete_org_unit(org_id)
    return {"status": "ok"}


# ─── Entity Relationships CRUD ─────────────────────────────────────


@app.get("/api/admin/relationships")
async def admin_list_relationships():
    return await db.list_entity_relationships()


@app.post("/api/admin/relationships")
async def admin_create_relationship(request: Request):
    body = await request.json()
    rid = await db.create_entity_relationship(
        source_type=body["source_type"],
        source_id=body["source_id"],
        relationship_type=body["relationship_type"],
        target_type=body["target_type"],
        target_id=body["target_id"],
        context=body.get("context", ""),
        bidirectional=body.get("bidirectional", False),
    )
    return {"status": "ok", "id": rid}


@app.delete("/api/admin/relationships/{rel_id}")
async def admin_delete_relationship(rel_id: int):
    await db.delete_entity_relationship(rel_id)
    return {"status": "ok"}


# ─── Role Assignments CRUD ─────────────────────────────────────────


@app.get("/api/admin/role-assignments")
async def admin_list_role_assignments(person_id: int = None):
    return await db.list_role_assignments(person_id)


@app.post("/api/admin/role-assignments")
async def admin_create_role_assignment(request: Request):
    body = await request.json()
    rid = await db.create_role_assignment(
        person_id=body["person_id"],
        role_name=body["role_name"],
        org_unit_id=body.get("org_unit_id"),
        scope=body.get("scope", ""),
        role_entity_name=body.get("role_entity_name"),
        start_date=body.get("start_date"),
        end_date=body.get("end_date"),
    )
    return {"status": "ok", "id": rid}


@app.put("/api/admin/role-assignments/{ra_id}")
async def admin_update_role_assignment(ra_id: int, request: Request):
    body = await request.json()
    await db.update_role_assignment(ra_id, **body)
    return {"status": "ok"}


@app.delete("/api/admin/role-assignments/{ra_id}")
async def admin_delete_role_assignment(ra_id: int):
    await db.delete_role_assignment(ra_id)
    return {"status": "ok"}


# ─── Static Entities CRUD ──────────────────────────────────────────


@app.get("/api/admin/static-entities")
async def admin_list_static_entities():
    return await db.list_static_entities()


@app.post("/api/admin/static-entities")
async def admin_create_static_entity(request: Request):
    body = await request.json()
    sid = await db.create_static_entity(
        name=body["name"],
        entity_type=body["entity_type"],
        description=body.get("description", ""),
        properties=body.get("properties"),
        aliases=body.get("aliases", []),
    )
    return {"status": "ok", "id": sid}


@app.put("/api/admin/static-entities/{entity_id}")
async def admin_update_static_entity(entity_id: int, request: Request):
    body = await request.json()
    await db.update_static_entity(entity_id, **body)
    return {"status": "ok"}


@app.delete("/api/admin/static-entities/{entity_id}")
async def admin_delete_static_entity(entity_id: int):
    await db.delete_static_entity(entity_id)
    return {"status": "ok"}


# ─── Initiatives CRUD ──────────────────────────────────────────────


@app.get("/api/admin/initiatives")
async def admin_list_initiatives():
    return await db.list_initiatives()


@app.post("/api/admin/initiatives")
async def admin_create_initiative(request: Request):
    body = await request.json()
    iid = await db.create_initiative(
        name=body["name"],
        initiative_type=body["initiative_type"],
        description=body.get("description", ""),
        properties=body.get("properties"),
        aliases=body.get("aliases", []),
        owner_person_id=body.get("owner_person_id"),
    )
    return {"status": "ok", "id": iid}


@app.put("/api/admin/initiatives/{init_id}")
async def admin_update_initiative(init_id: int, request: Request):
    body = await request.json()
    await db.update_initiative(init_id, **body)
    return {"status": "ok"}


@app.delete("/api/admin/initiatives/{init_id}")
async def admin_delete_initiative(init_id: int):
    await db.delete_initiative(init_id)
    return {"status": "ok"}


