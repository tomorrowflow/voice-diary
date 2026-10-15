"""Upstream failure contract on the session routes (UFH-01, ADR 0002):
Whisper preflight, and `code` / `upstream` on segment results."""

from __future__ import annotations

import asyncio

import httpx

import db
import routers.sessions as sessions_router
from tests.test_sessions import (
    _FakeSessionIngests,
    _auth,
    _bundle,
    _client,
    _fake_document_processor_pipeline,
    _manifest,
    _segment_row,
    _setup,
    _stub_pending_session_for_retry,
    _two_segment_manifest,
)


def test_post_session_503s_with_whisper_unavailable_contract_and_persists_nothing(
    monkeypatch, tmp_path
):
    _setup(monkeypatch)
    monkeypatch.setenv("DATA_DIR", str(tmp_path))

    async def fake_whisper_unreachable() -> bool:
        return False

    created: list[str] = []

    async def fake_create_session_status(session_id, received_at, state, segments) -> None:
        created.append(session_id)

    deleted: list[str] = []

    async def fake_delete_session_status(session_id) -> None:
        deleted.append(session_id)

    monkeypatch.setattr(sessions_router, "_whisper_reachable", fake_whisper_unreachable)
    monkeypatch.setattr(db, "create_session_status", fake_create_session_status)
    monkeypatch.setattr(db, "delete_session_status", fake_delete_session_status)

    resp = _client().post("/api/sessions", files=_bundle("sess-ufh-pre"), headers=_auth())

    assert resp.status_code == 503
    assert resp.json() == {
        "detail": "whisper_unavailable",
        "code": "whisper_unavailable",
        "upstream": "whisper",
        "retryable": True,
    }
    assert "retry-after" not in resp.headers
    # Nothing persisted: the status row written for the claim is rolled back,
    # there is no cache entry, and no bundle is left on disk.
    assert created == deleted == ["sess-ufh-pre"]
    assert "sess-ufh-pre" not in sessions_router._session_status
    session_dir = sessions_router._sessions_data_dir() / sessions_router._slug_session_id("sess-ufh-pre")
    assert not session_dir.exists()


def test_process_session_records_code_on_a_segment_whose_whisper_call_fails_mid_run(
    monkeypatch, tmp_path
):
    from asr_client import AsrTimeoutError
    from models import Manifest

    _setup(monkeypatch)
    session_id = "sess-ufh-whisper"
    parsed = Manifest.model_validate(_two_segment_manifest(session_id))
    ingests = _FakeSessionIngests(
        session_id, "processing", [_segment_row("s01", "pending_analysis"), _segment_row("s02", "pending_analysis")]
    )
    ingests.install(monkeypatch)

    async def fake_process_segment(*, manifest, segment, session_dir):
        if segment.segment_id == "s02":
            raise AsrTimeoutError("whisper read timed out")
        return sessions_router._SegmentArtifact(
            segment=segment, transcript_id=11, raw_text="hallo", corrected_text="hallo",
        )

    async def fake_run_processor(*, manifest, artifacts, todos_by_segment):
        return None

    monkeypatch.setattr(sessions_router, "_process_segment", fake_process_segment)
    monkeypatch.setattr(sessions_router, "_run_session_document_processor", fake_run_processor)

    results = asyncio.run(sessions_router._process_session(parsed, tmp_path))

    assert results[1].model_dump() == {
        "segment_id": "s02", "status": "failed", "transcript_id": None,
        "error": "whisper read timed out", "code": "whisper_timeout", "upstream": "whisper",
    }
    assert ingests.updates[-1][1][1] == _segment_row(
        "s02", "failed", error="whisper read timed out", code="whisper_timeout", upstream="whisper",
    )
    # The transcribed segment is untouched by the other's failure.
    assert results[0].code is None and results[0].upstream is None


def _run_session_with_analysis_failure(monkeypatch, tmp_path, session_id, exc):
    """`_process_session` for one transcribed segment whose narrative stage
    raises `exc`; returns the (single) segment result."""
    from models import Manifest

    _setup(monkeypatch)
    parsed = Manifest.model_validate(_manifest(session_id))
    _FakeSessionIngests(session_id, "processing", [_segment_row("s01", "pending_analysis")]).install(
        monkeypatch
    )

    async def fake_process_segment(*, manifest, segment, session_dir):
        return sessions_router._SegmentArtifact(
            segment=segment, transcript_id=5, raw_text="hallo", corrected_text="hallo",
        )

    async def failing_run_processor(*, manifest, artifacts, todos_by_segment):
        raise exc

    monkeypatch.setattr(sessions_router, "_process_segment", fake_process_segment)
    monkeypatch.setattr(sessions_router, "_run_session_document_processor", failing_run_processor)

    return asyncio.run(sessions_router._process_session(parsed, tmp_path))[0]


def test_process_session_records_code_when_ollama_fails_in_the_analysis_phase(monkeypatch, tmp_path):
    from ollama_client import OllamaUnavailableError

    result = _run_session_with_analysis_failure(
        monkeypatch, tmp_path, "sess-ufh-ollama", OllamaUnavailableError("connection refused"),
    )

    assert result.model_dump() == {
        "segment_id": "s01", "status": "pending_analysis", "transcript_id": 5,
        "error": "analysis_pending: connection refused",
        "code": "ollama_unavailable", "upstream": "ollama",
    }


def test_process_session_records_code_when_lightrag_fails_in_the_ingest_phase(monkeypatch, tmp_path):
    from lightrag_client import LightRAGTimeoutError

    result = _run_session_with_analysis_failure(
        monkeypatch, tmp_path, "sess-ufh-lightrag", LightRAGTimeoutError("no answer in 300s"),
    )

    assert result.status == "pending_analysis"
    assert result.error == "analysis_pending: no answer in 300s"
    assert (result.code, result.upstream) == ("lightrag_timeout", "lightrag")


def test_process_session_classifies_a_raw_httpx_timeout_from_the_analysis_path(monkeypatch, tmp_path):
    """The analysis call talks to Ollama with plain httpx; the real narrative
    stage must turn its raw timeout into `ollama_timeout`, error text intact."""
    import document_processor
    from models import Manifest

    _setup(monkeypatch)
    _fake_document_processor_pipeline(monkeypatch)
    session_id = "sess-ufh-raw-timeout"
    parsed = Manifest.model_validate(_manifest(session_id))
    _FakeSessionIngests(session_id, "processing", [_segment_row("s01", "pending_analysis")]).install(
        monkeypatch
    )

    async def fake_process_segment(*, manifest, segment, session_dir):
        return sessions_router._SegmentArtifact(
            segment=segment, transcript_id=5, raw_text="hallo", corrected_text="hallo",
        )

    async def raw_timeout(enriched, *, transport=None):
        raise httpx.ReadTimeout("read timed out")

    async def save_doc(**kwargs):
        raise AssertionError("analysis failed; nothing must be saved")

    monkeypatch.setattr(sessions_router, "_process_segment", fake_process_segment)
    monkeypatch.setattr(document_processor, "analyze_transcript", raw_timeout)
    monkeypatch.setattr(db, "save_processed_document", save_doc)

    result = asyncio.run(sessions_router._process_session(parsed, tmp_path))[0]

    assert (result.status, result.code, result.upstream) == ("pending_analysis", "ollama_timeout", "ollama")
    assert result.error == "analysis_pending: read timed out"


def test_process_session_leaves_code_null_for_an_unclassifiable_error(monkeypatch, tmp_path):
    result = _run_session_with_analysis_failure(
        monkeypatch, tmp_path, "sess-ufh-unknown", RuntimeError("disk full"),
    )

    assert result.error == "analysis_pending: disk full"
    assert result.code is None and result.upstream is None


def test_retry_analysis_records_code_and_upstream_on_the_still_pending_segment(monkeypatch, tmp_path):
    from ollama_client import OllamaTimeoutError

    _setup(monkeypatch)
    session_id = "sess-ufh-retry"
    persisted_updates = _stub_pending_session_for_retry(monkeypatch, tmp_path, session_id)

    async def fake_get_latest_processed_document(transcript_id: int) -> dict | None:
        return None

    async def failing_run_processor(**kwargs):
        raise OllamaTimeoutError("no answer in 600s")

    monkeypatch.setattr(db, "get_latest_processed_document", fake_get_latest_processed_document)
    monkeypatch.setattr(sessions_router, "_run_session_document_processor", failing_run_processor)

    resp = _client().post(f"/api/sessions/{session_id}/retry-analysis", headers=_auth())

    assert resp.status_code == 200
    expected = {
        "segment_id": "s01", "status": "pending_analysis", "transcript_id": 5,
        "error": "analysis_pending: no answer in 600s",
        "code": "ollama_timeout", "upstream": "ollama",
    }
    assert resp.json()["segments"] == [expected]
    assert persisted_updates == [(session_id, resp.json()["state"], [expected])]
    # The status route returns them too.
    status_resp = _client().get(f"/api/sessions/{session_id}/status", headers=_auth())
    assert status_resp.json()["segments"] == [expected]


def test_status_reads_a_row_written_before_the_contract_with_null_code_and_upstream(monkeypatch):
    """Rows in `session_ingests.segments` written before UFH-01 lack the keys."""
    _setup(monkeypatch)

    async def fake_get_session_status(session_id: str) -> dict | None:
        return {
            "session_id": "sess-old",
            "received_at": "2026-07-01T10:00:00Z",
            "state": "partial",
            "segments": [
                {"segment_id": "s01", "status": "failed", "transcript_id": None, "error": "whisper exploded"},
                {
                    "segment_id": "s02", "status": "pending_analysis", "transcript_id": 3,
                    "error": "analysis_pending: ollama unreachable",
                },
            ],
        }

    monkeypatch.setattr(db, "get_session_status", fake_get_session_status)

    resp = _client().get("/api/sessions/sess-old/status", headers=_auth())

    assert resp.status_code == 200
    segments = resp.json()["segments"]
    assert [(s["code"], s["upstream"]) for s in segments] == [(None, None), (None, None)]
    assert segments[0]["error"] == "whisper exploded"


def test_status_returns_code_and_upstream_from_a_persisted_row(monkeypatch):
    _setup(monkeypatch)

    async def fake_get_session_status(session_id: str) -> dict | None:
        return {
            "session_id": "sess-new",
            "received_at": "2026-07-01T10:00:00Z",
            "state": "failed",
            "segments": [
                {
                    "segment_id": "s01", "status": "failed", "transcript_id": None,
                    "error": "whisper down", "code": "whisper_unavailable", "upstream": "whisper",
                },
            ],
        }

    monkeypatch.setattr(db, "get_session_status", fake_get_session_status)

    resp = _client().get("/api/sessions/sess-new/status", headers=_auth())

    assert resp.json()["segments"][0]["code"] == "whisper_unavailable"
    assert resp.json()["segments"][0]["upstream"] == "whisper"
