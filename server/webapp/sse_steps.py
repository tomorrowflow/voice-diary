"""Bridge a callback-shaped step stage into an async-generator SSE stream.

`correction.correct_and_detect_entities` and `narrative.build_day_narrative`
report progress through an `on_step(event, data)` callback. The review SSE
routes need those events as an async generator, so the stage runs as a
background task while `StepStream.events()` drains its queue — the client sees
events as they happen instead of all at once at the end.

Usage:

    stream = StepStream(lambda on_step: stage(..., on_step=on_step),
                        failure_prefix="Document generation failed")
    async with aclosing(stream.events()) as events:
        async for event in events:
            yield event
    if stream.failed:
        return
    result = stream.result
"""

from __future__ import annotations

import asyncio
import json
import logging
from collections.abc import AsyncIterator, Awaitable, Callable
from typing import Generic, TypeVar

logger = logging.getLogger(__name__)

T = TypeVar("T")

OnStep = Callable[[str, dict], None]


class StepStream(Generic[T]):
    """One-shot bridge: `events()` yields SSE event dicts, then `result` holds
    the stage's return value.

    If the stage raises without having emitted an `error` step itself, `events()`
    logs it and yields one `error` event (`"<failure_prefix>: <exc>"`) and sets
    `failed`. If it already emitted an `error` step, no second one is added;
    `failed` is still set. If the consumer closes the generator early (client
    disconnect), the stage task is cancelled and awaited — which only happens
    promptly if the caller closes `events()` itself, hence `aclosing` above.
    """

    def __init__(self, run: Callable[[OnStep], Awaitable[T]], *, failure_prefix: str):
        self._run = run
        self._failure_prefix = failure_prefix
        self.result: T | None = None
        self.failed = False

    async def events(self) -> AsyncIterator[dict]:
        queue: asyncio.Queue = asyncio.Queue()
        done = object()

        def on_step(event: str, data: dict) -> None:
            queue.put_nowait((event, data))

        async def run_stage() -> T:
            try:
                return await self._run(on_step)
            finally:
                queue.put_nowait(done)

        task = asyncio.create_task(run_stage())

        error_relayed = False
        try:
            while True:
                item = await queue.get()
                if item is done:
                    break
                event, data = item
                error_relayed = error_relayed or event == "error"
                yield {"event": event, "data": json.dumps(data)}

            try:
                self.result = await task
            except Exception as e:
                self.failed = True
                if error_relayed:
                    # The stage already emitted the matching `error` event
                    # before raising.
                    return
                logger.exception("%s", self._failure_prefix)
                yield {"event": "error", "data": json.dumps({"message": f"{self._failure_prefix}: {e}"})}
        finally:
            # Client disconnect closes the generator mid-drain; don't leave the
            # stage (possibly a several-minute LLM call) running with nobody
            # listening.
            if not task.done():
                task.cancel()
            await asyncio.gather(task, return_exceptions=True)
