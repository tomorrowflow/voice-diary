"""UFH-03: `/health` overall status rules (SPEC §10.7).

`down` only for postgres/whisper; `degraded` for any other non-optional
upstream that is not `ok` (skipped/fixture ignored); voxtral is optional and
never changes the overall status.

The route is exercised through the `default_dependencies` seam of
`health_checks`; probe behavior itself is covered in `test_health_checks.py`.
"""

from __future__ import annotations

from collections.abc import Callable, Iterator

import httpx
import pytest
from fastapi.testclient import TestClient

import health_checks
import main
from health_checks import HealthDependencies
from routers import health
from tests.health_helpers import (
    BLINDFOLD,
    ENV,
    URLS,
    ProductionUpstreams,
    World,
    blindfold_route,
)

OK = {
    "postgres": "ok",
    "qdrant": "ok",
    "whisper": "ok",
    "lightrag": "ok",
    "ollama": "ok",
    "msgraph": "ok",
    "voxtral": "ok",
}


def _with(**overrides: str) -> dict[str, str]:
    return {**OK, **overrides}


CASES = [
    ("all_ok", {}, "ok"),
    ("postgres_down", {"postgres": "down"}, "down"),
    ("whisper_down", {"whisper": "down"}, "down"),
    ("postgres_and_whisper_down", {"postgres": "down", "whisper": "down"}, "down"),
    ("down_beats_degraded", {"whisper": "down", "ollama": "down"}, "down"),
    ("ollama_down", {"ollama": "down"}, "degraded"),
    ("lightrag_down", {"lightrag": "down"}, "degraded"),
    ("qdrant_down", {"qdrant": "down"}, "degraded"),
    ("msgraph_down", {"msgraph": "down"}, "degraded"),
    ("msgraph_not_bootstrapped", {"msgraph": "not_bootstrapped"}, "degraded"),
    ("msgraph_fixture", {"msgraph": "fixture"}, "ok"),
    ("msgraph_skipped", {"msgraph": "skipped"}, "ok"),
    ("ollama_skipped", {"ollama": "skipped"}, "ok"),
    ("lightrag_skipped", {"lightrag": "skipped"}, "ok"),
    ("qdrant_skipped", {"qdrant": "skipped"}, "ok"),
    ("voxtral_down", {"voxtral": "down"}, "ok"),
    ("voxtral_skipped", {"voxtral": "skipped"}, "ok"),
    ("voxtral_down_ollama_down", {"voxtral": "down", "ollama": "down"}, "degraded"),
    ("voxtral_down_whisper_down", {"voxtral": "down", "whisper": "down"}, "down"),
    (
        "skipped_and_fixture_with_one_failure",
        {"msgraph": "fixture", "qdrant": "skipped", "lightrag": "down"},
        "degraded",
    ),
]


@pytest.mark.parametrize(
    ("overrides", "expected"),
    [pytest.param(o, e, id=i) for i, o, e in CASES],
)
def test_overall_status(overrides: dict[str, str], expected: str) -> None:
    assert health.overall_status(_with(**overrides)) == expected


def test_blindfold_down_alone_is_degraded_never_down() -> None:
    assert health.overall_status(_with(blindfold="down")) == "degraded"
    assert health.overall_status(_with(blindfold="ok")) == "ok"


def test_router_keeps_the_boundary_surface() -> None:
    assert health.overall_status is health_checks.overall_status
    assert health.PROBE_TIMEOUT == health_checks.PROBE_TIMEOUT <= 5


# --- the route ------------------------------------------------------------


@pytest.fixture
def serve() -> Iterator[Callable[[HealthDependencies], TestClient]]:
    """Serve `/health` over the given dependencies."""
    # No `with`: the app's lifespan (Postgres etc.) is never started.
    client = TestClient(main.app)

    def use(deps: HealthDependencies) -> TestClient:
        main.app.dependency_overrides[health_checks.default_dependencies] = lambda: deps
        return client

    yield use
    main.app.dependency_overrides.pop(health_checks.default_dependencies, None)


def test_route_reports_every_upstream_and_status(
    serve: Callable[[HealthDependencies], TestClient],
) -> None:
    response = serve(World().deps()).get("/health")
    assert response.status_code == 200
    assert response.json() == {"status": "ok", "upstream": OK}


def test_route_reports_real_voxtral_probe_but_stays_ok(
    serve: Callable[[HealthDependencies], TestClient],
) -> None:
    body = serve(World(voxtral=False).deps()).get("/health").json()
    assert body["upstream"]["voxtral"] == "down"
    assert body["status"] == "ok"


def test_route_voxtral_down_plus_ollama_down_is_degraded(
    serve: Callable[[HealthDependencies], TestClient],
) -> None:
    world = World(voxtral=False, http={URLS["ollama"]: 500})
    body = serve(world.deps()).get("/health").json()
    assert body["status"] == "degraded"
    assert body["upstream"]["voxtral"] == "down"
    assert body["upstream"]["ollama"] == "down"


def test_route_postgres_down_is_down(
    serve: Callable[[HealthDependencies], TestClient],
) -> None:
    world = World(postgres=ConnectionError("no pool"))
    assert serve(world.deps()).get("/health").json()["status"] == "down"


def test_route_is_not_bearer_gated(
    serve: Callable[[HealthDependencies], TestClient],
) -> None:
    assert serve(World().deps()).get("/health").status_code == 200


def test_route_reports_skipped_fixture_and_not_bootstrapped(
    serve: Callable[[HealthDependencies], TestClient],
) -> None:
    skipped = serve(World(env={}, fixture=True).deps()).get("/health").json()
    assert skipped["upstream"]["msgraph"] == "fixture"
    assert skipped["upstream"]["qdrant"] == "skipped"
    assert skipped["status"] == "ok"

    pending = serve(World(msgraph_account=False).deps()).get("/health").json()
    assert pending["upstream"]["msgraph"] == "not_bootstrapped"
    assert pending["status"] == "degraded"


# --- BAR-03: Blindfold entry, only when ANALYSIS_ROUTE=blindfold ----------


def test_default_route_has_no_blindfold_key_and_sends_nothing(
    serve: Callable[[HealthDependencies], TestClient],
) -> None:
    world = World()
    body = serve(world.deps()).get("/health").json()
    assert body["upstream"] == OK
    assert "blindfold" not in body["upstream"]
    assert body["status"] == "ok"
    assert not any(url.startswith(BLINDFOLD) for url in world.http_calls)


@pytest.mark.parametrize("status", [200, 401, 404, 499])
def test_routed_reachable_is_ok_including_404(
    serve: Callable[[HealthDependencies], TestClient], status: int
) -> None:
    world = World(route=blindfold_route(), http={f"{BLINDFOLD}/v1/models": status})
    body = serve(world.deps()).get("/health").json()
    assert body["upstream"]["blindfold"] == "ok"
    assert body["status"] == "ok"
    assert world.http_calls.count(f"{BLINDFOLD}/v1/models") == 1


@pytest.mark.parametrize("status", [500, 502, 503])
def test_routed_5xx_is_down_and_degraded(
    serve: Callable[[HealthDependencies], TestClient], status: int
) -> None:
    world = World(route=blindfold_route(), http={f"{BLINDFOLD}/v1/models": status})
    body = serve(world.deps()).get("/health").json()
    assert body["upstream"]["blindfold"] == "down"
    assert body["status"] == "degraded"


@pytest.mark.parametrize(
    "error",
    [httpx.ConnectError("refused"), httpx.ConnectTimeout("slow"), httpx.ReadTimeout("slow")],
)
def test_routed_unreachable_is_down_and_degraded(
    serve: Callable[[HealthDependencies], TestClient], error: Exception
) -> None:
    world = World(route=blindfold_route(), http={f"{BLINDFOLD}/v1/models": error})
    body = serve(world.deps()).get("/health").json()
    assert body["upstream"]["blindfold"] == "down"
    assert body["status"] == "degraded"


@pytest.mark.parametrize("essential", ["postgres", "whisper"])
@pytest.mark.parametrize("routed", [False, True])
def test_essential_down_is_down_routed_or_not(
    serve: Callable[[HealthDependencies], TestClient], essential: str, routed: bool
) -> None:
    http: dict[str, int | Exception] = {f"{BLINDFOLD}/v1/models": 503}
    postgres = None
    if essential == "postgres":
        postgres = ConnectionError("no pool")
    else:
        http[URLS["whisper"]] = 503
    world = World(
        route=blindfold_route() if routed else None, http=http, postgres=postgres, env=ENV
    )
    assert serve(world.deps()).get("/health").json()["status"] == "down"


def test_ollama_entry_is_unchanged_when_routed(
    serve: Callable[[HealthDependencies], TestClient],
) -> None:
    world = World(route=blindfold_route(), http={URLS["ollama"]: 500})
    body = serve(world.deps()).get("/health").json()
    assert body["upstream"]["ollama"] == "down"
    assert body["upstream"]["blindfold"] == "ok"
    assert body["status"] == "degraded"


# --- production wiring: the real `default_dependencies()` ------------------
#
# No dependency override here. The process environment, the analysis route,
# `httpx`, the Postgres pool and the MSAL client are faked beneath the seam, so
# a change to the wiring in `default_dependencies()` fails these tests.

EXPECTED_HTTP = sorted([*URLS.values(), "http://voxtral.test:8000/v1/models"])


@pytest.fixture
def wired() -> TestClient:
    # No `with`: the app's lifespan (Postgres etc.) is never started.
    assert health_checks.default_dependencies not in main.app.dependency_overrides
    return TestClient(main.app)


def test_wired_default_local_route(
    wired: TestClient, monkeypatch: pytest.MonkeyPatch
) -> None:
    upstreams = ProductionUpstreams(monkeypatch)
    body = wired.get("/health").json()
    assert body == {"status": "ok", "upstream": OK}
    assert "blindfold" not in body["upstream"]
    assert sorted(upstreams.urls) == EXPECTED_HTTP
    assert upstreams.queries == ["SELECT 1"]
    assert set(upstreams.timeouts) == {health_checks.PROBE_TIMEOUT}
    assert all("authorization" not in r.headers for r in upstreams.requests)


def test_wired_routed_blindfold_is_probed_without_the_key(
    wired: TestClient, monkeypatch: pytest.MonkeyPatch
) -> None:
    upstreams = ProductionUpstreams(monkeypatch, route=blindfold_route(key="sk-secret-key"))
    body = wired.get("/health").json()
    assert body == {"status": "ok", "upstream": {**OK, "blindfold": "ok"}}
    assert upstreams.urls[-1] == f"{BLINDFOLD}/v1/models"
    assert sorted(upstreams.urls[:-1]) == EXPECTED_HTTP
    assert all("authorization" not in r.headers for r in upstreams.requests)
    assert not any("sk-secret-key" in url for url in upstreams.urls)
    assert set(upstreams.timeouts) == {health_checks.PROBE_TIMEOUT}


@pytest.mark.parametrize("status", [404, 499])
def test_wired_routed_below_500_is_ok(
    wired: TestClient, monkeypatch: pytest.MonkeyPatch, status: int
) -> None:
    ProductionUpstreams(
        monkeypatch, route=blindfold_route(), http={f"{BLINDFOLD}/v1/models": status}
    )
    body = wired.get("/health").json()
    assert body["upstream"]["blindfold"] == "ok"
    assert body["status"] == "ok"


@pytest.mark.parametrize("answer", [503, httpx.ConnectError("refused"), httpx.ReadTimeout("slow")])
def test_wired_routed_blindfold_failure_is_degraded(
    wired: TestClient, monkeypatch: pytest.MonkeyPatch, answer: int | Exception
) -> None:
    ProductionUpstreams(
        monkeypatch, route=blindfold_route(), http={f"{BLINDFOLD}/v1/models": answer}
    )
    body = wired.get("/health").json()
    assert body["upstream"]["blindfold"] == "down"
    assert body["status"] == "degraded"


def test_wired_postgres_down_is_down(
    wired: TestClient, monkeypatch: pytest.MonkeyPatch
) -> None:
    ProductionUpstreams(monkeypatch, postgres=ConnectionError("no pool"))
    body = wired.get("/health").json()
    assert body["upstream"]["postgres"] == "down"
    assert body["status"] == "down"


def test_wired_whisper_down_is_down(
    wired: TestClient, monkeypatch: pytest.MonkeyPatch
) -> None:
    ProductionUpstreams(monkeypatch, http={URLS["whisper"]: 503})
    body = wired.get("/health").json()
    assert body["upstream"]["whisper"] == "down"
    assert body["status"] == "down"


def test_wired_voxtral_down_stays_ok(
    wired: TestClient, monkeypatch: pytest.MonkeyPatch
) -> None:
    ProductionUpstreams(monkeypatch, http={"http://voxtral.test:8000/v1/models": 503})
    body = wired.get("/health").json()
    assert body["upstream"]["voxtral"] == "down"
    assert body["status"] == "ok"


def test_wired_environment_decides_skipped_and_fixture(
    wired: TestClient, monkeypatch: pytest.MonkeyPatch
) -> None:
    upstreams = ProductionUpstreams(monkeypatch, env={}, fixture=True)
    body = wired.get("/health").json()
    assert body["upstream"] == {
        "postgres": "ok",
        "qdrant": "skipped",
        "whisper": "skipped",
        "lightrag": "skipped",
        "ollama": "skipped",
        "msgraph": "fixture",
        "voxtral": "skipped",
    }
    assert body["status"] == "ok"
    assert upstreams.requests == []


def test_wired_graph_not_bootstrapped_is_degraded(
    wired: TestClient, monkeypatch: pytest.MonkeyPatch
) -> None:
    ProductionUpstreams(monkeypatch, msgraph_account=False)
    body = wired.get("/health").json()
    assert body["upstream"]["msgraph"] == "not_bootstrapped"
    assert body["status"] == "degraded"
