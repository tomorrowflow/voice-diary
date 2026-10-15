"""`/lightrag/query` and `/yesterday/open-todos` on the upstream failure
contract (UFH-02): LightRAG and the Ollama summariser each fail with their own
code, and a timeout is no longer folded into "unavailable"."""

from __future__ import annotations

import pytest

import enrichment
import routers.lightrag as lightrag_router
from lightrag_client import LightRAGEngineError, LightRAGTimeoutError, LightRAGUnavailableError
from ollama_client import OllamaEngineError, OllamaTimeoutError, OllamaUnavailableError
from tests.route_helpers import assert_failure, auth, client_for, raising

ROUTES = [
    ("post", "/lightrag/query", {"json": {"query": "was lief gestern?"}}),
    ("get", "/yesterday/open-todos", {}),
]


def _call(monkeypatch, method: str, path: str, kwargs: dict):
    client = client_for(lightrag_router.router, monkeypatch)
    return getattr(client, method)(path, headers=auth(), **kwargs)


async def _lightrag_answer(*_args, **_kwargs) -> str:
    return "- Board-Deck — Status: Offen"


@pytest.mark.parametrize("method, path, kwargs", ROUTES)
@pytest.mark.parametrize(
    "exc, code, status",
    [
        (LightRAGUnavailableError("connection refused"), "lightrag_unavailable", 503),
        (LightRAGTimeoutError("no answer in 120s"), "lightrag_timeout", 503),
        (LightRAGEngineError("lightrag 500: boom", status_code=500), "lightrag_engine_error", 502),
        (LightRAGEngineError("lightrag: bad json"), "lightrag_engine_error", 502),
    ],
)
def test_lightrag_failure_is_reported_with_its_own_code(
    monkeypatch, method, path, kwargs, exc, code, status
):
    monkeypatch.setattr(lightrag_router._lightrag_client, "query", raising(exc))

    resp = _call(monkeypatch, method, path, kwargs)

    assert_failure(resp, code=code, upstream="lightrag", status=status, retryable=True)
    assert "retry-after" not in resp.headers


@pytest.mark.parametrize("method, path, kwargs", ROUTES)
@pytest.mark.parametrize(
    "exc, code, status",
    [
        (OllamaUnavailableError("connection refused"), "ollama_unavailable", 503),
        (OllamaTimeoutError("no answer in 60s"), "ollama_timeout", 503),
        (OllamaEngineError("ollama 500", status_code=500), "ollama_engine_error", 502),
        (OllamaEngineError("bad json"), "ollama_engine_error", 502),
    ],
)
def test_summariser_failure_is_split_by_reason(monkeypatch, method, path, kwargs, exc, code, status):
    monkeypatch.setattr(lightrag_router._lightrag_client, "query", _lightrag_answer)
    monkeypatch.setattr(enrichment._ollama_client, "chat", raising(exc))

    resp = _call(monkeypatch, method, path, kwargs)

    assert_failure(resp, code=code, upstream="ollama", status=status, retryable=True)


@pytest.mark.parametrize("method, path, kwargs", ROUTES)
def test_empty_summariser_answer_is_an_ollama_engine_error(monkeypatch, method, path, kwargs):
    class _Empty:
        content = "   "

    async def empty_chat(*_args, **_kwargs):
        return _Empty()

    monkeypatch.setattr(lightrag_router._lightrag_client, "query", _lightrag_answer)
    monkeypatch.setattr(enrichment._ollama_client, "chat", empty_chat)

    resp = _call(monkeypatch, method, path, kwargs)

    assert_failure(resp, code="ollama_engine_error", upstream="ollama", status=502, retryable=True)


def test_success_is_unchanged(monkeypatch):
    async def summary(**_kwargs) -> str:
        return "Ein offener Punkt."

    monkeypatch.setattr(lightrag_router._lightrag_client, "query", _lightrag_answer)
    monkeypatch.setattr(lightrag_router, "summarise_for_speech", summary)

    resp = _call(monkeypatch, "get", "/yesterday/open-todos", {})

    assert resp.status_code == 200
    assert resp.json()["summary"] == "Ein offener Punkt."
    assert resp.json()["items"][0]["status"] == "Offen"
