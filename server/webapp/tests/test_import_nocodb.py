"""Tests for `import_nocodb` SQL generation (SEC-5).

The tool used to build INSERT statements via f-string interpolation of a
hand-rolled `sql_escape()`. These tests pin down the replacement:
`build_statements()` returns statements that use asyncpg's `$1, $2, ...`
placeholders, with values passed only as bound parameters, never spliced
into the query text.
"""

import csv
import importlib
import os
import sys

import pytest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from import_nocodb import SqlStatement, apply_statements, build_statements


def _write_csv(path, header, rows):
    with open(path, "w", newline="", encoding="utf-8") as f:
        writer = csv.writer(f)
        writer.writerow(header)
        writer.writerows(rows)


PERSON_HEADER = ["canonical_name", "first_name", "last_name", "role", "department", "company", "status", "person_variations"]


def _make_csv_dir(tmp_path, *, persons, person_variations=(), terms=(), term_variations=()):
    _write_csv(tmp_path / "team_roster.csv", PERSON_HEADER, persons)
    _write_csv(
        tmp_path / "person_variations.csv",
        ["variation", "variation_type", "confidence", "approved"],
        person_variations,
    )
    _write_csv(
        tmp_path / "terms_roster.csv",
        ["canonical_term", "category", "context", "status", "term_variations"],
        terms,
    )
    _write_csv(tmp_path / "term_variations.csv", ["variation", "approved"], term_variations)
    return tmp_path


def test_missing_database_url_fails_loud(monkeypatch, capsys):
    """SEC-4: without DATABASE_URL the tool must not fall back to the old
    guessable diary:diary credential. It exits with a clear error instead,
    like its other operator-facing failures (e.g. missing CSV files)."""
    import import_nocodb

    monkeypatch.delenv("DATABASE_URL", raising=False)
    with pytest.raises(SystemExit) as excinfo:
        importlib.reload(import_nocodb)
    assert excinfo.value.code == 1
    assert "DATABASE_URL is not set" in capsys.readouterr().err

    # Leave the module in a sane state (conftest's URL) for later tests.
    monkeypatch.undo()
    importlib.reload(import_nocodb)


def test_persons_insert_uses_placeholders_not_interpolated_value(tmp_path):
    malicious = "O'Brien'; DROP TABLE persons;--"
    csv_dir = _make_csv_dir(tmp_path, persons=[[malicious, "First", "Last", "role", "dept", "co", "active", "0"]])

    statements = build_statements(csv_dir)

    persons_stmt = next(s for s in statements if s.query.startswith("INSERT INTO persons"))
    assert malicious not in persons_stmt.query
    assert "$1" in persons_stmt.query
    assert persons_stmt.params[0] == malicious


def test_person_variation_insert_uses_placeholders_for_canonical_and_variation(tmp_path):
    malicious_variation = "x'); DELETE FROM persons;--"
    csv_dir = _make_csv_dir(
        tmp_path,
        persons=[["Alice", "Alice", "A", "role", "dept", "co", "active", "1"]],
        person_variations=[[malicious_variation, "asr_correction", "high", "1"]],
    )

    statements = build_statements(csv_dir)

    var_stmt = next(s for s in statements if s.query.startswith("INSERT INTO person_variations"))
    assert malicious_variation not in var_stmt.query
    assert "Alice" not in var_stmt.query
    assert var_stmt.params == ("Alice", malicious_variation, "asr_correction", "high", True)


def test_terms_insert_uses_placeholders_not_interpolated_value(tmp_path):
    malicious = "Kubernetes'); DROP TABLE terms;--"
    csv_dir = _make_csv_dir(
        tmp_path,
        persons=[["Alice", "Alice", "A", "role", "dept", "co", "active", "0"]],
        terms=[[malicious, "tech", "cluster orchestration", "active", "0"]],
    )

    statements = build_statements(csv_dir)

    terms_stmt = next(s for s in statements if s.query.startswith("INSERT INTO terms"))
    assert malicious not in terms_stmt.query
    assert "$1" in terms_stmt.query
    assert terms_stmt.params == (malicious, "tech", "cluster orchestration", "active")


def test_term_variation_insert_uses_placeholders_for_canonical_and_variation(tmp_path):
    malicious_variation = "k8s'); DELETE FROM terms;--"
    csv_dir = _make_csv_dir(
        tmp_path,
        persons=[["Alice", "Alice", "A", "role", "dept", "co", "active", "0"]],
        terms=[["Kubernetes", "tech", "cluster orchestration", "active", "1"]],
        term_variations=[[malicious_variation, "1"]],
    )

    statements = build_statements(csv_dir)

    var_stmt = next(s for s in statements if s.query.startswith("INSERT INTO term_variations"))
    assert malicious_variation not in var_stmt.query
    assert "Kubernetes" not in var_stmt.query
    assert var_stmt.params == ("Kubernetes", malicious_variation, True)


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
