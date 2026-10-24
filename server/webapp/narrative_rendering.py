"""
Narrative rendering — turns an enriched context plus the structured analysis
into the temporal-anchored diary Markdown and its document metadata.

Pure formatting: no LLM calls, no LightRAG, no network. The only outside input
is the wall clock (invalid entry dates fall back to it, and the footer stamps
the processing date), so tests control it by patching `datetime` here.
"""

import math
from datetime import datetime
from typing import NamedTuple

import analysis_route

MONTH_NAMES_DE = [
    "Januar", "Februar", "März", "April", "Mai", "Juni",
    "Juli", "August", "September", "Oktober", "November", "Dezember",
]
WEEKDAY_NAMES_DE = [
    "Montag", "Dienstag", "Mittwoch", "Donnerstag",
    "Freitag", "Samstag", "Sonntag",
]


class _DateParts(NamedTuple):
    iso_week: int
    quarter: int
    month: str
    weekday: str
    year: int
    day: int


def _date_parts(date_str: str) -> _DateParts:
    """Derive the calendar fields for an entry date; an unparseable date
    falls back to today."""
    try:
        date_obj = datetime.strptime(date_str, "%Y-%m-%d")
    except ValueError:
        date_obj = datetime.now()

    return _DateParts(
        iso_week=date_obj.isocalendar()[1],
        quarter=math.ceil(date_obj.month / 3),
        month=MONTH_NAMES_DE[date_obj.month - 1],
        weekday=WEEKDAY_NAMES_DE[date_obj.weekday()],
        year=date_obj.year,
        day=date_obj.day,
    )


def generate_narrative_document(enriched_ctx: dict, analysis: dict) -> str:
    """Build temporal-anchored narrative markdown from analysis results."""
    date_str = enriched_ctx["date"]
    iso_week, quarter, month, weekday, year, day = _date_parts(date_str)

    author = enriched_ctx["diary_author"]
    role = enriched_ctx["diary_author_role"]
    company = enriched_ctx["diary_author_company"]
    ctx = enriched_ctx["lightrag_context"]

    doc = ""

    # Title
    doc += f"# CTO Tagebuch - Kalenderwoche {iso_week}, {year}\n\n"
    doc += f"**Eintrag vom {weekday}, {day}. {month} {year}"
    doc += f" (Kalenderwoche {iso_week}, Q{quarter} {year})**\n"
    doc += f"**Autor:** {author} ({role}) bei {company}\n\n"
    doc += "---\n\n"

    # Summary
    doc += "## Zusammenfassung\n\n"
    doc += f"Am {day}. {month} {year}, "
    doc += f"während der Kalenderwoche {iso_week} im Q{quarter}, "
    doc += f"hat {author} folgende Themen bearbeitet:\n\n"

    # Historical context
    if ctx.get("available"):
        doc += "### Historischer Kontext\n\n"
        doc += f"{ctx['summary']}\n\n"

    # Full transcript
    doc += "---\n\n## Tagebucheintrag\n\n"
    doc += f"{enriched_ctx['normalized_text'] or ''}\n\n"

    # Relationships
    rels = analysis.get("relationships") or []
    if rels:
        doc += f"---\n\n## Beziehungen und Interaktionen (Kalenderwoche {iso_week}, {year})\n\n"
        for rel in rels:
            continuity = ""
            if rel.get("continuity") == "new":
                continuity = "Neu: "
            elif rel.get("continuity") == "changed":
                continuity = "Geändert: "
            rel_type = (rel.get("relationship") or "").replace("_", " ")
            doc += (
                f"{continuity}Während der Kalenderwoche {iso_week} von {year} "
                f"{rel.get('source', '')} {rel_type} {rel.get('target', '')}. "
                f"{rel.get('context', '')}\n\n"
            )

    # Projects
    projects = analysis.get("projects") or []
    if projects:
        doc += f"---\n\n## Projekte und Initiativen (Stand Kalenderwoche {iso_week}, {year})\n\n"
        for proj in projects:
            status_change = ""
            if proj.get("status_change") == "new":
                status_change = " (neu identifiziert)"
            elif proj.get("status_change") == "updated":
                status_change = " (Status aktualisiert)"
            doc += f"### Projekt: {proj.get('name', '')} (KW {iso_week}, {year}){status_change}\n\n"
            doc += f"Status: {proj.get('status', 'unbekannt')}. "
            doc += f"{proj.get('context', '')} "
            involved = proj.get("involved_persons") or []
            if involved:
                doc += f"Beteiligte Personen: {', '.join(involved)}. "
            techs = proj.get("technologies") or []
            if techs:
                doc += f"Technologien: {', '.join(techs)}. "
            doc += "\n\n"

    # Decisions
    decisions = analysis.get("decisions") or []
    if decisions:
        doc += f"---\n\n## Entscheidungen (Kalenderwoche {iso_week}, {year})\n\n"
        for dec in decisions:
            doc += (
                f"Am {day}. {month} {year} (KW {iso_week}) "
                f"hat {dec.get('decision_maker') or author} entschieden: "
                f"{dec.get('decision', '')} "
                f"Begründung: {dec.get('rationale') or 'Keine Angabe'}. "
            )
            impacted = dec.get("impacted_entities") or []
            if impacted:
                doc += f"Betroffen: {', '.join(impacted)}. "
            if dec.get("reverses_previous"):
                doc += "ACHTUNG: Diese Entscheidung revidiert eine frühere Entscheidung. "
            doc += "\n\n"

    # TODOs
    todos = analysis.get("todos") or []
    if todos:
        doc += "---\n\n## Aufgaben und TODOs\n\n"
        for todo in todos:
            recurrence = " (wiederkehrend)" if todo.get("recurrence") == "recurring" else ""
            first_mentioned = ""
            if todo.get("first_mentioned"):
                first_mentioned = f" Erstmals erwähnt: {todo['first_mentioned']}."
            doc += f"### Aufgabe: {todo.get('action', '')} (KW {iso_week}, {year}){recurrence}\n\n"
            doc += (
                f"Erstellt am {day}. {month} {year} "
                f"(Kalenderwoche {iso_week}, Q{quarter} {year}). "
                f"Verantwortlich: {todo.get('assignee') or 'Unbekannt'}. "
                f"Priorität: {todo.get('priority') or 'mittel'}. "
                f"{todo.get('context', '')}{first_mentioned}\n\n"
            )

    # Insights
    insights = analysis.get("insights") or []
    if insights:
        doc += f"---\n\n## Erkenntnisse und Learnings (Kalenderwoche {iso_week}, {year})\n\n"
        for insight in insights:
            novelty = ""
            if insight.get("novelty") == "new":
                novelty = "Neue Erkenntnis: "
            elif insight.get("novelty") == "confirming":
                novelty = "Bestätigung: "
            elif insight.get("novelty") == "contradicting":
                novelty = "Widerspruch zu früheren Erkenntnissen: "
            doc += (
                f"{novelty}{insight.get('insight', '')} "
                f"(Kategorie: {insight.get('category') or 'allgemein'}, "
                f"Relevanz: {insight.get('relevance') or 'Keine Angabe'}). "
            )
            if insight.get("related_to_previous"):
                doc += f"Bezug: {insight['related_to_previous']}. "
            doc += "\n\n"

    # Recurring themes
    themes = analysis.get("recurring_themes") or []
    if themes:
        doc += "---\n\n## Wiederkehrende Themen\n\n"
        for theme in themes:
            doc += (
                f"**{theme.get('theme', '')}** (Trend: {theme.get('trend', 'unbekannt')}): "
                f"{theme.get('context') or 'Keine Angabe'}. "
                f"Häufigkeit: {theme.get('frequency') or 'Unbekannt'}.\n\n"
            )

    # Metadata footer
    entities_ctx = enriched_ctx.get("entity_context") or {}
    persons_list = ", ".join(
        p["name"] for p in (entities_ctx.get("persons") or [])
    ) or "Keine"
    terms_list = ", ".join(
        t["term"] for t in (entities_ctx.get("terms") or [])
    ) or "Keine"

    doc += "---\n\n"
    doc += f"*Verarbeitet am {datetime.now().strftime('%Y-%m-%d')}. "
    doc += f"Datum: {date_str}, KW {iso_week}, Q{quarter} {year}. "
    doc += f"Personen: {persons_list}. "
    doc += f"Begriffe: {terms_list}.*\n"

    return doc


def build_document_metadata(enriched_ctx: dict, *, route: str = analysis_route.LOCAL) -> dict:
    """Build metadata dict for the processed document. `route` is the analysis
    route that produced the analysis (BAR-04); it is stored as `analysis_route`."""
    date_str = enriched_ctx["date"]
    parts = _date_parts(date_str)

    return {
        "date": date_str,
        "iso_week": parts.iso_week,
        "quarter": f"Q{parts.quarter}",
        "month": parts.month,
        "year": parts.year,
        "source": "voice_diary",
        "type": "cto_journal",
        "language": "de",
        "author": enriched_ctx["diary_author"],
        "analysis_route": route,
    }
