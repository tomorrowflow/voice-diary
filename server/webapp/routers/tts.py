"""TTS router — proxies Voxtral synthesis for the iOS app.

Endpoints:

    POST /api/tts/synthesize   { text, language, voice, response_format? }
                                → audio/wav body

Bearer-token auth applied via the router-level dependency. The route is
deliberately thin: validate, delegate to `voxtral_client`, return bytes.
Voice catalog validation lands in slice 02; v1 trusts the iOS client to
pass a voice id that vLLM will accept (vLLM's 400 propagates back as
`unknown_voice`).
"""

from __future__ import annotations

import base64
import logging
import secrets
from typing import Literal

from fastapi import APIRouter, Depends, File, Form, HTTPException, UploadFile, status
from fastapi.responses import Response
from pydantic import BaseModel, Field

from routers.auth import require_bearer
from voice_catalog import VoiceDescriptor, catalog as voice_catalog
from voxtral_client import (
    TTSEngineError,
    TTSTimeoutError,
    TTSUnavailableError,
    TTSUnknownVoiceError,
    VoxtralClient,
)

logger = logging.getLogger(__name__)


# vLLM Omni's docs claim `--allowed-local-media-path` enables `file://`
# URIs for ref_audio, but in practice (v0.18.0 + Voxtral-4B-TTS-2603)
# the cloning path still tries to base64-decode the ref_audio string
# regardless of the flag. We send a `data:audio/wav;base64,...` data
# URL instead — also documented and works reliably. The shared
# voxtral-refs bind mount stays in compose for now (cheap to keep,
# might be useful later if vLLM fixes the file:// path), but the
# webapp no longer depends on it for synthesis.

# Upload limits: 10 MB matches vLLM Omni's own cap; ~15 s of WAV at
# 24 kHz / mono / 16-bit is ~720 KB, so the limit only kicks in if the
# user tries to upload a fully different file. The audio-format check
# (WAV header) is best-effort — vLLM will reject malformed audio
# itself at synth time and we surface that via TTSUnknownVoiceError /
# TTSEngineError.
_MAX_AUDIO_BYTES = 10 * 1024 * 1024
_MAX_LABEL_LENGTH = 80
_MAX_REF_TEXT_LENGTH = 500


router = APIRouter(prefix="/api/tts", dependencies=[Depends(require_bearer)])


# --- request / response models -------------------------------------------


Language = Literal["DE", "EN"]
ResponseFormat = Literal["wav", "mp3", "opus", "flac", "pcm", "aac"]

# Voxtral handles up to ~2 min of native generation; 4 KB of text is a
# comfortable upper bound for any opener/follow-up/closing prompt we'd
# ever synthesise.
_MAX_TEXT_CHARS = 4000


class SynthesizeRequest(BaseModel):
    text: str = Field(..., min_length=1, max_length=_MAX_TEXT_CHARS)
    language: Language
    voice: str = Field(..., min_length=1, max_length=128)
    response_format: ResponseFormat = "wav"


# --- client lifecycle (module singleton) ---------------------------------


_client: VoxtralClient | None = None


def _get_client() -> VoxtralClient:
    """Lazy singleton — instantiated on first request so env vars set by
    `load_dotenv()` at app startup are in place."""
    global _client
    if _client is None:
        _client = VoxtralClient()
        logger.info(
            "voxtral_client initialised base_url=%s model=%s",
            _client.base_url, _client.model,
        )
    return _client


# --- route ----------------------------------------------------------------


@router.get("/voices")
async def voices() -> dict[str, list[dict[str, str | None]]]:
    """Bundled + custom + LibriVox voice references, grouped by source
    language.

    The route surfaces only the languages Voice Diary's UI supports
    (DE + EN). The full catalog has 9 languages — extending the route
    is a one-line change when we add free-reflection in other languages.

    Return type allows `str | None` per descriptor field because
    `VoiceDescriptor.ref_text` is nullable (bundled voices don't carry
    one). FastAPI 0.115+ uses the return annotation as an implicit
    response model, so a stricter `dict[str, str]` here fails
    validation on every nullable field and surfaces as a 500 with no
    useful log line.
    """
    return voice_catalog.list_grouped(languages=("DE", "EN"))


@router.post("/synthesize")
async def synthesize(req: SynthesizeRequest) -> Response:
    descriptor = voice_catalog.get(req.voice)
    if descriptor is None:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail={"error": "unknown_voice", "detail": f"voice '{req.voice}' is not in the Voxtral catalog"},
        )

    # Bundled voices use the preset-name path; filesystem-backed voices
    # (librivox + user-recorded) clone from the on-disk WAV via vLLM
    # Omni's task_type="Base" surface. We inline the WAV as a base64
    # data URL because vLLM's file:// support is unreliable (see top
    # of file for context). At ~640 KB per request the overhead is
    # negligible for our workload.
    ref_audio: str | None = None
    ref_text: str | None = None
    if descriptor.source != "bundled":
        audio_path = voice_catalog.reference_audio_path(req.voice)
        if audio_path is None:
            # Metadata exists but the WAV doesn't — treat as unknown so
            # the iOS client falls back per the engine policy.
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST,
                detail={"error": "unknown_voice", "detail": f"reference audio missing for voice '{req.voice}'"},
            )
        try:
            audio_bytes = audio_path.read_bytes()
        except OSError as exc:
            raise HTTPException(
                status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
                detail={"error": "ref_audio_read_failed", "detail": str(exc)},
            ) from exc
        encoded = base64.b64encode(audio_bytes).decode("ascii")
        ref_audio = f"data:audio/wav;base64,{encoded}"
        ref_text = descriptor.ref_text

    client = _get_client()
    try:
        result = await client.synthesize(
            req.text,
            language=req.language,
            voice=req.voice,
            response_format=req.response_format,
            ref_audio=ref_audio,
            ref_text=ref_text,
        )
    except TTSUnknownVoiceError as exc:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail={"error": "unknown_voice", "detail": str(exc)},
        ) from exc
    except TTSTimeoutError as exc:
        raise HTTPException(
            status_code=status.HTTP_504_GATEWAY_TIMEOUT,
            detail={"error": "voxtral_timeout", "detail": str(exc)},
        ) from exc
    except TTSUnavailableError as exc:
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail={"error": "voxtral_unavailable", "detail": str(exc)},
        ) from exc
    except TTSEngineError as exc:
        raise HTTPException(
            status_code=status.HTTP_502_BAD_GATEWAY,
            detail={"error": "voxtral_engine_error", "detail": str(exc)},
        ) from exc

    return Response(
        content=result.audio,
        media_type=result.content_type,
        headers={"Cache-Control": "no-store"},
    )


# --- custom voice management ----------------------------------------------


@router.post("/voices/custom", status_code=status.HTTP_201_CREATED)
async def create_custom_voice(
    label: str = Form(..., min_length=1, max_length=_MAX_LABEL_LENGTH),
    language: Literal["DE", "EN"] = Form(...),
    ref_text: str = Form("", max_length=_MAX_REF_TEXT_LENGTH),
    audio: UploadFile = File(...),
) -> dict[str, str | None]:
    """Upload a 3–15 s reference clip and register it as a custom voice.

    The audio is stored under `voxtral_refs_dir()/<id>/audio.wav` and
    a `metadata.json` alongside captures label/language/ref_text. The
    returned descriptor exposes the new `custom_<hex>` voice id; iOS
    stores it prefixed as `voxtral:custom_<hex>` and the next call to
    `/api/tts/voices` includes it.
    """
    audio_bytes = await audio.read()
    if not audio_bytes:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail={"error": "empty_audio", "detail": "audio file was empty"},
        )
    if len(audio_bytes) > _MAX_AUDIO_BYTES:
        raise HTTPException(
            status_code=status.HTTP_413_REQUEST_ENTITY_TOO_LARGE,
            detail={"error": "audio_too_large", "detail": f"audio must be ≤ {_MAX_AUDIO_BYTES} bytes"},
        )
    # Best-effort WAV-header sniff. vLLM accepts wav/mp3/flac/ogg/aac/
    # webm/mp4 per its docs, but for v1 we only ship the WAV path from
    # iOS (AVAudioRecorder writes WAV). Reject other formats early so
    # the user gets a clear error rather than a synth-time failure.
    if not audio_bytes.startswith(b"RIFF") or audio_bytes[8:12] != b"WAVE":
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail={"error": "audio_format", "detail": "audio must be a WAV file (RIFF/WAVE header expected)"},
        )

    voice_id = f"custom_{secrets.token_hex(4)}"
    try:
        descriptor = voice_catalog.add_filesystem_voice(
            voice_id,
            language=language,
            label=label.strip(),
            description="Eigene Aufnahme" if language == "DE" else "Custom recording",
            ref_text=ref_text.strip() or None,
            source="user",
            audio_bytes=audio_bytes,
        )
    except (FileExistsError, ValueError) as exc:
        # FileExistsError is statistically near-impossible (32 bits of
        # randomness per upload) — surfacing it cleanly anyway.
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail={"error": "voice_id_taken", "detail": str(exc)},
        ) from exc
    except RuntimeError as exc:
        # No refs_root configured — server-side misconfiguration.
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail={"error": "refs_root_missing", "detail": str(exc)},
        ) from exc

    logger.info(
        "voice catalog: created custom voice id=%s lang=%s label=%s",
        descriptor.id, descriptor.language, descriptor.label,
    )
    return descriptor.to_dict()


@router.delete("/voices/custom/{voice_id}", status_code=status.HTTP_204_NO_CONTENT)
async def delete_custom_voice(voice_id: str) -> Response:
    """Remove a user-uploaded reference clip. Refuses to delete
    bundled-Mistral voices and LibriVox-seeded voices — those live on
    the server as a curated set and are managed by the seed script."""
    descriptor = voice_catalog.get(voice_id)
    if descriptor is None:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail={"error": "voice_not_found", "detail": f"no such voice: {voice_id}"},
        )
    if descriptor.source != "user":
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail={"error": "not_deletable", "detail": f"voice source '{descriptor.source}' cannot be deleted via this route"},
        )
    if not voice_catalog.delete_filesystem_voice(voice_id):
        # Race: descriptor existed when we looked it up, but the
        # filesystem entry was removed before we got to it. Treat as
        # already-deleted (404 is fine, but 204 is more polite to a
        # client whose intent has been satisfied).
        return Response(status_code=status.HTTP_204_NO_CONTENT)
    logger.info("voice catalog: deleted custom voice id=%s", voice_id)
    return Response(status_code=status.HTTP_204_NO_CONTENT)
