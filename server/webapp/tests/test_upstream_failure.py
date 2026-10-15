"""Shared upstream failure contract (ADR 0002, SPEC §10.6.1): the exception
-> (code, upstream, status, retryable) table, the response shape, and the
raw-Ollama classification used at the narrative boundary."""

from __future__ import annotations

import asyncio

import httpx
import pytest
from fastapi import FastAPI
from fastapi.testclient import TestClient

import narrative
import upstream_failure
from asr_client import AsrEngineError, AsrTimeoutError, AsrUnavailableError
from enrichment import EnrichmentSummariserUnavailable
from lightrag_client import LightRAGEngineError, LightRAGTimeoutError, LightRAGUnavailableError
from msgraph_client import MSGraphError, MSGraphNotBootstrapped
from ollama_client import OllamaEngineError, OllamaTimeoutError, OllamaUnavailableError
from upstream_failure import UpstreamFailure
from voxtral_client import (
    TTSEngineError,
    TTSTimeoutError,
    TTSUnavailableError,
    TTSUnknownVoiceError,
)

# (exception, code, upstream, status, retryable) — the PRD / SPEC §10.6.1 catalogue.
CATALOGUE = [
    (AsrUnavailableError("down"), "whisper_unavailable", "whisper", 503, True),
    (AsrTimeoutError("slow"), "whisper_timeout", "whisper", 503, True),
    (AsrEngineError("500"), "whisper_engine_error", "whisper", 502, True),
    (OllamaUnavailableError("down"), "ollama_unavailable", "ollama", 503, True),
    (OllamaTimeoutError("slow"), "ollama_timeout", "ollama", 503, True),
    (OllamaEngineError("500", status_code=500), "ollama_engine_error", "ollama", 502, True),
    (LightRAGUnavailableError("down"), "lightrag_unavailable", "lightrag", 503, True),
    (LightRAGTimeoutError("slow"), "lightrag_timeout", "lightrag", 503, True),
    (LightRAGEngineError("500", status_code=500), "lightrag_engine_error", "lightrag", 502, True),
    (
        EnrichmentSummariserUnavailable("ollama_unreachable: refused"),
        "ollama_unavailable", "ollama", 503, True,
    ),
    (
        EnrichmentSummariserUnavailable("ollama_timeout: slow"),
        "ollama_timeout", "ollama", 503, True,
    ),
    (
        EnrichmentSummariserUnavailable("ollama_status_500"),
        "ollama_engine_error", "ollama", 502, True,
    ),
    (
        EnrichmentSummariserUnavailable("ollama_empty_response"),
        "ollama_engine_error", "ollama", 502, True,
    ),
    (MSGraphNotBootstrapped("run bootstrap"), "msgraph_not_bootstrapped", "msgraph", 503, False),
    (MSGraphError("rate_limited: backoff_exhausted"), "msgraph_rate_limited", "msgraph", 429, True),
    (MSGraphError("network_error: reset"), "msgraph_unavailable", "msgraph", 503, True),
    (MSGraphError("upstream_5xx: status=503"), "msgraph_engine_error", "msgraph", 502, True),
    (MSGraphError("graph_error: status=400"), "msgraph_engine_error", "msgraph", 502, True),
    (TTSUnavailableError("down"), "voxtral_unavailable", "voxtral", 503, True),
    (TTSTimeoutError("slow"), "voxtral_timeout", "voxtral", 503, True),
    (TTSEngineError("500"), "voxtral_engine_error", "voxtral", 502, True),
    (TTSUnknownVoiceError("nope"), "unknown_voice", "voxtral", 400, False),
]


@pytest.mark.parametrize(
    "exc, code, upstream, status_code, retryable",
    CATALOGUE,
    ids=[f"{type(c[0]).__name__}-{c[1]}" for c in CATALOGUE],
)
def test_every_client_exception_maps_to_its_documented_failure(
    exc, code, upstream, status_code, retryable
):
    failure = upstream_failure.failure_from_exception(exc)

    assert failure is not None
    assert (failure.code, failure.upstream, failure.status_code, failure.retryable) == (
        code, upstream, status_code, retryable,
    )
    assert failure.message == str(exc)


def test_unrelated_exceptions_do_not_map():
    assert upstream_failure.failure_from_exception(RuntimeError("disk full")) is None
    assert upstream_failure.failure_from_exception(httpx.ReadTimeout("slow")) is None
    assert upstream_failure.failure_fields(ValueError("x")) == {"code": None, "upstream": None}


def test_failure_fields_returns_code_and_upstream():
    assert upstream_failure.failure_fields(LightRAGTimeoutError("slow")) == {
        "code": "lightrag_timeout", "upstream": "lightrag",
    }


def test_str_of_failure_is_the_message_and_detail_adds_the_code():
    failure = upstream_failure.failure_from_exception(OllamaTimeoutError("no answer in 60s"))

    assert str(failure) == "no answer in 60s"
    assert failure.detail == "ollama_timeout: no answer in 60s"
    assert upstream_failure.whisper_unavailable().detail == "whisper_unavailable"


def _app_raising(failure: UpstreamFailure) -> TestClient:
    app = FastAPI()
    upstream_failure.install(app)

    @app.get("/boom")
    async def boom():
        raise failure

    return TestClient(app)


def test_response_body_keeps_string_detail_and_adds_code_upstream_retryable():
    resp = _app_raising(
        upstream_failure.failure_from_exception(AsrUnavailableError("connection refused"))
    ).get("/boom")

    assert resp.status_code == 503
    assert resp.json() == {
        "detail": "whisper_unavailable: connection refused",
        "code": "whisper_unavailable",
        "upstream": "whisper",
        "retryable": True,
    }
    assert "retry-after" not in resp.headers


def test_retry_after_header_is_present_only_when_a_wait_is_known():
    rate_limited = MSGraphError("rate_limited: backoff_exhausted")
    rate_limited.retry_after = 12.2  # exposed by the Graph client (UFH-02)
    resp = _app_raising(upstream_failure.failure_from_exception(rate_limited)).get("/boom")

    assert resp.status_code == 429
    assert resp.headers["retry-after"] == "13"
    assert resp.json()["code"] == "msgraph_rate_limited"

    unknown_wait = _app_raising(
        upstream_failure.failure_from_exception(MSGraphError("rate_limited: backoff_exhausted"))
    ).get("/boom")
    assert unknown_wait.status_code == 429
    assert "retry-after" not in unknown_wait.headers


def test_not_bootstrapped_is_not_retryable():
    resp = _app_raising(
        upstream_failure.failure_from_exception(MSGraphNotBootstrapped("run bootstrap"))
    ).get("/boom")

    assert resp.status_code == 503
    assert resp.json()["retryable"] is False


RAW_OLLAMA = [
    (httpx.ReadTimeout("read timed out"), "ollama_timeout", "ollama"),
    (RuntimeError("LLM analysis timed out after 600s"), "ollama_timeout", "ollama"),
    (httpx.ConnectError("refused"), "ollama_unavailable", "ollama"),
    (httpx.RemoteProtocolError("dropped"), "ollama_unavailable", "ollama"),
    (
        httpx.HTTPStatusError(
            "500", request=httpx.Request("POST", "http://x"), response=httpx.Response(500),
        ),
        "ollama_engine_error", "ollama",
    ),
]


@pytest.mark.parametrize("exc, code, upstream", RAW_OLLAMA, ids=[c[1] + "-" + type(c[0]).__name__ for c in RAW_OLLAMA])
def test_raw_ollama_errors_are_classified(exc, code, upstream):
    failure = upstream_failure.classify_raw_ollama_error(exc)

    assert (failure.code, failure.upstream) == (code, upstream)
    assert str(failure) == str(exc)


def test_unclassifiable_raw_error_gets_no_code():
    assert upstream_failure.classify_raw_ollama_error(RuntimeError("disk full")) is None
    assert upstream_failure.classify_raw_ollama_error(KeyError("normalized_text")) is None


def test_narrative_tags_raw_analysis_failures_and_keeps_the_message(monkeypatch):
    import document_processor

    async def no_context(*args, **kwargs):
        return ""

    async def timing_out(enriched, *, transport=None):
        raise RuntimeError("LLM analysis timed out after 600s")

    monkeypatch.setattr(document_processor, "query_lightrag_context", no_context)
    monkeypatch.setattr(document_processor, "query_lightrag_entity_history", no_context)
    monkeypatch.setattr(document_processor, "summarize_context", no_context)
    monkeypatch.setattr(document_processor, "build_enriched_context", lambda *a, **k: {})
    monkeypatch.setattr(document_processor, "analyze_transcript", timing_out)

    with pytest.raises(UpstreamFailure) as excinfo:
        asyncio.run(narrative.build_day_narrative("text", [], "2026-07-01"))

    assert excinfo.value.code == "ollama_timeout"
    assert str(excinfo.value) == "LLM analysis timed out after 600s"
