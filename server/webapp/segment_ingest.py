"""Segment ingest (ARCH-3): the operation `SessionIngest` runs for each segment
of a session, in the original ingest and when it resumes a stored bundle.

`SegmentIngest.ingest` reads the segment's audio, transcribes and persists it
(`transcript_ingest`, shared with `/api/ingest/upload`), loads the dictionary
snapshot, seeds a calendar event's attendees into its persons, runs the
non-interactive correction chain shared with the HTMX review flow
(`correction`, #51) and persists the detected entities. It returns the
`SegmentArtifact` the day narrative is built from, and raises on any failure:
what a failed segment means for the session is `SessionIngest`'s call.

Each collaborator is a constructor argument; one left unset resolves the
shared module's function when `ingest` runs. Two instances never share
dependencies.
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


class SegmentIngest:
    """The per-segment operation, over its own collaborators: `transcribe`
    (Whisper + persisted transcript), `load_snapshot` (dictionary), `correct`
    (correction + entity detection), `save_entities` and, for a recovery,
    `delete_transcripts`. A collaborator left unset is the shared module's
    function, looked up on each `ingest`."""

    def __init__(
        self,
        *,
        transcribe: Callable[..., Awaitable[transcript_ingest.TranscribedSegment]] | None = None,
        load_snapshot: Callable[[], Awaitable[dictionary.DictionarySnapshot]] | None = None,
        correct: Callable[..., Awaitable[correction.CorrectionResult]] | None = None,
        save_entities: Callable[[int, str, str], Awaitable[object]] | None = None,
        delete_transcripts: Callable[[list[int]], Awaitable[object]] | None = None,
    ) -> None:
        self._transcribe = transcribe
        self._load_snapshot = load_snapshot
        self._correct = correct
        self._save_entities = save_entities
        self._delete_transcripts = delete_transcripts

    async def ingest(
        self, *, manifest: Manifest, segment: Segment, session_dir: Path
    ) -> SegmentArtifact:
        """Per-segment pipeline up to entity detection.

        Returns an artifact with the persisted transcript ID and detected
        entities. Document analysis + LightRAG ingest happen once per run in
        `SessionIngest`'s narrative stage.
        """
        return await self._run(manifest, segment, session_dir, recovering=False)

    async def recover(
        self, *, manifest: Manifest, segment: Segment, session_dir: Path
    ) -> SegmentArtifact:
        """The same pipeline for a transcription recovery (ADR 0005): it
        reuses the transcript row an earlier attempt left behind (transcripts
        are unique per file name and date) and, when a step after Whisper
        fails, deletes the row it just wrote, so a failed attempt leaves no
        orphan and the next one starts clean."""
        return await self._run(manifest, segment, session_dir, recovering=True)

    async def _run(
        self, manifest: Manifest, segment: Segment, session_dir: Path, *, recovering: bool
    ) -> SegmentArtifact:
        transcribe = self._transcribe or transcript_ingest.transcribe_and_persist
        load_snapshot = self._load_snapshot or dictionary.load_dictionary_snapshot
        correct = self._correct or correction.correct_and_detect_entities
        save_entities = self._save_entities or db.save_detected_entities

        audio_path = session_dir / segment.audio_file
        if not audio_path.exists():
            raise FileNotFoundError(f"segment audio missing on disk: {segment.audio_file}")
        audio_bytes = audio_path.read_bytes()
        language = (segment.language or "de").split("-")[0]

        # 1-2. ffmpeg → Whisper → persisted transcript row, via the core shared
        # with main.py's /api/ingest/upload (SRV-A7).
        suffix = Path(segment.audio_file).suffix
        # Only a recovery passes `replace_existing`, so the original ingest and
        # the resume of a stored bundle call the collaborator as they always did.
        persistence = {"replace_existing": True} if recovering else {}
        transcribed = await transcribe(
            audio_bytes,
            src_suffix=suffix or ".m4a",
            filename=f"{manifest.session_id}::{segment.segment_id}{suffix}",
            date=manifest.date.isoformat(),
            author="Lukas Brandt",
            language=language,
            **persistence,
        )
        try:
            return await self._after_transcription(
                segment, transcribed, load_snapshot, correct, save_entities
            )
        except Exception:
            if recovering:
                await self._discard_transcript(transcribed.transcript_id)
            raise

    async def _after_transcription(
        self, segment: Segment, transcribed, load_snapshot, correct, save_entities
    ) -> SegmentArtifact:
        transcript_id = transcribed.transcript_id
        raw_transcript = transcribed.raw_text

        # 3-4. Dictionary corrections → vector few-shot LLM correction (falls
        # back to the pre-LLM text on failure) → entity detection → dismissal
        # filtering — the same non-interactive chain the HTMX review flow runs
        # (#51). For calendar_event segments we additionally seed the persons
        # dict with the manifest's canonical attendee names so the detector
        # resolves them deterministically (Graph already gave us the truth — no
        # need to fuzzy-match again).
        snapshot = await load_snapshot()
        if isinstance(segment, CalendarEventSegment):
            seed_persons = attendees_to_canonical_names(segment.calendar_ref.attendees)
            if seed_persons:
                snapshot = replace(
                    snapshot,
                    persons=_seed_persons_into_dict(snapshot.persons, seed_persons),
                )

        result = await correct(raw_transcript, snapshot=snapshot)
        corrected_text = result.corrected_text

        # Convert dataclass instances to dicts in the shape document_processor
        # expects (the HTMX review flow stores `text` for the canonical name).
        entities: list[dict] = []
        for d in result.entities:
            item = d.to_dict()
            item["text"] = d.canonical or d.original_text
            item["type"] = d.entity_type
            entities.append(item)

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


    async def _discard_transcript(self, transcript_id: int) -> None:
        """Best effort: a row that cannot be deleted is reused by the next
        recovery attempt, so a failure here is logged, not raised over the
        error that made the attempt fail."""
        delete = self._delete_transcripts or db.delete_transcripts
        try:
            await delete([transcript_id])
        except Exception:  # noqa: BLE001
            logger.warning("could not delete transcript %s after a failed recovery", transcript_id)


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
