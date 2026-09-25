"""Tests for `asr_client.AsrClient` — the shared ffmpeg + Whisper module.

Run inside the webapp container so deps + env match prod:

    docker compose run --rm webapp pytest webapp/tests/test_asr_client.py

The httpx transport is injected via `httpx.MockTransport` for the Whisper
calls, so no live sidecar is needed. `to_wav_16k_mono` shells out to the
real `ffmpeg` binary (must be on PATH) against tiny generated fixtures.
"""

from __future__ import annotations

import io
import wave

import httpx
import pytest

import asr_client as asr_client_module
from asr_client import (
    AsrClient,
    AsrEngineError,
    AsrTimeoutError,
    AsrUnavailableError,
    get_default_client,
)


@pytest.fixture(autouse=True)
def _reset_default_client():
    asr_client_module._default_client = None
    yield
    asr_client_module._default_client = None


def _client(handler=None, *, timeout_seconds: float = 5.0) -> AsrClient:
    transport = httpx.MockTransport(handler) if handler is not None else None
    return AsrClient(
        base_url="http://whisper.test",
        timeout_seconds=timeout_seconds,
        transport=transport,
    )


# --- transcribe -------------------------------------------------------------


async def test_transcribe_returns_text_on_2xx() -> None:
    def handler(request: httpx.Request) -> httpx.Response:
        assert request.method == "POST"
        assert request.url.path == "/asr"
        assert request.url.params["language"] == "de"
        return httpx.Response(200, json={"text": "  hallo welt  "})

    client = _client(handler)

    text = await client.transcribe(b"RIFF....", language="de")

    assert text == "hallo welt"


async def test_transcribe_falls_back_to_raw_text_on_non_json_body() -> None:
    def handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(200, text="  plain text transcript  ")

    client = _client(handler)

    text = await client.transcribe(b"RIFF....", language="en")

    assert text == "plain text transcript"


async def test_transcribe_5xx_maps_to_AsrEngineError() -> None:
    def handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(500, text="internal error")

    client = _client(handler)

    with pytest.raises(AsrEngineError):
        await client.transcribe(b"RIFF....", language="de")


async def test_transcribe_connect_error_maps_to_AsrUnavailableError() -> None:
    def handler(request: httpx.Request) -> httpx.Response:
        raise httpx.ConnectError("connection refused")

    client = _client(handler)

    with pytest.raises(AsrUnavailableError):
        await client.transcribe(b"RIFF....", language="de")


async def test_transcribe_timeout_maps_to_AsrTimeoutError() -> None:
    def handler(request: httpx.Request) -> httpx.Response:
        raise httpx.ReadTimeout("slow upstream")

    client = _client(handler)

    with pytest.raises(AsrTimeoutError):
        await client.transcribe(b"RIFF....", language="de")


# --- reachable ---------------------------------------------------------------


async def test_reachable_returns_true_on_2xx() -> None:
    def handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(200)

    assert await _client(handler).reachable() is True


async def test_reachable_returns_false_on_connection_failure() -> None:
    def handler(request: httpx.Request) -> httpx.Response:
        raise httpx.ConnectError("nope")

    assert await _client(handler).reachable() is False


# --- to_wav_16k_mono ----------------------------------------------------------


async def test_to_wav_16k_mono_converts_real_audio() -> None:
    buf = io.BytesIO()
    with wave.open(buf, "wb") as w:
        w.setnchannels(2)
        w.setsampwidth(2)
        w.setframerate(44100)
        w.writeframes(b"\x00\x00\x01\x00" * 4410)  # ~0.1s stereo silence-ish

    client = _client()
    wav_bytes = await client.to_wav_16k_mono(buf.getvalue(), ".wav")

    with wave.open(io.BytesIO(wav_bytes), "rb") as w:
        assert w.getframerate() == 16000
        assert w.getnchannels() == 1


async def test_to_wav_16k_mono_raises_AsrEngineError_on_invalid_audio() -> None:
    client = _client()

    with pytest.raises(AsrEngineError):
        await client.to_wav_16k_mono(b"not a real audio file", ".wav")


# --- get_default_client -------------------------------------------------------


def test_get_default_client_returns_same_instance_across_calls() -> None:
    first = get_default_client()
    second = get_default_client()

    assert first is second
