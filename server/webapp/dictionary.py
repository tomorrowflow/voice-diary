"""
The Dictionary snapshot both transcript pipelines run their correction chain
against: the HTMX SSE review flow (`routers/review_stream.py`) and the iOS
per-segment pipeline (`session_ingest._process_segment`).

One loader reads persons, terms, text corrections and entity dismissals so
callers hold a single value instead of four lists. Dismissals live in the
`text_corrections` table (type `entity_dismissal`); that storage detail stays
behind `load_dictionary_snapshot` and `DictionarySnapshot.is_dismissed`.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Iterable

import db


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
