"""`GET /email/search` on the upstream failure contract (UFH-02): Graph and the
Ollama summariser fail with their own codes."""

from __future__ import annotations

import pytest

import enrichment
import routers.email as email_router
from ollama_client import OllamaEngineError, OllamaTimeoutError, OllamaUnavailableError
from tests.route_helpers import (
    GRAPH_SCENARIOS,
    assert_failure,
    auth,
    client_for,
    graph_client,
    raising,
    serve_graph,
)


def _search(monkeypatch):
    return client_for(email_router.router, monkeypatch).get(
        "/email/search", params={"q": "budget"}, headers=auth()
    )


@pytest.mark.parametrize(
    "kwargs, code, status, retryable, retry_after",
    [scenario[1:] for scenario in GRAPH_SCENARIOS],
    ids=[scenario[0] for scenario in GRAPH_SCENARIOS],
)
def test_graph_failure_is_reported_with_its_own_code(
    monkeypatch, tmp_path, kwargs, code, status, retryable, retry_after
):
    serve_graph(monkeypatch, email_router, graph_client(monkeypatch, tmp_path, **kwargs))

    resp = _search(monkeypatch)

    assert_failure(resp, code=code, upstream="msgraph", status=status, retryable=retryable)
    assert resp.headers.get("retry-after") == retry_after


@pytest.mark.parametrize(
    "exc, code, status",
    [
        (OllamaUnavailableError("connection refused"), "ollama_unavailable", 503),
        (OllamaTimeoutError("no answer in 60s"), "ollama_timeout", 503),
        (OllamaEngineError("ollama 500", status_code=500), "ollama_engine_error", 502),
    ],
)
def test_summariser_failure_is_split_by_reason(monkeypatch, exc, code, status):
    class _Graph:
        async def get_json(self, *_args, **_kwargs) -> dict:
            return {"value": []}

    serve_graph(monkeypatch, email_router, _Graph())
    monkeypatch.setattr(enrichment._ollama_client, "chat", raising(exc))

    resp = _search(monkeypatch)

    assert_failure(resp, code=code, upstream="ollama", status=status, retryable=True)
