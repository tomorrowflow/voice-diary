"""UFH-03: `/health` overall status rules (SPEC §10.7).

`down` only for postgres/whisper; `degraded` for any other non-optional
upstream that is not `ok` (skipped/fixture ignored); voxtral is optional and
never changes the overall status.
"""

from __future__ import annotations

import pytest
from fastapi.testclient import TestClient

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
