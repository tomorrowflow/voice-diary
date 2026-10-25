"""Tests for `transcript_ingest.transcribe_and_persist` (SRV-A7).

`main.py`'s `/api/ingest/upload` and `session_ingest`'s per-segment
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
from transcript_ingest import transcribe_and_persist, transcribe_text


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
            author="Lukas Brandt",
            language="de",
        )
    )

    assert result.transcript_id == 42
    assert result.raw_text == "hallo welt"
    assert fake_client.to_wav_calls == [(b"raw-audio-bytes", ".m4a")]
    assert fake_client.transcribe_calls == [(fake_client.wav, "de")]
    assert created == [("session::seg01.m4a", "2026-07-04", "Lukas Brandt", "hallo welt")]


def test_transcribe_text_returns_the_text_and_persists_nothing(monkeypatch):
    fake_client = _FakeAsrClient(text="hallo welt")
    monkeypatch.setattr(asr_client, "get_default_client", lambda: fake_client)

    async def fail_create_transcript(*args, **kwargs):
        raise AssertionError("transcribe_text must not write a transcripts row")

    monkeypatch.setattr(db, "create_transcript", fail_create_transcript)

    text = asyncio.run(
        transcribe_text(
            b"raw-audio-bytes", src_suffix=".m4a", filename="session::seg01.m4a", language="en",
        )
    )

    assert text == "hallo welt"
    assert fake_client.to_wav_calls == [(b"raw-audio-bytes", ".m4a")]
    assert fake_client.transcribe_calls == [(fake_client.wav, "en")]


def test_transcribe_text_raises_on_empty_transcript(monkeypatch):
    monkeypatch.setattr(asr_client, "get_default_client", lambda: _FakeAsrClient(text=""))

    with pytest.raises(RuntimeError, match="empty transcript"):
        asyncio.run(
            transcribe_text(b"raw-audio-bytes", src_suffix=".m4a", filename="session::seg01.m4a")
        )


def test_save_recovered_transcript_is_one_upsert_of_the_whole_transcript(monkeypatch):
    """The transcript, its corrected text and its entities are written by one
    statement, keyed by file name and date, so a failure leaves no row and a
    row an earlier attempt left is replaced in place."""
    calls = []

    class _Pool:
        async def fetchrow(self, query, *args):
            calls.append(("fetchrow", query, args))
            return {"id": 7}

        async def execute(self, query, *args):
            calls.append(("execute", query, args))

    async def fake_get_pool():
        return _Pool()

    monkeypatch.setattr(db, "get_pool", fake_get_pool)

    transcript_id = asyncio.run(
        db.save_recovered_transcript(
            filename="session::seg01.m4a", date="2026-07-04", author="Lukas Brandt",
            raw_text="hallo welt", corrected_text="hallo Welt",
            detected_entities_json="[]",
        )
    )

    assert transcript_id == 7
    assert [kind for kind, _, _ in calls] == ["fetchrow"]
    _, query, args = calls[0]
    assert "ON CONFLICT (filename, date) DO UPDATE" in query
    for cleared in ("entities_json = NULL", "processing_error = NULL"):
        assert cleared in query
    assert args[0] == "session::seg01.m4a"
    assert str(args[1]) == "2026-07-04"
    assert args[2:] == ("Lukas Brandt", "hallo welt", "hallo Welt", "[]")


@pytest.mark.parametrize(("row", "expected"), [({"id": 7}, 7), (None, None)])
def test_find_saved_transcript_matches_the_exact_saved_values(monkeypatch, row, expected):
    """After a save whose result was lost: the row is only ours if it holds
    exactly what was being saved."""
    queries = []

    class _Pool:
        async def fetchrow(self, query, *args):
            queries.append((query, args))
            return row

    async def fake_get_pool():
        return _Pool()

    monkeypatch.setattr(db, "get_pool", fake_get_pool)

    found = asyncio.run(
        db.find_saved_transcript(
            filename="session::seg01.m4a", date="2026-07-04", raw_text="hallo welt",
            corrected_text="hallo Welt", detected_entities_json="[]",
        )
    )

    assert found == expected
    query, args = queries[0]
    for condition in ("filename = $1", "date = $2", "raw_text = $3", "corrected_text = $4"):
        assert condition in query
    assert "detected_entities_json = $5::jsonb" in query
    assert args[0] == "session::seg01.m4a"
    assert str(args[1]) == "2026-07-04"
    assert args[2:] == ("hallo welt", "hallo Welt", "[]")


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
                author="Lukas Brandt",
            )
        )
