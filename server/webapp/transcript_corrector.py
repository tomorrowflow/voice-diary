"""
LLM-based transcript correction for ASR errors.

Sends raw transcript text to Ollama to identify words that are valid German
but wrong in context (e.g., "Staat" instead of "Start"). Runs before entity
detection so the corrected text feeds into the entity pipeline.
"""

import json
import logging
import os
import re
import time

import httpx

logger = logging.getLogger(__name__)

OLLAMA_BASE_URL = os.getenv("OLLAMA_BASE_URL", "http://192.168.2.17:11434")
OLLAMA_MODEL = os.getenv("OLLAMA_MODEL", "qwen2.5:14b")
OLLAMA_TIMEOUT = float(os.getenv("OLLAMA_TIMEOUT", "120"))
OLLAMA_NUM_CTX = int(os.getenv("OLLAMA_NUM_CTX", "131072"))
LLM_CORRECTION_ENABLED = os.getenv(
    "LLM_CORRECTION_ENABLED",
    os.getenv("LLM_VALIDATION_ENABLED", "true"),
).lower() == "true"

SYSTEM_PROMPT = """\
You are a German transcript correction assistant. The text is a CTO diary \
entry transcribed by Whisper ASR from spoken German.

Your task: Find words that are valid German but WRONG in context — where ASR \
misheard a similar-sounding word.

Rules:
- The transcript is in German — corrections MUST also be German words
- Do NOT replace German words with English words
- Only fix common words where ASR clearly picked the wrong word
- Do NOT change proper nouns, company names, or person names (entity detection handles those)
- Do NOT change grammar, style, or punctuation
- Do NOT change words that are plausible in context even if unusual
- Focus on homophones and near-homophones that change meaning

Return JSON:
{"corrections": [{"original": "wrong word or short phrase", "corrected": "right word or phrase", "reason": "brief explanation"}]}

If no corrections are needed, return: {"corrections": []}"""


def _build_messages(
    text: str, correction_examples: list[dict] | None = None
) -> list[dict]:
    user_content = ""

    # Inject few-shot correction examples from vector store
    if correction_examples:
        user_content += "Past corrections in similar contexts:\n"
        for ex in correction_examples:
            ctx_before = ex.get("context_before", "")
            ctx_after = ex.get("context_after", "")
            context_hint = ""
            if ctx_before or ctx_after:
                context_hint = f" (context: ...{ctx_before}[{ex['original_text']}]{ctx_after}...)"
            user_content += f'- "{ex["original_text"]}" → "{ex["corrected_text"]}"{context_hint}\n'
        user_content += "\n"

    user_content += f"TRANSCRIPT:\n{text}"

    return [
        {"role": "system", "content": SYSTEM_PROMPT},
        {"role": "user", "content": user_content},
    ]


def _parse_corrections(response_text: str) -> list[dict]:
    """Parse the LLM JSON response into a list of correction dicts."""
    try:
        data = json.loads(response_text)
    except json.JSONDecodeError:
        logger.warning("LLM returned invalid JSON: %s", response_text[:200])
        return []

    if isinstance(data, dict) and "corrections" in data:
        corrections = data["corrections"]
    elif isinstance(data, list):
        corrections = data
    else:
        logger.warning("Unexpected LLM response structure: %s", type(data))
        return []

    # Validate each correction has required fields
    valid = []
    for c in corrections:
        if (
            isinstance(c, dict)
            and c.get("original")
            and c.get("corrected")
            and c["original"] != c["corrected"]
        ):
            valid.append({
                "original": c["original"],
                "corrected": c["corrected"],
                "reason": c.get("reason", ""),
            })
    return valid


def apply_llm_corrections(
    text: str, corrections: list[dict]
) -> tuple[str, list[dict]]:
    """Apply LLM corrections to text with word-boundary matching.

    Returns (corrected_text, applied_corrections_with_positions).
    Corrections are applied longest-first to avoid partial overlaps.
    """
    if not corrections:
        return text, []

    # Sort longest-first to avoid partial matches
    sorted_corrections = sorted(corrections, key=lambda c: -len(c["original"]))

    applied = []
    result = text

    for corr in sorted_corrections:
        original = corr["original"]
        replacement = corr["corrected"]
        pattern = r"\b" + re.escape(original) + r"\b"

        # Find all matches and their positions in the current result text
        matches = list(re.finditer(pattern, result, re.IGNORECASE))
        if not matches:
            continue

        # Apply replacements from end to start to preserve positions
        for match in reversed(matches):
            start = match.start()
            end = match.end()
            result = result[:start] + replacement + result[end:]
            applied.append({
                "original": original,
                "corrected": replacement,
                "reason": corr.get("reason", ""),
                "start": start,
                "end": start + len(replacement),
            })

    # Sort applied corrections by position for the UI
    applied.sort(key=lambda c: c["start"])
    return result, applied


async def correct_transcript(
    raw_text: str, correction_examples: list[dict] | None = None
) -> tuple[str, list[dict]]:
    """Send transcript to Ollama for contextual ASR error correction.

    Returns (corrected_text, corrections_list).
    Each correction: {original, corrected, reason, start, end}

    Args:
        raw_text: The transcript text to correct.
        correction_examples: Optional list of past correction dicts from vector store,
            each with keys: original_text, corrected_text, context_before, context_after.
    """
    if not LLM_CORRECTION_ENABLED:
        logger.info("LLM transcript correction disabled")
        return raw_text, []

    messages = _build_messages(raw_text, correction_examples=correction_examples)

    logger.info(
        "Calling Ollama for transcript correction (model: %s, timeout: %ss)",
        OLLAMA_MODEL,
        OLLAMA_TIMEOUT,
    )
    t0 = time.monotonic()

    try:
        async with httpx.AsyncClient(timeout=OLLAMA_TIMEOUT) as client:
            resp = await client.post(
                f"{OLLAMA_BASE_URL}/api/chat",
                json={
                    "model": OLLAMA_MODEL,
                    "messages": messages,
                    "format": "json",
                    "stream": False,
                    "options": {"num_ctx": OLLAMA_NUM_CTX},
                },
            )
            resp.raise_for_status()
    except httpx.ConnectError:
        logger.warning("Ollama unreachable at %s for transcript correction", OLLAMA_BASE_URL)
        return raw_text, []
    except httpx.TimeoutException:
        elapsed = time.monotonic() - t0
        logger.warning("Ollama transcript correction timed out after %.1fs", elapsed)
        return raw_text, []
    except httpx.HTTPStatusError as e:
        logger.warning("Ollama returned HTTP %d for transcript correction", e.response.status_code)
        return raw_text, []

    elapsed = time.monotonic() - t0
    logger.info("Ollama transcript correction responded in %.1fs", elapsed)

    try:
        body = resp.json()
        content = body.get("message", {}).get("content", "")
    except (json.JSONDecodeError, AttributeError):
        logger.warning("Failed to parse Ollama response for transcript correction")
        return raw_text, []

    corrections = _parse_corrections(content)
    if not corrections:
        logger.info("LLM found no transcript corrections")
        return raw_text, []

    logger.info("LLM suggested %d transcript correction(s)", len(corrections))
    corrected_text, applied = apply_llm_corrections(raw_text, corrections)
    logger.info("Applied %d transcript correction(s)", len(applied))

    return corrected_text, applied
