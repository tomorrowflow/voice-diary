"""Fixture-mode helpers.

When `MSGRAPH_FIXTURE_MODE=true` in `.env`, all routes that would otherwise
hit Microsoft Graph instead read canned JSON from `<DATA_DIR>/fixtures/`.
Events are shifted to "today" at read time so the same fixture file stays
useful from one day to the next without manual edits.

Flip the flag off (or remove the var) once Entra admin consent is granted
and the bootstrap script has run successfully.
"""

from __future__ import annotations

import json
import logging
import os
from datetime import date as date_type, datetime, time, timedelta
from pathlib import Path
from typing import Any
from zoneinfo import ZoneInfo

logger = logging.getLogger(__name__)


def fixture_mode() -> bool:
    raw = os.getenv("MSGRAPH_FIXTURE_MODE", "").strip().lower()
    return raw in ("1", "true", "yes", "on")


def _local_tz() -> ZoneInfo:
    return ZoneInfo(os.getenv("TZ", "Europe/Berlin"))


def _candidate_dirs() -> list[Path]:
    """Order:
      1. `<DATA_DIR>/fixtures/` — user-overridable, mounted from host.
      2. `<webapp>/fixture_data/` — defaults bundled in the image.
    """
    from paths import data_dir
    bundled = Path(__file__).resolve().parent / "fixture_data"
    return [data_dir() / "fixtures", bundled]


def _read_first(filename: str) -> dict | list | None:
    for base in _candidate_dirs():
        path = base / filename
        try:
            return json.loads(path.read_text())
        except FileNotFoundError:
            continue
        except json.JSONDecodeError as exc:
            logger.warning("fixture %s invalid JSON: %s", path, exc)
            return None
    logger.warning(
        "fixture %s not found in: %s",
        filename, ", ".join(str(b) for b in _candidate_dirs()),
    )
    return None


def _shift_iso_to_date(iso: str, target: date_type) -> str:
    """Replace the date portion of an ISO 8601 timestamp with `target`.

    Hours/minutes/seconds + zone are kept intact. If parsing fails, the
    original string is returned unchanged.
    """
    try:
        dt = datetime.fromisoformat(iso.replace("Z", "+00:00"))
    except ValueError:
        return iso
    new = dt.replace(year=target.year, month=target.month, day=target.day)
    return new.isoformat()


def _shift_graph_event_dates(event: dict, target: date_type) -> dict:
    """Mutate-then-return a Graph-shaped event with `start`/`end` shifted."""
    out = dict(event)
    for key in ("start", "end"):
        sub = out.get(key)
        if isinstance(sub, dict) and sub.get("dateTime"):
            sub = dict(sub)
            sub["dateTime"] = _shift_iso_to_date(sub["dateTime"], target)
            out[key] = sub
    return out


def load_calendar_events(date_str: str) -> list[dict]:
    """Return Graph-shaped events for the given local date from the fixture."""
    raw = _read_first("calendar_today.json")
    if raw is None:
        return []
    try:
        target = date_type.fromisoformat(date_str)
    except ValueError:
        target = date_type.today()
    events = raw.get("value", []) if isinstance(raw, dict) else raw
    return [_shift_graph_event_dates(ev, target) for ev in events or []]


def load_email_search(query: str) -> list[dict]:
    """Return Graph-shaped messages from the fixture, naïve-substring filtered."""
    raw = _read_first("email_search.json")
    if raw is None:
        return []
    messages = raw.get("value", []) if isinstance(raw, dict) else raw
    if not query.strip():
        return list(messages or [])
    needle = query.lower()
    out = []
    today = datetime.combine(
        date_type.today(), time.min, tzinfo=_local_tz()
    )
    # Re-base receivedDateTime so emails always look "recent".
    for raw_msg in messages or []:
        haystack = " ".join([
            str(raw_msg.get("subject", "")),
            str(raw_msg.get("bodyPreview", "")),
            str((raw_msg.get("from") or {}).get("emailAddress", {}).get("address", "")),
        ]).lower()
        if needle not in haystack:
            continue
        msg = dict(raw_msg)
        # Optional `receivedDaysAgo` field on the fixture lets us anchor it
        # to "today minus N days" so the timestamps don't go stale.
        days_ago = msg.pop("receivedDaysAgo", None)
        if isinstance(days_ago, (int, float)):
            ts = today - timedelta(days=int(days_ago), hours=2)
            msg["receivedDateTime"] = ts.astimezone(ZoneInfo("UTC")).strftime(
                "%Y-%m-%dT%H:%M:%SZ"
            )
        out.append(msg)
    return out


def load_calendar_event_by_id(graph_event_id: str) -> dict | None:
    """Return a single Graph-shaped event from the fixture, or None."""
    for ev in load_calendar_events(date_type.today().isoformat()):
        if ev.get("id") == graph_event_id:
            return ev
    return None


def status() -> str:
    """Probe value used by /health. 'fixture' is distinguishable from
    'ok' so the iOS UI can show a banner in dev mode."""
    return "fixture" if fixture_mode() else "skipped"


def __all_fixtures_present__() -> dict[str, Any]:
    """Diagnostic dict for human inspection."""
    return {
        "fixture_mode": fixture_mode(),
        "candidate_dirs": [str(b) for b in _candidate_dirs()],
        "calendar_today.json": _read_first("calendar_today.json") is not None,
        "email_search.json": _read_first("email_search.json") is not None,
    }
