"""Decision rules for LLM entity validation, tested without Ollama or SSE."""

import pytest

from entity_detector import DetectedEntity
from entity_validation import EntityValidation, apply_verdict


def ent(start, end, canonical, status="suggested", confidence="medium", **kw):
    return DetectedEntity(
        start=start,
        end=end,
        original_text=kw.pop("original_text", f"t{start}"),
        canonical=canonical,
        entity_type=kw.pop("entity_type", "PERSON"),
        match_type=kw.pop("match_type", "fuzzy"),
        confidence=confidence,
        status=status,
        **kw,
    )


def validation(*entities):
    """A validation over `entities`, all of which were sent to the model."""
    entities = list(entities)
    return EntityValidation(entities, list(enumerate(entities)))


# -- apply_verdict: one verdict, one entity ------------------------------------


def test_correct_confirms_a_suggested_entity():
    e = ent(0, 3, "Anna", status="suggested", confidence="low")

    log = apply_verdict(e, {"verdict": "correct", "reason": "fits"}, [])

    assert log == 'CONFIRMED "t0" -> "Anna" (fits)'
    assert (e.status, e.confidence, e.canonical) == ("auto-matched", "high", "Anna")
    assert (e.llm_validated, e.llm_reason) == (True, "fits")


def test_correct_raises_confidence_but_keeps_other_statuses():
    e = ent(0, 3, "Anna", status="new-entity")

    apply_verdict(e, {"verdict": "correct"}, [])

    assert (e.status, e.confidence) == ("new-entity", "high")


def test_correct_on_ambiguous_without_a_matching_candidate_keeps_it_ambiguous():
    candidates = [{"canonical": "Bob A", "id": 1}, {"canonical": "Bob B", "id": 2}]
    e = ent(0, 3, "Bob A", status="ambiguous", candidates=candidates, dictionary_id=None)

    log = apply_verdict(e, {"verdict": "correct", "suggested_canonical": "Bob C", "reason": "r"}, [])

    assert log == 'CONFIRMED "t0" -> "Bob A" (r)'
    assert (e.status, e.confidence, e.canonical, e.dictionary_id) == ("ambiguous", "high", "Bob A", None)
    assert e.match_type == "fuzzy"


def test_correct_on_ambiguous_picks_the_candidate_case_insensitively():
    candidates = [{"canonical": "Bob A", "id": 1}, {"canonical": "Bob B", "id": 2}]
    e = ent(0, 3, "Bob A", status="ambiguous", candidates=candidates)

    log = apply_verdict(e, {"verdict": "correct", "suggested_canonical": "BOB b", "reason": "r"}, [])

    assert log == 'CONFIRMED "t0" -> disambiguated to "Bob B" (r)'
    assert (e.canonical, e.dictionary_id, e.status, e.match_type) == ("Bob B", 2, "auto-matched", "llm")


def test_correct_on_ambiguous_without_suggested_canonical_does_not_disambiguate():
    candidates = [{"canonical": "Bob A", "id": 1}]
    e = ent(0, 3, "Bob A", status="ambiguous", candidates=candidates)

    apply_verdict(e, {"verdict": "correct"}, [])

    assert (e.status, e.dictionary_id, e.match_type) == ("ambiguous", None, "fuzzy")


def test_suggested_canonical_only_disambiguates_entities_that_were_ambiguous():
    candidates = [{"canonical": "Bob B", "id": 2}]
    e = ent(0, 3, "Bob A", status="suggested", candidates=candidates)

    apply_verdict(e, {"verdict": "correct", "suggested_canonical": "Bob B"}, [])

    assert (e.canonical, e.status, e.dictionary_id) == ("Bob A", "auto-matched", None)


def test_wrong_dismisses_and_records_a_new_suggestion():
    e = ent(4, 9, "Kubernetes Inc", entity_type="ORGANIZATION", source="term", dictionary_id=7)
    new = []

    log = apply_verdict(
        e,
        {
            "verdict": "wrong",
            "reason": "tool",
            "suggested_canonical": "Kubernetes",
            "suggested_type": "TECHNOLOGY",
        },
        new,
    )

    assert log == 'REJECTED "t4" (was "Kubernetes Inc") (tool) -> suggested "Kubernetes" instead'
    assert e.status == "dismissed"
    assert len(new) == 1
    suggestion = new[0]
    assert suggestion is not e
    assert (suggestion.start, suggestion.end, suggestion.original_text) == (4, 9, "t4")
    assert (suggestion.canonical, suggestion.entity_type) == ("Kubernetes", "TECHNOLOGY")
    assert (suggestion.match_type, suggestion.confidence, suggestion.status) == ("llm", "medium", "suggested")
    assert (suggestion.dictionary_id, suggestion.source) == (None, "term")
    assert (suggestion.llm_validated, suggestion.llm_reason, suggestion.llm_suggested) == (True, "tool", True)


def test_wrong_suggestion_inherits_the_entity_type_and_source_when_none_given():
    e = ent(0, 3, "Anna", entity_type="PERSON", source="person")
    new = []

    apply_verdict(e, {"verdict": "wrong", "suggested_canonical": "Anne", "suggested_type": None}, new)

    assert (new[0].entity_type, new[0].source) == ("PERSON", "person")


def test_wrong_without_a_suggestion_only_dismisses():
    e = ent(0, 3, "Anna")
    new = []

    log = apply_verdict(e, {"verdict": "wrong", "reason": "r"}, new)

    assert log == 'REJECTED "t0" (was "Anna") (r)'
    assert (e.status, new) == ("dismissed", [])


@pytest.mark.parametrize("verdict", [{"verdict": "uncertain", "reason": "r"}, {"reason": "r"}, {"verdict": "maybe", "reason": "r"}])
def test_anything_else_is_uncertain_and_leaves_the_decision_fields_alone(verdict):
    e = ent(0, 3, "Anna", status="suggested", confidence="low")
    new = []

    log = apply_verdict(e, verdict, new)

    assert log == 'UNCERTAIN "t0" -> "Anna" (r)'
    assert (e.status, e.confidence, e.canonical, new) == ("suggested", "low", "Anna", [])
    assert (e.llm_validated, e.llm_reason) == (True, "r")


# -- EntityValidation.apply: verdict -> entity mapping, counts -------------------


def test_verdict_indexes_are_one_based_positions_in_the_validated_subset():
    first, second = ent(0, 3, "Anna"), ent(5, 8, "Bob")
    # Original positions 4 and 9 in a longer entity list; the model sees 1 and 2.
    v = EntityValidation([], [(4, first), (9, second)])

    outcome = v.apply({"index": 2, "verdict": "correct", "reason": "r"})

    assert (outcome.kind, outcome.llm_index, outcome.entity, outcome.decision) == ("applied", 2, second, "correct")
    assert outcome.description == 'CONFIRMED "t5" -> "Bob" (r)'
    assert (first.llm_validated, second.llm_validated) == (False, True)


def test_counts_cover_each_decision_and_unvalidated_is_the_remainder():
    a, b, c, d = (ent(i * 10, i * 10 + 3, f"E{i}") for i in range(4))
    v = validation(a, b, c, d)

    for item in (
        {"index": 1, "verdict": "correct"},
        {"index": 2, "verdict": "wrong"},
        {"index": 3, "verdict": "uncertain"},
    ):
        v.apply(item)

    assert v.counts == {"correct": 1, "wrong": 1, "uncertain": 1}
    assert v.unvalidated == 1
    assert v.skipped == 0
    assert d.llm_validated is False


@pytest.mark.parametrize(
    "item",
    [
        "a string",
        None,
        ["index", 1],
        {},
        {"index": None},
        {"index": 0},
        {"index": 3},
        {"index": -1},
        {"index": "1"},
        {"index": 1.5},
    ],
)
def test_non_dict_missing_and_out_of_range_verdicts_are_skipped(item):
    a, b = ent(0, 3, "Anna"), ent(5, 8, "Bob")
    v = validation(a, b)

    outcome = v.apply(item)

    assert outcome.kind == "skipped"
    assert v.skipped == 1
    assert v.counts == {"correct": 0, "wrong": 0, "uncertain": 0}
    assert (a.llm_validated, b.llm_validated) == (False, False)
    assert v.unvalidated == 2


def test_integer_valued_float_index_matches_like_the_int():
    a = ent(0, 3, "Anna")
    v = validation(a)

    assert v.apply({"index": 1.0, "verdict": "correct"}).kind == "applied"
    assert a.llm_validated is True


def test_duplicate_verdicts_are_each_applied_and_counted():
    a, b = ent(0, 3, "Anna"), ent(5, 8, "Bob")
    v = validation(a, b)

    v.apply({"index": 1, "verdict": "wrong", "reason": "first", "suggested_canonical": "X"})
    v.apply({"index": 1, "verdict": "wrong", "reason": "second", "suggested_canonical": "Y"})

    assert v.counts["wrong"] == 2
    assert [n.canonical for n in v.new_entities] == ["X", "Y"]
    assert a.llm_reason == "second"
    # Two counted verdicts hide the entity that never got one.
    assert v.unvalidated == 0
    assert b.llm_validated is False


def test_unknown_decision_is_counted_under_its_own_key_not_as_validated():
    a = ent(0, 3, "Anna")
    v = validation(a)

    outcome = v.apply({"index": 1, "verdict": "maybe"})

    assert (outcome.kind, outcome.decision) == ("applied", "maybe")
    assert outcome.description.startswith("UNCERTAIN")
    assert v.counts == {"correct": 0, "wrong": 0, "uncertain": 0, "maybe": 1}
    assert v.unvalidated == 1


def test_a_verdict_that_raises_is_reported_failed_and_counted_as_skipped():
    broken = ent(0, 3, "Bob A", status="ambiguous", candidates=[{"canonical": "Bob A"}])  # no "id"
    fine = ent(5, 8, "Bob")
    v = validation(broken, fine)

    failed = v.apply({"index": 1, "verdict": "correct", "suggested_canonical": "bob a"})
    after = v.apply({"index": 2, "verdict": "correct"})

    assert failed.kind == "failed"
    assert failed.llm_index == 1
    assert isinstance(failed.error, KeyError)
    assert str(failed.error) == "'id'"
    assert v.skipped == 1
    # Mutation made before the exception stays; the verdict is not counted.
    assert (broken.llm_validated, broken.canonical) == (True, "Bob A")
    assert v.counts["correct"] == 1
    assert after.kind == "applied"


def test_an_unhashable_decision_fails_after_the_entity_was_already_changed():
    a = ent(0, 3, "Anna")
    v = validation(a)

    outcome = v.apply({"index": 1, "verdict": ["correct"], "reason": "r"})

    assert outcome.kind == "failed"
    assert isinstance(outcome.error, TypeError)
    assert a.llm_validated is True
    assert v.counts == {"correct": 0, "wrong": 0, "uncertain": 0}


def test_an_unhashable_index_is_not_guarded_and_raises():
    v = validation(ent(0, 3, "Anna"))

    with pytest.raises(TypeError):
        v.apply({"index": [1], "verdict": "correct"})

    assert v.skipped == 0


# -- EntityValidation.resolve: suggestions and overlap ---------------------------


def test_resolve_without_suggestions_returns_the_same_list_untouched():
    later, earlier = ent(10, 13, "B"), ent(0, 3, "A")
    entities = [later, earlier]
    v = EntityValidation(entities, list(enumerate(entities)))
    v.apply({"index": 1, "verdict": "correct"})

    assert v.resolve() is entities
    assert entities == [later, earlier]


def test_resolve_adds_suggestions_to_the_given_list_sorted_in_place():
    a, b = ent(10, 13, "B"), ent(0, 3, "A")
    entities = [a, b]
    v = EntityValidation(entities, list(enumerate(entities)))
    v.apply({"index": 1, "verdict": "wrong", "suggested_canonical": "B2"})

    resolved = v.resolve()

    assert resolved is not entities
    # The caller's list is extended and sorted, not de-duplicated.
    assert [(e.start, e.canonical, e.status) for e in entities] == [
        (0, "A", "suggested"),
        (10, "B", "dismissed"),
        (10, "B2", "suggested"),
    ]
    assert [(e.start, e.canonical) for e in resolved] == [(0, "A"), (10, "B2")]


def test_resolve_orders_by_start_then_longest_first():
    short = ent(0, 3, "Short", status="auto-matched")
    long = ent(0, 8, "Long", status="auto-matched")
    suggestion_source = ent(20, 23, "Gone")
    v = EntityValidation([short, long, suggestion_source], [(2, suggestion_source)])
    v.apply({"index": 1, "verdict": "wrong", "suggested_canonical": "Here"})

    resolved = v.resolve()

    # The longer span wins at the same start; the short one overlaps it and is dropped.
    assert [e.canonical for e in resolved] == ["Long", "Here"]


def test_resolve_keeps_the_first_of_overlapping_non_dismissed_spans():
    first = ent(0, 6, "First", status="auto-matched")
    overlapping = ent(3, 9, "Second", status="auto-matched")
    source = ent(20, 23, "Gone")
    v = EntityValidation([first, overlapping, source], [(2, source)])
    v.apply({"index": 1, "verdict": "wrong", "suggested_canonical": "Here"})

    assert [e.canonical for e in v.resolve()] == ["First", "Here"]


def test_resolve_lets_a_non_dismissed_span_replace_a_dismissed_one_it_overlaps():
    rejected = ent(0, 6, "Rejected")
    overlapping = ent(3, 9, "Overlap", status="auto-matched")
    v = EntityValidation([rejected, overlapping], [(0, rejected)])
    v.apply({"index": 1, "verdict": "wrong", "suggested_canonical": "Fix"})

    resolved = v.resolve()

    # The dismissed span is replaced by the first non-dismissed overlapper
    # (the sort puts the suggestion first), and the later overlapper is dropped.
    assert [(e.canonical, e.status) for e in resolved] == [("Fix", "suggested")]


def test_resolve_replaces_an_already_dismissed_span_with_its_non_dismissed_overlapper():
    dismissed = ent(0, 4, "Old", status="dismissed")
    overlapping = ent(2, 9, "New", status="auto-matched")
    source = ent(20, 23, "Gone")
    v = EntityValidation([dismissed, overlapping, source], [(2, source)])
    v.apply({"index": 1, "verdict": "wrong", "suggested_canonical": "Here"})

    resolved = v.resolve()

    assert [(e.canonical, e.status) for e in resolved] == [("New", "auto-matched"), ("Here", "suggested")]


def test_resolve_keeps_a_dismissed_span_that_is_overlapped_by_another_dismissed_one():
    first = ent(0, 6, "A", status="dismissed")
    second = ent(3, 9, "B", status="dismissed")
    source = ent(20, 23, "Gone")
    v = EntityValidation([first, second, source], [(2, source)])
    v.apply({"index": 1, "verdict": "wrong", "suggested_canonical": "Here"})

    assert [e.canonical for e in v.resolve()] == ["A", "Here"]


def test_a_dismissed_overlap_after_a_kept_span_is_dropped():
    kept = ent(0, 6, "Kept", status="auto-matched")
    dismissed = ent(3, 9, "Dismissed", status="dismissed")
    source = ent(20, 23, "Gone")
    v = EntityValidation([kept, dismissed, source], [(2, source)])
    v.apply({"index": 1, "verdict": "wrong", "suggested_canonical": "Here"})

    assert [e.canonical for e in v.resolve()] == ["Kept", "Here"]
