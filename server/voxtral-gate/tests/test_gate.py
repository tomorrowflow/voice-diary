"""Tests for `gate.EngineGate` — the sleep/wake decision logic.

Run inside the gate container so deps match prod:

    docker compose run --rm --no-deps --entrypoint pytest voxtral -q tests/test_gate.py

The engine is an `httpx.MockTransport`, so no live vLLM is needed. What's
under test is *when* the gate decides to sleep or wake, not the proxying
itself — the proxy path is a thin relay verified end-to-end against the
real engine (see README).
"""

from __future__ import annotations

import asyncio

import httpx
import pytest

import gate as gate_mod
from gate import EngineGate


# --- helpers --------------------------------------------------------------


class FakeEngine:
    """Records the sleep/wake calls the gate makes."""

    def __init__(self, *, sleeping: bool = False, supports_sleep: bool = True) -> None:
        self.sleeping = sleeping
        self.supports_sleep = supports_sleep
        self.calls: list[str] = []

    def handler(self, request: httpx.Request) -> httpx.Response:
        path = request.url.path
        self.calls.append(path)

        if not self.supports_sleep and path in ("/sleep", "/wake_up", "/is_sleeping"):
            return httpx.Response(404)

        if path == "/is_sleeping":
            return httpx.Response(200, json={"is_sleeping": self.sleeping})
        if path == "/sleep":
            self.sleeping = True
            return httpx.Response(200)
        if path == "/wake_up":
            self.sleeping = False
            return httpx.Response(200)
        return httpx.Response(200, content=b"ok")


def _gate(engine: FakeEngine) -> EngineGate:
    client = httpx.AsyncClient(transport=httpx.MockTransport(engine.handler))
    return EngineGate(client)


# --- bootstrap ------------------------------------------------------------


async def test_bootstrap_sleeps_engine_on_start(monkeypatch: pytest.MonkeyPatch) -> None:
    """A freshly-composed stack shouldn't sit on 20 GB until the first
    idle window elapses."""
    monkeypatch.setattr(gate_mod, "SLEEP_ON_START", True)
    engine = FakeEngine(sleeping=False)
    g = _gate(engine)

    await g.bootstrap()

    assert engine.sleeping is True
    assert g.status()["asleep"] is True
    assert g.status()["sleep_supported"] is True


async def test_bootstrap_degrades_to_passthrough_without_dev_mode() -> None:
    """No /is_sleeping route means the engine wasn't started with
    VLLM_SERVER_DEV_MODE=1. The gate must still proxy, just without
    reclaiming VRAM."""
    engine = FakeEngine(supports_sleep=False)
    g = _gate(engine)

    await g.bootstrap()

    assert g.status()["sleep_supported"] is False
    assert g.status()["asleep"] is False
    # Must not have attempted a sleep it can't perform.
    assert "/sleep" not in engine.calls


# --- wake -----------------------------------------------------------------


async def test_ensure_awake_wakes_a_sleeping_engine(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(gate_mod, "SLEEP_ON_START", False)
    engine = FakeEngine(sleeping=True)
    g = _gate(engine)
    await g.bootstrap()

    await g.ensure_awake()

    assert engine.sleeping is False
    assert engine.calls.count("/wake_up") == 1


async def test_ensure_awake_is_a_noop_when_already_awake(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setattr(gate_mod, "SLEEP_ON_START", False)
    engine = FakeEngine(sleeping=False)
    g = _gate(engine)
    await g.bootstrap()

    await g.ensure_awake()

    assert "/wake_up" not in engine.calls


async def test_concurrent_requests_wake_the_engine_once(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """A burst of synthesis calls after an idle period must not fire N
    parallel /wake_up RPCs at the engine."""
    monkeypatch.setattr(gate_mod, "SLEEP_ON_START", False)
    engine = FakeEngine(sleeping=True)
    g = _gate(engine)
    await g.bootstrap()

    await asyncio.gather(*(g.ensure_awake() for _ in range(8)))

    assert engine.calls.count("/wake_up") == 1


# --- idle sleep -----------------------------------------------------------


async def test_maybe_sleep_waits_for_the_idle_window(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setattr(gate_mod, "SLEEP_ON_START", False)
    monkeypatch.setattr(gate_mod, "IDLE_SECONDS", 300.0)
    engine = FakeEngine(sleeping=False)
    g = _gate(engine)
    await g.bootstrap()

    await g.maybe_sleep()

    assert engine.sleeping is False
    assert "/sleep" not in engine.calls


async def test_maybe_sleep_sleeps_once_past_the_idle_window(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setattr(gate_mod, "SLEEP_ON_START", False)
    monkeypatch.setattr(gate_mod, "IDLE_SECONDS", 0.0)
    engine = FakeEngine(sleeping=False)
    g = _gate(engine)
    await g.bootstrap()

    await g.maybe_sleep()

    assert engine.sleeping is True


async def test_maybe_sleep_never_sleeps_under_an_inflight_request(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """The regression this guards: a synthesis longer than the idle window
    must not have the weights yanked out from under it."""
    monkeypatch.setattr(gate_mod, "SLEEP_ON_START", False)
    monkeypatch.setattr(gate_mod, "IDLE_SECONDS", 0.0)
    engine = FakeEngine(sleeping=False)
    g = _gate(engine)
    await g.bootstrap()

    g.note_start()
    await g.maybe_sleep()
    assert engine.sleeping is False

    g.note_end()
    await g.maybe_sleep()
    assert engine.sleeping is True


async def test_request_during_idle_sleep_waits_and_rewakes(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """A request admitted while the idle /sleep RPC is still in flight
    must not be proxied onto an engine that is going to sleep — it waits
    for the sleep to land, then wakes the engine."""
    monkeypatch.setattr(gate_mod, "SLEEP_ON_START", False)
    monkeypatch.setattr(gate_mod, "IDLE_SECONDS", 0.0)
    engine = FakeEngine(sleeping=False)
    sleep_started = asyncio.Event()

    async def slow_handler(request: httpx.Request) -> httpx.Response:
        if request.url.path == "/sleep":
            sleep_started.set()
            await asyncio.sleep(0.05)
        return engine.handler(request)

    g = EngineGate(httpx.AsyncClient(transport=httpx.MockTransport(slow_handler)))
    await g.bootstrap()

    idle_tick = asyncio.create_task(g.maybe_sleep())
    await sleep_started.wait()
    g.note_start()
    await g.ensure_awake()
    await idle_tick

    assert engine.sleeping is False
    assert engine.calls[-2:] == ["/sleep", "/wake_up"]


async def test_maybe_sleep_is_a_noop_when_sleep_unsupported() -> None:
    engine = FakeEngine(supports_sleep=False)
    g = _gate(engine)
    await g.bootstrap()

    await g.maybe_sleep()

    assert "/sleep" not in engine.calls


# --- passthrough policy ---------------------------------------------------


def test_liveness_paths_are_excluded_from_waking() -> None:
    """webapp's /health probes Voxtral via GET /v1/models, and iOS polls
    that before onboarding. Waking a 20 GB model for a reachability check
    would defeat the gate entirely."""
    assert "/v1/models" in gate_mod.NO_WAKE_PATHS
    assert "/health" in gate_mod.NO_WAKE_PATHS
    assert "/v1/audio/speech" not in gate_mod.NO_WAKE_PATHS
