"""`POST /api/tts/synthesize` on the upstream failure contract (UFH-02): the
dict `detail` is gone, `voxtral_timeout` is 503, `unknown_voice` stays 400."""

from __future__ import annotations

import pytest

import routers.tts as tts_router
from tests.route_helpers import assert_failure, auth, client_for
from voice_catalog import catalog as voice_catalog
from voxtral_client import (
    SynthesisResult,
    TTSEngineError,
    TTSTimeoutError,
    TTSUnavailableError,
    TTSUnknownVoiceError,
)

BODY = {"text": "Guten Abend", "language": "DE", "voice": "known"}


class _FakeVoxtral:
    def __init__(self, exc: BaseException | None = None) -> None:
        self._exc = exc

    async def synthesize(self, *_args, **_kwargs) -> SynthesisResult:
        if self._exc is not None:
            raise self._exc
        return SynthesisResult(audio=b"RIFFwav", content_type="audio/wav")


def _post(monkeypatch, voxtral: _FakeVoxtral, body: dict = BODY):
    monkeypatch.setattr(voice_catalog, "exists", lambda voice: voice == "known")
    monkeypatch.setattr(tts_router, "_get_client", lambda: voxtral)
    return client_for(tts_router.router, monkeypatch).post(
        "/api/tts/synthesize", json=body, headers=auth()
    )


@pytest.mark.parametrize(
    "exc, code, status",
    [
        (TTSUnavailableError("connection refused"), "voxtral_unavailable", 503),
        (TTSTimeoutError("no audio in 60s"), "voxtral_timeout", 503),
        (TTSEngineError("voxtral 500"), "voxtral_engine_error", 502),
    ],
)
def test_voxtral_failure_uses_the_shared_body(monkeypatch, exc, code, status):
    resp = _post(monkeypatch, _FakeVoxtral(exc))

    body = assert_failure(resp, code=code, upstream="voxtral", status=status, retryable=True)
    assert isinstance(body["detail"], str)
    assert "error" not in body


def test_voice_missing_from_the_catalogue_is_400_unknown_voice(monkeypatch):
    resp = _post(monkeypatch, _FakeVoxtral(), {**BODY, "voice": "nope"})

    body = assert_failure(
        resp, code="unknown_voice", upstream="voxtral", status=400, retryable=False
    )
    assert "'nope'" in body["detail"]


def test_voice_rejected_by_the_engine_is_400_unknown_voice(monkeypatch):
    resp = _post(monkeypatch, _FakeVoxtral(TTSUnknownVoiceError("engine has no such voice")))

    assert_failure(resp, code="unknown_voice", upstream="voxtral", status=400, retryable=False)


def test_success_returns_the_audio(monkeypatch):
    resp = _post(monkeypatch, _FakeVoxtral())

    assert resp.status_code == 200
    assert resp.content == b"RIFFwav"
    assert resp.headers["cache-control"] == "no-store"
