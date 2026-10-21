"""BUG-57/#57: hardening of session retry, SSE bridge cancellation, the
startup sweep's shutdown lifecycle, and the vector lookup's thread use.

Run inside the webapp container so deps + env match prod:

    docker compose run --rm webapp pytest webapp/tests/test_bug57_lifecycle.py
"""

from __future__ import annotations

import asyncio
import json
import logging
import threading

import correction
import db
import fluency_checker
import main
import narrative
import routers.review_stream as review_stream
import session_processing
import vector_store
from dictionary import DictionarySnapshot


# --- (2) SSE bridge cancellation ------------------------------------------


def test_transcript_stream_generator_close_cancels_correction_task(monkeypatch):
    state = {}

    async def fake_correct(raw_text, *, snapshot=None, on_step=None):
        state["task"] = asyncio.current_task()
        on_step("log", {"message": "started", "level": "info"})
        try:
            await asyncio.sleep(3600)
        except asyncio.CancelledError:
            state["cancelled"] = True
            raise

    monkeypatch.setattr(correction, "correct_and_detect_entities", fake_correct)
    monkeypatch.setattr(fluency_checker, "FLUENCY_CHECK_ENABLED", False)

    async def run():
        agen = review_stream._process_transcript_events("x", DictionarySnapshot())
        first = await agen.__anext__()
        assert first["event"] == "log"
        await agen.aclose()
        return state["task"].done()

    assert asyncio.run(run()) is True
    assert state.get("cancelled") is True


def test_transcript_stream_correction_failure_emits_error_and_stops(monkeypatch):
    async def fake_correct(raw_text, *, snapshot=None, on_step=None):
        raise ValueError("kaboom")

    monkeypatch.setattr(correction, "correct_and_detect_entities", fake_correct)

    async def fluency_must_not_run(text):
        raise AssertionError("must not run after a failed correction")

    monkeypatch.setattr(fluency_checker, "FLUENCY_CHECK_ENABLED", True)
    monkeypatch.setattr(fluency_checker, "check_fluency", fluency_must_not_run)

    async def run():
        return [e async for e in review_stream._process_transcript_events("x", DictionarySnapshot())]

    events = asyncio.run(run())

    assert [e["event"] for e in events] == ["error"]
    assert json.loads(events[0]["data"]) == {"message": "Transcript correction failed: kaboom"}


def test_document_stream_generator_close_cancels_narrative_task(monkeypatch):
    state = {}

    async def fake_build(text, entities, date, *, author=None, ports=None, on_step=None):
        state["task"] = asyncio.current_task()
        on_step("log", {"message": "started", "level": "info"})
        try:
            await asyncio.sleep(3600)
        except asyncio.CancelledError:
            state["cancelled"] = True
            raise

    monkeypatch.setattr(narrative, "build_day_narrative", fake_build)

    async def run():
        agen = review_stream._process_document_events(7, "t", [], "2026-05-10")
        first = await agen.__anext__()
        assert first["event"] == "log"
        await agen.aclose()
        return state["task"].done()

    assert asyncio.run(run()) is True
    assert state.get("cancelled") is True


def test_document_stream_unexpected_failure_is_logged_and_emitted(monkeypatch, caplog):
    """A raise from the narrative stage that did NOT already emit an `error`
    event (i.e. not the analysis-failure path) must be logged and surfaced."""
    async def fake_build(text, entities, date, *, author=None, ports=None, on_step=None):
        on_step("log", {"message": "started", "level": "info"})
        raise ValueError("kaboom")

    monkeypatch.setattr(narrative, "build_day_narrative", fake_build)

    async def save_must_not_run(**kwargs):
        raise AssertionError("must not save after a failed narrative")

    monkeypatch.setattr(db, "save_processed_document", save_must_not_run)

    async def run():
        return [e async for e in review_stream._process_document_events(7, "t", [], "2026-05-10")]

    with caplog.at_level(logging.ERROR):
        events = asyncio.run(run())

    assert [e["event"] for e in events] == ["log", "error"]
    assert "kaboom" in json.loads(events[-1]["data"])["message"]
    assert any("kaboom" in r.getMessage() or (r.exc_info and "kaboom" in str(r.exc_info[1]))
               for r in caplog.records)


def test_document_stream_already_reported_failure_emits_no_second_error(monkeypatch):
    async def fake_build(text, entities, date, *, author=None, ports=None, on_step=None):
        on_step("error", {"message": "Analysis failed: boom"})
        raise RuntimeError("boom")

    monkeypatch.setattr(narrative, "build_day_narrative", fake_build)

    async def run():
        return [e async for e in review_stream._process_document_events(7, "t", [], "2026-05-10")]

    events = asyncio.run(run())
    assert [e["event"] for e in events] == ["error"]


# --- (3) sweep lifecycle at shutdown --------------------------------------


def test_lifespan_cancels_and_awaits_sweep_before_closing_pool(monkeypatch):
    monkeypatch.setenv("TAILNET_IP", "100.100.100.100")
    order: list[str] = []
    state = {}

    class _Conn:
        async def execute(self, *a, **k):
            return None

    class _Acquire:
        async def __aenter__(self):
            return _Conn()

        async def __aexit__(self, *a):
            return False

    class _Pool:
        def acquire(self):
            return _Acquire()

    async def fake_get_pool():
        return _Pool()

    async def fake_close_pool():
        order.append("close_pool")
        state["task_done_at_close"] = state["task"].done()

    async def fake_vs_close():
        order.append("vector_close")

    async def fake_sweep():
        state["task"] = asyncio.current_task()
        state["started"].set()
        try:
            await asyncio.sleep(3600)
        except asyncio.CancelledError:
            order.append("sweep_cancelled")
            raise

    monkeypatch.setattr(db, "get_pool", fake_get_pool)
    monkeypatch.setattr(db, "close_pool", fake_close_pool)
    monkeypatch.setattr(vector_store, "VECTOR_SEARCH_ENABLED", False)
    monkeypatch.setattr(vector_store, "close", fake_vs_close)
    monkeypatch.setattr(
        session_processing.get_processor(), "retry_stuck_sessions_on_startup", fake_sweep
    )

    async def run():
        state["started"] = asyncio.Event()
        async with main.lifespan(main.app):
            await asyncio.wait_for(state["started"].wait(), 5)
        return main.app.state.startup_retry_sweep_task

    task = asyncio.run(run())

    assert task.cancelled() or task.done()
    assert order.index("sweep_cancelled") < order.index("close_pool")
    assert state["task_done_at_close"] is True


# --- (4) vector lookup off the event loop ---------------------------------


def test_find_similar_corrections_queries_in_a_worker_thread(monkeypatch):
    monkeypatch.setattr(vector_store, "VECTOR_SEARCH_ENABLED", True)
    seen = {}

    class _Hit:
        score = 0.9
        metadata = {"original_text": "a", "corrected_text": "b"}

    class _Client:
        def query(self, **kwargs):
            seen["thread"] = threading.current_thread()
            return [_Hit()]

    async def fake_get_client():
        return _Client()

    monkeypatch.setattr(vector_store, "_get_client", fake_get_client)

    async def run():
        loop_thread = threading.current_thread()
        result = await vector_store.find_similar_corrections("text", limit=3)
        return loop_thread, result

    loop_thread, result = asyncio.run(run())

    assert seen["thread"] is not loop_thread
    assert result[0]["original_text"] == "a"
    assert result[0]["corrected_text"] == "b"
