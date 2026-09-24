"""Speech-ready Ollama summariser used by the iOS enrichment routes.

The output is consumed by Piper TTS on the iPhone, so it must be:
  - 2–3 sentences
  - in the requested language (de | en) — never mixed
  - prose only — no markdown, bullets, code, emoji, or quotation
  - free of speaker labels / preamble like "Hier ist die Zusammenfassung:"

Routes thread `response_language` into the system prompt explicitly. We
do not rely on the model auto-detecting it from the user's query, because
a German query about an English email should still be answered in German
when the user has set their voice to German.
"""

from __future__ import annotations

import logging
import os
from typing import Literal

import httpx

logger = logging.getLogger(__name__)

OLLAMA_BASE_URL = os.getenv("OLLAMA_BASE_URL", "http://192.168.2.17:11434")
OLLAMA_MODEL = os.getenv("OLLAMA_ENRICHMENT_MODEL", os.getenv("OLLAMA_MODEL", "qwen2.5:14b"))
OLLAMA_TIMEOUT = float(os.getenv("OLLAMA_ENRICHMENT_TIMEOUT", "60"))
OLLAMA_NUM_CTX = int(os.getenv("OLLAMA_ENRICHMENT_NUM_CTX", "32768"))


ResponseLanguage = Literal["de", "en"]


_SYSTEM_PROMPTS: dict[ResponseLanguage, str] = {
    "de": (
        "Du bist die Stimme einer persönlichen Tagebuch-Assistenz. "
        "Beantworte die Frage des Nutzers in zwei bis drei kurzen, "
        "sprechbaren Sätzen auf Deutsch. Schreibe ausschließlich Prosa: "
        "keine Aufzählungen, keine Markdown-Zeichen, keine Anführungszeichen, "
        "keine Emojis, keine Einleitungen wie 'Hier ist die Zusammenfassung:'. "
        "Wenn die Quellen die Frage nicht beantworten, sage das in einem Satz."
    ),
    "en": (
        "You are the voice of a personal diary assistant. "
        "Answer the user's question in two to three short, speakable "
        "sentences in English. Use prose only: no bullets, no markdown, "
        "no quotation marks, no emoji, no preamble such as "
        "'Here is the summary:'. If the sources do not answer the question, "
        "say so in one sentence."
    ),
}


class EnrichmentSummariserUnavailable(RuntimeError):
    """Ollama returned an unusable response or was unreachable."""


async def summarise_for_speech(
    *,
    query: str,
    sources_text: str,
    response_language: ResponseLanguage = "de",
) -> str:
    """Summarise `sources_text` in answer to `query` for TTS playback."""
    language = response_language if response_language in ("de", "en") else "de"
    system_prompt = _SYSTEM_PROMPTS[language]

    user_prompt = (
        f"Frage: {query}\n\nQuellen:\n{sources_text}"
        if language == "de"
        else f"Question: {query}\n\nSources:\n{sources_text}"
    )

    payload = {
        "model": OLLAMA_MODEL,
        "stream": False,
        "options": {"num_ctx": OLLAMA_NUM_CTX, "temperature": 0.2},
        "messages": [
            {"role": "system", "content": system_prompt},
            {"role": "user", "content": user_prompt},
        ],
    }

    try:
        async with httpx.AsyncClient(timeout=OLLAMA_TIMEOUT) as client:
            resp = await client.post(f"{OLLAMA_BASE_URL}/api/chat", json=payload)
            resp.raise_for_status()
            data = resp.json()
    except (httpx.NetworkError, httpx.TimeoutException) as exc:
        raise EnrichmentSummariserUnavailable(f"ollama_unreachable: {exc}") from exc
    except httpx.HTTPStatusError as exc:
        raise EnrichmentSummariserUnavailable(
            f"ollama_status_{exc.response.status_code}"
        ) from exc

    msg = data.get("message") or {}
    content = (msg.get("content") or "").strip()
    if not content:
        raise EnrichmentSummariserUnavailable("ollama_empty_response")
    # Drop any speaker labels / leading code fences — defence in depth.
    return _clean_for_speech(content)


def _clean_for_speech(text: str) -> str:
    """Strip residual markdown, bullets, and obvious preamble."""
    text = text.replace("```", "").replace("**", "").replace("*", "")
    lines: list[str] = []
    for line in text.splitlines():
        s = line.strip()
        if not s:
            continue
        # Drop bullet markers if the model still produced them.
        if s.startswith(("-", "•", "·", "—")):
            s = s.lstrip("-•·— ").strip()
        lines.append(s)
    return " ".join(lines)
