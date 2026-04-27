"""Email enrichment router.

`GET /email/search?q=...&from=ISO&to=ISO&response_language=de|en`

Forwards to MS Graph `/me/messages` with `$search` (and optional date
filter), feeds the top results plus the user's query into the speech-ready
Ollama summariser, returns a 2–3 sentence summary in the requested language.
"""

from __future__ import annotations

import logging
from datetime import datetime
from typing import Literal

from fastapi import APIRouter, Depends, HTTPException, Query, status
from pydantic import BaseModel, Field

import fixtures
from enrichment import (
    EnrichmentSummariserUnavailable,
    summarise_for_speech,
)
from msgraph_client import (
    MSGraphError,
    MSGraphNotBootstrapped,
    get_client,
)
from routers.auth import require_bearer

logger = logging.getLogger(__name__)


router = APIRouter(dependencies=[Depends(require_bearer)])


ResponseLanguage = Literal["de", "en"]


class EmailLink(BaseModel):
    id: str
    subject: str = ""
    sender: str = ""
    received: str = ""
    web_link: str = ""


class EmailSearchResponse(BaseModel):
    summary: str
    source_count: int
    response_language: ResponseLanguage
    links: list[EmailLink] = Field(default_factory=list)


def _shape_message(raw: dict) -> EmailLink:
    sender_obj = (raw.get("from") or {}).get("emailAddress") or {}
    sender = sender_obj.get("name") or sender_obj.get("address") or ""
    return EmailLink(
        id=raw.get("id", ""),
        subject=raw.get("subject") or "",
        sender=sender,
        received=raw.get("receivedDateTime") or "",
        web_link=raw.get("webLink") or "",
    )


def _format_sources(messages: list[dict]) -> str:
    """Compact text block fed to the summariser. Keep it short — Piper
    will speak only 2–3 sentences anyway."""
    parts: list[str] = []
    for raw in messages:
        link = _shape_message(raw)
        body = (raw.get("bodyPreview") or "").strip().replace("\n", " ")
        parts.append(
            f"- Von {link.sender} ({link.received}): {link.subject}. {body[:400]}"
        )
    return "\n".join(parts) or "(keine Treffer)"


@router.get("/email/search", response_model=EmailSearchResponse)
async def email_search(
    q: str = Query(min_length=1, max_length=200),
    from_: str | None = Query(default=None, alias="from"),
    to: str | None = Query(default=None),
    response_language: ResponseLanguage = Query(default="de"),
    top: int = Query(default=10, ge=1, le=25),
) -> EmailSearchResponse:
    if fixtures.fixture_mode():
        raw_messages = fixtures.load_email_search(q)[:top]
    else:
        params: dict[str, str] = {
            "$search": f'"{q}"',
            "$top": str(top),
            "$select": "id,subject,from,receivedDateTime,bodyPreview,webLink",
            "$orderby": "receivedDateTime desc",
        }
        # Graph $search is incompatible with $filter on receivedDateTime,
        # so we apply the date window client-side after retrieval.
        try:
            client = await get_client()
            data = await client.get_json("/me/messages", params=params)
        except MSGraphNotBootstrapped as exc:
            raise HTTPException(
                status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
                detail="msgraph_not_bootstrapped",
            ) from exc
        except MSGraphError as exc:
            raise HTTPException(
                status_code=status.HTTP_502_BAD_GATEWAY,
                detail=str(exc),
            ) from exc
        raw_messages = data.get("value", []) or []
    raw_messages = _filter_by_date(raw_messages, from_, to)

    sources_text = _format_sources(raw_messages)
    try:
        summary = await summarise_for_speech(
            query=q,
            sources_text=sources_text,
            response_language=response_language,
        )
    except EnrichmentSummariserUnavailable as exc:
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail=f"ollama_unavailable: {exc}",
        ) from exc

    return EmailSearchResponse(
        summary=summary,
        source_count=len(raw_messages),
        response_language=response_language,
        links=[_shape_message(m) for m in raw_messages],
    )


def _filter_by_date(
    messages: list[dict], from_iso: str | None, to_iso: str | None
) -> list[dict]:
    if not from_iso and not to_iso:
        return messages

    def parse(value: str | None) -> datetime | None:
        if not value:
            return None
        try:
            return datetime.fromisoformat(value.replace("Z", "+00:00"))
        except ValueError:
            return None

    start = parse(from_iso)
    end = parse(to_iso)
    out: list[dict] = []
    for raw in messages:
        received = parse(raw.get("receivedDateTime"))
        if received is None:
            continue
        if start and received < start:
            continue
        if end and received > end:
            continue
        out.append(raw)
    return out
