"""Opt-in analysis route (BAR-01, docs/prd/blindfold-analysis-routing.md).

Behaviour is checked at the HTTP boundary of the analysis call: an injected
`httpx` transport records every request the real narrative stage makes, and
fails any host it does not expect, so "default sends nothing to Blindfold" and
"routed sends the analysis to Blindfold alone" are enforced by the transport
itself. The drivers are the session ingest, `retry-analysis`, the startup
sweep and the HTMX review stream. No live Blindfold or cloud call.
"""

from __future__ import annotations

import asyncio
import json
import logging

import httpx
import pytest
from fastapi.testclient import TestClient

import analysis_route
import db
import document_processor
from analysis_route import AnalysisRouteError
from routers import review_stream
from tests.session_helpers import (
    FakeSessionIngests,
    NarrativeStage,
    SegmentPipeline,
    fresh_processor,
    manifest_dict,
    segment_row,
    stage_bundle,
    stage_pending_session,
)

OLLAMA = "http://ollama.test:11434"
BLINDFOLD = "http://blindfold.test:8080/proxy"
ROUTE_VARS = (
    "ANALYSIS_ROUTE", "BLINDFOLD_BASE_URL", "BLINDFOLD_API_KEY",
    "BLINDFOLD_ANALYSIS_MODEL", "BLINDFOLD_ANALYSIS_TIMEOUT",
)
ROUTED_ENV = {
    "ANALYSIS_ROUTE": "blindfold",
    "BLINDFOLD_BASE_URL": BLINDFOLD,
    "BLINDFOLD_ANALYSIS_MODEL": "frontier-1",
}
ANALYSIS_JSON = json.dumps({"relationships": [], "todos": [{"action": "x"}]})
SUMMARY_TEXT = "Kurzer Kontext der letzten Tage. " * 4


class LlmTransport:
    """Stands in for Ollama (`ollama.test`) and Blindfold (`blindfold.test`).
    Any other host, or a path other than `/v1/chat/completions`, is recorded
    in `unexpected` and answered 404; tests assert it stays empty."""

    def __init__(self, monkeypatch, *, ollama_status: int = 200, blindfold_status: int = 200):
        self.requests: list[httpx.Request] = []
        self.unexpected: list[httpx.Request] = []
        self._status = {"ollama.test": ollama_status, "blindfold.test": blindfold_status}
        # host -> an exception to raise, or a response to answer, for the
        # analysis call (`fail`); the context summary is never affected.
        self._analysis_failure: dict[str, Exception | httpx.Response] = {}
        transport = httpx.MockTransport(self._handle)
        real_client = httpx.AsyncClient

        class Client(real_client):
            def __init__(self, *args, **kwargs):
                if kwargs.get("transport") is None:
                    kwargs["transport"] = transport
                super().__init__(*args, **kwargs)

        monkeypatch.setattr(httpx, "AsyncClient", Client)
        monkeypatch.setattr(document_processor, "OLLAMA_BASE_URL", OLLAMA)
        monkeypatch.setattr(document_processor, "OLLAMA_ANALYSIS_MODEL", "local-model")

    def _handle(self, request: httpx.Request) -> httpx.Response:
        self.requests.append(request)
        host = request.url.host
        if host not in self._status or not request.url.path.endswith("/v1/chat/completions"):
            self.unexpected.append(request)
            return httpx.Response(404)
        if self._status[host] != 200:
            return httpx.Response(self._status[host], text="upstream error")
        is_analysis = "response_format" in json.loads(request.content)
        failure = self._analysis_failure.get(host)
        if is_analysis and failure is not None:
            if isinstance(failure, Exception):
                raise failure
            return failure
        content = ANALYSIS_JSON if is_analysis else SUMMARY_TEXT
        return httpx.Response(200, json={"choices": [{"message": {"content": content}}]})

    def fail(self, host: str, failure: Exception | httpx.Response | None) -> None:
        """Make `host`'s analysis call raise `failure` (a transport error) or
        answer it; `None` makes the host answer normally again."""
        if failure is None:
            self._analysis_failure.pop(host, None)
        else:
            self._analysis_failure[host] = failure

    def to(self, host: str) -> list[httpx.Request]:
        return [r for r in self.requests if r.url.host == host]

    def analysis_requests(self) -> list[httpx.Request]:
        return [r for r in self.requests if "response_format" in json.loads(r.content)]

    def summary_requests(self) -> list[httpx.Request]:
        return [r for r in self.requests if "response_format" not in json.loads(r.content)]


@pytest.fixture(autouse=True)
def _clean_route_env(monkeypatch):
    for name in ROUTE_VARS:
        monkeypatch.delenv(name, raising=False)
    monkeypatch.setattr(analysis_route, "_active", None)


def _route(monkeypatch, env: dict[str, str] | None = None) -> analysis_route.AnalysisRoute:
    """Make `env` the active route, as `configure()` would at start-up."""
    route = analysis_route.from_env(env or {})
    monkeypatch.setattr(analysis_route, "_active", route)
    return route


def _stub_lightrag(monkeypatch) -> None:
    async def no_context(*args, **kwargs):
        return ""

    monkeypatch.setattr(document_processor, "query_lightrag_context", no_context)
    monkeypatch.setattr(document_processor, "query_lightrag_entity_history", no_context)


def _ingest_session(monkeypatch, tmp_path, session_id: str):
    processor = fresh_processor(monkeypatch)
    manifest = manifest_dict(session_id)
    parsed, session_dir = stage_bundle(monkeypatch, tmp_path, session_id, manifest)
    ingests = FakeSessionIngests(
        session_id, "processing", [segment_row("s01", "pending_analysis")],
    ).install(monkeypatch)
    SegmentPipeline(monkeypatch, transcript_ids={"s01": 5})
    stage = NarrativeStage(monkeypatch, real_narrative=True)
    _stub_lightrag(monkeypatch)
    asyncio.run(processor.run_accepted(parsed, session_dir))
    return processor, ingests, stage


def _review_events(text: str = "raw text"):
    async def run():
        return [e async for e in review_stream._process_document_events(7, text, [], "2026-05-10")]

    return asyncio.run(run())


# --- Configuration validation ---


def test_unset_route_is_local():
    assert analysis_route.from_env({}) == analysis_route.AnalysisRoute(name="local")
    assert analysis_route.from_env({"ANALYSIS_ROUTE": ""}).is_blindfold is False
    assert analysis_route.from_env({"ANALYSIS_ROUTE": "local"}).is_blindfold is False


def test_local_route_ignores_blindfold_settings():
    route = analysis_route.from_env({"ANALYSIS_ROUTE": "local", "BLINDFOLD_BASE_URL": BLINDFOLD})
    assert route.is_blindfold is False
    assert route.blindfold_base_url is None


def test_unknown_route_value_names_the_variable():
    with pytest.raises(AnalysisRouteError, match="ANALYSIS_ROUTE"):
        analysis_route.from_env({"ANALYSIS_ROUTE": "cloud"})


@pytest.mark.parametrize("missing", ["BLINDFOLD_BASE_URL", "BLINDFOLD_ANALYSIS_MODEL"])
@pytest.mark.parametrize("empty", [False, True])
def test_blindfold_without_base_url_or_model_names_the_variable(missing, empty):
    env = {**ROUTED_ENV}
    if empty:
        env[missing] = "   "
    else:
        del env[missing]
    with pytest.raises(AnalysisRouteError, match=missing):
        analysis_route.from_env(env)


@pytest.mark.parametrize("value", ["soon", "0", "-5"])
def test_blindfold_timeout_must_be_a_positive_number(value):
    with pytest.raises(AnalysisRouteError, match="BLINDFOLD_ANALYSIS_TIMEOUT"):
        analysis_route.from_env({**ROUTED_ENV, "BLINDFOLD_ANALYSIS_TIMEOUT": value})


def test_valid_routed_config():
    route = analysis_route.from_env({
        **ROUTED_ENV, "BLINDFOLD_BASE_URL": BLINDFOLD + "/", "BLINDFOLD_API_KEY": "sk-secret",
        "BLINDFOLD_ANALYSIS_TIMEOUT": "42",
    })
    assert route.is_blindfold
    assert route.blindfold_base_url == BLINDFOLD
    assert route.blindfold_model == "frontier-1"
    assert route.blindfold_timeout == 42.0
    assert route.blindfold_api_key == "sk-secret"
    assert "sk-secret" not in repr(route)


def test_configure_routed_logs_one_warning_naming_url_and_model_never_the_key(monkeypatch, caplog):
    for name, value in {**ROUTED_ENV, "BLINDFOLD_API_KEY": "sk-secret"}.items():
        monkeypatch.setenv(name, value)

    with caplog.at_level(logging.DEBUG):
        route = analysis_route.configure()

    assert route.is_blindfold
    warnings = [r for r in caplog.records if r.levelno == logging.WARNING]
    assert len(warnings) == 1
    assert BLINDFOLD in warnings[0].getMessage()
    assert "frontier-1" in warnings[0].getMessage()
    assert "sk-secret" not in caplog.text


def test_configure_local_logs_nothing(caplog):
    with caplog.at_level(logging.DEBUG):
        route = analysis_route.configure()

    assert route.is_blindfold is False
    assert caplog.records == []


def test_configure_error_is_logged_and_never_falls_back_to_local(monkeypatch, caplog):
    monkeypatch.setenv("ANALYSIS_ROUTE", "blindfold")

    with caplog.at_level(logging.ERROR), pytest.raises(AnalysisRouteError, match="BLINDFOLD_BASE_URL"):
        analysis_route.configure()

    assert "Refusing to start" in caplog.text
    assert analysis_route._active is None


def test_app_refuses_to_start_on_an_unknown_route(monkeypatch):
    """Wired into main.py's lifespan, ahead of any database or Qdrant work."""
    import main

    monkeypatch.setenv("TAILNET_IP", "100.101.102.103")
    monkeypatch.setenv("ANALYSIS_ROUTE", "cloud")

    with pytest.raises(AnalysisRouteError, match="ANALYSIS_ROUTE"):
        with TestClient(main.app):
            pass


# --- Session ingest ---


def test_default_ingest_sends_the_analysis_to_ollama_and_never_to_blindfold(monkeypatch, tmp_path):
    llm = LlmTransport(monkeypatch)
    _route(monkeypatch)

    _, ingests, stage = _ingest_session(monkeypatch, tmp_path, "sess-default")

    assert ingests.row["segments"][0]["status"] == "processed"
    assert llm.unexpected == []
    assert llm.to("blindfold.test") == []
    assert len(llm.analysis_requests()) == 1
    assert llm.analysis_requests()[0].url == f"{OLLAMA}/v1/chat/completions"
    assert json.loads(llm.analysis_requests()[0].content)["model"] == "local-model"
    assert "authorization" not in llm.analysis_requests()[0].headers


def test_routed_ingest_sends_the_analysis_to_blindfold_alone(monkeypatch, tmp_path):
    llm = LlmTransport(monkeypatch)
    _route(monkeypatch, ROUTED_ENV)

    _, ingests, stage = _ingest_session(monkeypatch, tmp_path, "sess-routed")

    assert ingests.row["segments"][0]["status"] == "processed"
    assert llm.unexpected == []
    (analysis,) = llm.analysis_requests()
    assert analysis.url == f"{BLINDFOLD}/v1/chat/completions"
    body = json.loads(analysis.content)
    assert body["model"] == "frontier-1"
    assert body["response_format"] == {"type": "json_object"}
    assert body["stream"] is False
    assert "authorization" not in analysis.headers
    assert llm.to("blindfold.test") == [analysis]


def test_routed_ingest_sends_the_bearer_header_when_a_key_is_set(monkeypatch, tmp_path):
    llm = LlmTransport(monkeypatch)
    _route(monkeypatch, {**ROUTED_ENV, "BLINDFOLD_API_KEY": "sk-secret"})

    _ingest_session(monkeypatch, tmp_path, "sess-key")

    (analysis,) = llm.analysis_requests()
    assert analysis.headers["authorization"] == "Bearer sk-secret"
    # The key goes to Blindfold only.
    assert all("authorization" not in r.headers for r in llm.to("ollama.test"))


def test_routed_ingest_keeps_the_context_summary_on_ollama(monkeypatch, tmp_path):
    llm = LlmTransport(monkeypatch)
    _route(monkeypatch, {**ROUTED_ENV, "BLINDFOLD_API_KEY": "sk-secret"})

    _ingest_session(monkeypatch, tmp_path, "sess-summary")

    (summary,) = llm.summary_requests()
    assert summary.url == f"{OLLAMA}/v1/chat/completions"
    assert json.loads(summary.content)["model"] == "local-model"
    assert "authorization" not in summary.headers


def test_blindfold_timeout_defaults_to_the_local_analysis_timeout(monkeypatch):
    monkeypatch.setattr(document_processor, "OLLAMA_ANALYSIS_TIMEOUT", 111.0)

    _route(monkeypatch, ROUTED_ENV)
    assert document_processor._analysis_target().timeout == 111.0

    _route(monkeypatch, {**ROUTED_ENV, "BLINDFOLD_ANALYSIS_TIMEOUT": "7"})
    assert document_processor._analysis_target().timeout == 7.0
    assert document_processor._local_target().timeout == 111.0


# --- Retry and sweep read the route at run time ---


def test_retry_uses_the_route_in_force_when_it_runs(monkeypatch, tmp_path):
    llm = LlmTransport(monkeypatch)
    ingests = stage_pending_session(monkeypatch, tmp_path, "sess-retry")
    NarrativeStage(monkeypatch, real_narrative=True)
    _stub_lightrag(monkeypatch)
    processor = fresh_processor(monkeypatch)

    _route(monkeypatch)
    asyncio.run(processor.retry_analysis("sess-retry"))
    assert [r.url.host for r in llm.analysis_requests()] == ["ollama.test"]

    # The operator switches the route and restarts; the next retry follows it.
    ingests.row["state"] = "partial"
    ingests.row["segments"] = [segment_row("s01", "pending_analysis", 5, "analysis_pending: x")]
    processor._status.clear()
    _route(monkeypatch, ROUTED_ENV)
    asyncio.run(processor.retry_analysis("sess-retry"))

    assert [r.url.host for r in llm.analysis_requests()] == ["ollama.test", "blindfold.test"]
    assert llm.unexpected == []
    assert ingests.row["segments"][0]["status"] == "processed"


def test_startup_sweep_uses_the_route_in_force(monkeypatch, tmp_path):
    llm = LlmTransport(monkeypatch)
    ingests = stage_pending_session(monkeypatch, tmp_path, "sess-sweep")
    NarrativeStage(monkeypatch, real_narrative=True)
    _stub_lightrag(monkeypatch)
    processor = fresh_processor(monkeypatch)
    _route(monkeypatch, ROUTED_ENV)

    asyncio.run(processor.retry_stuck_sessions_on_startup())

    assert [r.url.host for r in llm.analysis_requests()] == ["blindfold.test"]
    assert [r.url.host for r in llm.summary_requests()] == ["ollama.test"]
    assert llm.unexpected == []
    assert ingests.row["segments"][0]["status"] == "processed"


def test_routed_failure_leaves_the_session_pending_and_never_tries_ollama(monkeypatch, tmp_path):
    llm = LlmTransport(monkeypatch, blindfold_status=503)
    _route(monkeypatch, ROUTED_ENV)

    _, ingests, _ = _ingest_session(monkeypatch, tmp_path, "sess-fail")

    assert ingests.row["segments"][0]["status"] == "pending_analysis"
    assert [r.url.host for r in llm.analysis_requests()] == ["blindfold.test"]


# --- HTMX review stream ---


def _stub_save(monkeypatch) -> None:
    async def save_processed_document(**kwargs):
        return {"id": 42, "version": 1}

    monkeypatch.setattr(db, "save_processed_document", save_processed_document)


def test_review_stream_default_analysis_goes_to_ollama(monkeypatch):
    llm = LlmTransport(monkeypatch)
    _route(monkeypatch)
    _stub_lightrag(monkeypatch)
    _stub_save(monkeypatch)

    events = _review_events()

    assert events[-1]["event"] == "done"
    assert [r.url.host for r in llm.analysis_requests()] == ["ollama.test"]
    assert llm.to("blindfold.test") == []
    assert llm.unexpected == []


def test_review_stream_routed_analysis_goes_to_blindfold(monkeypatch):
    llm = LlmTransport(monkeypatch)
    _route(monkeypatch, {**ROUTED_ENV, "BLINDFOLD_API_KEY": "sk-secret"})
    _stub_lightrag(monkeypatch)
    _stub_save(monkeypatch)

    events = _review_events()

    assert events[-1]["event"] == "done"
    (analysis,) = llm.analysis_requests()
    assert analysis.url == f"{BLINDFOLD}/v1/chat/completions"
    assert analysis.headers["authorization"] == "Bearer sk-secret"
    assert [r.url.host for r in llm.summary_requests()] == ["ollama.test"]
    assert llm.unexpected == []
