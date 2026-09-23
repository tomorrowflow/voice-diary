import json
import sys
import os

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

import httpx

from document_processor import (
    _split_diary_markdown,
    analyze_transcript,
    diary_to_interchange_jsonl,
    summarize_context,
)


SIMPLE_MARKDOWN = """\
# CTO Tagebuch - KW 19, 2026

**Eintrag vom Sonntag, 10. Mai 2026**

---

## Zusammenfassung

Am 10. Mai hat der Autor folgende Themen bearbeitet.

## Tagebucheintrag

Der Transkript des heutigen Eintrags.

---

## Erkenntnisse und Learnings (Kalenderwoche 19, 2026)

Neue Erkenntnis über das System.

---

*Verarbeitet am 2026-05-10. Datum: 2026-05-10, KW 19, Q2 2026.*
"""


def test_split_returns_correct_section_count():
    chunks = _split_diary_markdown(SIMPLE_MARKDOWN)
    # Title block, Zusammenfassung, Tagebucheintrag, Erkenntnisse, footer
    assert len(chunks) == 5


def test_split_headings():
    chunks = _split_diary_markdown(SIMPLE_MARKDOWN)
    headings = [c["heading"] for c in chunks]
    assert headings[0].startswith("CTO Tagebuch")
    assert headings[1] == "Zusammenfassung"
    assert headings[2] == "Tagebucheintrag"
    assert "Erkenntnisse" in headings[3]
    assert headings[4] == ""  # footer has no heading


def test_split_content_types():
    chunks = _split_diary_markdown(SIMPLE_MARKDOWN)
    assert chunks[0]["content_type"] == "summary"   # title
    assert chunks[1]["content_type"] == "summary"   # Zusammenfassung
    assert chunks[2]["content_type"] == "body"      # Tagebucheintrag
    assert chunks[3]["content_type"] == "body"      # Erkenntnisse
    assert chunks[4]["content_type"] == "references"  # footer


def test_split_no_empty_sections():
    chunks = _split_diary_markdown(SIMPLE_MARKDOWN)
    for chunk in chunks:
        assert chunk["content"].strip() != ""


def test_split_parent_headings_for_subsection():
    md = """\
## Projekte und Initiativen (Stand KW 19, 2026)

Übersicht.

### Projekt: Foo (KW 19, 2026)

Details zu Foo.
"""
    chunks = _split_diary_markdown(md)
    proj_chunk = next(c for c in chunks if "Foo" in c["heading"])
    assert proj_chunk["level"] == 3
    assert len(proj_chunk["parent_headings"]) == 1
    assert "Projekte" in proj_chunk["parent_headings"][0]


def test_interchange_jsonl_structure():
    jsonl = diary_to_interchange_jsonl("diary:2026-05-10", SIMPLE_MARKDOWN, {"date": "2026-05-10"})
    lines = jsonl.strip().split("\n")

    meta = json.loads(lines[0])
    assert meta["type"] == "meta"
    assert meta["format_version"] == "2.0"
    assert meta["engine"] == "voice-diary"
    assert meta["source_metadata"]["date"] == "2026-05-10"

    chunks = [json.loads(l) for l in lines[1:]]
    for idx, chunk in enumerate(chunks):
        assert chunk["type"] == "text"
        assert chunk["chunk_order_index"] == idx
        assert chunk["chunk_id"] == f"diary:2026-05-10-chunk-{idx:03d}"
        assert chunk["content"]
        assert chunk["content_type"] in ("summary", "body", "references")
        assert chunk["tokens"] >= 1


def test_interchange_chunk_order_contiguous():
    jsonl = diary_to_interchange_jsonl("diary:2026-05-10", SIMPLE_MARKDOWN, {})
    lines = jsonl.strip().split("\n")
    indices = [json.loads(l)["chunk_order_index"] for l in lines[1:]]
    assert indices == list(range(len(indices)))


# --- summarize_context: OpenAI-shape /v1/chat/completions -----------------


async def test_summarize_context_posts_to_v1_chat_completions():
    captured: dict = {}

    def handler(request: httpx.Request) -> httpx.Response:
        captured["url"] = str(request.url)
        return httpx.Response(
            200,
            json={"choices": [{"message": {"content": "x" * 60}}]},
        )

    result = await summarize_context(
        "recent", "history", "2026-05-10", transport=httpx.MockTransport(handler)
    )

    assert captured["url"].endswith("/v1/chat/completions")
    assert result == "x" * 60


async def test_summarize_context_payload_has_no_ollama_native_options():
    captured: dict = {}

    def handler(request: httpx.Request) -> httpx.Response:
        captured["body"] = json.loads(request.read())
        return httpx.Response(
            200,
            json={"choices": [{"message": {"content": "x" * 60}}]},
        )

    await summarize_context(
        "recent", "history", "2026-05-10", transport=httpx.MockTransport(handler)
    )

    body = captured["body"]
    assert "options" not in body
    assert "num_ctx" not in body
    assert body["temperature"] == 0.1
    assert body["stream"] is False


async def test_summarize_context_falls_back_on_error():
    def handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(500, json={"error": "boom"})

    result = await summarize_context(
        "recent", "history", "2026-05-10", transport=httpx.MockTransport(handler)
    )

    assert result == "Keine historischen Daten verfügbar."


# --- analyze_transcript: OpenAI-shape /v1/chat/completions -----------------


ENRICHED_CTX = {
    "normalized_text": "Heute mit Thomas über das Projekt gesprochen.",
    "entity_context": {"persons": [], "terms": []},
    "lightrag_context": {"summary": "", "available": False},
    "date": "2026-05-10",
    "diary_author": "Florian Wolf",
    "diary_author_role": "CTO, Managing Director",
    "diary_author_company": "Enersis",
}


def _analysis_response(payload: dict) -> httpx.Response:
    return httpx.Response(
        200,
        json={"choices": [{"message": {"content": json.dumps(payload)}}]},
    )


async def test_analyze_transcript_posts_to_v1_chat_completions_with_json_mode():
    captured: dict = {}

    def handler(request: httpx.Request) -> httpx.Response:
        captured["url"] = str(request.url)
        captured["body"] = json.loads(request.read())
        return _analysis_response({"relationships": [], "projects": [],
                                    "decisions": [], "todos": [],
                                    "insights": [], "recurring_themes": []})

    await analyze_transcript(ENRICHED_CTX, transport=httpx.MockTransport(handler))

    assert captured["url"].endswith("/v1/chat/completions")
    body = captured["body"]
    assert body["response_format"] == {"type": "json_object"}
    assert "options" not in body
    assert "num_ctx" not in body


async def test_analyze_transcript_parses_openai_shape_response():
    def handler(request: httpx.Request) -> httpx.Response:
        return _analysis_response({
            "relationships": [{"a": "Florian", "b": "Thomas"}],
            "projects": [], "decisions": [], "todos": [],
            "insights": [], "recurring_themes": [],
        })

    result = await analyze_transcript(
        ENRICHED_CTX, transport=httpx.MockTransport(handler)
    )

    assert result["relationships"] == [{"a": "Florian", "b": "Thomas"}]


async def test_analyze_transcript_read_timeout_raises_runtime_error():
    def handler(request: httpx.Request) -> httpx.Response:
        raise httpx.ReadTimeout("timed out", request=request)

    try:
        await analyze_transcript(ENRICHED_CTX, transport=httpx.MockTransport(handler))
        assert False, "expected RuntimeError"
    except RuntimeError as e:
        assert "timed out" in str(e)
