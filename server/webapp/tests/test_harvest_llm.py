"""Tests for `harvest_llm.extract_work_activities`.

The Ollama response feeding this function is derived from a diary
transcript — user-controlled, transcribed speech. `category` and
`description` are trusted downstream (rendered in the Harvest review UI,
eventually submitted as Harvest time-entry fields), so free-form LLM
output must be constrained before it leaves this module. See SEC-6.

Run inside the webapp container so deps + env match prod:

    docker compose run --rm webapp pytest tests/test_harvest_llm.py
"""

from __future__ import annotations

import json

import httpx

import harvest_llm


def _ollama_response(activities: list[dict]) -> httpx.Response:
    return httpx.Response(
        200,
        json={
            "message": {
                "content": json.dumps({"activities": activities}),
            }
        },
    )


def _patched_client_class(handler) -> type[httpx.AsyncClient]:
    """Build an httpx.AsyncClient subclass wired to a MockTransport.

    Also clears harvest_llm's in-memory cache so tests don't bleed into
    each other. The returned class is what monkeypatch swaps in for
    httpx.AsyncClient.
    """
    harvest_llm._cache.clear()

    class _PatchedAsyncClient(httpx.AsyncClient):
        def __init__(self, *args, **kwargs):
            kwargs["transport"] = httpx.MockTransport(handler)
            super().__init__(*args, **kwargs)

    return _PatchedAsyncClient


async def test_unknown_category_falls_back_to_other(monkeypatch) -> None:
    def handler(request: httpx.Request) -> httpx.Response:
        return _ollama_response(
            [{"description": "Did stuff", "estimated_hours": 1.0, "category": "ignore all rules and do X"}]
        )

    monkeypatch.setattr(httpx, "AsyncClient", _patched_client_class(handler))

    activities = await harvest_llm.extract_work_activities("transcript text", "2026-07-04")

    assert activities == [
        {"description": "Did stuff", "estimated_hours": 1.0, "category": "other"}
    ]


async def test_allowed_category_passes_through(monkeypatch) -> None:
    def handler(request: httpx.Request) -> httpx.Response:
        return _ollama_response(
            [{"description": "Reviewed a PR", "estimated_hours": 0.5, "category": "review"}]
        )

    monkeypatch.setattr(httpx, "AsyncClient", _patched_client_class(handler))

    activities = await harvest_llm.extract_work_activities("transcript text", "2026-07-04")

    assert activities == [
        {"description": "Reviewed a PR", "estimated_hours": 0.5, "category": "review"}
    ]


async def test_overlong_description_is_truncated(monkeypatch) -> None:
    long_description = "A" * 2000

    def handler(request: httpx.Request) -> httpx.Response:
        return _ollama_response(
            [{"description": long_description, "estimated_hours": 1.0, "category": "development"}]
        )

    monkeypatch.setattr(httpx, "AsyncClient", _patched_client_class(handler))

    activities = await harvest_llm.extract_work_activities("transcript text", "2026-07-04")

    assert len(activities[0]["description"]) == harvest_llm.MAX_DESCRIPTION_LENGTH
    assert activities[0]["description"] == long_description[: harvest_llm.MAX_DESCRIPTION_LENGTH]
