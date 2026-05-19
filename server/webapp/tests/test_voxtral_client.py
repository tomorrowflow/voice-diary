"""Tests for `voxtral_client.VoxtralClient`.

Run inside the webapp container so deps + env match prod:

    docker compose run --rm webapp pytest tests/test_voxtral_client.py

The httpx transport is injected via `httpx.MockTransport`, so no live
vLLM is needed. Each test drives one branch of the client's error
classification.
"""

from __future__ import annotations

import httpx
import pytest

from voxtral_client import (
    SynthesisResult,
    TTSEngineError,
    TTSTimeoutError,
    TTSUnavailableError,
    TTSUnknownVoiceError,
    VoxtralClient,
)


# --- helpers --------------------------------------------------------------


def _client(handler, *, retry_budget: int = 2, timeout: float = 5.0) -> VoxtralClient:
    """VoxtralClient wired to a `httpx.MockTransport`. Retry backoff is
    zeroed so retry tests don't sleep."""
    return VoxtralClient(
        base_url="http://voxtral.test",
        model="mistralai/Voxtral-4B-TTS-2603",
        timeout_seconds=timeout,
        retry_budget=retry_budget,
        retry_backoff_seconds=0.0,
        transport=httpx.MockTransport(handler),
    )


def _wav_bytes() -> bytes:
    # Minimal but recognisable as audio for content-type assertions.
    return b"RIFF\x00\x00\x00\x00WAVEfmt fake audio payload"


# --- happy path -----------------------------------------------------------


async def test_synthesize_returns_audio_bytes_on_2xx() -> None:
    audio = _wav_bytes()

    def handler(request: httpx.Request) -> httpx.Response:
        assert request.method == "POST"
        assert request.url.path == "/v1/audio/speech"
        return httpx.Response(200, content=audio, headers={"content-type": "audio/wav"})

    client = _client(handler)

    result = await client.synthesize("Hallo Welt.", language="DE", voice="casual_male")

    assert isinstance(result, SynthesisResult)
    assert result.audio == audio
    assert result.content_type == "audio/wav"


async def test_synthesize_forwards_text_voice_language_model_to_vllm() -> None:
    captured: dict = {}

    def handler(request: httpx.Request) -> httpx.Response:
        captured["body"] = request.read()
        return httpx.Response(200, content=_wav_bytes(), headers={"content-type": "audio/wav"})

    client = _client(handler)
    await client.synthesize("Guten Abend.", language="DE", voice="casual_female")

    import json
    payload = json.loads(captured["body"])
    assert payload["input"] == "Guten Abend."
    assert payload["voice"] == "casual_female"
    assert payload["language"] == "DE"
    assert payload["model"] == "mistralai/Voxtral-4B-TTS-2603"
    assert payload["response_format"] == "wav"


# --- error classification -------------------------------------------------


async def test_unknown_voice_400_maps_to_TTSUnknownVoiceError() -> None:
    def handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(
            400,
            json={"detail": "Unknown voice id 'nope' — not found in voice catalog"},
        )

    client = _client(handler, retry_budget=0)

    with pytest.raises(TTSUnknownVoiceError):
        await client.synthesize("x", language="DE", voice="nope")


async def test_generic_400_maps_to_TTSEngineError_not_voice_error() -> None:
    def handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(400, json={"detail": "input too long"})

    client = _client(handler, retry_budget=0)

    with pytest.raises(TTSEngineError):
        await client.synthesize("x", language="DE", voice="ok")


async def test_connection_refused_after_retries_maps_to_TTSUnavailableError() -> None:
    def handler(request: httpx.Request) -> httpx.Response:
        raise httpx.ConnectError("Connection refused")

    client = _client(handler, retry_budget=2)

    with pytest.raises(TTSUnavailableError):
        await client.synthesize("x", language="DE", voice="ok")


async def test_timeout_maps_to_TTSTimeoutError() -> None:
    def handler(request: httpx.Request) -> httpx.Response:
        raise httpx.ReadTimeout("slow upstream")

    client = _client(handler, retry_budget=2)

    with pytest.raises(TTSTimeoutError):
        await client.synthesize("x", language="DE", voice="ok")


# --- retry behaviour ------------------------------------------------------


async def test_5xx_then_200_returns_audio_on_retry() -> None:
    calls: list[int] = []

    def handler(request: httpx.Request) -> httpx.Response:
        calls.append(1)
        if len(calls) == 1:
            return httpx.Response(500, json={"detail": "transient"})
        return httpx.Response(200, content=_wav_bytes(), headers={"content-type": "audio/wav"})

    client = _client(handler, retry_budget=2)

    result = await client.synthesize("x", language="DE", voice="ok")
    assert len(calls) == 2
    assert result.audio == _wav_bytes()


async def test_5xx_exhausts_retry_budget_then_TTSEngineError() -> None:
    calls: list[int] = []

    def handler(request: httpx.Request) -> httpx.Response:
        calls.append(1)
        return httpx.Response(503, json={"detail": "still down"})

    client = _client(handler, retry_budget=2)

    with pytest.raises(TTSEngineError):
        await client.synthesize("x", language="DE", voice="ok")
    assert len(calls) == 3  # 1 initial + 2 retries


async def test_connect_error_then_success_retries_through() -> None:
    calls: list[int] = []

    def handler(request: httpx.Request) -> httpx.Response:
        calls.append(1)
        if len(calls) == 1:
            raise httpx.ConnectError("not yet")
        return httpx.Response(200, content=_wav_bytes(), headers={"content-type": "audio/wav"})

    client = _client(handler, retry_budget=2)

    result = await client.synthesize("x", language="DE", voice="ok")
    assert len(calls) == 2
    assert result.audio == _wav_bytes()


# --- probe ----------------------------------------------------------------


async def test_probe_returns_true_on_2xx() -> None:
    def handler(request: httpx.Request) -> httpx.Response:
        assert request.url.path == "/v1/models"
        return httpx.Response(200, json={"data": []})

    assert await _client(handler).probe() is True


async def test_probe_returns_false_on_connection_failure() -> None:
    def handler(request: httpx.Request) -> httpx.Response:
        raise httpx.ConnectError("nope")

    assert await _client(handler).probe() is False


# --- cloning (slice 07) ---------------------------------------------------


async def test_clone_includes_task_type_and_ref_fields() -> None:
    captured: dict = {}

    def handler(request: httpx.Request) -> httpx.Response:
        captured["body"] = request.read()
        return httpx.Response(200, content=_wav_bytes(), headers={"content-type": "audio/wav"})

    client = _client(handler)
    await client.synthesize(
        "Hallo.",
        language="DE",
        voice="custom_abc12345",
        ref_audio="file:///voxtral-refs/custom_abc12345/audio.wav",
        ref_text="Dies ist meine Referenz.",
    )

    import json
    payload = json.loads(captured["body"])
    assert payload["task_type"] == "Base"
    assert payload["ref_audio"] == "file:///voxtral-refs/custom_abc12345/audio.wav"
    assert payload["ref_text"] == "Dies ist meine Referenz."
    # The voice field is still required by vLLM Omni even when cloning.
    assert payload["voice"] == "custom_abc12345"


async def test_clone_omits_ref_text_when_not_provided() -> None:
    captured: dict = {}

    def handler(request: httpx.Request) -> httpx.Response:
        captured["body"] = request.read()
        return httpx.Response(200, content=_wav_bytes(), headers={"content-type": "audio/wav"})

    client = _client(handler)
    await client.synthesize(
        "Hello.",
        language="EN",
        voice="custom_deadbeef",
        ref_audio="file:///voxtral-refs/custom_deadbeef/audio.wav",
    )

    import json
    payload = json.loads(captured["body"])
    assert payload["task_type"] == "Base"
    assert payload["ref_audio"] == "file:///voxtral-refs/custom_deadbeef/audio.wav"
    assert "ref_text" not in payload


async def test_bundled_synth_does_not_include_clone_fields() -> None:
    """Backwards-compat: synth without ref_audio sends no task_type /
    ref_* fields so a bundled-voice call is byte-identical to slice 02."""
    captured: dict = {}

    def handler(request: httpx.Request) -> httpx.Response:
        captured["body"] = request.read()
        return httpx.Response(200, content=_wav_bytes(), headers={"content-type": "audio/wav"})

    client = _client(handler)
    await client.synthesize("Hallo.", language="DE", voice="de_male")

    import json
    payload = json.loads(captured["body"])
    assert "task_type" not in payload
    assert "ref_audio" not in payload
    assert "ref_text" not in payload
