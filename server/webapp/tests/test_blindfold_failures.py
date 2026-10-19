"""Blindfold failures keep their own codes and leave the session pending
(BAR-02, SPEC §10.5 / §10.6.1, ADR 0004).

Same injected-transport approach as `test_analysis_route.py`: the real
narrative stage makes the analysis call through an `httpx` transport that
raises or answers the failure under test, and fails any host it does not
expect. A routed failure must not trigger a second analysis request anywhere.
"""

from __future__ import annotations

import asyncio

import httpx
import pytest
from fastapi import FastAPI
from fastapi.testclient import TestClient

import upstream_failure
from tests.session_helpers import fresh_processor, stub_transcripts
from tests.test_analysis_route import (  # noqa: F401  (autouse fixture)
    ROUTED_ENV,
    LlmTransport,
    _clean_route_env,
    _ingest_session,
    _review_events,
    _route,
    _stub_lightrag,
    _stub_save,
)

CONNECT_ERROR = httpx.ConnectError("[Errno 111] Connection refused")
DNS_ERROR = httpx.ConnectError("[Errno -2] Name or service not known")

# (what the routed analysis call hits, code, HTTP status)
FAILURES = {
    "connection-refused": (CONNECT_ERROR, "blindfold_unavailable", 503),
    "dns-failure": (DNS_ERROR, "blindfold_unavailable", 503),
    "read-timeout": (httpx.ReadTimeout("read timed out"), "blindfold_timeout", 503),
    "http-500": (httpx.Response(500, text="boom"), "blindfold_engine_error", 502),
    "http-503": (httpx.Response(503, text="overloaded"), "blindfold_engine_error", 502),
    "http-429": (httpx.Response(429, text="slow down"), "blindfold_engine_error", 502),
    "http-401": (httpx.Response(401, text="bad key"), "blindfold_engine_error", 502),
    "http-403": (httpx.Response(403, text="forbidden"), "blindfold_engine_error", 502),
    "body-not-json": (httpx.Response(200, text="<html>gateway</html>"), "blindfold_engine_error", 502),
}


@pytest.fixture(params=FAILURES, ids=list(FAILURES))
def failure(request):
    return (request.param, *FAILURES[request.param])


def _routed_failed_ingest(monkeypatch, tmp_path, name, session_id):
    llm = LlmTransport(monkeypatch)
    llm.fail("blindfold.test", FAILURES[name][0])
    _route(monkeypatch, ROUTED_ENV)
    processor, ingests, stage = _ingest_session(monkeypatch, tmp_path, session_id)
    return llm, processor, ingests, stage


# --- The routed failure is classified and the session stays pending ---


def test_routed_failure_is_pending_with_the_blindfold_code(monkeypatch, tmp_path, failure):
    name, _, code, _ = failure

    llm, _, ingests, _ = _routed_failed_ingest(monkeypatch, tmp_path, name, f"sess-{name}")

    (segment,) = ingests.row["segments"]
    assert segment["status"] == "pending_analysis"
    assert segment["error"].startswith("analysis_pending: ")
    assert (segment["code"], segment["upstream"]) == (code, "blindfold")
    assert segment["transcript_id"] == 5
    assert ingests.row["state"] == "partial"
    assert llm.unexpected == []


def test_routed_failure_never_falls_back_to_ollama_or_any_other_host(monkeypatch, tmp_path, failure):
    name = failure[0]

    llm, _, _, _ = _routed_failed_ingest(monkeypatch, tmp_path, name, f"sess-nofb-{name}")

    assert [r.url.host for r in llm.analysis_requests()] == ["blindfold.test"]
    assert llm.to("ollama.test") == llm.summary_requests()
    assert llm.unexpected == []


def test_routed_failure_keeps_the_transcript_and_saves_no_document(monkeypatch, tmp_path, failure):
    name = failure[0]

    _, _, ingests, stage = _routed_failed_ingest(monkeypatch, tmp_path, name, f"sess-keep-{name}")

    assert ingests.row["segments"][0]["transcript_id"] == 5
    assert stage.documents == {}
    assert stage.ingested == []


def test_classified_failure_renders_in_the_shared_response_shape(failure):
    name, _, code, status_code = failure
    exc = FAILURES[name][0]
    if isinstance(exc, httpx.Response):
        exc = httpx.HTTPStatusError("x", request=httpx.Request("POST", "http://b"), response=exc)
    app = FastAPI()
    upstream_failure.install(app)

    @app.get("/boom")
    async def boom():
        raise upstream_failure.classify_raw_analysis_error(exc, "blindfold")

    resp = TestClient(app, raise_server_exceptions=False).get("/boom")

    assert resp.status_code == status_code
    body = resp.json()
    assert set(body) == {"detail", "code", "upstream", "retryable"}
    assert body["code"] == code
    assert body["upstream"] == "blindfold"
    assert body["retryable"] is True
    assert body["detail"].startswith(f"{code}: ")


@pytest.mark.parametrize("status", [401, 403])
def test_a_rejected_key_says_so_and_never_leaks_the_key(monkeypatch, tmp_path, status):
    llm = LlmTransport(monkeypatch)
    llm.fail("blindfold.test", httpx.Response(status, text="echo sk-secret"))
    _route(monkeypatch, {**ROUTED_ENV, "BLINDFOLD_API_KEY": "sk-secret"})

    _, ingests, _ = _ingest_session(monkeypatch, tmp_path, f"sess-key-{status}")

    (segment,) = ingests.row["segments"]
    assert segment["code"] == "blindfold_engine_error"
    assert "API key" in segment["error"]
    assert "sk-secret" not in segment["error"]


def test_a_blindfold_timeout_uses_the_routes_timeout_in_its_message(monkeypatch, tmp_path):
    llm = LlmTransport(monkeypatch)
    llm.fail("blindfold.test", httpx.ReadTimeout("read timed out"))
    _route(monkeypatch, {**ROUTED_ENV, "BLINDFOLD_ANALYSIS_TIMEOUT": "7"})

    _, ingests, _ = _ingest_session(monkeypatch, tmp_path, "sess-timeout-msg")

    assert ingests.row["segments"][0]["error"] == "analysis_pending: LLM analysis timed out after 7.0s"


# --- Retry and sweep recover under the route in force ---


def _pending_after_failure(monkeypatch, tmp_path, session_id, error=CONNECT_ERROR):
    llm = LlmTransport(monkeypatch)
    llm.fail("blindfold.test", error)
    _route(monkeypatch, ROUTED_ENV)
    processor, ingests, stage = _ingest_session(monkeypatch, tmp_path, session_id)
    stub_transcripts(monkeypatch, [5])
    assert ingests.row["segments"][0]["status"] == "pending_analysis"
    return llm, processor, ingests, stage


def test_retry_still_failing_keeps_the_session_pending_with_the_code(monkeypatch, tmp_path):
    llm, processor, ingests, _ = _pending_after_failure(monkeypatch, tmp_path, "sess-retry-fail")

    result = asyncio.run(processor.retry_analysis("sess-retry-fail"))

    assert result.state == "partial"
    (segment,) = result.segments
    assert (segment.status, segment.code, segment.upstream) == (
        "pending_analysis", "blindfold_unavailable", "blindfold",
    )
    assert segment.error.startswith("analysis_pending: ")
    assert [r.url.host for r in llm.analysis_requests()] == ["blindfold.test"] * 2
    assert llm.unexpected == []


def test_retry_recovers_once_blindfold_answers(monkeypatch, tmp_path):
    llm, processor, ingests, stage = _pending_after_failure(monkeypatch, tmp_path, "sess-retry-ok")
    llm.fail("blindfold.test", None)

    result = asyncio.run(processor.retry_analysis("sess-retry-ok"))

    assert result.state == "done"
    assert ingests.row["segments"][0]["status"] == "processed"
    assert [r.url.host for r in llm.analysis_requests()] == ["blindfold.test"] * 2
    assert 5 in stage.documents


def test_retry_under_the_local_route_produces_a_local_analysis(monkeypatch, tmp_path):
    llm, processor, ingests, stage = _pending_after_failure(monkeypatch, tmp_path, "sess-retry-local")
    _route(monkeypatch)

    result = asyncio.run(processor.retry_analysis("sess-retry-local"))

    assert result.state == "done"
    assert [r.url.host for r in llm.analysis_requests()] == ["blindfold.test", "ollama.test"]
    assert ingests.row["segments"][0]["status"] == "processed"
    assert 5 in stage.documents
    assert llm.unexpected == []


def test_startup_sweep_recovers_once_blindfold_answers(monkeypatch, tmp_path):
    llm, processor, ingests, _ = _pending_after_failure(monkeypatch, tmp_path, "sess-sweep-ok")
    llm.fail("blindfold.test", None)
    restarted = fresh_processor(monkeypatch)

    asyncio.run(restarted.retry_stuck_sessions_on_startup())

    assert ingests.row["segments"][0]["status"] == "processed"
    assert [r.url.host for r in llm.analysis_requests()] == ["blindfold.test"] * 2


def test_startup_sweep_under_the_local_route_produces_a_local_analysis(monkeypatch, tmp_path):
    llm, _, ingests, _ = _pending_after_failure(monkeypatch, tmp_path, "sess-sweep-local")
    _route(monkeypatch)
    restarted = fresh_processor(monkeypatch)

    asyncio.run(restarted.retry_stuck_sessions_on_startup())

    assert ingests.row["segments"][0]["status"] == "processed"
    assert [r.url.host for r in llm.analysis_requests()] == ["blindfold.test", "ollama.test"]


def test_startup_sweep_with_blindfold_still_down_leaves_it_pending(monkeypatch, tmp_path):
    llm, _, ingests, _ = _pending_after_failure(monkeypatch, tmp_path, "sess-sweep-down")
    restarted = fresh_processor(monkeypatch)

    asyncio.run(restarted.retry_stuck_sessions_on_startup())

    (segment,) = ingests.row["segments"]
    assert (segment["status"], segment["code"], segment["upstream"]) == (
        "pending_analysis", "blindfold_unavailable", "blindfold",
    )
    assert llm.to("ollama.test") == llm.summary_requests()


# --- Local codes are unchanged, and the default route cannot produce a blindfold code ---


LOCAL_FAILURES = {
    "connection-refused": (CONNECT_ERROR, "ollama_unavailable"),
    "read-timeout": (httpx.ReadTimeout("read timed out"), "ollama_timeout"),
    "http-500": (httpx.Response(500, text="boom"), "ollama_engine_error"),
}


@pytest.mark.parametrize("name", LOCAL_FAILURES)
def test_local_route_failures_keep_their_ollama_codes(monkeypatch, tmp_path, name):
    error, code = LOCAL_FAILURES[name]
    llm = LlmTransport(monkeypatch)
    llm.fail("ollama.test", error)
    _route(monkeypatch)

    _, ingests, _ = _ingest_session(monkeypatch, tmp_path, f"sess-local-{name}")

    (segment,) = ingests.row["segments"]
    assert segment["status"] == "pending_analysis"
    assert (segment["code"], segment["upstream"]) == (code, "ollama")
    assert llm.to("blindfold.test") == []


def test_local_route_unreadable_body_stays_unclassified(monkeypatch, tmp_path):
    llm = LlmTransport(monkeypatch)
    llm.fail("ollama.test", httpx.Response(200, text="<html>gateway</html>"))
    _route(monkeypatch)

    _, ingests, _ = _ingest_session(monkeypatch, tmp_path, "sess-local-body")

    (segment,) = ingests.row["segments"]
    assert segment["status"] == "pending_analysis"
    assert (segment["code"], segment["upstream"]) == (None, None)


@pytest.mark.parametrize("name", FAILURES)
def test_default_route_never_yields_a_blindfold_code(monkeypatch, tmp_path, name):
    error = FAILURES[name][0]
    llm = LlmTransport(monkeypatch)
    llm.fail("ollama.test", error)
    llm.fail("blindfold.test", error)
    _route(monkeypatch)

    _, ingests, _ = _ingest_session(monkeypatch, tmp_path, f"sess-default-{name}")

    (segment,) = ingests.row["segments"]
    assert segment["upstream"] != "blindfold"
    assert not (segment["code"] or "").startswith("blindfold_")
    assert llm.to("blindfold.test") == []


# --- HTMX review stream ---


def test_review_stream_routed_failure_ends_in_an_error_event_without_fallback(monkeypatch):
    llm = LlmTransport(monkeypatch)
    llm.fail("blindfold.test", httpx.ReadTimeout("read timed out"))
    _route(monkeypatch, ROUTED_ENV)
    _stub_lightrag(monkeypatch)
    _stub_save(monkeypatch)

    events = _review_events()

    assert events[-1]["event"] == "error"
    assert [r.url.host for r in llm.analysis_requests()] == ["blindfold.test"]
    assert llm.unexpected == []
