"""VectorStore driven through an injected fake client.

No Qdrant instance and no embedding model: the store takes its client (or
client factory) through the constructor, and the module-level entry points
are checked to delegate to the default store.
"""

import asyncio
import datetime
import threading
import uuid
from types import SimpleNamespace

import pytest

import vector_store
from vector_store import (
    COLLECTION_CORRECTIONS,
    COLLECTION_ENTITIES,
    VectorStore,
)


class _Hit:
    def __init__(self, score, metadata):
        self.score = score
        self.metadata = metadata


class FakeClient:
    def __init__(self, existing=(), hits=(), counts=None):
        self.collections = list(existing)
        self.hits = list(hits)
        self.counts = counts or {}
        self.calls = []
        self.closed = False
        self.query_thread = None
        self.fail_with = None

    def _record(self, method, **kwargs):
        self.calls.append((method, kwargs))
        if self.fail_with is not None:
            raise self.fail_with

    def get_collections(self):
        self._record("get_collections")
        return SimpleNamespace(
            collections=[SimpleNamespace(name=n) for n in self.collections]
        )

    def delete_collection(self, **kwargs):
        self._record("delete_collection", **kwargs)

    def create_collection(self, **kwargs):
        self._record("create_collection", **kwargs)

    def get_fastembed_vector_params(self):
        return "vector-params"

    def delete(self, **kwargs):
        self._record("delete", **kwargs)

    def add(self, **kwargs):
        self._record("add", **kwargs)

    def query(self, **kwargs):
        self.query_thread = threading.current_thread()
        self._record("query", **kwargs)
        return self.hits

    def get_collection(self, name):
        self._record("get_collection", name=name)
        return SimpleNamespace(points_count=self.counts[name])

    def close(self):
        self.closed = True

    def named(self, name):
        return [kw for n, kw in self.calls if n == name]


def _store(client=None, enabled=True, **kwargs):
    return VectorStore(is_enabled=lambda: enabled, client=client, **kwargs)


def _run(coro):
    return asyncio.run(coro)


# --- disabled mode ---------------------------------------------------------


def test_disabled_store_never_touches_the_client():
    def boom():
        raise AssertionError("client must not be built when disabled")

    store = _store(enabled=False, client_factory=boom)

    async def run():
        await store.init_collections(recreate=True)
        await store.delete_transcript_vectors(1)
        await store.store_correction_context("a", "b", "a b", 0, 1, "word", 1, "d")
        await store.store_entity_sample(
            "X", "person", 1, "s", "x", "x y", 0, 1, "exact", "confirmed", 1, "d"
        )
        return (
            await store.find_similar_corrections("t"),
            await store.find_entity_usage_samples("X", "person"),
            await store.get_collection_stats(),
            await store.backfill_from_review_log(object()),
        )

    corrections, samples, stats, backfill = _run(run())

    assert corrections == []
    assert samples == []
    assert stats == {"enabled": False}
    assert backfill == {"status": "disabled"}


def test_enabled_flag_is_read_on_every_call():
    state = {"on": False}
    client = FakeClient()
    store = VectorStore(is_enabled=lambda: state["on"], client=client)

    _run(store.delete_transcript_vectors(1))
    assert client.calls == []

    state["on"] = True
    _run(store.delete_transcript_vectors(1))
    assert len(client.named("delete")) == 2


# --- client lifecycle ------------------------------------------------------


def test_client_is_created_lazily_once_and_reused():
    built = []

    def factory():
        built.append(FakeClient())
        return built[-1]

    store = _store(client_factory=factory)
    assert built == []

    async def run():
        first = await store.ensure_client()
        second = await store.ensure_client()
        return first, second

    first, second = _run(run())

    assert first is second is built[0]
    assert len(built) == 1


def test_close_closes_client_and_next_use_builds_a_new_one():
    built = []

    def factory():
        built.append(FakeClient())
        return built[-1]

    store = _store(client_factory=factory)

    async def run():
        await store.ensure_client()
        await store.close()
        return await store.ensure_client()

    reinit = _run(run())

    assert built[0].closed is True
    assert len(built) == 2
    assert reinit is built[1]


def test_close_without_a_client_is_a_noop_and_swallows_close_errors():
    _run(_store().close())

    class Exploding(FakeClient):
        def close(self):
            raise RuntimeError("already gone")

    store = _store(Exploding())
    _run(store.close())

    assert store._client is None


def test_injected_client_is_used_without_calling_the_factory():
    client = FakeClient()
    store = _store(client, client_factory=lambda: pytest.fail("factory called"))

    assert _run(store.ensure_client()) is client


# --- collection initialisation --------------------------------------------


def test_init_collections_creates_both_missing_collections():
    client = FakeClient()

    _run(_store(client).init_collections())

    assert client.named("create_collection") == [
        {"collection_name": COLLECTION_CORRECTIONS, "vectors_config": "vector-params"},
        {"collection_name": COLLECTION_ENTITIES, "vectors_config": "vector-params"},
    ]
    assert client.named("delete_collection") == []


def test_init_collections_keeps_existing_collections():
    client = FakeClient(existing=[COLLECTION_CORRECTIONS])

    _run(_store(client).init_collections())

    assert [kw["collection_name"] for kw in client.named("create_collection")] == [
        COLLECTION_ENTITIES
    ]
    assert client.named("delete_collection") == []


def test_init_collections_recreate_drops_and_recreates_existing():
    client = FakeClient(existing=[COLLECTION_CORRECTIONS, COLLECTION_ENTITIES, "other"])

    _run(_store(client).init_collections(recreate=True))

    assert [kw["collection_name"] for kw in client.named("delete_collection")] == [
        COLLECTION_CORRECTIONS,
        COLLECTION_ENTITIES,
    ]
    assert [kw["collection_name"] for kw in client.named("create_collection")] == [
        COLLECTION_CORRECTIONS,
        COLLECTION_ENTITIES,
    ]


def test_init_collections_swallows_client_errors():
    client = FakeClient()
    client.fail_with = RuntimeError("qdrant down")

    _run(_store(client).init_collections())  # must not raise


# --- writes ---------------------------------------------------------------


def test_store_correction_context_writes_marked_document_and_metadata():
    client = FakeClient()
    full_text = "aaa bbb ccc"

    _run(
        _store(client).store_correction_context(
            original_text="bbb",
            corrected_text="BBB",
            full_text=full_text,
            start=4,
            end=7,
            correction_type="word",
            transcript_id=7,
            transcript_date="2026-01-02",
        )
    )

    (call,) = client.named("add")
    assert call["collection_name"] == COLLECTION_CORRECTIONS
    assert call["documents"] == ["aaa [bbb -> BBB] ccc"]
    assert call["metadata"] == [
        {
            "original_text": "bbb",
            "corrected_text": "BBB",
            "context_before": "aaa ",
            "context_after": " ccc",
            "full_context": full_text,
            "correction_type": "word",
            "transcript_id": 7,
            "transcript_date": "2026-01-02",
        }
    ]
    (point_id,) = call["ids"]
    assert str(uuid.UUID(point_id)) == point_id


def test_store_correction_context_uses_a_50_char_window():
    client = FakeClient()
    full_text = "x" * 100 + "WORD" + "y" * 100

    _run(
        _store(client).store_correction_context(
            "WORD", "word", full_text, 100, 104, "word", 1, "d"
        )
    )

    meta = client.named("add")[0]["metadata"][0]
    assert meta["context_before"] == "x" * 50
    assert meta["context_after"] == "y" * 50


def test_store_entity_sample_embeds_the_sentence_and_defaults_entity_id():
    client = FakeClient()
    full_text = "First one. Anna met Bob here! Last."

    _run(
        _store(client).store_entity_sample(
            entity_canonical="Anna",
            entity_type="person",
            entity_id=None,
            source="backfill",
            original_text="Ana",
            full_text=full_text,
            start=11,
            end=15,
            match_type="fuzzy",
            action="corrected",
            transcript_id=3,
            transcript_date="2026-02-03",
        )
    )

    (call,) = client.named("add")
    assert call["collection_name"] == COLLECTION_ENTITIES
    assert call["documents"] == ["Anna met Bob here"]
    assert call["metadata"] == [
        {
            "entity_canonical": "Anna",
            "entity_type": "person",
            "entity_id": 0,
            "source": "backfill",
            "original_text": "Ana",
            "sentence": "Anna met Bob here",
            "match_type": "fuzzy",
            "action": "corrected",
            "transcript_id": 3,
            "transcript_date": "2026-02-03",
        }
    ]
    assert len(call["ids"]) == 1


def test_store_entity_sample_keeps_a_given_entity_id():
    client = FakeClient()

    _run(
        _store(client).store_entity_sample(
            "Anna", "person", 42, "review", "Anna", "Anna.", 0, 4, "exact", "confirmed", 1, "d"
        )
    )

    assert client.named("add")[0]["metadata"][0]["entity_id"] == 42


def test_each_write_gets_a_fresh_uuid():
    client = FakeClient()
    store = _store(client)

    async def run():
        for _ in range(2):
            await store.store_correction_context("a", "b", "a", 0, 1, "word", 1, "d")

    _run(run())

    first, second = (kw["ids"][0] for kw in client.named("add"))
    assert first != second


def test_write_errors_are_swallowed():
    client = FakeClient()
    client.fail_with = RuntimeError("write failed")
    store = _store(client)

    async def run():
        await store.store_correction_context("a", "b", "a", 0, 1, "word", 1, "d")
        await store.store_entity_sample(
            "A", "person", 1, "s", "a", "a", 0, 1, "exact", "confirmed", 1, "d"
        )
        await store.delete_transcript_vectors(1)

    _run(run())  # must not raise


def test_client_factory_failure_is_swallowed_per_operation():
    def factory():
        raise RuntimeError("cannot connect")

    store = _store(client_factory=factory)

    async def run():
        await store.store_correction_context("a", "b", "a", 0, 1, "word", 1, "d")
        return (
            await store.find_similar_corrections("t"),
            await store.find_entity_usage_samples("A", "person"),
            await store.get_collection_stats(),
        )

    corrections, samples, stats = _run(run())

    assert corrections == []
    assert samples == []
    assert stats == {"enabled": True, "connected": False, "error": "cannot connect"}


# --- deletion -------------------------------------------------------------


def test_delete_transcript_vectors_filters_by_transcript_id_in_both_collections():
    from qdrant_client.models import FieldCondition, Filter, MatchValue

    client = FakeClient()

    _run(_store(client).delete_transcript_vectors(99))

    expected = Filter(
        must=[FieldCondition(key="transcript_id", match=MatchValue(value=99))]
    )
    assert client.named("delete") == [
        {"collection_name": COLLECTION_CORRECTIONS, "points_selector": expected},
        {"collection_name": COLLECTION_ENTITIES, "points_selector": expected},
    ]


# --- queries --------------------------------------------------------------


def test_find_similar_corrections_maps_limit_and_filters_by_threshold():
    hits = [
        _Hit(0.9, {"original_text": "a", "corrected_text": "b", "correction_type": "word"}),
        _Hit(0.65, {"original_text": "edge"}),
        _Hit(0.64, {"original_text": "too low"}),
    ]
    client = FakeClient(hits=hits)

    result = _run(_store(client).find_similar_corrections("some text", limit=3))

    assert client.named("query") == [
        {"collection_name": COLLECTION_CORRECTIONS, "query_text": "some text", "limit": 3}
    ]
    assert result == [
        {
            "original_text": "a",
            "corrected_text": "b",
            "context_before": "",
            "context_after": "",
            "full_context": "",
            "correction_type": "word",
            "score": 0.9,
        },
        {
            "original_text": "edge",
            "corrected_text": "",
            "context_before": "",
            "context_after": "",
            "full_context": "",
            "correction_type": "",
            "score": 0.65,
        },
    ]


def test_find_similar_corrections_defaults_and_custom_threshold():
    client = FakeClient(hits=[_Hit(0.5, {})])
    store = _store(client)

    assert _run(store.find_similar_corrections("t")) == []
    assert client.named("query")[0]["limit"] == 5
    assert len(_run(store.find_similar_corrections("t", threshold=0.5))) == 1


def test_find_similar_corrections_queries_off_the_event_loop():
    client = FakeClient(hits=[_Hit(0.9, {})])

    async def run():
        loop_thread = threading.current_thread()
        await _store(client).find_similar_corrections("t")
        return loop_thread

    loop_thread = _run(run())

    assert client.query_thread is not loop_thread


def test_find_similar_corrections_returns_empty_on_error():
    client = FakeClient()
    client.fail_with = RuntimeError("boom")

    assert _run(_store(client).find_similar_corrections("t")) == []


def test_find_entity_usage_samples_filters_by_name_and_type():
    from qdrant_client.models import FieldCondition, Filter, MatchValue

    hits = [
        _Hit(
            0.8,
            {
                "entity_canonical": "Anna",
                "entity_type": "person",
                "sentence": "Anna met Bob",
                "original_text": "Ana",
                "match_type": "fuzzy",
                "action": "corrected",
            },
        ),
        _Hit(0.59, {"entity_canonical": "below default threshold"}),
    ]
    client = FakeClient(hits=hits)

    result = _run(
        _store(client).find_entity_usage_samples(
            "Anna", "person", context="they met", limit=2
        )
    )

    assert client.named("query") == [
        {
            "collection_name": COLLECTION_ENTITIES,
            "query_text": "they met",
            "query_filter": Filter(
                must=[
                    FieldCondition(key="entity_canonical", match=MatchValue(value="Anna")),
                    FieldCondition(key="entity_type", match=MatchValue(value="person")),
                ]
            ),
            "limit": 2,
        }
    ]
    assert result == [
        {
            "entity_canonical": "Anna",
            "entity_type": "person",
            "sentence": "Anna met Bob",
            "original_text": "Ana",
            "match_type": "fuzzy",
            "action": "corrected",
            "score": 0.8,
        }
    ]


def test_find_entity_usage_samples_falls_back_to_canonical_without_context():
    client = FakeClient(hits=[_Hit(0.6, {})])

    result = _run(_store(client).find_entity_usage_samples("Anna", "person"))

    call = client.named("query")[0]
    assert call["query_text"] == "Anna"
    assert call["limit"] == 5
    assert len(result) == 1  # 0.6 meets the default threshold


def test_find_entity_usage_samples_returns_empty_on_error():
    client = FakeClient()
    client.fail_with = RuntimeError("boom")

    assert _run(_store(client).find_entity_usage_samples("A", "person")) == []


# --- stats ----------------------------------------------------------------


def test_get_collection_stats_reports_counts():
    client = FakeClient(counts={COLLECTION_CORRECTIONS: 4, COLLECTION_ENTITIES: 9})

    assert _run(_store(client).get_collection_stats()) == {
        "enabled": True,
        "connected": True,
        "corrections_count": 4,
        "entities_count": 9,
    }


def test_get_collection_stats_reports_connection_errors():
    client = FakeClient()
    client.fail_with = RuntimeError("no route")

    assert _run(_store(client).get_collection_stats()) == {
        "enabled": True,
        "connected": False,
        "error": "no route",
    }


# --- backfill (characterised with fakes only) -----------------------------


class FakePool:
    def __init__(self, review_rows, text_rows):
        self.review_rows = review_rows
        self.text_rows = text_rows
        self.queries = []

    async def fetch(self, sql):
        self.queries.append(sql)
        return self.review_rows if "FROM review_log" in sql else self.text_rows


def _review_row(**overrides):
    row = {
        "transcript_id": 5,
        "original_text": "Ana",
        "entity_type": "person",
        "match_type": "fuzzy",
        "action": "corrected",
        "corrected_text": "Anna",  # shadowed by transcripts.corrected_text, as in SQL
        "raw_text": "raw",
        "transcript_date": datetime.date(2026, 3, 4),
    }
    row.update(overrides)
    return row


def test_backfill_routes_stores_through_the_same_store_instance():
    client = FakeClient()
    pool = FakePool(
        review_rows=[
            _review_row(corrected_text="Anna met Ana today."),
            _review_row(action="confirmed", corrected_text="Ana and Ana"),
            _review_row(corrected_text="", raw_text=""),
        ],
        text_rows=[
            {"original_text": "teh", "corrected_text": "the", "correction_type": "word"}
        ],
    )

    result = _run(_store(client).backfill_from_review_log(pool))

    adds = client.named("add")
    assert [a["collection_name"] for a in adds] == [
        COLLECTION_ENTITIES,
        COLLECTION_CORRECTIONS,
        COLLECTION_ENTITIES,
        COLLECTION_CORRECTIONS,
    ]
    first_entity = adds[0]["metadata"][0]
    assert first_entity["source"] == "backfill"
    assert first_entity["entity_id"] == 0
    assert first_entity["transcript_date"] == "2026-03-04"
    assert adds[3]["metadata"][0]["correction_type"] == "text_correction"
    assert adds[3]["metadata"][0]["transcript_id"] == 0
    assert adds[3]["metadata"][0]["transcript_date"] == ""
    assert result == {
        "status": "ok",
        "corrections_stored": 2,
        "entities_stored": 2,
        "review_log_rows": 3,
        "text_correction_rows": 1,
    }
    assert "action IN ('confirmed', 'corrected')" in pool.queries[0]
    assert "correction_type = 'word'" in pool.queries[1]


def test_backfill_returns_error_status_when_the_query_fails():
    class BrokenPool:
        async def fetch(self, sql):
            raise RuntimeError("db gone")

    result = _run(_store(FakeClient()).backfill_from_review_log(BrokenPool()))

    assert result == {"status": "error", "error": "db gone"}


# --- module-level entry points --------------------------------------------


@pytest.fixture
def default_store(monkeypatch):
    """Point the module-level entry points at a fake-backed default store."""
    client = FakeClient(counts={COLLECTION_CORRECTIONS: 1, COLLECTION_ENTITIES: 2})
    store = VectorStore(is_enabled=lambda: vector_store.VECTOR_SEARCH_ENABLED, client=client)
    monkeypatch.setattr(vector_store, "_store", store)
    monkeypatch.setattr(vector_store, "VECTOR_SEARCH_ENABLED", True)
    return client


def test_module_functions_delegate_to_the_default_store(default_store):
    client = default_store

    async def run():
        await vector_store.init_collections(recreate=True)
        await vector_store.delete_transcript_vectors(8)
        await vector_store.store_correction_context("a", "b", "a b", 0, 1, "word", 8, "d")
        await vector_store.store_entity_sample(
            "A", "person", None, "s", "a", "a b", 0, 1, "exact", "confirmed", 8, "d"
        )
        client.hits = [_Hit(0.9, {"original_text": "a"})]
        corrections = await vector_store.find_similar_corrections("t", limit=2)
        samples = await vector_store.find_entity_usage_samples(
            "A", "person", context="c", limit=1, threshold=0.5
        )
        stats = await vector_store.get_collection_stats()
        backfill = await vector_store.backfill_from_review_log(FakePool([], []))
        await vector_store.close()
        return corrections, samples, stats, backfill

    corrections, samples, stats, backfill = _run(run())

    assert len(client.named("create_collection")) == 2
    assert len(client.named("delete")) == 2
    assert len(client.named("add")) == 2
    assert [q["limit"] for q in client.named("query")] == [2, 1]
    assert corrections[0]["original_text"] == "a"
    assert samples[0]["score"] == 0.9
    assert stats["corrections_count"] == 1 and stats["entities_count"] == 2
    assert backfill["status"] == "ok"
    assert client.closed is True


def test_module_entry_points_honour_the_enabled_constant(default_store, monkeypatch):
    monkeypatch.setattr(vector_store, "VECTOR_SEARCH_ENABLED", False)

    async def run():
        return (
            await vector_store.find_similar_corrections("t"),
            await vector_store.find_entity_usage_samples("A", "person"),
            await vector_store.get_collection_stats(),
            await vector_store.backfill_from_review_log(object()),
        )

    assert _run(run()) == ([], [], {"enabled": False}, {"status": "disabled"})
    assert default_store.calls == []


def test_module_get_client_is_the_default_stores_lazy_client(default_store):
    assert _run(vector_store._get_client()) is default_store


def test_default_store_operations_go_through_a_patched_get_client(monkeypatch):
    monkeypatch.setattr(vector_store, "VECTOR_SEARCH_ENABLED", True)
    client = FakeClient(hits=[_Hit(0.9, {"original_text": "a"})])

    async def fake_get_client():
        return client

    monkeypatch.setattr(vector_store, "_get_client", fake_get_client)

    result = _run(vector_store.find_similar_corrections("t"))

    assert result[0]["original_text"] == "a"


def test_default_store_is_configured_from_the_module_constants():
    store = vector_store._store

    assert store._url == vector_store.QDRANT_URL
    assert store._model == vector_store.EMBEDDING_MODEL
