"""Async HTTP client for Voxtral TTS via vLLM Omni.

Wraps the OpenAI-compatible `/v1/audio/speech` endpoint exposed by
`vllm/vllm-omni` serving `mistralai/Voxtral-4B-TTS-2603`. Owns the wire
format, timeouts, retries, and error classification. Knows nothing about
FastAPI — the `tts` router stays a thin auth + delegate layer on top.

Testability: the httpx transport is injectable via the constructor's
`transport` argument, so the pytest suite drives the client against a
`httpx.MockTransport` and never spins up a live vLLM.
"""

from __future__ import annotations

import asyncio
import logging
import os
from dataclasses import dataclass
from typing import Literal

import httpx

logger = logging.getLogger(__name__)


# --- typed errors ---------------------------------------------------------


class TTSError(Exception):
    """Base class for all Voxtral client failures."""


class TTSUnknownVoiceError(TTSError):
    """vLLM rejected the requested voice id (HTTP 400 with a voice-related detail)."""


class TTSUnavailableError(TTSError):
    """vLLM is unreachable — connection refused, DNS failure, server stopped."""


class TTSTimeoutError(TTSError):
    """vLLM did not respond within the configured timeout."""


class TTSEngineError(TTSError):
    """vLLM returned a server-side error (5xx) past the retry budget, or a
    non-retryable 4xx that is not specifically a voice problem."""


# --- response shape -------------------------------------------------------


ResponseFormat = Literal["wav", "mp3", "opus", "flac", "pcm", "aac"]


@dataclass(frozen=True)
class SynthesisResult:
    """Audio bytes plus the content type vLLM declared for them."""

    audio: bytes
    content_type: str


# --- client ---------------------------------------------------------------


class VoxtralClient:
    """Pure async client. One instance per FastAPI app lifespan.

    Construction reads `VOXTRAL_BASE_URL`, `VOXTRAL_MODEL`, and
    `VOXTRAL_TIMEOUT_SECONDS` from the environment by default; tests
    override them explicitly.
    """

    def __init__(
        self,
        *,
        base_url: str | None = None,
        model: str | None = None,
        timeout_seconds: float | None = None,
        retry_budget: int = 2,
        retry_backoff_seconds: float = 0.25,
        transport: httpx.AsyncBaseTransport | None = None,
    ) -> None:
        self._base_url = (base_url or os.getenv("VOXTRAL_BASE_URL", "http://voxtral:8001")).rstrip("/")
        self._model = model or os.getenv("VOXTRAL_MODEL", "mistralai/Voxtral-4B-TTS-2603")
        self._timeout = timeout_seconds if timeout_seconds is not None else float(
            os.getenv("VOXTRAL_TIMEOUT_SECONDS", "30")
        )
        self._retry_budget = max(0, retry_budget)
        self._retry_backoff = retry_backoff_seconds
        self._transport = transport

    @property
    def base_url(self) -> str:
        return self._base_url

    @property
    def model(self) -> str:
        return self._model

    # -- public surface ----------------------------------------------------

    async def synthesize(
        self,
        text: str,
        *,
        language: str,
        voice: str,
        response_format: ResponseFormat = "wav",
    ) -> SynthesisResult:
        """Render `text` in `voice` and return the audio bytes.

        Retries on connection errors and 5xx up to `retry_budget` extra
        attempts with exponential backoff. Maps vLLM responses to typed
        exceptions so the router (and iOS, later) can branch on them.

        Only the 20 preset speakers Mistral ships with the open-source
        checkpoint are usable here. An earlier slice tried to add
        reference-based cloning via `ref_audio` + `ref_text`, but the
        encoder needed to extract embeddings from raw audio was
        withheld from the public release. See the PRD post-mortem.
        """
        payload: dict[str, object] = {
            "input": text,
            "model": self._model,
            "voice": voice,
            "response_format": response_format,
            "language": language,
        }
        url = f"{self._base_url}/v1/audio/speech"

        last_5xx: httpx.Response | None = None
        attempt = 0
        max_attempts = 1 + self._retry_budget
        while attempt < max_attempts:
            attempt += 1
            try:
                async with self._make_client() as client:
                    resp = await client.post(url, json=payload)
            except httpx.TimeoutException as exc:
                logger.warning("voxtral synth timed out (attempt %d/%d): %s", attempt, max_attempts, exc)
                raise TTSTimeoutError(str(exc)) from exc
            except httpx.ConnectError as exc:
                logger.warning("voxtral unreachable (attempt %d/%d): %s", attempt, max_attempts, exc)
                if attempt < max_attempts:
                    await asyncio.sleep(self._retry_backoff * attempt)
                    continue
                raise TTSUnavailableError(str(exc)) from exc
            except httpx.HTTPError as exc:
                # Other transport-level failures (read error, network reset, …)
                logger.warning("voxtral transport error (attempt %d/%d): %s", attempt, max_attempts, exc)
                if attempt < max_attempts:
                    await asyncio.sleep(self._retry_backoff * attempt)
                    continue
                raise TTSEngineError(f"transport error: {exc}") from exc

            if resp.status_code < 400:
                return SynthesisResult(
                    audio=resp.content,
                    content_type=resp.headers.get("content-type", "audio/wav"),
                )

            if resp.status_code == 400:
                detail = _extract_error_detail(resp)
                if _looks_like_voice_error(detail):
                    raise TTSUnknownVoiceError(detail)
                raise TTSEngineError(f"vllm 400: {detail}")

            if resp.status_code >= 500:
                last_5xx = resp
                logger.warning(
                    "voxtral 5xx (attempt %d/%d): status=%d body=%s",
                    attempt, max_attempts, resp.status_code, resp.text[:200],
                )
                if attempt < max_attempts:
                    await asyncio.sleep(self._retry_backoff * attempt)
                    continue
                raise TTSEngineError(
                    f"vllm {resp.status_code} after {attempt} attempts: {_extract_error_detail(resp)}"
                )

            # Other 4xx — not retryable.
            raise TTSEngineError(f"vllm {resp.status_code}: {_extract_error_detail(resp)}")

        # Defensive — loop should always return or raise.
        assert last_5xx is not None  # noqa: S101
        raise TTSEngineError(f"vllm {last_5xx.status_code} after retry budget exhausted")

    async def probe(self, *, timeout_seconds: float = 2.0) -> bool:
        """Cheap reachability check for the `/health` route. True if vLLM
        is responding on the OpenAI-compatible `/v1/models` endpoint."""
        url = f"{self._base_url}/v1/models"
        try:
            async with self._make_client(timeout_seconds=timeout_seconds) as client:
                resp = await client.get(url)
            return resp.status_code < 500
        except httpx.HTTPError:
            return False

    # -- internals ---------------------------------------------------------

    def _make_client(self, *, timeout_seconds: float | None = None) -> httpx.AsyncClient:
        return httpx.AsyncClient(
            timeout=timeout_seconds if timeout_seconds is not None else self._timeout,
            transport=self._transport,
        )


# --- helpers --------------------------------------------------------------


def _extract_error_detail(resp: httpx.Response) -> str:
    try:
        body = resp.json()
    except Exception:  # noqa: BLE001
        return resp.text[:300]
    if isinstance(body, dict):
        for key in ("detail", "error", "message"):
            value = body.get(key)
            if isinstance(value, str):
                return value
            if isinstance(value, dict) and "message" in value:
                return str(value["message"])
    return str(body)[:300]


def _looks_like_voice_error(detail: str) -> bool:
    lowered = detail.lower()
    return "voice" in lowered and any(token in lowered for token in ("unknown", "not found", "invalid", "no such"))
