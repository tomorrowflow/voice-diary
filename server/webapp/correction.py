"""
Shared non-interactive transcript-correction chain for both server pipelines:
the HTMX SSE review flow (`main.py::process_transcript_stream`) and the iOS
session ingest (`routers/sessions.py::_process_segment`). The two paths used
to diverge — HTMX ran dictionary corrections, vector-store few-shot examples
and dismissal filtering that the iOS path skipped, so iOS diary entries
missed corrections the user had already taught the dictionary (#51).

Owned steps: dictionary text corrections -> vector-store few-shot examples
(when enabled) -> LLM transcript correction (falls back to the pre-LLM text
on any failure) -> entity detection -> dismissal filtering.

Deliberately NOT owned: the fluency check and `llm_validator` stay HTMX-only
(decision D2, handoff 01 re-check) — they only produce review-UI hints, never
affect the persisted transcript or entities, so the iOS path has no use for
them.

`on_step` mirrors `narrative.OnStep`: called as `on_step(event, data)` with
the same `log` event shape `main.py`'s SSE endpoint already emits. May be a
sync callable or return an awaitable. Callers that don't stream progress
(the iOS session path) simply omit it.
"""

from __future__ import annotations

import logging
import re
from dataclasses import dataclass, field
from typing import Awaitable, Callable

import transcript_corrector
import vector_store
from entity_detector import DetectedEntity, detect_entities

logger = logging.getLogger(__name__)

OnStep = Callable[[str, dict], "Awaitable[None] | None"]


@dataclass
class CorrectionResult:
    corrected_text: str
    llm_corrections: list[dict] = field(default_factory=list)
    applied_corrections: list[dict] = field(default_factory=list)
    entities: list[DetectedEntity] = field(default_factory=list)


def apply_text_corrections(
    raw_text: str, corrections: list[dict]
) -> tuple[str, list[dict]]:
    """Apply learned word corrections to raw transcript text.

    Returns (corrected_text, list_of_applied_corrections).
    Corrections are sorted longest-first and matched with word boundaries.
    """
    applied = []
    result = raw_text
    # corrections already sorted longest-first from DB query
    for corr in corrections:
        original = corr["original_text"]
        replacement = corr["corrected_text"]
        case_sensitive = corr.get("case_sensitive", False)
        flags = 0 if case_sensitive else re.IGNORECASE
        pattern = r"\b" + re.escape(original) + r"\b"
        new_result, count = re.subn(pattern, replacement, result, flags=flags)
        if count > 0:
            applied.append(
                {
                    "original": original,
                    "corrected": replacement,
                    "count": count,
                }
            )
            result = new_result
    return result, applied


async def _emit(on_step: OnStep | None, event: str, data: dict) -> None:
    if on_step is None:
        return
    maybe_awaitable = on_step(event, data)
    if maybe_awaitable is not None:
        await maybe_awaitable


async def _gather_correction_examples(text: str) -> list[dict]:
    """Sample up to 5 passages (~200 chars each) from the transcript and
    query the vector store for similar past corrections, deduplicated."""
    passage_len = 200
    passages = [
        text[i : i + passage_len] for i in range(0, len(text), passage_len)
    ][:5]
    seen: set[str] = set()
    examples: list[dict] = []
    for passage in passages:
        results = await vector_store.find_similar_corrections(passage, limit=3)
        for r in results:
            key = f"{r['original_text']}|{r['corrected_text']}"
            if key not in seen:
                seen.add(key)
                examples.append(r)
    return examples[:10]


async def correct_and_detect_entities(
    raw_text: str,
    *,
    persons: list[dict],
    terms: list[dict],
    text_corrections: list[dict] | None = None,
    dismissals: list[str] | None = None,
    on_step: OnStep | None = None,
) -> CorrectionResult:
    """Run dictionary corrections -> LLM correction -> entity detection ->
    dismissal filtering, emitting SSE-shaped `log` progress via `on_step` if
    given.
    """
    text = raw_text

    await _emit(on_step, "log", {"message": "Applying dictionary corrections...", "level": "info"})
    applied_corrections: list[dict] = []
    if text_corrections:
        text, applied_corrections = apply_text_corrections(text, text_corrections)

    llm_corrections: list[dict] = []
    if transcript_corrector.LLM_CORRECTION_ENABLED:
        correction_examples: list[dict] = []
        if vector_store.VECTOR_SEARCH_ENABLED:
            await _emit(on_step, "log", {"message": "Querying vector store for similar corrections...", "level": "info"})
            correction_examples = await _gather_correction_examples(text)
            if correction_examples:
                await _emit(on_step, "log", {"message": f"Found {len(correction_examples)} similar past corrections", "level": "ok"})

        await _emit(on_step, "log", {"message": "Calling Ollama for transcript correction...", "level": "info"})
        try:
            text, llm_corrections = await transcript_corrector.correct_transcript(
                text, correction_examples=correction_examples or None
            )
        except Exception as exc:  # noqa: BLE001 — fall back to the pre-LLM text, as sessions did before this module existed
            logger.warning("transcript_corrector failed: %s — using uncorrected text", exc)
            llm_corrections = []

        if llm_corrections:
            await _emit(on_step, "log", {"message": f"Applied {len(llm_corrections)} LLM correction(s)", "level": "ok"})
        else:
            await _emit(on_step, "log", {"message": "No LLM corrections needed", "level": "info"})
    else:
        await _emit(on_step, "log", {"message": "LLM transcript correction disabled", "level": "info"})

    await _emit(on_step, "log", {"message": "Detecting entities...", "level": "info"})
    entities = detect_entities(text=text, persons=persons, terms=terms)

    if dismissals:
        dismissals_lower = {d.lower() for d in dismissals}
        entities = [
            e for e in entities if e.original_text.lower() not in dismissals_lower
        ]

    await _emit(on_step, "log", {"message": f"Found {len(entities)} entities", "level": "ok"})

    return CorrectionResult(
        corrected_text=text,
        llm_corrections=llm_corrections,
        applied_corrections=applied_corrections,
        entities=entities,
    )
