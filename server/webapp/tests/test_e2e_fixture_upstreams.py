"""E2E-2: the fixture upstreams answer every LLM and LightRAG call the session
pipeline makes, deterministically and keyed by fixture.

Each call is made by the pipeline's own client or prompt builder against a live
fixture server, so a change to a prompt, a path or a parser that the fixtures
no longer satisfy fails here rather than on the 3090.
"""

import hashlib
import importlib.util
import json
import threading
from pathlib import Path

import httpx
import pytest

import document_processor
import fluency_checker
import harvest_llm
import llm_validator
import transcript_corrector
from lightrag_client import LightRAGClient
from ollama_client import OllamaClient

SERVER_DIR = Path(__file__).resolve().parents[2]
FIXTURE_UPSTREAMS = SERVER_DIR / "e2e" / "fixture_upstreams.py"

CAST_TRANSCRIPT = (
    "Heute habe ich mit Mira Lindqvist den Testplan für Projekt Leuchtturm besprochen."
)
OTHER_TRANSCRIPT = "Ein ganz anderer Text ohne bekannte Personen."


@pytest.fixture(scope="module")
def upstreams():
    spec = importlib.util.spec_from_file_location("fixture_upstreams", FIXTURE_UPSTREAMS)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    servers = {name: module._serve(name, 0) for name in ("ollama", "lightrag")}
    for server in servers.values():
        threading.Thread(target=server.serve_forever, daemon=True).start()
    urls = {name: f"http://127.0.0.1:{s.server_address[1]}" for name, s in servers.items()}
    yield module, urls
    for server in servers.values():
        server.shutdown()
        server.server_close()


def _log(urls, service="ollama"):
    return httpx.get(urls[service] + "/_fixture/requests").json()


def _new_entries(urls, since, service="ollama"):
    return _log(urls, service)[since:]


def _proxy_transport(base_url: str) -> httpx.MockTransport:
    """Send whatever `document_processor` posts to the fixture server."""
    async def handler(request: httpx.Request) -> httpx.Response:
        async with httpx.AsyncClient() as client:
            return await client.post(
                base_url + request.url.path, content=request.content,
                headers={"content-type": "application/json"},
            )
    return httpx.MockTransport(handler)


def _enriched(transcript: str, date: str = "2026-03-04") -> dict:
    record = {"corrected_text": transcript, "date": date, "author": None}
    return document_processor.build_enriched_context(record, [], "Keine historischen Daten verfügbar.")


async def test_transcript_correction_reply_parses_and_is_logged_by_kind(upstreams):
    _, urls = upstreams
    before = len(_log(urls))
    client = OllamaClient(base_url=urls["ollama"], model="m")
    corrector = transcript_corrector.TranscriptCorrector(client, 4096)
    text, applied = await corrector.correct(CAST_TRANSCRIPT)
    assert (text, applied) == (CAST_TRANSCRIPT, [])
    [entry] = _new_entries(urls, before)
    assert (entry["path"], entry["kind"], entry["fixture"]) == ("/api/chat", "transcript_correction", "e2e-cast")
    # The reply is the JSON envelope the corrector parses, not prose.
    raw = httpx.post(urls["ollama"] + "/api/chat", json={"messages": transcript_corrector._build_messages(CAST_TRANSCRIPT)}).json()
    assert json.loads(raw["message"]["content"]) == {"corrections": []}


async def test_fluency_reply_parses_as_the_issues_envelope(upstreams):
    _, urls = upstreams
    before = len(_log(urls))
    issues = await fluency_checker.FluencyChecker(OllamaClient(base_url=urls["ollama"]), 4096).check(CAST_TRANSCRIPT)
    assert issues == []
    [entry] = _new_entries(urls, before)
    assert entry["kind"] == "fluency_check"
    raw = httpx.post(urls["ollama"] + "/api/chat", json={"messages": fluency_checker._build_messages(CAST_TRANSCRIPT)}).json()
    assert json.loads(raw["message"]["content"]) == {"issues": []}


async def test_harvest_llm_gets_work_activities_for_the_cast_fixture(upstreams):
    _, urls = upstreams
    before = len(_log(urls))
    extractor = harvest_llm.WorkActivityExtractor(OllamaClient(base_url=urls["ollama"]), {})
    activities = await extractor.extract(CAST_TRANSCRIPT, "2026-03-04")
    assert activities and all(a["category"] in harvest_llm.ALLOWED_CATEGORIES for a in activities)
    assert "Leuchtturm" in activities[0]["description"]
    [entry] = _new_entries(urls, before)
    assert (entry["kind"], entry["fixture"]) == ("work_activities", "e2e-cast")


async def test_harvest_llm_gets_no_activities_for_an_unknown_transcript(upstreams):
    _, urls = upstreams
    extractor = harvest_llm.WorkActivityExtractor(OllamaClient(base_url=urls["ollama"]), {})
    assert await extractor.extract(OTHER_TRANSCRIPT, "2026-03-04") == []
    assert _log(urls)[-1]["fixture"] is None


def test_entity_validation_reply_parses_into_verdicts(upstreams):
    _, urls = upstreams
    messages = llm_validator._build_prompt(CAST_TRANSCRIPT, [])
    resp = httpx.post(urls["ollama"] + "/api/chat", json={"messages": messages, "format": "json"})
    assert llm_validator._parse_verdicts(resp.json()["message"]["content"]) == []
    assert _log(urls)[-1]["kind"] == "entity_validation"


async def test_analysis_is_keyed_by_fixture_and_takes_its_date_from_the_prompt(upstreams):
    _, urls = upstreams
    transport = _proxy_transport(urls["ollama"])
    cast = await document_processor.analyze_transcript(_enriched(CAST_TRANSCRIPT, "2026-03-04"), transport=transport)
    assert _log(urls)[-1]["fixture"] == "e2e-cast" and _log(urls)[-1]["kind"] == "analysis"
    assert cast["todos"][0]["action"] == "Testplan abstimmen"
    assert {r["date"] for r in cast["relationships"]} == {"2026-03-04"}
    assert cast["projects"][0]["name"] == "Projekt Leuchtturm"

    other = await document_processor.analyze_transcript(_enriched(OTHER_TRANSCRIPT), transport=transport)
    assert _log(urls)[-1]["fixture"] is None
    assert all(other[key] == [] for key in other)


async def test_cast_analysis_renders_a_known_narrative(upstreams):
    _, urls = upstreams
    enriched = _enriched(CAST_TRANSCRIPT, "2026-03-04")
    analysis = await document_processor.analyze_transcript(enriched, transport=_proxy_transport(urls["ollama"]))
    markdown = document_processor.generate_narrative_document(enriched, analysis)
    assert "Mira Lindqvist" in markdown
    assert "Projekt Leuchtturm" in markdown and "Testplan abstimmen" in markdown


async def test_context_summary_is_fixed_and_long_enough_to_be_used(upstreams):
    _, urls = upstreams
    before = len(_log(urls))
    summary = await document_processor.summarize_context("a", "b", "2026-03-04", transport=_proxy_transport(urls["ollama"]))
    assert len(summary) >= 50 and "Keine historischen Daten" not in summary
    assert _new_entries(urls, before)[0]["kind"] == "context_summary"


def test_a_fixture_claims_inflected_names_but_not_words_that_merely_contain_one(upstreams):
    module, _ = upstreams
    assert module.select_fixture("Jonas Falke übernimmt die Abstimmung") == "e2e-cast"
    assert module.select_fixture("mit mir allen den Testplan für Projekt LEUCHTTURM") == "e2e-cast"
    assert module.select_fixture("Der Admiral sah ein Wunder, ein miracle.") is None
    assert module.select_fixture("") is None


def test_identical_requests_get_byte_identical_replies(upstreams):
    _, urls = upstreams
    body = {"messages": [{"role": "user", "content": "Du analysierst das Tagebuch eines CTOs vom 2026-03-04.\n" + CAST_TRANSCRIPT}]}
    first = httpx.post(urls["ollama"] + "/v1/chat/completions", json=body)
    second = httpx.post(urls["ollama"] + "/v1/chat/completions", json=body)
    assert first.content == second.content


def test_every_log_entry_names_the_endpoint_and_a_body_digest(upstreams):
    _, urls = upstreams
    body = json.dumps({"messages": [{"role": "user", "content": "x"}]}).encode()
    httpx.post(urls["ollama"] + "/api/chat", content=body, headers={"content-type": "application/json"})
    entry = _log(urls)[-1]
    assert entry["service"] == "ollama" and entry["method"] == "POST" and entry["path"] == "/api/chat"
    assert entry["sha256"] == hashlib.sha256(body).hexdigest()
    assert entry["kind"] == "unknown" and entry["fixture"] is None


async def test_lightrag_calls_are_typed_in_the_log_and_documents_are_kept(upstreams):
    _, urls = upstreams
    before = len(_log(urls, "lightrag"))
    client = LightRAGClient(base_url=urls["lightrag"])
    assert await client.query("Fasse die wichtigsten Themen zusammen", mode="mix", top_k=5)
    await client.insert_document(doc_id="diary:2026-03-04", text="# Narrative", file_source="diary-2026-03-04.md")
    await client.delete_documents(["bone:x"])
    entries = _new_entries(urls, before, "lightrag")
    assert [(e["method"], e["path"], e["kind"]) for e in entries] == [
        ("POST", "/query", "lightrag_query"),
        ("POST", "/documents/text", "lightrag_insert"),
        ("DELETE", "/documents/delete_document", "lightrag_delete"),
    ]
    docs = httpx.get(urls["lightrag"] + "/_fixture/documents").json()
    assert docs["diary:2026-03-04"] == {
        "file_source": "diary-2026-03-04.md",
        "sha256": hashlib.sha256(b"# Narrative").hexdigest(),
        "text": "# Narrative",
    }


async def test_reinserting_a_document_id_replaces_it_like_lightrag(upstreams):
    _, urls = upstreams
    client = LightRAGClient(base_url=urls["lightrag"])
    await client.insert_document(doc_id="diary:2026-03-05", text="one", file_source="f")
    await client.insert_document(doc_id="diary:2026-03-05", text="two", file_source="f")
    assert httpx.get(urls["lightrag"] + "/_fixture/documents").json()["diary:2026-03-05"]["text"] == "two"
    await client.delete_documents(["diary:2026-03-05"])
    assert "diary:2026-03-05" not in httpx.get(urls["lightrag"] + "/_fixture/documents").json()


def test_fixture_log_and_documents_are_not_recorded_as_pipeline_calls(upstreams):
    _, urls = upstreams
    httpx.get(urls["lightrag"] + "/_fixture/documents")
    httpx.get(urls["lightrag"] + "/_fixture/requests")
    assert all(not e["path"].startswith("/_fixture") for e in _log(urls, "lightrag"))
