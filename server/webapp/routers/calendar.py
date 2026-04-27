"""Calendar router — proxies Microsoft Graph for the iOS app.

Endpoints:

    GET /today/calendar?date=YYYY-MM-DD&rsvp_filter=accepted,tentative
    GET /calendar/event/{graph_event_id}

Bearer-token auth applied via the router-level dependency.

RSVP filtering happens server-side after Graph returns — Graph's `$filter`
support for `responseStatus.response` is unreliable.
"""

from __future__ import annotations

import logging
import os
from datetime import date as date_type, datetime, time, timedelta
from typing import Literal
from zoneinfo import ZoneInfo

from fastapi import APIRouter, Depends, HTTPException, Query, status
from pydantic import BaseModel, Field

from msgraph_client import (
    MSGraphError,
    MSGraphNotBootstrapped,
    get_client,
)
from routers.auth import require_bearer

logger = logging.getLogger(__name__)

LOCAL_TZ = ZoneInfo(os.getenv("TZ", "Europe/Berlin"))


router = APIRouter(dependencies=[Depends(require_bearer)])


# --- Pydantic v2 response models ------------------------------------------


RsvpStatus = Literal[
    "accepted",
    "tentative",
    "declined",
    "not_responded",
    "organizer",
    "none",
]


class Attendee(BaseModel):
    name: str = ""
    email: str = ""


class CalendarEvent(BaseModel):
    graph_event_id: str
    subject: str = ""
    start: str
    end: str
    is_all_day: bool = False
    show_as: str = ""
    rsvp_status: RsvpStatus = "none"
    organizer: Attendee = Field(default_factory=Attendee)
    attendees: list[Attendee] = Field(default_factory=list)
    body_preview: str = ""
    is_recurring: bool = False
    web_link: str = ""


class TodayCalendarResponse(BaseModel):
    date: str
    rsvp_filter: list[RsvpStatus]
    events: list[CalendarEvent]


# --- helpers --------------------------------------------------------------


_GRAPH_RSVP_MAP: dict[str, RsvpStatus] = {
    "accepted": "accepted",
    "tentativelyAccepted": "tentative",
    "declined": "declined",
    "notResponded": "not_responded",
    "organizer": "organizer",
    "none": "none",
}


def _normalise_rsvp(graph_value: str) -> RsvpStatus:
    return _GRAPH_RSVP_MAP.get(graph_value, "none")


def _parse_rsvp_filter(raw: str | None) -> list[RsvpStatus]:
    if not raw or raw.strip().lower() == "all":
        return ["accepted", "tentative", "declined", "not_responded", "organizer", "none"]
    requested = {part.strip().lower() for part in raw.split(",") if part.strip()}
    valid: set[RsvpStatus] = {
        "accepted", "tentative", "declined", "not_responded", "organizer", "none",
    }
    filtered = [s for s in valid if s in requested]
    if not filtered:
        # Fall back to default if user passed something unrecognised.
        return ["accepted", "tentative", "organizer"]
    return filtered


def _local_day_bounds_iso(date_str: str) -> tuple[str, str]:
    """Return (start_iso, end_iso) covering the local day in UTC for Graph."""
    try:
        d = date_type.fromisoformat(date_str)
    except ValueError as exc:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail=f"invalid_date: {exc}",
        ) from exc
    start_local = datetime.combine(d, time.min, tzinfo=LOCAL_TZ)
    end_local = start_local + timedelta(days=1)
    # Graph's calendarView accepts UTC ISO 8601.
    return (
        start_local.astimezone(ZoneInfo("UTC")).strftime("%Y-%m-%dT%H:%M:%S.0000000"),
        end_local.astimezone(ZoneInfo("UTC")).strftime("%Y-%m-%dT%H:%M:%S.0000000"),
    )


def _to_local_iso(graph_dt: dict | None) -> str:
    """Convert Graph's `{dateTime, timeZone}` pair to local ISO 8601."""
    if not graph_dt:
        return ""
    raw = graph_dt.get("dateTime", "")
    if not raw:
        return ""
    tz_name = graph_dt.get("timeZone") or "UTC"
    try:
        # Graph datetimes are naive; pair them with the declared zone.
        dt = datetime.fromisoformat(raw.replace("Z", ""))
        if dt.tzinfo is None:
            try:
                dt = dt.replace(tzinfo=ZoneInfo(tz_name))
            except Exception:
                dt = dt.replace(tzinfo=ZoneInfo("UTC"))
        return dt.astimezone(LOCAL_TZ).isoformat()
    except (ValueError, TypeError):
        return raw


def _shape_event(raw: dict) -> CalendarEvent:
    organizer_raw = (raw.get("organizer") or {}).get("emailAddress") or {}
    attendees_raw = raw.get("attendees") or []
    response_status = (raw.get("responseStatus") or {}).get("response", "none")

    attendees = []
    for a in attendees_raw:
        ea = a.get("emailAddress") or {}
        if ea:
            attendees.append(Attendee(name=ea.get("name", ""), email=ea.get("address", "")))

    return CalendarEvent(
        graph_event_id=raw.get("id", ""),
        subject=raw.get("subject") or "",
        start=_to_local_iso(raw.get("start")),
        end=_to_local_iso(raw.get("end")),
        is_all_day=bool(raw.get("isAllDay")),
        show_as=raw.get("showAs") or "",
        rsvp_status=_normalise_rsvp(response_status),
        organizer=Attendee(
            name=organizer_raw.get("name", ""),
            email=organizer_raw.get("address", ""),
        ),
        attendees=attendees,
        body_preview=(raw.get("bodyPreview") or "")[:500],
        is_recurring=raw.get("recurrence") is not None,
        web_link=raw.get("webLink") or "",
    )


# --- routes ---------------------------------------------------------------


@router.get("/today/calendar", response_model=TodayCalendarResponse)
async def today_calendar(
    date: str = Query(default_factory=lambda: date_type.today().isoformat()),
    rsvp_filter: str | None = Query(default="accepted,tentative,organizer"),
) -> TodayCalendarResponse:
    """List the day's calendar events. RSVP filter is applied server-side."""
    allowed = _parse_rsvp_filter(rsvp_filter)
    start_iso, end_iso = _local_day_bounds_iso(date)

    try:
        client = await get_client()
        data = await client.get_json(
            "/me/calendarView",
            params={
                "startDateTime": start_iso,
                "endDateTime": end_iso,
                "$top": 100,
                "$orderby": "start/dateTime",
                "$select": (
                    "id,subject,start,end,isAllDay,showAs,bodyPreview,"
                    "responseStatus,organizer,attendees,recurrence,webLink"
                ),
            },
        )
    except MSGraphNotBootstrapped as exc:
        logger.warning("MS Graph not bootstrapped: %s", exc)
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="msgraph_not_bootstrapped",
        ) from exc
    except MSGraphError as exc:
        logger.warning("MS Graph error on /today/calendar: %s", exc)
        raise HTTPException(
            status_code=status.HTTP_502_BAD_GATEWAY,
            detail=str(exc),
        ) from exc

    raw_events = data.get("value", [])
    events = [_shape_event(ev) for ev in raw_events]
    events = [ev for ev in events if ev.rsvp_status in allowed]
    events.sort(key=lambda ev: ev.start)
    return TodayCalendarResponse(date=date, rsvp_filter=allowed, events=events)


@router.get("/calendar/event/{graph_event_id}", response_model=CalendarEvent)
async def calendar_event(graph_event_id: str) -> CalendarEvent:
    """Single-event detail for enrichment (`tell me more about this meeting`)."""
    if not graph_event_id:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="missing_event_id",
        )
    try:
        client = await get_client()
        raw = await client.get_json(f"/me/events/{graph_event_id}")
    except MSGraphNotBootstrapped as exc:
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="msgraph_not_bootstrapped",
        ) from exc
    except MSGraphError as exc:
        raise HTTPException(
            status_code=status.HTTP_502_BAD_GATEWAY,
            detail=str(exc),
        ) from exc
    return _shape_event(raw)
