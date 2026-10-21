"""
The Dictionary snapshot both transcript pipelines run their correction chain
against: the HTMX SSE review flow (`routers/review_stream.py`) and the iOS
per-segment pipeline (`session_processing._process_segment`).

One loader reads persons, terms, text corrections and entity dismissals so
callers hold a single value instead of four lists. Dismissals live in the
`text_corrections` table (type `entity_dismissal`); that storage detail stays
behind `load_dictionary_snapshot` and `DictionarySnapshot.is_dismissed`.

The write side lives here too: `learn_from_review` is the one place a reviewed
transcript grows the Dictionary, shared by the draft save and the final submit.
"""

from __future__ import annotations

import logging
import re
from collections.abc import Callable, Coroutine, Iterable
from dataclasses import dataclass, field
from datetime import date as date_module
from typing import Any

import db
import vector_store

logger = logging.getLogger(__name__)


@dataclass(frozen=True)
class DictionarySnapshot:
    persons: list[dict] = field(default_factory=list)
    terms: list[dict] = field(default_factory=list)
    text_corrections: list[dict] = field(default_factory=list)
    # Any iterable of dismissed texts in; a lowercased frozenset out.
    dismissals: Iterable[str] = frozenset()

    def __post_init__(self) -> None:
        object.__setattr__(
            self, "dismissals", frozenset(d.lower() for d in self.dismissals)
        )

    def is_dismissed(self, text: str) -> bool:
        return text.lower() in self.dismissals


async def load_dictionary_snapshot() -> DictionarySnapshot:
    return DictionarySnapshot(
        persons=await db.load_person_dictionary(),
        terms=await db.load_term_dictionary(),
        text_corrections=await db.load_text_corrections(),
        dismissals=await db.load_entity_dismissals(),
    )

# ─── Learning from a review ───────────────────────────────────────────


@dataclass(frozen=True)
class ReviewLearning:
    # Dictionary entries created from entities the reviewer marked "new-entity".
    # Only a draft save creates entries this way; a submit creates its entries
    # from the explicit `new_entities` list and reports 0 here.
    new_entries: int = 0


def _original(item: dict, default: Any = "") -> Any:
    """The text the reviewer replaced; payloads spell it `original` or `original_text`."""
    for key in ("original", "original_text"):
        if item.get(key) is not None:
            return item[key]
    return default


def _dictionary_id(item: dict) -> Any:
    """The matched dictionary row; payloads spell it `dictionary_id` or `dictionaryId`."""
    return item.get("dictionary_id") or item.get("dictionaryId")


def _text_edits(review: dict) -> list[tuple[str, str]]:
    edits = []
    for edit in review.get("text_edits", []):
        old_word = edit.get("oldWord", "").strip()
        new_word = edit.get("newWord", "").strip()
        if old_word and new_word and old_word != new_word:
            edits.append((old_word, new_word))
    return edits


async def _save_variation(repository: Any, source: str, dictionary_id: Any, original: str) -> None:
    if source == "person":
        await repository.save_person_variation(dictionary_id, original, "asr_correction")
    else:
        await repository.save_term_variation(dictionary_id, original)


async def learn_from_review(
    transcript_id: int,
    review: dict,
    *,
    submit: bool = False,
    repository: Any = None,
    vectors: Any = None,
    run_vector_task: Callable[[Coroutine[Any, Any, None]], Any] | None = None,
) -> ReviewLearning:
    """Grow the Dictionary from a reviewed transcript's payload.

    Both review routes call this after persisting the transcript. Payloads
    spell some keys two ways (`original`/`original_text`,
    `dictionary_id`/`dictionaryId`); either is accepted everywhere.

    Every review writes inline text edits as text corrections. A draft
    (`submit=False`) also creates entries for "new-entity" entities and saves
    variations for entities corrected onto an existing entry. A submit instead
    reads the reviewer's explicit `new_variations`, `disambiguated`,
    `new_entities` and `dismissed` lists, then logs each review action and
    stores vector samples. The vector write is handed to `run_vector_task`
    (the route's tracked task); without one it is awaited inline.

    `repository` (default `db`) and `vectors` (default `vector_store`) are
    injectable so the policy can be driven without Postgres or Qdrant.
    """
    repository = repository or db
    vectors = vectors or vector_store
    if submit:
        await _learn_from_submit(transcript_id, review, repository, vectors, run_vector_task)
        return ReviewLearning()
    return ReviewLearning(new_entries=await _learn_from_draft(review, repository))


async def _learn_from_draft(review: dict, repository: Any) -> int:
    new_entries = 0

    # New dictionary entries, so other transcripts can match them.
    for ent in review.get("entities", []):
        if ent.get("status") != "new-entity":
            continue
        canonical = ent.get("canonical", "")
        if not canonical:
            continue
        etype = ent.get("entity_type", "")
        if ent.get("source", "") == "person" or etype == "PERSON":
            await repository.create_person(canonical_name=canonical)
        else:
            category = etype.lower() if etype else "term"
            await repository.create_term(canonical_term=canonical, category=category)
        new_entries += 1

    # Corrections onto existing dictionary entries become variations.
    for ent in review.get("entities", []):
        did = _dictionary_id(ent)
        if not did:
            continue
        original = _original(ent)
        canonical = ent.get("canonical", "")
        if not original or not canonical or original == canonical:
            continue
        await _save_variation(repository, ent.get("source", ""), did, original)

    for old_word, new_word in _text_edits(review):
        await repository.save_text_correction(old_word, new_word, "word")

    return new_entries


async def _learn_from_submit(
    transcript_id: int,
    review: dict,
    repository: Any,
    vectors: Any,
    run_vector_task: Callable[[Coroutine[Any, Any, None]], Any] | None,
) -> None:
    for var in review.get("new_variations", []):
        did = _dictionary_id(var)
        if did:
            await _save_variation(repository, var["source"], did, _original(var))

    # Disambiguated first-name matches are saved as nicknames.
    for dis in review.get("disambiguated", []):
        original = _original(dis)
        if dis.get("chosen_id") and original:
            await repository.save_person_variation(dis["chosen_id"], original, "nickname")

    # Manually added entities.
    for new_ent in review.get("new_entities", []):
        if new_ent.get("source") == "person":
            await repository.create_person(canonical_name=new_ent["text"])
        else:
            await repository.create_term(
                canonical_term=new_ent["text"],
                category=new_ent.get("category", new_ent["type"].lower()),
            )

    for old_word, new_word in _text_edits(review):
        await repository.save_text_correction(old_word, new_word, "word")

    for dismissed in review.get("dismissed", []):
        original = _original(dismissed).strip()
        if original:
            await repository.save_text_correction(original, original, "entity_dismissal")

    for ent in review.get("entities", []):
        action = "corrected" if ent.get("is_correction") else "confirmed"
        await repository.log_review_action(
            transcript_id,
            _original(ent, ent["text"]),
            ent["text"],
            ent["type"],
            ent.get("match_type", "auto-matched"),
            action,
        )
    for dismissed in review.get("dismissed", []):
        original = _original(dismissed, None)
        if original is None:
            raise KeyError("original")
        await repository.log_review_action(
            transcript_id,
            original,
            dismissed["canonical"],
            dismissed["type"],
            "auto-matched",
            "dismissed",
        )

    if vectors.VECTOR_SEARCH_ENABLED:
        store = _store_review_vectors(transcript_id, review, vectors)
        if run_vector_task is None:
            await store
        else:
            run_vector_task(store)


async def _store_review_vectors(transcript_id: int, review: dict, vectors: Any) -> None:
    """Replace the transcript's vector samples with the reviewed ones."""
    corrected_text = review["corrected_transcript"]
    transcript_date = review.get("date", str(date_module.today()))

    # Remove existing vectors for this transcript to prevent duplicates
    await vectors.delete_transcript_vectors(transcript_id)

    # Text edits become correction contexts.
    for old_word, new_word in _text_edits(review):
        match = re.search(re.escape(new_word), corrected_text)
        if match:
            await vectors.store_correction_context(
                original_text=old_word,
                corrected_text=new_word,
                full_text=corrected_text,
                start=match.start(),
                end=match.end(),
                correction_type="text_edit",
                transcript_id=transcript_id,
                transcript_date=transcript_date,
            )

    # Entity corrections and confirmed entities.
    for ent in review.get("entities", []):
        start = ent.get("start", 0)
        end = ent.get("end", 0)
        original = _original(ent, ent.get("text", ""))
        canonical = ent.get("text", "")

        if ent.get("is_correction") and original.lower() != canonical.lower():
            await vectors.store_correction_context(
                original_text=original,
                corrected_text=canonical,
                full_text=corrected_text,
                start=start,
                end=end,
                correction_type="entity_correction",
                transcript_id=transcript_id,
                transcript_date=transcript_date,
            )

        await vectors.store_entity_sample(
            entity_canonical=canonical,
            entity_type=ent.get("type", ""),
            entity_id=_dictionary_id(ent),
            source=ent.get("source", ""),
            original_text=original,
            full_text=corrected_text,
            start=start,
            end=end,
            match_type=ent.get("match_type", ""),
            action="corrected" if ent.get("is_correction") else "confirmed",
            transcript_id=transcript_id,
            transcript_date=transcript_date,
        )

    logger.info("Stored vectors for transcript %s", transcript_id)

