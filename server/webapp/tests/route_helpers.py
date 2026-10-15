"""Shared pieces for the upstream-failure route tests (UFH-02): a test client
per router, the bearer header, one assertion for the contract body, and a real
`MSGraphClient` over a mock Graph transport and a scripted MSAL app."""

from __future__ import annotations

import httpx
import requests
from fastapi import APIRouter, FastAPI
from fastapi.testclient import TestClient

import msgraph_client
import upstream_failure

BEARER = "test-bearer-token"


def client_for(router: APIRouter, monkeypatch) -> TestClient:
    monkeypatch.setenv("IOS_BEARER_TOKEN", BEARER)
    monkeypatch.delenv("MSGRAPH_FIXTURE_MODE", raising=False)
    app = FastAPI()
    upstream_failure.install(app)
    app.include_router(router)
    return TestClient(app)


def auth() -> dict[str, str]:
    return {"Authorization": f"Bearer {BEARER}"}


def assert_failure(
    resp: httpx.Response, *, code: str, upstream: str, status: int, retryable: bool
) -> dict:
    body = resp.json()
    assert resp.status_code == status, body
    assert body["code"] == code
    assert body["upstream"] == upstream
    assert body["retryable"] is retryable
    assert body["detail"] == code or body["detail"].startswith(f"{code}: ")
    return body


def raising(exc: BaseException):
    """An async stub that raises `exc` whatever it is called with."""

    async def _raise(*_args, **_kwargs):
        raise exc

    return _raise


def graph_client(
    monkeypatch,
    tmp_path,
    handler=None,
    *,
    accounts: list | None = None,
    token_result: object = None,
) -> msgraph_client.MSGraphClient:
    """A real `MSGraphClient` whose Graph calls go to `handler` and whose MSAL
    app answers `accounts` / `token_result` (a dict, None, or an exception to raise)."""
    scripted_accounts = [{"home_account_id": "me"}] if accounts is None else accounts
    scripted_result = {"access_token": "tok"} if token_result is None else token_result

    class _MsalApp:
        def __init__(self, *_args, **_kwargs) -> None:
            pass

        def get_accounts(self) -> list:
            return scripted_accounts

        def acquire_token_silent(self, **_kwargs):
            if isinstance(scripted_result, BaseException):
                raise scripted_result
            return scripted_result

    monkeypatch.setattr(msgraph_client.msal, "PublicClientApplication", _MsalApp)

    async def no_sleep(_seconds: float) -> None:
        return None

    monkeypatch.setattr(msgraph_client.asyncio, "sleep", no_sleep)
    client = msgraph_client.MSGraphClient("cid", "tid", cache_path=tmp_path / "msal.bin")
    if handler is not None:
        client._http = httpx.AsyncClient(transport=httpx.MockTransport(handler))
    return client


def serve_graph(monkeypatch, router_module, client: msgraph_client.MSGraphClient) -> None:
    """Make `router_module.get_client()` return `client`."""

    async def get_client() -> msgraph_client.MSGraphClient:
        return client

    monkeypatch.setattr(router_module, "get_client", get_client)


def _graph_raises(exc: Exception):
    def handler(_request: httpx.Request) -> httpx.Response:
        raise exc

    return handler


def _graph_answers(status: int, headers: dict | None = None):
    def handler(_request: httpx.Request) -> httpx.Response:
        return httpx.Response(status, headers=headers, json={"error": {"code": "x", "message": "y"}})

    return handler


# (id, graph_client kwargs, expected code, status, retryable, Retry-After header)
GRAPH_SCENARIOS = [
    ("down", {"handler": _graph_raises(httpx.ConnectError("refused"))},
     "msgraph_unavailable", 503, True, None),
    ("slow", {"handler": _graph_raises(httpx.ReadTimeout("slow"))},
     "msgraph_unavailable", 503, True, None),
    ("protocol-error", {"handler": _graph_raises(httpx.RemoteProtocolError("bad framing"))},
     "msgraph_engine_error", 502, True, None),
    ("rate-limited", {"handler": _graph_answers(429, {"Retry-After": "7"})},
     "msgraph_rate_limited", 429, True, "7"),
    ("rate-limited-no-wait", {"handler": _graph_answers(429)},
     "msgraph_rate_limited", 429, True, None),
    ("graph-5xx", {"handler": _graph_answers(503)},
     "msgraph_engine_error", 502, True, None),
    ("graph-4xx", {"handler": _graph_answers(400)},
     "msgraph_engine_error", 502, True, None),
    ("msal-network", {"token_result": requests.ConnectionError("no route")},
     "msgraph_unavailable", 503, True, None),
    ("msal-error", {"token_result": ValueError("bad scope")},
     "msgraph_engine_error", 502, True, None),
    ("no-account", {"accounts": []},
     "msgraph_not_bootstrapped", 503, False, None),
    ("refresh-revoked", {"token_result": {"error": "invalid_grant"}},
     "msgraph_not_bootstrapped", 503, False, None),
]
