"""Async HTTP client for Ollama's `/api/chat` endpoint.

Every LLM-calling module (`llm_validator`, `fluency_checker`, `harvest_llm`,
`enrichment`, `transcript_corrector`, `document_processor`) used to open its
own `httpx.AsyncClient`, hand-build the `/api/chat` payload, and re-parse
Ollama's response and error shapes independently. `OllamaClient` is the one
place that owns the wire format, timeouts, and error classification, mirroring
`voxtral_client.VoxtralClient`.

Testability: the httpx transport is injectable via the constructor's
`transport` argument, so tests drive the client against a
`httpx.MockTransport` and never reach a live Ollama instance.
"""

from __future__ import annotations

import os
from dataclasses import dataclass

import httpx


# --- typed errors ---------------------------------------------------------


class OllamaError(Exception):
    """Base class for all Ollama client failures."""


class OllamaUnavailableError(OllamaError):
    """Ollama is unreachable — connection refused, DNS failure, server stopped."""


class OllamaTimeoutError(OllamaError):
    """Ollama did not respond within the configured timeout."""


class OllamaEngineError(OllamaError):
    """Ollama returned an HTTP error status, or its response body could not
    be parsed as JSON."""

    def __init__(self, message: str, *, status_code: int | None = None) -> None:
        super().__init__(message)
        self.status_code = status_code


# --- response shape --------------------------------------------------------


@dataclass(frozen=True)
class ChatResponse:
    """Extracted assistant text plus the raw decoded response body, so
    callers that need extra fields (e.g. token counts) can still get at them."""

    content: str
    raw: dict


# --- client ------------------------------------------------------------


class OllamaClient:
    """Pure async client. Holds no connection state, so a single
    module-level instance per caller is safe to share across requests.

    Construction reads `OLLAMA_BASE_URL`, `OLLAMA_MODEL`, and
    `OLLAMA_TIMEOUT` from the environment by default; tests override
    them explicitly.
    """

    def __init__(
        self,
        *,
        base_url: str | None = None,
        model: str | None = None,
        timeout_seconds: float | None = None,
        transport: httpx.AsyncBaseTransport | None = None,
    ) -> None:
        self._base_url = (base_url or os.getenv("OLLAMA_BASE_URL", "http://192.168.2.17:11434")).rstrip("/")
        self._model = model or os.getenv("OLLAMA_MODEL", "qwen2.5:14b")
        self._timeout = timeout_seconds if timeout_seconds is not None else float(
            os.getenv("OLLAMA_TIMEOUT", "120")
        )
        self._transport = transport

    @property
    def base_url(self) -> str:
        return self._base_url

    @property
    def model(self) -> str:
        return self._model

    # -- public surface ----------------------------------------------------

    async def chat(
        self,
        messages: list[dict],
        *,
        model: str | None = None,
        num_ctx: int | None = None,
        timeout: float | httpx.Timeout | None = None,
        format: str | None = None,
        temperature: float | None = None,
        options: dict | None = None,
    ) -> ChatResponse:
        """Send `messages` to `/api/chat` and return the assistant's reply.

        Raises `OllamaUnavailableError`, `OllamaTimeoutError`, or
        `OllamaEngineError` on failure so callers can branch on typed
        exceptions instead of catching raw `httpx` types.
        """
        merged_options: dict = dict(options or {})
        if num_ctx is not None:
            merged_options["num_ctx"] = num_ctx
        if temperature is not None:
            merged_options["temperature"] = temperature

        payload: dict[str, object] = {
            "model": model or self._model,
            "messages": messages,
            "stream": False,
        }
        if merged_options:
            payload["options"] = merged_options
        if format is not None:
            payload["format"] = format

        url = f"{self._base_url}/api/chat"
        effective_timeout = timeout if timeout is not None else self._timeout

        try:
            async with self._make_client(effective_timeout) as client:
                resp = await client.post(url, json=payload)
        except httpx.TimeoutException as exc:
            raise OllamaTimeoutError(str(exc)) from exc
        except httpx.ConnectError as exc:
            raise OllamaUnavailableError(str(exc)) from exc
        except httpx.HTTPError as exc:
            raise OllamaEngineError(f"transport error: {exc}") from exc

        if resp.status_code >= 400:
            raise OllamaEngineError(
                f"ollama {resp.status_code}: {_extract_error_detail(resp)}",
                status_code=resp.status_code,
            )

        try:
            body = resp.json()
        except ValueError as exc:
            raise OllamaEngineError(f"invalid JSON from ollama: {exc}") from exc

        return ChatResponse(content=_extract_content(body), raw=body)

    # -- internals ---------------------------------------------------------

    def _make_client(self, timeout: float | httpx.Timeout) -> httpx.AsyncClient:
        return httpx.AsyncClient(timeout=timeout, transport=self._transport)


# --- helpers --------------------------------------------------------------


def _extract_content(body: object) -> str:
    """Mirror the shape Ollama's `/api/chat` uses, with the `text` /
    `response` fallbacks some non-chat Ollama endpoints use."""
    if isinstance(body, dict):
        msg = body.get("message")
        if isinstance(msg, dict) and msg.get("content"):
            return msg["content"]
        if body.get("text"):
            return body["text"]
        if body.get("response"):
            return body["response"]
    return ""


def _extract_error_detail(resp: httpx.Response) -> str:
    try:
        body = resp.json()
    except ValueError:
        return resp.text[:300]
    if isinstance(body, dict):
        for key in ("detail", "error", "message"):
            value = body.get(key)
            if isinstance(value, str):
                return value
    return str(body)[:300]
