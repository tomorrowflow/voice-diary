"""Tests for transcription recovery (FTR-02, ADR 0005 and 0007): an explicit
request transcribes one `failed` segment again from its retained audio and the
day narrative then includes it.

Driven through `SessionIngest.recover` and its route
(`POST /api/sessions/{id}/segments/{segment_id}/retry-transcription`) with the
shared fakes from `session_helpers`: the segment pipeline (with its failure map
and transcript rows), the narrative stage, the in-memory session repository and
an injected Whisper reachability check. Run inside the webapp container, see
DEVELOPMENT.md §7.4.
"""

from __future__ import annotations

import asyncio
import json
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

import httpx
import pytest

import asr_client
import correction
import db
import session_ingest
import upstream_failure
from fastapi import FastAPI
from models import SegmentResult
from routers import sessions as sessions_router
from segment_ingest import SegmentArtifact
from tests.route_helpers import assert_failure
from tests.session_helpers import (
    FakeSessionIngests,
    NarrativeStage,
    SegmentPipeline,
    auth,
    bundle,
    fresh_ingest,
    manifest_dict,
    segment_row,
    stage_bundle,
    stub_transcripts,
)

SESSION = "2026-07-01T09:00:00+02:00"
OLD_ERROR = "whisper read timed out"


def _manifest(session_id: str, segment_ids: list[str]) -> dict:
    manifest = manifest_dict(session_id)
    manifest["segments"] = [
        {
            "segment_id": segment_id,
            "segment_type": "drive_by",
            "audio_file": f"segments/{segment_id}.m4a",
            "captured_at": f"2026-07-01T{10 + index}:00:00Z",
        }
        for index, segment_id in enumerate(segment_ids)
    ]
    return manifest


def _failed(segment_id: str) -> dict:
    return segment_row(segment_id, "failed", None, OLD_ERROR, "whisper_timeout", "whisper")


def _processed(segment_id: str, transcript_id: int) -> dict:
    return segment_row(segment_id, "processed", transcript_id)


def _pending(segment_id: str, transcript_id: int) -> dict:
    return segment_row(segment_id, "pending_analysis", transcript_id, "analysis_pending: boom")


class World:
    """A persisted session with its bundle on disk, the fakes around the
    session ingest, and a route client. `rows` are the session's segment rows;
    `transcript_ids` what a recovered segment's transcript row will be."""

    def __init__(
        self,
        monkeypatch,
        tmp_path,
        rows: list[dict],
        *,
        state: str = "partial",
        whisper_up=True,
        transcript_ids: dict[str, int] | None = None,
        segment_operation=None,
        correct=None,
        session_id: str = SESSION,
    ):
        self.session_id = session_id
        self.ingest = fresh_ingest(
            monkeypatch, whisper_up=whisper_up, segment_operation=segment_operation
        )
        self.parsed, self.session_dir = stage_bundle(
            monkeypatch, tmp_path, session_id, _manifest(session_id, [r["segment_id"] for r in rows])
        )
        self.ingests = FakeSessionIngests(session_id, state, rows).install()
        ids = transcript_ids or {}
        self.pipeline = SegmentPipeline(monkeypatch, transcript_ids=dict(ids), correct=correct)
        self.narrative = NarrativeStage(monkeypatch)
        kept = [r["transcript_id"] for r in rows if r["transcript_id"] is not None]
        stub_transcripts(monkeypatch, kept + list(ids.values()))

    def audio(self, segment_id: str):
        return self.session_dir / "segments" / f"{segment_id}.m4a"

    def client(self) -> httpx.AsyncClient:
        app = FastAPI()
        upstream_failure.install(app)
        app.include_router(sessions_router.router)
        return httpx.AsyncClient(
            transport=httpx.ASGITransport(app=app), base_url="http://test", headers=auth()
        )

    async def post(self, client: httpx.AsyncClient, segment_id: str, session_id: str | None = None):
        return await client.post(
            f"/api/sessions/{session_id or self.session_id}/segments/{segment_id}/retry-transcription"
        )

    async def status(self):
        """A snapshot: the cached status is updated in place as the session
        moves on."""
        return (await self.ingest.status(self.session_id)).model_copy(deep=True)

    def result(self, status, segment_id: str) -> SegmentResult:
        return next(s for s in status.segments if s.segment_id == segment_id)


def _latched_correction():
    """A `correct` for `World` that makes the recovered segment's correction
    step wait: the attempt is then in flight, past Whisper, until `release` is
    set. Returns `(started, release, correct)`."""
    started, release = asyncio.Event(), asyncio.Event()

    async def correct(raw_text):
        started.set()
        await release.wait()
        return correction.CorrectionResult(corrected_text=raw_text)

    return started, release, correct


# --- success --------------------------------------------------------------


def test_recovery_goes_transcribing_then_pending_analysis_then_processed(monkeypatch, tmp_path):
    started, release, correct = _latched_correction()
    world = World(
        monkeypatch, tmp_path, [_processed("s01", 5), _failed("s02")],
        transcript_ids={"s02": 12}, correct=correct,
    )

    async def run():
        async with world.client() as client:
            response = await world.post(client, "s02")
            body = response.json()
            await asyncio.wait_for(started.wait(), 1)
            mid = await world.status()
            release.set()
            await world.ingest.settled()
            final = await world.status()
        return response, body, mid, final

    response, body, mid, final = asyncio.run(run())

    assert response.status_code == 202
    assert body["state"] == "processing"
    assert [(s["segment_id"], s["status"], s["transcript_id"]) for s in body["segments"]] == [
        ("s01", "processed", 5), ("s02", "transcribing", None),
    ]
    assert mid.state == "processing"
    assert world.result(mid, "s02").status == "transcribing"
    assert world.result(mid, "s02").transcript_id is None
    assert final.state == "done"
    assert world.result(final, "s01") == SegmentResult(
        segment_id="s01", status="processed", transcript_id=5
    )
    assert world.result(final, "s02") == SegmentResult(
        segment_id="s02", status="processed", transcript_id=12
    )


def test_the_day_narrative_has_the_recovered_and_the_processed_segments(monkeypatch, tmp_path):
    world = World(
        monkeypatch, tmp_path, [_processed("s01", 5), _failed("s02")],
        transcript_ids={"s02": 12},
    )

    async def run():
        status = await world.ingest.recover(SESSION, "s02")
        await world.ingest.settled()
        return status

    asyncio.run(run())

    assert len(world.narrative.runs) == 1
    text = world.narrative.runs[0]["text"]
    assert "text-5" in text and "hallo welt" in text
    assert text.index("text-5") < text.index("hallo welt")
    assert set(world.narrative.documents) == {5, 12}
    # Only the recovered segment went through the pipeline.
    assert [call["filename"] for call in world.pipeline.transcribe_calls] == [f"{SESSION}::s02.m4a"]


def test_recovering_the_only_segment_of_an_all_failed_session_makes_it_done(monkeypatch, tmp_path):
    world = World(monkeypatch, tmp_path, [_failed("s01")], state="failed")

    async def run():
        await world.ingest.recover(SESSION, "s01")
        await world.ingest.settled()
        return await world.status()

    final = asyncio.run(run())

    assert final.state == "done"
    assert world.result(final, "s01").status == "processed"


def test_a_session_with_other_failed_segments_stays_partial(monkeypatch, tmp_path):
    world = World(monkeypatch, tmp_path, [_failed("s01"), _failed("s02")], state="failed")

    async def run():
        await world.ingest.recover(SESSION, "s02")
        await world.ingest.settled()
        return await world.status()

    final = asyncio.run(run())

    assert final.state == "partial"
    assert world.result(final, "s01").status == "failed"
    assert world.result(final, "s01").error == OLD_ERROR
    assert world.result(final, "s02").status == "processed"


# --- request errors -------------------------------------------------------


def _assert_nothing_started(world: World) -> None:
    assert world.ingests.updates == []
    assert world.pipeline.transcribe_calls == []
    assert world.narrative.runs == []


def test_an_unknown_session_or_segment_is_404_and_changes_nothing(monkeypatch, tmp_path):
    world = World(monkeypatch, tmp_path, [_failed("s01")], state="failed")

    async def run():
        async with world.client() as client:
            return (
                await world.post(client, "s01", "no-such-session"),
                await world.post(client, "s99"),
            )

    unknown_session, unknown_segment = asyncio.run(run())

    assert (unknown_session.status_code, unknown_session.json()["detail"]) == (404, "session_not_found")
    assert (unknown_segment.status_code, unknown_segment.json()["detail"]) == (404, "segment_not_found")
    _assert_nothing_started(world)


@pytest.mark.parametrize(
    "row",
    [
        _processed("s02", 5),
        _pending("s02", 5),
        segment_row("s02", "transcribing"),
    ],
    ids=["processed", "pending_analysis", "transcribing"],
)
def test_a_segment_that_is_not_failed_is_409_and_has_no_side_effect(monkeypatch, tmp_path, row):
    world = World(monkeypatch, tmp_path, [_failed("s01"), row])

    async def run():
        async with world.client() as client:
            response = await world.post(client, "s02")
        await world.ingest.settled()
        return response

    response = asyncio.run(run())

    assert (response.status_code, response.json()["detail"]) == (409, "segment_not_failed")
    _assert_nothing_started(world)
    assert world.ingests.rows[SESSION]["segments"][1]["status"] == row["status"]


def test_missing_audio_or_manifest_entry_is_409_and_changes_nothing(monkeypatch, tmp_path):
    world = World(monkeypatch, tmp_path, [_failed("s01"), _failed("s02")], state="failed")
    world.audio("s01").unlink()
    manifest_path = world.session_dir / "manifest.json"
    manifest = json.loads(manifest_path.read_text())
    manifest["segments"] = [s for s in manifest["segments"] if s["segment_id"] != "s02"]
    manifest_path.write_text(json.dumps(manifest))

    async def run():
        async with world.client() as client:
            return await world.post(client, "s01"), await world.post(client, "s02")

    no_audio, no_entry = asyncio.run(run())

    for response in (no_audio, no_entry):
        assert (response.status_code, response.json()["detail"]) == (409, "segment_audio_missing")
    _assert_nothing_started(world)


def test_whisper_unreachable_is_503_in_the_shared_shape_and_changes_nothing(monkeypatch, tmp_path):
    world = World(monkeypatch, tmp_path, [_failed("s01")], state="failed", whisper_up=False)

    async def run():
        async with world.client() as client:
            return await world.post(client, "s01")

    response = asyncio.run(run())

    assert_failure(
        response, code="whisper_unavailable", upstream="whisper", status=503, retryable=True
    )
    _assert_nothing_started(world)


def test_the_request_checks_run_in_the_documented_order(monkeypatch, tmp_path):
    """404 before not-failed before missing audio before Whisper before busy,
    each decided with Whisper down."""
    world = World(
        monkeypatch, tmp_path, [_processed("s01", 5), _failed("s02"), _failed("s03")],
        whisper_up=False,
    )
    world.audio("s02").unlink()

    async def run():
        async with world.client() as client:
            return {
                "not_found": await world.post(client, "s99"),
                "not_failed": await world.post(client, "s01"),
                "audio_missing": await world.post(client, "s02"),
                "whisper": await world.post(client, "s03"),
            }

    responses = asyncio.run(run())

    assert responses["not_found"].json()["detail"] == "segment_not_found"
    assert responses["not_failed"].json()["detail"] == "segment_not_failed"
    assert responses["audio_missing"].json()["detail"] == "segment_audio_missing"
    assert responses["whisper"].json()["code"] == "whisper_unavailable"
    _assert_nothing_started(world)


def test_whisper_unreachable_wins_over_a_busy_session(monkeypatch, tmp_path):
    state = {"up": True}
    started, release, correct = _latched_correction()
    world = World(
        monkeypatch, tmp_path, [_failed("s01"), _failed("s02")], state="failed",
        whisper_up=lambda: state["up"], correct=correct,
    )

    async def run():
        await world.ingest.recover(SESSION, "s01")
        await asyncio.wait_for(started.wait(), 1)
        state["up"] = False
        try:
            async with world.client() as client:
                return await world.post(client, "s02")
        finally:
            release.set()
            await world.ingest.settled()

    response = asyncio.run(run())

    assert response.json()["code"] == "whisper_unavailable"


def test_a_second_segment_of_a_busy_session_is_409_and_does_nothing(monkeypatch, tmp_path):
    started, release, correct = _latched_correction()
    world = World(
        monkeypatch, tmp_path, [_failed("s01"), _failed("s02")], state="failed", correct=correct,
    )
    pipeline = world.pipeline

    async def run():
        first = await world.ingest.recover(SESSION, "s01")
        await asyncio.wait_for(started.wait(), 1)
        updates_before = len(world.ingests.updates)
        try:
            async with world.client() as client:
                second = await world.post(client, "s02")
                repeat = await world.post(client, "s01")
        finally:
            release.set()
            await world.ingest.settled()
        return first, second, repeat, updates_before

    first, second, repeat, updates_before = asyncio.run(run())

    assert first.state == "processing"
    assert (second.status_code, second.json()["detail"]) == (409, "session_busy")
    assert (repeat.status_code, repeat.json()["detail"]) == (409, "segment_not_failed")
    assert len(world.ingests.updates) >= updates_before
    assert [call["filename"] for call in pipeline.transcribe_calls] == [f"{SESSION}::s01.m4a"]
    assert len(world.narrative.runs) == 1


def test_a_repeated_request_after_the_attempt_has_no_processing_side_effect(monkeypatch, tmp_path):
    world = World(monkeypatch, tmp_path, [_failed("s01")], state="failed")

    async def run():
        async with world.client() as client:
            first = await world.post(client, "s01")
            await world.ingest.settled()
            repeat = await world.post(client, "s01")
            await world.ingest.settled()
        return first, repeat

    first, repeat = asyncio.run(run())

    assert first.status_code == 202
    assert (repeat.status_code, repeat.json()["detail"]) == (409, "segment_not_failed")
    assert len(world.pipeline.transcribe_calls) == 1
    assert len(world.narrative.runs) == 1


# --- failures -------------------------------------------------------------


def test_a_transcription_failure_returns_the_segment_to_failed_with_the_latest_reason(
    monkeypatch, tmp_path,
):
    world = World(monkeypatch, tmp_path, [_processed("s01", 5), _failed("s02")])
    world.pipeline.failing["s02"] = asr_client.AsrUnavailableError("whisper is down")

    async def run():
        await world.ingest.recover(SESSION, "s02")
        await world.ingest.settled()
        failed = await world.status()
        # The next request can succeed.
        world.pipeline.failing.clear()
        await world.ingest.recover(SESSION, "s02")
        await world.ingest.settled()
        return failed, await world.status()

    failed, recovered = asyncio.run(run())

    assert world.result(failed, "s02") == SegmentResult(
        segment_id="s02", status="failed", transcript_id=None,
        error="whisper is down", code="whisper_unavailable", upstream="whisper",
        recoverable=True,
    )
    assert world.result(failed, "s01").status == "processed"
    assert failed.state == "partial"
    assert world.audio("s02").read_bytes() == b"fake-audio"
    assert world.narrative.runs and world.result(recovered, "s02").status == "processed"
    assert recovered.state == "done"


def test_an_error_that_is_not_an_upstream_failure_clears_the_old_code(monkeypatch, tmp_path):
    world = World(monkeypatch, tmp_path, [_failed("s01")], state="failed")
    world.pipeline.failing["s01"] = RuntimeError("Whisper returned an empty transcript")

    async def run():
        await world.ingest.recover(SESSION, "s01")
        await world.ingest.settled()
        return await world.status()

    status = asyncio.run(run())

    assert world.result(status, "s01") == SegmentResult(
        segment_id="s01", status="failed", error="Whisper returned an empty transcript",
        recoverable=True,
    )


def test_a_failure_after_whisper_leaves_no_orphan_and_the_next_attempt_succeeds(
    monkeypatch, tmp_path,
):
    world = World(monkeypatch, tmp_path, [_failed("s01")], state="failed")
    world.pipeline.save_entities_error = RuntimeError("database is down")

    async def run():
        await world.ingest.recover(SESSION, "s01")
        await world.ingest.settled()
        failed = await world.status()
        rows_after_failure = dict(world.pipeline.transcript_rows)
        world.pipeline.save_entities_error = None
        await world.ingest.recover(SESSION, "s01")
        await world.ingest.settled()
        return failed, rows_after_failure, await world.status()

    failed, rows_after_failure, recovered = asyncio.run(run())

    assert world.result(failed, "s01").status == "failed"
    assert world.result(failed, "s01").transcript_id is None
    assert rows_after_failure == {}
    assert world.pipeline.transcript_rows == {f"{SESSION}::s01.m4a": 10}
    assert world.result(recovered, "s01").status == "processed"
    assert world.result(recovered, "s01").transcript_id == 10


def test_a_transcript_row_an_earlier_attempt_left_is_reused_not_duplicated(monkeypatch, tmp_path):
    world = World(monkeypatch, tmp_path, [_failed("s01")], state="failed", transcript_ids={"s01": 12})
    world.pipeline.transcript_rows[f"{SESSION}::s01.m4a"] = 12

    async def run():
        await world.ingest.recover(SESSION, "s01")
        await world.ingest.settled()
        return await world.status()

    status = asyncio.run(run())

    assert world.result(status, "s01") == SegmentResult(
        segment_id="s01", status="processed", transcript_id=12
    )
    assert world.pipeline.transcript_rows == {f"{SESSION}::s01.m4a": 12}


@pytest.mark.parametrize("stage_failure", ["analysis", "lightrag"])
def test_a_narrative_failure_keeps_the_transcript_and_the_existing_retry_finishes_it(
    monkeypatch, tmp_path, stage_failure,
):
    world = World(
        monkeypatch, tmp_path, [_processed("s01", 5), _failed("s02")],
        transcript_ids={"s02": 12},
    )
    if stage_failure == "analysis":
        world.narrative.analysis_error = RuntimeError("ollama unreachable")
    else:
        world.narrative.ingest_error = RuntimeError("lightrag unreachable")

    async def run():
        await world.ingest.recover(SESSION, "s02")
        await world.ingest.settled()
        pending = await world.status()
        world.narrative.analysis_error = None
        world.narrative.ingest_error = None
        retried = await world.ingest.retry(SESSION)
        return pending, retried

    pending, retried = asyncio.run(run())

    recovered = world.result(pending, "s02")
    assert (recovered.status, recovered.transcript_id) == ("pending_analysis", 12)
    assert recovered.error.startswith("analysis_pending: ")
    assert world.result(pending, "s01").status == "processed"
    assert pending.state == "partial"
    assert retried.state == "done"
    assert world.result(retried, "s02") == SegmentResult(
        segment_id="s02", status="processed", transcript_id=12
    )
    assert len(world.pipeline.transcribe_calls) == 1  # the retry did not transcribe again


def test_the_automatic_retry_and_the_sweep_never_transcribe_a_failed_segment(monkeypatch, tmp_path):
    world = World(
        monkeypatch, tmp_path, [_pending("s01", 5), _failed("s02")], transcript_ids={"s02": 12},
    )

    async def run():
        retried = await world.ingest.retry(SESSION)
        await world.ingest.sweep()
        return retried, await world.status()

    retried, final = asyncio.run(run())

    assert world.result(retried, "s02").status == "failed"
    assert world.result(final, "s02").status == "failed"
    assert world.pipeline.transcribe_calls == []


def test_a_failed_segment_of_a_session_with_nothing_pending_is_not_retryable(monkeypatch, tmp_path):
    world = World(monkeypatch, tmp_path, [_processed("s01", 5), _failed("s02")])

    async def run():
        with pytest.raises(session_ingest.SessionNotRetryable):
            await world.ingest.retry(SESSION)
        await world.ingest.sweep()

    asyncio.run(run())

    assert world.pipeline.transcribe_calls == []


# --- coordination ---------------------------------------------------------


def test_recovery_does_not_wait_for_or_block_a_concurrent_upload(monkeypatch, tmp_path):
    started, release = asyncio.Event(), asyncio.Event()
    transcripts = {("upload-1", "s01"): 21, (SESSION, "s02"): 12}

    async def operation(*, manifest, segment, session_dir):
        if manifest.session_id == SESSION:
            started.set()
            await release.wait()
        transcript_id = transcripts[(manifest.session_id, segment.segment_id)]
        return SegmentArtifact(
            segment=segment, transcript_id=transcript_id,
            raw_text=f"raw-{transcript_id}", corrected_text=f"text-{transcript_id}",
        )

    world = World(
        monkeypatch, tmp_path, [_processed("s01", 5), _failed("s02")],
        segment_operation=operation,
    )
    stub_transcripts(monkeypatch, [5, 12, 21])

    async def run():
        await world.ingest.recover(SESSION, "s02")
        await asyncio.wait_for(started.wait(), 1)
        try:
            async with world.client() as client:
                upload = await asyncio.wait_for(
                    client.post("/api/sessions", files=bundle("upload-1")), 1
                )
            uploaded = await world.ingest.status("upload-1")
            during = await world.status()
        finally:
            release.set()
            await world.ingest.settled()
        return upload, uploaded, during, await world.status()

    upload, uploaded, during, final = asyncio.run(run())

    assert upload.status_code == 200
    assert uploaded.segments[0].status == "processed"
    assert world.result(during, "s02").status == "transcribing"
    assert final.state == "done"


def test_the_attempt_continues_when_the_requesting_task_is_cancelled(monkeypatch, tmp_path):
    started, release, correct = _latched_correction()
    world = World(monkeypatch, tmp_path, [_failed("s01")], state="failed", correct=correct)
    pipeline = world.pipeline

    async def run():
        request = asyncio.create_task(world.ingest.recover(SESSION, "s01"))
        await asyncio.wait_for(started.wait(), 1)
        request.cancel()
        await asyncio.gather(request, return_exceptions=True)
        release.set()
        await world.ingest.settled()
        return await world.status()

    final = asyncio.run(run())

    assert world.result(final, "s01").status == "processed"
    assert len(pipeline.transcribe_calls) == 1


def test_cancelling_the_request_while_it_is_accepted_never_strands_the_segment(
    monkeypatch, tmp_path,
):
    """The client leaves while `transcribing` is being persisted: the accepted
    attempt still starts and finishes, and the claim is released."""
    world = World(monkeypatch, tmp_path, [_failed("s01"), _failed("s02")], state="failed")
    repository = world.ingests.repository
    original_update = repository._update
    entered, gate = asyncio.Event(), asyncio.Event()
    updates = []

    async def held_update(session_id, state, segments):
        updates.append(state)
        if len(updates) == 1:  # the `transcribing` write
            entered.set()
            await asyncio.wait_for(gate.wait(), 1)
        await original_update(session_id, state, segments)

    monkeypatch.setattr(repository, "_update", held_update)

    async def run():
        request = asyncio.create_task(world.ingest.recover(SESSION, "s01"))
        await asyncio.wait_for(entered.wait(), 1)
        request.cancel()
        await asyncio.gather(request, return_exceptions=True)
        gate.set()
        await world.ingest.settled()
        # The claim is free again: the other segment can be recovered.
        await world.ingest.recover(SESSION, "s02")
        await world.ingest.settled()
        return await world.status()

    final = asyncio.run(run())

    assert [s.status for s in final.segments] == ["processed", "processed"]
    assert final.state == "done"
    assert len(world.pipeline.transcribe_calls) == 2


def test_a_failed_acceptance_restores_the_segment_and_releases_the_claim(monkeypatch, tmp_path):
    world = World(monkeypatch, tmp_path, [_failed("s01")], state="failed")
    repository = world.ingests.repository
    original_update = repository._update
    calls = []

    async def broken_first_update(session_id, state, segments):
        calls.append(state)
        if len(calls) == 1:
            raise OSError("database is down")
        await original_update(session_id, state, segments)

    monkeypatch.setattr(repository, "_update", broken_first_update)

    async def run():
        with pytest.raises(OSError):
            await world.ingest.recover(SESSION, "s01")
        failed = await world.status()
        await world.ingest.recover(SESSION, "s01")
        await world.ingest.settled()
        return failed, await world.status()

    failed, recovered = asyncio.run(run())

    assert world.result(failed, "s01").status == "failed"
    assert world.result(failed, "s01").error == OLD_ERROR
    assert failed.state == "failed"
    assert recovered.state == "done"
    assert len(world.pipeline.transcribe_calls) == 1


def test_a_transcript_that_cannot_be_linked_to_its_segment_is_deleted(monkeypatch, tmp_path):
    """The transcript was saved but persisting `pending_analysis` fails: the
    segment ends `failed` and the row nothing refers to is deleted."""
    world = World(monkeypatch, tmp_path, [_failed("s01")], state="failed")
    repository = world.ingests.repository
    original_update = repository._update
    calls = []

    async def failing_second_update(session_id, state, segments):
        calls.append(state)
        if len(calls) == 2:  # the `pending_analysis` write
            raise OSError("database is down")
        await original_update(session_id, state, segments)

    monkeypatch.setattr(repository, "_update", failing_second_update)

    async def run():
        await world.ingest.recover(SESSION, "s01")
        await world.ingest.settled()
        return await world.status()

    status = asyncio.run(run())

    assert world.result(status, "s01").status == "failed"
    assert world.result(status, "s01").error == "database is down"
    assert world.pipeline.transcript_rows == {}
    assert world.narrative.runs == []


def _failing_updates(world: World, monkeypatch, failing: set[int]) -> list[str]:
    """Make the n-th session-row write (1-based) of this test fail. Returns the
    list of states written, in order."""
    repository = world.ingests.repository
    original_update = repository._update
    calls: list[str] = []

    async def update(session_id, state, segments):
        calls.append(state)
        if len(calls) in failing:
            raise OSError("database is down")
        await original_update(session_id, state, segments)

    monkeypatch.setattr(repository, "_update", update)
    return calls


@pytest.mark.parametrize(
    ("failing", "narrative_fails"),
    [({3}, False), ({3, 4}, False), ({3}, True), ({3, 4}, True)],
    ids=["final-write", "final-write-and-repair", "pending-write", "pending-write-and-repair"],
)
def test_a_failure_writing_the_final_outcome_keeps_the_linked_transcript(
    monkeypatch, tmp_path, failing, narrative_fails,
):
    """The transcript is linked (`pending_analysis` persisted, write 2); the
    write of its outcome (3) fails, and the repair (4) may fail too. The
    segment is never overwritten with `failed`, the transcript row stays, and
    the existing retry finishes it."""
    world = World(
        monkeypatch, tmp_path, [_failed("s01")], state="failed", transcript_ids={"s01": 10},
    )
    if narrative_fails:
        world.narrative.analysis_error = RuntimeError("ollama unreachable")
    _failing_updates(world, monkeypatch, failing)

    async def run():
        await world.ingest.recover(SESSION, "s01")
        await world.ingest.settled()
        return dict(world.ingests.rows[SESSION]["segments"][0]), dict(world.pipeline.transcript_rows)

    stored, rows = asyncio.run(run())

    assert (stored["status"], stored["transcript_id"]) == ("pending_analysis", 10)
    assert rows == {f"{SESSION}::s01.m4a": 10}

    # After a restart only the stored row is left; the sweep and the route work from it.
    world.ingests.repository.restart()
    world.narrative.analysis_error = None

    retried = asyncio.run(world.ingest.retry(SESSION))

    assert world.result(retried, "s01") == SegmentResult(
        segment_id="s01", status="processed", transcript_id=10
    )
    assert len(world.pipeline.transcribe_calls) == 1  # the retry did not transcribe again


def test_a_save_that_committed_but_lost_its_result_is_found_and_linked(monkeypatch, tmp_path):
    """The one-statement save commits, the connection fails before the answer
    arrives: the lookup of what was saved finds the row, so the segment links
    it instead of being failed with an orphan behind."""
    world = World(
        monkeypatch, tmp_path, [_failed("s01")], state="failed", transcript_ids={"s01": 10},
    )
    world.pipeline.lose_save_result = True

    async def run():
        await world.ingest.recover(SESSION, "s01")
        await world.ingest.settled()
        return await world.status()

    status = asyncio.run(run())

    assert world.result(status, "s01") == SegmentResult(
        segment_id="s01", status="processed", transcript_id=10
    )
    assert world.pipeline.transcript_rows == {f"{SESSION}::s01.m4a": 10}
    assert len(world.narrative.runs) == 1


def test_a_lost_save_result_whose_lookup_fails_has_its_row_deleted(monkeypatch, tmp_path):
    """The save committed and neither its result nor the lookup got through:
    the attempt deletes exactly what it saved before failing the segment, so
    no row is left that nothing refers to."""
    world = World(
        monkeypatch, tmp_path, [_failed("s01")], state="failed", transcript_ids={"s01": 10},
    )
    world.pipeline.lose_save_result = True
    world.pipeline.find_error = ConnectionError("lookup failed")

    async def run():
        await world.ingest.recover(SESSION, "s01")
        await world.ingest.settled()
        failed = await world.status()
        rows_after_failure = dict(world.pipeline.transcript_rows)
        world.pipeline.lose_save_result = False
        world.pipeline.find_error = None
        await world.ingest.recover(SESSION, "s01")
        await world.ingest.settled()
        return failed, rows_after_failure, await world.status()

    failed, rows_after_failure, recovered = asyncio.run(run())

    assert world.result(failed, "s01").status == "failed"
    assert rows_after_failure == {}
    assert world.result(recovered, "s01") == SegmentResult(
        segment_id="s01", status="processed", transcript_id=10
    )
    assert world.pipeline.transcript_rows == {f"{SESSION}::s01.m4a": 10}


def test_a_lost_save_result_that_cannot_be_looked_up_or_deleted_is_replaced_next_time(
    monkeypatch, tmp_path,
):
    world = World(
        monkeypatch, tmp_path, [_failed("s01")], state="failed", transcript_ids={"s01": 10},
    )
    world.pipeline.lose_save_result = True
    world.pipeline.find_error = ConnectionError("lookup failed")
    world.pipeline.delete_error = ConnectionError("delete failed")

    async def run():
        await world.ingest.recover(SESSION, "s01")
        await world.ingest.settled()
        failed = await world.status()
        rows_after_failure = dict(world.pipeline.transcript_rows)
        world.pipeline.lose_save_result = False
        world.pipeline.find_error = None
        world.pipeline.delete_error = None
        await world.ingest.recover(SESSION, "s01")
        await world.ingest.settled()
        return failed, rows_after_failure, await world.status()

    failed, rows_after_failure, recovered = asyncio.run(run())

    assert world.result(failed, "s01").status == "failed"
    assert list(rows_after_failure.values()) == [10]  # the one case left: no database at all
    assert world.result(recovered, "s01").transcript_id == 10
    assert world.pipeline.transcript_rows == {f"{SESSION}::s01.m4a": 10}  # replaced, not duplicated


def test_a_row_with_other_values_is_not_deleted_after_a_lost_save_result(monkeypatch, tmp_path):
    """The compensating delete only removes what this attempt saved: a row a
    person has since edited (other corrected text) stays."""
    world = World(
        monkeypatch, tmp_path, [_failed("s01")], state="failed", transcript_ids={"s01": 10},
    )
    world.pipeline.lose_save_result = True
    world.pipeline.find_error = ConnectionError("lookup failed")
    original_delete = db.delete_saved_transcript

    async def delete_after_an_edit(**row):
        world.pipeline.recovered_values[row["filename"]] = (
            row["raw_text"], "edited by a person", row["detected_entities_json"],
        )
        return await original_delete(**row)

    monkeypatch.setattr(db, "delete_saved_transcript", delete_after_an_edit)

    async def run():
        await world.ingest.recover(SESSION, "s01")
        await world.ingest.settled()

    asyncio.run(run())

    assert world.pipeline.transcript_rows == {f"{SESSION}::s01.m4a": 10}


def test_reset_all_data_stops_a_running_recovery_and_leaves_no_transcript(monkeypatch, tmp_path):
    """Reset All Data waits for uploads and now also stops recoveries: one
    that was past Whisper cannot save a transcript after the tables were
    cleared, and its claim is released."""
    started, release, correct = _latched_correction()
    world = World(
        monkeypatch, tmp_path, [_failed("s01")], state="failed", correct=correct,
    )

    async def run():
        await world.ingest.recover(SESSION, "s01")
        await asyncio.wait_for(started.wait(), 1)
        await asyncio.wait_for(world.ingest.reset_all_data(), 1)
        release.set()  # too late: the attempt was stopped
        await world.ingest.settled()
        return await world.ingest.status(SESSION)

    status = asyncio.run(run())

    assert status is None
    assert world.pipeline.transcript_rows == {}
    assert world.ingests.rows == {}
    assert world.narrative.runs == []


def test_a_recovery_whose_session_disappeared_deletes_the_transcript_it_saved(
    monkeypatch, tmp_path,
):
    """The session row vanishes while the attempt is past Whisper (anything
    that forgets the session, not only a reset): once the transcript is saved
    and there is no session to link it to, the row is deleted again."""
    started, release, correct = _latched_correction()
    world = World(
        monkeypatch, tmp_path, [_failed("s01")], state="failed", correct=correct,
    )

    async def run():
        await world.ingest.recover(SESSION, "s01")
        await asyncio.wait_for(started.wait(), 1)
        await world.ingest.repository.delete(SESSION)
        release.set()
        await world.ingest.settled()

    asyncio.run(run())

    assert world.pipeline.transcript_rows == {}
    assert world.narrative.runs == []


def test_a_recovery_requested_while_a_reset_runs_waits_for_it_and_finds_no_session(
    monkeypatch, tmp_path,
):
    world = World(monkeypatch, tmp_path, [_failed("s01")], state="failed")
    cleared = asyncio.Event()
    original_clear = world.ingest._clear_everything
    resume = asyncio.Event()

    async def slow_clear():
        cleared.set()
        await asyncio.wait_for(resume.wait(), 1)
        await original_clear()

    monkeypatch.setattr(world.ingest, "_clear_everything", slow_clear)

    async def run():
        reset = asyncio.create_task(world.ingest.reset_all_data())
        await asyncio.wait_for(cleared.wait(), 1)
        recovery = asyncio.create_task(world.ingest.recover(SESSION, "s01"))
        await asyncio.sleep(0)
        waiting = not recovery.done()
        resume.set()
        await reset
        with pytest.raises(session_ingest.SessionNotFound):
            await asyncio.wait_for(recovery, 1)
        return waiting

    waiting = asyncio.run(run())

    assert waiting
    assert world.pipeline.transcribe_calls == []
    assert world.pipeline.transcript_rows == {}


def test_a_row_that_cannot_be_deleted_is_replaced_by_the_next_attempt(monkeypatch, tmp_path):
    world = World(monkeypatch, tmp_path, [_failed("s01")], state="failed")
    repository = world.ingests.repository
    original_update = repository._update
    calls = []

    async def failing_second_update(session_id, state, segments):
        calls.append(state)
        if len(calls) == 2:
            raise OSError("database is down")
        await original_update(session_id, state, segments)

    async def delete_fails(ids):
        raise OSError("database is down")

    monkeypatch.setattr(repository, "_update", failing_second_update)
    monkeypatch.setattr(db, "delete_transcripts", delete_fails)

    async def run():
        await world.ingest.recover(SESSION, "s01")
        await world.ingest.settled()
        failed = await world.status()
        rows_left = dict(world.pipeline.transcript_rows)
        await world.ingest.recover(SESSION, "s01")
        await world.ingest.settled()
        return failed, rows_left, await world.status()

    failed, rows_left, recovered = asyncio.run(run())

    assert world.result(failed, "s01").status == "failed"
    assert list(rows_left.values()) == [10]
    assert world.pipeline.transcript_rows == {f"{SESSION}::s01.m4a": 10}  # replaced, not duplicated
    assert world.result(recovered, "s01").transcript_id == 10
    assert recovered.state == "done"


def test_the_claim_is_released_when_the_attempt_ends(monkeypatch, tmp_path):
    world = World(monkeypatch, tmp_path, [_failed("s01"), _failed("s02")], state="failed")
    world.pipeline.failing["s01"] = RuntimeError("boom")

    async def run():
        await world.ingest.recover(SESSION, "s01")
        await world.ingest.settled()
        # s01 failed again, so s02 can be recovered: the session is not busy.
        await world.ingest.recover(SESSION, "s02")
        await world.ingest.settled()
        return await world.status()

    final = asyncio.run(run())

    assert world.result(final, "s01").status == "failed"
    assert world.result(final, "s02").status == "processed"


# --- status ---------------------------------------------------------------


def test_recoverable_is_true_while_the_audio_exists_and_false_once_it_is_gone(monkeypatch, tmp_path):
    world = World(
        monkeypatch, tmp_path, [_processed("s01", 5), _failed("s02"), _failed("s03")],
    )
    world.audio("s03").unlink()

    async def run():
        async with world.client() as client:
            response = await client.get(f"/api/sessions/{SESSION}/status")
        return response.json()

    body = asyncio.run(run())

    by_id = {s["segment_id"]: s for s in body["segments"]}
    assert "recoverable" not in by_id["s01"]
    assert by_id["s02"]["recoverable"] is True
    assert by_id["s03"]["recoverable"] is False
    # Computed on read: nothing was stored.
    assert all("recoverable" not in s for s in world.ingests.rows[SESSION]["segments"])


def test_recoverable_is_false_when_the_manifest_is_gone(monkeypatch, tmp_path):
    world = World(monkeypatch, tmp_path, [_failed("s01")], state="failed")
    (world.session_dir / "manifest.json").unlink()

    async def run():
        return await world.status()

    status = asyncio.run(run())

    assert status.segments[0].recoverable is False


def test_the_ingest_module_still_imports_no_http_types():
    assert "HTTPException" not in vars(session_ingest)
    assert "fastapi" not in {
        getattr(value, "__module__", "").split(".")[0] for value in vars(session_ingest).values()
    }
