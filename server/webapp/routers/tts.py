"""TTS router — proxies Voxtral synthesis for the iOS app.

Endpoints:

    GET  /api/tts/voices       → bundled DE + EN voices in the picker
    POST /api/tts/synthesize   { text, language, voice }
                                → audio/wav body

Bearer-token auth applied via the router-level dependency. The route
is deliberately thin: validate, delegate to `voxtral_client`, return
bytes.

History: an earlier slice (07a–07d) added voice-cloning support via
`POST /api/tts/voices/custom` + a base64/file:// `ref_audio` path
through the synth route. Voxtral's open-source checkpoint turned out
to be missing the audio encoder needed for cloning, so the slice was
reverted. See docs/prd/voxtral-tts-integration.md for the
post-mortem.
"""

from __future__ import annotations

import logging
from typing import Literal

from fastapi import APIRouter, Depends, HTTPException, status
from fastapi.responses import Response
from pydantic import BaseModel, Field

from routers.auth import require_bearer
from voice_catalog import catalog as voice_catalog
from voxtral_client import (
    TTSEngineError,
    TTSTimeoutError,
    TTSUnavailableError,
    TTSUnknownVoiceError,
    VoxtralClient,
)

logger = logging.getLogger(__name__)


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


# --- routes --------------------------------------------------------------


@router.get("/voices")
async def voices() -> dict[str, list[dict[str, str]]]:
    """Bundled Voxtral voice references, grouped by source language.

    The route surfaces only the languages Voice Diary's UI supports
    (DE + EN). The full catalog has 9 languages — extending the route
    is a one-line change when we add free-reflection in other languages.
    """
    return voice_catalog.list_grouped(languages=("DE", "EN"))


@router.post("/synthesize")
async def synthesize(req: SynthesizeRequest) -> Response:
    if not voice_catalog.exists(req.voice):
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail={"error": "unknown_voice", "detail": f"voice '{req.voice}' is not in the Voxtral catalog"},
        )

    client = _get_client()
    try:
        result = await client.synthesize(
            req.text,
            language=req.language,
            voice=req.voice,
            response_format=req.response_format,
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
