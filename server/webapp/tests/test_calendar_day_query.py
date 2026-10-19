"""REF-120: the iOS calendar route, the HTMX `/api/calendar/{date}` route and
Harvest's `/api/harvest/suggest` all ask Graph for a day through one
`MSGraphClient.events_for_day`, and read its times with one timezone rule."""

from __future__ import annotations

from datetime import date
from zoneinfo import ZoneInfo

import httpx
import pytest
from fastapi.testclient import TestClient

import db
import main
import msgraph_client
import routers.calendar as calendar_router
from tests.route_helpers import BEARER, auth, client_for, graph_client, serve_graph

BERLIN = ZoneInfo("Europe/Berlin")

# (local day, expected UTC window): a normal day, spring-forward (23 h), fall-back (25 h).
DAY_WINDOWS = [
    ("2026-10-15", "2026-10-14T22:00:00.0000000", "2026-10-15T22:00:00.0000000"),
    ("2026-03-29", "2026-03-28T23:00:00.0000000", "2026-03-29T22:00:00.0000000"),
    ("2026-10-25", "2026-10-24T22:00:00.0000000", "2026-10-25T23:00:00.0000000"),
]

# Graph's own shape; 22:00Z on the 15th is local midnight of the 16th.
GRAPH_EVENTS = [
    {
        "id": "ev-late",
        "subject": "Late sync",
        "start": {"dateTime": "2026-10-15T21:30:00.0000000", "timeZone": "UTC"},
        "end": {"dateTime": "2026-10-15T22:00:00.0000000", "timeZone": "UTC"},
        "showAs": "busy",
        "responseStatus": {"response": "accepted"},
    },
    {
        "id": "ev-early",
        "subject": "Standup",
        "start": {"dateTime": "2026-10-15T07:00:00.0000000", "timeZone": "UTC"},
        "end": {"dateTime": "2026-10-15T07:30:00.0000000", "timeZone": "UTC"},
        "showAs": "busy",
        "responseStatus": {"response": "organizer"},
    },
]


class FakeGraph:
    """A real `MSGraphClient` over a mock transport that records each request."""

    def __init__(self, monkeypatch, tmp_path, events=GRAPH_EVENTS) -> None:
        self.requests: list[httpx.Request] = []

        def handler(request: httpx.Request) -> httpx.Response:
            self.requests.append(request)
            return httpx.Response(200, json={"value": events})

        self.client = graph_client(monkeypatch, tmp_path, handler)

    def queries(self) -> list[tuple[str, dict[str, str]]]:
        return [(r.url.path, dict(r.url.params)) for r in self.requests]


@pytest.fixture
def graph(monkeypatch, tmp_path) -> FakeGraph:
    fake = FakeGraph(monkeypatch, tmp_path)
    serve_graph(monkeypatch, calendar_router, fake.client)

    async def get_client() -> msgraph_client.MSGraphClient:
        return fake.client

    monkeypatch.setattr(msgraph_client, "get_client", get_client)
    return fake


@pytest.fixture
def app_client(monkeypatch) -> TestClient:
    monkeypatch.setenv("IOS_BEARER_TOKEN", BEARER)
    monkeypatch.delenv("MSGRAPH_FIXTURE_MODE", raising=False)
    monkeypatch.setattr(main, "_harvest_pattern_db", {})

    async def nothing(*_args, **_kwargs):
        return None

    async def no_entries(*_args, **_kwargs):
        return []

    monkeypatch.setattr(db, "ensure_harvest_table", nothing)
    monkeypatch.setattr(db, "get_harvest_entries", no_entries)
    monkeypatch.setattr(db, "get_transcript_by_date", nothing)
    return TestClient(main.app)


def _ios(monkeypatch, day: str) -> dict:
    resp = client_for(calendar_router.router, monkeypatch).get(
        "/today/calendar", params={"date": day, "rsvp_filter": "all"}, headers=auth()
    )
    assert resp.status_code == 200, resp.text
    return resp.json()


@pytest.mark.parametrize("day, start, end", DAY_WINDOWS)
def test_day_window_is_the_local_midnight_to_midnight_in_utc(monkeypatch, day, start, end):
    monkeypatch.setattr(msgraph_client, "LOCAL_TZ", BERLIN)

    assert msgraph_client.local_day_bounds_utc(date.fromisoformat(day)) == (start, end)


@pytest.mark.parametrize("day, start, end", DAY_WINDOWS)
def test_every_consumer_sends_the_same_single_calendar_view_query(
    monkeypatch, graph, app_client, day, start, end
):
    monkeypatch.setattr(msgraph_client, "LOCAL_TZ", BERLIN)

    _ios(monkeypatch, day)
    ios_queries, graph.requests = graph.queries(), []
    app_client.get(f"/api/calendar/{day}", headers=auth())
    htmx_queries, graph.requests = graph.queries(), []
    app_client.get("/api/harvest/suggest", params={"date": day}, headers=auth())
    harvest_queries = graph.queries()

    assert len(ios_queries) == len(htmx_queries) == len(harvest_queries) == 1
    assert ios_queries == htmx_queries == harvest_queries
    path, params = ios_queries[0]
    assert path.endswith("/me/calendarView")
    assert params["startDateTime"] == start
    assert params["endDateTime"] == end
    assert params["$top"] == "100"
    assert params["$orderby"] == "start/dateTime"


def test_ios_route_response_is_unchanged(monkeypatch, graph):
    monkeypatch.setattr(msgraph_client, "LOCAL_TZ", BERLIN)

    body = _ios(monkeypatch, "2026-10-15")

    assert body["date"] == "2026-10-15"
    assert [(e["graph_event_id"], e["start"], e["end"]) for e in body["events"]] == [
        ("ev-early", "2026-10-15T09:00:00+02:00", "2026-10-15T09:30:00+02:00"),
        ("ev-late", "2026-10-15T23:30:00+02:00", "2026-10-16T00:00:00+02:00"),
    ]


def test_htmx_route_returns_graph_events_untouched(graph, app_client):
    resp = app_client.get("/api/calendar/2026-10-15", headers=auth())

    assert resp.status_code == 200
    assert resp.json() == {"date": "2026-10-15", "events": GRAPH_EVENTS}


def test_htmx_route_still_answers_empty_for_a_bad_date_or_a_graph_failure(
    monkeypatch, tmp_path, app_client
):
    assert app_client.get("/api/calendar/not-a-date", headers=auth()).json() == {
        "date": "not-a-date",
        "events": [],
    }

    failing = graph_client(
        monkeypatch, tmp_path, lambda _request: httpx.Response(503, json={})
    )

    async def get_client() -> msgraph_client.MSGraphClient:
        return failing

    monkeypatch.setattr(msgraph_client, "get_client", get_client)

    assert app_client.get("/api/calendar/2026-10-15", headers=auth()).json() == {
        "date": "2026-10-15",
        "events": [],
    }


def test_harvest_reads_times_with_the_same_rule_as_the_ios_route(monkeypatch, graph, app_client):
    monkeypatch.setattr(msgraph_client, "LOCAL_TZ", BERLIN)

    ios = {e["graph_event_id"]: e for e in _ios(monkeypatch, "2026-10-15")["events"]}
    resp = app_client.get("/api/harvest/suggest", params={"date": "2026-10-15"}, headers=auth())

    assert resp.status_code == 200
    suggestions = {s["notes"]: s for s in resp.json()["suggestions"]}
    for event_id, subject in (("ev-early", "Standup"), ("ev-late", "Late sync")):
        assert suggestions[subject]["start"] == ios[event_id]["start"]
        assert suggestions[subject]["end"] == ios[event_id]["end"]
    # The event ending at the local midnight lands on the next local day, offset intact.
    assert suggestions["Late sync"]["end"] == "2026-10-16T00:00:00+02:00"


@pytest.mark.parametrize(
    "graph_dt, expected",
    [
        ({"dateTime": "2026-03-29T00:30:00.0000000", "timeZone": "UTC"}, "2026-03-29T01:30:00+01:00"),
        ({"dateTime": "2026-03-29T01:30:00.0000000", "timeZone": "UTC"}, "2026-03-29T03:30:00+02:00"),
        ({"dateTime": "2026-10-25T00:30:00.0000000", "timeZone": "UTC"}, "2026-10-25T02:30:00+02:00"),
        ({"dateTime": "2026-10-25T01:30:00.0000000", "timeZone": "UTC"}, "2026-10-25T02:30:00+01:00"),
        ({"dateTime": "2026-10-15T09:00:00", "timeZone": "Europe/Berlin"}, "2026-10-15T09:00:00+02:00"),
        ({"dateTime": "2026-10-15T09:00:00", "timeZone": "No/Such_Zone"}, "2026-10-15T11:00:00+02:00"),
        ({"dateTime": "", "timeZone": "UTC"}, ""),
        (None, ""),
    ],
)
def test_to_local_iso_follows_dst_and_the_declared_zone(monkeypatch, graph_dt, expected):
    monkeypatch.setattr(msgraph_client, "LOCAL_TZ", BERLIN)

    assert msgraph_client.to_local_iso(graph_dt) == expected
