"""Email-result projection (REF-134) and `GET /email/search` success flow.

`prepare_email_results` is characterised directly. The route tests drive the
real route, projection and enrichment summariser. Fixture mode reads the real
fixture files; live mode keeps the real `get_client` factory and
`MSGraphClient.get_json` over a fake MSAL app and an intercepted HTTP client.
`OllamaClient.chat` runs for real over a mock transport. No live service is
contacted.
"""

from __future__ import annotations

import json

import httpx
import pytest

import enrichment
import msgraph_client
import routers.email as email_router
from email_results import EmailResults, prepare_email_results
from tests.route_helpers import auth, client_for


def _msg(**overrides) -> dict:
    raw = {
        "id": "m1",
        "subject": "Budget",
        "from": {"emailAddress": {"name": "Ada Lovelace", "address": "ada@example.com"}},
        "receivedDateTime": "2026-03-10T09:00:00Z",
        "bodyPreview": "Zahlen anbei.",
        "webLink": "https://mail.example/m1",
    }
    return {**raw, **overrides}


def _ids(results: EmailResults) -> list[str]:
    return [link["id"] for link in results.links]


# --- projection ---------------------------------------------------------------


def test_full_message_is_projected_byte_for_byte() -> None:
    results = prepare_email_results([_msg()], None, None)

    assert results == EmailResults(
        sources_text="- Von Ada Lovelace (2026-03-10T09:00:00Z): Budget. Zahlen anbei.",
        links=[
            {
                "id": "m1",
                "subject": "Budget",
                "sender": "Ada Lovelace",
                "received": "2026-03-10T09:00:00Z",
                "web_link": "https://mail.example/m1",
            }
        ],
    )


def test_sender_falls_back_to_address_then_empty() -> None:
    results = prepare_email_results(
        [
            _msg(id="a", **{"from": {"emailAddress": {"name": "", "address": "a@example.com"}}}),
            _msg(id="b", **{"from": {"emailAddress": {}}}),
            _msg(id="c", **{"from": None}),
            _msg(id="d", **{"from": {"emailAddress": None}}),
        ],
        None,
        None,
    )

    assert [link["sender"] for link in results.links] == ["a@example.com", "", "", ""]
    assert results.sources_text.splitlines()[0].startswith("- Von a@example.com (")
    assert results.sources_text.splitlines()[1].startswith("- Von  (")


def test_missing_fields_become_empty_strings() -> None:
    results = prepare_email_results([{}], None, None)

    assert results.links == [
        {"id": "", "subject": "", "sender": "", "received": "", "web_link": ""}
    ]
    assert results.sources_text == "- Von  (): . "


def test_empty_results_use_the_no_hits_text() -> None:
    assert prepare_email_results([], None, None) == EmailResults("(keine Treffer)", [])
    assert prepare_email_results([], "2026-03-01T00:00:00Z", None) == EmailResults(
        "(keine Treffer)", []
    )


def test_body_preview_is_stripped_newlines_replaced_and_cut_at_400() -> None:
    body = "  erste\nzweite\n" + "x" * 500 + "  "
    expected_body = ("erste zweite " + "x" * 500)[:400]

    results = prepare_email_results([_msg(bodyPreview=body)], None, None)

    assert results.sources_text == (
        f"- Von Ada Lovelace (2026-03-10T09:00:00Z): Budget. {expected_body}"
    )
    assert len(expected_body) == 400


def test_body_preview_missing_or_none_is_empty() -> None:
    results = prepare_email_results(
        [_msg(id="a", bodyPreview=None), _msg(id="b", bodyPreview="")], None, None
    )

    assert results.sources_text == "\n".join(
        ["- Von Ada Lovelace (2026-03-10T09:00:00Z): Budget. "] * 2
    )


def test_order_is_retrieval_order_not_date_order() -> None:
    results = prepare_email_results(
        [
            _msg(id="late", receivedDateTime="2026-03-12T00:00:00Z"),
            _msg(id="early", receivedDateTime="2026-03-01T00:00:00Z"),
            _msg(id="mid", receivedDateTime="2026-03-05T00:00:00Z"),
        ],
        "2026-02-01T00:00:00Z",
        None,
    )

    assert _ids(results) == ["late", "early", "mid"]
    assert results.sources_text.splitlines() == [
        "- Von Ada Lovelace (2026-03-12T00:00:00Z): Budget. Zahlen anbei.",
        "- Von Ada Lovelace (2026-03-01T00:00:00Z): Budget. Zahlen anbei.",
        "- Von Ada Lovelace (2026-03-05T00:00:00Z): Budget. Zahlen anbei.",
    ]


def test_window_is_inclusive_at_both_ends() -> None:
    messages = [
        _msg(id="before", receivedDateTime="2026-03-09T23:59:59Z"),
        _msg(id="start", receivedDateTime="2026-03-10T00:00:00Z"),
        _msg(id="inside", receivedDateTime="2026-03-10T12:00:00Z"),
        _msg(id="end", receivedDateTime="2026-03-11T00:00:00Z"),
        _msg(id="after", receivedDateTime="2026-03-11T00:00:01Z"),
    ]

    results = prepare_email_results(messages, "2026-03-10T00:00:00Z", "2026-03-11T00:00:00Z")

    assert _ids(results) == ["start", "inside", "end"]


def test_one_sided_windows() -> None:
    messages = [
        _msg(id="a", receivedDateTime="2026-03-01T00:00:00Z"),
        _msg(id="b", receivedDateTime="2026-03-20T00:00:00Z"),
    ]

    assert _ids(prepare_email_results(messages, "2026-03-10T00:00:00Z", None)) == ["b"]
    assert _ids(prepare_email_results(messages, None, "2026-03-10T00:00:00Z")) == ["a"]
    assert _ids(prepare_email_results(messages, "", "2026-03-10T00:00:00Z")) == ["a"]


def test_offsets_are_compared_as_instants() -> None:
    messages = [_msg(id="a", receivedDateTime="2026-03-10T10:00:00+02:00")]

    assert _ids(prepare_email_results(messages, "2026-03-10T08:00:00Z", "2026-03-10T08:00:00Z")) == [
        "a"
    ]
    assert _ids(prepare_email_results(messages, "2026-03-10T08:00:01Z", None)) == []


def test_no_bounds_keeps_messages_without_a_usable_date() -> None:
    messages = [
        _msg(id="ok"),
        _msg(id="missing", receivedDateTime=None),
        _msg(id="invalid", receivedDateTime="gestern"),
    ]

    assert _ids(prepare_email_results(messages, None, None)) == ["ok", "missing", "invalid"]
    assert _ids(prepare_email_results(messages, "", "")) == ["ok", "missing", "invalid"]


def test_missing_or_invalid_received_date_is_dropped_under_a_bound() -> None:
    messages = [
        _msg(id="ok"),
        _msg(id="missing", receivedDateTime=None),
        {k: v for k, v in _msg(id="absent").items() if k != "receivedDateTime"},
        _msg(id="invalid", receivedDateTime="gestern"),
        _msg(id="empty", receivedDateTime=""),
    ]

    assert _ids(prepare_email_results(messages, "2026-01-01T00:00:00Z", None)) == ["ok"]


def test_invalid_bounds_are_ignored_but_the_filter_still_runs() -> None:
    messages = [
        _msg(id="ok", receivedDateTime="2026-03-10T09:00:00Z"),
        _msg(id="invalid", receivedDateTime="gestern"),
    ]

    assert _ids(prepare_email_results(messages, "nonsense", None)) == ["ok"]
    assert _ids(prepare_email_results(messages, "nonsense", "also nonsense")) == ["ok"]
    # A valid bound next to an invalid one still applies.
    assert _ids(prepare_email_results(messages, "nonsense", "2026-03-01T00:00:00Z")) == []


@pytest.mark.parametrize(
    "received, from_iso, to_iso",
    [
        ("2026-03-10T09:00:00Z", "2026-03-10T00:00:00", None),
        ("2026-03-10T09:00:00", "2026-03-10T00:00:00Z", None),
        ("2026-03-10T09:00:00Z", None, "2026-03-11T00:00:00"),
    ],
    ids=["naive-from", "naive-received", "naive-to"],
)
def test_mixing_aware_and_naive_datetimes_raises_type_error(received, from_iso, to_iso) -> None:
    with pytest.raises(TypeError):
        prepare_email_results([_msg(receivedDateTime=received)], from_iso, to_iso)


def test_naive_values_on_both_sides_compare_fine() -> None:
    messages = [_msg(receivedDateTime="2026-03-10T09:00:00")]

    assert _ids(prepare_email_results(messages, "2026-03-10T00:00:00", None)) == ["m1"]


def test_input_messages_are_not_mutated() -> None:
    messages = [_msg()]
    snapshot = json.loads(json.dumps(messages))

    prepare_email_results(messages, "2026-01-01T00:00:00Z", "2027-01-01T00:00:00Z")

    assert messages == snapshot


# --- GET /email/search ----------------------------------------------------------


class _Ollama:
    """Real `OllamaClient.chat` over a mock transport that records the request."""

    def __init__(self, monkeypatch, answer: str = "Zusammenfassung.") -> None:
        self.requests: list[httpx.Request] = []
        self._answer = answer
        transport = httpx.MockTransport(self._handle)
        monkeypatch.setattr(enrichment._ollama_client, "_transport", transport)

    def _handle(self, request: httpx.Request) -> httpx.Response:
        self.requests.append(request)
        return httpx.Response(200, json={"message": {"content": self._answer}})

    @property
    def user_prompt(self) -> str:
        assert len(self.requests) == 1
        return json.loads(self.requests[0].content)["messages"][1]["content"]


def _fixture_mode(monkeypatch, tmp_path) -> None:
    monkeypatch.setenv("DATA_DIR", str(tmp_path))
    monkeypatch.setenv("MSGRAPH_FIXTURE_MODE", "true")


def test_fixture_mode_search_returns_projected_links_and_sends_sources(
    monkeypatch, tmp_path
) -> None:
    (tmp_path / "fixtures").mkdir()
    (tmp_path / "fixtures" / "email_search.json").write_text(
        json.dumps(
            {
                "value": [
                    _msg(id="f1", subject="Budget Q1", receivedDateTime="2026-03-10T09:00:00Z"),
                    _msg(id="f2", subject="Budget Q2", receivedDateTime="2026-04-10T09:00:00Z"),
                    _msg(id="f3", subject="Budget Q3", receivedDateTime="2026-03-20T09:00:00Z"),
                    _msg(id="f4", subject="Lunch", receivedDateTime="2026-03-11T09:00:00Z"),
                ]
            }
        )
    )
    client = client_for(email_router.router, monkeypatch)
    _fixture_mode(monkeypatch, tmp_path)
    ollama = _Ollama(monkeypatch)

    resp = client.get(
        "/email/search",
        params={
            "q": "budget",
            "from": "2026-03-01T00:00:00Z",
            "to": "2026-03-31T23:59:59Z",
            "response_language": "en",
        },
        headers=auth(),
    )

    assert resp.status_code == 200, resp.text
    assert resp.json() == {
        "summary": "Zusammenfassung.",
        "source_count": 2,
        "response_language": "en",
        "links": [
            {
                "id": "f1",
                "subject": "Budget Q1",
                "sender": "Ada Lovelace",
                "received": "2026-03-10T09:00:00Z",
                "web_link": "https://mail.example/m1",
            },
            {
                "id": "f3",
                "subject": "Budget Q3",
                "sender": "Ada Lovelace",
                "received": "2026-03-20T09:00:00Z",
                "web_link": "https://mail.example/m1",
            },
        ],
    }
    assert ollama.user_prompt == (
        "Question: budget\n\nSources:\n"
        "- Von Ada Lovelace (2026-03-10T09:00:00Z): Budget Q1. Zahlen anbei.\n"
        "- Von Ada Lovelace (2026-03-20T09:00:00Z): Budget Q3. Zahlen anbei."
    )


def test_fixture_mode_slices_to_top_before_filtering_by_date(monkeypatch, tmp_path) -> None:
    (tmp_path / "fixtures").mkdir()
    (tmp_path / "fixtures" / "email_search.json").write_text(
        json.dumps(
            {
                "value": [
                    _msg(id="old", receivedDateTime="2025-01-01T00:00:00Z"),
                    _msg(id="new1", receivedDateTime="2026-03-10T00:00:00Z"),
                    _msg(id="new2", receivedDateTime="2026-03-11T00:00:00Z"),
                ]
            }
        )
    )
    client = client_for(email_router.router, monkeypatch)
    _fixture_mode(monkeypatch, tmp_path)
    _Ollama(monkeypatch)

    resp = client.get(
        "/email/search",
        params={"q": "budget", "from": "2026-01-01T00:00:00Z", "top": 2},
        headers=auth(),
    )

    assert resp.status_code == 200, resp.text
    body = resp.json()
    assert [link["id"] for link in body["links"]] == ["new1"]
    assert body["source_count"] == 1


def test_fixture_mode_without_hits_sends_the_no_hits_text(monkeypatch, tmp_path) -> None:
    client = client_for(email_router.router, monkeypatch)
    _fixture_mode(monkeypatch, tmp_path)
    ollama = _Ollama(monkeypatch)

    resp = client.get("/email/search", params={"q": "zzz-no-such-mail"}, headers=auth())

    assert resp.status_code == 200, resp.text
    assert resp.json() == {
        "summary": "Zusammenfassung.",
        "source_count": 0,
        "response_language": "de",
        "links": [],
    }
    assert ollama.user_prompt == "Frage: zzz-no-such-mail\n\nQuellen:\n(keine Treffer)"


def test_fixture_mode_bundled_fixture_is_projected_in_file_order(monkeypatch, tmp_path) -> None:
    client = client_for(email_router.router, monkeypatch)
    _fixture_mode(monkeypatch, tmp_path)
    ollama = _Ollama(monkeypatch)

    resp = client.get("/email/search", params={"q": "board-deck"}, headers=auth())

    assert resp.status_code == 200, resp.text
    body = resp.json()
    assert [link["id"] for link in body["links"]] == ["FIXTURE-msg-board-deck"]
    assert body["links"][0]["sender"] == "Sabine Lehmann"
    assert body["source_count"] == 1
    assert "- Von Sabine Lehmann (" in ollama.user_prompt
    assert "): Board-Deck draft — Q2 update. Anbei der erste Entwurf" in ollama.user_prompt


class _Graph:
    """Live-Graph mode: the real `get_client` and `MSGraphClient.get_json` over
    a fake MSAL app and an intercepted HTTP client."""

    def __init__(self, monkeypatch, tmp_path, messages: list[dict] | None) -> None:
        self.requests: list[httpx.Request] = []
        self._messages = messages

        class _MsalApp:
            def __init__(self, *_args, **_kwargs) -> None:
                pass

            def get_accounts(self) -> list:
                return [{"home_account_id": "me"}]

            def acquire_token_silent(self, **_kwargs) -> dict:
                return {"access_token": "tok"}

        monkeypatch.setattr(msgraph_client.msal, "PublicClientApplication", _MsalApp)
        monkeypatch.setattr(msgraph_client, "_instance", None)
        monkeypatch.setenv("MSGRAPH_CLIENT_ID", "cid")
        monkeypatch.setenv("MSGRAPH_TENANT_ID", "tid")
        monkeypatch.setenv("MSGRAPH_CACHE_PATH", str(tmp_path / "msal.bin"))
        http = httpx.AsyncClient(transport=httpx.MockTransport(self._handle))
        monkeypatch.setattr(msgraph_client.MSGraphClient, "_client", property(lambda _self: http))

    def _handle(self, request: httpx.Request) -> httpx.Response:
        self.requests.append(request)
        return httpx.Response(200, json={"value": self._messages})

    @property
    def request(self) -> httpx.Request:
        assert len(self.requests) == 1
        return self.requests[0]


def test_graph_mode_search_queries_graph_and_projects_the_window(monkeypatch, tmp_path) -> None:
    client = client_for(email_router.router, monkeypatch)
    graph = _Graph(
        monkeypatch,
        tmp_path,
        [
            _msg(id="g1", subject="Rechnung", bodyPreview="Zeile eins\nZeile zwei"),
            _msg(id="g2", subject="Alt", receivedDateTime="2025-01-01T00:00:00Z"),
            _msg(
                id="g3",
                subject="Neu",
                receivedDateTime="2026-03-11T00:00:00Z",
                **{"from": {"emailAddress": {"address": "bob@example.com"}}},
            ),
            _msg(id="g4", subject="Ohne Datum", receivedDateTime=None),
        ],
    )
    ollama = _Ollama(monkeypatch)

    resp = client.get(
        "/email/search",
        params={"q": "Rechnung", "from": "2026-03-01T00:00:00Z", "top": 4},
        headers=auth(),
    )

    assert resp.status_code == 200, resp.text
    assert graph.request.method == "GET"
    assert graph.request.url.path == "/v1.0/me/messages"
    assert dict(graph.request.url.params) == {
        "$search": '"Rechnung"',
        "$top": "4",
        "$select": "id,subject,from,receivedDateTime,bodyPreview,webLink",
    }
    assert "$orderby" not in graph.request.url.params
    assert "$filter" not in graph.request.url.params
    body = resp.json()
    assert body["source_count"] == 2
    assert body["response_language"] == "de"
    assert body["summary"] == "Zusammenfassung."
    assert body["links"] == [
        {
            "id": "g1",
            "subject": "Rechnung",
            "sender": "Ada Lovelace",
            "received": "2026-03-10T09:00:00Z",
            "web_link": "https://mail.example/m1",
        },
        {
            "id": "g3",
            "subject": "Neu",
            "sender": "bob@example.com",
            "received": "2026-03-11T00:00:00Z",
            "web_link": "https://mail.example/m1",
        },
    ]
    assert ollama.user_prompt == (
        "Frage: Rechnung\n\nQuellen:\n"
        "- Von Ada Lovelace (2026-03-10T09:00:00Z): Rechnung. Zeile eins Zeile zwei\n"
        "- Von bob@example.com (2026-03-11T00:00:00Z): Neu. Zahlen anbei."
    )


def test_graph_mode_null_value_is_an_empty_result(monkeypatch, tmp_path) -> None:
    client = client_for(email_router.router, monkeypatch)
    graph = _Graph(monkeypatch, tmp_path, None)
    ollama = _Ollama(monkeypatch)

    resp = client.get("/email/search", params={"q": "x"}, headers=auth())

    assert resp.status_code == 200, resp.text
    assert resp.json()["links"] == []
    assert resp.json()["source_count"] == 0
    assert len(graph.requests) == 1
    assert ollama.user_prompt == "Frage: x\n\nQuellen:\n(keine Treffer)"


def test_graph_mode_aware_naive_mix_is_not_handled(monkeypatch, tmp_path) -> None:
    client = client_for(email_router.router, monkeypatch)
    _Graph(monkeypatch, tmp_path, [_msg()])
    ollama = _Ollama(monkeypatch)

    with pytest.raises(TypeError):
        client.get(
            "/email/search",
            params={"q": "x", "from": "2026-03-01T00:00:00"},
            headers=auth(),
        )

    assert ollama.requests == []


@pytest.mark.parametrize("headers", [{}, {"Authorization": "Bearer wrong"}], ids=["none", "wrong"])
def test_unauthorized_search_makes_no_upstream_calls(monkeypatch, tmp_path, headers) -> None:
    client = client_for(email_router.router, monkeypatch)
    graph = _Graph(monkeypatch, tmp_path, [_msg()])
    ollama = _Ollama(monkeypatch)

    resp = client.get("/email/search", params={"q": "budget"}, headers=headers)

    assert resp.status_code == 401
    assert graph.requests == []
    assert ollama.requests == []
    assert msgraph_client._instance is None


@pytest.mark.parametrize(
    "params",
    [{"q": ""}, {"q": "x" * 201}, {"q": "x", "top": 0}, {"q": "x", "top": 26}],
    ids=["empty-q", "long-q", "top-zero", "top-too-big"],
)
def test_query_and_top_constraints_reject_before_any_upstream_call(
    monkeypatch, tmp_path, params
) -> None:
    client = client_for(email_router.router, monkeypatch)
    graph = _Graph(monkeypatch, tmp_path, [_msg()])
    ollama = _Ollama(monkeypatch)

    resp = client.get("/email/search", params=params, headers=auth())

    assert resp.status_code == 422
    assert graph.requests == []
    assert ollama.requests == []


def test_unauthorized_fixture_mode_search_makes_no_upstream_calls(monkeypatch, tmp_path) -> None:
    client = client_for(email_router.router, monkeypatch)
    _fixture_mode(monkeypatch, tmp_path)
    ollama = _Ollama(monkeypatch)

    resp = client.get("/email/search", params={"q": "budget"})

    assert resp.status_code == 401
    assert ollama.requests == []
