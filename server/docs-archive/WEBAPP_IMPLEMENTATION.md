# Diary Transcript Review Webapp

Implementation guide for the entity review webapp that replaces the automated entity normalization pipeline (3 LLM chains, 21 NocoDB nodes) with a human-in-the-loop review interface backed by a growing dictionary.

**Stack:** Python 3.11+ / FastAPI / HTMX / Postgres / Docker

**Reference prototype:** `prototype-review-app.html`

---

## 1. Project Structure

```
webapp/
  main.py                 # FastAPI application
  entity_detector.py      # 4-pass detection engine
  db.py                   # Postgres connection & queries
  templates/
    base.html             # HTMX base layout
    index.html            # Transcript list page
    review.html           # Main review page (based on prototype)
  static/
    style.css             # CSS extracted from prototype
    app.js                # Client-side JS (render, interactions, selection popup)
  alembic/
    versions/
      001_initial.py
  alembic.ini
  requirements.txt
  Dockerfile
  docker-compose.yml
```

---

## 2. Postgres Schema

```sql
-- 001_initial.py (Alembic migration)

-- Persons roster (canonical names)
CREATE TABLE persons (
    id SERIAL PRIMARY KEY,
    canonical_name VARCHAR(200) NOT NULL UNIQUE,
    first_name VARCHAR(100),
    last_name VARCHAR(100),
    role VARCHAR(300),
    department VARCHAR(200),
    company VARCHAR(200),
    topics TEXT,
    status VARCHAR(20) DEFAULT 'active',
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- Person name variations (grows as user corrects)
CREATE TABLE person_variations (
    id SERIAL PRIMARY KEY,
    person_id INTEGER NOT NULL REFERENCES persons(id) ON DELETE CASCADE,
    variation VARCHAR(200) NOT NULL,
    variation_type VARCHAR(50) DEFAULT 'asr_correction',
        -- types: 'canonical', 'nickname', 'asr_correction', 'abbreviation'
    confidence VARCHAR(20) DEFAULT 'high',
    approved BOOLEAN DEFAULT TRUE,
    auto_created BOOLEAN DEFAULT FALSE,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    UNIQUE(person_id, variation)
);

-- Terms roster (canonical terms)
CREATE TABLE terms (
    id SERIAL PRIMARY KEY,
    canonical_term VARCHAR(300) NOT NULL UNIQUE,
    category VARCHAR(50) NOT NULL,
        -- categories: 'company', 'department', 'technology', 'term',
        --             'project', 'location', 'event'
    context TEXT,
    status VARCHAR(20) DEFAULT 'active',
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- Term variations (grows as user corrects)
CREATE TABLE term_variations (
    id SERIAL PRIMARY KEY,
    term_id INTEGER NOT NULL REFERENCES terms(id) ON DELETE CASCADE,
    variation VARCHAR(300) NOT NULL,
    approved BOOLEAN DEFAULT TRUE,
    auto_created BOOLEAN DEFAULT FALSE,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    UNIQUE(term_id, variation)
);

-- Transcripts (queue for review)
CREATE TABLE transcripts (
    id SERIAL PRIMARY KEY,
    filename VARCHAR(200) NOT NULL,
    date DATE NOT NULL,
    author VARCHAR(200),
    raw_text TEXT NOT NULL,
    corrected_text TEXT,
    status VARCHAR(20) DEFAULT 'pending',
        -- statuses: 'pending', 'in_review', 'submitted', 'processed'
    submitted_at TIMESTAMPTZ,
    processed_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ DEFAULT NOW()
);

-- Review log (tracks what was changed per transcript)
CREATE TABLE review_log (
    id SERIAL PRIMARY KEY,
    transcript_id INTEGER NOT NULL REFERENCES transcripts(id) ON DELETE CASCADE,
    original_text VARCHAR(500) NOT NULL,
    corrected_text VARCHAR(500) NOT NULL,
    entity_type VARCHAR(50) NOT NULL,
    match_type VARCHAR(50) NOT NULL,
    action VARCHAR(50) NOT NULL,
        -- 'confirmed', 'corrected', 'dismissed', 'added'
    created_at TIMESTAMPTZ DEFAULT NOW()
);

-- Indexes
CREATE INDEX idx_person_variations_lower ON person_variations (LOWER(variation));
CREATE INDEX idx_term_variations_lower ON term_variations (LOWER(variation));
CREATE INDEX idx_transcripts_status ON transcripts (status);
CREATE INDEX idx_persons_status ON persons (status) WHERE status = 'active';
CREATE INDEX idx_terms_status ON terms (status) WHERE status = 'active';
```

### Seed data (from current NocoDB export)

```sql
INSERT INTO persons (canonical_name, first_name, last_name, role, department, company, status)
VALUES
  ('Thomas Koller', 'Thomas', 'Koller',
   'CEO, Head of Sales, Founder, Managing Director', 'Management', 'Enersis', 'active'),
  ('Florian Wolf', 'Florian', 'Wolf',
   'CTO, Managing Director', 'Management', 'Enersis', 'active'),
  ('Monica Breitkreutz', 'Monica', 'Breitkreutz',
   'HR Manager', 'HR', 'Enersis', 'active'),
  ('Christian Boiger', 'Christian', 'Boiger',
   'Product Manager', 'Engineering', 'Enersis', 'active'),
  ('Michael Bez', 'Michael', 'Bez',
   'Board Member', 'Board of Directors', 'EnBW', 'active');

INSERT INTO person_variations (person_id, variation, variation_type, confidence) VALUES
  (1, 'Thomas', 'nickname', 'high'),
  (1, 'Thomas Koller', 'canonical', 'high'),
  (1, 'Koller', 'nickname', 'high'),
  (2, 'Florian', 'nickname', 'high'),
  (2, 'Flo', 'nickname', 'high'),
  (2, 'Florian Wolf', 'canonical', 'high'),
  (3, 'Monica', 'nickname', 'high'),
  (3, 'Monika', 'asr_correction', 'high'),
  (3, 'Monica Breitkreutz', 'canonical', 'high'),
  (4, 'Christian', 'nickname', 'high'),
  (4, 'Christian Boiger', 'canonical', 'high'),
  (4, 'Boiger', 'nickname', 'high');

INSERT INTO terms (canonical_term, category, context, status) VALUES
  ('Enersis', 'company', 'Main company entity', 'active'),
  ('EnBW', 'company', 'Parent company entity', 'active'),
  ('Engineering', 'department', 'Software development department', 'active'),
  ('BYOD Policy', 'term', 'Bring Your Own Device policy', 'active'),
  ('Kubernetes', 'technology', 'Container orchestration platform', 'active'),
  ('Magic Circle', 'department', 'Internal business division within Enersis', 'active'),
  ('Internal Business Services', 'department', 'HR and operations department', 'active'),
  ('Cloud Services', 'department', 'Cloud infrastructure division', 'active'),
  ('Payment Systems', 'department', 'Payment processing division', 'active');

INSERT INTO term_variations (term_id, variation) VALUES
  (1, 'Enersis'), (1, 'enersis'), (1, 'ENERSIS'),
  (1, 'Enersis AG'), (1, 'E-nersis'), (1, 'Enersis GmbH'), (1, 'Enersys'),
  (2, 'EnBW'),
  (3, 'Engineering'), (3, 'Softwareentwicklung'), (3, 'Technikabteilung'),
  (4, 'BYOD'), (4, 'Bring Your Own Device'), (4, 'BYOD Policy');
```

---

## 3. Entity Detection Engine

### `entity_detector.py`

The 4-pass detection engine replaces the Person Detection and Term Detection LLM chains.

```python
"""
4-pass entity detection engine.

Pass 1: Exact case-insensitive match against known variations -> auto-correct
Pass 2: Normalized match (strip diacritics, normalize whitespace) -> auto-correct
Pass 3: Levenshtein distance <= 2 for likely ASR errors -> flag as "suggested"
Pass 4: First-name-only resolution -> auto-correct if unambiguous,
        flag as "ambiguous" with candidates if multiple matches
"""

import re
import json
from dataclasses import dataclass, field, asdict
from unidecode import unidecode
from Levenshtein import distance as levenshtein_distance


@dataclass
class DetectedEntity:
    start: int
    end: int
    original_text: str
    canonical: str
    entity_type: str       # PERSON, ORGANIZATION, TERM, TECHNOLOGY, etc.
    match_type: str        # exact, variation, normalized, fuzzy, first_name, manual
    confidence: str        # high, medium, low
    status: str            # auto-matched, suggested, ambiguous, new-entity
    dictionary_id: int | None = None
    source: str = "term"   # person or term
    role: str = ""
    candidates: list = field(default_factory=list)
        # populated when status='ambiguous': list of
        # {"id": int, "canonical": str, "role": str}

    def to_dict(self) -> dict:
        return asdict(self)


CATEGORY_TO_TYPE = {
    "company": "ORGANIZATION",
    "department": "ORGANIZATION",
    "technology": "TECHNOLOGY",
    "term": "TERM",
    "project": "PROJECT",
    "location": "LOCATION",
    "event": "EVENT",
    "concept": "TERM",
}


def normalize_text(text: str) -> str:
    """Strip diacritics, normalize whitespace, lowercase."""
    return re.sub(r"\s+", " ", unidecode(text).lower().strip())


def is_word_boundary(text: str, start: int, end: int) -> bool:
    """Check if the match is at word boundaries."""
    before = text[start - 1] if start > 0 else " "
    after = text[end] if end < len(text) else " "
    return not before.isalnum() and not after.isalnum()


def detect_entities(
    text: str,
    persons: list[dict],
    terms: list[dict],
) -> list[DetectedEntity]:
    """Run 4-pass detection against the dictionary."""

    detected: list[DetectedEntity] = []
    text_lower = text.lower()

    # --- Build first-name ambiguity index for Pass 4 ---
    first_name_index: dict[str, list[dict]] = {}
    for person in persons:
        fn = (person.get("first_name") or "").strip().lower()
        if fn:
            first_name_index.setdefault(fn, []).append(person)

    # --- TERM MATCHING (Pass 1 + 2) ---
    for term in terms:
        canonical = term["canonical_term"]
        category = term.get("category", "term")
        entity_type = CATEGORY_TO_TYPE.get(category, "TERM")
        variations = _extract_variations(term.get("variations", []))
        variations.sort(key=len, reverse=True)

        for variation in variations:
            if not variation:
                continue
            var_lower = variation.lower()
            idx = 0
            while True:
                idx = text_lower.find(var_lower, idx)
                if idx == -1:
                    break
                if is_word_boundary(text, idx, idx + len(variation)):
                    original = text[idx : idx + len(variation)]
                    is_exact = original == canonical
                    detected.append(DetectedEntity(
                        start=idx,
                        end=idx + len(variation),
                        original_text=original,
                        canonical=canonical,
                        entity_type=entity_type,
                        match_type="exact" if is_exact else "variation",
                        confidence="high",
                        status="auto-matched",
                        dictionary_id=term["id"],
                        source="term",
                    ))
                idx += len(variation)

    # --- PERSON MATCHING (Pass 1 + 2 + 4) ---
    for person in persons:
        canonical = person["canonical_name"]
        variations = _extract_variations(person.get("variations", []))
        variations.sort(key=len, reverse=True)

        for variation in variations:
            if not variation:
                continue
            var_lower = variation.lower()
            idx = 0
            while True:
                idx = text_lower.find(var_lower, idx)
                if idx == -1:
                    break

                match_len = len(variation)
                if match_len < 5 and not is_word_boundary(text, idx, idx + match_len):
                    idx += 1
                    continue

                original = text[idx : idx + match_len]
                is_exact = original == canonical
                is_first_name = var_lower == (person.get("first_name") or "").lower()

                # --- Pass 4: First-name ambiguity check ---
                if is_first_name and var_lower in first_name_index:
                    matches = first_name_index[var_lower]
                    if len(matches) > 1:
                        # AMBIGUOUS: multiple persons share this first name
                        # Show radio buttons with all candidates
                        detected.append(DetectedEntity(
                            start=idx,
                            end=idx + match_len,
                            original_text=original,
                            canonical=original,  # don't auto-resolve
                            entity_type="PERSON",
                            match_type="first_name",
                            confidence="medium",
                            status="ambiguous",
                            dictionary_id=None,
                            source="person",
                            candidates=[
                                {
                                    "id": m["id"],
                                    "canonical": m["canonical_name"],
                                    "role": m.get("role", ""),
                                    "company": m.get("company", ""),
                                }
                                for m in matches
                            ],
                        ))
                        idx += match_len
                        continue

                detected.append(DetectedEntity(
                    start=idx,
                    end=idx + match_len,
                    original_text=original,
                    canonical=canonical,
                    entity_type="PERSON",
                    match_type="exact" if is_exact else (
                        "first_name" if is_first_name else "variation"
                    ),
                    confidence="high",
                    status="auto-matched",
                    dictionary_id=person["id"],
                    source="person",
                    role=person.get("role", ""),
                ))
                idx += match_len

    # --- FUZZY MATCHING (Pass 3) ---
    matched_ranges = [(d.start, d.end) for d in detected]

    common_words = {
        "ich", "er", "sie", "wir", "der", "die", "das", "ein", "eine",
        "und", "oder", "aber", "dass", "mit", "von", "bei", "für",
        "ist", "hat", "war", "sind", "haben", "werden", "kann",
        "auch", "noch", "schon", "sehr", "ganz", "nur", "dann",
        "Tag", "Tage", "Zeit", "Mal", "Jahr", "Monat", "Woche",
    }

    words = list(re.finditer(
        r"\b[A-ZÄÖÜ][a-zäöüß]+(?:\s+[A-ZÄÖÜ][a-zäöüß]+)?\b", text
    ))

    all_person_vars = []
    for person in persons:
        for v in _extract_variations(person.get("variations", [])):
            if len(v) >= 4:
                all_person_vars.append((v, person))

    all_term_vars = []
    for term in terms:
        for v in _extract_variations(term.get("variations", [])):
            if len(v) >= 4:
                all_term_vars.append((v, term))

    for match in words:
        word = match.group()
        w_start, w_end = match.start(), match.end()

        if word in common_words:
            continue
        if any(w_start < me and w_end > ms for ms, me in matched_ranges):
            continue

        best_match = None
        best_distance = 3

        for var_text, person in all_person_vars:
            d = levenshtein_distance(word.lower(), var_text.lower())
            if d <= 2 and d < best_distance and word[0].lower() == var_text[0].lower():
                best_distance = d
                best_match = ("person", person, var_text)

        for var_text, term in all_term_vars:
            d = levenshtein_distance(word.lower(), var_text.lower())
            if d <= 2 and d < best_distance and word[0].lower() == var_text[0].lower():
                best_distance = d
                best_match = ("term", term, var_text)

        if best_match:
            source_type, entry, _ = best_match
            if source_type == "person":
                detected.append(DetectedEntity(
                    start=w_start, end=w_end,
                    original_text=word,
                    canonical=entry["canonical_name"],
                    entity_type="PERSON",
                    match_type="fuzzy", confidence="medium",
                    status="suggested",
                    dictionary_id=entry["id"],
                    source="person",
                    role=entry.get("role", ""),
                ))
            else:
                category = entry.get("category", "term")
                detected.append(DetectedEntity(
                    start=w_start, end=w_end,
                    original_text=word,
                    canonical=entry["canonical_term"],
                    entity_type=CATEGORY_TO_TYPE.get(category, "TERM"),
                    match_type="fuzzy", confidence="medium",
                    status="suggested",
                    dictionary_id=entry["id"],
                    source="term",
                ))

    # --- DEDUPLICATE (keep longest match at each position) ---
    detected.sort(key=lambda d: (d.start, -(d.end - d.start)))
    deduped = []
    last_end = -1
    for d in detected:
        if d.start >= last_end:
            deduped.append(d)
            last_end = d.end
    return deduped


def _extract_variations(variations) -> list[str]:
    """Normalize variations from DB (may be JSON string, list of dicts, or list of strings)."""
    if isinstance(variations, str):
        variations = json.loads(variations)
    result = []
    for v in variations:
        if isinstance(v, dict):
            result.append(v.get("variation", v.get("text", "")))
        else:
            result.append(str(v))
    return result
```

---

## 4. Database Layer

### `db.py`

```python
import asyncpg
import os
from typing import Optional

_pool: Optional[asyncpg.Pool] = None

DATABASE_URL = os.getenv(
    "DATABASE_URL",
    "postgresql://diary:diary@localhost:5432/diary_processor"
)


async def get_pool() -> asyncpg.Pool:
    global _pool
    if _pool is None:
        _pool = await asyncpg.create_pool(DATABASE_URL, min_size=2, max_size=10)
    return _pool


async def close_pool():
    global _pool
    if _pool:
        await _pool.close()
        _pool = None


# --- Dictionary loading ---

async def load_person_dictionary() -> list[dict]:
    """Load all active persons with their variations."""
    pool = await get_pool()
    rows = await pool.fetch("""
        SELECT p.id, p.canonical_name, p.first_name, p.last_name,
               p.role, p.department, p.company,
               COALESCE(
                   json_agg(json_build_object(
                       'variation', pv.variation,
                       'type', pv.variation_type
                   )) FILTER (WHERE pv.id IS NOT NULL),
                   '[]'::json
               ) AS variations
        FROM persons p
        LEFT JOIN person_variations pv
          ON pv.person_id = p.id AND pv.approved = TRUE
        WHERE p.status = 'active'
        GROUP BY p.id
        ORDER BY p.canonical_name
    """)
    return [dict(r) for r in rows]


async def load_term_dictionary() -> list[dict]:
    """Load all active terms with their variations."""
    pool = await get_pool()
    rows = await pool.fetch("""
        SELECT t.id, t.canonical_term, t.category, t.context,
               COALESCE(
                   json_agg(tv.variation) FILTER (WHERE tv.id IS NOT NULL),
                   '[]'::json
               ) AS variations
        FROM terms t
        LEFT JOIN term_variations tv
          ON tv.term_id = t.id AND tv.approved = TRUE
        WHERE t.status = 'active'
        GROUP BY t.id
        ORDER BY t.canonical_term
    """)
    return [dict(r) for r in rows]


# --- Variation saving (dictionary growth) ---

async def save_person_variation(
    person_id: int, variation: str, variation_type: str = "asr_correction"
):
    pool = await get_pool()
    await pool.execute("""
        INSERT INTO person_variations (person_id, variation, variation_type, auto_created)
        VALUES ($1, $2, $3, FALSE)
        ON CONFLICT (person_id, variation) DO NOTHING
    """, person_id, variation, variation_type)


async def save_term_variation(term_id: int, variation: str):
    pool = await get_pool()
    await pool.execute("""
        INSERT INTO term_variations (term_id, variation, auto_created)
        VALUES ($1, $2, FALSE)
        ON CONFLICT (term_id, variation) DO NOTHING
    """, term_id, variation)


async def create_person(
    canonical_name: str, first_name: str = "", last_name: str = "",
    role: str = "", company: str = ""
) -> int:
    pool = await get_pool()
    row = await pool.fetchrow("""
        INSERT INTO persons (canonical_name, first_name, last_name, role, company)
        VALUES ($1, $2, $3, $4, $5)
        ON CONFLICT (canonical_name) DO UPDATE SET updated_at = NOW()
        RETURNING id
    """, canonical_name, first_name, last_name, role, company)
    person_id = row["id"]
    await save_person_variation(person_id, canonical_name, "canonical")
    return person_id


async def create_term(
    canonical_term: str, category: str, context: str = ""
) -> int:
    pool = await get_pool()
    row = await pool.fetchrow("""
        INSERT INTO terms (canonical_term, category, context)
        VALUES ($1, $2, $3)
        ON CONFLICT (canonical_term) DO UPDATE SET updated_at = NOW()
        RETURNING id
    """, canonical_term, category, context)
    term_id = row["id"]
    await save_term_variation(term_id, canonical_term)
    return term_id


# --- Transcript management ---

async def list_transcripts(status: str = None) -> list[dict]:
    pool = await get_pool()
    if status:
        rows = await pool.fetch(
            "SELECT id, filename, date, author, status, created_at "
            "FROM transcripts WHERE status = $1 ORDER BY date DESC", status
        )
    else:
        rows = await pool.fetch(
            "SELECT id, filename, date, author, status, created_at "
            "FROM transcripts ORDER BY date DESC"
        )
    return [dict(r) for r in rows]


async def get_transcript(transcript_id: int) -> dict | None:
    pool = await get_pool()
    row = await pool.fetchrow(
        "SELECT * FROM transcripts WHERE id = $1", transcript_id
    )
    return dict(row) if row else None


async def create_transcript(
    filename: str, date: str, author: str, raw_text: str
) -> int:
    pool = await get_pool()
    row = await pool.fetchrow("""
        INSERT INTO transcripts (filename, date, author, raw_text)
        VALUES ($1, $2::date, $3, $4) RETURNING id
    """, filename, date, author, raw_text)
    return row["id"]


async def submit_transcript(transcript_id: int, corrected_text: str):
    pool = await get_pool()
    await pool.execute("""
        UPDATE transcripts
        SET corrected_text = $2, status = 'submitted', submitted_at = NOW()
        WHERE id = $1
    """, transcript_id, corrected_text)


async def mark_transcript_processed(transcript_id: int):
    pool = await get_pool()
    await pool.execute("""
        UPDATE transcripts SET status = 'processed', processed_at = NOW()
        WHERE id = $1
    """, transcript_id)


# --- Review log ---

async def log_review_action(
    transcript_id: int, original: str, corrected: str,
    entity_type: str, match_type: str, action: str
):
    pool = await get_pool()
    await pool.execute("""
        INSERT INTO review_log
          (transcript_id, original_text, corrected_text, entity_type, match_type, action)
        VALUES ($1, $2, $3, $4, $5, $6)
    """, transcript_id, original, corrected, entity_type, match_type, action)
```

---

## 5. FastAPI Application

### `requirements.txt`

```
fastapi==0.115.0
uvicorn[standard]==0.30.0
jinja2==3.1.4
python-multipart==0.0.9
asyncpg==0.29.0
httpx==0.27.0
python-Levenshtein==0.25.1
unidecode==1.3.8
alembic==1.13.0
psycopg2-binary==2.9.9
```

### `main.py`

```python
import json
import os
from contextlib import asynccontextmanager
from datetime import date

import httpx
from fastapi import FastAPI, Request, Form
from fastapi.responses import HTMLResponse, RedirectResponse
from fastapi.staticfiles import StaticFiles
from fastapi.templating import Jinja2Templates

import db
from entity_detector import detect_entities

N8N_WEBHOOK_URL = os.getenv(
    "N8N_WEBHOOK_URL", "http://192.168.2.16:5678/webhook/diary-reviewed"
)


@asynccontextmanager
async def lifespan(app: FastAPI):
    await db.get_pool()
    yield
    await db.close_pool()


app = FastAPI(title="Diary Transcript Review", lifespan=lifespan)
app.mount("/static", StaticFiles(directory="static"), name="static")
templates = Jinja2Templates(directory="templates")


# ─── Pages ───────────────────────────────────────────────────────────

@app.get("/", response_class=HTMLResponse)
async def index(request: Request):
    """Transcript list page."""
    transcripts = await db.list_transcripts()
    return templates.TemplateResponse("index.html", {
        "request": request,
        "transcripts": transcripts,
    })


@app.get("/review/{transcript_id}", response_class=HTMLResponse)
async def review_page(request: Request, transcript_id: int):
    """Main review page. Runs detection server-side, renders result."""
    transcript = await db.get_transcript(transcript_id)
    if not transcript:
        return RedirectResponse("/")

    persons = await db.load_person_dictionary()
    terms = await db.load_term_dictionary()
    entities = detect_entities(transcript["raw_text"], persons, terms)

    return templates.TemplateResponse("review.html", {
        "request": request,
        "transcript": transcript,
        "entities_json": json.dumps([e.to_dict() for e in entities]),
        "raw_text": transcript["raw_text"],
        "person_count": len(persons),
        "term_count": len(terms),
    })


# ─── API ─────────────────────────────────────────────────────────────

@app.get("/api/dictionary")
async def get_dictionary():
    """Full entity dictionary (for optional client-side re-detection)."""
    persons = await db.load_person_dictionary()
    terms = await db.load_term_dictionary()
    return {"persons": persons, "terms": terms}


@app.post("/api/transcripts")
async def upload_transcript(
    filename: str = Form(...),
    date: str = Form(...),
    author: str = Form("Florian Wolf"),
    raw_text: str = Form(...),
):
    """Manually add a transcript to the review queue."""
    tid = await db.create_transcript(filename, date, author, raw_text)
    return {"id": tid, "status": "pending"}


@app.post("/api/transcripts/{transcript_id}/submit")
async def submit_review(transcript_id: int, request: Request):
    """
    Submit reviewed transcript. Saves corrections to dictionary,
    then forwards to n8n.

    Expected JSON body:
    {
        "corrected_transcript": "...",
        "date": "2025-05-14",
        "author": "Florian Wolf",
        "entities": [
            {"text": "Enersis", "type": "ORGANIZATION",
             "original": "Enersys", "is_correction": true,
             "match_type": "variation"}
        ],
        "new_variations": [
            {"original": "Enersys", "canonical": "Enersis",
             "type": "ORGANIZATION", "source": "term", "dictionary_id": 1}
        ],
        "new_entities": [
            {"text": "Tagesgeschaeft", "type": "TERM", "source": "term"}
        ],
        "disambiguated": [
            {"original": "Christian", "chosen_id": 4,
             "chosen_canonical": "Christian Boiger"}
        ],
        "dismissed": [
            {"original": "Thomas", "canonical": "Thomas Koller",
             "type": "PERSON"}
        ]
    }
    """
    body = await request.json()

    # 1. Save corrected transcript
    await db.submit_transcript(transcript_id, body["corrected_transcript"])

    # 2. Save new variations (dictionary growth)
    for var in body.get("new_variations", []):
        if var.get("dictionary_id"):
            if var["source"] == "person":
                await db.save_person_variation(
                    var["dictionary_id"], var["original"], "asr_correction"
                )
            else:
                await db.save_term_variation(
                    var["dictionary_id"], var["original"]
                )

    # 3. Save disambiguated first-name matches as variations
    #    e.g., "Christian" in this context -> Christian Boiger
    #    (only if the original text differs from the canonical)
    for dis in body.get("disambiguated", []):
        if dis.get("chosen_id") and dis.get("original"):
            await db.save_person_variation(
                dis["chosen_id"], dis["original"], "nickname"
            )

    # 4. Create new dictionary entries for manually added entities
    for new_ent in body.get("new_entities", []):
        if new_ent.get("source") == "person":
            await db.create_person(canonical_name=new_ent["text"])
        else:
            await db.create_term(
                canonical_term=new_ent["text"],
                category=new_ent.get("category", new_ent["type"].lower()),
            )

    # 5. Log all review actions
    for ent in body.get("entities", []):
        action = "corrected" if ent.get("is_correction") else "confirmed"
        await db.log_review_action(
            transcript_id, ent.get("original", ent["text"]),
            ent["text"], ent["type"], ent.get("match_type", "auto-matched"),
            action,
        )
    for dismissed in body.get("dismissed", []):
        await db.log_review_action(
            transcript_id, dismissed["original"], dismissed["canonical"],
            dismissed["type"], "auto-matched", "dismissed",
        )

    # 6. Forward to n8n pipeline
    pipeline_payload = {
        "transcript_id": transcript_id,
        "corrected_transcript": body["corrected_transcript"],
        "date": body.get("date", str(date.today())),
        "author": body.get("author", "Florian Wolf"),
        "entities": body.get("entities", []),
    }

    try:
        async with httpx.AsyncClient(timeout=30.0) as client:
            resp = await client.post(N8N_WEBHOOK_URL, json=pipeline_payload)
            resp.raise_for_status()
            await db.mark_transcript_processed(transcript_id)
            return {"status": "submitted", "n8n_response": resp.json()}
    except Exception as e:
        return {"status": "submitted", "n8n_error": str(e)}


# ─── Webhook receiver (n8n sends transcripts here after ASR) ────────

@app.post("/webhook/transcript-ready")
async def receive_transcript(request: Request):
    """
    n8n POSTs here after ASR:
    { "filename": "diary-14.05.2025", "date": "2025-05-14",
      "author": "Florian Wolf", "text": "..." }
    """
    body = await request.json()
    tid = await db.create_transcript(
        filename=body["filename"],
        date=body["date"],
        author=body.get("author", "Florian Wolf"),
        raw_text=body["text"],
    )
    return {
        "id": tid,
        "status": "pending",
        "review_url": f"/review/{tid}",
    }
```

---

## 6. Frontend

### `static/style.css`

Extract the full `<style>` block from `prototype-review-app.html` (lines 7-441) verbatim. Add the following for the ambiguous entity radio buttons:

```css
/* --- Ambiguous entity radio group --- */
.entity-candidates {
  margin: 8px 0;
  display: flex;
  flex-direction: column;
  gap: 6px;
}
.entity-candidates label {
  display: flex;
  align-items: center;
  gap: 8px;
  font-size: 13px;
  color: #c9d1d9;
  cursor: pointer;
  padding: 4px 8px;
  border-radius: 4px;
  transition: background 0.1s;
}
.entity-candidates label:hover {
  background: #161b22;
}
.entity-candidates input[type="radio"] {
  accent-color: #58a6ff;
}
.entity-candidates .candidate-role {
  font-size: 11px;
  color: #8b949e;
}

/* Ambiguous entity highlight in transcript */
.entity-highlight.ambiguous {
  background: rgba(163, 113, 247, 0.2);
  border-bottom: 2px dashed #a371f7;
  color: #d2a8ff;
}
.entity-card.ambiguous {
  border-left: 3px solid #a371f7;
}
```

### `static/app.js`

Extract all JavaScript functions from `prototype-review-app.html` (lines 666-1061). Key changes from prototype:

1. **Remove** `rawTranscript`, `dictionary`, and `detectEntities()` — these are server-rendered.
2. **Entity field names** use snake_case from server (`entity_type`, `original_text`, `match_type`, `dictionary_id`). Add compat: `ent.type = ent.entity_type || ent.type` etc.
3. **Add** ambiguous entity rendering (radio buttons in entity cards).
4. **Add** dismiss-then-recreate flow (already fixed in prototype).

#### Ambiguous entity rendering in `renderEntityList()`

When an entity has `status === 'ambiguous'`, the entity card shows radio buttons for each candidate plus a "None of these" option:

```javascript
// Inside the entity card template, after the match-info div:
if (ent.status === 'ambiguous' && ent.candidates && ent.candidates.length > 0) {
  // Render radio buttons for disambiguation
  cardHtml += `<div class="entity-candidates">`;
  for (const candidate of ent.candidates) {
    cardHtml += `
      <label>
        <input type="radio" name="disambig-${group.indices[0]}"
               value="${candidate.id}"
               onclick="event.stopPropagation(); disambiguateEntity(${group.indices[0]}, ${candidate.id}, '${escapeHtml(candidate.canonical)}')"
        >
        ${escapeHtml(candidate.canonical)}
        <span class="candidate-role">${escapeHtml(candidate.role || '')}</span>
      </label>
    `;
  }
  // "None of these" option -> dismiss, allowing user to then
  // select the text and create a new entity
  cardHtml += `
    <label>
      <input type="radio" name="disambig-${group.indices[0]}"
             value="none"
             onclick="event.stopPropagation(); dismissEntity(${group.indices[0]})"
      >
      None of these
      <span class="candidate-role">dismiss to mark as new entity</span>
    </label>
  `;
  cardHtml += `</div>`;
}
```

#### New `disambiguateEntity()` function

```javascript
function disambiguateEntity(idx, chosenId, chosenCanonical) {
  const original = entities[idx].original_text || entities[idx].originalText;
  // Update all entities with same original text
  entities.forEach(e => {
    const eOriginal = e.original_text || e.originalText;
    if (eOriginal === original && e.status === 'ambiguous') {
      e.canonical = chosenCanonical;
      e.dictionary_id = e.dictionaryId = chosenId;
      e.status = 'auto-matched';
      e.match_type = e.matchType = 'disambiguated';
      e.confidence = 'high';
      // Track for submit payload
      e._disambiguated = { original: eOriginal, chosen_id: chosenId, chosen_canonical: chosenCanonical };
    }
  });
  render();
}
```

#### Updated `submitReview()` to include disambiguated entities

```javascript
async function submitReview() {
  const activeEntities = entities.filter(e => e.status !== 'dismissed');
  const dismissed = entities.filter(e => e.status === 'dismissed');
  const corrections = activeEntities.filter(e =>
    (e.original_text || e.originalText) !== e.canonical
  );

  // Build corrected transcript
  let corrected = rawTranscript;
  const sorted = [...corrections].sort((a, b) => b.start - a.start);
  for (const ent of sorted) {
    corrected = corrected.substring(0, ent.start)
      + ent.canonical
      + corrected.substring(ent.end);
  }

  const payload = {
    corrected_transcript: corrected,
    date: TRANSCRIPT_DATE,
    author: TRANSCRIPT_AUTHOR,
    entities: activeEntities.map(e => ({
      text: e.canonical,
      type: e.entity_type || e.type,
      original: e.original_text || e.originalText,
      is_correction: (e.original_text || e.originalText) !== e.canonical,
      match_type: e.match_type || e.matchType,
    })),
    new_variations: corrections
      .filter(e => (e.dictionary_id || e.dictionaryId))
      .map(e => ({
        original: e.original_text || e.originalText,
        canonical: e.canonical,
        type: e.entity_type || e.type,
        source: e.source,
        dictionary_id: e.dictionary_id || e.dictionaryId,
      })),
    new_entities: activeEntities
      .filter(e => e.status === 'new-entity')
      .map(e => ({
        text: e.canonical,
        type: e.entity_type || e.type,
        source: e.source || ((e.entity_type || e.type) === 'PERSON' ? 'person' : 'term'),
      })),
    disambiguated: activeEntities
      .filter(e => e._disambiguated)
      .map(e => e._disambiguated),
    dismissed: dismissed.map(e => ({
      original: e.original_text || e.originalText,
      canonical: e.canonical,
      type: e.entity_type || e.type,
    })),
  };

  document.getElementById('submit-btn').disabled = true;
  document.getElementById('submit-btn').textContent = 'Submitting...';

  try {
    const resp = await fetch(`/api/transcripts/${TRANSCRIPT_ID}/submit`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(payload),
    });
    const result = await resp.json();
    if (result.status === 'submitted') {
      document.getElementById('submit-btn').textContent = 'Submitted';
      setTimeout(() => window.location.href = '/', 1000);
    } else {
      alert('Error: ' + JSON.stringify(result));
      document.getElementById('submit-btn').disabled = false;
      document.getElementById('submit-btn').textContent = 'Save & Submit to Pipeline';
    }
  } catch (err) {
    alert('Network error: ' + err.message);
    document.getElementById('submit-btn').disabled = false;
    document.getElementById('submit-btn').textContent = 'Save & Submit to Pipeline';
  }
}
```

#### Dismiss-then-recreate flow

Already fixed in prototype. When `addManualEntity()` is called, dismissed entities overlapping the new entity's range are removed first:

```javascript
function addManualEntity(type) {
  if (!pendingSelection) return;

  const newEntity = {
    start: pendingSelection.start,
    end: pendingSelection.end,
    original_text: pendingSelection.text,
    canonical: pendingSelection.text,
    entity_type: type,
    match_type: 'manual',
    confidence: 'high',
    status: 'new-entity',
    dictionary_id: null,
    source: type === 'PERSON' ? 'person' : 'term'
  };

  // Remove dismissed entities that overlap with the new entity's range
  entities = entities.filter(e =>
    !(e.status === 'dismissed' && e.start < newEntity.end && e.end > newEntity.start)
  );

  entities.push(newEntity);
  entities.sort((a, b) => a.start - b.start);

  // Deduplicate
  const deduped = [];
  let lastEnd = -1;
  for (const d of entities) {
    if (d.start >= lastEnd) {
      deduped.push(d);
      lastEnd = d.end;
    }
  }
  entities = deduped;

  hideSelectionPopup();
  window.getSelection().removeAllRanges();

  const newIdx = entities.findIndex(
    e => e.start === newEntity.start && e.end === newEntity.end
  );
  activeEntityIdx = newIdx;
  render();
}
```

---

## 7. Templates

### `templates/base.html`

```html
<!DOCTYPE html>
<html lang="de">
<head>
  <title>{% block title %}Diary Review{% endblock %}</title>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <script src="https://unpkg.com/htmx.org@1.9.12"></script>
  <link rel="stylesheet" href="/static/style.css">
</head>
<body>
  {% block content %}{% endblock %}
  <script src="/static/app.js"></script>
</body>
</html>
```

### `templates/review.html`

```html
{% extends "base.html" %}
{% block title %}Review: {{ transcript.filename }}{% endblock %}
{% block content %}

<header>
  <h1>Diary Transcript Review</h1>
  <div class="header-meta">
    <div><a href="/" class="btn btn-secondary"
            style="padding:4px 12px;font-size:12px;">All Transcripts</a></div>
    <div><strong>Date:</strong> {{ transcript.date }}</div>
    <div><strong>Author:</strong> {{ transcript.author }}</div>
    <div><strong>Dictionary:</strong> {{ person_count }} persons, {{ term_count }} terms</div>
  </div>
</header>

<div class="status-bar">
  <div class="stat"><span class="stat-dot green"></span>
    <span><strong id="auto-count">0</strong> auto-corrected</span></div>
  <div class="stat"><span class="stat-dot yellow"></span>
    <span><strong id="suggested-count">0</strong> suggested</span></div>
  <div class="stat"><span class="stat-dot blue"></span>
    <span><strong id="new-count">0</strong> new</span></div>
  <div class="stat"><span class="stat-dot red"></span>
    <span><strong id="unresolved-count">0</strong> need review</span></div>
</div>

<div class="main">
  <div class="transcript-panel">
    <h2>Transcript with Entity Detection</h2>
    <div class="transcript-text" id="transcript"></div>
  </div>

  <div class="selection-popup" id="selection-popup">
    <div class="selection-popup-label">Mark as entity:</div>
    <div class="selection-popup-text" id="selection-popup-text"></div>
    <div class="selection-popup-types">
      <button onclick="addManualEntity('PERSON')">Person</button>
      <button onclick="addManualEntity('ORGANIZATION')">Organization</button>
      <button onclick="addManualEntity('TERM')">Term</button>
      <button onclick="addManualEntity('TECHNOLOGY')">Technology</button>
      <button onclick="addManualEntity('PROJECT')">Project</button>
      <button onclick="addManualEntity('ROLE')">Role</button>
      <button onclick="addManualEntity('LOCATION')">Location</button>
      <button onclick="addManualEntity('EVENT')">Event</button>
    </div>
  </div>

  <div class="entity-sidebar">
    <div class="sidebar-header"><h2>Detected Entities</h2></div>
    <div class="entity-list" id="entity-list"></div>
  </div>
</div>

<footer>
  <div class="footer-info">
    <span id="correction-summary">Loading...</span>
  </div>
  <div class="footer-actions">
    <button class="btn btn-secondary" onclick="skipTranscript()">Skip</button>
    <button class="btn btn-primary" id="submit-btn" onclick="submitReview()">
      Save &amp; Submit to Pipeline
    </button>
  </div>
</footer>

<script>
  const TRANSCRIPT_ID = {{ transcript.id }};
  const TRANSCRIPT_DATE = '{{ transcript.date }}';
  const TRANSCRIPT_AUTHOR = '{{ transcript.author }}';
  const rawTranscript = {{ raw_text | tojson }};
  let entities = {{ entities_json | safe }};
  let activeEntityIdx = null;

  // All render/interaction logic loaded from /static/app.js
  render();
</script>

{% endblock %}
```

### `templates/index.html`

```html
{% extends "base.html" %}
{% block title %}Diary Transcripts{% endblock %}
{% block content %}

<header>
  <h1>Diary Transcript Review</h1>
  <div class="header-meta">
    <div>{{ transcripts | length }} transcripts</div>
  </div>
</header>

<div style="padding: 24px; max-width: 800px;">
  <h2 style="font-size:13px;text-transform:uppercase;letter-spacing:0.5px;color:#8b949e;margin-bottom:16px;">
    Transcripts
  </h2>

  {% for t in transcripts %}
  <a href="/review/{{ t.id }}" style="text-decoration:none;color:inherit;">
    <div class="entity-card" style="cursor:pointer;">
      <div class="entity-card-header">
        <span class="entity-original">{{ t.filename }}</span>
        <span class="entity-type-badge
          badge-{{ 'person' if t.status == 'pending' else 'term' if t.status == 'submitted' else 'technology' }}">
          {{ t.status }}
        </span>
      </div>
      <div class="entity-match-info">{{ t.date }} &middot; {{ t.author or 'Unknown' }}</div>
    </div>
  </a>
  {% else %}
  <p style="color:#8b949e;">
    No transcripts yet. They arrive via webhook from n8n after ASR processing.
  </p>
  {% endfor %}
</div>

{% endblock %}
```

---

## 8. Docker

### `Dockerfile`

```dockerfile
FROM python:3.11-slim
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY . .
EXPOSE 8000
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000"]
```

### `docker-compose.yml`

```yaml
services:
  webapp:
    build: ./webapp
    ports:
      - "8000:8000"
    environment:
      - DATABASE_URL=postgresql://diary:diary@postgres:5432/diary_processor
      - N8N_WEBHOOK_URL=http://192.168.2.16:5678/webhook/diary-reviewed
    depends_on:
      postgres:
        condition: service_healthy
    restart: unless-stopped

  postgres:
    image: postgres:16-alpine
    environment:
      POSTGRES_USER: diary
      POSTGRES_PASSWORD: diary
      POSTGRES_DB: diary_processor
    ports:
      - "5432:5432"
    volumes:
      - pgdata:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U diary"]
      interval: 5s
      timeout: 5s
      retries: 5
    restart: unless-stopped

volumes:
  pgdata:
```

---

## 9. Data Flow

```
n8n (after ASR)
  |
  | POST /webhook/transcript-ready
  |   { filename, date, author, text }
  v
Webapp (Postgres: transcripts table, status='pending')
  |
  | User opens /review/{id}
  |   -> Server loads dictionary from Postgres
  |   -> Server runs 4-pass entity detection
  |   -> Ambiguous first-names get candidates list
  |   -> Server renders review.html with entities
  |
  | User reviews:
  |   - Green (auto-matched): confirm or dismiss
  |   - Yellow (suggested): confirm, correct, or dismiss
  |   - Purple (ambiguous): pick candidate via radio buttons,
  |     or dismiss and select text to create new entity
  |   - Select text: mark as new entity via popup
  |
  | User clicks "Save & Submit"
  |   POST /api/transcripts/{id}/submit
  v
Webapp backend:
  1. Saves corrected_text to transcripts table
  2. Saves new variations to person_variations / term_variations
  3. Saves disambiguated names as variations (learning)
  4. Creates new persons/terms for manually added entities
  5. Logs all actions to review_log
  6. POSTs corrected transcript + entity list to n8n webhook
  |
  v
n8n (simplified workflow, see N8N_SIMPLIFIED_WORKFLOW.md)
```

---

## 10. Running Locally

```bash
# Start Postgres
docker compose up -d postgres

# Apply schema
psql postgresql://diary:diary@localhost:5432/diary_processor < schema.sql

# Run webapp
cd webapp
pip install -r requirements.txt
DATABASE_URL=postgresql://diary:diary@localhost:5432/diary_processor \
N8N_WEBHOOK_URL=http://192.168.2.16:5678/webhook/diary-reviewed \
uvicorn main:app --reload --port 8000

# Open http://localhost:8000
```

---

## 11. Learning Loop

The dictionary grows automatically through usage:

| Day | Auto-matched | Suggested | Ambiguous | Manual | Review time |
|-----|-------------|-----------|-----------|--------|-------------|
| 1   | ~40%        | ~20%      | ~10%      | ~30%   | 5-10 min    |
| 10  | ~65%        | ~15%      | ~5%       | ~15%   | 3-5 min     |
| 30  | ~85%        | ~10%      | ~2%       | ~3%    | 1-2 min     |
| 90+ | ~95%        | ~3%       | ~1%       | ~1%    | 30 sec      |

Every correction adds a row to `person_variations` or `term_variations`. Every disambiguation saves the first-name→person mapping. The next transcript benefits immediately.
