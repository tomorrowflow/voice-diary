"""UFH-03: `/health` overall status rules (SPEC §10.7).

`down` only for postgres/whisper; `degraded` for any other non-optional
upstream that is not `ok` (skipped/fixture ignored); voxtral is optional and
never changes the overall status.
"""

from __future__ import annotations

import asyncio

import httpx
import pytest
from fastapi.testclient import TestClient

import analysis_route
import main
from routers import health

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


@pytest.fixture
def client() -> TestClient:
    # No `with`: the app's lifespan (Postgres etc.) is never started.
    return TestClient(main.app)


def _stub_probes(monkeypatch: pytest.MonkeyPatch, results: dict[str, str]) -> None:
    for name, result in results.items():

        async def probe(result: str = result) -> str:
            return result

        monkeypatch.setattr(health, f"_probe_{name}", probe)


def test_route_reports_real_voxtral_probe_but_stays_ok(
    client: TestClient, monkeypatch: pytest.MonkeyPatch
) -> None:
    _stub_probes(monkeypatch, _with(voxtral="down"))
    response = client.get("/health")
    assert response.status_code == 200
    body = response.json()
    assert body["upstream"]["voxtral"] == "down"
    assert body["status"] == "ok"


def test_route_voxtral_down_plus_ollama_down_is_degraded(
    client: TestClient, monkeypatch: pytest.MonkeyPatch
) -> None:
    _stub_probes(monkeypatch, _with(voxtral="down", ollama="down"))
    body = client.get("/health").json()
    assert body["status"] == "degraded"
    assert body["upstream"]["voxtral"] == "down"
    assert body["upstream"]["ollama"] == "down"


def test_route_postgres_down_is_down(
    client: TestClient, monkeypatch: pytest.MonkeyPatch
) -> None:
    _stub_probes(monkeypatch, _with(postgres="down"))
    assert client.get("/health").json()["status"] == "down"


# --- BAR-03: Blindfold entry, only when ANALYSIS_ROUTE=blindfold ----------

BLINDFOLD = "http://blindfold.test:8080/proxy"


@pytest.fixture(autouse=True)
def _route_env(monkeypatch: pytest.MonkeyPatch) -> None:
    for name in (
        "ANALYSIS_ROUTE", "BLINDFOLD_BASE_URL", "BLINDFOLD_API_KEY",
        "BLINDFOLD_ANALYSIS_MODEL", "BLINDFOLD_ANALYSIS_TIMEOUT",
    ):
        monkeypatch.delenv(name, raising=False)
    monkeypatch.setattr(analysis_route, "_active", None)


def _route(monkeypatch: pytest.MonkeyPatch, *, routed: bool, key: str | None = None) -> None:
    env: dict[str, str] = {}
    if routed:
        env = {
            "ANALYSIS_ROUTE": "blindfold",
            "BLINDFOLD_BASE_URL": BLINDFOLD,
            "BLINDFOLD_ANALYSIS_MODEL": "frontier-1",
        }
        if key:
            env["BLINDFOLD_API_KEY"] = key
    monkeypatch.setattr(analysis_route, "_active", analysis_route.from_env(env))


class BlindfoldHost:
    """Stands in for the Blindfold host. Records every request and the timeout
    of every client built, and answers with `status` or raises `error` (an
    unreachable host)."""

    def __init__(
        self,
        monkeypatch: pytest.MonkeyPatch,
        *,
        status: int = 200,
        error: Exception | None = None,
    ) -> None:
        self.requests: list[httpx.Request] = []
        self.timeouts: list[object] = []
        self._status = status
        self._error = error
        transport = httpx.MockTransport(self._handle)
        real_client = httpx.AsyncClient
        host = self

        class Client(real_client):
            def __init__(self, *args, **kwargs):
                host.timeouts.append(kwargs.get("timeout"))
                kwargs["transport"] = transport
                super().__init__(*args, **kwargs)

        monkeypatch.setattr(httpx, "AsyncClient", Client)

    def _handle(self, request: httpx.Request) -> httpx.Response:
        self.requests.append(request)
        if self._error:
            raise self._error
        return httpx.Response(self._status)


def test_default_route_has_no_blindfold_key_and_sends_nothing(
    client: TestClient, monkeypatch: pytest.MonkeyPatch
) -> None:
    _route(monkeypatch, routed=False)
    host = BlindfoldHost(monkeypatch)
    _stub_probes(monkeypatch, OK)
    body = client.get("/health").json()
    assert body["upstream"] == OK
    assert "blindfold" not in body["upstream"]
    assert body["status"] == "ok"
    assert host.requests == []


@pytest.mark.parametrize("status", [200, 401, 404, 499])
def test_routed_reachable_is_ok_including_404(
    client: TestClient, monkeypatch: pytest.MonkeyPatch, status: int
) -> None:
    _route(monkeypatch, routed=True)
    host = BlindfoldHost(monkeypatch, status=status)
    _stub_probes(monkeypatch, OK)
    body = client.get("/health").json()
    assert body["upstream"]["blindfold"] == "ok"
    assert body["status"] == "ok"
    assert [(r.method, str(r.url)) for r in host.requests] == [
        ("GET", f"{BLINDFOLD}/v1/models")
    ]


@pytest.mark.parametrize("status", [500, 502, 503])
def test_routed_5xx_is_down_and_degraded(
    client: TestClient, monkeypatch: pytest.MonkeyPatch, status: int
) -> None:
    _route(monkeypatch, routed=True)
    BlindfoldHost(monkeypatch, status=status)
    _stub_probes(monkeypatch, OK)
    body = client.get("/health").json()
    assert body["upstream"]["blindfold"] == "down"
    assert body["status"] == "degraded"


@pytest.mark.parametrize(
    "error",
    [httpx.ConnectError("refused"), httpx.ConnectTimeout("slow"), httpx.ReadTimeout("slow")],
)
def test_routed_unreachable_is_down_and_degraded(
    client: TestClient, monkeypatch: pytest.MonkeyPatch, error: Exception
) -> None:
    _route(monkeypatch, routed=True)
    BlindfoldHost(monkeypatch, error=error)
    _stub_probes(monkeypatch, OK)
    body = client.get("/health").json()
    assert body["upstream"]["blindfold"] == "down"
    assert body["status"] == "degraded"


@pytest.mark.parametrize("essential", ["postgres", "whisper"])
@pytest.mark.parametrize("routed", [False, True])
def test_essential_down_is_down_routed_or_not(
    client: TestClient, monkeypatch: pytest.MonkeyPatch, essential: str, routed: bool
) -> None:
    _route(monkeypatch, routed=routed)
    BlindfoldHost(monkeypatch, status=503)
    _stub_probes(monkeypatch, _with(**{essential: "down"}))
    assert client.get("/health").json()["status"] == "down"


def test_blindfold_down_alone_is_degraded_never_down() -> None:
    assert health.overall_status(_with(blindfold="down")) == "degraded"
    assert health.overall_status(_with(blindfold="ok")) == "ok"


def test_ollama_entry_is_unchanged_when_routed(
    client: TestClient, monkeypatch: pytest.MonkeyPatch
) -> None:
    _route(monkeypatch, routed=True)
    BlindfoldHost(monkeypatch, status=200)
    _stub_probes(monkeypatch, _with(ollama="down"))
    body = client.get("/health").json()
    assert body["upstream"]["ollama"] == "down"
    assert body["upstream"]["blindfold"] == "ok"
    assert body["status"] == "degraded"


def test_probe_sends_no_api_key_and_uses_the_tight_probe_timeout(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    _route(monkeypatch, routed=True, key="sk-secret-key")
    host = BlindfoldHost(monkeypatch)
    assert asyncio.run(health._probe_blindfold()) == "ok"
    (request,) = host.requests
    assert "authorization" not in request.headers
    assert "sk-secret-key" not in str(request.url)
    assert host.timeouts == [health.PROBE_TIMEOUT]
    assert health.PROBE_TIMEOUT <= 5
