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
from types import SimpleNamespace

import correction
import db
import fluency_checker
import main
import narrative
import routers.sessions as sessions_router
import vector_store


def _art(transcript_id: int):
    return SimpleNamespace(transcript_id=transcript_id)


def _doc(doc_id: int, markdown: str, *, ingested: bool, metadata=None) -> dict:
    return {
        "id": doc_id,
        "document_markdown": markdown,
        "metadata": metadata if metadata is not None else {"date": "2026-07-01"},
        "lightrag_ingested": ingested,
    }


def _stub_retry_db(monkeypatch, docs_by_transcript: dict[int, dict]):
    ingested: list[tuple[str, dict]] = []
    marked: list[int] = []

    async def fake_get_latest(transcript_id):
        return docs_by_transcript[transcript_id]

    async def fake_sync_and_ingest(markdown, metadata, *, lightrag_client=None):
        ingested.append((markdown, metadata))
        return {}

    async def fake_mark(doc_id):
        marked.append(doc_id)

    monkeypatch.setattr(db, "get_latest_processed_document", fake_get_latest)
    monkeypatch.setattr(sessions_router.narrative, "sync_and_ingest", fake_sync_and_ingest)
    monkeypatch.setattr(db, "mark_document_ingested", fake_mark)
    return ingested, marked


# --- (1) ingest-only shortcut ---------------------------------------------


def test_retry_shortcut_declines_when_a_latest_document_diverges(monkeypatch):
    """One segment's latest document is a different (single-segment) narrative
    than the whole-session one: must re-analyze, not ingest docs[0] and mark
    both rows ingested."""
    ingested, marked = _stub_retry_db(
        monkeypatch,
        {
            1: _doc(10, "# whole session", ingested=False),
            2: _doc(11, "# single segment only", ingested=False),
        },
    )

    result = asyncio.run(sessions_router._retry_via_saved_document([_art(1), _art(2)]))

    assert result is False
    assert ingested == []
    assert marked == []


def test_retry_shortcut_declines_when_metadata_diverges(monkeypatch):
    ingested, marked = _stub_retry_db(
        monkeypatch,
        {
            1: _doc(10, "# same", ingested=False, metadata={"date": "2026-07-01"}),
            2: _doc(11, "# same", ingested=False, metadata={"date": "2026-07-02"}),
        },
    )

    assert asyncio.run(sessions_router._retry_via_saved_document([_art(1), _art(2)])) is False
    assert ingested == [] and marked == []


def test_retry_shortcut_ingests_identical_unmarked_documents_once(monkeypatch):
    ingested, marked = _stub_retry_db(
        monkeypatch,
        {
            1: _doc(10, "# whole session", ingested=False, metadata='{"date": "2026-07-01"}'),
            2: _doc(11, "# whole session", ingested=False),
        },
    )

    assert asyncio.run(sessions_router._retry_via_saved_document([_art(1), _art(2)])) is True
    assert ingested == [("# whole session", {"date": "2026-07-01"})]
    assert marked == [10, 11]


def test_retry_shortcut_marks_only_the_remainder_when_some_rows_already_marked(monkeypatch):
    """A previous run ingested the narrative then died part-way through
    marking: the marked rows prove the ingest happened, so mark the rest
    without re-ingesting."""
    ingested, marked = _stub_retry_db(
        monkeypatch,
        {
            1: _doc(10, "# whole session", ingested=True),
            2: _doc(11, "# whole session", ingested=False),
            3: _doc(12, "# whole session", ingested=False),
        },
    )

    result = asyncio.run(sessions_router._retry_via_saved_document([_art(1), _art(2), _art(3)]))

    assert result is True
    assert ingested == []
    assert marked == [11, 12]


def test_retry_shortcut_declines_when_all_marked_or_any_missing(monkeypatch):
    ingested, marked = _stub_retry_db(
        monkeypatch,
        {1: _doc(10, "# a", ingested=True), 2: _doc(11, "# a", ingested=True)},
    )
    assert asyncio.run(sessions_router._retry_via_saved_document([_art(1), _art(2)])) is False

    _stub_retry_db(monkeypatch, {1: _doc(10, "# a", ingested=False), 2: None})
    assert asyncio.run(sessions_router._retry_via_saved_document([_art(1), _art(2)])) is False
    assert ingested == [] and marked == []


# --- (2) SSE bridge cancellation ------------------------------------------


def test_transcript_stream_generator_close_cancels_correction_task(monkeypatch):
    state = {}

    async def fake_correct(raw_text, *, persons, terms, text_corrections=None,
                           dismissals=None, on_step=None):
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
        agen = main._process_transcript_events("x", [], [], [], [])
        first = await agen.__anext__()
        assert first["event"] == "log"
        await agen.aclose()
        return state["task"].done()

    assert asyncio.run(run()) is True
    assert state.get("cancelled") is True


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
        agen = main._process_document_events(7, "t", [], "2026-05-10")
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
        return [e async for e in main._process_document_events(7, "t", [], "2026-05-10")]

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
        return [e async for e in main._process_document_events(7, "t", [], "2026-05-10")]

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
    monkeypatch.setattr(sessions_router, "retry_stuck_sessions_on_startup", fake_sweep)

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
