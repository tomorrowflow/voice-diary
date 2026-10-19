"""Legacy review streaming flow — transcript and document SSE routes.

`GET /api/transcripts/{id}/process` streams the correction → fluency →
entities → LLM-validation pipeline for the review page;
`GET /api/transcripts/{id}/process-document` streams the narrative stage and
saves the resulting document. Both bridge a callback-shaped shared stage
(`correction.correct_and_detect_entities`, `narrative.build_day_narrative`)
into an async-generator SSE stream via a background task + queue.

Relocated out of `main.py` by ARCH-1; same paths, bearer auth, event
order/payloads, cancellation and persistence behaviour. The HTML pages
(`/review/{id}`, `/process/{id}`) stay in `main.py` since they render
`templates`.

Bearer-token auth applied via the router-level dependency (SEC-2).
"""

from __future__ import annotations

import asyncio
import json
import logging
from dataclasses import asdict

from fastapi import APIRouter, Depends
from fastapi.responses import JSONResponse
from sse_starlette.sse import EventSourceResponse

import correction
import db
import dictionary
import fluency_checker
import llm_validator
import narrative
import vector_store
from dictionary import DictionarySnapshot
from llm_validator import validate_entities_stream
from routers.auth import require_bearer

logger = logging.getLogger(__name__)

router = APIRouter(dependencies=[Depends(require_bearer)])


async def _cancel_bridge_task(task: asyncio.Task) -> None:
    """Cancel a still-running SSE bridge task and wait for it to unwind."""
    if not task.done():
        task.cancel()
    await asyncio.gather(task, return_exceptions=True)


@router.get("/api/transcripts/{transcript_id}/process")
async def process_transcript_stream(transcript_id: int):
    """SSE endpoint: runs the shared correction chain
    (`correction.correct_and_detect_entities`, #51), then the two
    review-UI-only steps that don't affect what's persisted — fluency check
    and LLM entity validation (decision D2, handoff 01 re-check: they only
    produce hints for this UI, so the iOS session path has no use for them)."""
    transcript = await db.get_transcript(transcript_id)
    if not transcript:
        return JSONResponse({"error": "not found"}, 404)

    # Pre-load the Dictionary before streaming starts
    snapshot = await dictionary.load_dictionary_snapshot()

    raw_text = transcript["raw_text"]

    return EventSourceResponse(_process_transcript_events(raw_text, snapshot))


async def _process_transcript_events(
    raw_text: str,
    snapshot: DictionarySnapshot | None = None,
):
    """Bridges `correction.correct_and_detect_entities`'s callback-shaped
    `on_step` progress into this endpoint's async-generator SSE shape (the
    same background-task + queue bridge `_process_document_events` uses for
    `narrative.build_day_narrative`), then runs fluency + LLM validation
    inline — same event names/payload shapes as before extraction. One
    accepted behaviour change: the "Detecting entities..." / "Found N
    entities" log lines now arrive during the bundled correction+detection
    call, ahead of the `correction` event, instead of just ahead of the
    `entities` event — the `correction`/`fluency`/`entities` state events
    themselves keep their original order and shape.
    """
    queue: asyncio.Queue = asyncio.Queue()
    _done = object()

    def on_step(event: str, data: dict) -> None:
        queue.put_nowait((event, data))

    async def run_correction():
        try:
            return await correction.correct_and_detect_entities(
                raw_text,
                snapshot=snapshot,
                on_step=on_step,
            )
        finally:
            queue.put_nowait(_done)

    task = asyncio.create_task(run_correction())

    try:
        while True:
            item = await queue.get()
            if item is _done:
                break
            event, data = item
            yield {"event": event, "data": json.dumps(data)}

        result = await task
    finally:
        # Client disconnect closes the generator mid-drain; don't leave the
        # correction chain running with nobody listening.
        await _cancel_bridge_task(task)
    text = result.corrected_text

    # Send corrected text + corrections to client
    yield {
        "event": "correction",
        "data": json.dumps({
            "text": text,
            "corrections": result.llm_corrections,
            "applied_corrections": result.applied_corrections,
        }),
    }

    # Phase 1.5: Fluency check (HTMX-only)
    fluency_issues = []
    if fluency_checker.FLUENCY_CHECK_ENABLED:
        yield {"event": "log", "data": json.dumps({"message": "Checking transcript fluency...", "level": "info"})}
        fluency_issues = await fluency_checker.check_fluency(text)
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

    entities = result.entities

    # Send entities to client
    yield {
        "event": "entities",
        "data": json.dumps([asdict(e) for e in entities]),
    }

    # Phase 3: LLM entity validation (HTMX-only)
    entity_usage_samples = None
    if vector_store.VECTOR_SEARCH_ENABLED and llm_validator.LLM_VALIDATION_ENABLED:
        yield {"event": "log", "data": json.dumps({"message": "Querying vector store for entity usage samples...", "level": "info"})}
        entity_usage_samples = {}
        for ent in entities:
            if ent.status in ("suggested", "ambiguous") or ent.confidence in ("medium", "low"):
                # Get context snippet for this entity
                ctx = text[max(0, ent.start - 50) : min(len(text), ent.end + 50)]
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
    async for event in validate_entities_stream(text, entities, entity_usage_samples=entity_usage_samples):
        yield event


@router.get("/api/transcripts/{transcript_id}/process-document")
async def process_document_stream(transcript_id: int):
    """SSE endpoint: runs the shared narrative stage (`narrative.build_day_narrative`,
    SRV-A1/#50), then saves the result — the one step that's specific to
    this review-UI flow (the sessions path saves against every segment's
    transcript instead)."""
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
    text = transcript.get("corrected_text") or transcript.get("raw_text", "")

    return EventSourceResponse(
        _process_document_events(transcript_id, text, entities, date_str, author=transcript.get("author"))
    )


async def _process_document_events(
    transcript_id: int, text: str, entities: list[dict], date_str: str, *, author: str | None = None
):
    """Bridges `narrative.build_day_narrative`'s callback-shaped `on_step`
    progress into this endpoint's async-generator SSE shape: the narrative
    stage runs as a background task while this generator drains its step
    queue, so the client still sees `step`/`log`/... events arrive as they
    happen (e.g. during the several-minute analysis call) instead of all at
    once at the end.
    """
    queue: asyncio.Queue = asyncio.Queue()
    _done = object()

    def on_step(event: str, data: dict) -> None:
        queue.put_nowait((event, data))

    async def run_narrative():
        try:
            return await narrative.build_day_narrative(
                text, entities, date_str, author=author, on_step=on_step
            )
        finally:
            queue.put_nowait(_done)

    task = asyncio.create_task(run_narrative())

    error_relayed = False
    try:
        while True:
            item = await queue.get()
            if item is _done:
                break
            event, data = item
            error_relayed = error_relayed or event == "error"
            yield {"event": event, "data": json.dumps(data)}

        try:
            result = await task
        except Exception as e:
            if error_relayed:
                # narrative.build_day_narrative already emitted the matching
                # `step`/`log`/`error` events (analysis failure) before raising.
                return
            logger.exception("process-document: narrative stage failed for transcript %s", transcript_id)
            yield {"event": "error", "data": json.dumps({"message": f"Document generation failed: {e}"})}
            return
    finally:
        # Client disconnect closes the generator mid-drain; stop the
        # narrative task (several-minute LLM call) instead of orphaning it.
        await _cancel_bridge_task(task)

    # Save the narrative — specific to this review-UI flow; the sessions
    # path saves the same markdown against every segment's transcript.
    yield {"event": "step", "data": json.dumps({"step": "document", "state": "active"})}
    yield {"event": "log", "data": json.dumps({"message": "Generating narrative document...", "level": "info"})}

    try:
        doc_row = await db.save_processed_document(
            transcript_id=transcript_id,
            document_markdown=result.markdown,
            analysis_json=result.analysis,
            context_summary=result.context_summary,
            metadata=result.metadata,
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
            "markdown": result.markdown,
            "metadata": result.metadata,
        }),
    }
    yield {"event": "step", "data": json.dumps({"step": "document", "state": "done"})}
    yield {"event": "done", "data": json.dumps({"doc_id": doc_id})}
