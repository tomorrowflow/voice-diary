import asyncpg
import json
import os
from datetime import date as date_type, datetime
from typing import Optional

_pool: Optional[asyncpg.Pool] = None

DATABASE_URL = os.getenv(
    "DATABASE_URL",
    "postgresql://diary:diary@localhost:5432/diary_processor",
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
               p.role, p.department, p.company, p.context,
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


_VARIATION_BLOCKLIST = {
    # Common German words that should never be stored as name/term variations.
    # These cause false-positive entity matches across all transcripts.
    "da", "wo", "so", "ja", "nun", "nie", "oft",
    "der", "die", "das", "dem", "den", "des",
    "ein", "eine", "einer", "einem", "einen",
    "und", "oder", "aber", "dass", "wenn", "weil",
    "ist", "hat", "war", "sind", "haben", "werden",
    "ich", "du", "er", "sie", "es", "wir", "ihr",
    "mit", "von", "bei", "für", "auf", "aus",
    "nach", "über", "unter", "vor", "zwischen",
    "auch", "noch", "schon", "dann", "denn", "doch",
    "sehr", "ganz", "nur", "eben", "halt", "wohl",
    "deal",  # commonly misheard but not a name
}


async def save_person_variation(
    person_id: int, variation: str, variation_type: str = "asr_correction"
):
    # Reject short common words that would cause false-positive matches
    if variation.lower() in _VARIATION_BLOCKLIST:
        return
    if len(variation) <= 2 and not variation.isupper():
        return
    pool = await get_pool()
    await pool.execute(
        """
        INSERT INTO person_variations (person_id, variation, variation_type, auto_created)
        VALUES ($1, $2, $3, FALSE)
        ON CONFLICT (person_id, variation) DO NOTHING
    """,
        person_id,
        variation,
        variation_type,
    )


async def save_term_variation(term_id: int, variation: str):
    # Reject short common words that would cause false-positive matches
    if variation.lower() in _VARIATION_BLOCKLIST:
        return
    if len(variation) <= 2 and not variation.isupper():
        return
    pool = await get_pool()
    await pool.execute(
        """
        INSERT INTO term_variations (term_id, variation, auto_created)
        VALUES ($1, $2, FALSE)
        ON CONFLICT (term_id, variation) DO NOTHING
    """,
        term_id,
        variation,
    )


async def load_all_persons() -> list[dict]:
    """Load all persons (including inactive) with their variations (including IDs)."""
    pool = await get_pool()
    rows = await pool.fetch("""
        SELECT p.id, p.canonical_name, p.first_name, p.last_name,
               p.role, p.department, p.company, p.context, p.status,
               COALESCE(
                   json_agg(json_build_object(
                       'id', pv.id,
                       'text', pv.variation,
                       'type', pv.variation_type
                   ) ORDER BY pv.id) FILTER (WHERE pv.id IS NOT NULL),
                   '[]'::json
               ) AS variations
        FROM persons p
        LEFT JOIN person_variations pv ON pv.person_id = p.id
        GROUP BY p.id
        ORDER BY p.canonical_name
    """)
    return [dict(r) for r in rows]


async def load_all_terms() -> list[dict]:
    """Load all terms (including inactive) with their variations (including IDs)."""
    pool = await get_pool()
    rows = await pool.fetch("""
        SELECT t.id, t.canonical_term, t.category, t.context, t.status,
               COALESCE(
                   json_agg(json_build_object(
                       'id', tv.id,
                       'text', tv.variation
                   ) ORDER BY tv.id) FILTER (WHERE tv.id IS NOT NULL),
                   '[]'::json
               ) AS variations
        FROM terms t
        LEFT JOIN term_variations tv ON tv.term_id = t.id
        GROUP BY t.id
        ORDER BY t.canonical_term
    """)
    return [dict(r) for r in rows]


async def update_person(
    person_id: int,
    *,
    first_name: str,
    last_name: str,
    role: str,
    department: str,
    company: str,
    context: str = "",
    status: str,
):
    pool = await get_pool()
    canonical_name = f"{first_name} {last_name}".strip()
    await pool.execute(
        """
        UPDATE persons
        SET canonical_name = $2, first_name = $3, last_name = $4,
            role = $5, department = $6, company = $7, context = $8,
            status = $9, updated_at = NOW()
        WHERE id = $1
    """,
        person_id,
        canonical_name,
        first_name,
        last_name,
        role,
        department,
        company,
        context,
        status,
    )


async def update_term(
    term_id: int,
    *,
    canonical_term: str,
    category: str,
    context: str,
    status: str,
):
    pool = await get_pool()
    await pool.execute(
        """
        UPDATE terms
        SET canonical_term = $2, category = $3, context = $4, status = $5,
            updated_at = NOW()
        WHERE id = $1
    """,
        term_id,
        canonical_term,
        category,
        context,
        status,
    )


async def delete_person(person_id: int):
    pool = await get_pool()
    await pool.execute("DELETE FROM persons WHERE id = $1", person_id)


async def delete_term(term_id: int):
    pool = await get_pool()
    await pool.execute("DELETE FROM terms WHERE id = $1", term_id)


async def delete_person_variation(variation_id: int):
    pool = await get_pool()
    await pool.execute("DELETE FROM person_variations WHERE id = $1", variation_id)


async def delete_term_variation(variation_id: int):
    pool = await get_pool()
    await pool.execute("DELETE FROM term_variations WHERE id = $1", variation_id)


async def create_person(
    canonical_name: str,
    first_name: str = "",
    last_name: str = "",
    role: str = "",
    company: str = "",
    context: str = "",
) -> int:
    pool = await get_pool()
    row = await pool.fetchrow(
        """
        INSERT INTO persons (canonical_name, first_name, last_name, role, company, context)
        VALUES ($1, $2, $3, $4, $5, $6)
        ON CONFLICT (canonical_name) DO UPDATE SET updated_at = NOW()
        RETURNING id
    """,
        canonical_name,
        first_name,
        last_name,
        role,
        company,
        context,
    )
    person_id = row["id"]
    await save_person_variation(person_id, canonical_name, "canonical")
    return person_id


async def create_term(
    canonical_term: str, category: str, context: str = ""
) -> int:
    pool = await get_pool()
    row = await pool.fetchrow(
        """
        INSERT INTO terms (canonical_term, category, context)
        VALUES ($1, $2, $3)
        ON CONFLICT (canonical_term) DO UPDATE SET updated_at = NOW()
        RETURNING id
    """,
        canonical_term,
        category,
        context,
    )
    term_id = row["id"]
    await save_term_variation(term_id, canonical_term)
    return term_id


# --- Transcript management ---


async def list_transcripts(status: str = None) -> list[dict]:
    pool = await get_pool()
    base = (
        "SELECT id, filename, date, author, status, created_at, "
        "submitted_at, processed_at, processing_error, "
        "array_length(regexp_split_to_array(raw_text, '\\s+'), 1) AS word_count "
        "FROM transcripts"
    )
    if status:
        rows = await pool.fetch(
            base + " WHERE status = $1 ORDER BY date DESC", status
        )
    else:
        rows = await pool.fetch(base + " ORDER BY date DESC")
    return [dict(r) for r in rows]


async def delete_transcripts(ids: list[int]):
    pool = await get_pool()
    await pool.execute(
        "DELETE FROM transcripts WHERE id = ANY($1::int[])", ids
    )


async def get_transcript(transcript_id: int) -> dict | None:
    pool = await get_pool()
    row = await pool.fetchrow(
        "SELECT * FROM transcripts WHERE id = $1", transcript_id
    )
    return dict(row) if row else None


def _parse_date_flexible(date_val) -> "date_type":
    """Parse a date from various formats: YYYY-MM-DD, YYYYMMDD, or extract
    8-digit date pattern from arbitrary strings."""
    import re as _re

    if isinstance(date_val, date_type):
        return date_val
    if not isinstance(date_val, str) or not date_val.strip():
        return date_type.today()

    s = date_val.strip()

    # Try YYYY-MM-DD
    try:
        return datetime.strptime(s, "%Y-%m-%d").date()
    except ValueError:
        pass

    # Try YYYYMMDD
    try:
        return datetime.strptime(s, "%Y%m%d").date()
    except ValueError:
        pass

    # Try DD.MM.YYYY (German format)
    try:
        return datetime.strptime(s, "%d.%m.%Y").date()
    except ValueError:
        pass

    # Extract 8-digit date pattern (YYYYMMDD) from anywhere in the string
    m = _re.search(r"(20\d{2})(0[1-9]|1[0-2])(0[1-9]|[12]\d|3[01])", s)
    if m:
        return date_type(int(m.group(1)), int(m.group(2)), int(m.group(3)))

    # Fallback to today
    return date_type.today()


async def create_transcript(
    filename: str, date: str, author: str, raw_text: str
) -> int:
    pool = await get_pool()
    # asyncpg requires a datetime.date object, not a string
    if not isinstance(date, date_type):
        date = _parse_date_flexible(date)
    row = await pool.fetchrow(
        """
        INSERT INTO transcripts (filename, date, author, raw_text)
        VALUES ($1, $2, $3, $4) RETURNING id
    """,
        filename,
        date,
        author,
        raw_text,
    )
    return row["id"]


async def save_draft(
    transcript_id: int,
    corrected_text: str,
    raw_text: str = None,
    entities_json: str = None,
):
    """Save corrected transcript, raw_text, and entity states, setting status to 'saved'.

    When entities_json is None, existing entities are preserved (not overwritten).
    """
    pool = await get_pool()
    if raw_text:
        await pool.execute(
            """
            UPDATE transcripts
            SET corrected_text = $2, raw_text = $3,
                entities_json = COALESCE($4::jsonb, entities_json),
                status = 'saved'
            WHERE id = $1
        """,
            transcript_id,
            corrected_text,
            raw_text,
            entities_json,
        )
    else:
        await pool.execute(
            """
            UPDATE transcripts
            SET corrected_text = $2,
                entities_json = COALESCE($3::jsonb, entities_json),
                status = 'saved'
            WHERE id = $1
        """,
            transcript_id,
            corrected_text,
            entities_json,
        )


async def submit_transcript(transcript_id: int, corrected_text: str):
    pool = await get_pool()
    await pool.execute(
        """
        UPDATE transcripts
        SET corrected_text = $2, status = 'submitted', submitted_at = NOW()
        WHERE id = $1
    """,
        transcript_id,
        corrected_text,
    )


async def reset_transcript(transcript_id: int):
    pool = await get_pool()
    await pool.execute(
        """
        UPDATE transcripts
        SET corrected_text = NULL, entities_json = NULL,
            status = 'pending', submitted_at = NULL,
            processed_at = NULL, processing_error = NULL
        WHERE id = $1
    """,
        transcript_id,
    )


async def mark_transcript_processed(transcript_id: int):
    pool = await get_pool()
    await pool.execute(
        """
        UPDATE transcripts SET status = 'processed', processed_at = NOW(),
               processing_error = NULL
        WHERE id = $1
    """,
        transcript_id,
    )


async def mark_transcript_failed(transcript_id: int, error: str):
    pool = await get_pool()
    await pool.execute(
        """
        UPDATE transcripts SET status = 'failed', processed_at = NOW(),
               processing_error = $2
        WHERE id = $1
    """,
        transcript_id,
        error,
    )


# --- Review log ---


async def log_review_action(
    transcript_id: int,
    original: str,
    corrected: str,
    entity_type: str,
    match_type: str,
    action: str,
):
    pool = await get_pool()
    await pool.execute(
        """
        INSERT INTO review_log
          (transcript_id, original_text, corrected_text, entity_type, match_type, action)
        VALUES ($1, $2, $3, $4, $5, $6)
    """,
        transcript_id,
        original,
        corrected,
        entity_type,
        match_type,
        action,
    )


# --- Data management ---


async def get_data_counts() -> dict:
    pool = await get_pool()
    row = await pool.fetchrow("""
        SELECT
            (SELECT COUNT(*) FROM persons) AS persons,
            (SELECT COUNT(*) FROM terms) AS terms,
            (SELECT COUNT(*) FROM person_variations) +
            (SELECT COUNT(*) FROM term_variations) AS variations,
            (SELECT COUNT(*) FROM transcripts) AS transcripts,
            (SELECT COUNT(*) FROM text_corrections WHERE active = TRUE) AS text_corrections
    """)
    return dict(row)


async def export_backup(
    include_transcripts: bool = True, include_review_log: bool = True
) -> dict:
    pool = await get_pool()

    # Persons with nested variations
    person_rows = await pool.fetch("""
        SELECT p.canonical_name, p.first_name, p.last_name,
               p.role, p.department, p.company, p.context, p.status,
               COALESCE(
                   json_agg(json_build_object(
                       'variation', pv.variation,
                       'type', pv.variation_type
                   ) ORDER BY pv.id) FILTER (WHERE pv.id IS NOT NULL),
                   '[]'::json
               ) AS variations
        FROM persons p
        LEFT JOIN person_variations pv ON pv.person_id = p.id
        GROUP BY p.id
        ORDER BY p.canonical_name
    """)
    persons = []
    for r in person_rows:
        p = dict(r)
        if isinstance(p["variations"], str):
            import json as _json
            p["variations"] = _json.loads(p["variations"])
        persons.append(p)

    # Terms with nested variations
    term_rows = await pool.fetch("""
        SELECT t.canonical_term, t.category, t.context, t.status,
               COALESCE(
                   json_agg(json_build_object(
                       'variation', tv.variation
                   ) ORDER BY tv.id) FILTER (WHERE tv.id IS NOT NULL),
                   '[]'::json
               ) AS variations
        FROM terms t
        LEFT JOIN term_variations tv ON tv.term_id = t.id
        GROUP BY t.id
        ORDER BY t.canonical_term
    """)
    terms = []
    for r in term_rows:
        t = dict(r)
        if isinstance(t["variations"], str):
            import json as _json
            t["variations"] = _json.loads(t["variations"])
        terms.append(t)

    backup = {
        "format": "diary-processor-backup",
        "version": 1,
        "created_at": datetime.utcnow().isoformat() + "Z",
        "persons": persons,
        "terms": terms,
    }

    if include_transcripts:
        rows = await pool.fetch(
            "SELECT filename, date, author, raw_text, corrected_text, status "
            "FROM transcripts ORDER BY date"
        )
        backup["transcripts"] = [
            {**dict(r), "date": r["date"].isoformat() if r["date"] else None}
            for r in rows
        ]

    if include_review_log:
        rows = await pool.fetch(
            "SELECT transcript_id, original_text, corrected_text, "
            "entity_type, match_type, action FROM review_log ORDER BY id"
        )
        backup["review_log"] = [dict(r) for r in rows]

    # Text corrections
    try:
        rows = await pool.fetch(
            "SELECT original_text, corrected_text, correction_type, "
            "case_sensitive, use_count, active "
            "FROM text_corrections ORDER BY id"
        )
        backup["text_corrections"] = [dict(r) for r in rows]
    except Exception:
        pass  # table may not exist yet

    return backup


async def restore_backup(data: dict):
    pool = await get_pool()
    async with pool.acquire() as conn:
        async with conn.transaction():
            # Determine which tables to truncate
            tables = ["persons", "terms"]
            if "transcripts" in data:
                tables.append("transcripts")
            if "review_log" in data:
                tables.append("review_log")
            if "text_corrections" in data:
                tables.append("text_corrections")
            await conn.execute(
                f"TRUNCATE {', '.join(tables)} CASCADE"
            )

            # Restore persons + variations
            for p in data.get("persons", []):
                row = await conn.fetchrow(
                    "INSERT INTO persons (canonical_name, first_name, last_name, "
                    "role, department, company, context, status) "
                    "VALUES ($1, $2, $3, $4, $5, $6, $7, $8) RETURNING id",
                    p["canonical_name"],
                    p.get("first_name", ""),
                    p.get("last_name", ""),
                    p.get("role", ""),
                    p.get("department", ""),
                    p.get("company", ""),
                    p.get("context", ""),
                    p.get("status", "active"),
                )
                pid = row["id"]
                for v in p.get("variations", []):
                    await conn.execute(
                        "INSERT INTO person_variations (person_id, variation, variation_type) "
                        "VALUES ($1, $2, $3) ON CONFLICT DO NOTHING",
                        pid,
                        v["variation"],
                        v.get("type", "asr_correction"),
                    )

            # Restore terms + variations
            for t in data.get("terms", []):
                row = await conn.fetchrow(
                    "INSERT INTO terms (canonical_term, category, context, status) "
                    "VALUES ($1, $2, $3, $4) RETURNING id",
                    t["canonical_term"],
                    t.get("category", "term"),
                    t.get("context", ""),
                    t.get("status", "active"),
                )
                tid = row["id"]
                for v in t.get("variations", []):
                    await conn.execute(
                        "INSERT INTO term_variations (term_id, variation) "
                        "VALUES ($1, $2) ON CONFLICT DO NOTHING",
                        tid,
                        v["variation"],
                    )

            # Restore transcripts
            for tr in data.get("transcripts", []):
                d = tr.get("date")
                if isinstance(d, str):
                    d = datetime.strptime(d, "%Y-%m-%d").date()
                await conn.execute(
                    "INSERT INTO transcripts (filename, date, author, raw_text, "
                    "corrected_text, status) VALUES ($1, $2, $3, $4, $5, $6)",
                    tr["filename"],
                    d,
                    tr.get("author", ""),
                    tr.get("raw_text", ""),
                    tr.get("corrected_text"),
                    tr.get("status", "pending"),
                )

            # Restore review log
            for rl in data.get("review_log", []):
                await conn.execute(
                    "INSERT INTO review_log (transcript_id, original_text, "
                    "corrected_text, entity_type, match_type, action) "
                    "VALUES ($1, $2, $3, $4, $5, $6)",
                    rl["transcript_id"],
                    rl["original_text"],
                    rl["corrected_text"],
                    rl["entity_type"],
                    rl["match_type"],
                    rl["action"],
                )

            # Restore text corrections
            for tc in data.get("text_corrections", []):
                await conn.execute(
                    "INSERT INTO text_corrections (original_text, corrected_text, "
                    "correction_type, case_sensitive, use_count, active) "
                    "VALUES ($1, $2, $3, $4, $5, $6) "
                    "ON CONFLICT (original_text, corrected_text) DO NOTHING",
                    tc["original_text"],
                    tc["corrected_text"],
                    tc.get("correction_type", "word"),
                    tc.get("case_sensitive", False),
                    tc.get("use_count", 1),
                    tc.get("active", True),
                )


async def import_csv_data(
    persons: list[dict],
    person_vars: list[dict],
    terms: list[dict],
    term_vars: list[dict],
    replace: bool = False,
) -> dict:
    pool = await get_pool()
    counts = {"persons": 0, "person_variations": 0, "terms": 0, "term_variations": 0}

    async with pool.acquire() as conn:
        async with conn.transaction():
            if replace:
                await conn.execute("TRUNCATE persons, terms CASCADE")

            # Import persons
            for p in persons:
                canonical = p.get("canonical_name", "").strip()
                if not canonical:
                    continue
                await conn.fetchrow(
                    "INSERT INTO persons (canonical_name, first_name, last_name, "
                    "role, department, company, context, status) "
                    "VALUES ($1, $2, $3, $4, $5, $6, $7, $8) "
                    "ON CONFLICT (canonical_name) DO UPDATE SET "
                    "first_name=EXCLUDED.first_name, last_name=EXCLUDED.last_name, "
                    "role=EXCLUDED.role, department=EXCLUDED.department, "
                    "company=EXCLUDED.company, context=EXCLUDED.context, "
                    "updated_at=NOW() RETURNING id",
                    canonical,
                    p.get("first_name", "").strip(),
                    p.get("last_name", "").strip(),
                    p.get("role", "").strip(),
                    p.get("department", "").strip(),
                    p.get("company", "").strip(),
                    p.get("context", "").strip(),
                    p.get("status", "active").strip(),
                )
                counts["persons"] += 1

            # Import person variations (chunked by parent count)
            var_idx = 0
            for p in persons:
                canonical = p.get("canonical_name", "").strip()
                if not canonical:
                    continue
                count = int(p.get("person_variations", 0))
                chunk = person_vars[var_idx:var_idx + count]
                var_idx += count
                pid_row = await conn.fetchrow(
                    "SELECT id FROM persons WHERE canonical_name = $1", canonical
                )
                if not pid_row:
                    continue
                pid = pid_row["id"]
                for v in chunk:
                    variation = v.get("variation", "").strip()
                    if not variation:
                        continue
                    await conn.execute(
                        "INSERT INTO person_variations "
                        "(person_id, variation, variation_type, confidence, approved) "
                        "VALUES ($1, $2, $3, $4, $5) "
                        "ON CONFLICT (person_id, variation) DO NOTHING",
                        pid,
                        variation,
                        v.get("variation_type", "asr_correction").strip(),
                        v.get("confidence", "high").strip(),
                        v.get("approved", "1") == "1",
                    )
                    counts["person_variations"] += 1

            # Import terms
            for t in terms:
                canonical = t.get("canonical_term", "").strip()
                if not canonical:
                    continue
                await conn.fetchrow(
                    "INSERT INTO terms (canonical_term, category, context, status) "
                    "VALUES ($1, $2, $3, $4) "
                    "ON CONFLICT (canonical_term) DO UPDATE SET "
                    "category=EXCLUDED.category, context=EXCLUDED.context, "
                    "updated_at=NOW() RETURNING id",
                    canonical,
                    t.get("category", "term").strip(),
                    t.get("context", "").strip(),
                    t.get("status", "active").strip(),
                )
                counts["terms"] += 1

            # Import term variations (chunked by parent count)
            var_idx = 0
            for t in terms:
                canonical = t.get("canonical_term", "").strip()
                if not canonical:
                    continue
                count = int(t.get("term_variations", 0))
                chunk = term_vars[var_idx:var_idx + count]
                var_idx += count
                tid_row = await conn.fetchrow(
                    "SELECT id FROM terms WHERE canonical_term = $1", canonical
                )
                if not tid_row:
                    continue
                tid = tid_row["id"]
                for v in chunk:
                    variation = v.get("variation", "").strip()
                    if not variation:
                        continue
                    await conn.execute(
                        "INSERT INTO term_variations "
                        "(term_id, variation, approved) "
                        "VALUES ($1, $2, $3) "
                        "ON CONFLICT (term_id, variation) DO NOTHING",
                        tid,
                        variation,
                        v.get("approved", "1") == "1",
                    )
                    counts["term_variations"] += 1

    return counts


async def clear_dictionary():
    pool = await get_pool()
    await pool.execute("TRUNCATE persons, terms CASCADE")


async def get_transcript_by_date(date_str: str) -> dict | None:
    """Get the most recent transcript for a given date."""
    pool = await get_pool()
    if isinstance(date_str, str):
        d = datetime.strptime(date_str, "%Y-%m-%d").date()
    else:
        d = date_str
    row = await pool.fetchrow(
        "SELECT * FROM transcripts WHERE date = $1 ORDER BY created_at DESC LIMIT 1",
        d,
    )
    return dict(row) if row else None


async def reset_all_data():
    pool = await get_pool()
    await pool.execute("TRUNCATE persons, terms, transcripts, review_log CASCADE")
    try:
        await pool.execute("DELETE FROM harvest_entries")
    except Exception:
        pass  # table may not exist yet
    try:
        await pool.execute("DELETE FROM text_corrections")
    except Exception:
        pass  # table may not exist yet


# --- Harvest entries ---


async def ensure_harvest_table():
    """Create harvest_entries table if it doesn't exist."""
    pool = await get_pool()
    await pool.execute("""
        CREATE TABLE IF NOT EXISTS harvest_entries (
            id SERIAL PRIMARY KEY,
            harvest_id BIGINT UNIQUE NOT NULL,
            spent_date DATE NOT NULL,
            hours NUMERIC(6,2) NOT NULL,
            notes TEXT,
            project_id BIGINT,
            project_name VARCHAR(300),
            task_id BIGINT,
            task_name VARCHAR(300),
            client_name VARCHAR(300),
            raw_json JSONB,
            created_at TIMESTAMPTZ DEFAULT NOW()
        )
    """)
    await pool.execute(
        "CREATE INDEX IF NOT EXISTS idx_harvest_entries_date ON harvest_entries (spent_date)"
    )


async def save_harvest_entries(entries: list[dict]):
    """Store Harvest time entries (upsert by harvest_id)."""
    pool = await get_pool()
    async with pool.acquire() as conn:
        async with conn.transaction():
            for entry in entries:
                project = entry.get("project") or {}
                task = entry.get("task") or {}
                client = entry.get("client") or {}
                spent = entry.get("spent_date", "")
                # Parse date string to date object
                if isinstance(spent, str):
                    try:
                        spent = date_type.fromisoformat(spent)
                    except ValueError:
                        continue
                await conn.execute("""
                    INSERT INTO harvest_entries
                        (harvest_id, spent_date, hours, notes,
                         project_id, project_name, task_id, task_name,
                         client_name, raw_json)
                    VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10)
                    ON CONFLICT (harvest_id) DO UPDATE SET
                        hours = EXCLUDED.hours,
                        notes = EXCLUDED.notes,
                        project_name = EXCLUDED.project_name,
                        task_name = EXCLUDED.task_name,
                        raw_json = EXCLUDED.raw_json
                """,
                    entry.get("id"),
                    spent,
                    float(entry.get("hours", 0)),
                    entry.get("notes") or "",
                    project.get("id"),
                    project.get("name", ""),
                    task.get("id"),
                    task.get("name", ""),
                    client.get("name", ""),
                    json.dumps(entry),
                )


async def get_harvest_entries() -> list[dict]:
    """Load all stored harvest entries as dicts for pattern building."""
    pool = await get_pool()
    rows = await pool.fetch("""
        SELECT harvest_id, spent_date, hours, notes,
               project_id, project_name, task_id, task_name,
               client_name
        FROM harvest_entries
        ORDER BY spent_date DESC
    """)
    return [
        {
            "id": r["harvest_id"],
            "spent_date": r["spent_date"].isoformat() if r["spent_date"] else "",
            "hours": float(r["hours"]),
            "notes": r["notes"],
            "project": {"id": r["project_id"], "name": r["project_name"]},
            "task": {"id": r["task_id"], "name": r["task_name"]},
            "client": {"name": r["client_name"]},
        }
        for r in rows
    ]


async def get_harvest_entry_stats() -> dict:
    """Get summary stats about stored harvest entries."""
    pool = await get_pool()
    row = await pool.fetchrow("""
        SELECT COUNT(*) AS cnt,
               MIN(spent_date) AS min_date,
               MAX(spent_date) AS max_date
        FROM harvest_entries
    """)
    if not row or row["cnt"] == 0:
        return {"count": 0, "from_date": None, "to_date": None}
    return {
        "count": row["cnt"],
        "from_date": row["min_date"].isoformat() if row["min_date"] else None,
        "to_date": row["max_date"].isoformat() if row["max_date"] else None,
    }


async def clear_harvest_entries():
    """Delete all stored harvest entries."""
    pool = await get_pool()
    await pool.execute("DELETE FROM harvest_entries")


# --- Text corrections ---


async def save_text_correction(
    original: str, corrected: str, correction_type: str = "word"
):
    """Upsert a text correction rule, incrementing use_count on conflict."""
    pool = await get_pool()
    await pool.execute(
        """
        INSERT INTO text_corrections (original_text, corrected_text, correction_type)
        VALUES ($1, $2, $3)
        ON CONFLICT (original_text, corrected_text)
        DO UPDATE SET use_count = text_corrections.use_count + 1,
                      updated_at = NOW()
    """,
        original,
        corrected,
        correction_type,
    )


async def load_text_corrections() -> list[dict]:
    """Load all active text corrections (excluding entity_dismissal type)."""
    pool = await get_pool()
    rows = await pool.fetch(
        """
        SELECT original_text, corrected_text, correction_type, case_sensitive
        FROM text_corrections
        WHERE active = TRUE AND correction_type != 'entity_dismissal'
        ORDER BY length(original_text) DESC
    """
    )
    return [dict(r) for r in rows]



# --- App settings ---


async def get_setting(key: str, default: str = "") -> str:
    pool = await get_pool()
    row = await pool.fetchrow(
        "SELECT value FROM app_settings WHERE key = $1", key
    )
    return row["value"] if row else default


async def set_setting(key: str, value: str):
    pool = await get_pool()
    await pool.execute(
        """
        INSERT INTO app_settings (key, value, updated_at)
        VALUES ($1, $2, NOW())
        ON CONFLICT (key) DO UPDATE SET value = $2, updated_at = NOW()
    """,
        key,
        value,
    )


async def get_all_settings() -> dict:
    pool = await get_pool()
    rows = await pool.fetch("SELECT key, value FROM app_settings ORDER BY key")
    return {r["key"]: r["value"] for r in rows}



# --- Ingest uploads ---


async def create_ingest_upload(filename: str, file_size: int) -> int:
    pool = await get_pool()
    row = await pool.fetchrow(
        """
        INSERT INTO ingest_uploads (filename, file_size, status)
        VALUES ($1, $2, 'uploading')
        RETURNING id
    """,
        filename,
        file_size,
    )
    return row["id"]


async def mark_ingest_success(
    upload_id: int, transcript_id: int = None, review_url: str = None
):
    pool = await get_pool()
    await pool.execute(
        """
        UPDATE ingest_uploads
        SET status = 'success', transcript_id = $2, review_url = $3,
            completed_at = NOW()
        WHERE id = $1
    """,
        upload_id,
        transcript_id,
        review_url,
    )


async def mark_ingest_failed(upload_id: int, error: str):
    pool = await get_pool()
    await pool.execute(
        """
        UPDATE ingest_uploads
        SET status = 'error', error_message = $2, completed_at = NOW()
        WHERE id = $1
    """,
        upload_id,
        error,
    )


async def list_ingest_uploads(limit: int = 100) -> list[dict]:
    pool = await get_pool()
    rows = await pool.fetch(
        """
        SELECT id, filename, file_size, status, error_message,
               transcript_id, review_url, created_at, completed_at
        FROM ingest_uploads
        ORDER BY created_at DESC
        LIMIT $1
    """,
        limit,
    )
    return [dict(r) for r in rows]


async def delete_ingest_uploads(ids: list[int]):
    pool = await get_pool()
    await pool.execute(
        "DELETE FROM ingest_uploads WHERE id = ANY($1::int[])", ids
    )


async def clear_ingest_history():
    pool = await get_pool()
    await pool.execute("DELETE FROM ingest_uploads")


# --- Processed documents ---


async def save_processed_document(
    transcript_id: int,
    document_markdown: str,
    analysis_json: dict | None = None,
    context_summary: str | None = None,
    metadata: dict | None = None,
) -> dict:
    """Save a new version of a processed document."""
    pool = await get_pool()
    # Get next version number
    row = await pool.fetchrow(
        "SELECT COALESCE(MAX(version), 0) + 1 AS next_version "
        "FROM processed_documents WHERE transcript_id = $1",
        transcript_id,
    )
    version = row["next_version"]
    row = await pool.fetchrow(
        """
        INSERT INTO processed_documents
            (transcript_id, version, document_markdown, analysis_json,
             context_summary, metadata)
        VALUES ($1, $2, $3, $4::jsonb, $5, $6::jsonb)
        RETURNING id, version, created_at
    """,
        transcript_id,
        version,
        document_markdown,
        json.dumps(analysis_json) if analysis_json else None,
        context_summary,
        json.dumps(metadata) if metadata else None,
    )
    return dict(row)


async def get_processed_document(doc_id: int) -> dict | None:
    """Get a processed document by its ID."""
    pool = await get_pool()
    row = await pool.fetchrow(
        "SELECT * FROM processed_documents WHERE id = $1", doc_id
    )
    return dict(row) if row else None


async def get_latest_processed_document(transcript_id: int) -> dict | None:
    """Get the latest version of a processed document for a transcript."""
    pool = await get_pool()
    row = await pool.fetchrow(
        "SELECT * FROM processed_documents "
        "WHERE transcript_id = $1 ORDER BY version DESC LIMIT 1",
        transcript_id,
    )
    return dict(row) if row else None


async def update_processed_document(doc_id: int, document_markdown: str) -> dict | None:
    """Update the markdown of a processed document."""
    pool = await get_pool()
    row = await pool.fetchrow(
        """
        UPDATE processed_documents
        SET document_markdown = $2, updated_at = NOW()
        WHERE id = $1
        RETURNING id, version, updated_at
    """,
        doc_id,
        document_markdown,
    )
    return dict(row) if row else None


async def mark_document_ingested(doc_id: int) -> dict | None:
    """Mark a document as ingested into LightRAG."""
    pool = await get_pool()
    row = await pool.fetchrow(
        """
        UPDATE processed_documents
        SET lightrag_ingested = TRUE, lightrag_ingested_at = NOW(), updated_at = NOW()
        WHERE id = $1
        RETURNING id, lightrag_ingested_at
    """,
        doc_id,
    )
    return dict(row) if row else None


async def get_document_versions(transcript_id: int) -> list[dict]:
    """Get all versions of processed documents for a transcript."""
    pool = await get_pool()
    rows = await pool.fetch(
        "SELECT id, version, lightrag_ingested, lightrag_ingested_at, "
        "created_at, updated_at "
        "FROM processed_documents WHERE transcript_id = $1 ORDER BY version DESC",
        transcript_id,
    )
    return [dict(r) for r in rows]


async def load_entity_dismissals() -> list[str]:
    """Load dismissed text patterns to filter from entity detection."""
    pool = await get_pool()
    rows = await pool.fetch(
        """
        SELECT original_text
        FROM text_corrections
        WHERE active = TRUE AND correction_type = 'entity_dismissal'
    """
    )
    return [r["original_text"] for r in rows]


# ═══════════════════════════════════════════════════════════════════
# Skeleton Sync: org_units, entity_relationships, role_assignments,
#                static_entities, initiatives
# ═══════════════════════════════════════════════════════════════════

# ── Org Units ───────────────────────────────────────────────────────

async def list_org_units():
    pool = await get_pool()
    rows = await pool.fetch(
        "SELECT o.*, p.name AS parent_name "
        "FROM org_units o LEFT JOIN org_units p ON o.parent_id = p.id "
        "ORDER BY o.entity_type, o.name"
    )
    return [dict(r) for r in rows]


async def create_org_unit(name, entity_type, parent_id=None, description="",
                          properties=None, aliases=None):
    pool = await get_pool()
    row = await pool.fetchrow(
        """INSERT INTO org_units (name, entity_type, parent_id, description, properties, aliases)
           VALUES ($1, $2, $3, $4, $5, $6) RETURNING id""",
        name, entity_type, parent_id, description,
        json.dumps(properties or {}), aliases or [],
    )
    return row["id"]


async def update_org_unit(org_id, **kwargs):
    pool = await get_pool()
    sets = []
    vals = []
    idx = 1
    for key in ("name", "entity_type", "parent_id", "description", "status"):
        if key in kwargs:
            idx += 1
            sets.append(f"{key} = ${idx}")
            vals.append(kwargs[key])
    if "properties" in kwargs:
        idx += 1
        sets.append(f"properties = ${idx}")
        vals.append(json.dumps(kwargs["properties"]))
    if "aliases" in kwargs:
        idx += 1
        sets.append(f"aliases = ${idx}")
        vals.append(kwargs["aliases"])
    if not sets:
        return
    await pool.execute(
        f"UPDATE org_units SET {', '.join(sets)} WHERE id = $1",
        org_id, *vals,
    )


async def delete_org_unit(org_id):
    pool = await get_pool()
    await pool.execute("DELETE FROM org_units WHERE id = $1", org_id)


# ── Entity Relationships ───────────────────────────────────────────

async def list_entity_relationships():
    pool = await get_pool()
    rows = await pool.fetch(
        "SELECT * FROM entity_relationships WHERE status = 'active' ORDER BY id"
    )
    return [dict(r) for r in rows]


async def create_entity_relationship(source_type, source_id, relationship_type,
                                      target_type, target_id, context="",
                                      bidirectional=False):
    pool = await get_pool()
    row = await pool.fetchrow(
        """INSERT INTO entity_relationships
               (source_type, source_id, relationship_type, target_type, target_id,
                context, bidirectional)
           VALUES ($1, $2, $3, $4, $5, $6, $7) RETURNING id""",
        source_type, source_id, relationship_type,
        target_type, target_id, context, bidirectional,
    )
    return row["id"]


async def delete_entity_relationship(rel_id):
    pool = await get_pool()
    await pool.execute("DELETE FROM entity_relationships WHERE id = $1", rel_id)


# ── Role Assignments ───────────────────────────────────────────────

async def list_role_assignments(person_id=None):
    pool = await get_pool()
    if person_id:
        rows = await pool.fetch(
            """SELECT ra.*, p.canonical_name AS person_name, o.name AS org_name
               FROM role_assignments ra
               LEFT JOIN persons p ON ra.person_id = p.id
               LEFT JOIN org_units o ON ra.org_unit_id = o.id
               WHERE ra.person_id = $1 ORDER BY ra.id""",
            person_id,
        )
    else:
        rows = await pool.fetch(
            """SELECT ra.*, p.canonical_name AS person_name, o.name AS org_name
               FROM role_assignments ra
               LEFT JOIN persons p ON ra.person_id = p.id
               LEFT JOIN org_units o ON ra.org_unit_id = o.id
               ORDER BY p.canonical_name, ra.id"""
        )
    return [dict(r) for r in rows]


async def create_role_assignment(person_id, role_name, org_unit_id=None,
                                  scope="", role_entity_name=None,
                                  start_date=None, end_date=None):
    pool = await get_pool()
    row = await pool.fetchrow(
        """INSERT INTO role_assignments
               (person_id, role_name, role_entity_name, scope,
                org_unit_id, start_date, end_date)
           VALUES ($1, $2, $3, $4, $5, $6, $7) RETURNING id""",
        person_id, role_name, role_entity_name, scope,
        org_unit_id, start_date, end_date,
    )
    return row["id"]


async def update_role_assignment(ra_id, **kwargs):
    pool = await get_pool()
    sets = []
    vals = []
    idx = 1
    for key in ("person_id", "role_name", "role_entity_name", "scope",
                "org_unit_id", "status", "start_date", "end_date"):
        if key in kwargs:
            idx += 1
            sets.append(f"{key} = ${idx}")
            vals.append(kwargs[key])
    if not sets:
        return
    await pool.execute(
        f"UPDATE role_assignments SET {', '.join(sets)} WHERE id = $1",
        ra_id, *vals,
    )


async def delete_role_assignment(ra_id):
    pool = await get_pool()
    await pool.execute("DELETE FROM role_assignments WHERE id = $1", ra_id)


# ── Static Entities ────────────────────────────────────────────────

async def list_static_entities():
    pool = await get_pool()
    rows = await pool.fetch(
        "SELECT * FROM static_entities ORDER BY entity_type, sort_order, name"
    )
    return [dict(r) for r in rows]


async def create_static_entity(name, entity_type, description="",
                                properties=None, aliases=None):
    pool = await get_pool()
    row = await pool.fetchrow(
        """INSERT INTO static_entities (name, entity_type, description, properties, aliases)
           VALUES ($1, $2, $3, $4, $5) RETURNING id""",
        name, entity_type, description,
        json.dumps(properties or {}), aliases or [],
    )
    return row["id"]


async def update_static_entity(entity_id, **kwargs):
    pool = await get_pool()
    sets = []
    vals = []
    idx = 1
    for key in ("name", "entity_type", "description", "sort_order", "status"):
        if key in kwargs:
            idx += 1
            sets.append(f"{key} = ${idx}")
            vals.append(kwargs[key])
    if "properties" in kwargs:
        idx += 1
        sets.append(f"properties = ${idx}")
        vals.append(json.dumps(kwargs["properties"]))
    if "aliases" in kwargs:
        idx += 1
        sets.append(f"aliases = ${idx}")
        vals.append(kwargs["aliases"])
    if not sets:
        return
    await pool.execute(
        f"UPDATE static_entities SET {', '.join(sets)} WHERE id = $1",
        entity_id, *vals,
    )


async def delete_static_entity(entity_id):
    pool = await get_pool()
    await pool.execute("DELETE FROM static_entities WHERE id = $1", entity_id)


# ── Initiatives ────────────────────────────────────────────────────

async def list_initiatives():
    pool = await get_pool()
    rows = await pool.fetch(
        """SELECT i.*, p.canonical_name AS owner_name
           FROM initiatives i
           LEFT JOIN persons p ON i.owner_person_id = p.id
           ORDER BY i.name"""
    )
    return [dict(r) for r in rows]


async def create_initiative(name, initiative_type, description="",
                             properties=None, aliases=None, owner_person_id=None):
    pool = await get_pool()
    row = await pool.fetchrow(
        """INSERT INTO initiatives
               (name, initiative_type, description, properties, aliases, owner_person_id)
           VALUES ($1, $2, $3, $4, $5, $6) RETURNING id""",
        name, initiative_type, description,
        json.dumps(properties or {}), aliases or [],
        owner_person_id,
    )
    return row["id"]


async def update_initiative(init_id, **kwargs):
    pool = await get_pool()
    sets = []
    vals = []
    idx = 1
    for key in ("name", "initiative_type", "description", "status", "owner_person_id"):
        if key in kwargs:
            idx += 1
            sets.append(f"{key} = ${idx}")
            vals.append(kwargs[key])
    if "properties" in kwargs:
        idx += 1
        sets.append(f"properties = ${idx}")
        vals.append(json.dumps(kwargs["properties"]))
    if "aliases" in kwargs:
        idx += 1
        sets.append(f"aliases = ${idx}")
        vals.append(kwargs["aliases"])
    if not sets:
        return
    await pool.execute(
        f"UPDATE initiatives SET {', '.join(sets)} WHERE id = $1",
        init_id, *vals,
    )


async def delete_initiative(init_id):
    pool = await get_pool()
    await pool.execute("DELETE FROM initiatives WHERE id = $1", init_id)
