"""Tests for `transcript_ingest.transcribe_and_persist` (SRV-A7).

`main.py`'s `/api/ingest/upload` and `routers/sessions.py`'s per-segment
pipeline both drove their own copy of "ffmpeg -> Whisper -> insert
`transcripts` row". This module is the shared core; these tests pin its
behavior against a fake `AsrClient` and a monkeypatched `db.create_transcript`
so no real ffmpeg/Whisper/Postgres is needed.
"""

from __future__ import annotations

import asyncio

import pytest

import asr_client
import db
from transcript_ingest import transcribe_and_persist


class _FakeAsrClient:
    def __init__(self, *, wav: bytes = b"WAV", text: str = "hallo welt"):
        self.wav = wav
        self.text = text
        self.to_wav_calls: list[tuple[bytes, str]] = []
        self.transcribe_calls: list[tuple[bytes, str]] = []

    async def to_wav_16k_mono(self, src_bytes: bytes, src_suffix: str) -> bytes:
        self.to_wav_calls.append((src_bytes, src_suffix))
        return self.wav

    async def transcribe(self, wav_bytes: bytes, *, language: str = "de") -> str:
        self.transcribe_calls.append((wav_bytes, language))
        return self.text


def test_transcribe_and_persist_returns_transcript_id_and_raw_text(monkeypatch):
    fake_client = _FakeAsrClient(text="hallo welt")
    monkeypatch.setattr(asr_client, "get_default_client", lambda: fake_client)

    created = []

    async def fake_create_transcript(filename, date, author, raw_text):
        created.append((filename, date, author, raw_text))
        return 42

    monkeypatch.setattr(db, "create_transcript", fake_create_transcript)

    result = asyncio.run(
        transcribe_and_persist(
            b"raw-audio-bytes",
            src_suffix=".m4a",
            filename="session::seg01.m4a",
            date="2026-07-04",
            author="Florian Wolf",
            language="de",
        )
    )

    assert result.transcript_id == 42
    assert result.raw_text == "hallo welt"
    assert fake_client.to_wav_calls == [(b"raw-audio-bytes", ".m4a")]
    assert fake_client.transcribe_calls == [(fake_client.wav, "de")]
    assert created == [("session::seg01.m4a", "2026-07-04", "Florian Wolf", "hallo welt")]


def test_transcribe_and_persist_raises_on_empty_transcript(monkeypatch):
    fake_client = _FakeAsrClient(text="")
    monkeypatch.setattr(asr_client, "get_default_client", lambda: fake_client)

    async def fail_create_transcript(*args, **kwargs):
        raise AssertionError("should not persist an empty transcript")

    monkeypatch.setattr(db, "create_transcript", fail_create_transcript)

    with pytest.raises(RuntimeError):
        asyncio.run(
            transcribe_and_persist(
                b"raw-audio-bytes",
                src_suffix=".m4a",
                filename="session::seg01.m4a",
                date="2026-07-04",
                author="Florian Wolf",
            )
        )
