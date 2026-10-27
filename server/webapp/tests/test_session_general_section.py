"""Tests for the `general_section` segment variant (FTR-07, SPEC §10.4): the
user-defined walkthrough section the iOS app already sends. It must be
accepted by manifest parsing and the session routes, keep its section context
through the stored bundle (reload, retry-analysis, transcription recovery) and
reach the day narrative as a title header, while the user's transcript stays
exactly what was spoken and the prompt stays out of the narrative input.

Driven through the routes with the shared fakes from `session_helpers`. Run
inside the webapp container, see DEVELOPMENT.md §7.4.
"""

from __future__ import annotations

import asyncio
import json
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

import httpx
import pytest
from fastapi import FastAPI
from fastapi.testclient import TestClient
from pydantic import ValidationError

import session_ingest
import upstream_failure
from models import GeneralSectionSegment, Manifest
from routers import sessions as sessions_router
from tests.session_helpers import (
    FakeSessionIngests,
    NarrativeStage,
    SegmentPipeline,
    auth,
    fresh_ingest,
    manifest_dict,
    segment_row,
    stage_bundle,
    stub_transcripts,
)

SECTION_ID = "5f0c2a52-7d58-4b8c-9c1e-0d6f4a3a9b11"
TITLE = "Abendreflexion"
PROMPT = "Was hat dich heute am meisten beschäftigt?"
HEADER = f"## Abschnitt: {TITLE}"


def _general_segment(segment_id: str = "s01", **overrides) -> dict:
    segment = {
        "segment_id": segment_id,
        "segment_type": "general_section",
        "section_id": SECTION_ID,
        "title": TITLE,
        "prompt_text": PROMPT,
        "audio_file": f"segments/{segment_id}.m4a",
        "transcript": "",
        "language": "de-DE",
    }
    segment.update(overrides)
    return segment


def _manifest(session_id: str, *segments: dict) -> dict:
    manifest = manifest_dict(session_id)
    manifest["segments"] = list(segments) or [_general_segment()]
    return manifest


def _drive_by(segment_id: str) -> dict:
    return {
        "segment_id": segment_id,
        "segment_type": "drive_by",
        "audio_file": f"segments/{segment_id}.m4a",
        "captured_at": "2026-07-01T10:00:00Z",
    }


def _bundle(manifest: dict) -> list[tuple]:
    files = [("manifest", ("manifest.json", json.dumps(manifest).encode(), "application/json"))]
    for segment in manifest["segments"]:
        files.append((segment["audio_file"], ("a.m4a", b"fake-audio-bytes", "audio/mp4")))
    return files


def _client() -> TestClient:
    app = FastAPI()
    upstream_failure.install(app)
    app.include_router(sessions_router.router)
    return TestClient(app)


# --- manifest model ---------------------------------------------------------


def test_manifest_parses_a_spec_shaped_general_section_and_keeps_its_fields():
    manifest = Manifest.model_validate(_manifest("sess-model"))

    segment = manifest.segments[0]
    assert isinstance(segment, GeneralSectionSegment)
    assert segment.segment_type == "general_section"
    assert (segment.section_id, segment.title, segment.prompt_text) == (SECTION_ID, TITLE, PROMPT)
    assert segment.audio_file == "segments/s01.m4a"
    assert segment.language == "de-DE"
    reloaded = Manifest.model_validate(json.loads(manifest.model_dump_json()))
    assert reloaded.segments[0] == segment


def test_section_id_is_any_string_not_only_a_uuid():
    manifest = Manifest.model_validate(_manifest("sess-model", _general_segment(section_id="custom-1")))

    assert manifest.segments[0].section_id == "custom-1"


@pytest.mark.parametrize("field", ["section_id", "title", "prompt_text"])
@pytest.mark.parametrize("missing", ["absent", "null"])
def test_a_general_section_without_a_required_field_is_invalid(field, missing):
    segment = _general_segment()
    if missing == "absent":
        del segment[field]
    else:
        segment[field] = None

    with pytest.raises(ValidationError):
        Manifest.model_validate(_manifest("sess-model", segment))


def test_the_legacy_variants_still_parse_to_their_own_models():
    manifest = Manifest.model_validate(_manifest("sess-model", _drive_by("s01"), _general_segment("s02")))

    assert [type(s).__name__ for s in manifest.segments] == ["DriveBySegment", "GeneralSectionSegment"]


# --- original ingest --------------------------------------------------------


def _stubs(monkeypatch, tmp_path, session_id: str, **pipeline):
    monkeypatch.setenv("DATA_DIR", str(tmp_path))
    fresh_ingest(monkeypatch)
    ingests = FakeSessionIngests.empty(session_id).install()
    return ingests, SegmentPipeline(monkeypatch, **pipeline), NarrativeStage(monkeypatch)


def test_post_session_accepts_a_general_section_and_processes_its_audio(monkeypatch, tmp_path):
    session_id = "sess-gs-post"
    manifest = _manifest(session_id)
    ingests, pipeline, stage = _stubs(monkeypatch, tmp_path, session_id, transcript_ids={"s01": 7})

    client = _client()
    resp = client.post("/api/sessions", files=_bundle(manifest), headers=auth())

    assert resp.status_code == 200
    assert resp.json()["segments"] == [segment_row("s01", "pending_analysis")]
    status = client.get(f"/api/sessions/{session_id}/status", headers=auth()).json()
    assert status["state"] == "done"
    assert status["segments"] == [segment_row("s01", "processed", 7)]
    assert [c["filename"] for c in pipeline.transcribe_calls] == [f"{session_id}::s01.m4a"]
    assert pipeline.transcribe_calls[0]["audio_bytes"] == b"fake-audio-bytes"
    assert ingests.row["state"] == "done"
    # The stored manifest keeps the section's own fields for reload and retry.
    stored = json.loads((session_ingest.session_dir_for(session_id) / "manifest.json").read_text())
    assert stored["segments"][0]["section_id"] == SECTION_ID
    assert stored["segments"][0]["title"] == TITLE
    assert stored["segments"][0]["prompt_text"] == PROMPT
    assert session_ingest.load_manifest(session_id).segments[0].section_id == SECTION_ID
    assert len(stage.runs) == 1


def test_the_narrative_input_carries_the_section_title_but_not_the_prompt(monkeypatch, tmp_path):
    session_id = "sess-gs-context"
    manifest = _manifest(session_id, _drive_by("s01"), _general_segment("s02"))
    _, pipeline, stage = _stubs(monkeypatch, tmp_path, session_id)

    resp = _client().post("/api/sessions", files=_bundle(manifest), headers=auth())

    assert resp.status_code == 200
    assert stage.runs[0]["text"] == (
        "## Notiz unterwegs\n\nhallo welt\n\n"
        f"{HEADER}\n\nhallo welt"
    )
    # The spoken text is what was transcribed and corrected; the prompt is an
    # AI prompt and is not part of the narrative input either.
    assert [c["raw_text"] for c in pipeline.correct_calls] == ["hallo welt", "hallo welt"]
    assert PROMPT not in stage.runs[0]["text"]


@pytest.mark.parametrize("field", ["section_id", "title", "prompt_text"])
def test_post_session_422s_before_any_side_effect_when_a_required_field_is_missing(
    monkeypatch, tmp_path, field
):
    session_id = "sess-gs-invalid"
    segment = _general_segment()
    del segment[field]
    ingests, pipeline, stage = _stubs(monkeypatch, tmp_path, session_id)

    resp = _client().post("/api/sessions", files=_bundle(_manifest(session_id, segment)), headers=auth())

    assert resp.status_code == 422
    assert resp.json()["detail"].startswith("manifest_invalid")
    assert not session_ingest.session_dir_for(session_id).exists()
    assert ingests.created == []
    assert pipeline.transcribe_calls == []
    assert stage.runs == []


# --- stored bundle: reload, retry, recovery ----------------------------------


def test_retry_analysis_reloads_the_stored_section_into_the_narrative(monkeypatch, tmp_path):
    session_id = "sess-gs-retry"
    fresh_ingest(monkeypatch)
    stage_bundle(monkeypatch, tmp_path, session_id, _manifest(session_id))
    FakeSessionIngests(
        session_id, "partial", [segment_row("s01", "pending_analysis", 5, "analysis_pending: first")]
    ).install()
    stub_transcripts(monkeypatch, [5])
    stage = NarrativeStage(monkeypatch)

    resp = _client().post(f"/api/sessions/{session_id}/retry-analysis", headers=auth())

    assert resp.status_code == 200
    assert resp.json()["state"] == "done"
    assert stage.runs[0]["text"] == f"{HEADER}\n\ntext-5"


def test_retry_analysis_resumes_an_untranscribed_general_section_from_its_audio(monkeypatch, tmp_path):
    session_id = "sess-gs-resume"
    fresh_ingest(monkeypatch)
    stage_bundle(monkeypatch, tmp_path, session_id, _manifest(session_id))
    FakeSessionIngests(session_id, "processing", [segment_row("s01", "pending_analysis")]).install()
    pipeline = SegmentPipeline(monkeypatch, transcript_ids={"s01": 11})
    stage = NarrativeStage(monkeypatch)

    resp = _client().post(f"/api/sessions/{session_id}/retry-analysis", headers=auth())

    assert resp.status_code == 200
    assert resp.json()["segments"] == [segment_row("s01", "processed", 11)]
    assert [c["audio_bytes"] for c in pipeline.transcribe_calls] == [b"fake-audio"]
    assert stage.runs[0]["text"].startswith(HEADER)


def test_retry_transcription_recovers_a_failed_general_section(monkeypatch, tmp_path):
    session_id = "sess-gs-recover"
    ingest = fresh_ingest(monkeypatch)
    stage_bundle(monkeypatch, tmp_path, session_id, _manifest(session_id))
    FakeSessionIngests(
        session_id, "failed",
        [segment_row("s01", "failed", None, "whisper read timed out", "whisper_timeout", "whisper")],
    ).install()
    pipeline = SegmentPipeline(monkeypatch, transcript_ids={"s01": 12})
    stage = NarrativeStage(monkeypatch)
    stub_transcripts(monkeypatch, [12])

    async def run():
        app = FastAPI()
        upstream_failure.install(app)
        app.include_router(sessions_router.router)
        async with httpx.AsyncClient(
            transport=httpx.ASGITransport(app=app), base_url="http://test", headers=auth()
        ) as client:
            response = await client.post(f"/api/sessions/{session_id}/segments/s01/retry-transcription")
            await ingest.settled()
            return response

    response = asyncio.run(run())

    assert response.status_code == 202
    assert [c["filename"] for c in pipeline.transcribe_calls] == [f"{session_id}::s01.m4a"]
    assert stage.runs[0]["text"].startswith(HEADER)
    assert PROMPT not in stage.runs[0]["text"]
