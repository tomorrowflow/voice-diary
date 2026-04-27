#!/usr/bin/env python3
"""
Import NocoDB CSV exports into the diary processor database.

Reads 4 CSV files exported from NocoDB and generates SQL to populate
the persons, person_variations, terms, and term_variations tables.

Usage:
    # Generate SQL to stdout:
    python import_nocodb.py /path/to/csv/dir

    # Apply directly to database:
    python import_nocodb.py /path/to/csv/dir | psql -h localhost -U diary diary_processor

    # Or pipe to a file:
    python import_nocodb.py /path/to/csv/dir > seed_full.sql

The CSV directory should contain NocoDB exports matching these patterns:
    *team_roster*.csv
    *person_variations*.csv
    *terms_roster*.csv
    *term_variations*.csv
"""

import csv
import io
import sys
from pathlib import Path


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


def sql_escape(value: str) -> str:
    """Escape a string for SQL single-quoted literal."""
    return value.replace("'", "''").strip()


def generate_sql(csv_dir: Path) -> str:
    """Generate SQL INSERT statements from NocoDB CSV exports."""
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

    lines = []
    lines.append("-- Auto-generated from NocoDB export")
    lines.append("-- Run: python import_nocodb.py /path/to/csvs | psql ...\n")
    lines.append("BEGIN;\n")

    # --- Persons ---
    lines.append("-- === Persons ===")
    for p in persons:
        canonical = sql_escape(p.get("canonical_name", ""))
        first = sql_escape(p.get("first_name", ""))
        last = sql_escape(p.get("last_name", ""))
        role = sql_escape(p.get("role", ""))
        dept = sql_escape(p.get("department", ""))
        company = sql_escape(p.get("company", ""))
        status = sql_escape(p.get("status", "active"))
        if not canonical:
            continue
        lines.append(
            f"INSERT INTO persons (canonical_name, first_name, last_name, role, department, company, status) "
            f"VALUES ('{canonical}', '{first}', '{last}', '{role}', '{dept}', '{company}', '{status}') "
            f"ON CONFLICT (canonical_name) DO UPDATE SET "
            f"first_name=EXCLUDED.first_name, last_name=EXCLUDED.last_name, "
            f"role=EXCLUDED.role, department=EXCLUDED.department, "
            f"company=EXCLUDED.company, updated_at=NOW();"
        )
    lines.append("")

    # --- Person variations (chunked by parent variation count) ---
    lines.append("-- === Person Variations ===")
    var_idx = 0
    total_person_vars = 0
    for p in persons:
        canonical = sql_escape(p.get("canonical_name", ""))
        if not canonical:
            continue
        count = int(p.get("person_variations", 0))
        chunk = person_vars[var_idx:var_idx + count]
        var_idx += count
        total_person_vars += len(chunk)

        for v in chunk:
            variation = sql_escape(v.get("variation", ""))
            var_type = sql_escape(v.get("variation_type", "asr_correction"))
            confidence = sql_escape(v.get("confidence", "high"))
            approved = v.get("approved", "1") == "1"
            if not variation:
                continue
            lines.append(
                f"INSERT INTO person_variations (person_id, variation, variation_type, confidence, approved) "
                f"VALUES ((SELECT id FROM persons WHERE canonical_name='{canonical}'), "
                f"'{variation}', '{var_type}', '{confidence}', {approved}) "
                f"ON CONFLICT (person_id, variation) DO NOTHING;"
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
    lines.append("")

    # --- Terms ---
    lines.append("-- === Terms ===")
    for t in terms:
        canonical = sql_escape(t.get("canonical_term", ""))
        category = sql_escape(t.get("category", "term"))
        context = sql_escape(t.get("context", ""))
        status = sql_escape(t.get("status", "active"))
        if not canonical:
            continue
        lines.append(
            f"INSERT INTO terms (canonical_term, category, context, status) "
            f"VALUES ('{canonical}', '{category}', '{context}', '{status}') "
            f"ON CONFLICT (canonical_term) DO UPDATE SET "
            f"category=EXCLUDED.category, context=EXCLUDED.context, updated_at=NOW();"
        )
    lines.append("")

    # --- Term variations (chunked by parent variation count) ---
    lines.append("-- === Term Variations ===")
    var_idx = 0
    total_term_vars = 0
    for t in terms:
        canonical = sql_escape(t.get("canonical_term", ""))
        if not canonical:
            continue
        count = int(t.get("term_variations", 0))
        chunk = term_vars[var_idx:var_idx + count]
        var_idx += count
        total_term_vars += len(chunk)

        for v in chunk:
            variation = sql_escape(v.get("variation", ""))
            approved = v.get("approved", "1") == "1"
            if not variation:
                continue
            lines.append(
                f"INSERT INTO term_variations (term_id, variation, approved) "
                f"VALUES ((SELECT id FROM terms WHERE canonical_term='{canonical}'), "
                f"'{variation}', {approved}) "
                f"ON CONFLICT (term_id, variation) DO NOTHING;"
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
    lines.append("")

    lines.append("COMMIT;")
    return "\n".join(lines)


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print(f"Usage: {sys.argv[0]} <csv_directory>", file=sys.stderr)
        print(f"Example: {sys.argv[0]} ./import/", file=sys.stderr)
        sys.exit(1)

    csv_dir = Path(sys.argv[1])
    if not csv_dir.is_dir():
        print(f"ERROR: {csv_dir} is not a directory", file=sys.stderr)
        sys.exit(1)

    sql = generate_sql(csv_dir)
    print(sql)
