"""Route-level tests for `routers/sessions.py` (SRV-A6, ARCH-2): multipart
parsing, status codes and response bodies for the three ways a session gets
processed — original ingest (`POST /api/sessions`), manual retry
(`POST /api/sessions/{id}/retry-analysis`) and the startup sweep whose result
`GET /api/sessions/{id}/status` reports.

The lifecycle behind them is tested through its own interface in
`test_session_processing.py`; here it runs for real behind the routes, with
`db`, `transcript_ingest`, `correction` and `narrative` stubbed
(`session_helpers`).

Run inside the webapp container so deps + env match prod:

    docker compose run --rm webapp pytest webapp/tests/test_sessions.py

No live Postgres is needed.
"""

from __future__ import annotations

import asyncio
import json as jsonlib
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

import httpx
from fastapi import FastAPI
from fastapi.testclient import TestClient

import session_processing
import upstream_failure
from routers import sessions as sessions_router
from tests.session_helpers import (
    FakeSessionIngests,
    NarrativeStage,
    SegmentPipeline,
    auth,
    bundle,
    fresh_processor,
    segment_row,
    stage_bundle,
    stage_pending_session,
    stub_transcripts,
    two_segment_manifest,
)


def _app() -> FastAPI:
    app = FastAPI()
    upstream_failure.install(app)
    app.include_router(sessions_router.router)
    return app


def _client() -> TestClient:
    return TestClient(_app())


def _async_client() -> httpx.AsyncClient:
    """In-loop client, so several requests can be in flight at once (the
    sync `TestClient` serialises them)."""
    return httpx.AsyncClient(transport=httpx.ASGITransport(app=_app()), base_url="http://test")


def _ingest_stubs(monkeypatch, tmp_path, session_id: str, **pipeline):
    monkeypatch.setenv("DATA_DIR", str(tmp_path))
    ingests = FakeSessionIngests.empty(session_id).install()
    SegmentPipeline(monkeypatch, **pipeline)
    return ingests, NarrativeStage(monkeypatch)


# --- status ---------------------------------------------------------------


def test_status_falls_back_to_persisted_row_when_not_in_memory_cache(monkeypatch):
    """A restart clears the in-memory cache; the status endpoint must still
    return a previously-completed session's status from the db."""
    fresh_processor(monkeypatch)
    FakeSessionIngests("sess-1", "done", [segment_row("s01", "processed", 42)]).install()

    resp = _client().get("/api/sessions/sess-1/status", headers=auth())

    assert resp.status_code == 200
    body = resp.json()
    assert body["state"] == "done"
    assert body["segments"][0]["transcript_id"] == 42


def test_status_404s_when_neither_cache_nor_db_has_the_session(monkeypatch):
    fresh_processor(monkeypatch)
    FakeSessionIngests.empty("sess-1").install()

    resp = _client().get("/api/sessions/unknown/status", headers=auth())

    assert resp.status_code == 404
    assert resp.json()["detail"] == "session_not_found"


def test_status_reads_a_row_written_before_the_failure_contract_with_null_code_and_upstream(monkeypatch):
    """Rows in `session_ingests.segments` written before UFH-01 lack the keys."""
    fresh_processor(monkeypatch)
    FakeSessionIngests(
        "sess-old", "partial",
        [
            {"segment_id": "s01", "status": "failed", "transcript_id": None, "error": "whisper exploded"},
            {
                "segment_id": "s02", "status": "pending_analysis", "transcript_id": 3,
                "error": "analysis_pending: ollama unreachable",
            },
        ],
    ).install()

    resp = _client().get("/api/sessions/sess-old/status", headers=auth())

    assert resp.status_code == 200
    segments = resp.json()["segments"]
    assert [(s["code"], s["upstream"]) for s in segments] == [(None, None), (None, None)]
    assert segments[0]["error"] == "whisper exploded"


def test_status_returns_code_and_upstream_from_a_persisted_row(monkeypatch):
    fresh_processor(monkeypatch)
    FakeSessionIngests(
        "sess-new", "failed",
        [segment_row("s01", "failed", error="whisper down", code="whisper_unavailable", upstream="whisper")],
    ).install()

    resp = _client().get("/api/sessions/sess-new/status", headers=auth())

    assert resp.json()["segments"][0]["code"] == "whisper_unavailable"
    assert resp.json()["segments"][0]["upstream"] == "whisper"


# --- original ingest: POST /api/sessions ----------------------------------


def test_post_session_accepts_the_bundle_then_processes_it_in_the_background(monkeypatch, tmp_path):
    """The 200 carries the pending segments and a poll URL; the persisted
    status row is written before it; the background run then finishes the
    session, which the status route reports."""
    fresh_processor(monkeypatch)
    ingests, stage = _ingest_stubs(monkeypatch, tmp_path, "sess-post-1", transcript_ids={"s01": 7})

    client = _client()
    resp = client.post("/api/sessions", files=bundle("sess-post-1"), headers=auth())

    assert resp.status_code == 200
    body = resp.json()
    assert body["session_id"] == "sess-post-1"
    assert body["processing_status_url"] == "/api/sessions/sess-post-1/status"
    assert body["segments"] == [segment_row("s01", "pending_analysis")]
    assert len(ingests.created) == 1
    session_id, received_at, state, segments = ingests.created[0]
    assert (session_id, received_at, state) == ("sess-post-1", body["received_at"], "processing")
    assert segments == [segment_row("s01", "pending_analysis")]
    # The bundle is on disk where the retry path will look for it.
    manifest_path = session_processing.session_dir_for("sess-post-1") / "manifest.json"
    assert jsonlib.loads(manifest_path.read_text())["session_id"] == "sess-post-1"

    status = client.get(body["processing_status_url"], headers=auth()).json()
    assert status["state"] == "done"
    assert status["segments"] == [segment_row("s01", "processed", 7)]
    assert len(stage.runs) == 1


def test_status_reports_failed_when_every_segment_failed(monkeypatch, tmp_path):
    fresh_processor(monkeypatch)
    _ingest_stubs(monkeypatch, tmp_path, "sess-all-failed", failing={"s01": RuntimeError("boom")})

    client = _client()
    client.post("/api/sessions", files=bundle("sess-all-failed"), headers=auth())

    status = client.get("/api/sessions/sess-all-failed/status", headers=auth()).json()
    assert status["state"] == "failed"
    assert [s["status"] for s in status["segments"]] == ["failed"]


def test_status_reports_partial_when_the_analysis_left_every_segment_pending(monkeypatch, tmp_path):
    """BUG-114/#114: all-pending is `partial`, not `done`."""
    fresh_processor(monkeypatch)
    _, stage = _ingest_stubs(monkeypatch, tmp_path, "sess-all-pending", transcript_ids={"s01": 7})
    stage.analysis_error = RuntimeError("ollama unreachable")

    client = _client()
    client.post("/api/sessions", files=bundle("sess-all-pending"), headers=auth())

    status = client.get("/api/sessions/sess-all-pending/status", headers=auth()).json()
    assert status["state"] == "partial"
    assert [s["status"] for s in status["segments"]] == ["pending_analysis"]


def test_status_reports_partial_for_processed_plus_pending_segments(monkeypatch, tmp_path):
    """BUG-114/#114: a retry that fails again on a session that also has a
    processed segment leaves it `partial`."""
    fresh_processor(monkeypatch)
    session_id = "sess-processed-plus-pending"
    stage_bundle(monkeypatch, tmp_path, session_id, two_segment_manifest(session_id))
    FakeSessionIngests(
        session_id, "partial",
        [segment_row("s01", "processed", 4), segment_row("s02", "pending_analysis", 5, "analysis_pending: first")],
    ).install()
    stub_transcripts(monkeypatch, [5])
    NarrativeStage(monkeypatch).analysis_error = RuntimeError("ollama unreachable")

    client = _client()
    retry = client.post(f"/api/sessions/{session_id}/retry-analysis", headers=auth())

    assert retry.status_code == 200
    status = client.get(f"/api/sessions/{session_id}/status", headers=auth()).json()
    assert status["state"] == "partial"
    assert [s["status"] for s in status["segments"]] == ["processed", "pending_analysis"]


def test_post_session_503s_with_whisper_unavailable_contract_and_persists_nothing(monkeypatch, tmp_path):
    """UFH-01: Whisper is the one upstream we can't work around — surface 503
    early, with nothing persisted: the status row written for the claim is
    rolled back, there is no cache entry, and no bundle is left on disk."""
    fresh_processor(monkeypatch, whisper_up=False)
    ingests, _ = _ingest_stubs(monkeypatch, tmp_path, "sess-ufh-pre")

    client = _client()
    resp = client.post("/api/sessions", files=bundle("sess-ufh-pre"), headers=auth())

    assert resp.status_code == 503
    assert resp.json() == {
        "detail": "whisper_unavailable",
        "code": "whisper_unavailable",
        "upstream": "whisper",
        "retryable": True,
    }
    assert "retry-after" not in resp.headers
    assert [c[0] for c in ingests.created] == ingests.deleted == ["sess-ufh-pre"]
    assert client.get("/api/sessions/sess-ufh-pre/status", headers=auth()).status_code == 404
    assert not session_processing.session_dir_for("sess-ufh-pre").exists()


def test_post_session_400s_when_the_manifest_part_is_missing(monkeypatch, tmp_path):
    fresh_processor(monkeypatch)
    _ingest_stubs(monkeypatch, tmp_path, "sess-no-manifest")

    resp = _client().post(
        "/api/sessions", files=[("segments/s01.m4a", ("s01.m4a", b"audio", "audio/mp4"))], headers=auth(),
    )

    assert resp.status_code == 400
    assert resp.json()["detail"] == "manifest_part_missing"


def test_post_session_422s_on_an_invalid_manifest(monkeypatch, tmp_path):
    fresh_processor(monkeypatch)
    _ingest_stubs(monkeypatch, tmp_path, "sess-bad-manifest")

    resp = _client().post(
        "/api/sessions",
        files=[("manifest", ("manifest.json", b'{"session_id": "x"}', "application/json"))],
        headers=auth(),
    )

    assert resp.status_code == 422
    assert resp.json()["detail"].startswith("manifest_invalid")


def test_post_session_409s_when_the_session_directory_already_exists(monkeypatch, tmp_path):
    fresh_processor(monkeypatch)
    _ingest_stubs(monkeypatch, tmp_path, "sess-dup")
    client = _client()

    first = client.post("/api/sessions", files=bundle("sess-dup"), headers=auth())
    second = client.post("/api/sessions", files=bundle("sess-dup"), headers=auth())

    assert first.status_code == 200
    assert second.status_code == 409
    assert second.json()["detail"] == "session_exists: sess-dup"


def test_post_session_400s_and_cleans_up_when_an_audio_part_is_missing(monkeypatch, tmp_path):
    fresh_processor(monkeypatch)
    ingests, _ = _ingest_stubs(monkeypatch, tmp_path, "sess-missing")

    resp = _client().post("/api/sessions", files=bundle("sess-missing")[:1], headers=auth())

    assert resp.status_code == 400
    assert resp.json()["detail"].startswith("missing_parts: ['segments/s01.m4a']")
    assert not session_processing.session_dir_for("sess-missing").exists()
    assert ingests.created == []


def test_post_session_ignores_unexpected_parts(monkeypatch, tmp_path):
    fresh_processor(monkeypatch)
    _ingest_stubs(monkeypatch, tmp_path, "sess-extra")
    files = bundle("sess-extra") + [("segments/other.m4a", ("other.m4a", b"audio", "audio/mp4"))]

    resp = _client().post("/api/sessions", files=files, headers=auth())

    assert resp.status_code == 200
    assert not (session_processing.session_dir_for("sess-extra") / "segments" / "other.m4a").exists()


def test_post_session_requires_the_bearer_token(monkeypatch, tmp_path):
    fresh_processor(monkeypatch)
    _ingest_stubs(monkeypatch, tmp_path, "sess-noauth")

    resp = _client().post("/api/sessions", files=bundle("sess-noauth"))

    assert resp.status_code in (401, 403)


# --- manual retry: POST /api/sessions/{id}/retry-analysis -----------------


def test_retry_analysis_404s_for_unknown_session(monkeypatch):
    """#52: retrying a session the server has never heard of (neither cache
    nor persisted row) must 404, matching the status endpoint's behaviour."""
    fresh_processor(monkeypatch)
    FakeSessionIngests.empty("unknown").install()

    resp = _client().post("/api/sessions/unknown/retry-analysis", headers=auth())

    assert resp.status_code == 404
    assert resp.json()["detail"] == "session_not_found"


def test_retry_analysis_409s_when_no_segment_is_pending_analysis(monkeypatch):
    """#52: a session with no `pending_analysis` segment (e.g. fully `done`,
    or still `processing`) is not in a retryable state."""
    fresh_processor(monkeypatch)
    FakeSessionIngests("sess-done", "done", [segment_row("s01", "processed", 1)]).install()

    resp = _client().post("/api/sessions/sess-done/retry-analysis", headers=auth())

    assert resp.status_code == 409
    assert resp.json()["detail"] == "session_not_retryable"


def test_retry_analysis_404s_when_the_manifest_is_gone_from_disk(monkeypatch, tmp_path):
    fresh_processor(monkeypatch)
    stage_pending_session(monkeypatch, tmp_path, "sess-no-manifest")
    NarrativeStage(monkeypatch)
    (session_processing.session_dir_for("sess-no-manifest") / "manifest.json").unlink()

    resp = _client().post("/api/sessions/sess-no-manifest/retry-analysis", headers=auth())

    assert resp.status_code == 404
    assert resp.json()["detail"] == "session_manifest_missing"


def test_retry_analysis_rebuilds_the_narrative_and_returns_the_done_status(monkeypatch, tmp_path):
    """#52: the happy path — retry reloads what's persisted, re-runs the
    narrative stage, and flips the segment (and session) to done."""
    fresh_processor(monkeypatch)
    ingests = stage_pending_session(monkeypatch, tmp_path, "sess-retry-full")
    stage = NarrativeStage(monkeypatch)

    client = _client()
    resp = client.post("/api/sessions/sess-retry-full/retry-analysis", headers=auth())

    assert resp.status_code == 200
    body = resp.json()
    assert body["state"] == "done"
    assert body["segments"] == [segment_row("s01", "processed", 5)]
    assert len(stage.runs) == 1
    assert ingests.updates == [("done", body["segments"])]
    assert client.get("/api/sessions/sess-retry-full/status", headers=auth()).json() == body


def test_retry_analysis_resumes_a_session_that_never_reached_transcription(monkeypatch, tmp_path):
    """BUG-112: segments without a transcript ID are transcribed from the
    stored audio — the route answers 200 with the done status, not 409."""
    fresh_processor(monkeypatch)
    stage_bundle(monkeypatch, tmp_path, "sess-resume-route", two_segment_manifest("sess-resume-route"))
    ingests = FakeSessionIngests(
        "sess-resume-route", "processing",
        [segment_row("s01", "pending_analysis"), segment_row("s02", "pending_analysis")],
    ).install()
    SegmentPipeline(monkeypatch, transcript_ids={"s01": 11, "s02": 12})
    stage = NarrativeStage(monkeypatch)

    client = _client()
    resp = client.post("/api/sessions/sess-resume-route/retry-analysis", headers=auth())

    assert resp.status_code == 200
    body = resp.json()
    assert body["state"] == "done"
    assert body["segments"] == [segment_row("s01", "processed", 11), segment_row("s02", "processed", 12)]
    assert len(stage.runs) == 1
    assert ingests.row["state"] == "done"
    assert client.get("/api/sessions/sess-resume-route/status", headers=auth()).json() == body


def test_retry_analysis_returns_partial_with_200_when_some_audio_is_missing(monkeypatch, tmp_path):
    fresh_processor(monkeypatch)
    _, session_dir = stage_bundle(monkeypatch, tmp_path, "sess-resume-gone", two_segment_manifest("sess-resume-gone"))
    (session_dir / "segments" / "s02.m4a").unlink()
    FakeSessionIngests(
        "sess-resume-gone", "processing",
        [segment_row("s01", "pending_analysis", 5), segment_row("s02", "pending_analysis")],
    ).install()
    stub_transcripts(monkeypatch, [5])
    NarrativeStage(monkeypatch)

    resp = _client().post("/api/sessions/sess-resume-gone/retry-analysis", headers=auth())

    assert resp.status_code == 200
    body = resp.json()
    assert body["state"] == "partial"
    assert body["segments"][0] == segment_row("s01", "processed", 5)
    assert body["segments"][1]["status"] == "failed"
    assert "audio missing on disk" in body["segments"][1]["error"]


def test_retry_analysis_returns_failed_with_200_when_no_audio_is_left(monkeypatch, tmp_path):
    fresh_processor(monkeypatch)
    _, session_dir = stage_bundle(monkeypatch, tmp_path, "sess-resume-none", two_segment_manifest("sess-resume-none"))
    for audio in (session_dir / "segments").iterdir():
        audio.unlink()
    FakeSessionIngests(
        "sess-resume-none", "processing",
        [segment_row("s01", "pending_analysis"), segment_row("s02", "pending_analysis")],
    ).install()
    NarrativeStage(monkeypatch)

    resp = _client().post("/api/sessions/sess-resume-none/retry-analysis", headers=auth())

    assert resp.status_code == 200
    assert resp.json()["state"] == "failed"
    assert [s["status"] for s in resp.json()["segments"]] == ["failed", "failed"]


def test_retry_analysis_409s_when_the_pending_transcript_rows_are_gone(monkeypatch, tmp_path):
    fresh_processor(monkeypatch)
    stage_bundle(monkeypatch, tmp_path, "sess-rows-gone")
    FakeSessionIngests(
        "sess-rows-gone", "done", [segment_row("s01", "pending_analysis", 9, "analysis_pending: boom")]
    ).install()
    stub_transcripts(monkeypatch, [])

    resp = _client().post("/api/sessions/sess-rows-gone/retry-analysis", headers=auth())

    assert resp.status_code == 409
    assert resp.json()["detail"] == "session_not_retryable"


def test_retry_analysis_returns_the_pending_status_with_200_when_analysis_fails_again(monkeypatch, tmp_path):
    """BUG-56/#56: the narrative stage failing again on retry must not 500 —
    the segments stay `pending_analysis` with an `analysis_pending: …` error,
    the status is persisted, and the route returns it with 200."""
    fresh_processor(monkeypatch)
    ingests = stage_pending_session(monkeypatch, tmp_path, "sess-retry-fails")
    stage = NarrativeStage(monkeypatch)
    stage.analysis_error = RuntimeError("ollama unreachable")

    client = _client()
    resp = client.post("/api/sessions/sess-retry-fails/retry-analysis", headers=auth())

    expected = [segment_row("s01", "pending_analysis", 5, "analysis_pending: ollama unreachable")]
    assert resp.status_code == 200
    assert resp.json()["segments"] == expected
    assert ingests.updates == [(resp.json()["state"], expected)]
    status = client.get("/api/sessions/sess-retry-fails/status", headers=auth())
    assert status.json()["segments"] == expected


def test_retry_analysis_409s_session_busy_while_another_retry_is_in_flight(monkeypatch, tmp_path):
    """A double tap: while the first retry is in flight, the second gets 409
    `session_busy`, and the narrative stage ran exactly once."""
    fresh_processor(monkeypatch)
    session_id = "sess-retry-double-tap"
    stage_pending_session(monkeypatch, tmp_path, session_id)
    stage = NarrativeStage(monkeypatch)

    async def scenario():
        started, release = stage.latch()
        url = f"/api/sessions/{session_id}/retry-analysis"
        async with _async_client() as client:
            first = asyncio.create_task(client.post(url, headers=auth()))
            try:
                await asyncio.wait_for(started.wait(), 5)
                second = await asyncio.wait_for(client.post(url, headers=auth()), 2)
            finally:
                release.set()
            first_resp = await first
            third = await client.post(url, headers=auth())
        return first_resp, second, third

    first_resp, second, third = asyncio.run(scenario())

    assert second.status_code == 409
    assert second.json()["detail"] == "session_busy"
    assert first_resp.status_code == 200
    assert len(stage.runs) == 1
    # Released: processed now, so not retryable — but crucially not "busy".
    assert third.status_code == 409
    assert third.json()["detail"] == "session_not_retryable"


def test_retry_analysis_409s_session_busy_during_the_original_ingest(monkeypatch, tmp_path):
    """A manual retry that overlaps the original background ingest gets the
    same 409 `session_busy`; the claim is released once the ingest ends."""
    fresh_processor(monkeypatch)
    session_id = "sess-retry-vs-ingest"
    _, stage = _ingest_stubs(monkeypatch, tmp_path, session_id)

    async def scenario():
        started, release = stage.latch()
        url = f"/api/sessions/{session_id}/retry-analysis"
        async with _async_client() as client:
            post = asyncio.create_task(client.post("/api/sessions", files=bundle(session_id), headers=auth()))
            try:
                await asyncio.wait_for(started.wait(), 5)
                during = await client.post(url, headers=auth())
            finally:
                release.set()
            post_resp = await post
            after = await client.post(url, headers=auth())
        return during, post_resp, after

    during, post_resp, after = asyncio.run(scenario())

    assert post_resp.status_code == 200
    assert during.status_code == 409
    assert during.json()["detail"] == "session_busy"
    assert after.status_code == 409
    assert after.json()["detail"] == "session_not_retryable"


# --- startup sweep --------------------------------------------------------


def test_startup_sweep_result_is_visible_through_the_status_route(monkeypatch, tmp_path):
    """The sweep (run from `main.py`'s lifespan) retries a session left
    `pending_analysis` by a prior process; its outcome is what the status
    route then reports."""
    fresh_processor(monkeypatch)
    ingests = stage_pending_session(monkeypatch, tmp_path, "sess-swept")
    NarrativeStage(monkeypatch)
    client = _client()
    assert client.get("/api/sessions/sess-swept/status", headers=auth()).json()["segments"][0]["status"] == "pending_analysis"
    # "Restart": the in-memory cache is gone, only the persisted row remains.
    processor = fresh_processor(monkeypatch, repository=ingests.repository)

    asyncio.run(processor.retry_stuck_sessions_on_startup())

    status = client.get("/api/sessions/sess-swept/status", headers=auth()).json()
    assert status["state"] == "done"
    assert status["segments"] == [segment_row("s01", "processed", 5)]
    assert ingests.row["segments"] == status["segments"]
