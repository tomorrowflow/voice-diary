"""Characterization of narrative Markdown + document metadata rendering.

The expectations below were captured from the renderer while it still lived in
`document_processor` and must not change: the saved diary documents (and the
LightRAG chunks split from them) depend on this exact text. Nothing here
touches the network; only the wall clock is controlled.
"""
import datetime as real_datetime
import os
import sys

import pytest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

import document_processor
import analysis_route

NOW = real_datetime.datetime(2027, 1, 2, 3, 4, 5)


@pytest.fixture(autouse=True)
def frozen_clock(monkeypatch):
    class FrozenDatetime(real_datetime.datetime):
        @classmethod
        def now(cls, tz=None):
            return NOW

    monkeypatch.setattr(document_processor, "datetime", FrozenDatetime)


def render(date="2026-05-10", analysis=None, **overrides):
    enriched = {
        "date": date,
        "diary_author": "Auth",
        "diary_author_role": "CTO",
        "diary_author_company": "Co",
        "lightrag_context": {"available": False, "summary": "ignored"},
        "normalized_text": "Text",
        "entity_context": None,
        **overrides,
    }
    return (
        document_processor.generate_narrative_document(enriched, analysis or {}),
        document_processor.build_document_metadata(enriched),
    )


def lines(text):
    return text.split("\n")


FULL_ANALYSIS = {
    "relationships": [
        {"source": "A", "relationship": "works_with", "target": "B",
         "context": "ctx", "continuity": "new"},
        {"source": "C", "relationship": "reports_to", "target": "D",
         "context": "", "continuity": "changed"},
    ],
    "projects": [
        {"name": "P1", "status": "aktiv", "context": "c",
         "involved_persons": ["X", "Y"], "technologies": ["py", "go"],
         "status_change": "new"},
        {"name": "P2", "status_change": "updated"},
    ],
    "decisions": [
        {"decision_maker": "M", "decision": "d", "rationale": "r",
         "impacted_entities": ["Z"], "reverses_previous": True},
        {"decision": "d2"},
    ],
    "todos": [
        {"action": "a", "recurrence": "recurring",
         "first_mentioned": "2026-01-01", "assignee": "Q",
         "priority": "hoch", "context": "c"},
        {"action": "b"},
    ],
    "insights": [
        {"insight": "i1", "novelty": "new", "category": "tech",
         "relevance": "hoch", "related_to_previous": "prev"},
        {"insight": "i2", "novelty": "confirming"},
        {"insight": "i3", "novelty": "contradicting"},
        {"insight": "i4"},
    ],
    "recurring_themes": [
        {"theme": "T", "trend": "up", "context": "c", "frequency": "oft"},
        {},
    ],
}

FULL_EXPECTED = "\n".join([
    "# CTO Tagebuch - Kalenderwoche 19, 2026",
    "",
    "**Eintrag vom Sonntag, 10. Mai 2026 (Kalenderwoche 19, Q2 2026)**",
    "**Autor:** Auth (CTO) bei Co",
    "",
    "---",
    "",
    "## Zusammenfassung",
    "",
    "Am 10. Mai 2026, während der Kalenderwoche 19 im Q2, hat Auth folgende Themen bearbeitet:",
    "",
    "### Historischer Kontext",
    "",
    "Hist",
    "",
    "summary",
    "",
    "---",
    "",
    "## Tagebucheintrag",
    "",
    "Text ä",
    "zwei",
    "",
    "---",
    "",
    "## Beziehungen und Interaktionen (Kalenderwoche 19, 2026)",
    "",
    "Neu: Während der Kalenderwoche 19 von 2026 A works with B. ctx",
    "",
    "Geändert: Während der Kalenderwoche 19 von 2026 C reports to D. ",
    "",
    "---",
    "",
    "## Projekte und Initiativen (Stand Kalenderwoche 19, 2026)",
    "",
    "### Projekt: P1 (KW 19, 2026) (neu identifiziert)",
    "",
    "Status: aktiv. c Beteiligte Personen: X, Y. Technologien: py, go. ",
    "",
    "### Projekt: P2 (KW 19, 2026) (Status aktualisiert)",
    "",
    "Status: unbekannt.  ",
    "",
    "---",
    "",
    "## Entscheidungen (Kalenderwoche 19, 2026)",
    "",
    "Am 10. Mai 2026 (KW 19) hat M entschieden: d Begründung: r. Betroffen: Z."
    " ACHTUNG: Diese Entscheidung revidiert eine frühere Entscheidung. ",
    "",
    "Am 10. Mai 2026 (KW 19) hat Auth entschieden: d2 Begründung: Keine Angabe. ",
    "",
    "---",
    "",
    "## Aufgaben und TODOs",
    "",
    "### Aufgabe: a (KW 19, 2026) (wiederkehrend)",
    "",
    "Erstellt am 10. Mai 2026 (Kalenderwoche 19, Q2 2026). Verantwortlich: Q."
    " Priorität: hoch. c Erstmals erwähnt: 2026-01-01.",
    "",
    "### Aufgabe: b (KW 19, 2026)",
    "",
    "Erstellt am 10. Mai 2026 (Kalenderwoche 19, Q2 2026). Verantwortlich: Unbekannt."
    " Priorität: mittel. ",
    "",
    "---",
    "",
    "## Erkenntnisse und Learnings (Kalenderwoche 19, 2026)",
    "",
    "Neue Erkenntnis: i1 (Kategorie: tech, Relevanz: hoch). Bezug: prev. ",
    "",
    "Bestätigung: i2 (Kategorie: allgemein, Relevanz: Keine Angabe). ",
    "",
    "Widerspruch zu früheren Erkenntnissen: i3 (Kategorie: allgemein, Relevanz: Keine Angabe). ",
    "",
    "i4 (Kategorie: allgemein, Relevanz: Keine Angabe). ",
    "",
    "---",
    "",
    "## Wiederkehrende Themen",
    "",
    "**T** (Trend: up): c. Häufigkeit: oft.",
    "",
    "**** (Trend: unbekannt): Keine Angabe. Häufigkeit: Unbekannt.",
    "",
    "---",
    "",
    "*Verarbeitet am 2027-01-02. Datum: 2026-05-10, KW 19, Q2 2026."
    " Personen: Anna, Bo. Begriffe: LLM.*",
    "",
])

EMPTY_EXPECTED = "\n".join([
    "# CTO Tagebuch - Kalenderwoche 19, 2026",
    "",
    "**Eintrag vom Sonntag, 10. Mai 2026 (Kalenderwoche 19, Q2 2026)**",
    "**Autor:** Auth (CTO) bei Co",
    "",
    "---",
    "",
    "## Zusammenfassung",
    "",
    "Am 10. Mai 2026, während der Kalenderwoche 19 im Q2, hat Auth folgende Themen bearbeitet:",
    "",
    "---",
    "",
    "## Tagebucheintrag",
    "",
    "",
    "",
    "---",
    "",
    "*Verarbeitet am 2027-01-02. Datum: 2026-05-10, KW 19, Q2 2026."
    " Personen: Keine. Begriffe: Keine.*",
    "",
])


def test_full_document_is_byte_for_byte_stable():
    md, _ = render(
        analysis=FULL_ANALYSIS,
        lightrag_context={"available": True, "summary": "Hist\n\nsummary"},
        normalized_text="Text ä\nzwei",
        entity_context={
            "persons": [{"name": "Anna"}, {"name": "Bo"}],
            "terms": [{"term": "LLM"}],
        },
    )
    assert md == FULL_EXPECTED


@pytest.mark.parametrize("analysis", [
    {},
    {k: [] for k in FULL_ANALYSIS},
    {k: None for k in FULL_ANALYSIS},
])
def test_absent_and_empty_sections_render_only_the_frame(analysis):
    md, _ = render(analysis=analysis, normalized_text=None)
    assert md == EMPTY_EXPECTED


@pytest.mark.parametrize("section, heading", [
    ("relationships", "## Beziehungen und Interaktionen"),
    ("projects", "## Projekte und Initiativen"),
    ("decisions", "## Entscheidungen"),
    ("todos", "## Aufgaben und TODOs"),
    ("insights", "## Erkenntnisse und Learnings"),
    ("recurring_themes", "## Wiederkehrende Themen"),
])
def test_each_section_appears_only_when_populated(section, heading):
    populated, _ = render(analysis={section: FULL_ANALYSIS[section]})
    assert any(line.startswith(heading) for line in lines(populated))
    for other, other_heading in [
        ("relationships", "## Beziehungen"), ("projects", "## Projekte"),
        ("decisions", "## Entscheidungen"), ("todos", "## Aufgaben"),
        ("insights", "## Erkenntnisse"), ("recurring_themes", "## Wiederkehrende"),
    ]:
        if other != section:
            assert other_heading not in populated


def test_sections_keep_their_heading_order():
    md, _ = render(analysis=FULL_ANALYSIS)
    headings = [line for line in lines(md) if line.startswith("## ")]
    assert [h.split(" (")[0] for h in headings] == [
        "## Zusammenfassung",
        "## Tagebucheintrag",
        "## Beziehungen und Interaktionen",
        "## Projekte und Initiativen",
        "## Entscheidungen",
        "## Aufgaben und TODOs",
        "## Erkenntnisse und Learnings",
        "## Wiederkehrende Themen",
    ]


def test_historical_context_requires_available_flag():
    shown, _ = render(lightrag_context={"available": True, "summary": "S"})
    hidden, _ = render(lightrag_context={"available": False, "summary": "S"})
    missing, _ = render(lightrag_context={})
    assert "### Historischer Kontext\n\nS\n\n" in shown
    assert "Historischer Kontext" not in hidden
    assert "Historischer Kontext" not in missing


# date -> (weekday, day, month, ISO week, heading year, quarter)
DATE_CASES = [
    ("2026-01-01", "Donnerstag", 1, "Januar", 1, 2026, 1),
    ("2024-12-30", "Montag", 30, "Dezember", 1, 2024, 4),  # ISO week 1 of 2025
    ("2021-01-03", "Sonntag", 3, "Januar", 53, 2021, 1),  # ISO week 53 of 2020
    ("2026-03-31", "Dienstag", 31, "März", 14, 2026, 1),
    ("2026-04-01", "Mittwoch", 1, "April", 14, 2026, 2),
    ("2026-06-30", "Dienstag", 30, "Juni", 27, 2026, 2),
    ("2026-07-01", "Mittwoch", 1, "Juli", 27, 2026, 3),
    ("2026-09-30", "Mittwoch", 30, "September", 40, 2026, 3),
    ("2026-10-01", "Donnerstag", 1, "Oktober", 40, 2026, 4),
    ("2026-12-31", "Donnerstag", 31, "Dezember", 53, 2026, 4),
]


@pytest.mark.parametrize("date, weekday, day, month, week, year, quarter", DATE_CASES)
def test_date_derived_fields_at_week_year_and_quarter_boundaries(
    date, weekday, day, month, week, year, quarter
):
    md, meta = render(date=date, analysis={"decisions": [{"decision": "d"}]})
    out = lines(md)
    assert out[0] == f"# CTO Tagebuch - Kalenderwoche {week}, {year}"
    assert out[2] == (
        f"**Eintrag vom {weekday}, {day}. {month} {year}"
        f" (Kalenderwoche {week}, Q{quarter} {year})**"
    )
    assert (
        f"Am {day}. {month} {year}, während der Kalenderwoche {week} im Q{quarter}, "
        "hat Auth folgende Themen bearbeitet:"
    ) in out
    assert f"Am {day}. {month} {year} (KW {week}) hat Auth entschieden: d Begründung: Keine Angabe. " in out
    assert out[-2] == (
        f"*Verarbeitet am 2027-01-02. Datum: {date}, KW {week}, Q{quarter} {year}."
        " Personen: Keine. Begriffe: Keine.*"
    )
    assert meta == {
        "date": date,
        "iso_week": week,
        "quarter": f"Q{quarter}",
        "month": month,
        "year": year,
        "source": "voice_diary",
        "type": "cto_journal",
        "language": "de",
        "author": "Auth",
        "analysis_route": analysis_route.LOCAL,
    }


@pytest.mark.parametrize("bad_date", ["garbage", "", "2026-02-29", "2026-5-1x"])
def test_invalid_date_falls_back_to_the_clock_but_keeps_the_raw_date_in_footer(bad_date):
    md, meta = render(date=bad_date)
    out = lines(md)
    # NOW = Saturday 2027-01-02, ISO week 53, Q1
    assert out[0] == "# CTO Tagebuch - Kalenderwoche 53, 2027"
    assert out[2] == "**Eintrag vom Samstag, 2. Januar 2027 (Kalenderwoche 53, Q1 2027)**"
    assert out[-2] == (
        f"*Verarbeitet am 2027-01-02. Datum: {bad_date}, KW 53, Q1 2027."
        " Personen: Keine. Begriffe: Keine.*"
    )
    assert meta["date"] == bad_date
    assert (meta["iso_week"], meta["quarter"], meta["month"], meta["year"]) == (
        53, "Q1", "Januar", 2027,
    )


def test_footer_processed_date_is_the_clock_not_the_entry_date():
    md, _ = render(date="2026-05-10")
    assert "*Verarbeitet am 2027-01-02. Datum: 2026-05-10," in md


def test_metadata_route_is_recorded_and_defaults_to_local():
    enriched = {"date": "2026-05-10", "diary_author": "Auth"}
    default = document_processor.build_document_metadata(enriched)
    routed = document_processor.build_document_metadata(enriched, route="blindfold")
    assert default["analysis_route"] == analysis_route.LOCAL == "local"
    assert routed == {**default, "analysis_route": "blindfold"}
