"""Health checking through its injectable boundary (REF-128).

`check_health` is driven with explicit fakes for Postgres, HTTP, Voxtral, the
MSAL cache, fixture mode, the environment and the analysis route. Nothing here
patches a `_probe_*` helper or replaces `httpx`.
"""

from __future__ import annotations

import asyncio
from collections.abc import Mapping

import httpx
import pytest

import analysis_route
import health_checks
from health_checks import HealthDependencies, check_health

BLINDFOLD = "http://blindfold.test:8080/proxy"

ENV = {
    "QDRANT_URL": "http://qdrant.test:6333",
    "WHISPER_URL": "http://whisper.test:9000/",
    "LIGHTRAG_URL": "http://lightrag.test:9621",
    "OLLAMA_BASE_URL": "http://ollama.test:11434/",
    "MSGRAPH_CLIENT_ID": "client",
    "MSGRAPH_TENANT_ID": "tenant",
    "VOXTRAL_BASE_URL": "http://voxtral.test:8000",
}

URLS = {
    "qdrant": "http://qdrant.test:6333",
    "whisper": "http://whisper.test:9000/",
    "lightrag": "http://lightrag.test:9621/health",
    "ollama": "http://ollama.test:11434/api/tags",
}

OK_UPSTREAM = {
    "postgres": "ok",
    "qdrant": "ok",
    "whisper": "ok",
    "lightrag": "ok",
    "ollama": "ok",
    "msgraph": "ok",
    "voxtral": "ok",
}


def local_route() -> analysis_route.AnalysisRoute:
    return analysis_route.from_env({})


def blindfold_route(key: str | None = None) -> analysis_route.AnalysisRoute:
    env = {
        "ANALYSIS_ROUTE": "blindfold",
        "BLINDFOLD_BASE_URL": BLINDFOLD,
        "BLINDFOLD_ANALYSIS_MODEL": "frontier-1",
    }
    if key:
        env["BLINDFOLD_API_KEY"] = key
    return analysis_route.from_env(env)


class World:
    """Fake upstreams. `http` maps a URL to the status it answers with or the
    exception it raises; an unlisted URL answers 200. Every call is recorded."""

    def __init__(
        self,
        *,
        env: Mapping[str, str] = ENV,
        route: analysis_route.AnalysisRoute | None = None,
        http: Mapping[str, int | Exception] | None = None,
        postgres: Exception | None = None,
        voxtral: bool | Exception = True,
        msgraph_account: bool | Exception = True,
        fixture: bool = False,
    ) -> None:
        self.env = dict(env)
        self.route = route or local_route()
        self.http = dict(http or {})
        self.postgres = postgres
        self.voxtral = voxtral
        self.msgraph_account = msgraph_account
        self.fixture = fixture
        self.http_calls: list[str] = []
        self.voxtral_calls: list[str] = []
        self.postgres_pings = 0
        self.msgraph_checks = 0

    async def _postgres_ping(self) -> None:
        self.postgres_pings += 1
        if self.postgres:
            raise self.postgres

    async def _http_status(self, url: str) -> int:
        self.http_calls.append(url)
        answer = self.http.get(url, 200)
        if isinstance(answer, Exception):
            raise answer
        return answer

    async def _voxtral_reachable(self, base_url: str) -> bool:
        self.voxtral_calls.append(base_url)
        if isinstance(self.voxtral, Exception):
            raise self.voxtral
        return self.voxtral

    async def _msgraph_has_account(self) -> bool:
        self.msgraph_checks += 1
        if isinstance(self.msgraph_account, Exception):
            raise self.msgraph_account
        return self.msgraph_account

    def deps(self) -> HealthDependencies:
        return HealthDependencies(
            postgres_ping=self._postgres_ping,
            http_status=self._http_status,
            voxtral_reachable=self._voxtral_reachable,
            msgraph_has_account=self._msgraph_has_account,
            fixture_mode=lambda: self.fixture,
            route=lambda: self.route,
            env=self.env,
        )


async def snapshot(world: World):
    return await check_health(world.deps())


# --- essential, degraded, optional ----------------------------------------


async def test_everything_up_is_ok_in_probe_order() -> None:
    result = await snapshot(World())
    assert result.status == "ok"
    assert result.upstream == OK_UPSTREAM
    assert list(result.upstream) == list(OK_UPSTREAM)


async def test_probes_the_configured_destinations() -> None:
    world = World()
    await snapshot(world)
    assert sorted(world.http_calls) == sorted(URLS.values())
    assert world.voxtral_calls == ["http://voxtral.test:8000"]
    assert world.postgres_pings == 1


@pytest.mark.parametrize("essential", ["postgres", "whisper"])
async def test_essential_down_is_down(essential: str) -> None:
    if essential == "postgres":
        world = World(postgres=ConnectionError("no pool"))
    else:
        world = World(http={URLS["whisper"]: httpx.ConnectError("refused")})
    result = await snapshot(world)
    assert result.upstream[essential] == "down"
    assert result.status == "down"


@pytest.mark.parametrize("name", ["qdrant", "lightrag", "ollama"])
async def test_non_essential_down_is_degraded(name: str) -> None:
    result = await snapshot(World(http={URLS[name]: 503}))
    assert result.upstream[name] == "down"
    assert result.status == "degraded"


async def test_down_beats_degraded() -> None:
    world = World(http={URLS["whisper"]: 500, URLS["ollama"]: 500})
    assert (await snapshot(world)).status == "down"


@pytest.mark.parametrize("voxtral", [False, ConnectionError("refused")])
async def test_optional_voxtral_down_is_reported_but_stays_ok(voxtral) -> None:
    result = await snapshot(World(voxtral=voxtral))
    assert result.upstream["voxtral"] == "down"
    assert result.status == "ok"


async def test_voxtral_down_does_not_hide_a_real_degradation() -> None:
    result = await snapshot(World(voxtral=False, http={URLS["ollama"]: 500}))
    assert result.status == "degraded"


@pytest.mark.parametrize(
    ("status", "expected"),
    [(200, "ok"), (301, "ok"), (401, "ok"), (404, "ok"), (499, "ok"), (500, "down"), (503, "down")],
)
async def test_http_answers_below_500_are_ok(status: int, expected: str) -> None:
    result = await snapshot(World(http={URLS["qdrant"]: status}))
    assert result.upstream["qdrant"] == expected


async def test_http_timeout_is_down() -> None:
    result = await snapshot(World(http={URLS["lightrag"]: httpx.ReadTimeout("slow")}))
    assert result.upstream["lightrag"] == "down"


# --- skipped ----------------------------------------------------------------


async def test_unconfigured_upstreams_are_skipped_and_not_probed() -> None:
    world = World(env={})
    result = await snapshot(world)
    assert result.upstream == {
        "postgres": "ok",
        "qdrant": "skipped",
        "whisper": "skipped",
        "lightrag": "skipped",
        "ollama": "skipped",
        "msgraph": "skipped",
        "voxtral": "skipped",
    }
    assert result.status == "ok"
    assert world.http_calls == []
    assert world.voxtral_calls == []
    assert world.msgraph_checks == 0


async def test_empty_url_counts_as_unconfigured() -> None:
    result = await snapshot(World(env={**ENV, "QDRANT_URL": "", "OLLAMA_BASE_URL": ""}))
    assert result.upstream["qdrant"] == "skipped"
    assert result.upstream["ollama"] == "skipped"


@pytest.mark.parametrize("missing", ["MSGRAPH_CLIENT_ID", "MSGRAPH_TENANT_ID"])
async def test_msgraph_needs_both_client_and_tenant(missing: str) -> None:
    world = World(env={k: v for k, v in ENV.items() if k != missing})
    result = await snapshot(world)
    assert result.upstream["msgraph"] == "skipped"
    assert world.msgraph_checks == 0


# --- fixture / Graph ----------------------------------------------------------


async def test_fixture_mode_reports_fixture_without_touching_graph() -> None:
    world = World(fixture=True)
    result = await snapshot(world)
    assert result.upstream["msgraph"] == "fixture"
    assert result.status == "ok"
    assert world.msgraph_checks == 0


async def test_fixture_mode_wins_over_missing_graph_settings() -> None:
    result = await snapshot(World(env={}, fixture=True))
    assert result.upstream["msgraph"] == "fixture"


async def test_graph_not_bootstrapped_is_degraded() -> None:
    result = await snapshot(World(msgraph_account=False))
    assert result.upstream["msgraph"] == "not_bootstrapped"
    assert result.status == "degraded"


async def test_graph_failure_is_down_and_degraded() -> None:
    result = await snapshot(World(msgraph_account=RuntimeError("no cache")))
    assert result.upstream["msgraph"] == "down"
    assert result.status == "degraded"


# --- Blindfold ---------------------------------------------------------------


async def test_default_local_route_has_no_blindfold_entry_and_sends_nothing_to_it() -> None:
    world = World()
    result = await snapshot(world)
    assert "blindfold" not in result.upstream
    assert not any(url.startswith(BLINDFOLD) for url in world.http_calls)


@pytest.mark.parametrize("status", [200, 401, 404, 499])
async def test_routed_blindfold_below_500_is_ok(status: int) -> None:
    url = f"{BLINDFOLD}/v1/models"
    world = World(route=blindfold_route(), http={url: status})
    result = await snapshot(world)
    assert result.upstream["blindfold"] == "ok"
    assert result.status == "ok"
    assert world.http_calls.count(url) == 1


@pytest.mark.parametrize("status", [500, 502, 503])
async def test_routed_blindfold_5xx_is_down_and_degraded(status: int) -> None:
    world = World(route=blindfold_route(), http={f"{BLINDFOLD}/v1/models": status})
    result = await snapshot(world)
    assert result.upstream["blindfold"] == "down"
    assert result.status == "degraded"


@pytest.mark.parametrize(
    "error",
    [httpx.ConnectError("refused"), httpx.ConnectTimeout("slow"), httpx.ReadTimeout("slow")],
)
async def test_routed_blindfold_unreachable_is_down_and_degraded(error: Exception) -> None:
    world = World(route=blindfold_route(), http={f"{BLINDFOLD}/v1/models": error})
    result = await snapshot(world)
    assert result.upstream["blindfold"] == "down"
    assert result.status == "degraded"


async def test_blindfold_is_probed_separately_after_the_standing_probes() -> None:
    world = World(route=blindfold_route())
    result = await snapshot(world)
    assert list(result.upstream) == [*OK_UPSTREAM, "blindfold"]
    assert world.http_calls[-1] == f"{BLINDFOLD}/v1/models"
    assert world.http_calls[:-1] != []


@pytest.mark.parametrize("essential", ["postgres", "whisper"])
@pytest.mark.parametrize("routed", [False, True])
async def test_essential_down_is_down_routed_or_not(essential: str, routed: bool) -> None:
    kwargs: dict = {"route": blindfold_route() if routed else local_route()}
    if essential == "postgres":
        kwargs["postgres"] = ConnectionError("no pool")
    else:
        kwargs["http"] = {URLS["whisper"]: 503}
    result = await snapshot(World(**kwargs))
    assert result.status == "down"


async def test_ollama_entry_is_unchanged_when_routed() -> None:
    world = World(route=blindfold_route(), http={URLS["ollama"]: 500})
    result = await snapshot(world)
    assert result.upstream["ollama"] == "down"
    assert result.upstream["blindfold"] == "ok"
    assert result.status == "degraded"


async def test_the_route_is_read_when_the_check_runs() -> None:
    world = World()
    deps = world.deps()
    assert "blindfold" not in (await check_health(deps)).upstream
    world.route = blindfold_route()
    assert "blindfold" in (await check_health(deps)).upstream


# --- concurrency ----------------------------------------------------------------


async def test_standing_probes_run_concurrently() -> None:
    """Postgres only answers once an HTTP probe is already in flight, so a
    sequential implementation would stall until the timeout."""
    world = World()
    http_started = asyncio.Event()
    base = world.deps()

    async def postgres_ping() -> None:
        await asyncio.wait_for(http_started.wait(), timeout=1)

    async def http_status(url: str) -> int:
        http_started.set()
        return await base.http_status(url)

    deps = HealthDependencies(
        postgres_ping=postgres_ping,
        http_status=http_status,
        voxtral_reachable=base.voxtral_reachable,
        msgraph_has_account=base.msgraph_has_account,
        fixture_mode=base.fixture_mode,
        route=base.route,
        env=base.env,
    )
    result = await check_health(deps)
    assert result.upstream["postgres"] == "ok"


# --- the real HTTP adapter ----------------------------------------------------


def _real_http_deps(
    world: World, transport: httpx.MockTransport
) -> HealthDependencies:
    base = world.deps()
    return HealthDependencies(
        postgres_ping=base.postgres_ping,
        http_status=health_checks.http_status_getter(transport),
        voxtral_reachable=base.voxtral_reachable,
        msgraph_has_account=base.msgraph_has_account,
        fixture_mode=base.fixture_mode,
        route=base.route,
        env=base.env,
    )


async def test_blindfold_probe_sends_no_api_key_and_uses_the_tight_timeout() -> None:
    requests: list[httpx.Request] = []

    def handle(request: httpx.Request) -> httpx.Response:
        requests.append(request)
        return httpx.Response(200)

    world = World(env={}, route=blindfold_route(key="sk-secret-key"))
    result = await check_health(_real_http_deps(world, httpx.MockTransport(handle)))
    assert result.upstream["blindfold"] == "ok"
    (request,) = requests
    assert (request.method, str(request.url)) == ("GET", f"{BLINDFOLD}/v1/models")
    assert "authorization" not in request.headers
    assert "sk-secret-key" not in str(request.url)
    timeout = request.extensions["timeout"]
    assert set(timeout.values()) == {health_checks.PROBE_TIMEOUT}
    assert health_checks.PROBE_TIMEOUT <= 5


async def test_real_http_adapter_reports_transport_errors_as_down() -> None:
    def handle(request: httpx.Request) -> httpx.Response:
        raise httpx.ConnectError("refused", request=request)

    world = World(env={"QDRANT_URL": URLS["qdrant"]})
    result = await check_health(_real_http_deps(world, httpx.MockTransport(handle)))
    assert result.upstream["qdrant"] == "down"


# --- the status matrix ----------------------------------------------------------


def test_overall_status_ignores_skipped_and_fixture_but_counts_other_failures() -> None:
    upstream = {
        **OK_UPSTREAM,
        "msgraph": "fixture",
        "qdrant": "skipped",
        "lightrag": "down",
    }
    assert health_checks.overall_status(upstream) == "degraded"  # type: ignore[arg-type]
