"""Tests for `correction.correct_and_detect_entities` — the shared
non-interactive correction chain both `main.py::process_transcript_stream`
(HTMX SSE) and `routers/sessions.py::_process_segment` (iOS sessions)
delegate to (#51).

`detect_entities` is monkeypatched at the module level (the established
pattern in `test_sessions.py`), since it has no injectable-port seam.

Run inside the webapp container so deps match prod:

    docker compose run --rm webapp pytest tests/test_correction.py
"""

from __future__ import annotations

import asyncio

import correction
import transcript_corrector
import vector_store
from entity_detector import DetectedEntity


def _run(coro):
    return asyncio.run(coro)


def _entity(text: str, entity_type: str = "PERSON") -> DetectedEntity:
    return DetectedEntity(
        start=0,
        end=len(text),
        original_text=text,
        canonical=text,
        entity_type=entity_type,
        match_type="exact",
        confidence="high",
        status="auto-matched",
    )


def test_dictionary_correction_is_applied_before_llm_correction(monkeypatch):
    monkeypatch.setattr(transcript_corrector, "LLM_CORRECTION_ENABLED", False)
    monkeypatch.setattr(correction, "detect_entities", lambda *, text, persons, terms: [])

    result = _run(
        correction.correct_and_detect_entities(
            "Ich fahre nach Berlim heute.",
            persons=[],
            terms=[],
            text_corrections=[
                {"original_text": "Berlim", "corrected_text": "Berlin", "case_sensitive": False}
            ],
        )
    )

    assert result.corrected_text == "Ich fahre nach Berlin heute."
    assert result.applied_corrections == [
        {"original": "Berlim", "corrected": "Berlin", "count": 1}
    ]


def test_dismissed_entity_is_filtered_out(monkeypatch):
    monkeypatch.setattr(transcript_corrector, "LLM_CORRECTION_ENABLED", False)
    kept = _entity("Thomas")
    dismissed = _entity("Baumarkt", entity_type="ORGANIZATION")
    monkeypatch.setattr(
        correction, "detect_entities", lambda *, text, persons, terms: [kept, dismissed]
    )

    result = _run(
        correction.correct_and_detect_entities(
            "Thomas war im Baumarkt.",
            persons=[],
            terms=[],
            dismissals=["Baumarkt"],
        )
    )

    assert result.entities == [kept]


def test_llm_correction_failure_falls_back_to_pre_llm_text(monkeypatch):
    monkeypatch.setattr(transcript_corrector, "LLM_CORRECTION_ENABLED", True)
    monkeypatch.setattr(vector_store, "VECTOR_SEARCH_ENABLED", False)
    monkeypatch.setattr(correction, "detect_entities", lambda *, text, persons, terms: [])

    async def fake_correct_transcript(text, correction_examples=None):
        raise RuntimeError("ollama exploded")

    monkeypatch.setattr(transcript_corrector, "correct_transcript", fake_correct_transcript)

    result = _run(
        correction.correct_and_detect_entities(
            "Der Text bleibt unveraendert.",
            persons=[],
            terms=[],
        )
    )

    assert result.corrected_text == "Der Text bleibt unveraendert."
    assert result.llm_corrections == []
