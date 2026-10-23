"""Upstream-aware health endpoint.

`GET /health` probes Postgres, Qdrant, Whisper, LightRAG, Ollama, the MSAL
token cache, the optional Voxtral sidecar and, only when
`ANALYSIS_ROUTE=blindfold`, Blindfold, and returns:

    { "status": "ok" | "degraded" | "down",
      "upstream": { "postgres": "ok" | "down" | "skipped", ... } }

The probing and the status rules live in `health_checks`; this module only
validates and serves the response. Probe timeouts are short (~2 s) so the iOS
app's reachability check doesn't hang.

This route is intentionally **not** bearer-token gated: iOS pings it
before onboarding (i.e. before the user has even pasted the bearer in).
The endpoint reveals only liveness signals — never tokens, never PII.
"""

from __future__ import annotations

from fastapi import APIRouter, Depends
from pydantic import BaseModel, Field

from health_checks import (
    PROBE_TIMEOUT,
    HealthDependencies,
    OverallStatus,
    ProbeResult,
    check_health,
    default_dependencies,
    overall_status,
)

__all__ = ["PROBE_TIMEOUT", "HealthResponse", "overall_status", "router"]

router = APIRouter()


class HealthResponse(BaseModel):
    status: OverallStatus
    upstream: dict[str, ProbeResult] = Field(default_factory=dict)


@router.get("/health", response_model=HealthResponse)
async def health(
    deps: HealthDependencies = Depends(default_dependencies),
) -> HealthResponse:
    snapshot = await check_health(deps)
    return HealthResponse(status=snapshot.status, upstream=snapshot.upstream)
