"""Email enrichment router.

`GET /email/search?q=...&from=ISO&to=ISO&response_language=de|en`

Forwards to MS Graph `/me/messages` with `$search` (and optional date
filter), feeds the top results plus the user's query into the speech-ready
Ollama summariser, returns a 2–3 sentence summary in the requested language.
"""

from __future__ import annotations

import logging
from typing import Literal

from fastapi import APIRouter, Depends, Query
from pydantic import BaseModel, Field

import fixtures
import upstream_failure
from email_results import prepare_email_results
from enrichment import summarise_for_speech
from msgraph_client import get_client
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
        # Graph caveats on `/me/messages`:
        #   * `$search` and `$orderby` are mutually exclusive — Graph
        #     returns a 4xx if both are set. Search results come back in
        #     relevance order which is what we want anyway.
        #   * `$search` and `$filter` on `receivedDateTime` are also
        #     incompatible, so the date window is applied client-side
        #     after retrieval.
        params: dict[str, str] = {
            "$search": f'"{q}"',
            "$top": str(top),
            "$select": "id,subject,from,receivedDateTime,bodyPreview,webLink",
        }
        with upstream_failure.raise_as_failure():
            client = await get_client()
            data = await client.get_json("/me/messages", params=params)
        raw_messages = data.get("value", []) or []
    results = prepare_email_results(raw_messages, from_, to)
    links = [EmailLink(**link) for link in results.links]

    with upstream_failure.raise_as_failure():
        summary = await summarise_for_speech(
            query=q,
            sources_text=results.sources_text,
            response_language=response_language,
        )

    return EmailSearchResponse(
        summary=summary,
        source_count=len(links),
        response_language=response_language,
        links=links,
    )
