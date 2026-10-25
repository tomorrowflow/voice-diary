"""Shared transcribe-and-persist core (SRV-A7).

`main.py`'s manual `/api/ingest/upload` route and `session_ingest`'s
per-segment iOS pipeline each drove audio through ffmpeg + Whisper and then
inserted a `transcripts` row, via two separate near-identical copies of the
glue. `asr_client.AsrClient` already unified the ffmpeg/Whisper half
(SRV-A2); this module unifies the remaining "persist the result" step so
both callers share one core. Each caller keeps its own failure bookkeeping
(`ingest_uploads` table vs the `session_ingests` row) and whatever it does
next (entity detection + document_processor for sessions, the review UI for
manual uploads) — that part is intentionally not shared, it's where the two
pipelines actually differ.

`transcribe_text` is the Whisper half on its own: a transcription recovery
(FTR-02) needs the text before any row exists, so that the transcript and its
entities can be saved together.
"""

from __future__ import annotations

import logging
from dataclasses import dataclass

import asr_client
import db

logger = logging.getLogger(__name__)


@dataclass
class TranscribedSegment:
    transcript_id: int
    raw_text: str


async def transcribe_text(
    audio_bytes: bytes,
    *,
    src_suffix: str,
    filename: str,
    language: str = "de",
) -> str:
    """ffmpeg -> Whisper -> the raw transcript text; nothing is persisted.

    `filename` only names what is being transcribed in the log. Raises
    `RuntimeError` if Whisper returns an empty transcript; the ASR-specific
    errors (`AsrTimeoutError`, `AsrUnavailableError`, `AsrEngineError`)
    propagate from `asr_client` unchanged.
    """
    logger.info("transcribing %s", filename)
    client = asr_client.get_default_client()
    wav_bytes = await client.to_wav_16k_mono(audio_bytes, src_suffix)
    raw_text = await client.transcribe(wav_bytes, language=language)
    if not raw_text:
        raise RuntimeError("Whisper returned an empty transcript")
    return raw_text


async def transcribe_and_persist(
    audio_bytes: bytes,
    *,
    src_suffix: str,
    filename: str,
    date: str,
    author: str,
    language: str = "de",
) -> TranscribedSegment:
    """ffmpeg -> Whisper -> a persisted `transcripts` row.

    Raises `RuntimeError` if Whisper returns an empty transcript (nothing
    worth persisting); the ASR-specific errors (`AsrTimeoutError`,
    `AsrUnavailableError`, `AsrEngineError`) propagate from `asr_client`
    unchanged for callers to classify into their own HTTP response shape.
    """
    raw_text = await transcribe_text(
        audio_bytes, src_suffix=src_suffix, filename=filename, language=language,
    )
    transcript_id = await db.create_transcript(
        filename=filename, date=date, author=author, raw_text=raw_text,
    )
    return TranscribedSegment(transcript_id=transcript_id, raw_text=raw_text)
