"""SRV-A5: ~30 shallow CRUD pass-through routes must live in dedicated
routers, not inflate `main.py` alongside the deep ingest/review logic.

`docs/REVIEW-2026-07-04.md` §2 SRV-A5 — persons/terms/variations/vector
routes belong in `routers/dictionary.py`; org-units/relationships/
role-assignments/static-entities/initiatives routes belong in
`routers/admin.py`. Purely mechanical: same paths, same behavior, same
`require_bearer` gating (SEC-2) — only the module changes.
"""

from __future__ import annotations

import pytest
from fastapi.routing import APIRoute

import main


def _route(method: str, path: str) -> APIRoute:
    for route in main.app.routes:
        candidate = route
        if hasattr(candidate, "original_router"):
            candidate = candidate.original_router
        for sub in getattr(candidate, "routes", [candidate]):
            if (
                isinstance(sub, APIRoute)
                and sub.path == path
                and method in sub.methods
            ):
                return sub
    raise AssertionError(f"no route for {method} {path}")


# The full set of shallow CRUD paths the finding calls out, split across
# the two target routers.
DICTIONARY_PATHS = [
    ("PUT", "/api/admin/persons/{person_id}"),
    ("DELETE", "/api/admin/persons/{person_id}"),
    ("POST", "/api/admin/persons"),
    ("POST", "/api/admin/persons/{person_id}/variations"),
    ("DELETE", "/api/admin/persons/{person_id}/variations/{variation_id}"),
    ("PUT", "/api/admin/terms/{term_id}"),
    ("DELETE", "/api/admin/terms/{term_id}"),
    ("POST", "/api/admin/terms"),
    ("POST", "/api/admin/terms/{term_id}/variations"),
    ("DELETE", "/api/admin/terms/{term_id}/variations/{variation_id}"),
    ("GET", "/api/admin/vector-status"),
    ("POST", "/api/admin/backfill-vectors"),
]

ADMIN_PATHS = [
    ("GET", "/api/admin/org-units"),
    ("POST", "/api/admin/org-units"),
    ("PUT", "/api/admin/org-units/{org_id}"),
    ("DELETE", "/api/admin/org-units/{org_id}"),
    ("GET", "/api/admin/relationships"),
    ("POST", "/api/admin/relationships"),
    ("DELETE", "/api/admin/relationships/{rel_id}"),
    ("GET", "/api/admin/role-assignments"),
    ("POST", "/api/admin/role-assignments"),
    ("PUT", "/api/admin/role-assignments/{ra_id}"),
    ("DELETE", "/api/admin/role-assignments/{ra_id}"),
    ("GET", "/api/admin/static-entities"),
    ("POST", "/api/admin/static-entities"),
    ("PUT", "/api/admin/static-entities/{entity_id}"),
    ("DELETE", "/api/admin/static-entities/{entity_id}"),
    ("GET", "/api/admin/initiatives"),
    ("POST", "/api/admin/initiatives"),
    ("PUT", "/api/admin/initiatives/{init_id}"),
    ("DELETE", "/api/admin/initiatives/{init_id}"),
]


@pytest.mark.parametrize("method,path", DICTIONARY_PATHS)
def test_dictionary_crud_route_out_of_main(method: str, path: str) -> None:
    route = _route(method, path)
    assert route.endpoint.__module__ == "routers.dictionary"


@pytest.mark.parametrize("method,path", ADMIN_PATHS)
def test_admin_crud_route_out_of_main(method: str, path: str) -> None:
    route = _route(method, path)
    assert route.endpoint.__module__ == "routers.admin"
