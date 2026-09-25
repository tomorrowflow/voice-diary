"""Async HTTP client for the LightRAG knowledge-graph service.

Wraps LightRAG's `/query`, `/documents/text`, and `/documents/delete_document`
endpoints. Owns the wire format, timeouts, retries, and error classification —
mirrors `voxtral_client.VoxtralClient` / `ollama_client.OllamaClient`, the
established deep-adapter template for external seams in this codebase.

Unlike Voxtral/Ollama, LightRAG's base URL and API key are editable at
runtime via the admin settings UI (`lightrag_url`/`lightrag_api_key` rows
in Postgres), so — unless overridden explicitly at construction, which
tests do — `resolve_base_url()`/`resolve_api_key()` read `db.get_setting`
fresh on every call, falling back to the `LIGHTRAG_URL`/`LIGHTRAG_API_KEY`
env vars when the DB isn't reachable.

Testability: the httpx transport is injectable via the constructor's
`transport` argument, so the pytest suite drives the client against a
`httpx.MockTransport` and never reaches a live LightRAG instance.
"""

from __future__ import annotations

import asyncio
import logging
import os

import httpx

logger = logging.getLogger(__name__)

DEFAULT_BASE_URL = "http://192.168.2.16:9621"
DEFAULT_API_KEY = ""


# --- typed errors ---------------------------------------------------------


class LightRAGError(Exception):
    """Base class for all LightRAG client failures."""


class LightRAGUnavailableError(LightRAGError):
    """LightRAG is unreachable — connection refused, DNS failure, server stopped,
    or the connection dropped mid-request."""


class LightRAGTimeoutError(LightRAGError):
    """LightRAG did not respond within the configured timeout."""


class LightRAGEngineError(LightRAGError):
    """LightRAG returned an HTTP error status past the retry budget (or a
    non-retryable 4xx), or its response body could not be parsed as JSON."""

    def __init__(self, message: str, *, status_code: int | None = None) -> None:
        super().__init__(message)
        self.status_code = status_code


# --- client -----------------------------------------------------------------


class LightRAGClient:
    """Pure async client. One instance per caller module, mirroring the
    `_ollama_client = OllamaClient(...)` module-level pattern used by
    `enrichment.py`, `llm_validator.py`, etc.
    """

    def __init__(
        self,
        *,
        base_url: str | None = None,
        api_key: str | None = None,
        retry_attempts: int = 3,
        retry_backoff_seconds: float = 1.0,
        transport: httpx.AsyncBaseTransport | None = None,
    ) -> None:
        self._base_url_override = base_url.rstrip("/") if base_url else None
        self._api_key_override = api_key
        self._retry_attempts = max(1, retry_attempts)
        self._retry_backoff = retry_backoff_seconds
        self._transport = transport

    # -- config resolution ---------------------------------------------------

    async def resolve_base_url(self) -> str:
        if self._base_url_override is not None:
            return self._base_url_override
        return (await _resolve_setting("lightrag_url", "LIGHTRAG_URL", DEFAULT_BASE_URL)).rstrip("/")

    async def resolve_api_key(self) -> str:
        if self._api_key_override is not None:
            return self._api_key_override
        return await _resolve_setting("lightrag_api_key", "LIGHTRAG_API_KEY", DEFAULT_API_KEY)

    # -- public surface ----------------------------------------------------

    async def query(
        self,
        query: str,
        *,
        mode: str = "mix",
        top_k: int = 5,
        timeout_seconds: float = 300.0,
    ) -> str:
        """Send a one-shot natural-language query to `/query`.

        No retry — callers that need resilience (the diary context lookups,
        the briefing router) already treat a failed query as "no context
        available" rather than something worth retrying.
        """
        url, headers = await self._url_and_headers("/query")
        payload = {"query": query, "mode": mode, "top_k": top_k}

        resp = await self._send_once("POST", url, json=payload, headers=headers, timeout_seconds=timeout_seconds)
        body = _parse_json(resp)
        if isinstance(body, dict):
            return (body.get("response") or "").strip()
        return ""

    async def insert_document(
        self,
        *,
        doc_id: str,
        text: str,
        file_source: str,
        metadata: dict | None = None,
        timeout_seconds: float = 120.0,
        retry_attempts: int | None = None,
    ) -> dict:
        """POST a document (diary entry or skeleton bone) to `/documents/text`.

        Retries on timeouts, transport errors, and 5xx with exponential
        backoff; 4xx is surfaced immediately since it won't recover.
        """
        url, headers = await self._url_and_headers("/documents/text")
        payload: dict[str, object] = {"id": doc_id, "file_source": file_source, "text": text}
        if metadata is not None:
            payload["metadata"] = metadata

        resp = await self._send_with_retry(
            "POST", url, json=payload, headers=headers,
            timeout_seconds=timeout_seconds, retry_attempts=retry_attempts,
        )
        return _parse_json(resp)

    async def delete_documents(
        self,
        doc_ids: list[str],
        *,
        timeout_seconds: float = 60.0,
        retry_attempts: int | None = None,
    ) -> dict:
        """DELETE documents by id via `/documents/delete_document`."""
        url, headers = await self._url_and_headers("/documents/delete_document")
        resp = await self._send_with_retry(
            "DELETE", url, json={"doc_ids": doc_ids}, headers=headers,
            timeout_seconds=timeout_seconds, retry_attempts=retry_attempts,
        )
        return _parse_json(resp)

    # -- internals ---------------------------------------------------------

    async def _url_and_headers(self, path: str) -> tuple[str, dict]:
        base = await self.resolve_base_url()
        api_key = await self.resolve_api_key()
        headers = {"X-API-Key": api_key} if api_key else {}
        return f"{base}{path}", headers

    def _make_client(self, timeout_seconds: float) -> httpx.AsyncClient:
        return httpx.AsyncClient(timeout=timeout_seconds, transport=self._transport)

    async def _send_once(
        self, method: str, url: str, *, json: dict, headers: dict, timeout_seconds: float,
    ) -> httpx.Response:
        try:
            async with self._make_client(timeout_seconds) as client:
                resp = await client.request(method, url, json=json, headers=headers)
        except httpx.TimeoutException as exc:
            raise LightRAGTimeoutError(str(exc)) from exc
        except httpx.NetworkError as exc:
            raise LightRAGUnavailableError(str(exc)) from exc
        except httpx.HTTPError as exc:
            raise LightRAGEngineError(f"transport error: {exc}") from exc

        if resp.status_code >= 400:
            raise LightRAGEngineError(
                f"lightrag {resp.status_code}: {_extract_error_detail(resp)}",
                status_code=resp.status_code,
            )
        return resp

    async def _send_with_retry(
        self,
        method: str,
        url: str,
        *,
        json: dict,
        headers: dict,
        timeout_seconds: float,
        retry_attempts: int | None,
    ) -> httpx.Response:
        max_attempts = self._retry_attempts if retry_attempts is None else max(1, retry_attempts)

        for attempt in range(1, max_attempts + 1):
            try:
                return await self._send_once(
                    method, url, json=json, headers=headers, timeout_seconds=timeout_seconds,
                )
            except LightRAGError as exc:
                if _is_client_error(exc) or attempt >= max_attempts:
                    raise
                logger.warning(
                    "LightRAG %s %s attempt %d/%d failed (%s) — retrying",
                    method, url, attempt, max_attempts, exc,
                )
            await asyncio.sleep(self._retry_backoff * (2 ** (attempt - 1)))

        raise AssertionError("unreachable: the final attempt always returns or raises")


# --- helpers ----------------------------------------------------------------


async def _resolve_setting(db_key: str, env_key: str, default: str) -> str:
    """Read `db_key` from Postgres settings, falling back to `env_key` (or
    `default`) when the DB isn't reachable — e.g. in unit tests, or if
    Postgres is down but LightRAG itself is still worth trying."""
    try:
        import db
        return await db.get_setting(db_key, os.getenv(env_key, default))
    except Exception:  # noqa: BLE001
        return os.getenv(env_key, default)


def _is_client_error(exc: LightRAGError) -> bool:
    """4xx is non-retryable — a bad payload or auth problem won't recover."""
    return isinstance(exc, LightRAGEngineError) and exc.status_code is not None and exc.status_code < 500


def _parse_json(resp: httpx.Response):
    try:
        return resp.json()
    except ValueError as exc:
        raise LightRAGEngineError(f"invalid JSON from lightrag: {exc}") from exc


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
