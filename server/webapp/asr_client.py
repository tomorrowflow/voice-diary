"""Shared ffmpeg + Whisper audio module.

Owns the two things every audio-ingest caller needs: normalising arbitrary
input audio to 16 kHz mono WAV via `ffmpeg`, and POSTing that WAV to the
Whisper `/asr` sidecar. `main.py` (manual ingest upload/retry) and
`routers/sessions.py` (iOS session ingest) both drive this client instead
of keeping their own near-identical copies.

Testability: the httpx transport is injectable via the constructor's
`transport` argument, so the pytest suite drives `transcribe`/`reachable`
against a `httpx.MockTransport` and never needs a live Whisper sidecar.
`to_wav_16k_mono` shells out to the real `ffmpeg` binary — there is no
useful fake for that half.
"""

from __future__ import annotations

import asyncio
import json
import logging
import os
import shutil
import tempfile
from pathlib import Path

import httpx

logger = logging.getLogger(__name__)


# --- typed errors ----------------------------------------------------------


class AsrError(Exception):
    """Base class for all ASR client failures."""


class AsrUnavailableError(AsrError):
    """Whisper is unreachable — connection refused, DNS failure, sidecar down."""


class AsrTimeoutError(AsrError):
    """Whisper did not respond within the configured timeout."""


class AsrEngineError(AsrError):
    """ffmpeg failed to convert the audio, Whisper returned an error status,
    or the request failed with a non-timeout, non-connect transport error."""


# --- client ------------------------------------------------------------------


class AsrClient:
    """Pure async client. One instance is shared across callers.

    Construction reads `WHISPER_URL` and `WHISPER_TIMEOUT_SECONDS` from the
    environment by default; tests override both explicitly.
    """

    def __init__(
        self,
        *,
        base_url: str | None = None,
        timeout_seconds: float | None = None,
        transport: httpx.AsyncBaseTransport | None = None,
    ) -> None:
        self._base_url = (base_url or os.getenv("WHISPER_URL", "http://whisper:9000")).rstrip("/")
        self._timeout = timeout_seconds if timeout_seconds is not None else float(
            os.getenv("WHISPER_TIMEOUT_SECONDS", "600")
        )
        self._transport = transport

    @property
    def base_url(self) -> str:
        return self._base_url

    # -- public surface -------------------------------------------------------

    async def to_wav_16k_mono(self, src_bytes: bytes, src_suffix: str) -> bytes:
        """Run ffmpeg to convert arbitrary input audio to 16 kHz mono PCM WAV."""
        tmpdir = Path(tempfile.mkdtemp(prefix="asr-"))
        src_path = tmpdir / f"in{src_suffix or '.bin'}"
        wav_path = tmpdir / "out.wav"
        try:
            src_path.write_bytes(src_bytes)
            proc = await asyncio.create_subprocess_exec(
                "ffmpeg", "-y", "-i", str(src_path),
                "-ar", "16000", "-ac", "1", "-f", "wav", str(wav_path),
                stdout=asyncio.subprocess.DEVNULL,
                stderr=asyncio.subprocess.PIPE,
            )
            _, stderr = await proc.communicate()
            if proc.returncode != 0:
                tail = stderr.decode("utf-8", errors="replace")[-500:]
                raise AsrEngineError(f"ffmpeg failed (exit {proc.returncode}): {tail}")
            return wav_path.read_bytes()
        finally:
            shutil.rmtree(tmpdir, ignore_errors=True)

    async def transcribe(self, wav_bytes: bytes, *, language: str = "de") -> str:
        """POST WAV bytes to the Whisper sidecar and return the transcript text."""
        url = f"{self._base_url}/asr"
        try:
            async with self._make_client() as client:
                resp = await client.post(
                    url,
                    params={"task": "transcribe", "language": language, "output": "json"},
                    files={"audio_file": ("audio.wav", wav_bytes, "audio/wav")},
                )
        except httpx.TimeoutException as exc:
            logger.warning("whisper transcribe timed out: %s", exc)
            raise AsrTimeoutError(str(exc)) from exc
        except httpx.ConnectError as exc:
            logger.warning("whisper unreachable: %s", exc)
            raise AsrUnavailableError(str(exc)) from exc
        except httpx.HTTPError as exc:
            logger.warning("whisper transport error: %s", exc)
            raise AsrEngineError(f"transport error: {exc}") from exc

        if resp.status_code >= 400:
            raise AsrEngineError(f"whisper {resp.status_code}: {resp.text[:300]}")

        try:
            data = resp.json()
        except json.JSONDecodeError:
            return resp.text.strip()
        return (data.get("text") or "").strip()

    async def reachable(self, *, timeout_seconds: float = 2.5) -> bool:
        """Cheap reachability check used as a pre-flight before a session upload."""
        try:
            async with self._make_client(timeout_seconds=timeout_seconds) as client:
                resp = await client.get(f"{self._base_url}/")
            return resp.status_code < 500
        except httpx.HTTPError:
            return False

    # -- internals --------------------------------------------------------------

    def _make_client(self, *, timeout_seconds: float | None = None) -> httpx.AsyncClient:
        return httpx.AsyncClient(
            timeout=timeout_seconds if timeout_seconds is not None else self._timeout,
            transport=self._transport,
        )


# --- process-wide default ----------------------------------------------------


_default_client: AsrClient | None = None


def get_default_client() -> AsrClient:
    """Return the shared process-wide `AsrClient`, constructing it on first use.

    Deferred to first call so the env vars loaded by `load_dotenv()` at app
    startup (`WHISPER_URL`, `WHISPER_TIMEOUT_SECONDS`) are in place before the
    constructor reads them.
    """
    global _default_client
    if _default_client is None:
        _default_client = AsrClient()
    return _default_client
