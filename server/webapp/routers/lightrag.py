"""LightRAG enrichment + briefing-context router.

Endpoints:
    POST /lightrag/query                    — natural-language query, summarised
    GET  /yesterday/open-todos              — open todos for the briefing

Both routes pass LightRAG's response through the speech-ready Ollama
summariser so iOS can play the result via Piper without further shaping.
"""

from __future__ import annotations

import logging
from datetime import date, timedelta
from typing import Literal

import httpx
from fastapi import APIRouter, Depends, HTTPException, Query, status
from pydantic import BaseModel, Field

from document_processor import _lightrag_headers, get_lightrag_api_key, get_lightrag_url
from enrichment import (
    EnrichmentSummariserUnavailable,
    summarise_for_speech,
)
from routers.auth import require_bearer

logger = logging.getLogger(__name__)


router = APIRouter(dependencies=[Depends(require_bearer)])


ResponseLanguage = Literal["de", "en"]
QueryMode = Literal["naive", "local", "global", "hybrid", "mix"]


class LightRAGQueryBody(BaseModel):
    query: str = Field(min_length=1, max_length=400)
    mode: QueryMode = "hybrid"
    response_language: ResponseLanguage = "de"
    top_k: int = Field(default=5, ge=1, le=20)


class LightRAGSummaryResponse(BaseModel):
    summary: str
    response_language: ResponseLanguage
    raw_response: str = ""


class TodoItem(BaseModel):
    text: str
    status: str = "Offen"
    due: str | None = None
    source_date: str | None = None


class OpenTodosResponse(BaseModel):
    summary: str
    response_language: ResponseLanguage
    items: list[TodoItem] = Field(default_factory=list)


# --- helpers --------------------------------------------------------------


async def _query_lightrag(query: str, *, mode: str, top_k: int) -> str:
    url = await get_lightrag_url()
    api_key = await get_lightrag_api_key()
    try:
        async with httpx.AsyncClient(timeout=120.0) as client:
            resp = await client.post(
                f"{url}/query",
                json={"query": query, "mode": mode, "top_k": top_k},
                headers=_lightrag_headers(api_key),
            )
            resp.raise_for_status()
            data = resp.json()
            return (data.get("response") or "").strip()
    except (httpx.NetworkError, httpx.TimeoutException) as exc:
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail=f"lightrag_unavailable: {exc}",
        ) from exc
    except httpx.HTTPStatusError as exc:
        raise HTTPException(
            status_code=status.HTTP_502_BAD_GATEWAY,
            detail=f"lightrag_status_{exc.response.status_code}",
        ) from exc


# --- routes ---------------------------------------------------------------


@router.post("/lightrag/query", response_model=LightRAGSummaryResponse)
async def lightrag_query(body: LightRAGQueryBody) -> LightRAGSummaryResponse:
    raw_response = await _query_lightrag(
        body.query, mode=body.mode, top_k=body.top_k
    )
    if not raw_response:
        raw_response = "(LightRAG hat keine Treffer geliefert.)"
    try:
        summary = await summarise_for_speech(
            query=body.query,
            sources_text=raw_response,
            response_language=body.response_language,
        )
    except EnrichmentSummariserUnavailable as exc:
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail=f"ollama_unavailable: {exc}",
        ) from exc
    return LightRAGSummaryResponse(
        summary=summary,
        response_language=body.response_language,
        raw_response=raw_response,
    )


@router.get("/yesterday/open-todos", response_model=OpenTodosResponse)
async def yesterday_open_todos(
    response_language: ResponseLanguage = Query(default="de"),
    lookback_days: int = Query(default=7, ge=1, le=30),
) -> OpenTodosResponse:
    """Return offene Punkte from the last N days for the briefing.

    The narratives produced by `document_processor.py` embed todos under a
    `## Offene Punkte` section with German status labels. We ask LightRAG
    to surface those, then summarise speech-ready.
    """
    today = date.today()
    earliest = today - timedelta(days=lookback_days)
    query = (
        f"Liste alle offenen Punkte (Status 'Offen' oder 'InArbeit' oder "
        f"'Blockiert') aus den Tagebucheinträgen zwischen {earliest.isoformat()} "
        f"und {today.isoformat()}. Gib für jeden Punkt: Aufgabe, Status, "
        f"Quelldatum, Fälligkeit (falls genannt)."
    )
    raw_response = await _query_lightrag(query, mode="hybrid", top_k=15)

    if not raw_response.strip():
        raw_response = "(Keine offenen Punkte gefunden.)"

    try:
        summary = await summarise_for_speech(
            query=(
                "Welche offenen Punkte stehen aus der letzten Woche?"
                if response_language == "de"
                else "What open todos are still pending from the last week?"
            ),
            sources_text=raw_response,
            response_language=response_language,
        )
    except EnrichmentSummariserUnavailable as exc:
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail=f"ollama_unavailable: {exc}",
        ) from exc

    return OpenTodosResponse(
        summary=summary,
        response_language=response_language,
        items=_parse_todo_lines(raw_response),
    )


def _parse_todo_lines(text: str) -> list[TodoItem]:
    """Best-effort extraction of bullet-style todo lines from LightRAG output.

    The HTMX pipeline produces predictable lines like:
        - Board-Deck bis Donnerstag — Status: Offen (fällig 2026-04-30)
    But LightRAG re-emits them in arbitrary forms, so this is heuristic.
    """
    out: list[TodoItem] = []
    for line in text.splitlines():
        s = line.strip().lstrip("-•·— ").strip()
        if not s:
            continue
        if "Status:" not in s and "status:" not in s:
            continue
        # Split off "Status: ..." chunk.
        head, _, tail = s.partition("Status:")
        if not tail:
            head, _, tail = s.partition("status:")
        status_token = tail.strip().split()[0] if tail.strip() else "Offen"
        # Optional "(fällig 2026-04-30)" tail.
        due = None
        if "fällig" in tail:
            after = tail.split("fällig", 1)[1]
            due = after.strip(" ()-—.").split()[0] if after.strip() else None
        out.append(TodoItem(
            text=head.rstrip(" —-").strip(),
            status=status_token.strip(",.;"),
            due=due,
        ))
    return out
