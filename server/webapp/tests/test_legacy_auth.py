"""SEC-2: legacy HTMX/admin/data routes in `main.py` must require the same
bearer token as the iOS-facing routers.

`docs/REVIEW-2026-07-04.md` §3 SEC-2 — `routers/__init__.py` used to claim
these routes "stay open on the Docker network", but they share the same
published port as the bearer-gated iOS routers, so anyone reaching the
port could read transcripts or run destructive admin ops.

No live Postgres/Qdrant/Ollama in this environment: `TestClient(main.app)`
used without the `with` context manager never runs the app's lifespan, so
these tests never touch a real database.
"""

from __future__ import annotations

from collections.abc import Iterator

import pytest
from fastapi import APIRouter
from fastapi.routing import APIRoute
from fastapi.testclient import TestClient
from starlette.routing import Mount, Route

import db
import main
from routers.auth import require_bearer

client = TestClient(main.app)

BEARER_TOKEN = "test-bearer-token"

# A representative sample of the routes the finding calls out by name,
# spanning the review UI, the data API, and the admin API.
UNAUTHENTICATED_CASES = [
    ("GET", "/"),
    ("GET", "/review/1"),
    ("GET", "/api/dictionary"),
    ("POST", "/api/transcripts/delete"),
    ("POST", "/api/data/clear-dictionary"),
    ("DELETE", "/api/admin/persons/1"),
    ("POST", "/api/ingest/clear-history"),
]


@pytest.fixture(autouse=True)
def _bearer_token(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("IOS_BEARER_TOKEN", BEARER_TOKEN)


@pytest.mark.parametrize("method,path", UNAUTHENTICATED_CASES)
def test_legacy_route_rejects_missing_bearer(method: str, path: str) -> None:
    response = client.request(method, path)
    assert response.status_code == 401


@pytest.mark.parametrize("method,path", UNAUTHENTICATED_CASES)
def test_legacy_route_rejects_wrong_bearer(method: str, path: str) -> None:
    response = client.request(
        method, path, headers={"Authorization": "Bearer wrong-token"}
    )
    assert response.status_code == 401


def test_legacy_route_fails_closed_when_token_not_configured(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.delenv("IOS_BEARER_TOKEN", raising=False)
    response = client.get(
        "/api/dictionary", headers={"Authorization": f"Bearer {BEARER_TOKEN}"}
    )
    assert response.status_code == 503


def test_legacy_route_accepts_correct_bearer(monkeypatch: pytest.MonkeyPatch) -> None:
    async def fake_persons() -> list[dict]:
        return []

    async def fake_terms() -> list[dict]:
        return []

    monkeypatch.setattr(db, "load_person_dictionary", fake_persons)
    monkeypatch.setattr(db, "load_term_dictionary", fake_terms)

    response = client.get(
        "/api/dictionary", headers={"Authorization": f"Bearer {BEARER_TOKEN}"}
    )
    assert response.status_code == 200
    assert response.json() == {"persons": [], "terms": []}


def test_health_stays_open_without_bearer() -> None:
    response = client.get("/health")
    assert response.status_code != 401


def _api_routes(router: APIRouter | object) -> Iterator[APIRoute]:
    """Yield every APIRoute reachable from `router` or `app.routes`.

    `include_router` wraps each included router in a private `_IncludedRouter`
    that holds the original router in `original_router`, so recurse through
    that. Unknown route kinds raise instead of being skipped: a new route
    type must be classified here on purpose, never silently bypass the audit.
    """
    for route in getattr(router, "routes", []):  # type: ignore[attr-defined]
        if isinstance(route, APIRoute):
            yield route
        elif hasattr(route, "original_router"):
            yield from _api_routes(route.original_router)
        elif isinstance(route, (Mount, Route)):
            continue  # static files + FastAPI docs routes — no handlers of ours
        else:
            raise AssertionError(f"unclassified route kind: {type(route).__name__}")


def test_every_api_route_except_health_requires_bearer() -> None:
    """Completeness guard: the sample cases above pin named routes, this
    walks the whole route tree so a future route added without auth can't
    silently reopen the port (SEC-2 acceptance).
    """
    ungated = {
        route.path
        for route in _api_routes(main.app)
        if require_bearer not in [d.dependency for d in route.dependencies]
    }
    assert ungated == {"/health"}, f"routes without require_bearer: {sorted(ungated)}"
