"""Shared pieces for the session-processing tests (ARCH-2).

`session_processing.SessionProcessor` is driven through its public interface;
these helpers stub only what it talks to — `db`, `transcript_ingest`,
`correction`, `narrative` — never its own private stages:

* `fresh_processor` — a clean processor, installed as the process-wide one so
  the routes use it too;
* `FakeSessionIngests` — the `session_ingests` table;
* `SegmentPipeline` — phase 1 (Whisper, correction, entity persistence);
* `NarrativeStage` — phase 2 (analysis, LightRAG) with in-memory
  `processed_documents`;
* `stage_bundle` / `stage_pending_session` — a bundle on disk / a persisted
  session stuck in `pending_analysis`.
"""

from __future__ import annotations

import asyncio
import json
from pathlib import Path
from typing import Awaitable, Callable

import correction
import db
import dictionary
import narrative
import session_processing
import transcript_ingest
from dictionary import DictionarySnapshot
from models import Manifest

BEARER = "test-token"


def auth() -> dict:
    return {"Authorization": f"Bearer {BEARER}"}


def manifest_dict(session_id: str) -> dict:
    return {
        "session_id": session_id,
        "date": "2026-07-01",
        "device": "iPhone17,2",
        "app_version": "1.0",
        "audio_codec": {
            "codec": "aac-lc",
            "sample_rate": 16000,
            "channels": 1,
            "bitrate": 64000,
        },
        "segments": [
            {
                "segment_id": "s01",
                "segment_type": "drive_by",
                "audio_file": "segments/s01.m4a",
                "captured_at": "2026-07-01T10:00:00Z",
            }
        ],
    }


def two_segment_manifest(session_id: str) -> dict:
    manifest = manifest_dict(session_id)
    manifest["segments"].append(
        {
            "segment_id": "s02",
            "segment_type": "drive_by",
            "audio_file": "segments/s02.m4a",
            "captured_at": "2026-07-01T11:00:00Z",
        }
    )
    return manifest


def bundle(session_id: str) -> list[tuple]:
    """Multipart `files=` for `POST /api/sessions`."""
    manifest = json.dumps(manifest_dict(session_id)).encode()
    return [
        ("manifest", ("manifest.json", manifest, "application/json")),
        ("segments/s01.m4a", ("s01.m4a", b"fake-audio-bytes", "audio/mp4")),
    ]


def segment_row(
    segment_id: str, status: str, transcript_id: int | None = None, error: str | None = None,
    code: str | None = None, upstream: str | None = None,
):
    return {
        "segment_id": segment_id, "status": status, "transcript_id": transcript_id,
        "error": error, "code": code, "upstream": upstream,
    }


def fresh_processor(monkeypatch, *, whisper_up=True) -> session_processing.SessionProcessor:
    """A clean `SessionProcessor`, installed as the process-wide one (what the
    routes and `main.py` use). `whisper_up` is a bool, or a callable returning
    one to change it mid-test."""
    monkeypatch.setenv("IOS_BEARER_TOKEN", BEARER)

    async def whisper_reachable() -> bool:
        return whisper_up() if callable(whisper_up) else whisper_up

    processor = session_processing.SessionProcessor(whisper_reachable=whisper_reachable)
    monkeypatch.setattr(session_processing, "_default", processor)
    return processor


class FakeSessionIngests:
    """In-memory stand-in for the `session_ingests` table. `row` is the row of
    the session it was built for; `add` puts more sessions in. `updates` lists
    every `update_session_status` as `(state, segments)`."""

    def __init__(self, session_id: str, state: str, segments: list[dict]):
        self.session_id = session_id
        self.rows: dict[str, dict] = {}
        self.add(session_id, state, segments)
        self.updates: list[tuple[str, list[dict]]] = []
        self.created: list[tuple] = []
        self.deleted: list[str] = []
        self.failed: list[str] = []

    @classmethod
    def empty(cls, session_id: str) -> "FakeSessionIngests":
        ingests = cls(session_id, "processing", [])
        del ingests.rows[session_id]
        return ingests

    @property
    def row(self) -> dict | None:
        return self.rows.get(self.session_id)

    def add(self, session_id: str, state: str, segments: list[dict]) -> None:
        self.rows[session_id] = {
            "session_id": session_id,
            "received_at": "2026-07-01T10:00:00Z",
            "state": state,
            "segments": segments,
        }

    def install(self, monkeypatch) -> "FakeSessionIngests":
        async def get_session_status(sid: str) -> dict | None:
            return self.rows.get(sid)

        async def create_session_status(session_id, received_at, state, segments) -> None:
            self.created.append((session_id, received_at, state, segments))
            self.rows[session_id] = {
                "session_id": session_id, "received_at": received_at,
                "state": state, "segments": segments,
            }

        async def update_session_status(session_id: str, state: str, segments: list[dict]) -> None:
            self.rows[session_id] = {**self.rows[session_id], "state": state, "segments": segments}
            self.updates.append((state, segments))

        async def delete_session_status(session_id: str) -> None:
            self.deleted.append(session_id)
            self.rows.pop(session_id, None)

        async def mark_session_failed(session_id: str) -> None:
            self.failed.append(session_id)

        async def list_pending_analysis_session_ids() -> list[str]:
            return [
                sid for sid, row in self.rows.items()
                if row["state"] == "processing"
                or (row["state"] != "done"
                    and any(seg["status"] == "pending_analysis" for seg in row["segments"]))
            ]

        async def correct_legacy_done_sessions() -> int:
            legacy = [
                row for row in self.rows.values()
                if row["state"] == "done"
                and any(seg["status"] == "pending_analysis" for seg in row["segments"])
            ]
            for row in legacy:
                row["state"] = "partial"
            return len(legacy)

        monkeypatch.setattr(db, "get_session_status", get_session_status)
        monkeypatch.setattr(db, "create_session_status", create_session_status)
        monkeypatch.setattr(db, "update_session_status", update_session_status)
        monkeypatch.setattr(db, "delete_session_status", delete_session_status)
        monkeypatch.setattr(db, "mark_session_failed", mark_session_failed)
        monkeypatch.setattr(db, "list_pending_analysis_session_ids", list_pending_analysis_session_ids)
        monkeypatch.setattr(db, "correct_legacy_done_sessions", correct_legacy_done_sessions)
        return self


def stub_transcripts(monkeypatch, transcript_ids, *, entities_json=None) -> None:
    """Persisted transcript rows for `transcript_ids`; `db.get_transcript`
    returns `None` for any other id. Each row's text is `text-{id}`."""
    ids = set(transcript_ids)

    async def get_transcript(transcript_id: int) -> dict | None:
        if transcript_id not in ids:
            return None
        return {
            "id": transcript_id, "raw_text": f"raw-{transcript_id}",
            "corrected_text": f"text-{transcript_id}", "entities_json": entities_json,
        }

    monkeypatch.setattr(db, "get_transcript", get_transcript)


def stage_bundle(monkeypatch, tmp_path, session_id: str, manifest: dict | None = None) -> tuple[Manifest, Path]:
    """Write a session bundle (manifest + a stub audio file per segment) under
    `DATA_DIR`; returns the parsed manifest and the session directory."""
    monkeypatch.setenv("DATA_DIR", str(tmp_path))
    manifest = manifest if manifest is not None else manifest_dict(session_id)
    session_dir = session_processing.session_dir_for(session_id)
    session_dir.mkdir(parents=True)
    (session_dir / "manifest.json").write_text(json.dumps(manifest))
    parsed = Manifest.model_validate(manifest)
    for seg in parsed.segments:
        audio = session_dir / seg.audio_file
        audio.parent.mkdir(parents=True, exist_ok=True)
        audio.write_bytes(b"fake-audio")
    return parsed, session_dir


def stage_pending_session(monkeypatch, tmp_path, session_id: str) -> FakeSessionIngests:
    """A persisted single-segment `pending_analysis` session (transcript 5)
    with its bundle on disk, ready for a retry."""
    stage_bundle(monkeypatch, tmp_path, session_id)
    ingests = FakeSessionIngests(
        session_id, "partial",
        [segment_row("s01", "pending_analysis", 5, "analysis_pending: first failure")],
    ).install(monkeypatch)

    stub_transcripts(monkeypatch, [5])
    return ingests


class SegmentPipeline:
    """Phase 1 with its collaborators stubbed: `transcribe_and_persist` hands
    out `transcript_ids[segment_id]` (default 10 + position) or raises
    `failing[segment_id]`; correction leaves the text unchanged unless
    `correct` is given; the dictionaries are empty unless overridden."""

    def __init__(
        self,
        monkeypatch,
        *,
        transcript_ids: dict[str, int] | None = None,
        failing: dict[str, BaseException] | None = None,
        correct=None,
        persons: list | None = None,
        terms: list | None = None,
        text_corrections: list | None = None,
        dismissals: list | None = None,
    ):
        self.transcribe_calls: list[dict] = []
        self.correct_calls: list[dict] = []
        self.saved_entities: list[tuple] = []
        self._ids = transcript_ids or {}
        self._failing = failing or {}

        async def transcribe_and_persist(audio_bytes, *, src_suffix, filename, date, author, language="de"):
            segment_id = filename.split("::", 1)[1].rsplit(".", 1)[0]
            self.transcribe_calls.append({
                "audio_bytes": audio_bytes, "src_suffix": src_suffix, "filename": filename,
                "date": date, "author": author, "language": language,
            })
            if segment_id in self._failing:
                raise self._failing[segment_id]
            transcript_id = self._ids.setdefault(segment_id, 10 + len(self._ids))
            return transcript_ingest.TranscribedSegment(transcript_id=transcript_id, raw_text="hallo welt")

        async def correct_and_detect_entities(raw_text, *, snapshot=None, on_step=None):
            self.correct_calls.append({
                "raw_text": raw_text, "persons": snapshot.persons, "terms": snapshot.terms,
                "text_corrections": snapshot.text_corrections,
                "dismissals": sorted(snapshot.dismissals),
            })
            if correct is not None:
                return await correct(raw_text)
            return correction.CorrectionResult(corrected_text=raw_text)

        async def load_dictionary_snapshot():
            return DictionarySnapshot(
                persons=persons or [], terms=terms or [],
                text_corrections=text_corrections or [], dismissals=dismissals or [],
            )

        async def save_detected_entities(transcript_id, text, detected_entities_json):
            self.saved_entities.append((transcript_id, text, detected_entities_json))

        monkeypatch.setattr(transcript_ingest, "transcribe_and_persist", transcribe_and_persist)
        monkeypatch.setattr(correction, "correct_and_detect_entities", correct_and_detect_entities)
        monkeypatch.setattr(dictionary, "load_dictionary_snapshot", load_dictionary_snapshot)
        monkeypatch.setattr(db, "save_detected_entities", save_detected_entities)


class NarrativeStage:
    """Phase 2 with the LLM/LightRAG-bound `narrative` stage stubbed and
    `processed_documents` kept in memory (`documents[transcript_id]`).

    `runs` records each analysis (text, entities, date), `ingested` each
    LightRAG ingest, `marked` each document marked ingested. Set
    `analysis_error` (an exception, or a function of the run returning one or
    `None`) / `ingest_error` to make that step fail; `before_analysis` is
    awaited as analysis starts; `latch()` makes analysis block until released."""

    def __init__(self, monkeypatch):
        self.runs: list[dict] = []
        self.ingested: list[tuple[str, dict]] = []
        self.marked: list[int] = []
        self.documents: dict[int, dict] = {}
        self.analysis_error: BaseException | Callable[[dict], BaseException | None] | None = None
        self.ingest_error: BaseException | None = None
        self.before_analysis: Callable[[dict], Awaitable[None]] | None = None
        self._latch: tuple[asyncio.Event, asyncio.Event] | None = None

        async def build_day_narrative(text, entities, date, *, author=None, ports=None, on_step=None):
            self.runs.append({"text": text, "entities": entities, "date": date})
            if self.before_analysis is not None:
                await self.before_analysis(self.runs[-1])
            if self._latch is not None:
                started, release = self._latch
                started.set()
                await release.wait()
            error = self.analysis_error(self.runs[-1]) if callable(self.analysis_error) else self.analysis_error
            if error is not None:
                raise error
            return narrative.NarrativeResult(
                context_summary="", enriched_context={}, analysis={},
                markdown="# narrative", metadata={"date": date},
            )

        async def sync_and_ingest(markdown, metadata, *, lightrag_client=None):
            if self.ingest_error is not None:
                raise self.ingest_error
            self.ingested.append((markdown, metadata))
            return {}

        async def save_processed_document(
            *, transcript_id, document_markdown, analysis_json, context_summary, metadata
        ):
            doc_id = 100 + transcript_id
            self.documents[transcript_id] = {
                "id": doc_id, "document_markdown": document_markdown,
                "metadata": metadata, "lightrag_ingested": False,
            }
            return {"id": doc_id, "version": 1, "created_at": None}

        async def get_latest_processed_document(transcript_id: int) -> dict | None:
            return self.documents.get(transcript_id)

        async def mark_document_ingested(doc_id: int):
            self.marked.append(doc_id)
            for doc in self.documents.values():
                if doc["id"] == doc_id:
                    doc["lightrag_ingested"] = True
            return {"id": doc_id, "lightrag_ingested_at": None}

        monkeypatch.setattr(narrative, "build_day_narrative", build_day_narrative)
        monkeypatch.setattr(narrative, "sync_and_ingest", sync_and_ingest)
        monkeypatch.setattr(db, "save_processed_document", save_processed_document)
        monkeypatch.setattr(db, "get_latest_processed_document", get_latest_processed_document)
        monkeypatch.setattr(db, "mark_document_ingested", mark_document_ingested)

    def latch(self) -> tuple[asyncio.Event, asyncio.Event]:
        """Block analysis; returns `(started, release)` events. Create inside
        the running loop."""
        self._latch = (asyncio.Event(), asyncio.Event())
        return self._latch

    def save_document(self, transcript_id: int, markdown: str, metadata: dict, *, ingested: bool = False) -> None:
        """A document an earlier run already saved for `transcript_id`."""
        self.documents[transcript_id] = {
            "id": 100 + transcript_id, "document_markdown": markdown,
            "metadata": metadata, "lightrag_ingested": ingested,
        }


def fake_document_processor_pipeline(monkeypatch, *, ingest=None):
    """For tests that run the *real* `narrative` stage: stub every
    `document_processor` step `narrative.build_day_narrative` calls before/around
    `ingest_to_lightrag` (via `narrative.sync_and_ingest`). Also stubs
    `skeleton_sync.sync_incremental` — `sync_and_ingest` calls it for real
    and there's no DB here."""
    import document_processor
    import skeleton_sync

    async def fake_query_lightrag_context(date_str, *, client=None):
        return ""

    async def fake_query_lightrag_entity_history(names, date_str, *, client=None):
        return ""

    async def fake_summarize_context(recent_ctx, entity_hist, date_str, *, transport=None):
        return ""

    def fake_build_enriched_context(transcript_record, entities, context_summary):
        return {}

    async def fake_analyze_transcript(enriched, *, transport=None):
        return {}

    def fake_generate_narrative_document(enriched, analysis):
        return "# narrative"

    def fake_build_document_metadata(enriched):
        return {}

    async def fake_sync_incremental(triggered_by: str):
        return skeleton_sync.SyncStats()

    monkeypatch.setattr(document_processor, "query_lightrag_context", fake_query_lightrag_context)
    monkeypatch.setattr(document_processor, "query_lightrag_entity_history", fake_query_lightrag_entity_history)
    monkeypatch.setattr(document_processor, "summarize_context", fake_summarize_context)
    monkeypatch.setattr(document_processor, "build_enriched_context", fake_build_enriched_context)
    monkeypatch.setattr(document_processor, "analyze_transcript", fake_analyze_transcript)
    monkeypatch.setattr(document_processor, "generate_narrative_document", fake_generate_narrative_document)
    monkeypatch.setattr(document_processor, "build_document_metadata", fake_build_document_metadata)
    monkeypatch.setattr(skeleton_sync, "sync_incremental", fake_sync_incremental)

    if ingest is not None:
        monkeypatch.setattr(document_processor, "ingest_to_lightrag", ingest)
