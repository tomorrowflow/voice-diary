"""Shared upstream failure contract (ADR 0002, SPEC §10.6.1).

One exception type, `UpstreamFailure`, and one exception handler render every
upstream failure the same way: the string `detail` (`"<code>"` or
`"<code>: <message>"`, so installed apps keep working) plus top-level `code`,
`upstream` and `retryable`, and a `Retry-After` header only where a wait is
known.

`raise_as_failure` is how a route puts a client call on the contract.
`failure_from_exception` maps each upstream client's exception classes to an
`UpstreamFailure`; `classify_raw_analysis_error` does the same for the plain
`httpx` / `RuntimeError` failures that escape `document_processor`'s analysis
path, as `ollama_*` on the local route and `blindfold_*` on the Blindfold route
(BAR-02, ADR 0004). `failure_fields` is what the sessions pipeline records on a
segment.
"""

from __future__ import annotations

import math
from collections.abc import Iterator
from contextlib import contextmanager
from typing import Literal

import httpx
from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse

from asr_client import AsrEngineError, AsrError, AsrTimeoutError, AsrUnavailableError
from document_processor import UnreadableLlmResponse
from enrichment import EnrichmentSummariserUnavailable
from lightrag_client import (
    LightRAGEngineError,
    LightRAGError,
    LightRAGTimeoutError,
    LightRAGUnavailableError,
)
from msgraph_client import MSGraphError, MSGraphNotBootstrapped
from ollama_client import (
    OllamaEngineError,
    OllamaError,
    OllamaTimeoutError,
    OllamaUnavailableError,
)
from voxtral_client import (
    TTSEngineError,
    TTSError,
    TTSTimeoutError,
    TTSUnavailableError,
    TTSUnknownVoiceError,
)

Upstream = Literal["whisper", "ollama", "lightrag", "msgraph", "voxtral", "blindfold"]

# (code, upstream, status, retryable) — the catalogue in the PRD / SPEC §10.6.1.
_DOWN = 503
_ERROR = 502


class UpstreamFailure(Exception):
    """An upstream is down, slow or answered with an error.

    `str(exc)` is the human message only, so callers that format
    `f"analysis_pending: {exc}"` keep the text they had before the contract.
    """

    def __init__(
        self,
        *,
        code: str,
        upstream: Upstream,
        status_code: int,
        retryable: bool,
        message: str = "",
        retry_after: float | None = None,
    ) -> None:
        super().__init__(message)
        self.code = code
        self.upstream = upstream
        self.status_code = status_code
        self.retryable = retryable
        self.message = message
        self.retry_after = retry_after

    @property
    def detail(self) -> str:
        return f"{self.code}: {self.message}" if self.message else self.code


def whisper_unavailable(message: str = "") -> UpstreamFailure:
    return UpstreamFailure(
        code="whisper_unavailable", upstream="whisper", status_code=_DOWN,
        retryable=True, message=message,
    )


async def upstream_failure_handler(_request: Request, exc: UpstreamFailure) -> JSONResponse:
    headers = {}
    if exc.retry_after is not None:
        headers["Retry-After"] = str(max(1, math.ceil(exc.retry_after)))
    return JSONResponse(
        status_code=exc.status_code,
        content={
            "detail": exc.detail,
            "code": exc.code,
            "upstream": exc.upstream,
            "retryable": exc.retryable,
        },
        headers=headers or None,
    )


def install(app: FastAPI) -> None:
    """Register the exception handler on `app`."""
    app.add_exception_handler(UpstreamFailure, upstream_failure_handler)


def _make(
    code: str, upstream: Upstream, status_code: int, exc: Exception,
    *, retryable: bool = True, retry_after: float | None = None,
) -> UpstreamFailure:
    return UpstreamFailure(
        code=code, upstream=upstream, status_code=status_code,
        retryable=retryable, message=str(exc), retry_after=retry_after,
    )


def _msgraph_failure(exc: MSGraphError) -> UpstreamFailure:
    # The client reports the kind as the message prefix (`rate_limited: …`,
    # `network_error: …`, `upstream_5xx: …`, `graph_error: …`).
    kind = str(exc).split(":", 1)[0].strip()
    if kind == "rate_limited":
        retry_after = getattr(exc, "retry_after", None)
        return _make("msgraph_rate_limited", "msgraph", 429, exc, retry_after=retry_after)
    if kind == "network_error":
        return _make("msgraph_unavailable", "msgraph", _DOWN, exc)
    return _make("msgraph_engine_error", "msgraph", _ERROR, exc)


def failure_from_exception(exc: BaseException) -> UpstreamFailure | None:
    """Map an upstream client exception to its `UpstreamFailure`, or None
    when `exc` is not one of the clients' typed failures."""
    if isinstance(exc, UpstreamFailure):
        return exc
    if isinstance(exc, AsrError):
        if isinstance(exc, AsrUnavailableError):
            return _make("whisper_unavailable", "whisper", _DOWN, exc)
        if isinstance(exc, AsrTimeoutError):
            return _make("whisper_timeout", "whisper", _DOWN, exc)
        if isinstance(exc, AsrEngineError):
            return _make("whisper_engine_error", "whisper", _ERROR, exc)
        return None
    if isinstance(exc, OllamaError):
        if isinstance(exc, OllamaUnavailableError):
            return _make("ollama_unavailable", "ollama", _DOWN, exc)
        if isinstance(exc, OllamaTimeoutError):
            return _make("ollama_timeout", "ollama", _DOWN, exc)
        if isinstance(exc, OllamaEngineError):
            return _make("ollama_engine_error", "ollama", _ERROR, exc)
        return None
    if isinstance(exc, LightRAGError):
        if isinstance(exc, LightRAGUnavailableError):
            return _make("lightrag_unavailable", "lightrag", _DOWN, exc)
        if isinstance(exc, LightRAGTimeoutError):
            return _make("lightrag_timeout", "lightrag", _DOWN, exc)
        if isinstance(exc, LightRAGEngineError):
            return _make("lightrag_engine_error", "lightrag", _ERROR, exc)
        return None
    if isinstance(exc, EnrichmentSummariserUnavailable):
        # The summariser folds three Ollama reasons into one exception; its
        # message prefix (`ollama_unreachable|ollama_timeout|…`) says which.
        reason = str(exc)
        if reason.startswith("ollama_timeout"):
            return _make("ollama_timeout", "ollama", _DOWN, exc)
        if reason.startswith("ollama_unreachable"):
            return _make("ollama_unavailable", "ollama", _DOWN, exc)
        return _make("ollama_engine_error", "ollama", _ERROR, exc)
    if isinstance(exc, MSGraphNotBootstrapped):
        return _make(
            "msgraph_not_bootstrapped", "msgraph", _DOWN, exc, retryable=False,
        )
    if isinstance(exc, MSGraphError):
        return _msgraph_failure(exc)
    if isinstance(exc, TTSError):
        if isinstance(exc, TTSUnknownVoiceError):
            return _make("unknown_voice", "voxtral", 400, exc, retryable=False)
        if isinstance(exc, TTSUnavailableError):
            return _make("voxtral_unavailable", "voxtral", _DOWN, exc)
        if isinstance(exc, TTSTimeoutError):
            return _make("voxtral_timeout", "voxtral", _DOWN, exc)
        if isinstance(exc, TTSEngineError):
            return _make("voxtral_engine_error", "voxtral", _ERROR, exc)
        return None
    return None


@contextmanager
def raise_as_failure() -> Iterator[None]:
    """Re-raise any upstream client exception raised inside the block as its
    `UpstreamFailure`, so the route answers in the shared shape. Anything that
    is not a typed upstream failure propagates unchanged."""
    try:
        yield
    except Exception as exc:
        failure = failure_from_exception(exc)
        if failure is None or failure is exc:
            raise
        raise failure from exc


def classify_raw_analysis_error(
    exc: BaseException, upstream: Literal["ollama", "blindfold"] = "ollama",
) -> UpstreamFailure | None:
    """Classify what `document_processor`'s analysis call raises: it talks to
    `upstream` (the analysis route's destination) with plain `httpx` and
    signals a timeout with a bare `RuntimeError`. Only call this at that
    boundary — outside it a `httpx` error says nothing about which upstream
    failed. Unclassifiable errors return None.

    On the Blindfold route an unreadable response body is an engine error too,
    and a 401 / 403 says the key was rejected; the message never carries the
    response body or the key."""
    typed = failure_from_exception(exc)
    if typed is not None:
        return typed
    blindfold = upstream == "blindfold"
    if isinstance(exc, httpx.TimeoutException) or (
        isinstance(exc, RuntimeError) and str(exc).startswith("LLM analysis timed out")
    ):
        return _make(f"{upstream}_timeout", upstream, _DOWN, exc)
    if isinstance(exc, httpx.HTTPStatusError):
        if blindfold:
            status = exc.response.status_code
            if status in (401, 403):
                message = f"Blindfold rejected the API key (HTTP {status})"
            else:
                message = f"Blindfold answered with HTTP {status}"
            return _make("blindfold_engine_error", "blindfold", _ERROR, RuntimeError(message))
        return _make("ollama_engine_error", "ollama", _ERROR, exc)
    if isinstance(exc, httpx.TransportError):
        return _make(f"{upstream}_unavailable", upstream, _DOWN, exc)
    if blindfold and isinstance(exc, UnreadableLlmResponse):
        return _make("blindfold_engine_error", "blindfold", _ERROR, exc)
    return None


def failure_fields(exc: BaseException) -> dict[str, str | None]:
    """`code` / `upstream` to record on a segment result; both None when the
    error is not an upstream failure."""
    failure = failure_from_exception(exc)
    if failure is None:
        return {"code": None, "upstream": None}
    return {"code": failure.code, "upstream": failure.upstream}
