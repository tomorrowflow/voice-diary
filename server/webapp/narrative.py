"""
Shared narrative stage for both server pipelines: the HTMX SSE review flow
(`main.py::process_document_stream`) and the iOS session ingest
(`routers/sessions.py::_run_session_document_processor`). Both callers used
to hand-assemble the same sequence of `document_processor` step calls with
their own (slightly different) error handling; this module is the one place
that sequence and its failure policy live.

Owned steps: context query -> context summary -> enriched context ->
analysis -> narrative markdown -> metadata. Ports (`NarrativePorts`) carry
the LightRAG client and the LLM transport so a caller's tests can inject
fakes without monkeypatching module globals — the same injection points
`document_processor`'s functions already expose.

Failure policy (SRV, issue #50):
- LightRAG context query fails -> continue with empty context.
- Context summary fails -> continue with "Keine historischen Daten verfügbar.".
- Analysis fails -> raise, after emitting the SSE-shaped error events via
  `on_step` so the HTMX progress UI can show them; the sessions caller's own
  try/except turns the same raise into `pending_analysis`.

`sync_and_ingest` is the explicit (still best-effort) skeleton-sync-then-
ingest step. The sessions path runs it right after saving; the HTMX path
runs it only from the manual `/api/documents/{id}/ingest` button.
"""

from __future__ import annotations

import asyncio
import logging
from dataclasses import dataclass
from typing import Awaitable, Callable

import httpx

import document_processor
from lightrag_client import LightRAGClient

logger = logging.getLogger(__name__)

# Called as `on_step(event, data)` with the same event names/payload shapes
# main.py's SSE endpoint already emits (`step`, `log`, `context`, `summary`,
# `analysis`, `error`). May be a sync callable or return an awaitable.
OnStep = Callable[[str, dict], "Awaitable[None] | None"]


@dataclass
class NarrativePorts:
    """Injection points for the narrative stage's external dependencies.

    Both fields default to `None`, meaning "use `document_processor`'s own
    module-level client" — the same default the individual step functions
    already fall back to.
    """

    lightrag_client: LightRAGClient | None = None
    llm_transport: httpx.AsyncBaseTransport | None = None


@dataclass
class NarrativeResult:
    context_summary: str
    enriched_context: dict
    analysis: dict
    markdown: str
    metadata: dict


async def _emit(on_step: OnStep | None, event: str, data: dict) -> None:
    if on_step is None:
        return
    maybe_awaitable = on_step(event, data)
    if maybe_awaitable is not None:
        await maybe_awaitable


async def build_day_narrative(
    text: str,
    entities: list[dict],
    date: str,
    *,
    author: str | None = None,
    ports: NarrativePorts | None = None,
    on_step: OnStep | None = None,
) -> NarrativeResult:
    """Run context query -> summary -> enrichment -> analysis -> narrative
    markdown -> metadata for a day's transcript text, emitting SSE-shaped
    progress via `on_step` if given. `author` falls back to
    `document_processor.build_enriched_context`'s default when omitted.

    Raises whatever `document_processor.analyze_transcript` raises (after
    emitting the matching error events) — analysis failure is the one step
    in this pipeline that isn't degraded, per the decided failure policy.
    """
    ports = ports or NarrativePorts()

    person_names = [
        e.get("text") or e.get("canonical", "")
        for e in entities
        if (e.get("type") or e.get("entity_type", "")) == "PERSON"
    ]

    await _emit(on_step, "step", {"step": "context", "state": "active"})
    await _emit(on_step, "log", {"message": "Querying LightRAG for context...", "level": "info"})
    try:
        recent_ctx, entity_hist = await asyncio.gather(
            document_processor.query_lightrag_context(date, client=ports.lightrag_client),
            document_processor.query_lightrag_entity_history(person_names, date, client=ports.lightrag_client),
        )
    except Exception as e:  # noqa: BLE001 — degrade policy: any failure here is "no context"
        recent_ctx, entity_hist = "", ""
        await _emit(on_step, "log", {"message": f"LightRAG query failed: {e}", "level": "error"})
    await _emit(on_step, "context", {"recent": recent_ctx[:200], "entities": entity_hist[:200]})
    await _emit(on_step, "step", {"step": "context", "state": "done"})

    await _emit(on_step, "step", {"step": "summary", "state": "active"})
    await _emit(on_step, "log", {"message": "Summarizing context via LLM...", "level": "info"})
    try:
        context_summary = await document_processor.summarize_context(
            recent_ctx, entity_hist, date, transport=ports.llm_transport
        )
    except Exception as e:  # noqa: BLE001 — degrade policy: any failure here is "no summary"
        context_summary = "Keine historischen Daten verfügbar."
        await _emit(on_step, "log", {"message": f"Summarization failed: {e}", "level": "error"})
    await _emit(on_step, "summary", {"summary": context_summary})
    await _emit(on_step, "step", {"step": "summary", "state": "done"})

    transcript_record = {"corrected_text": text, "date": date, "author": author}
    enriched = document_processor.build_enriched_context(transcript_record, entities, context_summary)

    await _emit(on_step, "step", {"step": "analysis", "state": "active"})
    await _emit(
        on_step,
        "log",
        {"message": "Analyzing transcript via LLM (this may take a while)...", "level": "info"},
    )
    try:
        analysis = await document_processor.analyze_transcript(enriched, transport=ports.llm_transport)
    except Exception as e:
        error_msg = str(e) or type(e).__name__
        logger.error("Document analysis failed: %s", error_msg)
        await _emit(on_step, "step", {"step": "analysis", "state": "error"})
        await _emit(on_step, "log", {"message": f"Analysis failed: {error_msg}", "level": "error"})
        await _emit(on_step, "error", {"message": f"Analysis failed: {error_msg}"})
        raise

    await _emit(on_step, "analysis", {"analysis": analysis})
    await _emit(on_step, "step", {"step": "analysis", "state": "done"})

    markdown = document_processor.generate_narrative_document(enriched, analysis)
    metadata = document_processor.build_document_metadata(enriched)

    return NarrativeResult(
        context_summary=context_summary,
        enriched_context=enriched,
        analysis=analysis,
        markdown=markdown,
        metadata=metadata,
    )


async def sync_and_ingest(
    markdown: str,
    metadata: dict,
    *,
    lightrag_client: LightRAGClient | None = None,
) -> dict:
    """Explicit pre-ingest skeleton sync (best-effort), then LightRAG ingest.

    `document_processor.ingest_to_lightrag` used to run the skeleton sync
    itself, hidden inside the ingest call (SRV-A1/#50, T3). It's an explicit
    step here so a caller (or a test) can see and reason about it separately
    from the ingest call it precedes. Still best-effort: a sync failure is
    logged and swallowed, never blocking the ingest. An ingest failure
    propagates — the caller (sessions.py) leaves the already-saved documents
    unmarked and retryable.
    """
    try:
        import skeleton_sync

        sync_stats = await skeleton_sync.sync_incremental(triggered_by="pre-ingestion")
        if sync_stats.has_changes():
            logger.info("Pre-ingestion skeleton sync: %s", sync_stats.to_dict())
    except Exception as e:  # noqa: BLE001 — best-effort, never blocks ingest
        logger.warning("Pre-ingestion skeleton sync failed (continuing): %s", e)

    return await document_processor.ingest_to_lightrag(markdown, metadata, client=lightrag_client)
