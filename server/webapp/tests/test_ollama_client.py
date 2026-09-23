"""Tests for `ollama_client.OllamaClient`.

Run inside the webapp container so deps + env match prod:

    docker compose run --rm webapp pytest tests/test_ollama_client.py

The httpx transport is injected via `httpx.MockTransport`, so no live
Ollama is needed.
"""

from __future__ import annotations

import httpx
import pytest

from ollama_client import (
    ChatResponse,
    OllamaClient,
    OllamaEngineError,
    OllamaTimeoutError,
    OllamaUnavailableError,
)


def _client(handler, **kwargs) -> OllamaClient:
    return OllamaClient(
        base_url="http://ollama.test",
        model="qwen2.5:14b",
        timeout_seconds=5.0,
        transport=httpx.MockTransport(handler),
        **kwargs,
    )


# --- happy path -----------------------------------------------------------


async def test_chat_returns_message_content_on_2xx() -> None:
    def handler(request: httpx.Request) -> httpx.Response:
        assert request.method == "POST"
        assert request.url.path == "/api/chat"
        return httpx.Response(200, json={"message": {"content": "hallo welt"}})

    client = _client(handler)
    result = await client.chat([{"role": "user", "content": "hi"}])

    assert isinstance(result, ChatResponse)
    assert result.content == "hallo welt"
    assert result.raw["message"]["content"] == "hallo welt"


async def test_chat_forwards_model_messages_format_and_options() -> None:
    captured: dict = {}

    def handler(request: httpx.Request) -> httpx.Response:
        import json

        captured["body"] = json.loads(request.read())
        return httpx.Response(200, json={"message": {"content": "ok"}})

    client = _client(handler)
    await client.chat(
        [{"role": "user", "content": "hi"}],
        model="qwen2.5:14b",
        num_ctx=131072,
        format="json",
    )

    body = captured["body"]
    assert body["model"] == "qwen2.5:14b"
    assert body["messages"] == [{"role": "user", "content": "hi"}]
    assert body["format"] == "json"
    assert body["stream"] is False
    assert body["options"]["num_ctx"] == 131072


async def test_chat_falls_back_to_response_key() -> None:
    def handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(200, json={"response": "fallback text"})

    client = _client(handler)
    result = await client.chat([{"role": "user", "content": "hi"}])
    assert result.content == "fallback text"


# --- error classification -------------------------------------------------


async def test_connect_error_maps_to_OllamaUnavailableError() -> None:
    def handler(request: httpx.Request) -> httpx.Response:
        raise httpx.ConnectError("Connection refused")

    client = _client(handler)
    with pytest.raises(OllamaUnavailableError):
        await client.chat([{"role": "user", "content": "hi"}])


async def test_timeout_maps_to_OllamaTimeoutError() -> None:
    def handler(request: httpx.Request) -> httpx.Response:
        raise httpx.ReadTimeout("slow upstream")

    client = _client(handler)
    with pytest.raises(OllamaTimeoutError):
        await client.chat([{"role": "user", "content": "hi"}])


async def test_5xx_maps_to_OllamaEngineError_with_status_code() -> None:
    def handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(503, json={"error": "model not loaded"})

    client = _client(handler)
    with pytest.raises(OllamaEngineError) as exc_info:
        await client.chat([{"role": "user", "content": "hi"}])
    assert exc_info.value.status_code == 503


async def test_4xx_maps_to_OllamaEngineError() -> None:
    def handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(400, json={"error": "bad request"})

    client = _client(handler)
    with pytest.raises(OllamaEngineError) as exc_info:
        await client.chat([{"role": "user", "content": "hi"}])
    assert exc_info.value.status_code == 400


async def test_invalid_json_body_maps_to_OllamaEngineError() -> None:
    def handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(200, content=b"not json")

    client = _client(handler)
    with pytest.raises(OllamaEngineError):
        await client.chat([{"role": "user", "content": "hi"}])


# --- construction -----------------------------------------------------------


async def test_chat_accepts_httpx_timeout_object_for_per_phase_timeouts() -> None:
    def handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(200, json={"message": {"content": "ok"}})

    client = _client(handler)
    per_phase = httpx.Timeout(connect=30.0, read=300.0, write=30.0, pool=30.0)
    result = await client.chat([{"role": "user", "content": "hi"}], timeout=per_phase)
    assert result.content == "ok"


def test_defaults_read_from_environment(monkeypatch) -> None:
    monkeypatch.setenv("OLLAMA_BASE_URL", "http://envhost:11434")
    monkeypatch.setenv("OLLAMA_MODEL", "llama3:8b")
    monkeypatch.setenv("OLLAMA_TIMEOUT", "42")

    client = OllamaClient()

    assert client.base_url == "http://envhost:11434"
    assert client.model == "llama3:8b"
