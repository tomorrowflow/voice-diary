"""Pydantic v2 models for the iOS session manifest.

Mirrors `SPEC.md` §10.3. The iOS app POSTs `manifest.json` as one part of
a multipart/form-data bundle alongside per-segment `.m4a` files.

Validation here is intentionally narrow: anything missing or malformed
gets rejected by FastAPI with a 422, so iOS gets a precise error rather
than a half-processed session.
"""

from __future__ import annotations

from datetime import date as date_type, datetime
from typing import Annotated, Literal

from pydantic import BaseModel, ConfigDict, Field, model_validator


# --- value types -----------------------------------------------------------

TodoStatus = Literal["Offen", "InArbeit", "Abgeschlossen", "Blockiert"]
TodoType = Literal["explicit", "implicit"]
SegmentType = Literal["calendar_event", "drive_by", "free_reflection", "empty_block"]
RsvpStatus = Literal[
    "accepted", "tentative", "declined", "not_responded", "organizer", "none"
]
LanguageTag = Annotated[str, Field(pattern=r"^[a-z]{2}(-[A-Z]{2})?$")]


# --- audio ----------------------------------------------------------------


class AudioCodec(BaseModel):
    model_config = ConfigDict(extra="forbid")

    codec: Literal["aac-lc"]
    sample_rate: int = Field(ge=8000, le=48000)
    channels: int = Field(ge=1, le=2)
    bitrate: int = Field(ge=16000, le=256000)


# --- calendar reference ---------------------------------------------------


class CalendarRef(BaseModel):
    model_config = ConfigDict(extra="ignore")

    graph_event_id: str
    title: str = ""
    start: str
    end: str
    attendees: list[str] = Field(default_factory=list)
    rsvp_status: RsvpStatus = "none"


# --- todos ----------------------------------------------------------------


class Todo(BaseModel):
    model_config = ConfigDict(extra="ignore")

    text: str
    type: TodoType
    due: str | None = None
    status: TodoStatus = "Offen"
    source_segment_id: str | None = None


class TodoRejected(BaseModel):
    model_config = ConfigDict(extra="ignore")

    text: str
    type: TodoType = "implicit"
    source_segment_id: str | None = None


# --- AI prompts -----------------------------------------------------------


class AiPrompt(BaseModel):
    """Free-form record of AI prompts/answers issued during the walkthrough.

    Fields vary by `role` (opener / follow_up / enrichment_query /
    enrichment_answer / closing / gap). Kept loose on purpose — the iOS
    app evolves these and the server only stores them.
    """

    model_config = ConfigDict(extra="allow")

    at: str
    segment_id: str | None = None
    role: str
    text: str | None = None


# --- segments -------------------------------------------------------------


class TimeRange(BaseModel):
    model_config = ConfigDict(extra="forbid")

    start: str  # "HH:MM"
    end: str  # "HH:MM"


class SegmentBase(BaseModel):
    model_config = ConfigDict(extra="ignore")

    segment_id: str
    segment_type: SegmentType
    audio_file: str
    transcript: str = ""
    language: LanguageTag = "de-DE"


class CalendarEventSegment(SegmentBase):
    segment_type: Literal["calendar_event"] = "calendar_event"
    calendar_ref: CalendarRef
    todos_detected: list[Todo] = Field(default_factory=list)
    linked_seed_ids: list[str] = Field(default_factory=list)


class DriveBySegment(SegmentBase):
    segment_type: Literal["drive_by"] = "drive_by"
    captured_at: str
    linked_calendar_event_id: str | None = None
    seed_id: str | None = None


class FreeReflectionSegment(SegmentBase):
    segment_type: Literal["free_reflection"] = "free_reflection"
    captured_at: str | None = None


class EmptyBlockSegment(SegmentBase):
    segment_type: Literal["empty_block"] = "empty_block"
    time_range: TimeRange


Segment = Annotated[
    CalendarEventSegment
    | DriveBySegment
    | FreeReflectionSegment
    | EmptyBlockSegment,
    Field(discriminator="segment_type"),
]


# --- manifest -------------------------------------------------------------


class Manifest(BaseModel):
    model_config = ConfigDict(extra="ignore")

    session_id: str
    date: date_type
    device: str
    app_version: str
    locale_primary: LanguageTag = "de-DE"
    audio_codec: AudioCodec
    segments: list[Segment]
    todos_implicit_confirmed: list[Todo] = Field(default_factory=list)
    todos_implicit_rejected: list[TodoRejected] = Field(default_factory=list)
    drive_by_seeds_unsurfaced: list[dict] = Field(default_factory=list)
    raw_session_audio: str | None = None
    ai_prompts: list[AiPrompt] = Field(default_factory=list)
    response_language_setting: Literal["match_input", "de", "en"] = "match_input"

    @model_validator(mode="after")
    def _check_segment_audio_paths(self) -> "Manifest":
        seen: set[str] = set()
        for seg in self.segments:
            if not seg.audio_file:
                raise ValueError(f"segment {seg.segment_id}: missing audio_file")
            if ".." in seg.audio_file or seg.audio_file.startswith("/"):
                raise ValueError(
                    f"segment {seg.segment_id}: audio_file must be a relative path"
                )
            if seg.audio_file in seen:
                raise ValueError(
                    f"segment {seg.segment_id}: duplicate audio_file {seg.audio_file}"
                )
            seen.add(seg.audio_file)
        return self


# --- response models ------------------------------------------------------


class SegmentResult(BaseModel):
    segment_id: str
    status: Literal["processed", "failed", "pending_analysis"]
    transcript_id: int | None = None
    error: str | None = None


class SessionAccepted(BaseModel):
    status: Literal["accepted"] = "accepted"
    session_id: str
    received_at: str
    processing_status_url: str
    segments: list[SegmentResult] = Field(default_factory=list)


class SessionStatus(BaseModel):
    session_id: str
    received_at: str
    state: Literal["processing", "done", "failed", "partial"]
    segments: list[SegmentResult]


def utcnow_iso() -> str:
    return datetime.utcnow().isoformat(timespec="seconds") + "Z"
