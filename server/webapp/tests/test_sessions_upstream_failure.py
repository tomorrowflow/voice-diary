"""Upstream failure contract on the session lifecycle (UFH-01, ADR 0002):
`code` / `upstream` on segment results. The Whisper preflight 503 and the
status route's `code` / `upstream` fields are covered in `test_sessions.py`."""

from __future__ import annotations

import asyncio

import httpx
from fastapi import FastAPI
from fastapi.testclient import TestClient

import db
import upstream_failure
from routers import sessions as sessions_router
from tests.session_helpers import (
    FakeSessionIngests,
    NarrativeStage,
    SegmentPipeline,
    auth,
    fake_document_processor_pipeline,
    fresh_ingest,
    manifest_dict,
    segment_row,
    stage_bundle,
    stage_pending_session,
    two_segment_manifest,
)


def _run_session(monkeypatch, tmp_path, session_id, *, failing=None, manifest=None):
    """The original ingest's background run for `session_id`'s bundle, with
    phase 1 stubbed; returns `(ingests, narrative stage)`."""
    processor = fresh_ingest(monkeypatch)
    manifest = manifest if manifest is not None else manifest_dict(session_id)
    parsed, session_dir = stage_bundle(monkeypatch, tmp_path, session_id, manifest)
    ingests = FakeSessionIngests(
        session_id, "processing", [segment_row(s["segment_id"], "pending_analysis") for s in manifest["segments"]],
    ).install()
    SegmentPipeline(monkeypatch, transcript_ids={"s01": 5, "s02": 6}, failing=failing)
    stage = NarrativeStage(monkeypatch)
    return processor, parsed, session_dir, ingests, stage


def _segments_after_analysis_failure(monkeypatch, tmp_path, session_id, exc):
    """One transcribed segment whose narrative stage raises `exc`; returns the
    persisted segment row."""
    processor, parsed, session_dir, ingests, stage = _run_session(monkeypatch, tmp_path, session_id)
    stage.analysis_error = exc

    asyncio.run(processor.process(parsed, session_dir))

    return ingests.row["segments"][0]


def test_run_records_code_on_a_segment_whose_whisper_call_fails_mid_run(monkeypatch, tmp_path):
    from asr_client import AsrTimeoutError

    session_id = "sess-ufh-whisper"
    processor, parsed, session_dir, ingests, _ = _run_session(
        monkeypatch, tmp_path, session_id,
        failing={"s02": AsrTimeoutError("whisper read timed out")},
        manifest=two_segment_manifest(session_id),
    )

    asyncio.run(processor.process(parsed, session_dir))

    assert ingests.row["segments"][1] == segment_row(
        "s02", "failed", error="whisper read timed out", code="whisper_timeout", upstream="whisper",
    )
    # The transcribed segment is untouched by the other's failure.
    assert ingests.row["segments"][0] == segment_row("s01", "processed", 5)


def test_run_records_code_when_ollama_fails_in_the_analysis_phase(monkeypatch, tmp_path):
    from ollama_client import OllamaUnavailableError

    row = _segments_after_analysis_failure(
        monkeypatch, tmp_path, "sess-ufh-ollama", OllamaUnavailableError("connection refused"),
    )

    assert row == segment_row(
        "s01", "pending_analysis", 5, "analysis_pending: connection refused",
        code="ollama_unavailable", upstream="ollama",
    )


def test_run_records_code_when_lightrag_fails_in_the_ingest_phase(monkeypatch, tmp_path):
    from lightrag_client import LightRAGTimeoutError

    row = _segments_after_analysis_failure(
        monkeypatch, tmp_path, "sess-ufh-lightrag", LightRAGTimeoutError("no answer in 300s"),
    )

    assert row["status"] == "pending_analysis"
    assert row["error"] == "analysis_pending: no answer in 300s"
    assert (row["code"], row["upstream"]) == ("lightrag_timeout", "lightrag")


def test_run_classifies_a_raw_httpx_timeout_from_the_analysis_path(monkeypatch, tmp_path):
    """The analysis call talks to Ollama with plain httpx; the real narrative
    stage must turn its raw timeout into `ollama_timeout`, error text intact."""
    import document_processor

    session_id = "sess-ufh-raw-timeout"
    processor = fresh_ingest(monkeypatch)
    parsed, session_dir = stage_bundle(monkeypatch, tmp_path, session_id)
    ingests = FakeSessionIngests(
        session_id, "processing", [segment_row("s01", "pending_analysis")]
    ).install()
    SegmentPipeline(monkeypatch, transcript_ids={"s01": 5})
    fake_document_processor_pipeline(monkeypatch)

    async def raw_timeout(enriched, *, transport=None):
        raise httpx.ReadTimeout("read timed out")

    async def save_doc(**kwargs):
        raise AssertionError("analysis failed; nothing must be saved")

    monkeypatch.setattr(document_processor, "analyze_transcript", raw_timeout)
    monkeypatch.setattr(db, "save_processed_document", save_doc)

    asyncio.run(processor.process(parsed, session_dir))

    assert ingests.row["segments"][0] == segment_row(
        "s01", "pending_analysis", 5, "analysis_pending: read timed out",
        code="ollama_timeout", upstream="ollama",
    )


def test_run_leaves_code_null_for_an_unclassifiable_error(monkeypatch, tmp_path):
    row = _segments_after_analysis_failure(
        monkeypatch, tmp_path, "sess-ufh-unknown", RuntimeError("disk full"),
    )

    assert row["error"] == "analysis_pending: disk full"
    assert row["code"] is None and row["upstream"] is None


def test_retry_analysis_route_returns_code_and_upstream_on_the_still_pending_segment(monkeypatch, tmp_path):
    from ollama_client import OllamaTimeoutError

    fresh_ingest(monkeypatch)
    ingests = stage_pending_session(monkeypatch, tmp_path, "sess-ufh-retry")
    stage = NarrativeStage(monkeypatch)
    stage.analysis_error = OllamaTimeoutError("no answer in 600s")
    app = FastAPI()
    upstream_failure.install(app)
    app.include_router(sessions_router.router)
    client = TestClient(app)

    resp = client.post("/api/sessions/sess-ufh-retry/retry-analysis", headers=auth())

    assert resp.status_code == 200
    expected = segment_row(
        "s01", "pending_analysis", 5, "analysis_pending: no answer in 600s",
        code="ollama_timeout", upstream="ollama",
    )
    assert resp.json()["segments"] == [expected]
    assert ingests.updates == [(resp.json()["state"], [expected])]
    # The status route returns them too.
    status_resp = client.get("/api/sessions/sess-ufh-retry/status", headers=auth())
    assert status_resp.json()["segments"] == [expected]
