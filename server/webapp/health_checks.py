"""Health checking: probe every upstream and fold the results into a status.

`check_health(deps)` probes Postgres, Qdrant, Whisper, LightRAG, Ollama, the
MSAL token cache and the optional Voxtral sidecar concurrently and, only when
`ANALYSIS_ROUTE=blindfold`, Blindfold afterwards, then folds the per-upstream
results with `overall_status` (SPEC §10.7, ADR 0002-0004).

Everything that talks to the outside world is a field of `HealthDependencies`,
so tests hand `check_health` plain fakes. `default_dependencies()` builds the
real ones. The HTTP route stays in `routers/health.py`.
"""

from __future__ import annotations

import asyncio
import logging
import os
from collections.abc import Awaitable, Callable, Mapping
from dataclasses import dataclass, field
from typing import Literal

import httpx

import analysis_route

logger = logging.getLogger(__name__)


PROBE_TIMEOUT = 2.0  # seconds — keep this snappy

ProbeResult = Literal["ok", "down", "skipped", "not_bootstrapped", "fixture"]
OverallStatus = Literal["ok", "degraded", "down"]

# Without either of these no audio path is possible, so the server is `down`.
ESSENTIAL_UPSTREAMS = frozenset({"postgres", "whisper"})
# Optional upstreams report their real probe result but never change the
# overall status: Voxtral is only an opt-in TTS voice, and the app falls back
# to Piper when it is unavailable.
OPTIONAL_UPSTREAMS = frozenset({"voxtral"})
# Probe results that say nothing about health (not configured / dev mode).
IGNORED_RESULTS = frozenset({"skipped", "fixture"})


# --- injectable dependencies ----------------------------------------------


@dataclass(frozen=True)
class HealthDependencies:
    """The outside world a health check touches. Each callable raises on
    failure; the probe turns that into `down`.

    - `env`               configuration, read when each probe runs.
    - `route`             the active analysis route.
    - `postgres_ping`     round-trips a trivial query.
    - `http_status`       GETs a URL, returns the status code, sending no
                          credentials; bounded by `PROBE_TIMEOUT`.
    - `voxtral_reachable` whether the Voxtral sidecar at a base URL answers.
    - `fixture_mode`      whether the server runs on fixtures (dev mode).
    - `msgraph_has_account` whether the MSAL cache holds at least one account.
    """

    postgres_ping: Callable[[], Awaitable[None]]
    http_status: Callable[[str], Awaitable[int]]
    voxtral_reachable: Callable[[str], Awaitable[bool]]
    msgraph_has_account: Callable[[], Awaitable[bool]]
    fixture_mode: Callable[[], bool]
    route: Callable[[], analysis_route.AnalysisRoute] = analysis_route.current
    env: Mapping[str, str] = field(default_factory=lambda: os.environ)


@dataclass(frozen=True)
class HealthSnapshot:
    status: OverallStatus
    upstream: dict[str, ProbeResult]


# --- real dependencies ----------------------------------------------------


async def _postgres_ping() -> None:
    import db

    pool = await db.get_pool()
    async with pool.acquire() as conn:
        await asyncio.wait_for(conn.execute("SELECT 1"), timeout=PROBE_TIMEOUT)


def http_status_getter(
    transport: httpx.AsyncBaseTransport | None = None,
) -> Callable[[str], Awaitable[int]]:
    """A plain GET with the probe timeout; `transport` lets tests observe the
    request without replacing `httpx`."""

    async def http_status(url: str) -> int:
        async with httpx.AsyncClient(timeout=PROBE_TIMEOUT, transport=transport) as client:
            return (await client.get(url)).status_code

    return http_status


async def _voxtral_reachable(base_url: str) -> bool:
    from voxtral_client import VoxtralClient

    return await VoxtralClient(base_url=base_url).probe(timeout_seconds=PROBE_TIMEOUT)


async def _msgraph_has_account() -> bool:
    from msgraph_client import get_client

    client = await get_client()
    return bool(client._app.get_accounts())  # type: ignore[attr-defined]


def _fixture_mode() -> bool:
    import fixtures

    return fixtures.fixture_mode()


def default_dependencies() -> HealthDependencies:
    return HealthDependencies(
        postgres_ping=_postgres_ping,
        http_status=http_status_getter(),
        voxtral_reachable=_voxtral_reachable,
        msgraph_has_account=_msgraph_has_account,
        fixture_mode=_fixture_mode,
    )


# --- individual probes ----------------------------------------------------


async def _probe_postgres(deps: HealthDependencies) -> ProbeResult:
    try:
        await deps.postgres_ping()
        return "ok"
    except Exception as exc:  # noqa: BLE001
        logger.debug("postgres probe failed: %s", exc)
        return "down"


async def _probe_http(deps: HealthDependencies, name: str, url: str) -> ProbeResult:
    """Any answer below 500 is `ok`; an error or timeout is `down`."""
    try:
        # Try a cheap GET on root or /health if available.
        return "ok" if await deps.http_status(url) < 500 else "down"
    except Exception as exc:  # noqa: BLE001
        logger.debug("%s probe failed (%s): %s", name, url, exc)
        return "down"


async def _probe_configured_http(
    deps: HealthDependencies, name: str, env_var: str, path: str
) -> ProbeResult:
    base = deps.env.get(env_var)
    if not base:
        return "skipped"
    return await _probe_http(deps, name, base.rstrip("/") + path)


async def _probe_qdrant(deps: HealthDependencies) -> ProbeResult:
    url = deps.env.get("QDRANT_URL")
    if not url:
        return "skipped"
    return await _probe_http(deps, "qdrant", url)


async def _probe_blindfold(deps: HealthDependencies) -> ProbeResult:
    """Reachability check on the Blindfold base URL, only called when routed.

    Any answer below 500 is `ok`, so the probe does not depend on Blindfold
    serving `/v1/models`. It sends no API key: it checks the host is up, not
    that the key is valid."""
    route = deps.route()
    if not route.is_blindfold:
        return "skipped"
    return await _probe_http(deps, "blindfold", route.blindfold_base_url + "/v1/models")


async def _probe_voxtral(deps: HealthDependencies) -> ProbeResult:
    """Reachability check for the vLLM Omni sidecar, under the tight probe
    timeout so a slow vLLM startup doesn't block the iOS reachability poll."""
    base = deps.env.get("VOXTRAL_BASE_URL")
    if not base:
        return "skipped"
    try:
        return "ok" if await deps.voxtral_reachable(base) else "down"
    except Exception as exc:  # noqa: BLE001
        logger.debug("voxtral probe failed: %s", exc)
        return "down"


async def _probe_msgraph(deps: HealthDependencies) -> ProbeResult:
    """Token freshness check: cache loaded + at least one account.

    In fixture mode the probe reports `fixture` so the iOS UI can show a
    distinct dev-mode banner.
    """
    if deps.fixture_mode():
        return "fixture"
    if not (deps.env.get("MSGRAPH_CLIENT_ID") and deps.env.get("MSGRAPH_TENANT_ID")):
        return "skipped"
    try:
        return "ok" if await deps.msgraph_has_account() else "not_bootstrapped"
    except Exception as exc:  # noqa: BLE001
        logger.debug("msgraph probe failed: %s", exc)
        return "down"


# --- overall status -------------------------------------------------------


def overall_status(upstream: dict[str, ProbeResult]) -> OverallStatus:
    """Fold the per-upstream probe results into one overall status.

    - `down`     — an essential upstream (postgres, whisper) is `down`.
    - `degraded` — any other non-optional upstream that is neither `skipped`
                   nor `fixture` is not `ok` (incl. msgraph `not_bootstrapped`).
    - `ok`       — otherwise. Optional upstreams (voxtral) are never counted.
    """
    if any(upstream.get(name) == "down" for name in ESSENTIAL_UPSTREAMS):
        return "down"
    counted = (
        result
        for name, result in upstream.items()
        if name not in OPTIONAL_UPSTREAMS and result not in IGNORED_RESULTS
    )
    return "ok" if all(result == "ok" for result in counted) else "degraded"


# --- snapshot -------------------------------------------------------------


async def check_health(deps: HealthDependencies | None = None) -> HealthSnapshot:
    """Probe every upstream and report the overall status.

    The seven standing probes run concurrently; the `blindfold` entry exists
    only when routed, and is probed after them."""
    deps = deps or default_dependencies()
    names = ("postgres", "qdrant", "whisper", "lightrag", "ollama", "msgraph", "voxtral")
    probes = await asyncio.gather(
        _probe_postgres(deps),
        _probe_qdrant(deps),
        _probe_configured_http(deps, "whisper", "WHISPER_URL", "/"),
        _probe_configured_http(deps, "lightrag", "LIGHTRAG_URL", "/health"),
        _probe_configured_http(deps, "ollama", "OLLAMA_BASE_URL", "/api/tags"),
        _probe_msgraph(deps),
        _probe_voxtral(deps),
    )
    upstream: dict[str, ProbeResult] = dict(zip(names, probes))
    # Only when routed: with the default route the response has no key.
    if deps.route().is_blindfold:
        upstream["blindfold"] = await _probe_blindfold(deps)

    return HealthSnapshot(status=overall_status(upstream), upstream=upstream)
