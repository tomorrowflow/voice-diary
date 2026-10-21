"""Harvest suggestion flow and pattern-cache lifecycle (REF-125).

One owner for the in-memory pattern DB: it is loaded lazily from the stored
Harvest entries, rebuilt when entries are refreshed, and dropped when they are
cleared. `suggest(date)` maps a day's calendar events and diary activities to
Harvest booking suggestions. The routes in `main.py` are HTTP adapters over it.
"""

from __future__ import annotations

import logging
from collections.abc import Awaitable, Callable
from typing import Any

import db
import harvest_llm
import harvest_patterns
from msgraph_client import to_local_iso

logger = logging.getLogger(__name__)

# Reads the raw Graph-shaped events of a local calendar day (the shared day
# query of REF-120); injected so this module does not depend on the app entry
# point.
CalendarFetcher = Callable[[str], Awaitable[list[dict]]]

_pattern_db: dict | None = None


# ─── Cache lifecycle ─────────────────────────────────────────────────


def is_loaded() -> bool:
    """Whether a pattern DB is currently cached."""
    return _pattern_db is not None


def keyword_count() -> int:
    """Number of keyword patterns in the cached pattern DB (0 if none)."""
    return len(_pattern_db["keyword_patterns"]) if _pattern_db else 0


async def status() -> dict:
    """Stored-entry stats plus the cache state, as the status route reports it."""
    await db.ensure_harvest_table()
    return {
        "entries": await db.get_harvest_entry_stats(),
        "pattern_db_loaded": is_loaded(),
        "pattern_keywords": keyword_count(),
    }


async def load() -> dict:
    """Return the cached pattern DB, building it from stored entries if needed.

    Raises whatever the database raises; nothing is cached on failure.
    """
    global _pattern_db
    if not _pattern_db:
        await db.ensure_harvest_table()
        _pattern_db = harvest_patterns.build_pattern_db(await db.get_harvest_entries())
    return _pattern_db


async def refresh(entries: list[dict]) -> dict:
    """Replace the stored Harvest entries and rebuild the cached pattern DB."""
    global _pattern_db
    await db.ensure_harvest_table()
    await db.clear_harvest_entries()
    await db.save_harvest_entries(entries)
    _pattern_db = harvest_patterns.build_pattern_db(entries)
    return _pattern_db


async def invalidate() -> None:
    """Clear the stored Harvest entries and drop the cached pattern DB."""
    global _pattern_db
    await db.ensure_harvest_table()
    await db.clear_harvest_entries()
    _pattern_db = None


# ─── Suggestions ─────────────────────────────────────────────────────


async def _calendar_events(date: str, fetch_events: CalendarFetcher) -> list[dict]:
    """Bookable events of the day (not free/tentative), local times, sorted."""
    events = []
    for ev in await fetch_events(date):
        start = to_local_iso(ev.get("start"))
        end = to_local_iso(ev.get("end"))
        if not start or "T" not in start:
            continue
        if ev.get("showAs") in ("free", "tentative"):
            continue
        events.append({
            "subject": ev.get("subject", ""),
            "start": start,
            "end": end,
            "showAs": ev.get("showAs", ""),
        })
    events.sort(key=lambda e: e["start"])
    return events


def _calendar_suggestions(events: list[dict], pattern_db: dict) -> list[dict]:
    suggestions = []
    for ev in events:
        hours = harvest_patterns.calculate_event_hours(
            ev["start"], ev["end"], pattern_db.get("speedy_meeting_rounding", True)
        )
        pattern = harvest_patterns.match_calendar_to_pattern(ev["subject"], pattern_db)

        if pattern:
            project = {"id": pattern["project_id"], "name": pattern["project_name"]}
            task = {"id": pattern["task_id"], "name": pattern["task_name"]}
            source, confidence = "calendar+pattern", "high"
        elif pattern_db.get("default_project"):
            dp = pattern_db["default_project"]
            project = {"id": dp["project_id"], "name": dp["project_name"]}
            task = {"id": dp["task_id"], "name": dp["task_name"]}
            source, confidence = "calendar", "low"
        else:
            project, task = None, None
            source, confidence = "calendar", "low"

        suggestions.append({
            "project": project,
            "task": task,
            "hours": hours,
            "notes": ev["subject"],
            "source": source,
            "confidence": confidence,
            "start": ev["start"],
            "end": ev["end"],
        })
    return suggestions


def _diary_suggestions(activities: list[dict], pattern_db: dict) -> list[dict]:
    """Diary activities as gap-fill entries, on "Selbstorganisation" if known."""
    so = pattern_db.get("selbstorganisation")
    project = {"id": so["project_id"], "name": so["project_name"]} if so else None
    task = {"id": so["task_id"], "name": so["task_name"]} if so else None
    return [
        {
            "project": project,
            "task": task,
            "hours": activity["estimated_hours"],
            "notes": activity["description"],
            "source": "diary+llm",
            "confidence": "medium",
            "category": activity["category"],
        }
        for activity in activities
    ]


async def suggest(date: str, *, fetch_events: CalendarFetcher) -> dict[str, Any]:
    """Generate Harvest booking suggestions for a given date."""
    global _pattern_db
    errors: list[str] = []

    events = await _calendar_events(date, fetch_events)

    if not _pattern_db:
        try:
            await load()
        except Exception as e:
            errors.append(f"Harvest patterns: {e}")
            _pattern_db = harvest_patterns.build_pattern_db([])
    pattern_db = _pattern_db or harvest_patterns.build_pattern_db([])

    suggestions = _calendar_suggestions(events, pattern_db)

    transcript = await db.get_transcript_by_date(date)
    diary_activities = []
    if transcript:
        text = transcript.get("corrected_text") or transcript.get("raw_text", "")
        if text:
            diary_activities = await harvest_llm.extract_work_activities(text, date)
    suggestions.extend(_diary_suggestions(diary_activities, pattern_db))

    return {
        "date": date,
        "suggestions": suggestions,
        "total_hours": sum(s["hours"] for s in suggestions),
        "transcript_id": transcript["id"] if transcript else None,
        "pattern_db_loaded": bool(pattern_db.get("keyword_patterns")),
        "errors": errors,
    }
