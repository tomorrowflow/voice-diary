"""
LLM processing of diary transcripts into Harvest-compatible work descriptions.
Uses Ollama (same setup as llm_validator.py).
"""

import json
import logging
import os

import httpx

logger = logging.getLogger(__name__)

OLLAMA_BASE_URL = os.getenv("OLLAMA_BASE_URL", "http://192.168.2.17:11434")
OLLAMA_MODEL = os.getenv("OLLAMA_MODEL", "qwen2.5:14b")
OLLAMA_TIMEOUT = float(os.getenv("OLLAMA_TIMEOUT", "120"))

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
        async with httpx.AsyncClient(timeout=OLLAMA_TIMEOUT) as client:
            resp = await client.post(
                f"{OLLAMA_BASE_URL}/api/chat",
                json={
                    "model": OLLAMA_MODEL,
                    "messages": prompt,
                    "format": "json",
                    "stream": False,
                },
            )
            resp.raise_for_status()
    except Exception as e:
        logger.warning("Ollama call failed for harvest LLM: %s", e)
        return []

    try:
        body = resp.json()
        content = body.get("message", {}).get("content", "")
        data = json.loads(content)
    except (json.JSONDecodeError, AttributeError) as e:
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
            "description": item.get("description", ""),
            "estimated_hours": _parse_hours(item.get("estimated_hours", 1.0)),
            "category": item.get("category", "other"),
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
        "- category: One of: development, meeting, documentation, planning, review, "
        "operations, communication, other\n\n"
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
