"""Tests for `import_nocodb` SQL generation (SEC-5).

The tool used to build INSERT statements via f-string interpolation of a
hand-rolled `sql_escape()`. These tests pin down the replacement:
`build_statements()` returns statements that use asyncpg's `$1, $2, ...`
placeholders, with values passed only as bound parameters, never spliced
into the query text.
"""

import csv
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from import_nocodb import SqlStatement, apply_statements, build_statements


def _write_csv(path, header, rows):
    with open(path, "w", newline="", encoding="utf-8") as f:
        writer = csv.writer(f)
        writer.writerow(header)
        writer.writerows(rows)


def _make_csv_dir(tmp_path, *, canonical_name):
    _write_csv(
        tmp_path / "team_roster.csv",
        ["canonical_name", "first_name", "last_name", "role", "department", "company", "status", "person_variations"],
        [[canonical_name, "First", "Last", "role", "dept", "co", "active", "0"]],
    )
    _write_csv(tmp_path / "person_variations.csv", ["variation", "variation_type", "confidence", "approved"], [])
    _write_csv(
        tmp_path / "terms_roster.csv",
        ["canonical_term", "category", "context", "status", "term_variations"],
        [],
    )
    _write_csv(tmp_path / "term_variations.csv", ["variation", "approved"], [])
    return tmp_path


def test_persons_insert_uses_placeholders_not_interpolated_value(tmp_path):
    malicious = "O'Brien'; DROP TABLE persons;--"
    csv_dir = _make_csv_dir(tmp_path, canonical_name=malicious)

    statements = build_statements(csv_dir)

    persons_stmt = next(s for s in statements if s.query.startswith("INSERT INTO persons"))
    assert malicious not in persons_stmt.query
    assert "$1" in persons_stmt.query
    assert persons_stmt.params[0] == malicious


class _FakeTransaction:
    async def __aenter__(self):
        return self

    async def __aexit__(self, *exc_info):
        return False


class _FakeConnection:
    def __init__(self):
        self.executed: list[tuple] = []
        self.closed = False

    def transaction(self):
        return _FakeTransaction()

    async def execute(self, query, *params):
        self.executed.append((query, params))

    async def close(self):
        self.closed = True


def test_person_variation_insert_uses_placeholders_for_canonical_and_variation(tmp_path):
    malicious_variation = "x'); DELETE FROM persons;--"
    _write_csv(
        tmp_path / "team_roster.csv",
        ["canonical_name", "first_name", "last_name", "role", "department", "company", "status", "person_variations"],
        [["Alice", "Alice", "A", "role", "dept", "co", "active", "1"]],
    )
    _write_csv(
        tmp_path / "person_variations.csv",
        ["variation", "variation_type", "confidence", "approved"],
        [[malicious_variation, "asr_correction", "high", "1"]],
    )
    _write_csv(
        tmp_path / "terms_roster.csv",
        ["canonical_term", "category", "context", "status", "term_variations"],
        [],
    )
    _write_csv(tmp_path / "term_variations.csv", ["variation", "approved"], [])

    statements = build_statements(tmp_path)

    var_stmt = next(s for s in statements if s.query.startswith("INSERT INTO person_variations"))
    assert malicious_variation not in var_stmt.query
    assert "Alice" not in var_stmt.query
    assert var_stmt.params == ("Alice", malicious_variation, "asr_correction", "high", True)


async def test_apply_statements_executes_each_with_bound_params(monkeypatch):
    fake_conn = _FakeConnection()

    async def fake_connect(database_url):
        assert database_url == "postgresql://fake/db"
        return fake_conn

    monkeypatch.setattr("import_nocodb.asyncpg.connect", fake_connect)

    statements = [
        SqlStatement("INSERT INTO persons (canonical_name) VALUES ($1)", ("Alice",)),
        SqlStatement("INSERT INTO terms (canonical_term) VALUES ($1)", ("term",)),
    ]

    await apply_statements(statements, database_url="postgresql://fake/db")

    assert fake_conn.executed == [
        ("INSERT INTO persons (canonical_name) VALUES ($1)", ("Alice",)),
        ("INSERT INTO terms (canonical_term) VALUES ($1)", ("term",)),
    ]
    assert fake_conn.closed is True
