"""Tests for `segment_ingest.SegmentIngest` (ARCH-3): the per-segment operation
behind `SessionIngest`, driven through its `ingest` method with the four
collaborators it coordinates — Whisper transcription + persistence, the
dictionary snapshot, correction + entity detection, detected-entity
persistence — injected as local fakes. Nothing is monkeypatched.

Run inside the webapp container so deps + env match prod:

    docker compose run --rm webapp pytest webapp/tests/test_segment_ingest.py
"""

from __future__ import annotations

import json
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

import pytest

import correction
import db
import dictionary
import transcript_ingest
from dictionary import DictionarySnapshot
from entity_detector import DetectedEntity
from models import Manifest
from segment_ingest import SegmentIngest
from tests.session_helpers import manifest_dict


class Collaborators:
    """Local stand-ins for the four collaborators; `calls` records the order
    they ran in."""

    def __init__(self, *, persons: list | None = None, entities: list | None = None):
        self.calls: list[str] = []
        self.transcribed: list[dict] = []
        self.corrected: list[dict] = []
        self.saved: list[tuple] = []
        self.recovered: list[dict] = []
        self._persons = persons or []
        self._entities = entities or []

    async def transcribe(self, audio_bytes, *, src_suffix, filename, date, author, language="de"):
        self.calls.append("transcribe")
        self.transcribed.append({
            "audio_bytes": audio_bytes, "src_suffix": src_suffix, "filename": filename,
            "date": date, "author": author, "language": language,
        })
        return transcript_ingest.TranscribedSegment(transcript_id=42, raw_text="hallo welt")

    async def load_snapshot(self):
        self.calls.append("snapshot")
        return DictionarySnapshot(
            persons=list(self._persons), terms=[{"canonical_name": "Sprint"}],
            text_corrections=[], dismissals=[],
        )

    async def correct(self, raw_text, *, snapshot=None, on_step=None):
        self.calls.append("correct")
        self.corrected.append({"raw_text": raw_text, "snapshot": snapshot})
        return correction.CorrectionResult(corrected_text="hallo Welt", entities=self._entities)

    async def save_entities(self, transcript_id, text, detected_entities_json):
        self.calls.append("save")
        self.saved.append((transcript_id, text, detected_entities_json))

    async def transcribe_text(self, audio_bytes, *, src_suffix, filename, language="de"):
        self.calls.append("transcribe_text")
        self.transcribed.append({
            "audio_bytes": audio_bytes, "src_suffix": src_suffix, "filename": filename,
            "language": language,
        })
        return "hallo welt"

    async def save_recovered(self, **row):
        self.calls.append("save_recovered")
        self.recovered.append(row)
        return 42

    async def find_saved(self, **row):
        self.calls.append("find_saved")
        return None

    async def delete_saved(self, **row):
        self.calls.append("delete_saved")
        return True

    def segment_ingest(self) -> SegmentIngest:
        return SegmentIngest(
            transcribe=self.transcribe, load_snapshot=self.load_snapshot,
            correct=self.correct, save_entities=self.save_entities,
            transcribe_text=self.transcribe_text, save_recovered=self.save_recovered,
            find_saved=self.find_saved, delete_saved=self.delete_saved,
        )


def _bundle(tmp_path, *, audio_file="segments/s01.m4a", segment: dict | None = None, **manifest_overrides):
    """A parsed manifest whose first segment is `segment` over the defaults,
    with its audio on disk under `tmp_path`."""
    raw = manifest_dict("sess-1")
    raw["segments"][0]["audio_file"] = audio_file
    raw["segments"][0].update(segment or {})
    raw.update(manifest_overrides)
    manifest = Manifest.model_validate(raw)
    audio = tmp_path / audio_file
    audio.parent.mkdir(parents=True, exist_ok=True)
    audio.write_bytes(b"fake-audio")
    return manifest, manifest.segments[0]


def _calendar_segment(attendees: list[str]) -> dict:
    return {
        "segment_type": "calendar_event",
        "calendar_ref": {
            "graph_event_id": "evt-1", "start": "2026-07-01T10:00:00Z",
            "end": "2026-07-01T11:00:00Z", "attendees": attendees,
        },
    }


async def test_a_segment_is_transcribed_corrected_and_its_entities_persisted(tmp_path):
    entity = DetectedEntity(
        start=0, end=4, original_text="Anna", canonical="Anna", entity_type="PERSON",
        match_type="exact", confidence="high", status="auto-matched",
    )
    fakes = Collaborators(entities=[entity])
    manifest, segment = _bundle(tmp_path, date="2026-07-04")

    artifact = await fakes.segment_ingest().ingest(
        manifest=manifest, segment=segment, session_dir=tmp_path
    )

    expected_entities = [{
        "start": 0, "end": 4, "original_text": "Anna", "canonical": "Anna",
        "entity_type": "PERSON", "match_type": "exact", "confidence": "high",
        "status": "auto-matched", "dictionary_id": None, "source": "term",
        "role": "", "candidates": [], "llm_validated": False, "llm_reason": "",
        "llm_suggested": False, "text": "Anna", "type": "PERSON",
    }]
    assert fakes.calls == ["transcribe", "snapshot", "correct", "save"]
    assert fakes.transcribed == [{
        "audio_bytes": b"fake-audio", "src_suffix": ".m4a", "filename": "sess-1::s01.m4a",
        "date": "2026-07-04", "author": "Lukas Brandt", "language": "de",
    }]
    assert fakes.corrected[0]["raw_text"] == "hallo welt"
    transcript_id, text, entities_json = fakes.saved[0]
    assert (transcript_id, text) == (42, "hallo Welt")
    assert json.loads(entities_json) == expected_entities
    assert (artifact.segment, artifact.transcript_id) == (segment, 42)
    assert (artifact.raw_text, artifact.corrected_text) == ("hallo welt", "hallo Welt")
    assert artifact.entities == expected_entities


async def test_entities_are_persisted_even_when_correction_changed_nothing(tmp_path):
    fakes = Collaborators()

    async def correct(raw_text, *, snapshot=None, on_step=None):
        return correction.CorrectionResult(corrected_text=raw_text)

    fakes.correct = correct
    manifest, segment = _bundle(tmp_path)

    await fakes.segment_ingest().ingest(manifest=manifest, segment=segment, session_dir=tmp_path)

    assert fakes.saved == [(42, "hallo welt", "[]")]


@pytest.mark.parametrize(
    ("tag", "audio_file", "language", "suffix", "filename"),
    [
        ("en-US", "segments/s01.m4a", "en", ".m4a", "sess-1::s01.m4a"),
        ("de-DE", "segments/s01.wav", "de", ".wav", "sess-1::s01.wav"),
        ("de-DE", "segments/s01", "de", ".m4a", "sess-1::s01"),
    ],
)
async def test_language_and_suffix_come_from_the_segment(
    tmp_path, tag, audio_file, language, suffix, filename
):
    fakes = Collaborators()
    manifest, segment = _bundle(tmp_path, audio_file=audio_file, segment={"language": tag})

    await fakes.segment_ingest().ingest(manifest=manifest, segment=segment, session_dir=tmp_path)

    call = fakes.transcribed[0]
    assert (call["language"], call["src_suffix"], call["filename"]) == (language, suffix, filename)


async def test_missing_audio_raises_before_any_collaborator_runs(tmp_path):
    fakes = Collaborators()
    manifest, segment = _bundle(tmp_path)
    (tmp_path / segment.audio_file).unlink()

    with pytest.raises(FileNotFoundError, match="segment audio missing on disk: segments/s01.m4a"):
        await fakes.segment_ingest().ingest(manifest=manifest, segment=segment, session_dir=tmp_path)

    assert fakes.calls == []


async def test_a_collaborator_failure_propagates_and_persists_nothing(tmp_path):
    fakes = Collaborators()

    async def correct(raw_text, *, snapshot=None, on_step=None):
        raise RuntimeError("ollama down")

    fakes.correct = correct
    manifest, segment = _bundle(tmp_path)

    with pytest.raises(RuntimeError, match="ollama down"):
        await fakes.segment_ingest().ingest(manifest=manifest, segment=segment, session_dir=tmp_path)

    assert fakes.saved == []


async def test_a_recovery_saves_the_transcript_and_its_entities_in_one_write_at_the_end(tmp_path):
    entity = DetectedEntity(
        start=0, end=4, original_text="Anna", canonical="Anna", entity_type="PERSON",
        match_type="exact", confidence="high", status="auto-matched",
    )
    fakes = Collaborators(entities=[entity])
    manifest, segment = _bundle(tmp_path, date="2026-07-04")

    artifact = await fakes.segment_ingest().recover(
        manifest=manifest, segment=segment, session_dir=tmp_path
    )

    assert fakes.calls == ["transcribe_text", "snapshot", "correct", "save_recovered"]
    assert fakes.transcribed == [{
        "audio_bytes": b"fake-audio", "src_suffix": ".m4a", "filename": "sess-1::s01.m4a",
        "language": "de",
    }]
    row = fakes.recovered[0]
    assert (row["filename"], row["date"], row["author"]) == (
        "sess-1::s01.m4a", "2026-07-04", "Lukas Brandt",
    )
    assert (row["raw_text"], row["corrected_text"]) == ("hallo welt", "hallo Welt")
    assert [e["canonical"] for e in json.loads(row["detected_entities_json"])] == ["Anna"]
    assert (artifact.transcript_id, artifact.raw_text, artifact.corrected_text) == (
        42, "hallo welt", "hallo Welt",
    )
    assert artifact.entities == json.loads(row["detected_entities_json"])


@pytest.mark.parametrize("failing_step", ["transcribe_text", "correct", "load_snapshot"])
async def test_a_recovery_that_fails_before_its_write_leaves_nothing_behind(tmp_path, failing_step):
    fakes = Collaborators()

    async def fail(*args, **kwargs):
        raise RuntimeError("step failed")

    setattr(fakes, failing_step, fail)
    manifest, segment = _bundle(tmp_path)

    with pytest.raises(RuntimeError, match="step failed"):
        await fakes.segment_ingest().recover(manifest=manifest, segment=segment, session_dir=tmp_path)

    assert fakes.recovered == []
    assert "save_recovered" not in fakes.calls


async def test_a_failed_recovery_write_that_saved_nothing_propagates(tmp_path):
    fakes = Collaborators()

    async def save_recovered(**row):
        raise OSError("database is down")

    fakes.save_recovered = save_recovered
    manifest, segment = _bundle(tmp_path)

    with pytest.raises(OSError, match="database is down"):
        await fakes.segment_ingest().recover(manifest=manifest, segment=segment, session_dir=tmp_path)

    assert fakes.calls[-1] == "find_saved"  # asked whether anything was saved


async def test_a_recovery_write_that_committed_but_failed_is_found_and_returned(tmp_path):
    """The statement committed and the connection dropped before its result
    arrived: the lookup of the exact saved values finds the row's id."""
    fakes = Collaborators()
    saved = {}

    async def save_recovered(*, author, **row):
        saved.update(row)
        raise ConnectionError("connection lost")

    async def find_saved(**row):
        return 77 if row == saved else None

    fakes.save_recovered = save_recovered
    fakes.find_saved = find_saved
    manifest, segment = _bundle(tmp_path)

    artifact = await fakes.segment_ingest().recover(
        manifest=manifest, segment=segment, session_dir=tmp_path
    )

    assert artifact.transcript_id == 77
    assert (artifact.raw_text, artifact.corrected_text) == ("hallo welt", "hallo Welt")


async def test_a_failed_lookup_after_a_failed_write_deletes_what_was_saved(tmp_path):
    """Neither the result nor the lookup got through: the attempt takes back
    the row, by the exact values it saved, and raises the write's own error."""
    fakes = Collaborators()
    saved = {}
    deleted = []

    async def save_recovered(*, author, **row):
        saved.update(row)
        raise ConnectionError("connection lost")

    async def find_saved(**row):
        raise OSError("lookup failed too")

    async def delete_saved(**row):
        deleted.append(row)
        return True

    fakes.save_recovered = save_recovered
    fakes.find_saved = find_saved
    fakes.delete_saved = delete_saved
    manifest, segment = _bundle(tmp_path)

    with pytest.raises(ConnectionError, match="connection lost"):
        await fakes.segment_ingest().recover(manifest=manifest, segment=segment, session_dir=tmp_path)

    assert deleted == [saved]


async def test_a_lookup_that_found_nothing_deletes_nothing(tmp_path):
    fakes = Collaborators()  # `find_saved` answers None
    deleted = []

    async def save_recovered(**row):
        raise ConnectionError("connection lost")

    async def delete_saved(**row):
        deleted.append(row)
        return True

    fakes.save_recovered = save_recovered
    fakes.delete_saved = delete_saved
    manifest, segment = _bundle(tmp_path)

    with pytest.raises(ConnectionError, match="connection lost"):
        await fakes.segment_ingest().recover(manifest=manifest, segment=segment, session_dir=tmp_path)

    assert deleted == []


async def test_a_failed_delete_after_a_failed_lookup_does_not_hide_the_writes_error(tmp_path):
    fakes = Collaborators()

    async def save_recovered(**row):
        raise ConnectionError("connection lost")

    async def find_saved(**row):
        raise OSError("lookup failed too")

    async def delete_saved(**row):
        raise OSError("delete failed too")

    fakes.save_recovered = save_recovered
    fakes.find_saved = find_saved
    fakes.delete_saved = delete_saved
    manifest, segment = _bundle(tmp_path)

    with pytest.raises(ConnectionError, match="connection lost"):
        await fakes.segment_ingest().recover(manifest=manifest, segment=segment, session_dir=tmp_path)


async def test_a_recovery_with_the_audio_gone_runs_no_collaborator(tmp_path):
    fakes = Collaborators()
    manifest, segment = _bundle(tmp_path)
    (tmp_path / segment.audio_file).unlink()

    with pytest.raises(FileNotFoundError, match="segment audio missing on disk"):
        await fakes.segment_ingest().recover(manifest=manifest, segment=segment, session_dir=tmp_path)

    assert fakes.calls == []


async def test_calendar_attendees_are_seeded_into_the_persons_the_detector_sees(tmp_path):
    existing = {"id": 3, "canonical_name": "Anna Beispiel", "first_name": "Anna"}
    fakes = Collaborators(persons=[existing])
    manifest, segment = _bundle(
        tmp_path,
        segment=_calendar_segment(
            ["max.mustermann@example.com", "anna.beispiel@example.com", "  ", "@nolocal.example", "j_doe@x.io"]
        ),
    )

    await fakes.segment_ingest().ingest(manifest=manifest, segment=segment, session_dir=tmp_path)

    snapshot = fakes.corrected[0]["snapshot"]
    assert [p["canonical_name"] for p in snapshot.persons] == ["Anna Beispiel", "Max Mustermann", "J Doe"]
    assert snapshot.persons[0] is existing
    assert snapshot.persons[1] == {
        "id": None, "canonical_name": "Max Mustermann", "first_name": "Max", "role": "",
        "department": "", "company": "", "context": "", "variations": [],
    }
    assert snapshot.terms == [{"canonical_name": "Sprint"}]


async def test_other_segment_types_and_attendee_free_events_leave_the_snapshot_alone(tmp_path):
    fakes = Collaborators(persons=[{"canonical_name": "Anna"}])
    drive_by, drive_by_segment = _bundle(tmp_path)
    event, event_segment = _bundle(tmp_path, segment=_calendar_segment([]))

    ingest = fakes.segment_ingest()
    await ingest.ingest(manifest=drive_by, segment=drive_by_segment, session_dir=tmp_path)
    await ingest.ingest(manifest=event, segment=event_segment, session_dir=tmp_path)

    assert [c["snapshot"].persons for c in fakes.corrected] == [[{"canonical_name": "Anna"}]] * 2


async def test_two_instances_use_only_their_own_collaborators(tmp_path):
    first, second = Collaborators(), Collaborators()
    manifest, segment = _bundle(tmp_path)

    await first.segment_ingest().ingest(manifest=manifest, segment=segment, session_dir=tmp_path)

    assert first.calls == ["transcribe", "snapshot", "correct", "save"]
    assert second.calls == []


async def test_unset_collaborators_default_to_the_shared_modules(monkeypatch, tmp_path):
    """Production wiring: with nothing injected, the operation resolves
    `transcript_ingest`, `dictionary`, `correction` and `db` when it runs."""
    fakes = Collaborators()
    monkeypatch.setattr(transcript_ingest, "transcribe_and_persist", fakes.transcribe)
    monkeypatch.setattr(dictionary, "load_dictionary_snapshot", fakes.load_snapshot)
    monkeypatch.setattr(correction, "correct_and_detect_entities", fakes.correct)
    monkeypatch.setattr(db, "save_detected_entities", fakes.save_entities)
    manifest, segment = _bundle(tmp_path)

    await SegmentIngest().ingest(manifest=manifest, segment=segment, session_dir=tmp_path)

    assert fakes.calls == ["transcribe", "snapshot", "correct", "save"]
