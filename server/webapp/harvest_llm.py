"""
LLM processing of diary transcripts into Harvest-compatible work descriptions.
Uses Ollama (same setup as llm_validator.py).
"""

import json
import logging
import os

from ollama_client import OllamaClient

logger = logging.getLogger(__name__)

OLLAMA_BASE_URL = os.getenv("OLLAMA_BASE_URL", "http://192.168.2.17:11434")
OLLAMA_MODEL = os.getenv("OLLAMA_MODEL", "qwen2.5:14b")
OLLAMA_TIMEOUT = float(os.getenv("OLLAMA_TIMEOUT", "120"))

_ollama_client = OllamaClient(base_url=OLLAMA_BASE_URL, model=OLLAMA_MODEL, timeout_seconds=OLLAMA_TIMEOUT)

# `extract_work_activities` crosses a trust boundary: the transcript it
# receives is transcribed user speech (effectively untrusted text) that
# flows into the LLM prompt — a prompt-injection surface — and the LLM's
# output then surfaces as Harvest time-entry fields in the review UI.
# So `category` is allowlisted to the exact values the prompt offers the
# model, and `description` is length-bounded. Accepted risk for a
# single-user tool; see SEC-6 / docs/REVIEW-2026-07-04.md.
# Tuple (not set) so the prompt lists categories in a stable order.
ALLOWED_CATEGORIES = (
    "development",
    "meeting",
    "documentation",
    "planning",
    "review",
    "operations",
    "communication",
    "other",
)
DEFAULT_CATEGORY = "other"
MAX_DESCRIPTION_LENGTH = 500

# In-memory cache: (transcript_text_hash, date) -> result
_cache: dict[tuple, list[dict]] = {}


async def extract_work_activities(transcript: str, date_str: str) -> list[dict]:
    """
    Ask the LLM to extract work activities from a diary transcript.

    Returns a list of dicts:
    [{"description": "...", "estimated_hours": 1.0, "category": "development"}, ...]
    """
    cache_key = (hash(transcript), date_str)
    if cache_key in _cache:
        return _cache[cache_key]

    prompt = _build_prompt(transcript, date_str)

    try:
        result = await _ollama_client.chat(prompt, format="json")
    except Exception as e:
        logger.warning("Ollama call failed for harvest LLM: %s", e)
        return []

    try:
        data = json.loads(result.content)
    except json.JSONDecodeError as e:
        logger.warning("Failed to parse Ollama response: %s", e)
        return []

    activities = []
    items = data if isinstance(data, list) else data.get("activities", data.get("work_activities", []))
    if not isinstance(items, list):
        return []

    for item in items:
        if not isinstance(item, dict):
            continue
        activities.append({
            "description": _parse_description(item.get("description")),
            "estimated_hours": _parse_hours(item.get("estimated_hours", 1.0)),
            "category": _parse_category(item.get("category")),
        })

    _cache[cache_key] = activities
    return activities


def _parse_hours(val) -> float:
    """Parse hours value, rounding to nearest 0.25."""
    try:
        h = float(val)
        return max(0.25, round(h * 4) / 4)
    except (ValueError, TypeError):
        return 1.0


def _parse_category(val) -> str:
    """Allowlist the category against the values offered in the prompt.

    The model is free text underneath `format: json`; anything outside
    the allowlist (including prompt-injection attempts riding along in
    the transcript) collapses to the default category.
    """
    if isinstance(val, str) and val in ALLOWED_CATEGORIES:
        return val
    return DEFAULT_CATEGORY


def _parse_description(val) -> str:
    """Bound the description length before it reaches Harvest / the UI."""
    text = val if isinstance(val, str) else ""
    return text[:MAX_DESCRIPTION_LENGTH]


def _build_prompt(transcript: str, date_str: str) -> list[dict]:
    system_msg = (
        "You are a time tracking assistant. Given a German CTO diary transcript, "
        "extract distinct work activities that were performed during the day. "
        "Each activity should have a brief customer-compatible description (German), "
        "an estimated time spent in hours, and a category."
    )

    user_msg = (
        f"Date: {date_str}\n\n"
        f"DIARY TRANSCRIPT:\n{transcript}\n\n"
        "Extract the work activities mentioned in this diary. For each activity provide:\n"
        "- description: Brief German description suitable for a Harvest time entry note "
        "(customer-compatible, professional)\n"
        "- estimated_hours: How long this activity likely took (number, round to 0.25h)\n"
        f"- category: One of: {', '.join(ALLOWED_CATEGORIES)}\n\n"
        "Respond with JSON:\n"
        '{"activities": [{"description": "...", "estimated_hours": 1.0, "category": "development"}]}\n\n'
        "Rules:\n"
        "- Only include activities actually mentioned in the transcript\n"
        "- Descriptions must be professional and customer-compatible\n"
        "- Don't include meeting attendance (that comes from the calendar)\n"
        "- Focus on work done between meetings (coding, reviewing, planning, etc.)\n"
        "- Estimate times conservatively\n"
    )

    return [
        {"role": "system", "content": system_msg},
        {"role": "user", "content": user_msg},
    ]
