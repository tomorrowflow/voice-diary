"""Characterization of `llm_validator.validate_entities_stream`.

The review routes replace the whole generator in their tests, so nothing
else pins the events it emits. These tests drive the real generator with a
fake Ollama client and compare the exact log/result/error events. Only the
elapsed-time figures vary between runs; they are normalized.
"""

import asyncio
import json
import re

import pytest

import llm_validator
from entity_detector import DetectedEntity
from ollama_client import (
    ChatResponse,
    OllamaEngineError,
    OllamaTimeoutError,
    OllamaUnavailableError,
)

TEXT = "Anna hatte Acme dann Kubernetes und dazu Bob."


class FakeOllama:
    """Stands in for `llm_validator._ollama_client`."""

    def __init__(self, content=None, error=None):
        self.content = content
        self.error = error
        self.calls = []

    async def chat(self, messages, **kwargs):
        self.calls.append((messages, kwargs))
        if self.error is not None:
            raise self.error
        return ChatResponse(content=self.content, raw={})


def ent(start, end, canonical, status="suggested", confidence="medium", **kw):
    return DetectedEntity(
        start=start,
        end=end,
        original_text=TEXT[start:end],
        canonical=canonical,
        entity_type=kw.pop("entity_type", "PERSON"),
        match_type=kw.pop("match_type", "fuzzy"),
        confidence=confidence,
        status=status,
        **kw,
    )


def verdicts(*items):
    return json.dumps({"validations": list(items)})


@pytest.fixture
def ollama(monkeypatch):
    fake = FakeOllama()
    monkeypatch.setattr(llm_validator, "_ollama_client", fake)
    monkeypatch.setattr(llm_validator, "LLM_VALIDATION_ENABLED", True)
    monkeypatch.setattr(llm_validator, "OLLAMA_MODEL", "test-model")
    monkeypatch.setattr(llm_validator, "OLLAMA_BASE_URL", "http://ollama.test")
    return fake


def collect(entities, entity_usage_samples=None, text=TEXT):
    async def go():
        return [
            ev
            async for ev in llm_validator.validate_entities_stream(
                text, entities, entity_usage_samples=entity_usage_samples
            )
        ]

    return asyncio.run(go())


def logs(events):
    """(level, message) pairs of the log events, elapsed time masked."""
    out = []
    for ev in events:
        if ev["event"] == "log":
            payload = json.loads(ev["data"])
            out.append((payload["level"], re.sub(r"\d+\.\d+s", "<t>s", payload["message"])))
    return out


def result_of(events):
    last = events[-1]
    assert last["event"] == "result"
    return json.loads(last["data"])


# -- paths that never reach the model ----------------------------------------


def test_disabled_emits_warning_and_returns_entities_untouched(ollama, monkeypatch):
    monkeypatch.setattr(llm_validator, "LLM_VALIDATION_ENABLED", False)
    entities = [ent(0, 4, "Anna")]

    events = collect(entities)

    assert [e["event"] for e in events] == ["log", "result"]
    assert logs(events) == [("warn", "LLM validation disabled")]
    assert result_of(events) == [e.to_dict() for e in entities]
    assert ollama.calls == []
    assert entities[0].llm_validated is False


def test_nothing_to_validate_skips_the_model(ollama):
    entities = [ent(0, 4, "Anna", status="auto-matched", confidence="high", match_type="exact")]

    events = collect(entities)

    assert logs(events) == [
        ("info", "No entities need LLM validation (all high-confidence exact matches)")
    ]
    assert result_of(events) == [e.to_dict() for e in entities]
    assert ollama.calls == []


# -- upstream failures --------------------------------------------------------


@pytest.mark.parametrize(
    ("error", "expected"),
    [
        (OllamaUnavailableError("down"), ("error", "Ollama unreachable at http://ollama.test")),
        (OllamaTimeoutError("slow"), ("error", "Ollama timed out after <t>s")),
        (OllamaEngineError("boom"), ("error", "Ollama error: boom")),
    ],
)
def test_upstream_failure_logs_error_and_returns_entities_unchanged(ollama, error, expected):
    ollama.error = error
    entities = [ent(0, 4, "Anna")]

    events = collect(entities)

    assert [e["event"] for e in events[-2:]] == ["log", "result"]
    assert logs(events)[-1] == expected
    assert result_of(events) == [e.to_dict() for e in entities]
    assert entities[0].llm_validated is False


@pytest.mark.parametrize(
    ("content", "message"),
    [
        ("", "Empty Ollama response body"),
        ("not json", "Could not parse LLM verdicts from response"),
        ("[]", "Could not parse LLM verdicts from response"),
        ('{"a": 1, "b": 2}', "Could not parse LLM verdicts from response"),
    ],
)
def test_unusable_response_logs_error_and_returns_entities_unchanged(ollama, content, message):
    ollama.content = content
    entities = [ent(0, 4, "Anna")]

    events = collect(entities)

    assert logs(events)[-1] == ("error", message)
    assert result_of(events) == [e.to_dict() for e in entities]
    assert entities[0].llm_validated is False


# -- full run ----------------------------------------------------------------


def test_full_run_emits_exact_event_sequence_and_result(ollama):
    skipped = ent(0, 4, "Anna", status="auto-matched", confidence="high", match_type="exact")
    confirmed = ent(11, 15, "Acme GmbH", entity_type="ORGANIZATION")
    rejected = ent(21, 31, "Kubernetes Inc", entity_type="ORGANIZATION")
    unsure = ent(41, 44, "Bobby")
    ambiguous = ent(
        41,
        44,
        "Bob A",
        status="ambiguous",
        candidates=[
            {"canonical": "Bob A", "id": 1},
            {"canonical": "Bob B", "id": 2},
        ],
    )
    entities = [skipped, confirmed, rejected, unsure, ambiguous]
    ollama.content = verdicts(
        {"index": 1, "verdict": "correct", "reason": "fits"},
        {
            "index": 2,
            "verdict": "wrong",
            "reason": "is a tool",
            "suggested_canonical": "Kubernetes",
            "suggested_type": "TECHNOLOGY",
        },
        {"index": 3, "verdict": "uncertain", "reason": "unclear"},
        {"index": 4, "verdict": "correct", "reason": "bob b", "suggested_canonical": "bob b"},
    )

    events = collect(entities, entity_usage_samples={"Acme GmbH|ORGANIZATION": [{"sentence": "s"}]})

    assert [e["event"] for e in events] == ["log"] * (len(events) - 1) + ["result"]
    assert logs(events) == [
        ("info", "Filtering: 4 of 5 entities need validation"),
        ("info", '  1. "Acme" -> "Acme GmbH" [fuzzy, medium, suggested]'),
        ("info", '  2. "Kubernetes" -> "Kubernetes Inc" [fuzzy, medium, suggested]'),
        ("info", '  3. "Bob" -> "Bobby" [fuzzy, medium, suggested]'),
        ("info", '  4. "Bob" -> "Bob A" [fuzzy, medium, ambiguous]'),
        ("info", "Enriching prompt with 1 past usage samples"),
        ("info", "Building prompt for test-model..."),
        ("info", "Calling Ollama for entity validation..."),
        ("info", "Ollama responded in <t>s"),
        ("info", "Received 4 verdicts, applying..."),
        ("ok", 'CONFIRMED "Acme" -> "Acme GmbH" (fits)'),
        (
            "warn",
            'REJECTED "Kubernetes" (was "Kubernetes Inc") (is a tool)'
            ' -> suggested "Kubernetes" instead',
        ),
        ("info", 'UNCERTAIN "Bob" -> "Bobby" (unclear)'),
        ("ok", 'CONFIRMED "Bob" -> disambiguated to "Bob B" (bob b)'),
        ("ok", "Done: 2 confirmed, 1 rejected, 1 uncertain, 1 new suggestions"),
    ]
    per_entity = [json.loads(e["data"]) for e in events if e["event"] == "log"][10:14]
    assert [(p["entity_start"], p["entity_end"]) for p in per_entity] == [
        (11, 15),
        (21, 31),
        (41, 44),
        (41, 44),
    ]
    # Entities that went through the model are mutated in place.
    assert (confirmed.status, confirmed.confidence, confirmed.llm_validated) == (
        "auto-matched",
        "high",
        True,
    )
    assert (rejected.status, unsure.status, unsure.llm_reason) == ("dismissed", "suggested", "unclear")
    assert (ambiguous.canonical, ambiguous.dictionary_id, ambiguous.match_type) == ("Bob B", 2, "llm")
    assert skipped.llm_validated is False

    result = result_of(events)
    # The dismissed "Kubernetes Inc" span is superseded by the new suggestion,
    # and the later overlapping "Bob" spans collapse to the first kept one.
    assert [(r["start"], r["end"], r["canonical"], r["status"]) for r in result] == [
        (0, 4, "Anna", "auto-matched"),
        (11, 15, "Acme GmbH", "auto-matched"),
        (21, 31, "Kubernetes", "suggested"),
        (41, 44, "Bobby", "suggested"),
    ]
    assert result[2]["llm_suggested"] is True
    assert result[2]["entity_type"] == "TECHNOLOGY"
    assert result[2]["match_type"] == "llm"


def test_verdict_indexes_are_one_based_over_the_validated_subset(ollama):
    first = ent(0, 4, "Anna", status="auto-matched", confidence="high", match_type="exact")
    second = ent(11, 15, "Acme GmbH")
    third = ent(41, 44, "Bobby")
    ollama.content = verdicts({"index": 2, "verdict": "correct", "reason": "ok"})

    collect([first, second, third])

    messages, kwargs = ollama.calls[0]
    assert '1. "Acme"' in messages[1]["content"]
    assert '2. "Bob"' in messages[1]["content"]
    assert kwargs == {"format": "json", "num_ctx": llm_validator.OLLAMA_NUM_CTX}
    assert (first.llm_validated, second.llm_validated, third.llm_validated) == (False, False, True)


# -- malformed verdicts -------------------------------------------------------


def test_malformed_out_of_range_and_duplicate_verdicts(ollama):
    first = ent(11, 15, "Acme GmbH")
    second = ent(41, 44, "Bobby")
    ollama.content = verdicts(
        "just a string",
        {"verdict": "correct"},
        {"index": 0, "verdict": "correct"},
        {"index": 3, "verdict": "correct"},
        {"index": "1", "verdict": "correct"},
        {"index": 1, "verdict": "correct", "reason": "a"},
        {"index": 1, "verdict": "wrong", "reason": "b"},
    )

    events = collect([first, second])

    assert logs(events)[-4:] == [
        ("ok", 'CONFIRMED "Acme" -> "Acme GmbH" (a)'),
        ("warn", 'REJECTED "Acme" (was "Acme GmbH") (b)'),
        ("warn", "Skipped 5 unparseable verdict(s)"),
        # The duplicate counts twice, so the unanswered second entity is not
        # reported as "without verdict".
        ("ok", "Done: 1 confirmed, 1 rejected, 0 uncertain"),
    ]
    # Duplicates are applied in order; the later verdict wins on the entity.
    assert first.status == "dismissed"
    assert first.llm_reason == "b"
    assert second.llm_validated is False


def test_unknown_verdict_value_is_treated_as_uncertain_but_not_counted(ollama):
    entity = ent(11, 15, "Acme GmbH")
    ollama.content = verdicts({"index": 1, "verdict": "maybe", "reason": "hm"})

    events = collect([entity])

    assert logs(events)[-2:] == [
        ("info", 'UNCERTAIN "Acme" -> "Acme GmbH" (hm)'),
        ("ok", "Done: 0 confirmed, 0 rejected, 0 uncertain, 1 without verdict"),
    ]
    assert entity.llm_validated is True
    assert entity.status == "suggested"


def test_missing_verdict_value_defaults_to_uncertain(ollama):
    entity = ent(11, 15, "Acme GmbH")
    ollama.content = verdicts({"index": 1})

    events = collect([entity])

    assert logs(events)[-2:] == [
        ("info", 'UNCERTAIN "Acme" -> "Acme GmbH" ()'),
        ("ok", "Done: 0 confirmed, 0 rejected, 1 uncertain"),
    ]


def test_a_failing_verdict_is_logged_and_the_rest_still_apply(ollama):
    broken = ent(
        41,
        44,
        "Bob A",
        status="ambiguous",
        candidates=[{"canonical": "Bob A"}],  # no "id": raises while applying
    )
    fine = ent(11, 15, "Acme GmbH")
    ollama.content = verdicts(
        {"index": 1, "verdict": "correct", "suggested_canonical": "Bob A", "reason": "r"},
        {"index": 2, "verdict": "correct", "reason": "ok"},
    )

    events = collect([broken, fine])

    assert logs(events)[-4:] == [
        ("error", "Error processing verdict #1: 'id'"),
        ("ok", 'CONFIRMED "Acme" -> "Acme GmbH" (ok)'),
        ("warn", "Skipped 1 unparseable verdict(s)"),
        ("ok", "Done: 1 confirmed, 0 rejected, 0 uncertain, 1 without verdict"),
    ]
    # The entity was already mutated before the failure.
    assert broken.llm_validated is True
    assert broken.canonical == "Bob A"
    assert fine.status == "auto-matched"


def test_unhashable_index_aborts_the_stream_after_earlier_logs(ollama):
    entity = ent(11, 15, "Acme GmbH")
    ollama.content = verdicts(
        {"index": 1, "verdict": "correct", "reason": "ok"},
        {"index": [1], "verdict": "correct"},
    )
    seen = []

    async def go():
        async for ev in llm_validator.validate_entities_stream(TEXT, [entity]):
            seen.append(ev)

    with pytest.raises(TypeError):
        asyncio.run(go())

    assert logs(seen)[-1] == ("ok", 'CONFIRMED "Acme" -> "Acme GmbH" (ok)')


# -- new suggestions and overlap ----------------------------------------------


def test_new_suggestions_extend_and_sort_the_callers_list_in_place(ollama):
    later = ent(41, 44, "Bobby")
    earlier = ent(11, 15, "Acme GmbH")
    entities = [later, earlier]
    ollama.content = verdicts(
        {"index": 1, "verdict": "wrong", "reason": "r", "suggested_canonical": "Bob"},
        {"index": 2, "verdict": "wrong", "reason": "r", "suggested_canonical": "Acme"},
    )

    events = collect(entities)

    assert logs(events)[-1] == ("ok", "Done: 0 confirmed, 2 rejected, 0 uncertain, 2 new suggestions")
    # In-place: extended and sorted by (start, -length), not de-duplicated.
    assert [(e.start, e.canonical, e.status) for e in entities] == [
        (11, "Acme GmbH", "dismissed"),
        (11, "Acme", "suggested"),
        (41, "Bobby", "dismissed"),
        (41, "Bob", "suggested"),
    ]
    # The emitted result is the overlap-resolved list.
    assert [(r["start"], r["canonical"], r["status"]) for r in result_of(events)] == [
        (11, "Acme", "suggested"),
        (41, "Bob", "suggested"),
    ]


def test_wrong_without_suggestion_dismisses_and_adds_nothing(ollama):
    entity = ent(11, 15, "Acme GmbH")
    ollama.content = verdicts({"index": 1, "verdict": "wrong", "reason": "r"})

    events = collect([entity])

    assert logs(events)[-2:] == [
        ("warn", 'REJECTED "Acme" (was "Acme GmbH") (r)'),
        ("ok", "Done: 0 confirmed, 1 rejected, 0 uncertain"),
    ]
    assert [(r["status"], r["llm_validated"]) for r in result_of(events)] == [("dismissed", True)]
