"""
Document processing pipeline — ports the n8n Analysis → LightRAG workflow to Python.

Steps:
1. Query LightRAG for recent context + entity history (parallel)
2. Summarize context via Ollama
3. Analyze transcript via Ollama → structured JSON
4. Generate temporal-anchored narrative markdown
5. (Optional) Ingest into LightRAG
"""

import json
import logging
import math
import os
import re
import time
from datetime import datetime

import httpx

logger = logging.getLogger(__name__)

# --- Config ---

OLLAMA_BASE_URL = os.getenv("OLLAMA_BASE_URL", "http://192.168.2.17:11434")
OLLAMA_ANALYSIS_MODEL = os.getenv(
    "OLLAMA_ANALYSIS_MODEL", os.getenv("OLLAMA_MODEL", "qwen2.5:14b")
)
OLLAMA_ANALYSIS_NUM_CTX = int(os.getenv("OLLAMA_ANALYSIS_NUM_CTX", "262144"))
OLLAMA_ANALYSIS_TIMEOUT = float(os.getenv("OLLAMA_ANALYSIS_TIMEOUT", "300"))
LIGHTRAG_URL = os.getenv("LIGHTRAG_URL", "http://192.168.2.16:9621")
LIGHTRAG_API_KEY = os.getenv("LIGHTRAG_API_KEY", "")

MONTH_NAMES_DE = [
    "Januar", "Februar", "März", "April", "Mai", "Juni",
    "Juli", "August", "September", "Oktober", "November", "Dezember",
]
WEEKDAY_NAMES_DE = [
    "Montag", "Dienstag", "Mittwoch", "Donnerstag",
    "Freitag", "Samstag", "Sonntag",
]


def _extract_ollama_content(result: dict) -> str:
    """Extract text content from Ollama /api/chat response."""
    if isinstance(result, dict):
        msg = result.get("message")
        if isinstance(msg, dict) and msg.get("content"):
            return msg["content"]
        if result.get("text"):
            return result["text"]
        if result.get("response"):
            return result["response"]
    return ""


# --- LightRAG queries ---


async def get_lightrag_url() -> str:
    """Get LightRAG URL from DB settings, falling back to env/default."""
    try:
        import db
        url = await db.get_setting("lightrag_url", LIGHTRAG_URL)
        return url.rstrip("/")
    except Exception:
        return LIGHTRAG_URL.rstrip("/")


async def get_lightrag_api_key() -> str:
    """Get LightRAG API key from DB settings, falling back to env."""
    try:
        import db
        return await db.get_setting("lightrag_api_key", LIGHTRAG_API_KEY)
    except Exception:
        return LIGHTRAG_API_KEY


def _lightrag_headers(api_key: str) -> dict:
    """Build headers for LightRAG requests."""
    headers = {}
    if api_key:
        headers["X-API-Key"] = api_key
    return headers


async def query_lightrag_context(date_str: str) -> str:
    """Query LightRAG for recent 14-day context summary."""
    url = await get_lightrag_url()
    api_key = await get_lightrag_api_key()
    query = (
        f"Fasse die wichtigsten Themen, Entscheidungen und TODOs der letzten "
        f"14 Tage vor dem {date_str} in maximal 5 Stichpunkten zusammen. "
        f"Fokus auf: wiederkehrende Themen, offene Aufgaben, wichtige Erkenntnisse."
    )
    try:
        async with httpx.AsyncClient(timeout=300.0) as client:
            resp = await client.post(
                f"{url}/query",
                json={"query": query, "mode": "mix", "top_k": 5},
                headers=_lightrag_headers(api_key),
            )
            resp.raise_for_status()
            data = resp.json()
            return data.get("response", "") or ""
    except Exception as e:
        logger.warning("LightRAG recent context query failed: %s", e)
        return ""


async def query_lightrag_entity_history(persons: list[str], date_str: str) -> str:
    """Query LightRAG for person history."""
    if not persons:
        return ""
    url = await get_lightrag_url()
    api_key = await get_lightrag_api_key()
    person_list = ", ".join(persons)
    query = (
        f"Für jede dieser Personen: {person_list} - gib mir maximal 3 Stichpunkte: "
        f"(1) Rolle/Position, (2) letzte Interaktion/Thema, (3) wichtigste offene "
        f"Themen oder Charakterzüge."
    )
    try:
        async with httpx.AsyncClient(timeout=300.0) as client:
            resp = await client.post(
                f"{url}/query",
                json={"query": query, "mode": "mix", "top_k": 3},
                headers=_lightrag_headers(api_key),
            )
            resp.raise_for_status()
            data = resp.json()
            return data.get("response", "") or ""
    except Exception as e:
        logger.warning("LightRAG entity history query failed: %s", e)
        return ""


# --- Ollama calls ---


async def summarize_context(
    recent_context: str, entity_history: str, date_str: str
) -> str:
    """Compress LightRAG responses into a 200-word German summary."""
    prompt = (
        "Du bist ein Kontext-Komprimierer. Deine Aufgabe ist es, umfangreiche "
        "LightRAG-Responses in prägnante, strukturierte Zusammenfassungen zu komprimieren.\n\n"
        f"## INPUT - Recent Context (letzte 14 Tage):\n{recent_context or 'Keine Daten'}\n\n"
        f"## INPUT - Entity History:\n{entity_history or 'Keine Daten'}\n\n"
        "## DEINE AUFGABE:\n\n"
        "Erstelle eine KOMPAKTE Zusammenfassung mit maximal 200 Wörtern, strukturiert in:\n\n"
        "**Letzte Woche (max 5 Bulletpoints):**\n"
        "- Wichtigste wiederkehrende Themen\n"
        "- Kritische offene TODOs\n"
        "- Bedeutende Entscheidungen\n\n"
        "**Personen-Kontext (nur für erwähnte Personen, max 2-3 Bulletpoints pro Person):**\n"
        "- Name: [Rolle], letzte Interaktion: [Thema], Besonderheit: [Charakterzug/offenes Thema]\n\n"
        "## WICHTIG:\n"
        "- NUR die essentiellsten Informationen\n"
        "- Keine vollständigen Sätze - kurze Stichpunkte\n"
        "- Maximal 200 Wörter GESAMT\n"
        '- Wenn keine relevanten Daten: "Keine historischen Daten verfügbar"\n'
        "- **ALLE AUSGABEN NUR AUF DEUTSCH**\n"
        f"- Datumsbezug (heute) ist auf {date_str}\n\n"
        "## OUTPUT:\nNur der komprimierte Text auf DEUTSCH, keine JSON, keine Formatierung."
    )

    try:
        timeout = httpx.Timeout(connect=30.0, read=OLLAMA_ANALYSIS_TIMEOUT, write=30.0, pool=30.0)
        async with httpx.AsyncClient(timeout=timeout) as client:
            resp = await client.post(
                f"{OLLAMA_BASE_URL}/api/chat",
                json={
                    "model": OLLAMA_ANALYSIS_MODEL,
                    "stream": False,
                    "options": {
                        "temperature": 0.1,
                        "num_ctx": OLLAMA_ANALYSIS_NUM_CTX,
                    },
                    "messages": [{"role": "user", "content": prompt}],
                },
            )
            resp.raise_for_status()
            content = _extract_ollama_content(resp.json())
            if content and len(content) >= 50:
                return content
            return "Keine historischen Daten verfügbar."
    except Exception as e:
        logger.warning("Context summarization failed: %s (%s)", e, type(e).__name__)
        return "Keine historischen Daten verfügbar."


def build_enriched_context(
    transcript: dict, entities: list[dict], context_summary: str
) -> dict:
    """Build the enriched context dict from webapp data + context summary."""
    persons = [
        {
            "name": e.get("text") or e.get("canonical", ""),
            "role": e.get("role", ""),
            "company": e.get("company", "Enersis"),
            "confidence": "high",
        }
        for e in entities
        if e.get("type") == "PERSON" or e.get("entity_type") == "PERSON"
    ]
    terms = [
        {
            "term": e.get("text") or e.get("canonical", ""),
            "category": (e.get("type") or e.get("entity_type", "term")).lower(),
            "confidence": "high",
        }
        for e in entities
        if (e.get("type") or e.get("entity_type", "")) != "PERSON"
    ]

    return {
        "normalized_text": transcript.get("corrected_text") or transcript.get("raw_text", ""),
        "original_text": transcript.get("corrected_text") or transcript.get("raw_text", ""),
        "entity_context": {"persons": persons, "terms": terms},
        "lightrag_context": {
            "summary": context_summary,
            "available": bool(context_summary and len(context_summary) > 50),
            "analyzed_persons": [p["name"] for p in persons],
        },
        "date": str(transcript.get("date", "")),
        "diary_author": transcript.get("author") or "Florian Wolf",
        "diary_author_role": "CTO, Managing Director",
        "diary_author_company": "Enersis",
        "stats": {
            "total_persons": len(persons),
            "total_terms": len(terms),
        },
    }


async def analyze_transcript(enriched_ctx: dict) -> dict:
    """Run the main analysis LLM call — returns structured JSON."""
    persons_text = "\n".join(
        f"- {p['name']} ({p['role']} at {p['company']})"
        for p in enriched_ctx["entity_context"]["persons"]
    ) or "Keine Personen identifiziert"

    terms_text = "\n".join(
        f"- {t['term']} ({t['category']})"
        for t in enriched_ctx["entity_context"]["terms"]
    ) or "Keine Begriffe identifiziert"

    date_str = enriched_ctx["date"]
    author = enriched_ctx["diary_author"]
    role = enriched_ctx["diary_author_role"]
    company = enriched_ctx["diary_author_company"]
    ctx = enriched_ctx["lightrag_context"]

    prompt = (
        f"Du analysierst das Tagebuch eines CTOs vom {date_str}.\n\n"
        "## WICHTIG: Entities wurden bereits normalisiert!\n\n"
        "Der folgende Text enthält bereits normalisierte Entity-Namen. "
        "Du musst KEINE Entity-Normalisierung mehr durchführen.\n\n"
        f"**Bereits identifizierte Personen:**\n{persons_text}\n\n"
        f"**Bereits identifizierte Begriffe:**\n{terms_text}\n\n"
        f"## KONTEXT:\nDieser Tagebucheintrag wurde aufgezeichnet von: "
        f"{author} ({role} at {company})\n\n"
        f'**WICHTIG:** Der Text ist in der Ich-Perspektive geschrieben. '
        f'Wenn du Relationships extrahierst:\n'
        f'- "ich" bezieht sich auf {author}\n'
        f'- "wir" bezieht sich auf das {company} Team\n'
        f'- Schreibe Relationships in 3. Person '
        f'(z.B. "{author} diskutierte_mit Thomas")\n\n'
        "## KOMPAKTER HISTORISCHER KONTEXT:\n\n"
        f"{ctx['summary'] if ctx.get('available') else 'Keine historischen Daten verfügbar'}\n\n"
        "**NUTZE DIESEN KONTEXT UM:**\n"
        "1. **Wiederkehrende Muster zu erkennen**: Wenn eine Person/Thema schon mehrfach erwähnt wurde\n"
        "2. **TODO-Kontinuität**: Wenn ein TODO bereits in früheren Einträgen erwähnt wurde\n"
        "3. **Beziehungsdynamiken**: Wie entwickelt sich die Beziehung zu einer Person über Zeit?\n"
        "4. **Thematische Konsistenz**: Welche Themen tauchen wiederholt auf?\n\n"
        "## DEINE AUFGABE:\n\n"
        "Extrahiere strukturierte Informationen für einen Knowledge Graph. "
        "**ALLE INHALTE MÜSSEN AUF DEUTSCH SEIN!**\n\n"
        "### 1. BEZIEHUNGEN (relationships)\n"
        "Identifiziere Beziehungen zwischen Entities (Personen, Firmen, Projekten, Technologien).\n\n"
        "**WICHTIG**: Nutze den historischen Kontext um Beziehungen zu qualifizieren:\n"
        '- Wenn eine Beziehung schon existiert, markiere als "continuing"\n'
        '- Wenn eine Beziehung neu ist, markiere als "new"\n'
        "- Wenn sich eine Beziehung geändert hat, notiere die Änderung im context\n\n"
        "**Erlaubte Relationship-Typen:**\n"
        "- arbeitet_an, leitet, berichtet_an, reviewed, diskutierte_mit, delegierte_an\n"
        "- unterstützt, arbeitete_zusammen_mit, berät, implementiert\n"
        "- entwickelt, nutzt, integriert_mit, abhängig_von, ersetzt\n"
        "- gehört_zu, teil_von, verantwortlich_für, involviert_in\n"
        "- finanziert, partnert_mit, konkurriert_mit\n"
        "- plant, evaluiert, entschied_für, entschied_gegen\n\n"
        "**Format:**\n"
        '{"relationships": [{"source": "Entity A", "relationship": "relationship_type", '
        '"target": "Entity B", "context": "Kurze Erklärung auf DEUTSCH", '
        f'"continuity": "new|continuing|changed", "date": "{date_str}"'
        "}]}\n\n"
        "### 2. PROJEKTE & INITIATIVEN (projects)\n\n"
        "**WICHTIG**: Prüfe ob das Projekt bereits in früheren Einträgen erwähnt wurde.\n\n"
        '{"projects": [{"name": "Projektname auf DEUTSCH", '
        '"status": "geplant|in_arbeit|abgeschlossen|blockiert", '
        '"status_change": "new|updated|unchanged", '
        '"involved_persons": ["Person1"], "involved_companies": ["Firma1"], '
        '"technologies": ["Tech1"], "context": "Zielbeschreibung auf DEUTSCH", '
        f'"date": "{date_str}"'
        "}]}\n\n"
        "### 3. ENTSCHEIDUNGEN & AKTIONEN (decisions & todos)\n\n"
        "**WICHTIG FÜR TODOs**:\n"
        "- Prüfe ob das TODO bereits in früheren Einträgen erwähnt wurde\n"
        '- Wenn ja, markiere als "recurring" und notiere "first_mentioned" wenn erkennbar\n'
        "- Wenn ein TODO wiederholt erwähnt wird ohne Fortschritt, erhöhe die priority\n\n"
        '{"decisions": [{"decision": "Entscheidung auf DEUTSCH", '
        f'"decision_maker": "{author}", "rationale": "Begründung auf DEUTSCH", '
        '"impacted_entities": ["Entity1"], "reverses_previous": false, '
        f'"date": "{date_str}"'
        "}], "
        '"todos": [{"action": "Aufgabenbeschreibung auf DEUTSCH", '
        '"assignee": "Person", "priority": "hoch|mittel|niedrig", '
        '"context": "Begründung auf DEUTSCH", "recurrence": "new|recurring", '
        f'"first_mentioned": null, "date": "{date_str}"'
        "}]}\n\n"
        "### 4. ERKENNTNISSE & LEARNINGS (insights)\n\n"
        '{"insights": [{"insight": "Erkenntnis auf DEUTSCH", '
        '"category": "technisch|strategisch|organisatorisch|markt", '
        '"relevance": "Für wen relevant - auf DEUTSCH", '
        '"novelty": "new|confirming|contradicting", '
        '"related_to_previous": "Bezug zu früheren Erkenntnissen", '
        f'"date": "{date_str}"'
        "}]}\n\n"
        "### 5. WIEDERKEHRENDE THEMEN (recurring_themes)\n\n"
        '{"recurring_themes": [{"theme": "Themenname auf DEUTSCH", '
        '"frequency": "Häufigkeit auf DEUTSCH", '
        '"trend": "increasing|stable|decreasing", '
        '"context": "Warum relevant - auf DEUTSCH"}]}\n\n'
        "## WICHTIGE REGELN:\n"
        "1. Verwende NUR die bereits normalisierten Entity-Namen aus dem Text\n"
        "2. KEINE neue Entity-Normalisierung - die Namen sind bereits korrekt\n"
        "3. Konvertiere Ich-Perspektive zu 3. Person in Relationships\n"
        f"4. Datum immer angeben - verwende {date_str}\n"
        "5. Nutze den historischen Kontext aktiv\n"
        "6. Nur Fakten extrahieren - keine Spekulationen\n"
        "7. Alle Relationships müssen Entities aus dem Text verknüpfen\n"
        "8. ALLE TEXTINHALTE MÜSSEN AUF DEUTSCH SEIN\n\n"
        "## OUTPUT FORMAT:\n"
        "Provide ONLY a single valid JSON object with ALL sections:\n"
        '{"relationships": [...], "projects": [...], "decisions": [...], '
        '"todos": [...], "insights": [...], "recurring_themes": [...]}\n\n'
        "NO markdown formatting, NO code blocks, just pure JSON.\n\n"
        f"## TEXT ZUR ANALYSE:\n{enriched_ctx['normalized_text']}"
    )

    try:
        # Use separate connect/read/write timeouts — analysis can take minutes
        timeout = httpx.Timeout(
            connect=30.0,
            read=OLLAMA_ANALYSIS_TIMEOUT,
            write=30.0,
            pool=30.0,
        )
        async with httpx.AsyncClient(timeout=timeout) as client:
            resp = await client.post(
                f"{OLLAMA_BASE_URL}/api/chat",
                json={
                    "model": OLLAMA_ANALYSIS_MODEL,
                    "stream": False,
                    "format": "json",
                    "options": {
                        "temperature": 0.1,
                        "num_ctx": OLLAMA_ANALYSIS_NUM_CTX,
                    },
                    "messages": [{"role": "user", "content": prompt}],
                },
            )
            resp.raise_for_status()
            content = _extract_ollama_content(resp.json())
    except httpx.ReadTimeout:
        logger.error("Main analysis timed out after %ss (model: %s)", OLLAMA_ANALYSIS_TIMEOUT, OLLAMA_ANALYSIS_MODEL)
        raise RuntimeError(f"LLM analysis timed out after {OLLAMA_ANALYSIS_TIMEOUT}s")
    except Exception as e:
        logger.error("Main analysis LLM call failed: %s (%s)", e, type(e).__name__)
        raise

    # Parse JSON from response
    analysis = {
        "relationships": [], "projects": [], "decisions": [],
        "todos": [], "insights": [], "recurring_themes": [],
    }

    if content:
        try:
            cleaned = re.sub(r"```json\s*", "", content)
            cleaned = re.sub(r"```\s*", "", cleaned).strip()
            first_brace = cleaned.find("{")
            last_brace = cleaned.rfind("}")
            if first_brace != -1 and last_brace != -1:
                cleaned = cleaned[first_brace : last_brace + 1]
            parsed = json.loads(cleaned)
            if isinstance(parsed, dict):
                for key in analysis:
                    if key in parsed:
                        analysis[key] = parsed[key]
        except json.JSONDecodeError as e:
            logger.error("Failed to parse analysis JSON: %s", e)

    return analysis


def _iso_week(date_obj) -> int:
    """Compute ISO week number."""
    return date_obj.isocalendar()[1]


def generate_narrative_document(enriched_ctx: dict, analysis: dict) -> str:
    """Build temporal-anchored narrative markdown from analysis results."""
    date_str = enriched_ctx["date"]
    try:
        date_obj = datetime.strptime(date_str, "%Y-%m-%d")
    except ValueError:
        date_obj = datetime.now()

    iso_week = _iso_week(date_obj)
    quarter = math.ceil(date_obj.month / 3)
    month = MONTH_NAMES_DE[date_obj.month - 1]
    weekday = WEEKDAY_NAMES_DE[date_obj.weekday()]
    year = date_obj.year
    day = date_obj.day

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


def build_document_metadata(enriched_ctx: dict) -> dict:
    """Build metadata dict for the processed document."""
    date_str = enriched_ctx["date"]
    try:
        date_obj = datetime.strptime(date_str, "%Y-%m-%d")
    except ValueError:
        date_obj = datetime.now()

    iso_week = _iso_week(date_obj)
    quarter = math.ceil(date_obj.month / 3)
    month = MONTH_NAMES_DE[date_obj.month - 1]

    return {
        "date": date_str,
        "iso_week": iso_week,
        "quarter": f"Q{quarter}",
        "month": month,
        "year": date_obj.year,
        "source": "voice_diary",
        "type": "cto_journal",
        "language": "de",
        "author": enriched_ctx["diary_author"],
    }


async def ingest_to_lightrag(markdown: str, metadata: dict) -> dict:
    """POST document to LightRAG /documents/text.

    Performs a pre-ingestion skeleton sync to flush any pending bone
    documents before ingesting the diary entry.
    """
    # Pre-ingestion: sync pending skeleton bones (best-effort)
    try:
        import skeleton_sync
        sync_stats = await skeleton_sync.sync_incremental(triggered_by="pre-ingestion")
        if sync_stats.has_changes():
            logger.info("Pre-ingestion skeleton sync: %s", sync_stats.to_dict())
    except Exception as e:
        logger.warning("Pre-ingestion skeleton sync failed (continuing): %s", e)

    url = await get_lightrag_url()
    api_key = await get_lightrag_api_key()
    date_str = metadata.get("date", "unknown")
    diary_id = f"diary:{date_str}"
    try:
        async with httpx.AsyncClient(timeout=300.0) as client:
            resp = await client.post(
                f"{url}/documents/text",
                json={
                    "id": diary_id,
                    "file_source": f"diary-{date_str}.md",
                    "text": markdown,
                    "metadata": metadata,
                },
                headers=_lightrag_headers(api_key),
            )
            resp.raise_for_status()
            return resp.json()
    except Exception as e:
        logger.error("LightRAG ingest failed: %s", e)
        raise
