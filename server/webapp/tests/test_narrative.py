"""Tests for `narrative.build_day_narrative` / `narrative.sync_and_ingest` —
the one shared narrative stage both `main.py::process_document_stream` (HTMX
SSE) and `routers/sessions.py::_run_session_document_processor` (iOS
sessions) delegate to (SRV-A1/#50).

Fakes are injected at the ports (`NarrativePorts.lightrag_client` wired to
an `httpx.MockTransport`, `NarrativePorts.llm_transport` likewise) — no
monkeypatching of `document_processor` module globals. Run inside the
webapp container so deps match prod:

    docker compose run --rm webapp pytest tests/test_narrative.py
"""

from __future__ import annotations

import json

import httpx
import pytest

from lightrag_client import LightRAGClient
from narrative import NarrativePorts, build_day_narrative, sync_and_ingest

ENTITIES = [{"text": "Thomas", "type": "PERSON"}, {"text": "Voice Diary", "type": "PROJECT"}]

ANALYSIS_JSON = {
    "relationships": [], "projects": [], "decisions": [],
    "todos": [], "insights": [], "recurring_themes": [],
}


def _lightrag_client(handler) -> LightRAGClient:
    return LightRAGClient(
        base_url="http://lightrag.test", api_key="", transport=httpx.MockTransport(handler)
    )


def _llm_handler(*, summary_response: httpx.Response | Exception, analysis_response: httpx.Response | Exception):
    """Route on the presence of `response_format` (only `analyze_transcript`
    sets `json_mode=True`), so a single transport can give the summary call
    and the analysis call independent outcomes."""

    def handler(request: httpx.Request) -> httpx.Response:
        body = json.loads(request.read())
        outcome = analysis_response if body.get("response_format") else summary_response
        if isinstance(outcome, Exception):
            raise outcome
        return outcome

    return handler


def _ok_summary() -> httpx.Response:
    return httpx.Response(200, json={"choices": [{"message": {"content": "y" * 60}}]})


def _ok_analysis() -> httpx.Response:
    return httpx.Response(
        200, json={"choices": [{"message": {"content": json.dumps(ANALYSIS_JSON)}}]}
    )


def _recording_on_step():
    events: list[tuple[str, dict]] = []

    def on_step(event: str, data: dict) -> None:
        events.append((event, data))

    return on_step, events


# --- happy path -------------------------------------------------------


async def test_happy_path_returns_full_narrative_result():
    ports = NarrativePorts(
        lightrag_client=_lightrag_client(lambda r: httpx.Response(200, json={"response": "hist"})),
        llm_transport=httpx.MockTransport(_llm_handler(summary_response=_ok_summary(), analysis_response=_ok_analysis())),
    )

    result = await build_day_narrative(
        "Heute mit Thomas gesprochen.", ENTITIES, "2026-05-10", ports=ports
    )

    assert result.context_summary == "y" * 60
    assert result.analysis == ANALYSIS_JSON
    assert "2026" in result.markdown
    assert result.metadata["date"] == "2026-05-10"


async def test_author_reaches_enriched_context_and_defaults_when_omitted():
    def ports():
        return NarrativePorts(
            lightrag_client=_lightrag_client(lambda r: httpx.Response(200, json={"response": "hist"})),
            llm_transport=httpx.MockTransport(_llm_handler(summary_response=_ok_summary(), analysis_response=_ok_analysis())),
        )

    explicit = await build_day_narrative("text", ENTITIES, "2026-05-10", author="Jane Doe", ports=ports())
    default = await build_day_narrative("text", ENTITIES, "2026-05-10", ports=ports())

    assert explicit.enriched_context["diary_author"] == "Jane Doe"
    assert default.enriched_context["diary_author"] == "Florian Wolf"


async def test_happy_path_emits_sse_shaped_step_events_in_order():
    on_step, events = _recording_on_step()
    ports = NarrativePorts(
        lightrag_client=_lightrag_client(lambda r: httpx.Response(200, json={"response": "hist"})),
        llm_transport=httpx.MockTransport(_llm_handler(summary_response=_ok_summary(), analysis_response=_ok_analysis())),
    )

    await build_day_narrative("text", ENTITIES, "2026-05-10", ports=ports, on_step=on_step)

    step_events = [(e, d) for e, d in events if e == "step"]
    assert step_events == [
        ("step", {"step": "context", "state": "active"}),
        ("step", {"step": "context", "state": "done"}),
        ("step", {"step": "summary", "state": "active"}),
        ("step", {"step": "summary", "state": "done"}),
        ("step", {"step": "analysis", "state": "active"}),
        ("step", {"step": "analysis", "state": "done"}),
    ]
    assert ("summary", {"summary": "y" * 60}) in events
    assert ("analysis", {"analysis": ANALYSIS_JSON}) in events


# --- degrade policy -----------------------------------------------------


async def test_context_query_failure_degrades_to_empty_context():
    on_step, events = _recording_on_step()

    def failing_lightrag_handler(request: httpx.Request) -> httpx.Response:
        raise httpx.ConnectError("refused", request=request)

    ports = NarrativePorts(
        lightrag_client=_lightrag_client(failing_lightrag_handler),
        llm_transport=httpx.MockTransport(_llm_handler(summary_response=_ok_summary(), analysis_response=_ok_analysis())),
    )

    result = await build_day_narrative("text", ENTITIES, "2026-05-10", ports=ports, on_step=on_step)

    assert ("context", {"recent": "", "entities": ""}) in events
    # The rest of the pipeline still completes.
    assert result.analysis == ANALYSIS_JSON


async def test_summary_failure_degrades_to_fallback_text():
    on_step, events = _recording_on_step()
    ports = NarrativePorts(
        lightrag_client=_lightrag_client(lambda r: httpx.Response(200, json={"response": "hist"})),
        llm_transport=httpx.MockTransport(
            _llm_handler(summary_response=httpx.Response(500, json={"error": "boom"}), analysis_response=_ok_analysis())
        ),
    )

    result = await build_day_narrative("text", ENTITIES, "2026-05-10", ports=ports, on_step=on_step)

    assert result.context_summary == "Keine historischen Daten verfügbar."
    assert ("summary", {"summary": "Keine historischen Daten verfügbar."}) in events
    # The rest of the pipeline still completes — analysis isn't skipped.
    assert result.analysis == ANALYSIS_JSON


async def test_analysis_failure_raises_and_emits_error_events():
    on_step, events = _recording_on_step()
    ports = NarrativePorts(
        lightrag_client=_lightrag_client(lambda r: httpx.Response(200, json={"response": "hist"})),
        llm_transport=httpx.MockTransport(
            _llm_handler(summary_response=_ok_summary(), analysis_response=httpx.Response(500, json={"error": "boom"}))
        ),
    )

    with pytest.raises(Exception, match="500"):
        await build_day_narrative("text", ENTITIES, "2026-05-10", ports=ports, on_step=on_step)

    assert ("step", {"step": "analysis", "state": "error"}) in events
    error_logs = [d for e, d in events if e == "log" and d["level"] == "error" and "Analysis failed" in d["message"]]
    assert error_logs
    error_events = [d for e, d in events if e == "error"]
    assert error_events and "Analysis failed" in error_events[0]["message"]


# --- ingest step (T3: explicit skeleton sync + ingest) -------------------


async def test_sync_and_ingest_runs_skeleton_sync_before_posting_document(monkeypatch):
    import skeleton_sync

    calls: list[str] = []

    async def fake_sync_incremental(triggered_by: str):
        calls.append("sync")
        return skeleton_sync.SyncStats()

    monkeypatch.setattr(skeleton_sync, "sync_incremental", fake_sync_incremental)

    def handler(request: httpx.Request) -> httpx.Response:
        calls.append("ingest")
        return httpx.Response(200, json={"status": "ok"})

    result = await sync_and_ingest(
        "# markdown", {"date": "2026-05-10"}, lightrag_client=_lightrag_client(handler)
    )

    assert result == {"status": "ok"}
    assert calls == ["sync", "ingest"]


async def test_sync_and_ingest_swallows_skeleton_sync_failure_and_still_ingests(monkeypatch):
    import skeleton_sync

    async def failing_sync(triggered_by: str):
        raise RuntimeError("no db pool in this sandbox")

    monkeypatch.setattr(skeleton_sync, "sync_incremental", failing_sync)

    def handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(200, json={"status": "ok"})

    result = await sync_and_ingest(
        "# markdown", {"date": "2026-05-10"}, lightrag_client=_lightrag_client(handler)
    )

    assert result == {"status": "ok"}


async def test_sync_and_ingest_propagates_ingest_failure(monkeypatch):
    """The decided failure policy (#50): a LightRAG ingest failure must
    propagate, so the sessions caller never reaches `mark_document_ingested`
    and the already-saved rows stay unmarked and retryable. The caller-side
    bookkeeping is covered by
    `test_sessions.py::test_run_session_document_processor_leaves_documents_unmarked_on_ingest_failure`."""
    import skeleton_sync

    async def fake_sync_incremental(triggered_by: str):
        return skeleton_sync.SyncStats()

    monkeypatch.setattr(skeleton_sync, "sync_incremental", fake_sync_incremental)

    def failing_handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(500, json={"error": "lightrag unreachable"})

    with pytest.raises(Exception, match="500"):
        await sync_and_ingest(
            "# markdown", {"date": "2026-05-10"}, lightrag_client=_lightrag_client(failing_handler)
        )
