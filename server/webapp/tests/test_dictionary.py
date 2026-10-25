"""Tests for `dictionary.DictionarySnapshot` — the single Dictionary value both
transcript pipelines hand to `correction.correct_and_detect_entities`.

No `db.*` loader is monkeypatched: the snapshot is built from fake data
directly, and the loader runs against a fake connection pool so the real `db`
queries' result shapes (including how dismissals are stored) are exercised.

Run inside the webapp container so deps match prod. From `server/`, with the
`.env` stub from DEVELOPMENT.md §7.4:

    docker compose -p vd-test run --rm --no-deps -e PYTHONDONTWRITEBYTECODE=1 -v ..:/repo -w /repo/server webapp pytest webapp/tests/test_dictionary.py -q -p no:cacheprovider
"""

from __future__ import annotations

import asyncio

import pytest

import correction
import db
import dictionary
import transcript_corrector
from dictionary import DictionarySnapshot


def _run(coro):
    return asyncio.run(coro)


PERSONS = [
    {
        "id": 1, "canonical_name": "Anna Schmidt", "first_name": "Anna",
        "last_name": "Schmidt", "role": "", "department": "", "company": "",
        "context": "", "variations": [],
    }
]
TERMS = [
    {"id": 1, "canonical_term": "Berlin", "category": "term", "context": "", "variations": []},
    {"id": 2, "canonical_term": "Baumarkt", "category": "term", "context": "", "variations": []},
]


def test_snapshot_holds_fake_data_and_matches_dismissals_case_insensitively():
    snapshot = DictionarySnapshot(
        persons=PERSONS,
        terms=TERMS,
        text_corrections=[{"original_text": "Berlim", "corrected_text": "Berlin"}],
        dismissals=["Baumarkt"],
    )

    assert snapshot.persons == PERSONS
    assert snapshot.terms == TERMS
    assert snapshot.text_corrections == [{"original_text": "Berlim", "corrected_text": "Berlin"}]
    assert snapshot.is_dismissed("baumarkt")
    assert snapshot.is_dismissed("BAUMARKT")
    assert not snapshot.is_dismissed("Berlin")


def test_empty_snapshot_has_no_dictionary_data():
    snapshot = DictionarySnapshot()

    assert snapshot.persons == []
    assert snapshot.terms == []
    assert snapshot.text_corrections == []
    assert not snapshot.is_dismissed("anything")


def test_correction_and_entity_detection_run_on_the_snapshot(monkeypatch):
    monkeypatch.setattr(transcript_corrector, "LLM_CORRECTION_ENABLED", False)
    snapshot = DictionarySnapshot(
        persons=PERSONS,
        terms=TERMS,
        text_corrections=[{"original_text": "Berlim", "corrected_text": "Berlin"}],
        dismissals=["Baumarkt"],
    )

    result = _run(
        correction.correct_and_detect_entities(
            "Anna Schmidt fuhr nach Berlim und dann zum Baumarkt.", snapshot=snapshot
        )
    )

    assert result.corrected_text == "Anna Schmidt fuhr nach Berlin und dann zum Baumarkt."
    assert result.applied_corrections == [{"original": "Berlim", "corrected": "Berlin", "count": 1}]
    assert sorted(e.canonical for e in result.entities) == ["Anna Schmidt", "Berlin"]


class _FakePool:
    """Answers the four dictionary queries; dismissals share the
    `text_corrections` table with word corrections, as in Postgres."""

    def __init__(self):
        self.queries: list[str] = []

    async def fetch(self, sql, *args):
        self.queries.append(sql)
        if "FROM persons" in sql:
            return PERSONS
        if "FROM terms" in sql:
            return TERMS
        assert "FROM text_corrections" in sql
        if "!= 'entity_dismissal'" in sql:
            return [
                {
                    "original_text": "Berlim", "corrected_text": "Berlin",
                    "correction_type": "word", "case_sensitive": False,
                }
            ]
        return [{"original_text": "Baumarkt"}]


@pytest.fixture
def fake_pool(monkeypatch):
    pool = _FakePool()
    monkeypatch.setattr(db, "_pool", pool)
    return pool


def test_load_dictionary_snapshot_reads_all_four_inputs(fake_pool):
    snapshot = _run(dictionary.load_dictionary_snapshot())

    assert snapshot.persons == PERSONS
    assert snapshot.terms == TERMS
    assert [c["original_text"] for c in snapshot.text_corrections] == ["Berlim"]
    assert snapshot.is_dismissed("Baumarkt")
    assert len(fake_pool.queries) == 4


def test_correction_loads_a_snapshot_when_none_is_given(monkeypatch, fake_pool):
    monkeypatch.setattr(transcript_corrector, "LLM_CORRECTION_ENABLED", False)

    result = _run(
        correction.correct_and_detect_entities("Anna Schmidt fuhr nach Berlim zum Baumarkt.")
    )

    assert result.corrected_text == "Anna Schmidt fuhr nach Berlin zum Baumarkt."
    assert sorted(e.canonical for e in result.entities) == ["Anna Schmidt", "Berlin"]
