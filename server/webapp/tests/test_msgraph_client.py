"""`MSGraphClient` failure wrapping (UFH-02): every transport exception and MSAL
failure leaves as `MSGraphError` / `MSGraphNotBootstrapped`, and an exhausted
429 backoff carries Graph's `Retry-After`."""

from __future__ import annotations

import asyncio

import httpx
import pytest
import requests

import msgraph_client
from msgraph_client import MSGraphError, MSGraphNotBootstrapped
from tests.route_helpers import graph_client


def _get(client, path: str = "/me/messages"):
    return asyncio.run(client.get_json(path))


def _answers(responses: list[httpx.Response]):
    calls: list[httpx.Request] = []

    def handler(request: httpx.Request) -> httpx.Response:
        calls.append(request)
        return responses[min(len(calls), len(responses)) - 1]

    handler.calls = calls
    return handler


def test_exhausted_429_backoff_exposes_retry_after(monkeypatch, tmp_path):
    handler = _answers([httpx.Response(429, headers={"Retry-After": "30"})])
    client = graph_client(monkeypatch, tmp_path, handler)

    with pytest.raises(MSGraphError, match="^rate_limited") as info:
        _get(client)

    assert info.value.retry_after == 30.0
    assert len(handler.calls) == 3  # first try + two backoff retries


def test_429_without_a_usable_retry_after_exposes_none(monkeypatch, tmp_path):
    handler = _answers([httpx.Response(429, headers={"Retry-After": "Wed, 21 Oct 2026 07:28:00 GMT"})])
    client = graph_client(monkeypatch, tmp_path, handler)

    with pytest.raises(MSGraphError, match="^rate_limited") as info:
        _get(client)

    assert info.value.retry_after is None


def test_429_that_clears_on_retry_returns_the_data(monkeypatch, tmp_path):
    handler = _answers([httpx.Response(429, headers={"Retry-After": "1"}), httpx.Response(200, json={"value": [1]})])
    client = graph_client(monkeypatch, tmp_path, handler)

    assert _get(client) == {"value": [1]}


@pytest.mark.parametrize(
    "exc, kind",
    [
        (httpx.ConnectError("refused"), "network_error"),
        (httpx.ReadTimeout("slow"), "network_error"),
        (httpx.RemoteProtocolError("server disconnected"), "transport_error"),
    ],
)
def test_transport_exceptions_become_msgraph_errors(monkeypatch, tmp_path, exc, kind):
    def handler(_request: httpx.Request) -> httpx.Response:
        raise exc

    client = graph_client(monkeypatch, tmp_path, handler)

    with pytest.raises(MSGraphError, match=f"^{kind}"):
        _get(client)


def test_a_200_with_a_non_json_body_is_a_bad_response(monkeypatch, tmp_path):
    client = graph_client(monkeypatch, tmp_path, _answers([httpx.Response(200, content=b"<html>")]))

    with pytest.raises(MSGraphError, match="^bad_response"):
        _get(client)


@pytest.mark.parametrize(
    "exc, kind",
    [
        (requests.ConnectionError("no route"), "network_error"),
        (requests.Timeout("slow"), "network_error"),
        (ValueError("bad scope"), "auth_error"),
    ],
)
def test_msal_exceptions_become_msgraph_errors(monkeypatch, tmp_path, exc, kind):
    client = graph_client(monkeypatch, tmp_path, token_result=exc)

    with pytest.raises(MSGraphError, match=f"^{kind}"):
        _get(client)


def test_no_account_and_failed_refresh_are_not_bootstrapped(monkeypatch, tmp_path):
    with pytest.raises(MSGraphNotBootstrapped):
        _get(graph_client(monkeypatch, tmp_path, accounts=[]))
    with pytest.raises(MSGraphNotBootstrapped):
        _get(graph_client(monkeypatch, tmp_path, token_result={"error": "invalid_grant"}))


@pytest.mark.parametrize(
    "body",
    [{"error": "invalid_request"}, {"error": {"message": None}}, ["unexpected"], "plain text"],
)
def test_graph_4xx_with_an_odd_error_body_is_still_a_graph_error(monkeypatch, tmp_path, body):
    client = graph_client(monkeypatch, tmp_path, _answers([httpx.Response(400, json=body)]))

    with pytest.raises(MSGraphError, match="^graph_error: status=400"):
        _get(client)


def test_a_200_with_a_non_object_body_is_a_bad_response(monkeypatch, tmp_path):
    client = graph_client(monkeypatch, tmp_path, _answers([httpx.Response(200, json=["x"])]))

    with pytest.raises(MSGraphError, match="^bad_response"):
        _get(client)


def test_other_httpx_request_errors_become_msgraph_errors(monkeypatch, tmp_path):
    def handler(_request: httpx.Request) -> httpx.Response:
        raise httpx.DecodingError("bad content-encoding")

    with pytest.raises(MSGraphError, match="^transport_error"):
        _get(graph_client(monkeypatch, tmp_path, handler))


@pytest.mark.parametrize(
    "raw, expected",
    [
        ("30", 30.0), ("0.5", 0.5), ("0", None), ("-3", None), ("soon", None),
        (None, None), ("inf", None), ("nan", None),
    ],
)
def test_parse_retry_after_only_accepts_a_finite_positive_wait(raw, expected):
    assert msgraph_client._parse_retry_after(raw) == expected


def test_a_cache_write_failure_does_not_fail_the_request(monkeypatch, tmp_path):
    def boom(*_args) -> None:
        raise OSError("disk full")

    monkeypatch.setattr(msgraph_client, "_persist_cache", boom)
    client = graph_client(monkeypatch, tmp_path, _answers([httpx.Response(200, json={"value": []})]))

    assert _get(client) == {"value": []}


def test_missing_client_or_tenant_id_is_not_bootstrapped():
    with pytest.raises(MSGraphNotBootstrapped):
        msgraph_client.MSGraphClient("", "tid")


@pytest.mark.parametrize(
    "exc, kind",
    [
        (requests.ConnectionError("no route"), "network_error"),
        (ValueError("bad authority"), "auth_error"),
    ],
)
def test_msal_construction_failures_become_msgraph_errors(monkeypatch, tmp_path, exc, kind):
    def broken_app(*_args, **_kwargs):
        raise exc

    monkeypatch.setattr(msgraph_client.msal, "PublicClientApplication", broken_app)

    with pytest.raises(MSGraphError, match=f"^{kind}"):
        msgraph_client.MSGraphClient("cid", "tid", cache_path=tmp_path / "msal.bin")
