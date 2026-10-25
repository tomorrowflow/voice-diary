"""Tests for `transcript_corrector` — the contextual LLM transcript correction.

Characterization tests pin the exact output of the prompt -> chat -> parse ->
apply pipeline, quirks included (cascading and overlapping suggestions,
replacement-relative positions), so refactors cannot change behavior unnoticed.
The default-wiring tests go through the real `correct_transcript` and the real
`OllamaClient.chat` over `httpx.MockTransport`; no live Ollama is needed.

Run inside the webapp container so deps match prod:

    docker compose run --rm webapp pytest tests/test_transcript_corrector.py
"""

from __future__ import annotations

import hashlib
import importlib.util
import json
import logging
from pathlib import Path

import httpx
import pytest

import correction
import transcript_corrector
import vector_store
from dictionary import DictionarySnapshot
from ollama_client import OllamaClient
from transcript_corrector import (
    TranscriptCorrector,
    _build_messages,
    _parse_corrections,
    apply_llm_corrections,
    correct_transcript,
)


def _c(original: str, corrected: str, reason: str = "") -> dict:
    return {"original": original, "corrected": corrected, "reason": reason}


def _applied(original: str, corrected: str, start: int, end: int, reason: str = "") -> dict:
    return {
        "original": original,
        "corrected": corrected,
        "reason": reason,
        "start": start,
        "end": end,
    }


# --- apply_llm_corrections: ordering and positions ------------------------


def test_repeated_words_are_all_replaced_in_position_order() -> None:
    text, applied = apply_llm_corrections(
        "Der Staat und der staat, Staat!", [_c("Staat", "Start", "hom")]
    )

    assert text == "Der Start und der Start, Start!"
    assert applied == [
        _applied("Staat", "Start", 4, 9, "hom"),
        _applied("Staat", "Start", 18, 23, "hom"),
        _applied("Staat", "Start", 25, 30, "hom"),
    ]


def test_matching_is_case_insensitive_and_uses_the_suggested_replacement_verbatim() -> None:
    text, applied = apply_llm_corrections("STAAT staat Staat", [_c("staat", "Start")])

    assert text == "Start Start Start"
    assert [(a["start"], a["end"]) for a in applied] == [(0, 5), (6, 11), (12, 17)]


def test_unicode_words_match_on_word_boundaries() -> None:
    text, applied = apply_llm_corrections(
        "Über Größe und größe Ärger",
        [_c("größe", "Grösse"), _c("Ärger", "Aerger")],
    )

    assert text == "Über Grösse und Grösse Aerger"
    assert applied == [
        _applied("größe", "Grösse", 5, 11),
        _applied("größe", "Grösse", 15, 21),
        _applied("Ärger", "Aerger", 23, 29),
    ]


def test_original_is_not_matched_inside_a_longer_word() -> None:
    text, applied = apply_llm_corrections("Staatsrat Staat", [_c("Staat", "Start")])

    assert text == "Staatsrat Start"
    assert applied == [_applied("Staat", "Start", 10, 15)]


def test_regex_metacharacters_in_original_are_escaped() -> None:
    text, applied = apply_llm_corrections("Kosten 3.5 und 3x5", [_c("3.5", "drei")])

    assert text == "Kosten drei und 3x5"
    assert applied == [_applied("3.5", "drei", 7, 11)]


def test_original_that_starts_with_punctuation_never_gets_a_leading_word_boundary() -> None:
    text, applied = apply_llm_corrections(
        "Preis (neu) a+b? und a+b?", [_c("a+b?", "x"), _c("(neu)", "alt")]
    )

    assert text == "Preis (neu) a+b? und a+b?"
    assert applied == []


def test_overlapping_suggestions_apply_the_longer_original_first() -> None:
    text, applied = apply_llm_corrections(
        "Das ist der neue Stand heute",
        [_c("der neue", "die alte"), _c("neue Stand", "frischer Stand")],
    )

    assert text == "Das ist der frischer Stand heute"
    assert applied == [_applied("neue Stand", "frischer Stand", 12, 26)]


def test_cascading_suggestions_rewrite_text_produced_by_an_earlier_replacement() -> None:
    text, applied = apply_llm_corrections("Eins zwei", [_c("Eins", "zwei"), _c("zwei", "drei")])

    assert text == "drei drei"
    assert applied == [
        _applied("Eins", "zwei", 0, 4),
        _applied("zwei", "drei", 0, 4),
        _applied("zwei", "drei", 5, 9),
    ]


def test_equal_length_originals_keep_the_order_they_were_suggested_in() -> None:
    suggestions = [_c("cd", "xy"), _c("ab", "zz")]

    text, applied = apply_llm_corrections("ab cd ab", suggestions)

    assert text == "zz xy zz"
    assert applied == [
        _applied("ab", "zz", 0, 2),
        _applied("cd", "xy", 3, 5),
        _applied("ab", "zz", 6, 8),
    ]
    assert apply_llm_corrections("ab cd ab", list(reversed(suggestions))) == (text, applied)


def test_equal_start_positions_keep_their_application_order() -> None:
    text, applied = apply_llm_corrections("aa bb", [_c("aa", "bb"), _c("bb", "cc")])

    assert text == "cc cc"
    assert [(a["original"], a["start"]) for a in applied] == [("aa", 0), ("bb", 0), ("bb", 3)]


def test_length_changing_replacement_positions_are_relative_to_the_replacement() -> None:
    text, applied = apply_llm_corrections(
        "a b a bb", [_c("a", "langer text"), _c("bb", "c")]
    )

    assert text == "langer text b langer text c"
    assert applied == [
        _applied("a", "langer text", 0, 11),
        _applied("a", "langer text", 4, 15),
        _applied("bb", "c", 6, 7),
    ]


def test_duplicate_suggestions_only_apply_the_first_one() -> None:
    text, applied = apply_llm_corrections(
        "Haus Haus", [_c("Haus", "Heim", "r1"), _c("Haus", "Hof", "r2")]
    )

    assert text == "Heim Heim"
    assert applied == [
        _applied("Haus", "Heim", 0, 4, "r1"),
        _applied("Haus", "Heim", 5, 9, "r1"),
    ]


def test_missing_reason_defaults_to_empty_string() -> None:
    _, applied = apply_llm_corrections("foo bar", [{"original": "foo", "corrected": "baz"}])

    assert applied == [_applied("foo", "baz", 0, 3)]


def test_no_corrections_or_no_matches_return_the_text_unchanged() -> None:
    assert apply_llm_corrections("foo bar", []) == ("foo bar", [])
    assert apply_llm_corrections("foo bar", [_c("nicht da", "x")]) == ("foo bar", [])


# --- _parse_corrections: wire shapes --------------------------------------


def test_parse_accepts_a_wrapped_object_and_a_bare_list() -> None:
    wrapped = json.dumps({"corrections": [_c("a", "b", "r")]})
    bare = json.dumps([{"original": "a", "corrected": "b"}])

    assert _parse_corrections(wrapped) == [_c("a", "b", "r")]
    assert _parse_corrections(bare) == [_c("a", "b")]


def test_parse_drops_same_word_empty_and_non_dict_entries_and_defaults_reason() -> None:
    payload = json.dumps(
        {
            "corrections": [
                {"original": "a", "corrected": "a"},
                {"original": "", "corrected": "b"},
                {"original": "a", "corrected": ""},
                "x",
                3,
                {"original": "x", "corrected": "y", "reason": "r"},
                {"original": "p", "corrected": "q"},
            ]
        }
    )

    assert _parse_corrections(payload) == [_c("x", "y", "r"), _c("p", "q")]


@pytest.mark.parametrize(
    "payload",
    ["not json", "", '{"foo": 1}', '"str"', "7", "[]", '{"corrections": []}',
     '{"corrections": {"a": 1}}', '{"corrections": "abc"}'],
)
def test_parse_returns_empty_for_invalid_or_unusable_shapes(payload: str) -> None:
    assert _parse_corrections(payload) == []


def test_parse_keeps_non_string_fields_untouched() -> None:
    assert _parse_corrections('{"corrections": [{"original": 1, "corrected": 2}]}') == [
        _c(1, 2)  # type: ignore[arg-type]
    ]


@pytest.mark.parametrize("payload", ['{"corrections": null}', '{"corrections": 5}'])
def test_parse_raises_on_a_non_iterable_corrections_value(payload: str) -> None:
    with pytest.raises(TypeError):
        _parse_corrections(payload)


# --- _build_messages: prompt bytes ----------------------------------------


def test_system_prompt_is_unchanged() -> None:
    digest = hashlib.sha256(transcript_corrector.SYSTEM_PROMPT.encode()).hexdigest()

    assert digest == "2be5e5a36086b704a832bdb6e9c03f57217b0835ef9ae32d15a667e10096535c"


def test_messages_without_examples_are_system_prompt_plus_bare_transcript() -> None:
    assert _build_messages("Hallo Welt") == [
        {"role": "system", "content": transcript_corrector.SYSTEM_PROMPT},
        {"role": "user", "content": "TRANSCRIPT:\nHallo Welt"},
    ]
    assert _build_messages("Hallo Welt", []) == _build_messages("Hallo Welt")


def test_messages_list_few_shot_examples_in_order_with_optional_context() -> None:
    examples = [
        {
            "original_text": "Staat",
            "corrected_text": "Start",
            "context_before": "der ",
            "context_after": " heute",
        },
        {"original_text": "Wahl", "corrected_text": "Wal"},
    ]

    user = _build_messages("Text", examples)[1]["content"]

    assert user == (
        "Past corrections in similar contexts:\n"
        '- "Staat" → "Start" (context: ...der [Staat] heute...)\n'
        '- "Wahl" → "Wal"\n'
        "\n"
        "TRANSCRIPT:\nText"
    )


# --- correct_transcript over mock HTTP ------------------------------------


class _Ollama:
    """Records `/api/chat` request bodies and answers with a canned handler."""

    def __init__(self, handler=None) -> None:
        self.bodies: list[dict] = []
        self._handler = handler

    def __call__(self, request: httpx.Request) -> httpx.Response:
        assert request.url.path == "/api/chat"
        self.bodies.append(json.loads(request.read()))
        if self._handler is not None:
            return self._handler(request)
        raise AssertionError("no handler")

    def client(self) -> OllamaClient:
        return OllamaClient(
            base_url="http://ollama.test",
            model="qwen-test",
            timeout_seconds=5.0,
            transport=httpx.MockTransport(self),
        )


def _reply(content: str):
    return lambda request: httpx.Response(200, json={"message": {"content": content}})


def _wire(monkeypatch: pytest.MonkeyPatch, handler) -> _Ollama:
    ollama = _Ollama(handler)
    monkeypatch.setattr(transcript_corrector, "LLM_CORRECTION_ENABLED", True)
    monkeypatch.setattr(transcript_corrector, "OLLAMA_NUM_CTX", 4096)
    monkeypatch.setattr(transcript_corrector, "_ollama_client", ollama.client())
    return ollama


async def test_correct_transcript_sends_prompt_json_format_and_context_window(monkeypatch) -> None:
    reply = json.dumps({"corrections": [_c("Staat", "Start", "Homophon")]})
    ollama = _wire(monkeypatch, _reply(reply))
    examples = [
        {
            "original_text": "Wahl",
            "corrected_text": "Wal",
            "context_before": "der ",
            "context_after": " singt",
        }
    ]

    text, applied = await correct_transcript("Der Staat beginnt.", correction_examples=examples)

    assert text == "Der Start beginnt."
    assert applied == [_applied("Staat", "Start", 4, 9, "Homophon")]
    assert ollama.bodies == [
        {
            "model": "qwen-test",
            "messages": _build_messages("Der Staat beginnt.", examples),
            "stream": False,
            "format": "json",
            "options": {"num_ctx": 4096},
        }
    ]
    assert ollama.bodies[0]["messages"][1]["content"].startswith(
        "Past corrections in similar contexts:\n"
        '- "Wahl" → "Wal" (context: ...der [Wahl] singt...)\n'
    )


async def test_correct_transcript_without_examples_sends_only_the_transcript(monkeypatch) -> None:
    ollama = _wire(monkeypatch, _reply('{"corrections": []}'))

    result = await correct_transcript("Hallo")

    assert result == ("Hallo", [])
    assert ollama.bodies[0]["messages"][1]["content"] == "TRANSCRIPT:\nHallo"


async def test_correct_transcript_applies_a_bare_list_reply(monkeypatch) -> None:
    _wire(monkeypatch, _reply(json.dumps([{"original": "Staat", "corrected": "Start"}])))

    assert await correct_transcript("Staat Staat") == (
        "Start Start",
        [_applied("Staat", "Start", 0, 5), _applied("Staat", "Start", 6, 11)],
    )


async def test_correct_transcript_applies_cascading_suggestions_from_the_model(monkeypatch) -> None:
    reply = json.dumps({"corrections": [_c("Eins", "zwei"), _c("zwei", "drei")]})
    _wire(monkeypatch, _reply(reply))

    text, applied = await correct_transcript("Eins zwei")

    assert text == "drei drei"
    assert [(a["original"], a["start"], a["end"]) for a in applied] == [
        ("Eins", 0, 4),
        ("zwei", 0, 4),
        ("zwei", 5, 9),
    ]


async def test_correct_transcript_honors_the_flag_at_call_time_without_calling_ollama(
    monkeypatch, caplog
) -> None:
    ollama = _wire(monkeypatch, _reply("unused"))
    monkeypatch.setattr(transcript_corrector, "LLM_CORRECTION_ENABLED", False)

    with caplog.at_level(logging.INFO, logger="transcript_corrector"):
        result = await correct_transcript("Der Staat")

    assert result == ("Der Staat", [])
    assert ollama.bodies == []
    assert "LLM transcript correction disabled" in caplog.text


@pytest.mark.parametrize(
    "content, logged",
    [
        ("", "Empty Ollama response for transcript correction"),
        ('{"corrections": []}', "LLM found no transcript corrections"),
        ("not json", "LLM returned invalid JSON"),
        ('{"unexpected": true}', "Unexpected LLM response structure"),
    ],
)
async def test_unusable_model_output_returns_the_raw_text(
    monkeypatch, caplog, content: str, logged: str
) -> None:
    _wire(monkeypatch, _reply(content))

    with caplog.at_level(logging.INFO, logger="transcript_corrector"):
        result = await correct_transcript("Der Staat")

    assert result == ("Der Staat", [])
    assert logged in caplog.text


def _raise(exc: Exception):
    def handler(request: httpx.Request) -> httpx.Response:
        raise exc

    return handler


@pytest.mark.parametrize(
    "handler, logged",
    [
        (_raise(httpx.ConnectError("refused")), "Ollama unreachable at"),
        (_raise(httpx.ReadTimeout("slow")), "Ollama transcript correction timed out after"),
        (
            lambda request: httpx.Response(500, json={"error": "boom"}),
            "Ollama error for transcript correction: ollama 500: boom",
        ),
        (
            lambda request: httpx.Response(200, content=b"<html>"),
            "Ollama error for transcript correction: invalid JSON from ollama",
        ),
    ],
    ids=["connection", "timeout", "status", "bad-wire-json"],
)
async def test_typed_ollama_errors_fall_back_to_the_raw_text(
    monkeypatch, caplog, handler, logged: str
) -> None:
    ollama = _wire(monkeypatch, handler)

    with caplog.at_level(logging.INFO, logger="transcript_corrector"):
        result = await correct_transcript("Der Staat")

    assert result == ("Der Staat", [])
    assert len(ollama.bodies) == 1
    assert logged in caplog.text


async def test_malformed_corrections_value_propagates_to_the_caller(monkeypatch) -> None:
    _wire(monkeypatch, _reply('{"corrections": null}'))

    with pytest.raises(TypeError):
        await correct_transcript("Der Staat")


# --- TranscriptCorrector: the explicit client ------------------------------


async def test_corrector_uses_its_own_client_and_context_window_not_module_state(
    monkeypatch,
) -> None:
    module_side = _wire(monkeypatch, _reply("unused"))
    mine = _Ollama(_reply(json.dumps({"corrections": [_c("Staat", "Start")]})))
    corrector = TranscriptCorrector(mine.client(), num_ctx=777)

    text, applied = await corrector.correct("Der Staat", correction_examples=None)

    assert (text, applied) == ("Der Start", [_applied("Staat", "Start", 4, 9)])
    assert module_side.bodies == []
    assert mine.bodies == [
        {
            "model": "qwen-test",
            "messages": _build_messages("Der Staat"),
            "stream": False,
            "format": "json",
            "options": {"num_ctx": 777},
        }
    ]


async def test_corrector_does_not_consult_the_module_enabled_flag(monkeypatch) -> None:
    monkeypatch.setattr(transcript_corrector, "LLM_CORRECTION_ENABLED", False)
    ollama = _Ollama(_reply(json.dumps({"corrections": [_c("Staat", "Start")]})))

    text, _ = await TranscriptCorrector(ollama.client(), num_ctx=1).correct("Staat")

    assert text == "Start"
    assert len(ollama.bodies) == 1


async def test_corrector_falls_back_to_the_raw_text_on_a_typed_error() -> None:
    ollama = _Ollama(_raise(httpx.ConnectError("refused")))

    result = await TranscriptCorrector(ollama.client(), num_ctx=1).correct("Der Staat")

    assert result == ("Der Staat", [])


async def test_module_entry_point_reads_client_and_context_window_on_every_call(
    monkeypatch,
) -> None:
    first = _wire(monkeypatch, _reply('{"corrections": []}'))
    await correct_transcript("eins")

    second = _Ollama(_reply('{"corrections": []}'))
    monkeypatch.setattr(transcript_corrector, "_ollama_client", second.client())
    monkeypatch.setattr(transcript_corrector, "OLLAMA_NUM_CTX", 2048)
    await correct_transcript("zwei")

    assert [b["options"] for b in first.bodies] == [{"num_ctx": 4096}]
    assert [b["options"] for b in second.bodies] == [{"num_ctx": 2048}]


# --- import-time configuration --------------------------------------------


def _import_fresh_module():
    path = Path(transcript_corrector.__file__)
    spec = importlib.util.spec_from_file_location("transcript_corrector_fresh", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


@pytest.mark.parametrize(
    "env, expected",
    [
        ({}, True),
        ({"LLM_VALIDATION_ENABLED": "false"}, False),
        ({"LLM_CORRECTION_ENABLED": "false"}, False),
        ({"LLM_CORRECTION_ENABLED": "true", "LLM_VALIDATION_ENABLED": "false"}, True),
        ({"LLM_CORRECTION_ENABLED": "TRUE"}, True),
        ({"LLM_CORRECTION_ENABLED": "yes"}, False),
    ],
)
def test_enabled_flag_precedence_is_resolved_at_import(monkeypatch, env, expected) -> None:
    monkeypatch.delenv("LLM_CORRECTION_ENABLED", raising=False)
    monkeypatch.delenv("LLM_VALIDATION_ENABLED", raising=False)
    for key, value in env.items():
        monkeypatch.setenv(key, value)

    assert _import_fresh_module().LLM_CORRECTION_ENABLED is expected


def test_default_client_and_context_window_come_from_the_environment(monkeypatch) -> None:
    monkeypatch.setenv("OLLAMA_BASE_URL", "http://ollama.example:1234")
    monkeypatch.setenv("OLLAMA_MODEL", "some-model")
    monkeypatch.setenv("OLLAMA_TIMEOUT", "7")
    monkeypatch.setenv("OLLAMA_NUM_CTX", "999")

    module = _import_fresh_module()

    assert module.OLLAMA_NUM_CTX == 999
    assert module._ollama_client.base_url == "http://ollama.example:1234"
    assert module._ollama_client.model == "some-model"


# --- through the unchanged consumer ---------------------------------------


async def test_llm_corrections_reach_correction_result_through_the_real_consumer(
    monkeypatch,
) -> None:
    reply = json.dumps({"corrections": [_c("Staat", "Start", "Homophon")]})
    ollama = _wire(monkeypatch, _reply(reply))
    monkeypatch.setattr(vector_store, "VECTOR_SEARCH_ENABLED", False)

    result = await correction.correct_and_detect_entities(
        "Der Staat beginnt.", snapshot=DictionarySnapshot()
    )

    assert result.corrected_text == "Der Start beginnt."
    assert result.llm_corrections == [_applied("Staat", "Start", 4, 9, "Homophon")]
    assert result.applied_corrections == []
    assert result.entities == []
    assert len(ollama.bodies) == 1
    assert ollama.bodies[0]["messages"] == _build_messages("Der Staat beginnt.")
