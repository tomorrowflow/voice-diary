"""Upstream-aware health endpoint.

`GET /health` probes Postgres, Qdrant, Whisper, LightRAG, Ollama, and the
MSAL token cache and returns:

    { "status": "ok" | "degraded" | "down",
      "upstream": { "postgres": "ok" | "down" | "skipped", ... } }

Probe timeouts are short (~2 s) so the iOS app's reachability check
doesn't hang.

This route is intentionally **not** bearer-token gated: iOS pings it
before onboarding (i.e. before the user has even pasted the bearer in).
The endpoint reveals only liveness signals — never tokens, never PII.
"""

from __future__ import annotations

import asyncio
import logging
import os
from typing import Literal

import httpx
from fastapi import APIRouter
from pydantic import BaseModel, Field

logger = logging.getLogger(__name__)


router = APIRouter()


PROBE_TIMEOUT = 2.0  # seconds — keep this snappy

ProbeResult = Literal["ok", "down", "skipped", "not_bootstrapped"]
OverallStatus = Literal["ok", "degraded", "down"]


class HealthResponse(BaseModel):
    status: OverallStatus
    upstream: dict[str, ProbeResult] = Field(default_factory=dict)


# --- individual probes ----------------------------------------------------


async def _probe_postgres() -> ProbeResult:
    try:
        import db
        pool = await db.get_pool()
        async with pool.acquire() as conn:
            await asyncio.wait_for(conn.execute("SELECT 1"), timeout=PROBE_TIMEOUT)
        return "ok"
    except Exception as exc:  # noqa: BLE001
        logger.debug("postgres probe failed: %s", exc)
        return "down"


async def _probe_http(name: str, url: str | None) -> ProbeResult:
    if not url:
        return "skipped"
    try:
        async with httpx.AsyncClient(timeout=PROBE_TIMEOUT) as client:
            # Try a cheap GET on root or /health if available.
            resp = await client.get(url)
            return "ok" if resp.status_code < 500 else "down"
    except Exception as exc:  # noqa: BLE001
        logger.debug("%s probe failed (%s): %s", name, url, exc)
        return "down"


async def _probe_qdrant() -> ProbeResult:
    return await _probe_http("qdrant", os.getenv("QDRANT_URL"))


async def _probe_whisper() -> ProbeResult:
    base = os.getenv("WHISPER_URL")
    if not base:
        return "skipped"
    return await _probe_http("whisper", base.rstrip("/") + "/")


async def _probe_lightrag() -> ProbeResult:
    base = os.getenv("LIGHTRAG_URL")
    if not base:
        return "skipped"
    return await _probe_http("lightrag", base.rstrip("/") + "/health")


async def _probe_ollama() -> ProbeResult:
    base = os.getenv("OLLAMA_BASE_URL")
    if not base:
        return "skipped"
    return await _probe_http("ollama", base.rstrip("/") + "/api/tags")


async def _probe_msgraph() -> ProbeResult:
    """Token freshness check: cache loaded + at least one account."""
    if not (os.getenv("MSGRAPH_CLIENT_ID") and os.getenv("MSGRAPH_TENANT_ID")):
        return "skipped"
    try:
        from msgraph_client import get_client
        client = await get_client()
        accounts = client._app.get_accounts()  # type: ignore[attr-defined]
        return "ok" if accounts else "not_bootstrapped"
    except Exception as exc:  # noqa: BLE001
        logger.debug("msgraph probe failed: %s", exc)
        return "down"


# --- route ----------------------------------------------------------------


@router.get("/health", response_model=HealthResponse)
async def health() -> HealthResponse:
    names = ("postgres", "qdrant", "whisper", "lightrag", "ollama", "msgraph")
    probes = await asyncio.gather(
        _probe_postgres(),
        _probe_qdrant(),
        _probe_whisper(),
        _probe_lightrag(),
        _probe_ollama(),
        _probe_msgraph(),
        return_exceptions=False,
    )
    upstream: dict[str, ProbeResult] = dict(zip(names, probes))

    # Overall status:
    #   "ok"        — everything that isn't 'skipped' is 'ok'
    #   "down"      — postgres or whisper is 'down' (no audio path possible)
    #   "degraded"  — anything else is failing
    relevant = [v for v in upstream.values() if v != "skipped"]
    if upstream["postgres"] == "down" or upstream["whisper"] == "down":
        overall: OverallStatus = "down"
    elif all(v == "ok" for v in relevant):
        overall = "ok"
    else:
        overall = "degraded"
    return HealthResponse(status=overall, upstream=upstream)
