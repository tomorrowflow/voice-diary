"""REF-121/#121: `sse_steps.StepStream`, the shared on_step → SSE bridge used by
the transcript-correction and narrative review routes.

Run inside the webapp container so deps + env match prod. From `server/`, with
the `.env` stub from DEVELOPMENT.md §7.4:

    docker compose -p vd-test run --rm --no-deps -e PYTHONDONTWRITEBYTECODE=1 -v ..:/repo -w /repo/server webapp pytest webapp/tests/test_sse_steps.py -q -p no:cacheprovider
"""

from __future__ import annotations

import asyncio
import json
import logging

from sse_steps import StepStream


def test_normal_completion_relays_steps_in_order_then_exposes_result():
    async def stage(on_step):
        on_step("step", {"step": "a", "state": "active"})
        await asyncio.sleep(0)
        on_step("log", {"message": "hi", "level": "info"})
        return "the-result"

    async def run():
        stream = StepStream(stage, failure_prefix="Stage failed")
        events = [e async for e in stream.events()]
        return stream, events

    stream, events = asyncio.run(run())

    assert events == [
        {"event": "step", "data": json.dumps({"step": "a", "state": "active"})},
        {"event": "log", "data": json.dumps({"message": "hi", "level": "info"})},
    ]
    assert stream.failed is False
    assert stream.result == "the-result"


def test_stage_exception_emits_error_event_logs_and_marks_failed(caplog):
    async def stage(on_step):
        on_step("log", {"message": "started", "level": "info"})
        raise ValueError("kaboom")

    async def run():
        stream = StepStream(stage, failure_prefix="Stage failed")
        events = [e async for e in stream.events()]
        return stream, events

    with caplog.at_level(logging.ERROR):
        stream, events = asyncio.run(run())

    assert [e["event"] for e in events] == ["log", "error"]
    assert json.loads(events[-1]["data"]) == {"message": "Stage failed: kaboom"}
    assert stream.failed is True
    assert stream.result is None
    assert any(r.exc_info and "kaboom" in str(r.exc_info[1]) for r in caplog.records)


def test_exception_after_stage_emitted_error_adds_no_second_error():
    async def stage(on_step):
        on_step("error", {"message": "Analysis failed: boom"})
        raise RuntimeError("boom")

    async def run():
        stream = StepStream(stage, failure_prefix="Stage failed")
        events = [e async for e in stream.events()]
        return stream, events

    stream, events = asyncio.run(run())

    assert [e["event"] for e in events] == ["error"]
    assert json.loads(events[0]["data"]) == {"message": "Analysis failed: boom"}
    assert stream.failed is True


def test_client_disconnect_cancels_and_awaits_the_stage():
    state = {}

    async def stage(on_step):
        state["task"] = asyncio.current_task()
        on_step("log", {"message": "started", "level": "info"})
        try:
            await asyncio.sleep(3600)
        except asyncio.CancelledError:
            state["cancelled"] = True
            raise

    async def run():
        stream = StepStream(stage, failure_prefix="Stage failed")
        agen = stream.events()
        first = await agen.__anext__()
        assert first["event"] == "log"
        await agen.aclose()
        return state["task"].done()

    assert asyncio.run(run()) is True
    assert state.get("cancelled") is True
