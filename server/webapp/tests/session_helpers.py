"""Shared pieces for the session-ingest tests (ARCH-2, REF-126).

`session_ingest.SessionIngest` is driven through its public interface; these
helpers stub only what it talks to — `db`, `transcript_ingest`, `correction`,
`narrative` — never its own private stages:

* `fresh_ingest` — a clean session ingest over an in-memory session-ingest
  repository (REF-122/#122), installed as the process-wide one so the routes
  use it too;
* `FakeSessionIngests` — rows for that repository's `session_ingests` table;
* `SegmentPipeline` — phase 1 (Whisper, correction, entity persistence) with
  the shared modules stubbed, behind the real `SegmentIngest`;
* `RecordingSegmentOperation` — a segment operation handed to one
  `SessionIngest` through `fresh_ingest(segment_operation=...)`;
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
import session_ingest
import transcript_ingest
from dictionary import DictionarySnapshot
from models import Manifest
from segment_ingest import SegmentArtifact, SegmentOperation
from session_repository import InMemorySessionIngests

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


class RecordingIngests(InMemorySessionIngests):
    """The in-memory session-ingest adapter, noting each row operation so a
    test can assert what was persisted and in which order: `updates` lists
    every transition as `(state, segments)`, `fetched` every row read, `listed`
    every sweep listing. A test can make the store fail (`update_error`,
    `list_error`, `correct_error`) or run code when a row is inserted
    (`on_insert`)."""

    def __init__(self) -> None:
        super().__init__()
        self.updates: list[tuple[str, list[dict]]] = []
        self.created: list[tuple] = []
        self.deleted: list[str] = []
        self.failed: list[str] = []
        self.fetched: list[str] = []
        self.listed: list[list[str]] = []
        self.update_error: BaseException | None = None
        self.list_error: BaseException | None = None
        self.correct_error: BaseException | None = None
        self.on_insert: Callable[[str], Awaitable[None]] | None = None

    @property
    def cached_ids(self) -> set[str]:
        return set(self._cache)

    async def _insert(self, session_id, received_at, state, segments) -> None:
        self.created.append((session_id, received_at, state, segments))
        if self.on_insert is not None:
            await self.on_insert(session_id)
        await super()._insert(session_id, received_at, state, segments)

    async def _update(self, session_id, state, segments) -> None:
        if self.update_error is not None:
            raise self.update_error
        self.updates.append((state, segments))
        await super()._update(session_id, state, segments)

    async def _set_failed(self, session_id) -> None:
        self.failed.append(session_id)
        await super()._set_failed(session_id)

    async def _fetch(self, session_id) -> dict | None:
        self.fetched.append(session_id)
        return await super()._fetch(session_id)

    async def _delete(self, session_id) -> None:
        self.deleted.append(session_id)
        await super()._delete(session_id)

    async def _list_sweep_candidates(self) -> list[str]:
        if self.list_error is not None:
            raise self.list_error
        self.listed.append(await super()._list_sweep_candidates())
        return self.listed[-1]

    async def _correct_legacy_done(self) -> int:
        if self.correct_error is not None:
            raise self.correct_error
        return await super()._correct_legacy_done()


class RecordingSegmentOperation:
    """A `SessionIngest` segment operation (ARCH-3) that never touches a
    collaborator: it hands out `transcript_ids[segment_id]` or raises
    `failing[segment_id]`, and notes each call as `(session_id, segment_id)`
    in `calls`. The artifact's text is `text-{transcript_id}`."""

    def __init__(
        self,
        transcript_ids: dict[str, int],
        *,
        failing: dict[str, BaseException] | None = None,
    ):
        self.calls: list[tuple[str, str]] = []
        self._ids = transcript_ids
        self._failing = failing or {}

    async def __call__(self, *, manifest, segment, session_dir) -> SegmentArtifact:
        self.calls.append((manifest.session_id, segment.segment_id))
        if segment.segment_id in self._failing:
            raise self._failing[segment.segment_id]
        transcript_id = self._ids[segment.segment_id]
        return SegmentArtifact(
            segment=segment, transcript_id=transcript_id,
            raw_text=f"raw-{transcript_id}", corrected_text=f"text-{transcript_id}",
        )


def fresh_ingest(
    monkeypatch,
    *,
    whisper_up=True,
    repository: RecordingIngests | None = None,
    segment_operation: SegmentOperation | None = None,
) -> session_ingest.SessionIngest:
    """A clean `SessionIngest` over an in-memory repository, installed as the
    process-wide one (what the routes and `main.py` use). `whisper_up` is a
    bool, or a callable returning one to change it mid-test. Passing the
    `repository` of an earlier session ingest models a restart: the rows stay,
    the status cache and the in-flight claims are gone. `segment_operation`
    replaces the real per-segment operation for this ingest alone."""
    monkeypatch.setenv("IOS_BEARER_TOKEN", BEARER)

    async def whisper_reachable() -> bool:
        return whisper_up() if callable(whisper_up) else whisper_up

    if repository is not None:
        repository.restart()
    ingest = session_ingest.SessionIngest(
        whisper_reachable=whisper_reachable,
        repository=repository if repository is not None else RecordingIngests(),
        segment_operation=segment_operation,
    )
    monkeypatch.setattr(session_ingest, "_default", ingest)
    # No test reaches the database: a reset only clears the tables `db` owns.
    monkeypatch.setattr(db, "reset_all_data", _no_database_reset)
    if not getattr(db.list_transcripts, "keeps_pipeline_table", False):
        # Over a restart, the `SegmentPipeline` table stays.
        monkeypatch.setattr(db, "list_transcripts", _no_database_transcripts)
    return ingest


async def _no_database_reset() -> None:
    return None


async def _no_database_transcripts(status=None) -> list[dict]:
    return []


class FakeSessionIngests:
    """Rows for the `session_ingests` table, held by the in-memory adapter.
    `row` is the row of the session it was built for; `add` puts more sessions
    in; `install` makes the session ingest from `fresh_ingest` use them. The
    adapter's `updates`, `created`, `deleted` and `failed` are readable here."""

    def __init__(self, session_id: str, state: str, segments: list[dict]):
        self.session_id = session_id
        self.repository = RecordingIngests()
        self.add(session_id, state, segments)

    @classmethod
    def empty(cls, session_id: str) -> "FakeSessionIngests":
        ingests = cls(session_id, "processing", [])
        del ingests.rows[session_id]
        return ingests

    @property
    def rows(self) -> dict[str, dict]:
        return self.repository.rows

    @property
    def updates(self) -> list[tuple[str, list[dict]]]:
        return self.repository.updates

    @property
    def created(self) -> list[tuple]:
        return self.repository.created

    @property
    def deleted(self) -> list[str]:
        return self.repository.deleted

    @property
    def failed(self) -> list[str]:
        return self.repository.failed

    @property
    def row(self) -> dict | None:
        return self.rows.get(self.session_id)

    def add(self, session_id: str, state: str, segments: list[dict]) -> None:
        self.repository.rows[session_id] = {
            "session_id": session_id,
            "received_at": "2026-07-01T10:00:00Z",
            "state": state,
            "segments": segments,
        }

    def install(self) -> "FakeSessionIngests":
        """Hand these rows to the session ingest `fresh_ingest` installed, so
        call it first."""
        ingest = session_ingest._default
        assert ingest is not None and isinstance(ingest.repository, RecordingIngests)
        ingest.repository = self.repository
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
    session_dir = session_ingest.session_dir_for(session_id)
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
    ).install()

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
        # The `transcripts` table as far as the pipeline touches it, by file
        # name (unique per date, like the real index): a plain insert over an
        # existing row fails, the recovery's one-statement save replaces it in
        # place and keeps its id. `save_entities_error` makes the write of the
        # entities (or of the whole recovered transcript) fail.
        self.transcript_rows: dict[str, int] = {}
        self.save_entities_error: BaseException | None = None
        # A recovery's one-statement save that commits but whose result is
        # lost (`lose_save_result`); `find_error` makes the follow-up lookup of
        # what was saved fail too, `delete_error` the compensating delete after
        # it. `recovered_values` is what each row holds.
        self.lose_save_result = False
        self.find_error: BaseException | None = None
        self.delete_error: BaseException | None = None
        self.recovered_values: dict[str, tuple] = {}
        self._ids = transcript_ids or {}
        self.failing = failing or {}

        def segment_of(filename: str) -> str:
            return filename.split("::", 1)[1].rsplit(".", 1)[0]

        async def transcribe_and_persist(
            audio_bytes, *, src_suffix, filename, date, author, language="de",
        ):
            segment_id = segment_of(filename)
            self.transcribe_calls.append({
                "audio_bytes": audio_bytes, "src_suffix": src_suffix, "filename": filename,
                "date": date, "author": author, "language": language,
            })
            if segment_id in self.failing:
                raise self.failing[segment_id]
            if filename in self.transcript_rows:
                raise RuntimeError("duplicate key value violates idx_transcripts_filename_date")
            transcript_id = self._ids.setdefault(segment_id, 10 + len(self._ids))
            self.transcript_rows[filename] = transcript_id
            return transcript_ingest.TranscribedSegment(transcript_id=transcript_id, raw_text="hallo welt")

        async def transcribe_text(audio_bytes, *, src_suffix, filename, language="de"):
            self.transcribe_calls.append({
                "audio_bytes": audio_bytes, "src_suffix": src_suffix, "filename": filename,
                "language": language,
            })
            if segment_of(filename) in self.failing:
                raise self.failing[segment_of(filename)]
            return "hallo welt"

        async def save_recovered_transcript(
            *, filename, date, author, raw_text, corrected_text, detected_entities_json
        ):
            if self.save_entities_error is not None:
                raise self.save_entities_error
            transcript_id = self._ids.setdefault(segment_of(filename), 10 + len(self._ids))
            self.transcript_rows[filename] = transcript_id
            self.saved_entities.append((transcript_id, corrected_text, detected_entities_json))
            self.recovered_values[filename] = (raw_text, corrected_text, detected_entities_json)
            if self.lose_save_result:
                # Committed, but the answer never reaches the caller.
                raise ConnectionError("connection lost before the result arrived")
            return transcript_id

        async def find_saved_transcript(
            *, filename, date, raw_text, corrected_text, detected_entities_json
        ):
            if self.find_error is not None:
                raise self.find_error
            if self.recovered_values.get(filename) == (
                raw_text, corrected_text, detected_entities_json,
            ):
                return self.transcript_rows.get(filename)
            return None

        async def delete_saved_transcript(
            *, filename, date, raw_text, corrected_text, detected_entities_json
        ):
            if self.delete_error is not None:
                raise self.delete_error
            if self.recovered_values.get(filename) == (
                raw_text, corrected_text, detected_entities_json,
            ):
                self.transcript_rows.pop(filename, None)
                self.recovered_values.pop(filename, None)
                return True
            return False

        async def find_recovered_transcript(*, filename, date):
            # Only a row written with its entities (the recovery's save) counts.
            if filename in self.recovered_values:
                return self.transcript_rows.get(filename)
            return None

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
            if self.save_entities_error is not None:
                raise self.save_entities_error
            self.saved_entities.append((transcript_id, text, detected_entities_json))

        async def delete_transcripts(ids):
            self.transcript_rows = {
                name: row_id for name, row_id in self.transcript_rows.items() if row_id not in ids
            }

        async def list_transcripts(status=None):
            return [
                {"id": row_id, "filename": name} for name, row_id in self.transcript_rows.items()
            ]

        list_transcripts.keeps_pipeline_table = True
        monkeypatch.setattr(db, "list_transcripts", list_transcripts)
        monkeypatch.setattr(db, "delete_transcripts", delete_transcripts)
        monkeypatch.setattr(db, "save_recovered_transcript", save_recovered_transcript)
        monkeypatch.setattr(db, "find_saved_transcript", find_saved_transcript)
        monkeypatch.setattr(db, "delete_saved_transcript", delete_saved_transcript)
        monkeypatch.setattr(db, "find_recovered_transcript", find_recovered_transcript)
        monkeypatch.setattr(transcript_ingest, "transcribe_text", transcribe_text)
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
    awaited as analysis starts; `latch()` makes analysis block until released.
    `real_narrative=True` keeps the real `narrative.build_day_narrative`, so the
    caller's `document_processor` stubs / injected LLM transport take effect."""

    def __init__(self, monkeypatch, *, real_narrative: bool = False):
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

        if not real_narrative:
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

    def fake_build_document_metadata(enriched, *, route="local"):
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
