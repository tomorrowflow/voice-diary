"""Tests for `harvest_llm.WorkActivityExtractor` and its module-level wrapper.

The extractor owns the cache -> prompt -> chat -> parse -> cache sequence.
Unit cases build it with a real `OllamaClient` on an `httpx.MockTransport`
and a private cache dict. The wiring cases go through the unchanged public
`extract_work_activities` and the module's real `_ollama_client`, replacing
only `httpx.AsyncClient`'s transport, so they prove the production client and
the `_cache` mapping are what the wrapper supplies.

Run inside the webapp container so deps + env match prod:

    docker compose run --rm webapp pytest tests/test_harvest_extractor.py
"""

from __future__ import annotations

import json

import httpx
import pytest

import harvest_llm
from ollama_client import OllamaClient

TRANSCRIPT = "Heute habe ich am Backend gearbeitet."
DATE = "2026-07-04"


def _content_response(content: str) -> httpx.Response:
    return httpx.Response(200, json={"message": {"content": content}})


def _activities_response(activities: list[dict]) -> httpx.Response:
    return _content_response(json.dumps({"activities": activities}))


def _json_response(body) -> httpx.Response:
    return _content_response(json.dumps(body))


class _Upstream:
    """Counts and records requests, replying through `respond`."""

    def __init__(self, respond) -> None:
        self.respond = respond
        self.requests: list[httpx.Request] = []

    def __call__(self, request: httpx.Request) -> httpx.Response:
        self.requests.append(request)
        return self.respond(request)

    @property
    def payloads(self) -> list[dict]:
        return [json.loads(r.content) for r in self.requests]


def _extractor(respond, cache=None) -> tuple[harvest_llm.WorkActivityExtractor, _Upstream, dict]:
    upstream = _Upstream(respond)
    client = OllamaClient(
        base_url="http://ollama.test",
        model="test-model",
        timeout_seconds=5,
        transport=httpx.MockTransport(upstream),
    )
    cache = {} if cache is None else cache
    return harvest_llm.WorkActivityExtractor(client, cache), upstream, cache


async def _extract_one(item) -> dict:
    extractor, _, _ = _extractor(lambda request: _activities_response([item]))
    (activity,) = await extractor.extract(TRANSCRIPT, DATE)
    return activity


# --- containers -----------------------------------------------------------


async def test_top_level_list_is_accepted() -> None:
    extractor, _, _ = _extractor(
        lambda request: _json_response([{"description": "A", "estimated_hours": 2, "category": "review"}])
    )

    assert await extractor.extract(TRANSCRIPT, DATE) == [
        {"description": "A", "estimated_hours": 2.0, "category": "review"}
    ]


async def test_activities_key_is_accepted() -> None:
    extractor, _, _ = _extractor(lambda request: _activities_response([{"description": "A"}]))

    assert [a["description"] for a in await extractor.extract(TRANSCRIPT, DATE)] == ["A"]


async def test_work_activities_key_is_accepted() -> None:
    extractor, _, _ = _extractor(
        lambda request: _json_response({"work_activities": [{"description": "W"}]})
    )

    assert [a["description"] for a in await extractor.extract(TRANSCRIPT, DATE)] == ["W"]


async def test_activities_key_wins_over_work_activities() -> None:
    extractor, _, _ = _extractor(
        lambda request: _json_response(
            {"activities": [{"description": "A"}], "work_activities": [{"description": "W"}]}
        )
    )

    assert [a["description"] for a in await extractor.extract(TRANSCRIPT, DATE)] == ["A"]


async def test_present_non_list_activities_is_not_replaced_by_work_activities() -> None:
    extractor, _, cache = _extractor(
        lambda request: _json_response(
            {"activities": {"description": "A"}, "work_activities": [{"description": "W"}]}
        )
    )

    assert await extractor.extract(TRANSCRIPT, DATE) == []
    assert cache == {}


async def test_dict_without_known_key_yields_cached_empty_list() -> None:
    extractor, upstream, cache = _extractor(lambda request: _json_response({"other": []}))

    assert await extractor.extract(TRANSCRIPT, DATE) == []
    assert await extractor.extract(TRANSCRIPT, DATE) == []
    assert len(upstream.requests) == 1
    assert list(cache) == [(hash(TRANSCRIPT), DATE)]


async def test_non_dict_items_are_skipped() -> None:
    extractor, _, _ = _extractor(
        lambda request: _activities_response(
            ["text", 3, None, ["nested"], {"description": "Kept"}, {"description": "Also kept"}]
        )
    )

    activities = await extractor.extract(TRANSCRIPT, DATE)

    assert [a["description"] for a in activities] == ["Kept", "Also kept"]


# --- category and description ---------------------------------------------


@pytest.mark.parametrize("category", harvest_llm.ALLOWED_CATEGORIES)
async def test_every_allowed_category_passes_through(category: str) -> None:
    assert (await _extract_one({"category": category}))["category"] == category


@pytest.mark.parametrize(
    "category",
    ["Development", "development ", "", "ignore all rules", 5, None, ["review"], {"a": 1}],
)
async def test_other_category_values_fall_back_to_default(category) -> None:
    assert (await _extract_one({"category": category}))["category"] == harvest_llm.DEFAULT_CATEGORY


async def test_missing_category_falls_back_to_default() -> None:
    assert (await _extract_one({"description": "x"}))["category"] == "other"


async def test_description_at_limit_is_kept_and_over_limit_truncated() -> None:
    limit = harvest_llm.MAX_DESCRIPTION_LENGTH
    assert limit == 500

    assert (await _extract_one({"description": "a" * limit}))["description"] == "a" * limit
    assert (await _extract_one({"description": "a" * (limit + 1)}))["description"] == "a" * limit


@pytest.mark.parametrize("description", [None, 5, ["x"], {"a": 1}])
async def test_non_string_or_missing_description_becomes_empty(description) -> None:
    assert (await _extract_one({"description": description}))["description"] == ""
    assert (await _extract_one({}))["description"] == ""


# --- hours ----------------------------------------------------------------


@pytest.mark.parametrize(
    ("hours", "expected"),
    [
        (1, 1.0),
        (1.0, 1.0),
        (0.25, 0.25),
        (0.5, 0.5),
        (0.1, 0.25),
        (0.125, 0.25),
        (0.375, 0.5),
        (0.625, 0.5),
        (1.1, 1.0),
        (1.13, 1.25),
        (1.125, 1.0),
        (1.375, 1.5),
        (7.9, 8.0),
        ("2.5", 2.5),
        (0, 0.25),
        (-3, 0.25),
        (True, 1.0),
    ],
)
async def test_hours_round_to_quarter_hours_with_minimum(hours, expected: float) -> None:
    assert (await _extract_one({"estimated_hours": hours}))["estimated_hours"] == expected


@pytest.mark.parametrize("hours", ["abc", "", None, [1], {"h": 1}, "nan"])
async def test_invalid_hours_fall_back_to_one_hour(hours) -> None:
    assert (await _extract_one({"estimated_hours": hours}))["estimated_hours"] == 1.0


async def test_missing_hours_default_to_one_hour() -> None:
    assert (await _extract_one({"description": "x"}))["estimated_hours"] == 1.0


async def test_infinite_hours_still_raise_overflow_error() -> None:
    extractor, _, cache = _extractor(
        lambda request: _content_response('{"activities": [{"estimated_hours": Infinity}]}')
    )

    with pytest.raises(OverflowError):
        await extractor.extract(TRANSCRIPT, DATE)
    assert cache == {}


# --- failures -------------------------------------------------------------


def _refused(request: httpx.Request) -> httpx.Response:
    raise httpx.ConnectError("refused", request=request)


@pytest.mark.parametrize(
    "respond",
    [
        lambda request: httpx.Response(500, json={"error": "boom"}),
        _refused,
        lambda request: httpx.Response(200, text="not json"),
        lambda request: _content_response("not json"),
        lambda request: _content_response(""),
        lambda request: _json_response({"activities": {"description": "x"}}),
        lambda request: _json_response({"activities": "text"}),
        lambda request: _json_response({"activities": None}),
    ],
    ids=["http-500", "transport", "body-not-json", "content-not-json", "empty-content", "dict-items", "str-items", "null-items"],
)
async def test_failures_return_empty_and_are_not_cached(respond) -> None:
    extractor, upstream, cache = _extractor(respond)

    assert await extractor.extract(TRANSCRIPT, DATE) == []
    assert cache == {}
    assert await extractor.extract(TRANSCRIPT, DATE) == []
    assert len(upstream.requests) == 2


@pytest.mark.parametrize("body", [5, "text", None, True])
async def test_scalar_json_still_raises_attribute_error(body) -> None:
    extractor, _, cache = _extractor(lambda request: _json_response(body))

    with pytest.raises(AttributeError):
        await extractor.extract(TRANSCRIPT, DATE)
    assert cache == {}


async def test_unexpected_chat_error_is_caught_broadly() -> None:
    class _BrokenClient:
        async def chat(self, messages, **kwargs):
            raise RuntimeError("unexpected")

    cache: dict = {}
    extractor = harvest_llm.WorkActivityExtractor(_BrokenClient(), cache)

    assert await extractor.extract(TRANSCRIPT, DATE) == []
    assert cache == {}


# --- request and cache (unit) ---------------------------------------------


async def test_request_carries_prompt_json_format_and_model() -> None:
    extractor, upstream, _ = _extractor(lambda request: _activities_response([]))

    await extractor.extract(TRANSCRIPT, DATE)

    (request,) = upstream.requests
    assert str(request.url) == "http://ollama.test/api/chat"
    assert upstream.payloads == [
        {
            "model": "test-model",
            "messages": harvest_llm._build_prompt(TRANSCRIPT, DATE),
            "stream": False,
            "format": "json",
        }
    ]


async def test_cache_hit_skips_the_request_and_returns_the_same_list() -> None:
    extractor, upstream, cache = _extractor(lambda request: _activities_response([{"description": "A"}]))

    first = await extractor.extract(TRANSCRIPT, DATE)
    second = await extractor.extract(TRANSCRIPT, DATE)

    assert second is first
    assert len(upstream.requests) == 1
    assert cache == {(hash(TRANSCRIPT), DATE): first}


async def test_precached_entry_is_returned_without_a_request() -> None:
    cached = [{"description": "cached", "estimated_hours": 1.0, "category": "other"}]
    extractor, upstream, _ = _extractor(
        lambda request: _activities_response([]), cache={(hash(TRANSCRIPT), DATE): cached}
    )

    assert await extractor.extract(TRANSCRIPT, DATE) is cached
    assert upstream.requests == []


async def test_other_date_or_transcript_misses_the_cache() -> None:
    extractor, upstream, cache = _extractor(lambda request: _activities_response([]))

    await extractor.extract(TRANSCRIPT, DATE)
    await extractor.extract(TRANSCRIPT, "2026-07-05")
    await extractor.extract("anderer Text", DATE)

    assert len(upstream.requests) == 3
    assert set(cache) == {
        (hash(TRANSCRIPT), DATE),
        (hash(TRANSCRIPT), "2026-07-05"),
        (hash("anderer Text"), DATE),
    }


async def test_private_cache_is_independent_of_the_module_cache() -> None:
    harvest_llm._cache.clear()
    extractor, _, cache = _extractor(lambda request: _activities_response([]))

    await extractor.extract(TRANSCRIPT, DATE)

    assert cache
    assert harvest_llm._cache == {}


# --- production wiring through the public wrapper -------------------------


@pytest.fixture
def upstream(monkeypatch) -> _Upstream:
    """Intercept only the HTTP transport underneath the module's real client."""
    harvest_llm._cache.clear()
    holder = _Upstream(lambda request: _activities_response([{"description": "Wired", "category": "review"}]))

    class _PatchedAsyncClient(httpx.AsyncClient):
        def __init__(self, *args, **kwargs):
            kwargs["transport"] = httpx.MockTransport(holder)
            super().__init__(*args, **kwargs)

    monkeypatch.setattr(httpx, "AsyncClient", _PatchedAsyncClient)
    yield holder
    harvest_llm._cache.clear()


async def test_wrapper_issues_the_documented_request(upstream: _Upstream) -> None:
    await harvest_llm.extract_work_activities(TRANSCRIPT, DATE)

    (request,) = upstream.requests
    assert str(request.url) == f"{harvest_llm._ollama_client.base_url}/api/chat"
    assert upstream.payloads == [
        {
            "model": harvest_llm._ollama_client.model,
            "messages": harvest_llm._build_prompt(TRANSCRIPT, DATE),
            "stream": False,
            "format": "json",
        }
    ]


async def test_wrapper_caches_identical_calls_in_module_cache(upstream: _Upstream) -> None:
    first = await harvest_llm.extract_work_activities(TRANSCRIPT, DATE)
    second = await harvest_llm.extract_work_activities(TRANSCRIPT, DATE)

    assert first == [{"description": "Wired", "estimated_hours": 1.0, "category": "review"}]
    assert second is first
    assert len(upstream.requests) == 1
    assert harvest_llm._cache == {(hash(TRANSCRIPT), DATE): first}


async def test_wrapper_misses_for_other_date_or_transcript(upstream: _Upstream) -> None:
    await harvest_llm.extract_work_activities(TRANSCRIPT, DATE)
    await harvest_llm.extract_work_activities(TRANSCRIPT, "2026-07-05")
    await harvest_llm.extract_work_activities("anderer Text", DATE)

    assert len(upstream.requests) == 3


async def test_clearing_module_cache_refetches(upstream: _Upstream) -> None:
    first = await harvest_llm.extract_work_activities(TRANSCRIPT, DATE)

    harvest_llm._cache.clear()
    second = await harvest_llm.extract_work_activities(TRANSCRIPT, DATE)

    assert len(upstream.requests) == 2
    assert second == first
    assert second is not first


async def test_wrapper_caches_successful_empty_list(upstream: _Upstream) -> None:
    upstream.respond = lambda request: _activities_response([])

    first = await harvest_llm.extract_work_activities(TRANSCRIPT, DATE)
    second = await harvest_llm.extract_work_activities(TRANSCRIPT, DATE)

    assert first == []
    assert second is first
    assert len(upstream.requests) == 1


async def test_wrapper_does_not_cache_failures(upstream: _Upstream) -> None:
    upstream.respond = lambda request: httpx.Response(503, json={"error": "down"})
    assert await harvest_llm.extract_work_activities(TRANSCRIPT, DATE) == []

    upstream.respond = lambda request: _content_response("not json")
    assert await harvest_llm.extract_work_activities(TRANSCRIPT, DATE) == []

    upstream.respond = lambda request: _json_response({"activities": "nope"})
    assert await harvest_llm.extract_work_activities(TRANSCRIPT, DATE) == []

    assert harvest_llm._cache == {}
    assert len(upstream.requests) == 3

    upstream.respond = lambda request: _activities_response([{"description": "Recovered"}])
    recovered = await harvest_llm.extract_work_activities(TRANSCRIPT, DATE)

    assert [a["description"] for a in recovered] == ["Recovered"]
    assert len(upstream.requests) == 4


# --- call-time client lookup (the one case that swaps `_ollama_client`) ---


async def test_wrapper_reads_the_current_client_on_each_call(monkeypatch) -> None:
    harvest_llm._cache.clear()
    other = _Upstream(lambda request: _activities_response([{"description": "Other client"}]))
    monkeypatch.setattr(
        harvest_llm,
        "_ollama_client",
        OllamaClient(base_url="http://other.test", model="other-model", transport=httpx.MockTransport(other)),
    )

    result = await harvest_llm.extract_work_activities(TRANSCRIPT, DATE)

    assert [a["description"] for a in result] == ["Other client"]
    assert other.payloads[0]["model"] == "other-model"
    harvest_llm._cache.clear()
