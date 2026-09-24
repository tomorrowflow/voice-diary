"""
LLM-based fluency checker for transcripts.

Identifies disfluent sentences (false starts, broken syntax, filler words,
mid-sentence topic changes) in spoken German diary transcripts. Returns
sentence-level annotations for UI highlighting — does not auto-fix.
"""

import json
import logging
import os
import time

import httpx

logger = logging.getLogger(__name__)

OLLAMA_BASE_URL = os.getenv("OLLAMA_BASE_URL", "http://192.168.2.17:11434")
OLLAMA_MODEL = os.getenv("OLLAMA_MODEL", "qwen2.5:14b")
OLLAMA_TIMEOUT = float(os.getenv("OLLAMA_TIMEOUT", "120"))
OLLAMA_NUM_CTX = int(os.getenv("OLLAMA_NUM_CTX", "131072"))
FLUENCY_CHECK_ENABLED = os.getenv("FLUENCY_CHECK_ENABLED", "true").lower() == "true"

SYSTEM_PROMPT = """\
You are a German transcript fluency analyser. The text is a CTO diary \
entry transcribed by Whisper ASR from spoken German.

Your task: Find sentences or phrases that are disfluent — broken, incomplete, \
or hard to understand due to how they were spoken (not due to ASR errors).

Look for:
- Incomplete sentences that trail off or restart
- False starts where the speaker begins a thought then abandons it
- Mid-sentence topic switches that make the sentence incoherent
- Excessive filler words that obscure meaning (ähm, also, quasi, sozusagen)
- Run-on sentences that merge unrelated thoughts without clear separation
- Grammatically broken constructions that are hard to parse

Do NOT flag:
- Sentences that are simply informal or conversational but still clear
- ASR transcription errors (wrong words) — those are handled separately
- Correct sentences that just use colloquial German
- Short sentences or fragments that are intentionally brief

For each disfluent passage, quote the EXACT text from the transcript \
(character-perfect, including any punctuation) and categorise the issue.

Return JSON:
{"issues": [{"text": "exact quote from transcript", "category": "incomplete|false_start|topic_switch|filler_heavy|run_on|broken_syntax", "note": "brief explanation in English"}]}

If no issues are found, return: {"issues": []}"""


def _build_messages(text: str) -> list[dict]:
    return [
        {"role": "system", "content": SYSTEM_PROMPT},
        {"role": "user", "content": f"TRANSCRIPT:\n{text}"},
    ]


def _parse_issues(response_text: str) -> list[dict]:
    """Parse the LLM JSON response into a list of fluency issues."""
    try:
        data = json.loads(response_text)
    except json.JSONDecodeError:
        logger.warning("Fluency checker: invalid JSON: %s", response_text[:200])
        return []

    if isinstance(data, dict) and "issues" in data:
        issues = data["issues"]
    elif isinstance(data, list):
        issues = data
    else:
        logger.warning("Fluency checker: unexpected response structure: %s", type(data))
        return []

    valid = []
    for item in issues:
        if isinstance(item, dict) and item.get("text"):
            valid.append({
                "text": item["text"],
                "category": item.get("category", "broken_syntax"),
                "note": item.get("note", ""),
            })
    return valid


def locate_issues(text: str, issues: list[dict]) -> list[dict]:
    """Find character positions for each issue's quoted text in the transcript.

    Returns issues enriched with start/end positions. Issues whose quoted text
    cannot be found in the transcript are dropped.
    """
    located = []
    for issue in issues:
        quote = issue["text"]
        idx = text.find(quote)
        if idx == -1:
            # Try case-insensitive fallback
            idx = text.lower().find(quote.lower())
        if idx == -1:
            logger.debug("Fluency issue quote not found in transcript: %s", quote[:60])
            continue
        located.append({
            "start": idx,
            "end": idx + len(quote),
            "text": quote,
            "category": issue["category"],
            "note": issue["note"],
        })
    return located


async def check_fluency(raw_text: str) -> list[dict]:
    """Send transcript to Ollama for fluency analysis.

    Returns list of located issues:
    [{start, end, text, category, note}, ...]
    """
    if not FLUENCY_CHECK_ENABLED:
        logger.info("Fluency check disabled")
        return []

    messages = _build_messages(raw_text)

    logger.info(
        "Calling Ollama for fluency check (model: %s, timeout: %ss)",
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
        logger.warning("Ollama unreachable at %s for fluency check", OLLAMA_BASE_URL)
        return []
    except httpx.TimeoutException:
        elapsed = time.monotonic() - t0
        logger.warning("Fluency check timed out after %.1fs", elapsed)
        return []
    except httpx.HTTPStatusError as e:
        logger.warning("Ollama returned HTTP %d for fluency check", e.response.status_code)
        return []

    elapsed = time.monotonic() - t0
    logger.info("Fluency check responded in %.1fs", elapsed)

    try:
        body = resp.json()
        content = body.get("message", {}).get("content", "")
    except (json.JSONDecodeError, AttributeError):
        logger.warning("Failed to parse Ollama response for fluency check")
        return []

    issues = _parse_issues(content)
    if not issues:
        logger.info("No fluency issues found")
        return []

    located = locate_issues(raw_text, issues)
    logger.info("Found %d fluency issues (%d located)", len(issues), len(located))
    return located
