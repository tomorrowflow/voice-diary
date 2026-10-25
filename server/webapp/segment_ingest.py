"""Segment ingest (ARCH-3): the operation `SessionIngest` runs for each segment
of a session, in the original ingest, when it resumes a stored bundle and, as
`recover`, in a transcription recovery (FTR-02).

`SegmentIngest.ingest` reads the segment's audio, transcribes and persists it
(`transcript_ingest`, shared with `/api/ingest/upload`), loads the dictionary
snapshot, seeds a calendar event's attendees into its persons, runs the
non-interactive correction chain shared with the HTMX review flow
(`correction`, #51) and persists the detected entities. It returns the
`SegmentArtifact` the day narrative is built from, and raises on any failure:
what a failed segment means for the session is `SessionIngest`'s call.

`SegmentIngest.recover` runs the same chain for one failed segment, but writes
nothing until the end: Whisper and the correction chain run first, and the
transcript row, its corrected text and its entities are then saved by one
statement. A failed attempt therefore leaves no row behind, a row an earlier
attempt left (transcripts are unique per file name and date) is replaced in
place, and a segment is never linked to a transcript without its entities.

Each collaborator is a constructor argument; one left unset resolves the
shared module's function when `ingest` or `recover` runs. Two instances never
share dependencies.
"""

from __future__ import annotations

import json
import logging
import re
from dataclasses import dataclass, field, replace
from pathlib import Path
from typing import Awaitable, Callable, Protocol

import correction
import db
import dictionary
import transcript_ingest
from models import CalendarEventSegment, Manifest, Segment

logger = logging.getLogger(__name__)

_AUTHOR = "Lukas Brandt"


@dataclass
class SegmentArtifact:
    """Per-segment outputs handed off to the session-level analysis stage."""

    segment: Segment
    transcript_id: int
    raw_text: str
    corrected_text: str
    entities: list[dict] = field(default_factory=list)


class SegmentOperation(Protocol):
    """What `SessionIngest` calls per segment; `SegmentIngest.ingest` (and
    `SegmentIngest.recover` for a transcription recovery)."""

    def __call__(
        self, *, manifest: Manifest, segment: Segment, session_dir: Path
    ) -> Awaitable[SegmentArtifact]: ...


@dataclass
class _Source:
    """What a segment's audio is transcribed as."""

    audio_bytes: bytes
    suffix: str
    filename: str
    date: str
    language: str


class SegmentIngest:
    """The per-segment operation, over its own collaborators: `transcribe`
    (Whisper + persisted transcript), `load_snapshot` (dictionary), `correct`
    (correction + entity detection) and `save_entities` for `ingest`;
    `transcribe_text` (Whisper only), `load_snapshot`, `correct`,
    `save_recovered` (transcript and entities in one write) and `find_saved`
    (did a failed write commit anyway?) for `recover`. A
    collaborator left unset is the shared module's function, looked up on
    each call."""

    def __init__(
        self,
        *,
        transcribe: Callable[..., Awaitable[transcript_ingest.TranscribedSegment]] | None = None,
        load_snapshot: Callable[[], Awaitable[dictionary.DictionarySnapshot]] | None = None,
        correct: Callable[..., Awaitable[correction.CorrectionResult]] | None = None,
        save_entities: Callable[[int, str, str], Awaitable[object]] | None = None,
        transcribe_text: Callable[..., Awaitable[str]] | None = None,
        save_recovered: Callable[..., Awaitable[int]] | None = None,
        find_saved: Callable[..., Awaitable[int | None]] | None = None,
    ) -> None:
        self._transcribe = transcribe
        self._load_snapshot = load_snapshot
        self._correct = correct
        self._save_entities = save_entities
        self._transcribe_text = transcribe_text
        self._save_recovered = save_recovered
        self._find_saved_transcript = find_saved

    async def ingest(
        self, *, manifest: Manifest, segment: Segment, session_dir: Path
    ) -> SegmentArtifact:
        """Per-segment pipeline up to entity detection.

        Returns an artifact with the persisted transcript ID and detected
        entities. Document analysis + LightRAG ingest happen once per run in
        `SessionIngest`'s narrative stage.
        """
        transcribe = self._transcribe or transcript_ingest.transcribe_and_persist
        save_entities = self._save_entities or db.save_detected_entities

        source = _read_source(manifest, segment, session_dir)

        # 1-2. ffmpeg → Whisper → persisted transcript row, via the core shared
        # with main.py's /api/ingest/upload (SRV-A7).
        transcribed = await transcribe(
            source.audio_bytes,
            src_suffix=source.suffix or ".m4a",
            filename=source.filename,
            date=source.date,
            author=_AUTHOR,
            language=source.language,
        )
        transcript_id = transcribed.transcript_id
        raw_transcript = transcribed.raw_text

        corrected_text, entities = await self._correct_and_detect(segment, raw_transcript)

        # Always persist, even when correction left the text unchanged —
        # otherwise the detected entities are lost and a retry-analysis (#52)
        # rebuilding the session narrative from Postgres would see none. Goes to
        # `detected_entities_json`, not `save_draft`: status='saved' and
        # `entities_json` are reserved for human review (BUG-55), and the review
        # page skips SSE processing for transcripts that carry them.
        await save_entities(transcript_id, corrected_text, json.dumps(entities))

        return SegmentArtifact(
            segment=segment,
            transcript_id=transcript_id,
            raw_text=raw_transcript,
            corrected_text=corrected_text,
            entities=entities,
        )

    async def recover(
        self, *, manifest: Manifest, segment: Segment, session_dir: Path
    ) -> SegmentArtifact:
        """The pipeline of a transcription recovery (ADR 0005): Whisper, then
        the correction chain, then one write of the transcript and its
        entities, replacing a row an earlier attempt left. Nothing is written
        before that last step, so any failure leaves nothing behind."""
        transcribe_text = self._transcribe_text or transcript_ingest.transcribe_text
        save_recovered = self._save_recovered or db.save_recovered_transcript

        source = _read_source(manifest, segment, session_dir)

        raw_transcript = await transcribe_text(
            source.audio_bytes,
            src_suffix=source.suffix or ".m4a",
            filename=source.filename,
            language=source.language,
        )
        corrected_text, entities = await self._correct_and_detect(segment, raw_transcript)
        saved = dict(
            filename=source.filename,
            date=source.date,
            raw_text=raw_transcript,
            corrected_text=corrected_text,
            detected_entities_json=json.dumps(entities),
        )
        try:
            transcript_id = await save_recovered(author=_AUTHOR, **saved)
        except Exception as save_error:
            # The statement may have committed before its result was lost. If
            # the row holds exactly what was being saved, it is this attempt's
            # transcript: return it so it gets linked rather than orphaned.
            transcript_id = await self._find_saved(saved)
            if transcript_id is None:
                raise save_error from None
            logger.warning(
                "saving transcript %s: the result was lost but the row was saved (%s)",
                source.filename, save_error,
            )

        return SegmentArtifact(
            segment=segment,
            transcript_id=transcript_id,
            raw_text=raw_transcript,
            corrected_text=corrected_text,
            entities=entities,
        )

    async def _find_saved(self, saved: dict) -> int | None:
        """The id of the row a failed save may have written, or None when
        there is none or the lookup itself fails (the save's own error is then
        what the caller raises; a leftover row is replaced by the next attempt)."""
        find_saved = self._find_saved_transcript or db.find_saved_transcript
        try:
            return await find_saved(**saved)
        except Exception:  # noqa: BLE001
            logger.exception("could not tell whether the transcript %s was saved", saved["filename"])
            return None

    async def _correct_and_detect(
        self, segment: Segment, raw_transcript: str
    ) -> tuple[str, list[dict]]:
        """Dictionary corrections → vector few-shot LLM correction (falls back
        to the pre-LLM text on failure) → entity detection → dismissal
        filtering — the same non-interactive chain the HTMX review flow runs
        (#51). For calendar_event segments we additionally seed the persons
        dict with the manifest's canonical attendee names so the detector
        resolves them deterministically (Graph already gave us the truth — no
        need to fuzzy-match again).

        Returns the corrected text and the entities as dicts in the shape
        document_processor expects (the HTMX review flow stores `text` for the
        canonical name)."""
        load_snapshot = self._load_snapshot or dictionary.load_dictionary_snapshot
        correct = self._correct or correction.correct_and_detect_entities

        snapshot = await load_snapshot()
        if isinstance(segment, CalendarEventSegment):
            seed_persons = attendees_to_canonical_names(segment.calendar_ref.attendees)
            if seed_persons:
                snapshot = replace(
                    snapshot,
                    persons=_seed_persons_into_dict(snapshot.persons, seed_persons),
                )

        result = await correct(raw_transcript, snapshot=snapshot)

        entities: list[dict] = []
        for d in result.entities:
            item = d.to_dict()
            item["text"] = d.canonical or d.original_text
            item["type"] = d.entity_type
            entities.append(item)
        return result.corrected_text, entities


def _read_source(manifest: Manifest, segment: Segment, session_dir: Path) -> _Source:
    audio_path = session_dir / segment.audio_file
    if not audio_path.exists():
        raise FileNotFoundError(f"segment audio missing on disk: {segment.audio_file}")
    suffix = Path(segment.audio_file).suffix
    return _Source(
        audio_bytes=audio_path.read_bytes(),
        suffix=suffix,
        filename=f"{manifest.session_id}::{segment.segment_id}{suffix}",
        date=manifest.date.isoformat(),
        language=(segment.language or "de").split("-")[0],
    )


def attendees_to_canonical_names(attendees: list[str]) -> list[str]:
    """Strip emails to local-parts and Title-case for the entity seed list."""
    out: list[str] = []
    for entry in attendees:
        local = entry.split("@", 1)[0].strip()
        if not local:
            continue
        # `firstname.lastname` → `Firstname Lastname`
        cleaned = re.sub(r"[._]+", " ", local).strip()
        cleaned = " ".join(part.capitalize() for part in cleaned.split() if part)
        if cleaned:
            out.append(cleaned)
    return out


def _seed_persons_into_dict(
    persons_dict: list[dict], seed_names: list[str]
) -> list[dict]:
    """Ensure each calendar attendee appears in the persons dict so the
    detector resolves them on Pass 1 (exact match)."""
    existing = {(p.get("canonical_name") or "").lower() for p in persons_dict}
    augmented = list(persons_dict)
    for name in seed_names:
        if name.lower() in existing:
            continue
        first = name.split()[0] if name.split() else ""
        augmented.append({
            "id": None,
            "canonical_name": name,
            "first_name": first,
            "role": "",
            "department": "",
            "company": "",
            "context": "",
            "variations": [],
        })
        existing.add(name.lower())
    return augmented
