"""Email-result projection for `GET /email/search`.

Pure: Graph-shaped messages in, the date-filtered link list and the compact
source text for the summariser out. Retrieval, auth and upstream failures
stay in `routers/email.py`.
"""

from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime


@dataclass(frozen=True)
class EmailResults:
    """`links` keep the retrieval order; each has the `EmailLink` fields."""

    sources_text: str
    links: list[dict[str, str]]


def prepare_email_results(
    messages: list[dict], from_iso: str | None, to_iso: str | None
) -> EmailResults:
    """Filter `messages` to the inclusive `from_iso`..`to_iso` window and project them."""
    kept = _filter_by_date(messages, from_iso, to_iso)
    return EmailResults(
        sources_text=_format_sources(kept),
        links=[_shape_message(raw) for raw in kept],
    )


def _parse_iso(value: str | None) -> datetime | None:
    if not value:
        return None
    try:
        return datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None


def _filter_by_date(
    messages: list[dict], from_iso: str | None, to_iso: str | None
) -> list[dict]:
    if not from_iso and not to_iso:
        return messages

    start = _parse_iso(from_iso)
    end = _parse_iso(to_iso)
    out: list[dict] = []
    for raw in messages:
        received = _parse_iso(raw.get("receivedDateTime"))
        if received is None:
            continue
        if start and received < start:
            continue
        if end and received > end:
            continue
        out.append(raw)
    return out


def _shape_message(raw: dict) -> dict[str, str]:
    sender_obj = (raw.get("from") or {}).get("emailAddress") or {}
    return {
        "id": raw.get("id", ""),
        "subject": raw.get("subject") or "",
        "sender": sender_obj.get("name") or sender_obj.get("address") or "",
        "received": raw.get("receivedDateTime") or "",
        "web_link": raw.get("webLink") or "",
    }


def _format_sources(messages: list[dict]) -> str:
    """Compact text block fed to the summariser. Keep it short — Piper
    will speak only 2–3 sentences anyway."""
    parts: list[str] = []
    for raw in messages:
        link = _shape_message(raw)
        body = (raw.get("bodyPreview") or "").strip().replace("\n", " ")
        parts.append(
            f"- Von {link['sender']} ({link['received']}): {link['subject']}. {body[:400]}"
        )
    return "\n".join(parts) or "(keine Treffer)"
