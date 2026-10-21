"""REF-123: `dictionary.learn_from_review` is the single place a reviewed
transcript grows the Dictionary, for both the draft save and the submit.

The domain entry point is driven with a fake repository and a fake vector
store, so no Postgres or Qdrant is involved. The two routes are checked only
for delegation and their unchanged response shapes.
"""

from __future__ import annotations

import asyncio

import pytest

import db
import dictionary
import main


class FakeRepository:
    def __init__(self) -> None:
        self.calls: list[tuple] = []

    async def create_person(self, canonical_name, **kwargs):
        self.calls.append(("create_person", canonical_name))

    async def create_term(self, canonical_term, category, **kwargs):
        self.calls.append(("create_term", canonical_term, category))

    async def save_person_variation(self, person_id, variation, variation_type="asr_correction"):
        self.calls.append(("person_variation", person_id, variation, variation_type))

    async def save_term_variation(self, term_id, variation):
        self.calls.append(("term_variation", term_id, variation))

    async def save_text_correction(self, original, corrected, correction_type="word"):
        self.calls.append(("text_correction", original, corrected, correction_type))

    async def log_review_action(self, transcript_id, original, corrected, entity_type, match_type, action):
        self.calls.append(
            ("log", transcript_id, original, corrected, entity_type, match_type, action)
        )


class FakeVectors:
    def __init__(self, enabled: bool = True) -> None:
        self.VECTOR_SEARCH_ENABLED = enabled
        self.calls: list[tuple] = []

    async def delete_transcript_vectors(self, transcript_id):
        self.calls.append(("delete", transcript_id))

    async def store_correction_context(self, **kwargs):
        self.calls.append(("correction", kwargs["correction_type"], kwargs["original_text"]))

    async def store_entity_sample(self, **kwargs):
        self.calls.append(
            ("sample", kwargs["entity_canonical"], kwargs["entity_id"], kwargs["original_text"],
             kwargs["action"])
        )


def _draft(review: dict):
    repo = FakeRepository()
    learning = asyncio.run(dictionary.learn_from_review(7, review, repository=repo))
    return repo, learning


def _submit(review: dict, *, vectors: FakeVectors | None = None, run_vector_task=None):
    repo = FakeRepository()
    vectors = vectors or FakeVectors(enabled=False)
    learning = asyncio.run(
        dictionary.learn_from_review(
            7, review, submit=True, repository=repo, vectors=vectors,
            run_vector_task=run_vector_task,
        )
    )
    return repo, vectors, learning


# ─── Draft save ───────────────────────────────────────────────────────


def test_draft_new_person_and_new_term_are_created_and_counted():
    repo, learning = _draft({"entities": [
        {"status": "new-entity", "canonical": "Anna Schmidt", "source": "person"},
        {"status": "new-entity", "canonical": "Bob Meier", "entity_type": "PERSON"},
        {"status": "new-entity", "canonical": "Baumarkt", "entity_type": "ORG"},
        {"status": "new-entity", "canonical": "Kanban"},
        {"status": "new-entity", "canonical": ""},
        {"status": "auto-matched", "canonical": "Berlin"},
    ]})

    assert repo.calls == [
        ("create_person", "Anna Schmidt"),
        ("create_person", "Bob Meier"),
        ("create_term", "Baumarkt", "org"),
        ("create_term", "Kanban", "term"),
    ]
    assert learning.new_entries == 4


@pytest.mark.parametrize(
    "original_key, id_key",
    [("original_text", "dictionary_id"), ("original", "dictionaryId"),
     ("original", "dictionary_id"), ("original_text", "dictionaryId")],
)
def test_draft_variation_accepts_both_payload_spellings(original_key, id_key):
    repo, _ = _draft({"entities": [
        {original_key: "Tomas", "canonical": "Martin", id_key: 3, "source": "person"},
        {original_key: "Berlim", "canonical": "Berlin", id_key: 9, "source": "term"},
    ]})

    assert repo.calls == [
        ("person_variation", 3, "Tomas", "asr_correction"),
        ("term_variation", 9, "Berlim"),
    ]


def test_draft_skips_entities_that_teach_nothing():
    repo, _ = _draft({"entities": [
        {"original_text": "Anna", "canonical": "Anna", "dictionary_id": 1, "source": "person"},
        {"original_text": "", "canonical": "Anna", "dictionary_id": 1, "source": "person"},
        {"original_text": "Ana", "canonical": "", "dictionary_id": 1, "source": "person"},
        {"original_text": "Ana", "canonical": "Anna", "source": "person"},
    ]})

    assert repo.calls == []


def test_draft_text_edits_become_text_corrections_and_nothing_submit_only():
    repo, learning = _draft({
        "corrected_transcript": "Berlin",
        "text_edits": [
            {"oldWord": " Berlim ", "newWord": "Berlin "},
            {"oldWord": "same", "newWord": "same"},
            {"oldWord": "", "newWord": "x"},
        ],
        "entities": [{"text": "Berlin", "original": "Berlim", "type": "LOCATION",
                      "is_correction": True}],
        "dismissed": [{"original": "Hallo", "canonical": "Hallo", "type": "TERM"}],
        "new_entities": [{"text": "Ignored", "type": "TERM"}],
        "disambiguated": [{"original": "Tom", "chosen_id": 4}],
    })

    assert repo.calls == [("text_correction", "Berlim", "Berlin", "word")]
    assert learning.new_entries == 0


# ─── Submit ───────────────────────────────────────────────────────────


@pytest.mark.parametrize(
    "original_key, id_key",
    [("original", "dictionary_id"), ("original_text", "dictionaryId")],
)
def test_submit_new_variations_accept_both_payload_spellings(original_key, id_key):
    repo, _, _ = _submit({"new_variations": [
        {original_key: "Tomas", id_key: 3, "source": "person"},
        {original_key: "Berlim", id_key: 9, "source": "term"},
        {original_key: "Orphan", "source": "term"},
    ]})

    assert repo.calls == [
        ("person_variation", 3, "Tomas", "asr_correction"),
        ("term_variation", 9, "Berlim"),
    ]


def test_submit_new_person_new_term_and_disambiguated_nickname():
    repo, _, learning = _submit({
        "new_entities": [
            {"text": "Anna Schmidt", "type": "PERSON", "source": "person"},
            {"text": "Baumarkt", "type": "ORG", "source": "term"},
            {"text": "Kanban", "type": "TERM", "source": "term", "category": "method"},
        ],
        "disambiguated": [
            {"original": "Tom", "chosen_id": 4},
            {"original_text": "Bob", "chosen_id": 5},
            {"original": "", "chosen_id": 6},
            {"original": "Nobody"},
        ],
    })

    assert repo.calls == [
        ("person_variation", 4, "Tom", "nickname"),
        ("person_variation", 5, "Bob", "nickname"),
        ("create_person", "Anna Schmidt"),
        ("create_term", "Baumarkt", "org"),
        ("create_term", "Kanban", "method"),
    ]
    assert learning.new_entries == 0


def test_submit_text_edits_dismissals_and_review_log():
    repo, _, _ = _submit({
        "text_edits": [{"oldWord": "Berlim", "newWord": "Berlin"}],
        "dismissed": [
            {"original": " Hallo ", "canonical": "Hallo", "type": "TERM"},
            {"original_text": "Welt", "canonical": "Welt", "type": "TERM"},
        ],
        "entities": [
            {"text": "Martin", "original": "Tomas", "type": "PERSON", "is_correction": True,
             "match_type": "fuzzy"},
            {"text": "Berlin", "type": "LOCATION"},
        ],
    })

    assert repo.calls == [
        ("text_correction", "Berlim", "Berlin", "word"),
        ("text_correction", "Hallo", "Hallo", "entity_dismissal"),
        ("text_correction", "Welt", "Welt", "entity_dismissal"),
        ("log", 7, "Tomas", "Martin", "PERSON", "fuzzy", "corrected"),
        ("log", 7, "Berlin", "Berlin", "LOCATION", "auto-matched", "confirmed"),
        ("log", 7, " Hallo ", "Hallo", "TERM", "auto-matched", "dismissed"),
        ("log", 7, "Welt", "Welt", "TERM", "auto-matched", "dismissed"),
    ]


def test_submit_ignores_draft_only_new_entity_status():
    repo, _, learning = _submit({"entities": [
        {"status": "new-entity", "canonical": "Anna", "source": "person",
         "text": "Anna", "type": "PERSON", "original_text": "Ana", "dictionary_id": 1},
    ]})

    assert [c[0] for c in repo.calls] == ["log"]
    assert learning.new_entries == 0


# ─── Submit vectors ───────────────────────────────────────────────────

VECTOR_REVIEW = {
    "corrected_transcript": "Martin fährt nach Berlin.",
    "date": "2026-10-18",
    "entities": [
        {"text": "Martin", "original_text": "Tomas", "type": "PERSON", "source": "person",
         "is_correction": True, "dictionaryId": 7},
        {"text": "Berlin", "type": "LOCATION", "dictionary_id": 2},
    ],
    "text_edits": [{"oldWord": "Berlim", "newWord": "Berlin"}],
}


def test_submit_hands_vector_write_to_the_tracked_task_runner():
    vectors = FakeVectors()
    handed: list = []

    async def run():
        repo = FakeRepository()
        await dictionary.learn_from_review(
            7, VECTOR_REVIEW, submit=True, repository=repo, vectors=vectors,
            run_vector_task=handed.append,
        )
        before = list(vectors.calls)
        await handed[0]
        return before

    before = asyncio.run(run())

    assert len(handed) == 1
    assert before == []  # handed over, not run inline
    assert vectors.calls == [
        ("delete", 7),
        ("correction", "text_edit", "Berlim"),
        ("correction", "entity_correction", "Tomas"),
        ("sample", "Martin", 7, "Tomas", "corrected"),
        ("sample", "Berlin", 2, "Berlin", "confirmed"),
    ]


def test_submit_awaits_vector_write_inline_without_a_runner():
    _, vectors, _ = _submit(VECTOR_REVIEW, vectors=FakeVectors())

    assert vectors.calls[0] == ("delete", 7)
    assert len(vectors.calls) == 5


def test_submit_without_vector_search_stores_no_vectors():
    handed: list = []
    _, vectors, _ = _submit(VECTOR_REVIEW, vectors=FakeVectors(enabled=False),
                            run_vector_task=handed.append)

    assert handed == []
    assert vectors.calls == []


def test_draft_never_touches_vectors_or_the_review_log():
    vectors = FakeVectors()
    repo = FakeRepository()
    asyncio.run(dictionary.learn_from_review(7, VECTOR_REVIEW, repository=repo, vectors=vectors))

    assert vectors.calls == []
    assert [c for c in repo.calls if c[0] == "log"] == []


# ─── Routes delegate ──────────────────────────────────────────────────


class _FakeRequest:
    def __init__(self, body: dict) -> None:
        self._body = body

    async def json(self) -> dict:
        return self._body


@pytest.fixture
def stub_db(monkeypatch: pytest.MonkeyPatch) -> list[tuple]:
    calls: list[tuple] = []

    def record(name):
        async def fake(*args, **kwargs):
            calls.append((name, args, kwargs))
        return fake

    for name in ("save_draft", "create_person", "create_term", "save_person_variation",
                 "save_term_variation", "save_text_correction", "log_review_action"):
        monkeypatch.setattr(db, name, record(name))
    return calls


def test_save_draft_route_delegates_and_keeps_response_shape(stub_db):
    body = {
        "corrected_transcript": "Anna",
        "entities": [{"status": "new-entity", "canonical": "Anna", "source": "person"}],
    }
    response = asyncio.run(main.save_draft(7, _FakeRequest(body)))

    assert response == {"status": "saved", "new_dictionary_entries": 1}
    assert [c[0] for c in stub_db] == ["save_draft", "create_person"]


def test_submit_route_delegates_and_keeps_response_shape(stub_db, monkeypatch):
    seen: list[tuple] = []

    async def fake_learn(transcript_id, review, **kwargs):
        seen.append((transcript_id, review, kwargs))

    monkeypatch.setattr(dictionary, "learn_from_review", fake_learn)
    body = {"corrected_transcript": "Anna", "entities": []}
    response = asyncio.run(main.submit_review(7, _FakeRequest(body)))

    assert response == {"status": "submitted"}
    assert [c[0] for c in stub_db] == ["save_draft"]
    (transcript_id, review, kwargs), = seen
    assert (transcript_id, review) == (7, body)
    assert kwargs["submit"] is True
    assert callable(kwargs["run_vector_task"])

