"""Tests for the `harvest` module (REF-125): `suggest(date)` over fake calendar
and pattern data, the pattern-cache lifecycle, and the Harvest routes' contracts.

Run inside the webapp container so deps + env match prod:

    docker compose run --rm webapp pytest tests/test_harvest.py
"""

from __future__ import annotations

import httpx
import pytest
from fastapi.testclient import TestClient

import db
import harvest
import harvest_llm
import main
from tests.route_helpers import BEARER, auth

DAY = "2026-10-15"
PLANNING = {"id": 1, "name": "ACME"}, {"id": 10, "name": "Planning"}
OTHER = {"id": 2, "name": "Intern"}, {"id": 20, "name": "Selbstorganisation"}


def _entry(project_task, notes: str, hours: float = 1.0) -> dict:
    project, task = project_task
    return {"project": project, "task": task, "notes": notes, "hours": hours}


# Two matching entries make "sprint"/"planning" patterns on ACME (and ACME the
# default); the Selbstorganisation note picks the gap-fill project.
ENTRIES = [
    _entry(PLANNING, "Sprint Planning"),
    _entry(PLANNING, "Sprint Planning"),
    _entry(PLANNING, "Sprint Planning"),
    _entry(OTHER, "Selbstorganisation"),
]


def _graph_event(subject: str, start: str, end: str, show_as: str = "busy") -> dict:
    return {
        "subject": subject,
        "start": {"dateTime": f"{start}.0000000", "timeZone": "Europe/Berlin"},
        "end": {"dateTime": f"{end}.0000000", "timeZone": "Europe/Berlin"},
        "showAs": show_as,
    }


class FakeDb:
    """In-memory stand-in for the Harvest tables and the transcript lookup."""

    def __init__(self, entries: list[dict] | None = None, transcript: dict | None = None):
        self.entries = list(entries or [])
        self.transcript = transcript
        self.calls: list[str] = []
        self.fail_reading_entries = False

    async def ensure_harvest_table(self):
        self.calls.append("ensure")

    async def get_harvest_entries(self):
        self.calls.append("get")
        if self.fail_reading_entries:
            raise RuntimeError("db down")
        return list(self.entries)

    async def clear_harvest_entries(self):
        self.calls.append("clear")
        self.entries = []

    async def save_harvest_entries(self, entries):
        self.calls.append("save")
        self.entries = list(entries)

    async def get_harvest_entry_stats(self):
        return {"count": len(self.entries), "from_date": None, "to_date": None}

    async def get_transcript_by_date(self, date):
        return self.transcript


@pytest.fixture
def fake_db(monkeypatch) -> FakeDb:
    fake = FakeDb(ENTRIES)
    for name in (
        "ensure_harvest_table",
        "get_harvest_entries",
        "clear_harvest_entries",
        "save_harvest_entries",
        "get_harvest_entry_stats",
        "get_transcript_by_date",
    ):
        monkeypatch.setattr(db, name, getattr(fake, name))
    monkeypatch.setattr(harvest, "_pattern_db", None)
    return fake


def _calendar(*events: dict):
    async def fetch(date: str) -> list[dict]:
        assert date == DAY
        return list(events)

    return fetch


async def _no_activities(text: str, date: str) -> list[dict]:
    return []


@pytest.fixture(autouse=True)
def no_llm(monkeypatch):
    monkeypatch.setattr(harvest_llm, "extract_work_activities", _no_activities)


# ─── suggest(date) ───────────────────────────────────────────────────


async def test_suggest_matches_events_to_patterns_default_and_unknown(fake_db):
    fetch = _calendar(
        _graph_event("Sprint Planning ACME", "2026-10-15T09:00:00", "2026-10-15T10:00:00"),
        _graph_event("Lunch & Learn", "2026-10-15T11:00:00", "2026-10-15T11:30:00"),
    )

    result = await harvest.suggest(DAY, fetch_events=fetch)

    matched, fallback = result["suggestions"]
    assert matched["source"] == "calendar+pattern"
    assert matched["confidence"] == "high"
    assert matched["project"] == {"id": 1, "name": "ACME"}
    assert matched["task"] == {"id": 10, "name": "Planning"}
    assert matched["hours"] == 1.0
    assert (matched["start"], matched["end"]) == (
        "2026-10-15T09:00:00+02:00",
        "2026-10-15T10:00:00+02:00",
    )
    assert fallback["source"] == "calendar"
    assert fallback["confidence"] == "low"
    assert fallback["project"] == {"id": 1, "name": "ACME"}  # most used combo
    assert result["total_hours"] == sum(s["hours"] for s in result["suggestions"])
    assert result["pattern_db_loaded"] is True
    assert result["errors"] == []
    assert result["transcript_id"] is None


async def test_suggest_skips_free_and_tentative_events_and_sorts_by_start(fake_db):
    fetch = _calendar(
        _graph_event("Later", "2026-10-15T14:00:00", "2026-10-15T15:00:00"),
        _graph_event("Hold", "2026-10-15T08:00:00", "2026-10-15T09:00:00", show_as="tentative"),
        _graph_event("Free slot", "2026-10-15T09:00:00", "2026-10-15T10:00:00", show_as="free"),
        _graph_event("Earlier", "2026-10-15T10:00:00", "2026-10-15T11:00:00"),
    )

    result = await harvest.suggest(DAY, fetch_events=fetch)

    assert [s["notes"] for s in result["suggestions"]] == ["Earlier", "Later"]


async def test_suggest_without_patterns_leaves_project_and_task_empty(fake_db):
    fake_db.entries = []

    result = await harvest.suggest(
        DAY,
        fetch_events=_calendar(
            _graph_event("Standup", "2026-10-15T09:00:00", "2026-10-15T09:30:00")
        ),
    )

    [suggestion] = result["suggestions"]
    assert suggestion["project"] is None and suggestion["task"] is None
    assert suggestion["confidence"] == "low"
    assert result["pattern_db_loaded"] is False


async def test_suggest_adds_diary_activities_on_the_selbstorganisation_project(
    fake_db, monkeypatch
):
    fake_db.transcript = {"id": 7, "corrected_text": "Wrote docs.", "raw_text": "raw"}
    seen = {}

    async def activities(text: str, date: str) -> list[dict]:
        seen["args"] = (text, date)
        return [{"description": "Docs", "estimated_hours": 0.5, "category": "admin"}]

    monkeypatch.setattr(harvest_llm, "extract_work_activities", activities)

    result = await harvest.suggest(DAY, fetch_events=_calendar())

    assert seen["args"] == ("Wrote docs.", DAY)
    assert result["transcript_id"] == 7
    assert result["suggestions"] == [
        {
            "project": {"id": 2, "name": "Intern"},
            "task": {"id": 20, "name": "Selbstorganisation"},
            "hours": 0.5,
            "notes": "Docs",
            "source": "diary+llm",
            "confidence": "medium",
            "category": "admin",
        }
    ]
    assert result["total_hours"] == 0.5


async def test_suggest_diary_activities_without_selbstorganisation_have_no_project(
    fake_db, monkeypatch
):
    fake_db.entries = [_entry(PLANNING, "Sprint Planning")] * 2
    fake_db.transcript = {"id": 3, "raw_text": "Did things."}

    async def activities(text: str, date: str) -> list[dict]:
        assert text == "Did things."  # falls back to the raw text
        return [{"description": "Things", "estimated_hours": 2.0, "category": "other"}]

    monkeypatch.setattr(harvest_llm, "extract_work_activities", activities)

    result = await harvest.suggest(DAY, fetch_events=_calendar())

    [suggestion] = result["suggestions"]
    assert suggestion["project"] is None and suggestion["task"] is None
    assert suggestion["source"] == "diary+llm"


async def test_suggest_reports_a_pattern_load_failure_and_still_answers(fake_db):
    fake_db.fail_reading_entries = True

    result = await harvest.suggest(
        DAY,
        fetch_events=_calendar(
            _graph_event("Standup", "2026-10-15T09:00:00", "2026-10-15T09:30:00")
        ),
    )

    assert result["errors"] == ["Harvest patterns: db down"]
    assert result["pattern_db_loaded"] is False
    assert result["suggestions"][0]["project"] is None


# ─── Cache lifecycle ─────────────────────────────────────────────────


async def test_load_builds_once_from_stored_entries_then_reuses_the_cache(fake_db):
    assert harvest.is_loaded() is False

    first = await harvest.load()
    second = await harvest.load()

    assert first is second
    assert harvest.is_loaded() is True
    assert harvest.keyword_count() == len(first["keyword_patterns"]) > 0
    assert fake_db.calls.count("get") == 1


async def test_refresh_replaces_stored_entries_and_rebuilds_the_cache(fake_db):
    await harvest.load()
    new_entries = [_entry(OTHER, "Retro Board")] * 2

    pattern_db = await harvest.refresh(new_entries)

    assert fake_db.entries == new_entries
    assert fake_db.calls[-3:] == ["ensure", "clear", "save"]
    assert pattern_db is await harvest.load()
    assert "retro" in pattern_db["keyword_patterns"]
    assert "sprint" not in pattern_db["keyword_patterns"]


async def test_invalidate_clears_stored_entries_and_drops_the_cache(fake_db):
    await harvest.load()

    await harvest.invalidate()

    assert fake_db.entries == []
    assert harvest.is_loaded() is False
    assert harvest.keyword_count() == 0
    reloaded = await harvest.load()  # rebuilt, from nothing
    assert reloaded["keyword_patterns"] == {}


async def test_status_reports_entry_stats_and_cache_state(fake_db):
    before = await harvest.status()
    assert before["pattern_db_loaded"] is False and before["pattern_keywords"] == 0

    await harvest.load()
    after = await harvest.status()

    assert after["entries"]["count"] == len(ENTRIES)
    assert after["pattern_db_loaded"] is True
    assert after["pattern_keywords"] == harvest.keyword_count() > 0


# ─── Route contracts ─────────────────────────────────────────────────


@pytest.fixture
def client(fake_db, monkeypatch) -> TestClient:
    monkeypatch.setenv("IOS_BEARER_TOKEN", BEARER)
    monkeypatch.setattr(main, "HARVEST_ACCESS_TOKEN", "tok")
    monkeypatch.setattr(main, "HARVEST_USER_ID", "")
    return TestClient(main.app, headers=auth())


def test_pattern_status_route_shape(client):
    body = client.get("/api/harvest/pattern-status").json()

    assert set(body) == {"entries", "pattern_db_loaded", "pattern_keywords", "has_token"}
    assert body["has_token"] is True
    assert body["pattern_db_loaded"] is False


def test_load_patterns_route_fetches_pages_stores_entries_and_fills_the_cache(
    client, fake_db, monkeypatch
):
    page_two = "https://api.harvestapp.com/v2/time_entries?page=2"
    pages = {
        False: {"time_entries": ENTRIES[:2], "links": {"next": page_two}},
        True: {"time_entries": ENTRIES[2:], "links": {"next": None}},
    }

    def handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(200, json=pages["page=2" in str(request.url)])

    real_client = httpx.AsyncClient

    class Mocked(real_client):
        def __init__(self, *args, **kwargs):
            kwargs["transport"] = httpx.MockTransport(handler)
            super().__init__(*args, **kwargs)

    monkeypatch.setattr(httpx, "AsyncClient", Mocked)
    fake_db.entries = []

    body = client.post("/api/harvest/load-patterns").json()

    assert body["status"] == "ok"
    assert body["entries_fetched"] == len(ENTRIES)
    assert body["entries"]["count"] == len(ENTRIES)
    assert body["pattern_keywords"] == harvest.keyword_count() > 0
    assert harvest.is_loaded() is True


def test_load_patterns_route_without_a_token_is_a_500(client, monkeypatch):
    monkeypatch.setattr(main, "HARVEST_ACCESS_TOKEN", "")

    resp = client.post("/api/harvest/load-patterns")

    assert resp.status_code == 500
    assert resp.json() == {"error": "HARVEST_ACCESS_TOKEN not set"}


async def test_clear_patterns_route_empties_storage_and_cache(client, fake_db):
    await harvest.load()

    resp = client.post("/api/harvest/clear-patterns")

    assert resp.json() == {"status": "ok"}
    assert fake_db.entries == []
    assert harvest.is_loaded() is False


def test_suggest_route_passes_the_shared_calendar_fetch_to_the_module(client, monkeypatch):
    async def fetch(date: str) -> list[dict]:
        return [_graph_event("Sprint Planning", "2026-10-15T09:00:00", "2026-10-15T10:30:00")]

    monkeypatch.setattr(main, "_fetch_calendar_events", fetch)

    body = client.get("/api/harvest/suggest", params={"date": DAY}).json()

    assert set(body) == {
        "date",
        "suggestions",
        "total_hours",
        "transcript_id",
        "pattern_db_loaded",
        "errors",
    }
    assert body["date"] == DAY
    assert body["suggestions"][0]["notes"] == "Sprint Planning"
    assert body["suggestions"][0]["source"] == "calendar+pattern"
