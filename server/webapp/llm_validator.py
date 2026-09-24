"""
LLM-based validation layer for detected entities.

Sends uncertain entities (fuzzy, ambiguous, low-confidence) to Ollama
for contextual validation against the full transcript. Streams progress
via SSE events so the UI can show a live log.
"""

import json
import logging
import os
import time
from dataclasses import asdict

import httpx

from entity_detector import DetectedEntity

logger = logging.getLogger(__name__)

OLLAMA_BASE_URL = os.getenv("OLLAMA_BASE_URL", "http://192.168.2.17:11434")
OLLAMA_MODEL = os.getenv("OLLAMA_MODEL", "qwen2.5:14b")
LLM_VALIDATION_ENABLED = os.getenv("LLM_VALIDATION_ENABLED", "true").lower() == "true"
OLLAMA_TIMEOUT = float(os.getenv("OLLAMA_TIMEOUT", "120"))
OLLAMA_NUM_CTX = int(os.getenv("OLLAMA_NUM_CTX", "131072"))


def _needs_validation(ent: DetectedEntity) -> bool:
    """Decide whether an entity should be sent to the LLM for validation."""
    if ent.status in ("suggested", "ambiguous"):
        return True
    if ent.confidence in ("medium", "low"):
        return True
    return False


def _get_context_snippet(text: str, start: int, end: int, window: int = 30) -> str:
    """Extract surrounding context for an entity occurrence."""
    ctx_start = max(0, start - window)
    ctx_end = min(len(text), end + window)
    before = text[ctx_start:start]
    original = text[start:end]
    after = text[end:ctx_end]
    return f"...{before}[{original}]{after}..."


def _build_prompt(
    text: str,
    to_validate: list[tuple[int, DetectedEntity]],
    entity_usage_samples: dict[str, list[dict]] | None = None,
) -> list[dict]:
    """Build the chat messages for Ollama.

    Args:
        text: Full transcript text.
        to_validate: List of (original_index, entity) tuples to validate.
        entity_usage_samples: Optional dict keyed by "canonical|type" with lists
            of past usage sample dicts (each having 'sentence' key).
    """
    system_msg = (
        "You are an entity validation assistant for German-language CTO diary "
        "transcripts. Given a transcript and a list of detected entities with "
        "proposed canonical matches, determine if each match is correct in context."
    )

    entity_lines = []
    for idx, (orig_idx, ent) in enumerate(to_validate, 1):
        context = _get_context_snippet(text, ent.start, ent.end)
        line = (
            f'{idx}. "{ent.original_text}" at position {ent.start}-{ent.end} '
            f'-> proposed: "{ent.canonical}"\n'
            f"   (type: {ent.entity_type}, match: {ent.match_type}, "
            f"confidence: {ent.confidence})\n"
            f'   Context: "{context}"'
        )
        if ent.status == "ambiguous" and ent.candidates:
            line += "\n   Candidates:"
            for ci, cand in enumerate(ent.candidates):
                role_info = cand.get("role", "")
                company_info = cand.get("company", "")
                details = ", ".join(filter(None, [role_info, company_info]))
                line += f'\n   {chr(97 + ci)}) {cand["canonical"]}'
                if details:
                    line += f" ({details})"
                # Add usage samples for each candidate
                if entity_usage_samples:
                    cand_key = f"{cand['canonical']}|{ent.entity_type}"
                    cand_samples = entity_usage_samples.get(cand_key, [])
                    if cand_samples:
                        for sample in cand_samples[:2]:
                            line += f'\n      e.g.: "{sample["sentence"]}"'
            line += '\n   Pick the most likely candidate given context, or "uncertain".'

        # Add usage samples for the proposed canonical
        if entity_usage_samples:
            key = f"{ent.canonical}|{ent.entity_type}"
            samples = entity_usage_samples.get(key, [])
            if samples:
                line += f'\n   Past usage examples of "{ent.canonical}":'
                for sample in samples[:3]:
                    line += f'\n   - "{sample["sentence"]}"'

        entity_lines.append(line)

    user_msg = (
        f"TRANSCRIPT:\n{text}\n\n"
        f"ENTITIES TO VALIDATE:\n"
        + "\n".join(entity_lines)
        + "\n\n"
        "For each entity, respond with a JSON object:\n"
        "{\n"
        '  "validations": [\n'
        "    {\n"
        '      "index": 1,\n'
        '      "verdict": "correct" | "wrong" | "uncertain",\n'
        '      "reason": "brief explanation",\n'
        '      "suggested_canonical": "alternative name or null",\n'
        '      "suggested_type": "alternative entity type or null"\n'
        "    }\n"
        "  ]\n"
        "}\n\n"
        "Rules:\n"
        '- "correct": the proposed canonical makes sense in this context\n'
        '- "wrong": the text clearly refers to something different\n'
        '- "uncertain": cannot determine from context alone\n'
        '- When verdict is "wrong", suggest an alternative if possible\n'
        "- Consider German language context and CTO/tech domain\n"
        "- For ambiguous entities with candidates, pick the best candidate "
        "and put their name in suggested_canonical\n"
    )

    return [
        {"role": "system", "content": system_msg},
        {"role": "user", "content": user_msg},
    ]


def _parse_verdicts(response_text: str) -> list | None:
    """Parse the LLM JSON response into a list of verdict items."""
    try:
        data = json.loads(response_text)
    except json.JSONDecodeError:
        logger.warning("LLM returned invalid JSON: %s", response_text[:200])
        return None

    if isinstance(data, dict) and "validations" in data:
        return data["validations"]
    if isinstance(data, dict) and "results" in data:
        return data["results"]
    if isinstance(data, list):
        return data
    # Some models wrap in a single-key dict with an unexpected key
    if isinstance(data, dict) and len(data) == 1:
        val = next(iter(data.values()))
        if isinstance(val, list):
            return val
    logger.warning("Unexpected LLM response structure: %s", type(data))
    return None


def _apply_verdict(
    ent: DetectedEntity,
    verdict: dict,
    new_entities: list[DetectedEntity],
) -> str:
    """Apply a single LLM verdict to an entity. Returns a log description."""
    decision = verdict.get("verdict", "uncertain")
    reason = verdict.get("reason", "")
    suggested_canonical = verdict.get("suggested_canonical")
    suggested_type = verdict.get("suggested_type")

    ent.llm_validated = True
    ent.llm_reason = reason

    if decision == "correct":
        old_status = ent.status
        ent.confidence = "high"
        if ent.status == "suggested":
            ent.status = "auto-matched"
        # For ambiguous with a suggested canonical matching a candidate
        if old_status == "ambiguous" and suggested_canonical and ent.candidates:
            for cand in ent.candidates:
                if cand["canonical"].lower() == suggested_canonical.lower():
                    ent.canonical = cand["canonical"]
                    ent.dictionary_id = cand["id"]
                    ent.status = "auto-matched"
                    ent.match_type = "llm"
                    return (
                        f'CONFIRMED "{ent.original_text}" -> '
                        f'disambiguated to "{cand["canonical"]}" ({reason})'
                    )
        return f'CONFIRMED "{ent.original_text}" -> "{ent.canonical}" ({reason})'

    elif decision == "wrong":
        ent.status = "dismissed"
        log = f'REJECTED "{ent.original_text}" (was "{ent.canonical}") ({reason})'
        if suggested_canonical:
            new_ent = DetectedEntity(
                start=ent.start,
                end=ent.end,
                original_text=ent.original_text,
                canonical=suggested_canonical,
                entity_type=suggested_type or ent.entity_type,
                match_type="llm",
                confidence="medium",
                status="suggested",
                dictionary_id=None,
                source=ent.source,
                llm_validated=True,
                llm_reason=reason,
                llm_suggested=True,
            )
            new_entities.append(new_ent)
            log += f' -> suggested "{suggested_canonical}" instead'
        return log

    else:
        return f'UNCERTAIN "{ent.original_text}" -> "{ent.canonical}" ({reason})'


def _sse_log(
    message: str,
    level: str = "info",
    entity_start: int | None = None,
    entity_end: int | None = None,
) -> dict:
    """Build an SSE event dict for a log line."""
    payload = {"message": message, "level": level}
    if entity_start is not None:
        payload["entity_start"] = entity_start
        payload["entity_end"] = entity_end
    return {"event": "log", "data": json.dumps(payload)}


def _sse_result(entities: list[DetectedEntity]) -> dict:
    """Build an SSE event dict for the final result."""
    return {
        "event": "result",
        "data": json.dumps([asdict(e) for e in entities]),
    }


def _sse_error(message: str) -> dict:
    """Build an SSE event dict for an error."""
    return {"event": "error", "data": json.dumps({"message": message})}


async def validate_entities_stream(
    text: str,
    entities: list[DetectedEntity],
    entity_usage_samples: dict[str, list[dict]] | None = None,
):
    """
    Async generator that yields SSE event dicts.
    Streams log progress, then yields the final entity list as 'result'.
    """
    if not LLM_VALIDATION_ENABLED:
        yield _sse_log("LLM validation disabled", "warn")
        yield _sse_result(entities)
        return

    # Filter entities that need validation
    to_validate = [
        (i, ent) for i, ent in enumerate(entities) if _needs_validation(ent)
    ]

    if not to_validate:
        yield _sse_log("No entities need LLM validation (all high-confidence exact matches)")
        yield _sse_result(entities)
        return

    yield _sse_log(
        f"Filtering: {len(to_validate)} of {len(entities)} entities need validation"
    )
    for i, (orig_idx, ent) in enumerate(to_validate, 1):
        yield _sse_log(
            f"  {i}. \"{ent.original_text}\" -> \"{ent.canonical}\" "
            f"[{ent.match_type}, {ent.confidence}, {ent.status}]"
        )

    # Build prompt
    if entity_usage_samples:
        yield _sse_log(f"Enriching prompt with {sum(len(v) for v in entity_usage_samples.values())} past usage samples")
    yield _sse_log(f"Building prompt for {OLLAMA_MODEL}...")
    messages = _build_prompt(text, to_validate, entity_usage_samples=entity_usage_samples)

    # Call Ollama
    logger.info("Calling Ollama at %s (model: %s, timeout: %ss)", OLLAMA_BASE_URL, OLLAMA_MODEL, OLLAMA_TIMEOUT)
    yield _sse_log(f"Calling Ollama for entity validation...")
    t0 = time.monotonic()

    try:
        async with httpx.AsyncClient(timeout=OLLAMA_TIMEOUT) as client:
            resp = await client.post(
                f"{OLLAMA_BASE_URL}/api/chat",
                json={
                    "model": OLLAMA_MODEL,
                    "messages": messages,
                    "format": "json",
                    "stream": False,
                    "options": {"num_ctx": OLLAMA_NUM_CTX},
                },
            )
            resp.raise_for_status()
    except httpx.ConnectError:
        msg = f"Ollama unreachable at {OLLAMA_BASE_URL}"
        logger.warning(msg)
        yield _sse_log(msg, "error")
        yield _sse_result(entities)
        return
    except httpx.TimeoutException:
        elapsed = time.monotonic() - t0
        msg = f"Ollama timed out after {elapsed:.1f}s"
        logger.warning(msg)
        yield _sse_log(msg, "error")
        yield _sse_result(entities)
        return
    except httpx.HTTPStatusError as e:
        msg = f"Ollama returned HTTP {e.response.status_code}"
        logger.warning(msg)
        yield _sse_log(msg, "error")
        yield _sse_result(entities)
        return

    elapsed = time.monotonic() - t0
    yield _sse_log(f"Ollama responded in {elapsed:.1f}s")

    # Parse response
    try:
        body = resp.json()
        content = body.get("message", {}).get("content", "")
    except (json.JSONDecodeError, AttributeError):
        yield _sse_log("Failed to parse Ollama response body", "error")
        yield _sse_result(entities)
        return

    verdicts = _parse_verdicts(content)
    if not verdicts:
        yield _sse_log("Could not parse LLM verdicts from response", "error")
        yield _sse_result(entities)
        return

    yield _sse_log(f"Received {len(verdicts)} verdicts, applying...")

    # Build index lookup: LLM index (1-based) -> (original_idx, entity)
    validate_by_llm_idx = {
        i + 1: (orig_idx, ent) for i, (orig_idx, ent) in enumerate(to_validate)
    }

    # Apply verdicts
    new_entities: list[DetectedEntity] = []
    counts = {"correct": 0, "wrong": 0, "uncertain": 0}
    skipped = 0
    for verdict in verdicts:
        # Skip non-dict items (LLM sometimes returns strings in the array)
        if not isinstance(verdict, dict):
            skipped += 1
            continue
        llm_idx = verdict.get("index")
        if llm_idx not in validate_by_llm_idx:
            skipped += 1
            continue
        try:
            orig_idx, ent = validate_by_llm_idx[llm_idx]
            log_line = _apply_verdict(ent, verdict, new_entities)

            decision = verdict.get("verdict", "uncertain")
            counts[decision] = counts.get(decision, 0) + 1

            level = "ok" if decision == "correct" else ("warn" if decision == "wrong" else "info")
            yield _sse_log(log_line, level, entity_start=ent.start, entity_end=ent.end)
        except Exception as e:
            skipped += 1
            yield _sse_log(f"Error processing verdict #{llm_idx}: {e}", "error")

    if skipped:
        yield _sse_log(f"Skipped {skipped} unparseable verdict(s)", "warn")

    # Insert new LLM-suggested entities
    if new_entities:
        entities.extend(new_entities)
        entities.sort(key=lambda d: (d.start, -(d.end - d.start)))
        deduped = []
        last_end = -1
        for d in entities:
            if d.start >= last_end:
                deduped.append(d)
                last_end = d.end
            elif d.status != "dismissed":
                if deduped and deduped[-1].status == "dismissed":
                    deduped[-1] = d
                    last_end = d.end
        entities = deduped

    validated = counts["correct"] + counts["wrong"] + counts["uncertain"]
    unvalidated = len(to_validate) - validated
    yield _sse_log(
        f"Done: {counts['correct']} confirmed, {counts['wrong']} rejected, "
        f"{counts['uncertain']} uncertain"
        + (f", {len(new_entities)} new suggestions" if new_entities else "")
        + (f", {unvalidated} without verdict" if unvalidated else ""),
        "ok",
    )

    yield _sse_result(entities)
