"""`/today/calendar` and `/calendar/event/{id}` on the upstream failure contract
(UFH-02): every Graph failure mode is coded, none becomes a bare 500."""

from __future__ import annotations

import pytest

import routers.calendar as calendar_router
from tests.route_helpers import (
    GRAPH_SCENARIOS,
    assert_failure,
    auth,
    client_for,
    graph_client,
    serve_graph,
)

ROUTES = [
    ("/today/calendar", {"date": "2026-10-15"}),
    ("/calendar/event/AAMk-event-1", {}),
]


@pytest.mark.parametrize("path, params", ROUTES)
@pytest.mark.parametrize(
    "kwargs, code, status, retryable, retry_after",
    [scenario[1:] for scenario in GRAPH_SCENARIOS],
    ids=[scenario[0] for scenario in GRAPH_SCENARIOS],
)
def test_graph_failure_is_reported_with_its_own_code(
    monkeypatch, tmp_path, path, params, kwargs, code, status, retryable, retry_after
):
    serve_graph(monkeypatch, calendar_router, graph_client(monkeypatch, tmp_path, **kwargs))

    resp = client_for(calendar_router.router, monkeypatch).get(path, params=params, headers=auth())

    assert_failure(resp, code=code, upstream="msgraph", status=status, retryable=retryable)
    assert resp.headers.get("retry-after") == retry_after


def test_invalid_date_keeps_its_plain_400(monkeypatch):
    resp = client_for(calendar_router.router, monkeypatch).get(
        "/today/calendar", params={"date": "not-a-date"}, headers=auth()
    )

    assert resp.status_code == 400
    assert resp.json()["detail"].startswith("invalid_date")
    assert "code" not in resp.json()
