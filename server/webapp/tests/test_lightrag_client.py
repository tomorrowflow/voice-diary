"""Tests for `lightrag_client.LightRAGClient`.

Run inside the webapp container so deps + env match prod:

    docker compose run --rm webapp pytest tests/test_lightrag_client.py

The httpx transport is injected via `httpx.MockTransport`, so no live
LightRAG instance is needed. Each test drives one branch of the client's
error classification or retry behaviour.
"""

from __future__ import annotations

import json

import httpx
import pytest

from lightrag_client import (
    LightRAGClient,
    LightRAGEngineError,
    LightRAGTimeoutError,
    LightRAGUnavailableError,
)


# --- helpers --------------------------------------------------------------


def _client(handler, **kwargs) -> LightRAGClient:
    """LightRAGClient wired to a `httpx.MockTransport` with explicit
    base_url/api_key overrides, so tests never touch the DB-settings path."""
    kwargs.setdefault("retry_backoff_seconds", 0.0)
    return LightRAGClient(
        base_url="http://lightrag.test",
        api_key="test-key",
        transport=httpx.MockTransport(handler),
        **kwargs,
    )


# --- query ------------------------------------------------------------------


async def test_query_returns_response_text_on_2xx() -> None:
    def handler(request: httpx.Request) -> httpx.Response:
        assert request.method == "POST"
        assert request.url.path == "/query"
        return httpx.Response(200, json={"response": "the answer"})

    client = _client(handler)

    result = await client.query("was ist los?", mode="mix", top_k=5)

    assert result == "the answer"


async def test_query_forwards_query_mode_top_k_and_api_key_header() -> None:
    captured: dict = {}

    def handler(request: httpx.Request) -> httpx.Response:
        captured["body"] = json.loads(request.read())
        captured["headers"] = request.headers
        return httpx.Response(200, json={"response": ""})

    client = _client(handler)
    await client.query("frage", mode="hybrid", top_k=15)

    assert captured["body"] == {"query": "frage", "mode": "hybrid", "top_k": 15}
    assert captured["headers"]["x-api-key"] == "test-key"


async def test_query_missing_response_key_returns_empty_string() -> None:
    def handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(200, json={})

    assert await _client(handler).query("x") == ""


async def test_query_connect_error_raises_unavailable() -> None:
    def handler(request: httpx.Request) -> httpx.Response:
        raise httpx.ConnectError("refused")

    with pytest.raises(LightRAGUnavailableError):
        await _client(handler).query("x")


async def test_query_dropped_connection_raises_unavailable() -> None:
    def handler(request: httpx.Request) -> httpx.Response:
        raise httpx.ReadError("connection reset")

    with pytest.raises(LightRAGUnavailableError):
        await _client(handler).query("x")


async def test_query_timeout_raises_timeout_error() -> None:
    def handler(request: httpx.Request) -> httpx.Response:
        raise httpx.ReadTimeout("slow")

    with pytest.raises(LightRAGTimeoutError):
        await _client(handler).query("x")


async def test_query_5xx_raises_engine_error_without_retry() -> None:
    calls: list[int] = []

    def handler(request: httpx.Request) -> httpx.Response:
        calls.append(1)
        return httpx.Response(500, json={"detail": "boom"})

    with pytest.raises(LightRAGEngineError):
        await _client(handler).query("x")
    assert len(calls) == 1  # query() never retries


async def test_query_4xx_raises_engine_error() -> None:
    def handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(400, json={"detail": "bad query"})

    with pytest.raises(LightRAGEngineError):
        await _client(handler).query("x")


# --- insert_document ---------------------------------------------------------


async def test_insert_document_posts_id_file_source_text() -> None:
    captured: dict = {}

    def handler(request: httpx.Request) -> httpx.Response:
        assert request.url.path == "/documents/text"
        captured["body"] = json.loads(request.read())
        return httpx.Response(200, json={"status": "ok"})

    client = _client(handler)
    result = await client.insert_document(doc_id="diary:2026-05-10", text="hi", file_source="diary-2026-05-10.md")

    assert result == {"status": "ok"}
    assert captured["body"] == {
        "id": "diary:2026-05-10",
        "file_source": "diary-2026-05-10.md",
        "text": "hi",
    }


async def test_insert_document_includes_metadata_when_given() -> None:
    captured: dict = {}

    def handler(request: httpx.Request) -> httpx.Response:
        captured["body"] = json.loads(request.read())
        return httpx.Response(200, json={"status": "ok"})

    client = _client(handler)
    await client.insert_document(
        doc_id="bone:person:thomas",
        text="Thomas ist CTO.",
        file_source="bone:person:thomas",
        metadata={"type": "skeleton", "category": "person"},
    )

    assert captured["body"]["metadata"] == {"type": "skeleton", "category": "person"}


async def test_insert_document_retries_5xx_then_succeeds() -> None:
    calls: list[int] = []

    def handler(request: httpx.Request) -> httpx.Response:
        calls.append(1)
        if len(calls) == 1:
            return httpx.Response(503, json={"detail": "transient"})
        return httpx.Response(200, json={"status": "ok"})

    client = _client(handler, retry_attempts=3)
    result = await client.insert_document(doc_id="x", text="y", file_source="z")

    assert len(calls) == 2
    assert result == {"status": "ok"}


async def test_insert_document_exhausts_retries_then_raises_engine_error() -> None:
    calls: list[int] = []

    def handler(request: httpx.Request) -> httpx.Response:
        calls.append(1)
        return httpx.Response(500, json={"detail": "still down"})

    client = _client(handler, retry_attempts=3)

    with pytest.raises(LightRAGEngineError):
        await client.insert_document(doc_id="x", text="y", file_source="z")
    assert len(calls) == 3


async def test_insert_document_4xx_not_retried() -> None:
    calls: list[int] = []

    def handler(request: httpx.Request) -> httpx.Response:
        calls.append(1)
        return httpx.Response(400, json={"detail": "bad payload"})

    client = _client(handler, retry_attempts=3)

    with pytest.raises(LightRAGEngineError):
        await client.insert_document(doc_id="x", text="y", file_source="z")
    assert len(calls) == 1


async def test_insert_document_invalid_json_raises_engine_error() -> None:
    def handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(200, text="not json")

    with pytest.raises(LightRAGEngineError):
        await _client(handler).insert_document(doc_id="x", text="y", file_source="z")


# --- delete_documents ---------------------------------------------------------


async def test_delete_documents_sends_doc_ids_as_delete() -> None:
    captured: dict = {}

    def handler(request: httpx.Request) -> httpx.Response:
        assert request.method == "DELETE"
        assert request.url.path == "/documents/delete_document"
        captured["body"] = json.loads(request.read())
        return httpx.Response(200, json={"status": "deleted"})

    client = _client(handler)
    result = await client.delete_documents(["bone:person:thomas", "bone:term:foo"])

    assert result == {"status": "deleted"}
    assert captured["body"] == {"doc_ids": ["bone:person:thomas", "bone:term:foo"]}


# --- base_url / api_key resolution ------------------------------------------


async def test_resolve_base_url_falls_back_to_env_when_db_unavailable(monkeypatch) -> None:
    monkeypatch.setenv("LIGHTRAG_URL", "http://from-env:9621")
    client = LightRAGClient(transport=httpx.MockTransport(lambda r: httpx.Response(200)))

    assert await client.resolve_base_url() == "http://from-env:9621"


async def test_resolve_base_url_prefers_db_setting(monkeypatch) -> None:
    import db

    async def fake_get_setting(key: str, default: str = "") -> str:
        assert key == "lightrag_url"
        return "http://from-db:9621"

    monkeypatch.setattr(db, "get_setting", fake_get_setting)
    client = LightRAGClient(transport=httpx.MockTransport(lambda r: httpx.Response(200)))

    assert await client.resolve_base_url() == "http://from-db:9621"


async def test_explicit_base_url_override_skips_db_lookup(monkeypatch) -> None:
    import db

    async def fail_get_setting(key: str, default: str = "") -> str:
        raise AssertionError("should not be called when base_url override is given")

    monkeypatch.setattr(db, "get_setting", fail_get_setting)
    client = LightRAGClient(
        base_url="http://override:9621",
        transport=httpx.MockTransport(lambda r: httpx.Response(200)),
    )

    assert await client.resolve_base_url() == "http://override:9621"
