"""`enrichment.summarise_for_speech` and `SpeechSummariser` (REF-131).

The module-level wrapper is driven through the real `enrichment._ollama_client`
and its real `chat`; only the HTTP transport underneath is replaced by an
`httpx.MockTransport`. `/lightrag/query` is driven through the real router, the
real summariser and the real LightRAG and Ollama client methods, with the same
single interception point. No live service is contacted.
"""

from __future__ import annotations

import json

import httpx
import pytest

import enrichment
import routers.lightrag as lightrag_router
from enrichment import EnrichmentSummariserUnavailable, SpeechSummariser, summarise_for_speech
from ollama_client import (
    OllamaClient,
    OllamaEngineError,
    OllamaTimeoutError,
    OllamaUnavailableError,
)
from tests.route_helpers import assert_failure, auth, client_for

DE_SYSTEM = (
    "Du bist die Stimme einer persönlichen Tagebuch-Assistenz. "
    "Beantworte die Frage des Nutzers in zwei bis drei kurzen, "
    "sprechbaren Sätzen auf Deutsch. Schreibe ausschließlich Prosa: "
    "keine Aufzählungen, keine Markdown-Zeichen, keine Anführungszeichen, "
    "keine Emojis, keine Einleitungen wie 'Hier ist die Zusammenfassung:'. "
    "Wenn die Quellen die Frage nicht beantworten, sage das in einem Satz."
)
EN_SYSTEM = (
    "You are the voice of a personal diary assistant. "
    "Answer the user's question in two to three short, speakable "
    "sentences in English. Use prose only: no bullets, no markdown, "
    "no quotation marks, no emoji, no preamble such as "
    "'Here is the summary:'. If the sources do not answer the question, "
    "say so in one sentence."
)


def _chat_reply(content: str) -> httpx.Response:
    return httpx.Response(200, json={"message": {"content": content}})


class _Ollama:
    """A scripted Ollama transport that records every request body."""

    def __init__(self, answer) -> None:
        self._answer = answer
        self.requests: list[httpx.Request] = []
        self.transport = httpx.MockTransport(self._handle)

    def _handle(self, request: httpx.Request) -> httpx.Response:
        self.requests.append(request)
        if isinstance(self._answer, BaseException):
            raise self._answer
        if isinstance(self._answer, httpx.Response):
            return self._answer
        return _chat_reply(self._answer)

    @property
    def body(self) -> dict:
        assert len(self.requests) == 1
        return json.loads(self.requests[0].content)


def _serve_module_client(monkeypatch, answer) -> _Ollama:
    """Keep the real `enrichment._ollama_client`; replace only its transport."""
    ollama = _Ollama(answer)
    monkeypatch.setattr(enrichment._ollama_client, "_transport", ollama.transport)
    return ollama


async def _summarise(**overrides) -> str:
    kwargs = {"query": "Was steht an?", "sources_text": "Quelle eins."}
    return await summarise_for_speech(**{**kwargs, **overrides})


# --- prompts and HTTP payload --------------------------------------------------


async def test_german_prompt_and_exact_http_payload(monkeypatch) -> None:
    ollama = _serve_module_client(monkeypatch, "Heute ist Montag.")

    summary = await _summarise(query="Was steht an?", sources_text="Quelle eins.")

    assert summary == "Heute ist Montag."
    request = ollama.requests[0]
    assert request.method == "POST"
    assert str(request.url) == f"{enrichment._ollama_client.base_url}/api/chat"
    assert ollama.body == {
        "model": enrichment._ollama_client.model,
        "messages": [
            {"role": "system", "content": DE_SYSTEM},
            {"role": "user", "content": "Frage: Was steht an?\n\nQuellen:\nQuelle eins."},
        ],
        "stream": False,
        "options": {"num_ctx": enrichment.OLLAMA_NUM_CTX, "temperature": 0.2},
    }
    assert "format" not in ollama.body
    assert request.extensions["timeout"]["read"] == enrichment.OLLAMA_TIMEOUT


async def test_english_prompt(monkeypatch) -> None:
    ollama = _serve_module_client(monkeypatch, "Today is Monday.")

    summary = await _summarise(query="What is on?", sources_text="Source one.", response_language="en")

    assert summary == "Today is Monday."
    assert ollama.body["messages"] == [
        {"role": "system", "content": EN_SYSTEM},
        {"role": "user", "content": "Question: What is on?\n\nSources:\nSource one."},
    ]


@pytest.mark.parametrize("language", ["fr", "", "EN", "de-DE"])
async def test_unsupported_language_falls_back_to_german(monkeypatch, language) -> None:
    ollama = _serve_module_client(monkeypatch, "ok")

    await _summarise(query="Q", sources_text="S", response_language=language)

    assert ollama.body["messages"] == [
        {"role": "system", "content": DE_SYSTEM},
        {"role": "user", "content": "Frage: Q\n\nQuellen:\nS"},
    ]


async def test_language_defaults_to_german(monkeypatch) -> None:
    ollama = _serve_module_client(monkeypatch, "ok")

    await summarise_for_speech(query="Q", sources_text="S")

    assert ollama.body["messages"][0] == {"role": "system", "content": DE_SYSTEM}


async def test_wrapper_reads_the_current_context_window_on_each_call(monkeypatch) -> None:
    ollama = _serve_module_client(monkeypatch, "ok")

    monkeypatch.setattr(enrichment, "OLLAMA_NUM_CTX", 1111)
    await _summarise()
    monkeypatch.setattr(enrichment, "OLLAMA_NUM_CTX", 2222)
    await _summarise()

    contexts = [json.loads(r.content)["options"]["num_ctx"] for r in ollama.requests]
    assert contexts == [1111, 2222]


async def test_wrapper_uses_the_current_module_client(monkeypatch) -> None:
    replacement = _Ollama("von der Ersatz-Instanz")
    monkeypatch.setattr(
        enrichment,
        "_ollama_client",
        OllamaClient(
            base_url="http://replacement.test",
            model="other-model",
            timeout_seconds=5.0,
            transport=replacement.transport,
        ),
    )

    summary = await _summarise()

    assert summary == "von der Ersatz-Instanz"
    assert str(replacement.requests[0].url) == "http://replacement.test/api/chat"
    assert replacement.body["model"] == "other-model"


# --- cleanup --------------------------------------------------------------------


@pytest.mark.parametrize(
    "raw, expected",
    [
        ("Alles **gut** und *klar*.", "Alles gut und klar."),
        ("```\nCode bleibt\n```", "Code bleibt"),
        ("- Erster Punkt\n- Zweiter Punkt", "Erster Punkt Zweiter Punkt"),
        ("• Eins\n· Zwei\n— Drei", "Eins Zwei Drei"),
        ("-- - Punkt", "Punkt"),
        ("Satz eins.\n\n   \nSatz zwei.", "Satz eins. Satz zwei."),
        ("  umrahmt  ", "umrahmt"),
        ("Ein Bindestrich-Wort bleibt.", "Ein Bindestrich-Wort bleibt."),
    ],
)
async def test_residual_markdown_and_bullets_are_cleaned(monkeypatch, raw, expected) -> None:
    _serve_module_client(monkeypatch, raw)

    assert await _summarise() == expected


@pytest.mark.parametrize("raw", ["***", "```", "**", "-", "- *"])
async def test_markdown_only_output_is_returned_as_an_empty_string(monkeypatch, raw) -> None:
    _serve_module_client(monkeypatch, raw)

    assert await _summarise() == ""


@pytest.mark.parametrize(
    "response",
    [
        _chat_reply("   \n\t "),
        httpx.Response(200, json={"message": {"content": ""}}),
        httpx.Response(200, json={}),
        httpx.Response(200, json=["not", "a", "dict"]),
    ],
)
async def test_blank_output_is_an_empty_response_error(monkeypatch, response) -> None:
    _serve_module_client(monkeypatch, response)

    with pytest.raises(EnrichmentSummariserUnavailable) as caught:
        await _summarise()

    assert str(caught.value) == "ollama_empty_response"
    assert caught.value.__cause__ is None


# --- error translation ----------------------------------------------------------


@pytest.mark.parametrize(
    "failure, message, cause_type",
    [
        (httpx.ConnectError("refused"), "ollama_unreachable: refused", OllamaUnavailableError),
        (httpx.ReadTimeout("slow"), "ollama_timeout: slow", OllamaTimeoutError),
        (httpx.ConnectTimeout("slow connect"), "ollama_timeout: slow connect", OllamaTimeoutError),
        (
            httpx.RemoteProtocolError("bad framing"),
            "ollama_error: transport error: bad framing",
            OllamaEngineError,
        ),
        (httpx.Response(500, json={"error": "boom"}), "ollama_status_500", OllamaEngineError),
        (httpx.Response(404, text="model not found"), "ollama_status_404", OllamaEngineError),
        (
            httpx.Response(200, content=b"<html>"),
            "ollama_error: invalid JSON from ollama: Expecting value: line 1 column 1 (char 0)",
            OllamaEngineError,
        ),
    ],
)
async def test_ollama_failures_become_summariser_unavailable(
    monkeypatch, failure, message, cause_type
) -> None:
    _serve_module_client(monkeypatch, failure)

    with pytest.raises(EnrichmentSummariserUnavailable) as caught:
        await _summarise()

    assert str(caught.value) == message
    assert isinstance(caught.value.__cause__, cause_type)


# --- SpeechSummariser with explicit configuration ----------------------------------


def _summariser(ollama: _Ollama, *, num_ctx: int = 4096) -> SpeechSummariser:
    client = OllamaClient(
        base_url="http://ollama.test",
        model="test-model",
        timeout_seconds=5.0,
        transport=ollama.transport,
    )
    return SpeechSummariser(client=client, num_ctx=num_ctx)


async def test_summariser_uses_its_own_client_and_context_window() -> None:
    ollama = _Ollama("**Fertig.**")

    summary = await _summariser(ollama, num_ctx=4096).summarise(
        query="Q", sources_text="S", response_language="en"
    )

    assert summary == "Fertig."
    assert str(ollama.requests[0].url) == "http://ollama.test/api/chat"
    assert ollama.body == {
        "model": "test-model",
        "messages": [
            {"role": "system", "content": EN_SYSTEM},
            {"role": "user", "content": "Question: Q\n\nSources:\nS"},
        ],
        "stream": False,
        "options": {"num_ctx": 4096, "temperature": 0.2},
    }


async def test_summariser_language_defaults_to_german_and_falls_back() -> None:
    default = _Ollama("ok")
    await _summariser(default).summarise(query="Q", sources_text="S")
    fallback = _Ollama("ok")
    await _summariser(fallback).summarise(query="Q", sources_text="S", response_language="fr")

    assert default.body["messages"] == fallback.body["messages"]
    assert default.body["messages"][0]["content"] == DE_SYSTEM


async def test_summariser_does_not_touch_module_configuration(monkeypatch) -> None:
    module_ollama = _serve_module_client(monkeypatch, "unused")
    own = _Ollama("eigener Client")

    summary = await _summariser(own).summarise(query="Q", sources_text="S")

    assert summary == "eigener Client"
    assert module_ollama.requests == []


async def test_summariser_translates_errors_and_keeps_the_cause() -> None:
    with pytest.raises(EnrichmentSummariserUnavailable) as caught:
        await _summariser(_Ollama(httpx.ConnectError("refused"))).summarise(
            query="Q", sources_text="S"
        )

    assert str(caught.value) == "ollama_unreachable: refused"
    assert isinstance(caught.value.__cause__, OllamaUnavailableError)

    with pytest.raises(EnrichmentSummariserUnavailable, match="^ollama_empty_response$"):
        await _summariser(_Ollama("  ")).summarise(query="Q", sources_text="S")


# --- /lightrag/query end to end ------------------------------------------------------


class _Upstreams:
    """One HTTP boundary for the router's real LightRAG client and the real
    module Ollama client: `/query` is LightRAG, `/api/chat` is Ollama."""

    def __init__(self, *, lightrag, ollama) -> None:
        self._lightrag = lightrag
        self._ollama = ollama
        self.requests: list[httpx.Request] = []
        self.transport = httpx.MockTransport(self._handle)

    def _handle(self, request: httpx.Request) -> httpx.Response:
        self.requests.append(request)
        answer = self._lightrag if request.url.path == "/query" else self._ollama
        if isinstance(answer, BaseException):
            raise answer
        return answer

    def at(self, path: str) -> list[httpx.Request]:
        return [r for r in self.requests if r.url.path == path]


def _route_client(monkeypatch, *, lightrag, ollama):
    upstreams = _Upstreams(lightrag=lightrag, ollama=ollama)
    monkeypatch.setattr(lightrag_router._lightrag_client, "_base_url_override", "http://lightrag.test")
    monkeypatch.setattr(lightrag_router._lightrag_client, "_api_key_override", "")
    monkeypatch.setattr(lightrag_router._lightrag_client, "_transport", upstreams.transport)
    monkeypatch.setattr(enrichment._ollama_client, "_transport", upstreams.transport)
    return client_for(lightrag_router.router, monkeypatch), upstreams


def _lightrag_reply(text: str) -> httpx.Response:
    return httpx.Response(200, json={"response": text})


def test_lightrag_query_summarises_the_real_lightrag_answer(monkeypatch) -> None:
    client, upstreams = _route_client(
        monkeypatch,
        lightrag=_lightrag_reply("  - Board-Deck: offen  "),
        ollama=_chat_reply("**Das Board-Deck** ist noch offen."),
    )

    resp = client.post(
        "/lightrag/query",
        headers=auth(),
        json={"query": "was lief gestern?", "mode": "local", "response_language": "en", "top_k": 3},
    )

    assert resp.status_code == 200, resp.text
    assert resp.json() == {
        "summary": "Das Board-Deck ist noch offen.",
        "response_language": "en",
        "raw_response": "- Board-Deck: offen",
    }
    assert json.loads(upstreams.at("/query")[0].content) == {
        "query": "was lief gestern?",
        "mode": "local",
        "top_k": 3,
    }
    chat = json.loads(upstreams.at("/api/chat")[0].content)
    assert chat["messages"] == [
        {"role": "system", "content": EN_SYSTEM},
        {
            "role": "user",
            "content": "Question: was lief gestern?\n\nSources:\n- Board-Deck: offen",
        },
    ]
    assert chat["options"] == {"num_ctx": enrichment.OLLAMA_NUM_CTX, "temperature": 0.2}


def test_lightrag_query_without_a_bearer_token_never_reaches_an_upstream(monkeypatch) -> None:
    client, upstreams = _route_client(
        monkeypatch, lightrag=_lightrag_reply("x"), ollama=_chat_reply("y")
    )

    resp = client.post("/lightrag/query", json={"query": "was lief gestern?"})

    assert resp.status_code in (401, 403)
    assert upstreams.requests == []


def test_lightrag_query_with_no_hits_still_summarises_the_placeholder(monkeypatch) -> None:
    client, upstreams = _route_client(
        monkeypatch, lightrag=_lightrag_reply("   "), ollama=_chat_reply("Nichts gefunden.")
    )

    resp = client.post("/lightrag/query", headers=auth(), json={"query": "was lief gestern?"})

    assert resp.json()["raw_response"] == "(LightRAG hat keine Treffer geliefert.)"
    chat = json.loads(upstreams.at("/api/chat")[0].content)
    assert chat["messages"][1]["content"].endswith(
        "Quellen:\n(LightRAG hat keine Treffer geliefert.)"
    )


@pytest.mark.parametrize(
    "ollama, code, status",
    [
        (httpx.ConnectError("refused"), "ollama_unavailable", 503),
        (httpx.ReadTimeout("slow"), "ollama_timeout", 503),
        (httpx.Response(500, json={"error": "boom"}), "ollama_engine_error", 502),
        (httpx.Response(200, content=b"<html>"), "ollama_engine_error", 502),
        (_chat_reply("   "), "ollama_engine_error", 502),
    ],
)
def test_lightrag_query_maps_real_summariser_failures(monkeypatch, ollama, code, status) -> None:
    client, upstreams = _route_client(
        monkeypatch, lightrag=_lightrag_reply("Treffer"), ollama=ollama
    )

    resp = client.post("/lightrag/query", headers=auth(), json={"query": "was lief gestern?"})

    assert_failure(resp, code=code, upstream="ollama", status=status, retryable=True)
    assert len(upstreams.at("/api/chat")) == 1


@pytest.mark.parametrize(
    "lightrag, code, status",
    [
        (httpx.ConnectError("refused"), "lightrag_unavailable", 503),
        (httpx.ReadTimeout("slow"), "lightrag_timeout", 503),
        (httpx.Response(500, json={"detail": "boom"}), "lightrag_engine_error", 502),
        (httpx.Response(200, content=b"<html>"), "lightrag_engine_error", 502),
    ],
)
def test_lightrag_query_maps_real_lightrag_failures(monkeypatch, lightrag, code, status) -> None:
    client, upstreams = _route_client(
        monkeypatch, lightrag=lightrag, ollama=_chat_reply("unused")
    )

    resp = client.post("/lightrag/query", headers=auth(), json={"query": "was lief gestern?"})

    assert_failure(resp, code=code, upstream="lightrag", status=status, retryable=True)
    assert upstreams.at("/api/chat") == []
