"""Tests for `fluency_checker`.

Run inside the webapp container so deps + env match prod:

    docker compose run --rm webapp pytest tests/test_fluency_checker.py

Two layers are covered. The pure parsing and locating rules are pinned
directly. The production path (`check_fluency` with the module's real default
`OllamaClient`) is driven over an intercepted httpx transport, so the prompt,
the request, the fallbacks and the annotations are all asserted without a live
Ollama. `FluencyChecker` is compared against that wrapper for identical output.
"""

from __future__ import annotations

import hashlib
import json
import logging

import httpx
import pytest

import fluency_checker
from fluency_checker import FluencyChecker, check_fluency, locate_issues, _parse_issues
from ollama_client import OllamaClient

# sha256 of SYSTEM_PROMPT as shipped; a prompt edit must be a deliberate change.
SYSTEM_PROMPT_SHA256 = "08dcae154462f1af38473ff002b09ad5c3fdea0412ed986e1d168c026ed0e0d4"


def _reply(content: str) -> httpx.Response:
    return httpx.Response(200, json={"message": {"content": content}})


def _issues_reply(*issues: dict) -> httpx.Response:
    return _reply(json.dumps({"issues": list(issues)}))


class _Wire:
    """Intercepted HTTP transport that records each request it receives."""

    def __init__(self, respond) -> None:
        self._respond = respond
        self.requests: list[httpx.Request] = []

    def __call__(self, request: httpx.Request) -> httpx.Response:
        self.requests.append(request)
        return self._respond(request)

    @property
    def transport(self) -> httpx.MockTransport:
        return httpx.MockTransport(self)

    @property
    def bodies(self) -> list[dict]:
        return [json.loads(r.content) for r in self.requests]


def _raise(exc: Exception):
    def respond(request: httpx.Request) -> httpx.Response:
        raise exc

    return respond


@pytest.fixture
def production(monkeypatch):
    """Route the module's real default client through an intercepted transport."""

    def install(respond, *, enabled: bool = True, num_ctx: int = 4096) -> _Wire:
        wire = _Wire(respond)
        monkeypatch.setattr(fluency_checker, "FLUENCY_CHECK_ENABLED", enabled)
        monkeypatch.setattr(fluency_checker, "OLLAMA_NUM_CTX", num_ctx)
        monkeypatch.setattr(fluency_checker._ollama_client, "_transport", wire.transport)
        return wire

    return install


def _service(respond, *, num_ctx: int = 4096) -> tuple[FluencyChecker, _Wire]:
    wire = _Wire(respond)
    client = OllamaClient(
        base_url="http://ollama.test",
        model="qwen2.5:14b",
        timeout_seconds=5.0,
        transport=wire.transport,
    )
    return FluencyChecker(client, num_ctx), wire


TRANSCRIPT = "Ich wollte heute, ähm, also das Projekt. Dann kam der Anruf. Ich wollte heute."


# --- locate_issues --------------------------------------------------------


def _issue(text: str, **extra) -> dict:
    return {"text": text, "category": "incomplete", "note": "n", **extra}


def test_locate_exact_match_gives_start_and_end() -> None:
    located = locate_issues(TRANSCRIPT, [_issue("Dann kam der Anruf.")])

    assert located == [
        {"start": 41, "end": 60, "text": "Dann kam der Anruf.", "category": "incomplete", "note": "n"}
    ]
    assert TRANSCRIPT[41:60] == "Dann kam der Anruf."


def test_locate_exact_match_wins_over_earlier_case_variant() -> None:
    text = "ich wollte. Ich wollte."

    [hit] = locate_issues(text, [_issue("Ich wollte.")])

    assert hit["start"] == 12


def test_locate_falls_back_to_case_insensitive_search() -> None:
    [hit] = locate_issues("dann kam der anruf.", [_issue("Dann KAM der Anruf.")])

    assert (hit["start"], hit["end"]) == (0, 19)
    assert hit["text"] == "Dann KAM der Anruf."


def test_locate_uses_first_occurrence_of_a_repeated_quote() -> None:
    [hit] = locate_issues(TRANSCRIPT, [_issue("Ich wollte heute")])

    assert hit["start"] == 0
    assert TRANSCRIPT.count("Ich wollte heute") == 2


def test_locate_drops_quotes_that_are_not_in_the_transcript() -> None:
    located = locate_issues(
        TRANSCRIPT,
        [_issue("gibt es nicht"), _issue("Dann kam der Anruf."), _issue("auch nicht")],
    )

    assert [i["text"] for i in located] == ["Dann kam der Anruf."]


def test_locate_keeps_the_order_of_the_input_not_the_position() -> None:
    located = locate_issues(TRANSCRIPT, [_issue("Dann kam"), _issue("Ich wollte heute,")])

    assert [i["start"] for i in located] == [41, 0]


def test_locate_positions_count_unicode_code_points() -> None:
    text = "Ä 😀 öh, also ähm genau"

    [hit] = locate_issues(text, [_issue("ähm genau")])
    [emoji] = locate_issues(text, [_issue("😀")])

    assert (hit["start"], hit["end"]) == (13, 22)
    assert text[hit["start"] : hit["end"]] == "ähm genau"
    assert (emoji["start"], emoji["end"]) == (2, 3)


def test_locate_case_fallback_handles_non_ascii_letters() -> None:
    [hit] = locate_issues("so ÄHM, also", [_issue("ähm, ALSO")])

    assert (hit["start"], hit["end"]) == (3, 12)


def test_locate_returns_empty_for_no_issues() -> None:
    assert locate_issues(TRANSCRIPT, []) == []


def test_locate_passes_category_and_note_through() -> None:
    [hit] = locate_issues(
        TRANSCRIPT, [{"text": "Dann kam", "category": "run_on", "note": "weil"}]
    )

    assert (hit["category"], hit["note"]) == ("run_on", "weil")


def test_locate_with_non_string_quote_raises_as_before() -> None:
    with pytest.raises(TypeError):
        locate_issues(TRANSCRIPT, [{"text": 123, "category": "x", "note": ""}])


# --- _parse_issues --------------------------------------------------------


def test_parse_object_form() -> None:
    parsed = _parse_issues(json.dumps({"issues": [{"text": "a", "category": "run_on", "note": "n"}]}))

    assert parsed == [{"text": "a", "category": "run_on", "note": "n"}]


def test_parse_bare_list_form() -> None:
    parsed = _parse_issues(json.dumps([{"text": "a", "category": "run_on", "note": "n"}]))

    assert parsed == [{"text": "a", "category": "run_on", "note": "n"}]


def test_parse_defaults_missing_category_and_note() -> None:
    assert _parse_issues(json.dumps({"issues": [{"text": "a"}]})) == [
        {"text": "a", "category": "broken_syntax", "note": ""}
    ]


def test_parse_keeps_explicit_null_category_and_note() -> None:
    parsed = _parse_issues(json.dumps({"issues": [{"text": "a", "category": None, "note": None}]}))

    assert parsed == [{"text": "a", "category": None, "note": None}]


def test_parse_drops_items_without_usable_text() -> None:
    items = [{"text": ""}, {"text": None}, {"category": "x"}, "text", 5, None, ["a"], {"text": "ok"}]

    assert [i["text"] for i in _parse_issues(json.dumps({"issues": items}))] == ["ok"]


def test_parse_keeps_order() -> None:
    items = [{"text": "b"}, {"text": "a"}, {"text": "c"}]

    assert [i["text"] for i in _parse_issues(json.dumps(items))] == ["b", "a", "c"]


def test_parse_ignores_extra_fields() -> None:
    [parsed] = _parse_issues(json.dumps([{"text": "a", "start": 9, "extra": True}]))

    assert set(parsed) == {"text", "category", "note"}


@pytest.mark.parametrize("body", ["not json", "", "{'issues': []}", '{"issues": [}'])
def test_parse_invalid_json_gives_no_issues(body: str, caplog) -> None:
    with caplog.at_level(logging.WARNING, logger="fluency_checker"):
        assert _parse_issues(body) == []

    assert "invalid JSON" in caplog.text


@pytest.mark.parametrize("body", ['{"foo": 1}', '{"issue": []}', '"text"', "5", "null", "true"])
def test_parse_unexpected_structure_gives_no_issues(body: str, caplog) -> None:
    with caplog.at_level(logging.WARNING, logger="fluency_checker"):
        assert _parse_issues(body) == []

    assert "unexpected response structure" in caplog.text


def test_parse_string_issues_value_yields_nothing() -> None:
    assert _parse_issues('{"issues": "abc"}') == []


@pytest.mark.parametrize("body", ['{"issues": null}', '{"issues": 5}', '{"issues": true}'])
def test_parse_non_iterable_issues_raises_as_before(body: str) -> None:
    with pytest.raises(TypeError):
        _parse_issues(body)


def test_parse_dict_issues_value_iterates_keys_and_yields_nothing() -> None:
    assert _parse_issues('{"issues": {"text": "a"}}') == []


# --- production path: check_fluency over the real default client ----------


async def test_check_fluency_sends_the_prompt_format_and_context(production) -> None:
    wire = production(lambda request: _issues_reply())

    await check_fluency(TRANSCRIPT)

    [request] = wire.requests
    [body] = wire.bodies
    assert request.method == "POST"
    assert request.url.path == "/api/chat"
    assert body["model"] == fluency_checker._ollama_client.model
    assert body["format"] == "json"
    assert body["stream"] is False
    assert body["options"] == {"num_ctx": 4096}
    system, user = body["messages"]
    assert system["role"] == "system"
    assert hashlib.sha256(system["content"].encode()).hexdigest() == SYSTEM_PROMPT_SHA256
    assert user == {"role": "user", "content": f"TRANSCRIPT:\n{TRANSCRIPT}"}
    assert len(body["messages"]) == 2


async def test_check_fluency_returns_located_annotations(production) -> None:
    production(
        lambda request: _issues_reply(
            {"text": "ähm, also das Projekt.", "category": "incomplete", "note": "trails off"},
            {"text": "ich wollte heute", "category": "false_start", "note": "restart"},
            {"text": "never said", "category": "run_on", "note": "dropped"},
            {"text": "Dann kam der Anruf."},
        )
    )

    issues = await check_fluency(TRANSCRIPT)

    assert issues == [
        {
            "start": 18,
            "end": 40,
            "text": "ähm, also das Projekt.",
            "category": "incomplete",
            "note": "trails off",
        },
        {
            "start": 0,
            "end": 16,
            "text": "ich wollte heute",
            "category": "false_start",
            "note": "restart",
        },
        {
            "start": 41,
            "end": 60,
            "text": "Dann kam der Anruf.",
            "category": "broken_syntax",
            "note": "",
        },
    ]


async def test_check_fluency_accepts_a_bare_list_reply(production) -> None:
    production(lambda request: _reply(json.dumps([{"text": "Dann kam", "note": "x"}])))

    assert await check_fluency(TRANSCRIPT) == [
        {"start": 41, "end": 49, "text": "Dann kam", "category": "broken_syntax", "note": "x"}
    ]


async def test_check_fluency_reads_context_window_at_call_time(production) -> None:
    wire = production(lambda request: _issues_reply(), num_ctx=2048)
    await check_fluency("eins")

    fluency_checker.OLLAMA_NUM_CTX = 8192
    await check_fluency("zwei")

    assert [b["options"]["num_ctx"] for b in wire.bodies] == [2048, 8192]


async def test_check_fluency_reads_the_client_at_call_time(production, monkeypatch) -> None:
    production(lambda request: pytest.fail("the replaced client must be used"))
    swapped = _Wire(lambda request: _issues_reply({"text": "zwei"}))
    other = OllamaClient(
        base_url="http://other.test", model="m", timeout_seconds=1.0, transport=swapped.transport
    )
    monkeypatch.setattr(fluency_checker, "_ollama_client", other)

    issues = await check_fluency("eins zwei")

    assert [i["text"] for i in issues] == ["zwei"]
    assert str(swapped.requests[0].url) == "http://other.test/api/chat"


async def test_check_fluency_disabled_makes_no_http_call(production, caplog) -> None:
    wire = production(lambda request: _issues_reply({"text": "eins"}), enabled=False)

    with caplog.at_level(logging.INFO, logger="fluency_checker"):
        assert await check_fluency("eins") == []

    assert wire.requests == []
    assert "Fluency check disabled" in caplog.text


async def test_check_fluency_reads_the_enabled_flag_at_call_time(production) -> None:
    wire = production(lambda request: _issues_reply(), enabled=False)
    await check_fluency("eins")

    fluency_checker.FLUENCY_CHECK_ENABLED = True
    await check_fluency("eins")

    assert len(wire.requests) == 1


@pytest.mark.parametrize(
    "response",
    [
        httpx.Response(200, json={"message": {"content": ""}}),
        httpx.Response(200, json={}),
        httpx.Response(200, json={"message": {}}),
        httpx.Response(200, json=[]),
    ],
    ids=["empty-content", "empty-object", "empty-message", "non-object"],
)
async def test_check_fluency_empty_response_gives_no_issues(production, response, caplog) -> None:
    production(lambda request: response)

    with caplog.at_level(logging.WARNING, logger="fluency_checker"):
        assert await check_fluency("eins") == []

    assert "Empty Ollama response for fluency check" in caplog.text


@pytest.mark.parametrize(
    ("respond", "logged"),
    [
        (_raise(httpx.ConnectError("refused")), "unreachable"),
        (_raise(httpx.ReadTimeout("slow")), "timed out"),
        (lambda request: httpx.Response(503, json={"error": "busy"}), "Ollama error"),
        (lambda request: httpx.Response(200, content=b"<html>not json"), "Ollama error"),
        (_raise(httpx.ReadError("reset")), "Ollama error"),
    ],
    ids=["connect", "timeout", "status", "invalid-wire-json", "transport-error"],
)
async def test_check_fluency_upstream_failures_give_no_issues(
    production, respond, logged, caplog
) -> None:
    production(respond)

    with caplog.at_level(logging.WARNING, logger="fluency_checker"):
        assert await check_fluency("eins") == []

    assert logged in caplog.text


async def test_check_fluency_logs_the_configured_endpoint_when_unreachable(
    production, caplog
) -> None:
    production(_raise(httpx.ConnectError("refused")))

    with caplog.at_level(logging.WARNING, logger="fluency_checker"):
        await check_fluency("eins")

    assert f"Ollama unreachable at {fluency_checker.OLLAMA_BASE_URL}" in caplog.text


async def test_check_fluency_invalid_model_json_gives_no_issues(production) -> None:
    production(lambda request: _reply("Sorry, no JSON today"))

    assert await check_fluency("eins") == []


async def test_check_fluency_all_quotes_unfound_gives_no_issues(production) -> None:
    production(lambda request: _issues_reply({"text": "xyz"}))

    assert await check_fluency("eins") == []


async def test_check_fluency_malformed_issue_shape_raises_as_before(production) -> None:
    production(lambda request: _reply('{"issues": null}'))

    with pytest.raises(TypeError):
        await check_fluency("eins")


async def test_check_fluency_non_string_quote_raises_as_before(production) -> None:
    production(lambda request: _issues_reply({"text": 123}))

    with pytest.raises(TypeError):
        await check_fluency("eins")


# --- FluencyChecker is what check_fluency delegates to --------------------


REPLIES = {
    "object": _issues_reply(
        {"text": "also das Projekt", "category": "incomplete", "note": "n"},
        {"text": "ICH WOLLTE", "category": "false_start", "note": "m"},
        {"text": "nirgends"},
    ),
    "list": _reply(json.dumps([{"text": "Dann kam"}])),
    "defaults": _issues_reply({"text": "Anruf"}),
    "none-found": _issues_reply(),
    "invalid-json": _reply("???"),
    "wrong-structure": _reply('{"foo": 1}'),
    "empty": _reply(""),
    "status": httpx.Response(500, json={"error": "boom"}),
    "wire-garbage": httpx.Response(200, content=b"garbage"),
}


@pytest.mark.parametrize("name", REPLIES)
async def test_service_matches_the_module_entry_point(name: str, production) -> None:
    respond = lambda request: REPLIES[name]  # noqa: E731
    production(respond, num_ctx=4096)
    service, _ = _service(respond, num_ctx=4096)

    assert await service.check(TRANSCRIPT) == await check_fluency(TRANSCRIPT)


@pytest.mark.parametrize(
    "exc", [httpx.ConnectError("x"), httpx.ReadTimeout("x"), httpx.ReadError("x")]
)
async def test_service_matches_the_module_entry_point_on_transport_failure(
    exc, production
) -> None:
    production(_raise(exc))
    service, _ = _service(_raise(exc))

    assert await service.check(TRANSCRIPT) == await check_fluency(TRANSCRIPT) == []


async def test_service_uses_its_own_client_and_context_window(production) -> None:
    prod_wire = production(lambda request: pytest.fail("module client must not be used"))
    service, wire = _service(lambda request: _issues_reply({"text": "zwei"}), num_ctx=777)

    issues = await service.check("eins zwei")

    assert issues == [
        {"start": 5, "end": 9, "text": "zwei", "category": "broken_syntax", "note": ""}
    ]
    assert prod_wire.requests == []
    [body] = wire.bodies
    assert body["options"] == {"num_ctx": 777}
    assert body["format"] == "json"
    assert body["messages"] == fluency_checker._build_messages("eins zwei")


async def test_service_does_not_consult_the_enabled_flag(production) -> None:
    production(lambda request: _issues_reply(), enabled=False)
    service, wire = _service(lambda request: _issues_reply({"text": "eins"}))

    assert [i["text"] for i in await service.check("eins")] == ["eins"]
    assert len(wire.requests) == 1


async def test_service_reuses_one_instance_across_calls() -> None:
    service, wire = _service(lambda request: _issues_reply({"text": "b"}))

    first = await service.check("a b")
    second = await service.check("b a")

    assert [i["start"] for i in first] == [2]
    assert [i["start"] for i in second] == [0]
    assert len(wire.requests) == 2
