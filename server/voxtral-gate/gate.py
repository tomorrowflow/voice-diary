"""Lazy-wake reverse proxy in front of the Voxtral vLLM Omni engine.

Voxtral holds ~19 GB of VRAM on the RTX 3090 but serves a route the iOS
app hits in short bursts. This gate sits at `voxtral:8001` — the address
`webapp` already talks to — and forwards to the real engine at
`voxtral-engine:8001`, putting it to sleep when idle:

    idle > VOXTRAL_IDLE_SECONDS  →  POST /sleep?level=1   (weights → host RAM)
    request arrives              →  POST /wake_up         (~seconds)
                                    then proxy as normal

Sleep level 1 offloads weights to host RAM and discards the KV cache, so
waking is a few seconds rather than the ~60 s a full container restart
costs. The vLLM API-server process stays alive throughout, which is what
lets the no-wake passthrough below work.

Two things this deliberately does NOT do:

  * It never wakes the engine for a liveness probe. `webapp`'s /health
    route probes Voxtral via `GET /v1/models`, and iOS polls that before
    onboarding — waking a 20 GB model for a reachability check would
    defeat the entire point. Those paths are answered by the still-alive
    API server while the weights are offloaded.
  * It never returns 503-while-warming. A request that arrives during a
    wake (or during the engine's initial boot) is held open until the
    engine is ready, so `voxtral_client`'s existing error branches stay
    exactly as meaningful as they were before the gate existed.

The /sleep, /wake_up and /is_sleeping routes only exist when the engine
runs with VLLM_SERVER_DEV_MODE=1 (see docker-compose.yml). If they're
absent the gate logs a warning once and degrades to a plain pass-through
proxy — correct, just without the VRAM saving.
"""

from __future__ import annotations

import asyncio
import logging
import os
import time
from contextlib import asynccontextmanager
from typing import AsyncIterator, Callable

import httpx
from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse, StreamingResponse

logging.basicConfig(
    level=os.getenv("LOG_LEVEL", "INFO").upper(),
    format="%(asctime)s %(levelname)s %(name)s %(message)s",
)
logger = logging.getLogger("voxtral_gate")


# --- configuration --------------------------------------------------------

ENGINE_URL = os.getenv("VOXTRAL_ENGINE_URL", "http://voxtral-engine:8001").rstrip("/")
IDLE_SECONDS = float(os.getenv("VOXTRAL_IDLE_SECONDS", "300"))
SLEEP_LEVEL = os.getenv("VOXTRAL_SLEEP_LEVEL", "1")
WAKE_TIMEOUT = float(os.getenv("VOXTRAL_WAKE_TIMEOUT_SECONDS", "180"))
PROXY_TIMEOUT = float(os.getenv("VOXTRAL_PROXY_TIMEOUT_SECONDS", "300"))
BOOT_TIMEOUT = float(os.getenv("VOXTRAL_BOOT_TIMEOUT_SECONDS", "600"))
IDLE_POLL_SECONDS = float(os.getenv("VOXTRAL_IDLE_POLL_SECONDS", "10"))
SLEEP_ON_START = os.getenv("VOXTRAL_SLEEP_ON_START", "true").lower() == "true"

# Answered without waking the engine — the vLLM API server process serves
# these fine with its weights offloaded.
NO_WAKE_PATHS = frozenset(
    {"/health", "/ping", "/version", "/metrics", "/v1/models", "/is_sleeping"}
)

# Per RFC 9110 §7.6.1 these are connection-scoped and must not be relayed.
HOP_BY_HOP_HEADERS = frozenset(
    {
        "connection",
        "keep-alive",
        "proxy-authenticate",
        "proxy-authorization",
        "te",
        "trailers",
        "transfer-encoding",
        "upgrade",
    }
)


# --- gate -----------------------------------------------------------------


class EngineGate:
    """Tracks whether the engine is asleep and serialises the transitions.

    `_asleep` is None until the bootstrap probe has spoken to the engine.
    `_sleep_supported` is None for the same window, then True/False for
    the process lifetime.
    """

    def __init__(self, client: httpx.AsyncClient) -> None:
        self._client = client
        self._lock = asyncio.Lock()
        self._booted = asyncio.Event()
        self._asleep: bool | None = None
        self._sleep_supported: bool | None = None
        self._inflight = 0
        self._last_activity = time.monotonic()
        self._wakes = 0
        self._sleeps = 0

    # -- request accounting ------------------------------------------------

    def note_start(self) -> None:
        """Called before a waking request is admitted. Incrementing the
        in-flight count *before* the awake check is what stops the idle
        loop from sleeping the engine out from under a live request."""
        self._inflight += 1
        self._last_activity = time.monotonic()

    def note_end(self) -> None:
        self._inflight -= 1
        self._last_activity = time.monotonic()

    # -- lifecycle ---------------------------------------------------------

    async def bootstrap(self) -> None:
        """Wait for the engine to finish its ~60 s boot, learn whether the
        dev-mode sleep routes exist, then optionally sleep it immediately
        so a freshly-composed stack doesn't sit on 20 GB of VRAM."""
        deadline = time.monotonic() + BOOT_TIMEOUT
        while time.monotonic() < deadline:
            try:
                resp = await self._client.get(f"{ENGINE_URL}/is_sleeping", timeout=5.0)
            except httpx.HTTPError:
                await asyncio.sleep(2.0)
                continue

            if resp.status_code == 404:
                self._sleep_supported = False
                self._asleep = False
                logger.warning(
                    "engine has no /is_sleeping route — start it with "
                    "VLLM_SERVER_DEV_MODE=1 and --enable-sleep-mode to enable "
                    "VRAM reclaim. Running as a plain pass-through proxy."
                )
                break

            if resp.status_code < 400:
                self._sleep_supported = True
                self._asleep = bool(resp.json().get("is_sleeping", False))
                logger.info(
                    "engine reachable, sleep control available (asleep=%s)",
                    self._asleep,
                )
                break

            await asyncio.sleep(2.0)
        else:
            # Never became reachable. Leave sleep control off; proxied
            # requests will surface the connection error to the caller.
            self._sleep_supported = False
            self._asleep = False
            logger.error("engine unreachable after %.0fs of boot polling", BOOT_TIMEOUT)

        if self._sleep_supported and SLEEP_ON_START and not self._asleep:
            # Taken before releasing waiters so a request queued on boot
            # waits out this sleep and then wakes the engine, rather than
            # racing the /sleep RPC via ensure_awake's fast path.
            async with self._lock:
                self._booted.set()
                await self._sleep_now(reason="startup")
        else:
            self._booted.set()

    async def ensure_awake(self) -> None:
        """Block until the engine can serve. Held open rather than failing
        fast — see the module docstring."""
        await asyncio.wait_for(self._booted.wait(), timeout=BOOT_TIMEOUT)

        if not self._sleep_supported:
            return
        # The lock-free fast path is only safe when no transition is in
        # flight: during an idle /sleep RPC `_asleep` still reads False.
        if self._asleep is False and not self._lock.locked():
            return

        async with self._lock:
            if self._asleep is False:
                return  # another request woke it while we queued
            started = time.monotonic()
            resp = await self._client.post(
                f"{ENGINE_URL}/wake_up", timeout=WAKE_TIMEOUT
            )
            resp.raise_for_status()
            self._asleep = False
            self._wakes += 1
            logger.info("woke engine in %.2fs", time.monotonic() - started)

    async def maybe_sleep(self) -> None:
        """Idle-loop tick. No-ops unless the engine is awake, unused, and
        past the idle window."""
        if not self._sleep_supported or self._asleep is not False:
            return
        if self._inflight > 0:
            return
        if time.monotonic() - self._last_activity < IDLE_SECONDS:
            return

        async with self._lock:
            # Re-check under the lock: a request may have arrived while we
            # waited for it.
            if self._asleep is not False or self._inflight > 0:
                return
            if time.monotonic() - self._last_activity < IDLE_SECONDS:
                return
            await self._sleep_now(reason="idle")

    async def _sleep_now(self, *, reason: str) -> None:
        started = time.monotonic()
        try:
            resp = await self._client.post(
                f"{ENGINE_URL}/sleep",
                params={"level": SLEEP_LEVEL},
                timeout=WAKE_TIMEOUT,
            )
            resp.raise_for_status()
        except httpx.HTTPError as exc:
            logger.warning("sleep (%s) failed: %s", reason, exc)
            return
        self._asleep = True
        self._sleeps += 1
        logger.info(
            "slept engine (%s, level=%s) in %.2fs",
            reason, SLEEP_LEVEL, time.monotonic() - started,
        )

    # -- introspection -----------------------------------------------------

    def status(self) -> dict[str, object]:
        idle_for = time.monotonic() - self._last_activity
        return {
            "engine_url": ENGINE_URL,
            "sleep_supported": self._sleep_supported,
            "asleep": self._asleep,
            "inflight": self._inflight,
            "idle_seconds": round(idle_for, 1),
            "idle_timeout_seconds": IDLE_SECONDS,
            "sleep_level": SLEEP_LEVEL,
            "wakes": self._wakes,
            "sleeps": self._sleeps,
        }


# --- app ------------------------------------------------------------------


@asynccontextmanager
async def lifespan(app: FastAPI) -> AsyncIterator[None]:
    client = httpx.AsyncClient(timeout=PROXY_TIMEOUT)
    gate = EngineGate(client)
    app.state.client = client
    app.state.gate = gate

    boot_task = asyncio.create_task(gate.bootstrap())
    idle_task = asyncio.create_task(_idle_loop(gate))
    try:
        yield
    finally:
        for task in (idle_task, boot_task):
            task.cancel()
        await asyncio.gather(idle_task, boot_task, return_exceptions=True)
        await client.aclose()


async def _idle_loop(gate: EngineGate) -> None:
    while True:
        await asyncio.sleep(IDLE_POLL_SECONDS)
        try:
            await gate.maybe_sleep()
        except Exception as exc:  # noqa: BLE001 — the loop must never die
            logger.warning("idle tick failed: %s", exc)


app = FastAPI(title="voxtral-gate", lifespan=lifespan)


@app.get("/gate/status")
async def gate_status(request: Request) -> JSONResponse:
    """Gate's own state — never touches the engine, safe to poll."""
    return JSONResponse(request.app.state.gate.status())


@app.api_route(
    "/{path:path}",
    methods=["GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS"],
    # The handler returns a raw Response subclass, not a serialisable body;
    # without this FastAPI tries to build a Pydantic model from the union.
    response_model=None,
)
async def proxy(path: str, request: Request) -> StreamingResponse | JSONResponse:
    gate: EngineGate = request.app.state.gate
    client: httpx.AsyncClient = request.app.state.client

    needs_engine = request.url.path not in NO_WAKE_PATHS

    if needs_engine:
        gate.note_start()
        try:
            await gate.ensure_awake()
        except (httpx.HTTPError, asyncio.TimeoutError) as exc:
            gate.note_end()
            logger.error("wake failed: %s", exc)
            return JSONResponse(
                status_code=503,
                content={"error": "voxtral_wake_failed", "detail": str(exc)},
            )
        except BaseException:
            gate.note_end()
            raise

    release = gate.note_end if needs_engine else None
    try:
        return await _forward(client, request, path, release=release)
    except BaseException:
        if release:
            release()
        raise


async def _forward(
    client: httpx.AsyncClient,
    request: Request,
    path: str,
    *,
    release: Callable[[], None] | None,
) -> StreamingResponse | JSONResponse:
    """Relay the request to the engine and stream the response back.

    `release` (the in-flight decrement) fires when the response body is
    fully drained, not when the headers arrive — a long synthesis must
    keep the engine pinned awake for its whole duration.
    """
    headers = {
        key: value
        for key, value in request.headers.items()
        if key.lower() not in HOP_BY_HOP_HEADERS and key.lower() != "host"
    }
    body = await request.body()

    upstream = client.build_request(
        request.method,
        f"{ENGINE_URL}/{path}",
        params=request.url.query or None,
        headers=headers,
        content=body,
    )

    try:
        resp = await client.send(upstream, stream=True)
    except httpx.HTTPError as exc:
        if release:
            release()
        logger.error("proxy to engine failed: %s", exc)
        return JSONResponse(
            status_code=502,
            content={"error": "voxtral_proxy_error", "detail": str(exc)},
        )

    async def stream() -> AsyncIterator[bytes]:
        try:
            async for chunk in resp.aiter_raw():
                yield chunk
        finally:
            await resp.aclose()
            if release:
                release()

    passthrough = {
        key: value
        for key, value in resp.headers.items()
        if key.lower() not in HOP_BY_HOP_HEADERS and key.lower() != "content-length"
    }
    return StreamingResponse(
        stream(),
        status_code=resp.status_code,
        headers=passthrough,
    )
