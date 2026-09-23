#!/usr/bin/env python3
"""
Import NocoDB CSV exports into the diary processor database.

Reads 4 CSV files exported from NocoDB and applies parameterized INSERT
statements (via asyncpg) to populate the persons, person_variations,
terms, and term_variations tables. Values are always bound as query
parameters, never interpolated into SQL text.

Usage:
    # Apply directly to the database (reads DATABASE_URL from the
    # environment; defaults to postgresql://diary:diary@localhost:5432/diary_processor):
    python import_nocodb.py /path/to/csv/dir

    # Preview the statements and their bound params without touching the database:
    python import_nocodb.py /path/to/csv/dir --dry-run

The CSV directory should contain NocoDB exports matching these patterns:
    *team_roster*.csv
    *person_variations*.csv
    *terms_roster*.csv
    *term_variations*.csv
"""

import asyncio
import csv
import io
import os
import sys
from dataclasses import dataclass
from pathlib import Path

import asyncpg

DATABASE_URL = os.getenv(
    "DATABASE_URL",
    "postgresql://diary:diary@localhost:5432/diary_processor",
)


@dataclass
class SqlStatement:
    """A parameterized statement: `query` uses asyncpg's $1, $2, ...
    placeholders; `params` are bound positionally by asyncpg. CSV values
    are never spliced into `query` text, so they cannot break out of a
    literal or inject additional statements."""

    query: str
    params: tuple


def find_csv(directory: Path, pattern: str) -> Path:
    """Find a CSV file matching a pattern in the directory."""
    matches = sorted(directory.glob(f"*{pattern}*.csv"))
    if not matches:
        print(f"ERROR: No CSV matching '*{pattern}*.csv' in {directory}", file=sys.stderr)
        sys.exit(1)
    if len(matches) > 1:
        print(f"WARNING: Multiple matches for '{pattern}', using newest: {matches[-1].name}", file=sys.stderr)
    return matches[-1]


def parse_team_roster(path: Path) -> list[dict]:
    """Parse team_roster CSV (NocoDB double-encodes rows with commas)."""
    persons = []
    with open(path, "r", encoding="utf-8-sig") as f:
        reader = csv.reader(f)
        header = next(reader)
        for row in reader:
            if len(row) == 1:
                # Double-encoded: entire row is one quoted field
                inner = next(csv.reader(io.StringIO(row[0])))
                persons.append(dict(zip(header, inner)))
            else:
                persons.append(dict(zip(header, row)))
    return persons


def parse_csv(path: Path) -> list[dict]:
    """Parse a normal CSV file."""
    with open(path, "r", encoding="utf-8-sig") as f:
        return list(csv.DictReader(f))


def _clean(value, default: str = "") -> str:
    """Normalize a raw CSV cell to a stripped string, applying `default`
    for missing/empty values. No SQL escaping needed: values are only
    ever bound as query parameters, never interpolated into SQL text."""
    value = (value or "").strip()
    return value or default


def build_statements(csv_dir: Path) -> list[SqlStatement]:
    """Parse NocoDB CSV exports into a list of parameterized statements."""
    # Find CSV files
    team_roster_path = find_csv(csv_dir, "team_roster")
    person_vars_path = find_csv(csv_dir, "person_variations")
    terms_roster_path = find_csv(csv_dir, "terms_roster")
    term_vars_path = find_csv(csv_dir, "term_variations")

    print(f"Reading: {team_roster_path.name}", file=sys.stderr)
    print(f"Reading: {person_vars_path.name}", file=sys.stderr)
    print(f"Reading: {terms_roster_path.name}", file=sys.stderr)
    print(f"Reading: {term_vars_path.name}", file=sys.stderr)

    # Parse CSVs
    persons = parse_team_roster(team_roster_path)
    person_vars = parse_csv(person_vars_path)
    terms = parse_csv(terms_roster_path)
    term_vars = parse_csv(term_vars_path)

    statements: list[SqlStatement] = []

    # --- Persons ---
    for p in persons:
        canonical = _clean(p.get("canonical_name"))
        if not canonical:
            continue
        first = _clean(p.get("first_name"))
        last = _clean(p.get("last_name"))
        role = _clean(p.get("role"))
        dept = _clean(p.get("department"))
        company = _clean(p.get("company"))
        status = _clean(p.get("status"), "active")
        statements.append(
            SqlStatement(
                "INSERT INTO persons (canonical_name, first_name, last_name, role, department, company, status) "
                "VALUES ($1, $2, $3, $4, $5, $6, $7) "
                "ON CONFLICT (canonical_name) DO UPDATE SET "
                "first_name=EXCLUDED.first_name, last_name=EXCLUDED.last_name, "
                "role=EXCLUDED.role, department=EXCLUDED.department, "
                "company=EXCLUDED.company, updated_at=NOW()",
                (canonical, first, last, role, dept, company, status),
            )
        )

    # --- Person variations (chunked by parent variation count) ---
    var_idx = 0
    total_person_vars = 0
    for p in persons:
        canonical = _clean(p.get("canonical_name"))
        if not canonical:
            continue
        count = int(p.get("person_variations", 0))
        chunk = person_vars[var_idx:var_idx + count]
        var_idx += count
        total_person_vars += len(chunk)

        for v in chunk:
            variation = _clean(v.get("variation"))
            if not variation:
                continue
            var_type = _clean(v.get("variation_type"), "asr_correction")
            confidence = _clean(v.get("confidence"), "high")
            approved = v.get("approved", "1") == "1"
            statements.append(
                SqlStatement(
                    "INSERT INTO person_variations (person_id, variation, variation_type, confidence, approved) "
                    "VALUES ((SELECT id FROM persons WHERE canonical_name=$1), $2, $3, $4, $5) "
                    "ON CONFLICT (person_id, variation) DO NOTHING",
                    (canonical, variation, var_type, confidence, approved),
                )
            )

    if var_idx != len(person_vars):
        print(
            f"WARNING: Person variation count mismatch! "
            f"Assigned {var_idx}, total in CSV {len(person_vars)}",
            file=sys.stderr,
        )
    else:
        print(
            f"OK: {len(persons)} persons, {total_person_vars} person variations",
            file=sys.stderr,
        )

    # --- Terms ---
    for t in terms:
        canonical = _clean(t.get("canonical_term"))
        if not canonical:
            continue
        category = _clean(t.get("category"), "term")
        context = _clean(t.get("context"))
        status = _clean(t.get("status"), "active")
        statements.append(
            SqlStatement(
                "INSERT INTO terms (canonical_term, category, context, status) "
                "VALUES ($1, $2, $3, $4) "
                "ON CONFLICT (canonical_term) DO UPDATE SET "
                "category=EXCLUDED.category, context=EXCLUDED.context, updated_at=NOW()",
                (canonical, category, context, status),
            )
        )

    # --- Term variations (chunked by parent variation count) ---
    var_idx = 0
    total_term_vars = 0
    for t in terms:
        canonical = _clean(t.get("canonical_term"))
        if not canonical:
            continue
        count = int(t.get("term_variations", 0))
        chunk = term_vars[var_idx:var_idx + count]
        var_idx += count
        total_term_vars += len(chunk)

        for v in chunk:
            variation = _clean(v.get("variation"))
            if not variation:
                continue
            approved = v.get("approved", "1") == "1"
            statements.append(
                SqlStatement(
                    "INSERT INTO term_variations (term_id, variation, approved) "
                    "VALUES ((SELECT id FROM terms WHERE canonical_term=$1), $2, $3) "
                    "ON CONFLICT (term_id, variation) DO NOTHING",
                    (canonical, variation, approved),
                )
            )

    if var_idx != len(term_vars):
        print(
            f"WARNING: Term variation count mismatch! "
            f"Assigned {var_idx}, total in CSV {len(term_vars)}",
            file=sys.stderr,
        )
    else:
        print(
            f"OK: {len(terms)} terms, {total_term_vars} term variations",
            file=sys.stderr,
        )

    return statements


async def apply_statements(statements: list[SqlStatement], database_url: str = DATABASE_URL) -> None:
    """Apply statements to Postgres in a single transaction, positionally
    binding each statement's params via asyncpg (no string interpolation)."""
    conn = await asyncpg.connect(database_url)
    try:
        async with conn.transaction():
            for stmt in statements:
                await conn.execute(stmt.query, *stmt.params)
    finally:
        await conn.close()


def main() -> None:
    if len(sys.argv) < 2:
        print(f"Usage: {sys.argv[0]} <csv_directory> [--dry-run]", file=sys.stderr)
        print(f"Example: {sys.argv[0]} ./import/", file=sys.stderr)
        sys.exit(1)

    csv_dir = Path(sys.argv[1])
    if not csv_dir.is_dir():
        print(f"ERROR: {csv_dir} is not a directory", file=sys.stderr)
        sys.exit(1)

    dry_run = "--dry-run" in sys.argv[2:]
    statements = build_statements(csv_dir)

    if dry_run:
        for stmt in statements:
            print(f"{stmt.query} -- params={stmt.params!r}")
        print(f"-- {len(statements)} statements (dry run, nothing applied)", file=sys.stderr)
        return

    asyncio.run(apply_statements(statements))
    print(f"Applied {len(statements)} statements to {DATABASE_URL}", file=sys.stderr)


if __name__ == "__main__":
    main()
