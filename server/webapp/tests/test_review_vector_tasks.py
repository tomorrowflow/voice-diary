"""BUG-116: `submit_review` must retain its vector-store write until it
finishes and surface its failure.

The route is awaited directly: `TestClient` without a `with` block tears its
event loop down after each request, which would cancel the background task
and hide exactly what these tests check.
"""

from __future__ import annotations

import asyncio
import logging

import pytest

import db
import main
import vector_store


class _FakeRequest:
    def __init__(self, body: dict) -> None:
        self._body = body

    async def json(self) -> dict:
        return self._body


BODY = {
    "corrected_transcript": "Martin fährt nach Berlin.",
    "date": "2026-10-18",
    "entities": [
        {
            "text": "Martin", "original": "Tomas", "type": "PERSON", "source": "person",
            "start": 0, "end": 6, "is_correction": True, "dictionary_id": 7,
        },
    ],
    "text_edits": [{"oldWord": "Berlim", "newWord": "Berlin"}],
}


@pytest.fixture(autouse=True)
def _stub_db(monkeypatch: pytest.MonkeyPatch) -> None:
    async def noop(*args, **kwargs):
        return None

    monkeypatch.setattr(db, "save_draft", noop)
    monkeypatch.setattr(db, "save_text_correction", noop)
    monkeypatch.setattr(db, "log_review_action", noop)
    monkeypatch.setattr(vector_store, "VECTOR_SEARCH_ENABLED", True)


def test_vector_write_is_retained_and_completes_after_response(monkeypatch):
    calls: list[str] = []
    release = asyncio.Event()

    async def delete_transcript_vectors(transcript_id):
        await release.wait()
        calls.append("delete")

    async def store_correction_context(**kwargs):
        calls.append(kwargs["correction_type"])

    async def store_entity_sample(**kwargs):
        calls.append("entity_sample")

    monkeypatch.setattr(vector_store, "delete_transcript_vectors", delete_transcript_vectors)
    monkeypatch.setattr(vector_store, "store_correction_context", store_correction_context)
    monkeypatch.setattr(vector_store, "store_entity_sample", store_entity_sample)

    async def run():
        response = await main.submit_review(5, _FakeRequest(BODY))
        pending = set(main._review_vector_tasks)
        in_flight = calls[:]
        release.set()
        await asyncio.gather(*pending)
        await asyncio.sleep(0)  # let the done callback run
        return response, pending, in_flight

    response, pending, in_flight = asyncio.run(run())

    assert response == {"status": "submitted"}
    assert len(pending) == 1
    assert in_flight == []
    assert calls == ["delete", "text_edit", "entity_correction", "entity_sample"]
    assert main._review_vector_tasks == set()


def test_failing_vector_write_is_logged_and_released(monkeypatch, caplog):
    async def delete_transcript_vectors(transcript_id):
        raise RuntimeError("qdrant down")

    monkeypatch.setattr(vector_store, "delete_transcript_vectors", delete_transcript_vectors)

    async def run():
        response = await main.submit_review(5, _FakeRequest(BODY))
        pending = set(main._review_vector_tasks)
        await asyncio.gather(*pending, return_exceptions=True)
        await asyncio.sleep(0)
        return response

    with caplog.at_level(logging.WARNING, logger=main.logger.name):
        response = asyncio.run(run())

    assert response == {"status": "submitted"}
    assert any(
        "Failed to store vectors for transcript 5" in r.getMessage()
        and "qdrant down" in r.getMessage()
        and r.exc_info is not None
        for r in caplog.records
    )
    assert main._review_vector_tasks == set()
