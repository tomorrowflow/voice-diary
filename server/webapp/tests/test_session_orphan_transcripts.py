"""Tests for removing orphan transcripts at startup (FTR-06, FTR-03, #205, SPEC
§10.6.1): in the same reconciliation pass that settles interrupted recoveries,
a session's transcript row that no segment references is deleted; one a segment
references is never touched.

Driven through `SessionIngest.sweep` (the startup entry point) with the shared
fakes from `session_helpers`: the in-memory repository's restart
(`fresh_ingest(repository=...)`), the segment pipeline's `transcripts` table,
and the narrative stage. Run inside the webapp container, see DEVELOPMENT.md
§7.4.
"""

from __future__ import annotations

import asyncio
import logging
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

import db
from tests.session_helpers import stage_bundle, stub_transcripts
from tests.test_session_interrupted_recovery import _restart, _save_transcript, _stored, _transcribing
from tests.test_session_recovery import SESSION, World, _failed, _manifest, _pending, _processed

OTHER = "2026-07-01T14:00:00+02:00"


def _name(segment_id: str, session_id: str = SESSION) -> str:
    return f"{session_id}::{segment_id}.m4a"


def _delete_calls(monkeypatch) -> list[list[int]]:
    """Every `db.delete_transcripts` call, as the ids it was given; the call
    still goes through to the fake table."""
    calls: list[list[int]] = []
    working = db.delete_transcripts

    async def recording(ids):
        calls.append(list(ids))
        await working(ids)

    monkeypatch.setattr(db, "delete_transcripts", recording)
    return calls


def test_an_orphan_transcript_is_removed_and_logged_with_its_id_and_the_count(
    monkeypatch, tmp_path, caplog,
):
    world = World(monkeypatch, tmp_path, [_processed("s01", 5)], state="done")
    world.pipeline.transcript_rows.update({_name("s01"): 5, _name("s02"): 99})
    restarted = _restart(monkeypatch, world)

    with caplog.at_level(logging.INFO):
        asyncio.run(restarted.sweep())

    assert world.pipeline.transcript_rows == {_name("s01"): 5}
    messages = [record.getMessage() for record in caplog.records]
    assert any("99" in m and "orphan transcript" in m for m in messages)
    assert any("removed 1 orphan transcript" in m for m in messages)
    assert world.pipeline.transcribe_calls == []


def test_transcripts_a_segment_references_are_kept_in_every_session_and_status(
    monkeypatch, tmp_path,
):
    world = World(
        monkeypatch, tmp_path,
        [_processed("s01", 5), _pending("s02", 6), _failed("s03")], state="partial",
    )
    stage_bundle(monkeypatch, tmp_path, OTHER, _manifest(OTHER, ["s01"]))
    world.ingests.add(OTHER, "done", [_processed("s01", 7)])
    world.pipeline.transcript_rows.update(
        {_name("s01"): 5, _name("s02"): 6, _name("s01", OTHER): 7}
    )
    stub_transcripts(monkeypatch, [5, 6, 7])
    calls = _delete_calls(monkeypatch)
    restarted = _restart(monkeypatch, world)

    asyncio.run(restarted.sweep())

    assert calls == []
    assert world.pipeline.transcript_rows == {
        _name("s01"): 5, _name("s02"): 6, _name("s01", OTHER): 7,
    }


def test_a_pass_with_no_orphans_changes_nothing(monkeypatch, tmp_path, caplog):
    world = World(monkeypatch, tmp_path, [_processed("s01", 5)], state="done")
    world.pipeline.transcript_rows[_name("s01")] = 5
    calls = _delete_calls(monkeypatch)
    restarted = _restart(monkeypatch, world)
    before = [dict(s) for s in world.ingests.rows[SESSION]["segments"]]

    with caplog.at_level(logging.INFO):
        asyncio.run(restarted.sweep())

    assert calls == []
    assert world.pipeline.transcript_rows == {_name("s01"): 5}
    assert world.ingests.rows[SESSION]["segments"] == before
    assert world.ingests.updates == []
    assert not any("orphan" in record.getMessage() for record in caplog.records)


def test_a_second_pass_finds_nothing_left_to_remove(monkeypatch, tmp_path):
    world = World(monkeypatch, tmp_path, [_processed("s01", 5)], state="done")
    world.pipeline.transcript_rows.update({_name("s01"): 5, _name("s02"): 99, _name("s03"): 98})
    calls = _delete_calls(monkeypatch)
    restarted = _restart(monkeypatch, world)

    async def run():
        await restarted.sweep()
        await restarted.sweep()

    asyncio.run(run())

    assert sorted(i for call in calls for i in call) == [98, 99]
    assert world.pipeline.transcript_rows == {_name("s01"): 5}


def test_a_transcript_that_is_not_a_sessions_segment_is_never_removed(monkeypatch, tmp_path):
    """The review UI and the manual upload create transcripts no segment will
    ever reference; only a session's own segment rows can be orphans."""
    world = World(monkeypatch, tmp_path, [_processed("s01", 5)], state="done")
    world.pipeline.transcript_rows.update({
        _name("s01"): 5,
        "diary-2026-06-30.txt": 40,
        _name("s01", "a-session-with-no-row"): 41,
    })
    calls = _delete_calls(monkeypatch)
    restarted = _restart(monkeypatch, world)

    asyncio.run(restarted.sweep())

    assert calls == []
    assert len(world.pipeline.transcript_rows) == 3


def test_the_transcript_an_interrupted_recovery_saved_is_settled_first_and_kept(
    monkeypatch, tmp_path,
):
    """The segment is `transcribing` until the reconciliation links the saved
    transcript to it; that row is not an orphan."""
    world = World(monkeypatch, tmp_path, [_transcribing("s01")], state="processing")
    _save_transcript(monkeypatch, world, "s01", 10)
    world.pipeline.transcript_rows[_name("s02")] = 99
    restarted = _restart(monkeypatch, world)

    asyncio.run(restarted.sweep())

    _, (segment,) = _stored(world)
    assert (segment.status, segment.transcript_id) == ("processed", 10)
    assert world.pipeline.transcript_rows == {_name("s01"): 10}
    assert world.pipeline.transcribe_calls == []


def test_a_transcript_row_an_interrupted_recovery_left_without_a_link_is_removed(
    monkeypatch, tmp_path,
):
    """A row without entities is not a saved recovery (FTR-03): the segment
    fails as interrupted and no segment references the row."""
    world = World(monkeypatch, tmp_path, [_transcribing("s01")], state="processing")
    world.pipeline.transcript_rows[_name("s01")] = 10
    restarted = _restart(monkeypatch, world)

    asyncio.run(restarted.sweep())

    _, (segment,) = _stored(world)
    assert (segment.status, segment.code) == ("failed", "recovery_interrupted")
    assert world.pipeline.transcript_rows == {}


def test_nothing_is_removed_while_a_session_could_not_be_settled(monkeypatch, tmp_path):
    """Its saved transcript may be the one that segment should be linked to
    next startup."""
    world = World(monkeypatch, tmp_path, [_transcribing("s01")], state="processing")
    _save_transcript(monkeypatch, world, "s01", 10)
    world.pipeline.transcript_rows[_name("s02")] = 99

    async def broken(*, filename, date):
        raise ConnectionError("database went away")

    monkeypatch.setattr(db, "find_recovered_transcript", broken)
    calls = _delete_calls(monkeypatch)
    restarted = _restart(monkeypatch, world)

    asyncio.run(restarted.sweep())

    assert world.ingests.rows[SESSION]["segments"][0]["status"] == "transcribing"
    assert calls == []
    assert world.pipeline.transcript_rows[_name("s01")] == 10


def test_nothing_is_removed_while_a_session_run_is_active_in_this_process(monkeypatch, tmp_path):
    world = World(monkeypatch, tmp_path, [_transcribing("s01")], state="processing")
    world.pipeline.transcript_rows[_name("s02")] = 99
    calls = _delete_calls(monkeypatch)
    restarted = _restart(monkeypatch, world)

    async def run():
        assert await restarted._try_begin(SESSION)
        await restarted.sweep()

    asyncio.run(run())

    assert calls == []


def test_a_busy_sessions_rows_are_kept_while_its_run_is_saving_a_transcript(monkeypatch, tmp_path):
    """The claim a run holds is what keeps a row it saved, and has not yet
    linked, from being taken for an orphan."""
    world = World(monkeypatch, tmp_path, [_processed("s01", 5)], state="done")
    world.pipeline.transcript_rows.update({_name("s01"): 5, _name("s02"): 99})
    calls = _delete_calls(monkeypatch)
    restarted = _restart(monkeypatch, world)

    async def run():
        assert await restarted._try_begin(SESSION)
        await restarted.sweep()

    asyncio.run(run())

    assert calls == []
    assert world.pipeline.transcript_rows[_name("s02")] == 99


def test_a_failing_delete_is_logged_and_does_not_stop_the_others_or_the_sweep(
    monkeypatch, tmp_path, caplog,
):
    world = World(
        monkeypatch, tmp_path, [_processed("s01", 5), _pending("s02", 6)], state="partial",
    )
    world.pipeline.transcript_rows.update(
        {_name("s01"): 5, _name("s02"): 6, _name("s03"): 98, _name("s04"): 99}
    )
    stub_transcripts(monkeypatch, [5, 6])
    working = db.delete_transcripts

    async def broken_for_98(ids):
        if 98 in ids:
            raise ConnectionError("database went away")
        await working(ids)

    monkeypatch.setattr(db, "delete_transcripts", broken_for_98)
    restarted = _restart(monkeypatch, world)

    with caplog.at_level(logging.INFO):
        asyncio.run(restarted.sweep())

    assert set(world.pipeline.transcript_rows.values()) == {5, 6, 98}
    assert any("98" in record.getMessage() for record in caplog.records if record.levelno >= logging.WARNING)
    assert any("removed 1 orphan transcript" in record.getMessage() for record in caplog.records)
    assert world.pipeline.transcribe_calls == []
    assert _stored(world)[0] == "done"  # the sweep went on to retry the pending segment


def test_listing_the_transcripts_failing_never_blocks_startup(monkeypatch, tmp_path):
    world = World(monkeypatch, tmp_path, [_processed("s01", 5)], state="done")

    async def broken():
        raise ConnectionError("database went away")

    monkeypatch.setattr(db, "list_transcripts", broken)
    restarted = _restart(monkeypatch, world)

    asyncio.run(restarted.sweep())  # does not raise

    assert _stored(world)[0] == "done"
