"""
Decision rules for LLM entity validation.

Pure, synchronous rules that turn the model's verdicts into entity changes:
which entity a verdict refers to, how a correct/wrong/uncertain verdict
mutates it, which new suggestions it creates, and how overlapping spans are
resolved afterwards. Nothing here talks to Ollama or formats SSE events;
`llm_validator` owns prompt building, transport, progress and delivery.
"""

from dataclasses import dataclass

from entity_detector import DetectedEntity


def apply_verdict(
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


@dataclass
class VerdictOutcome:
    """What happened to one verdict.

    kind is "applied" (entity changed, `decision`/`description` set),
    "skipped" (not a dict or not a known index) or "failed" (applying raised;
    `error` is the exception and the entity may already be partly changed).
    """

    kind: str
    llm_index: object = None
    entity: DetectedEntity | None = None
    decision: str | None = None
    description: str = ""
    error: Exception | None = None


class EntityValidation:
    """One validation pass over the entities that were sent to the model.

    `to_validate` is the (original_index, entity) list in prompt order; the
    model's one-based verdict index refers to a position in that list. Feed
    verdicts to `apply` one at a time, then call `resolve` for the final
    entity list. Verdicts are applied in the order given, so a duplicate
    index is applied (and counted) again.
    """

    def __init__(
        self,
        entities: list[DetectedEntity],
        to_validate: list[tuple[int, DetectedEntity]],
    ):
        self._entities = entities
        self._to_validate = to_validate
        self._by_llm_index = {
            i + 1: (orig_idx, ent) for i, (orig_idx, ent) in enumerate(to_validate)
        }
        self.new_entities: list[DetectedEntity] = []
        self.counts = {"correct": 0, "wrong": 0, "uncertain": 0}
        self.skipped = 0

    @property
    def unvalidated(self) -> int:
        """Entities sent to the model minus verdicts counted (duplicates count again)."""
        validated = self.counts["correct"] + self.counts["wrong"] + self.counts["uncertain"]
        return len(self._to_validate) - validated

    def apply(self, verdict) -> VerdictOutcome:
        """Apply one verdict item from the model's response."""
        # Skip non-dict items (LLM sometimes returns strings in the array)
        if not isinstance(verdict, dict):
            self.skipped += 1
            return VerdictOutcome("skipped")
        llm_idx = verdict.get("index")
        if llm_idx not in self._by_llm_index:
            self.skipped += 1
            return VerdictOutcome("skipped", llm_index=llm_idx)
        try:
            _, ent = self._by_llm_index[llm_idx]
            description = apply_verdict(ent, verdict, self.new_entities)

            decision = verdict.get("verdict", "uncertain")
            self.counts[decision] = self.counts.get(decision, 0) + 1
        except Exception as e:
            self.skipped += 1
            return VerdictOutcome("failed", llm_index=llm_idx, error=e)
        return VerdictOutcome(
            "applied",
            llm_index=llm_idx,
            entity=ent,
            decision=decision,
            description=description,
        )

    def resolve(self) -> list[DetectedEntity]:
        """Insert the new suggestions and resolve overlapping spans.

        New suggestions are added to the list given at construction, which is
        re-sorted in place by (start, longest first). The returned list keeps
        the first entity at each position, except that a non-dismissed entity
        replaces a dismissed one it overlaps. With no new suggestions the
        original list is returned untouched.
        """
        entities = self._entities
        if not self.new_entities:
            return entities
        entities.extend(self.new_entities)
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
        return deduped
