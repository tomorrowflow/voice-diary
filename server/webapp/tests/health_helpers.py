"""Shared fakes for the health tests: `World` stands in for every upstream the
health check touches and builds the `HealthDependencies` that read from it."""

from __future__ import annotations

from collections.abc import Mapping

import httpx
import pytest

import analysis_route
import db
import msgraph_client
from health_checks import HealthDependencies

BLINDFOLD = "http://blindfold.test:8080/proxy"

ENV = {
    "QDRANT_URL": "http://qdrant.test:6333",
    "WHISPER_URL": "http://whisper.test:9000/",
    "LIGHTRAG_URL": "http://lightrag.test:9621",
    "OLLAMA_BASE_URL": "http://ollama.test:11434/",
    "MSGRAPH_CLIENT_ID": "client",
    "MSGRAPH_TENANT_ID": "tenant",
    "VOXTRAL_BASE_URL": "http://voxtral.test:8000",
}

URLS = {
    "qdrant": "http://qdrant.test:6333",
    "whisper": "http://whisper.test:9000/",
    "lightrag": "http://lightrag.test:9621/health",
    "ollama": "http://ollama.test:11434/api/tags",
}

OK_UPSTREAM = {
    "postgres": "ok",
    "qdrant": "ok",
    "whisper": "ok",
    "lightrag": "ok",
    "ollama": "ok",
    "msgraph": "ok",
    "voxtral": "ok",
}


def local_route() -> analysis_route.AnalysisRoute:
    return analysis_route.from_env({})


def blindfold_route(key: str | None = None) -> analysis_route.AnalysisRoute:
    env = {
        "ANALYSIS_ROUTE": "blindfold",
        "BLINDFOLD_BASE_URL": BLINDFOLD,
        "BLINDFOLD_ANALYSIS_MODEL": "frontier-1",
    }
    if key:
        env["BLINDFOLD_API_KEY"] = key
    return analysis_route.from_env(env)


class World:
    """Fake upstreams. `http` maps a URL to the status it answers with or the
    exception it raises; an unlisted URL answers 200. Every call is recorded."""

    def __init__(
        self,
        *,
        env: Mapping[str, str] = ENV,
        route: analysis_route.AnalysisRoute | None = None,
        http: Mapping[str, int | Exception] | None = None,
        postgres: Exception | None = None,
        voxtral: bool | Exception = True,
        msgraph_account: bool | Exception = True,
        fixture: bool = False,
    ) -> None:
        self.env = dict(env)
        self.route = route or local_route()
        self.http = dict(http or {})
        self.postgres = postgres
        self.voxtral = voxtral
        self.msgraph_account = msgraph_account
        self.fixture = fixture
        self.http_calls: list[str] = []
        self.voxtral_calls: list[str] = []
        self.postgres_pings = 0
        self.msgraph_checks = 0

    async def _postgres_ping(self) -> None:
        self.postgres_pings += 1
        if self.postgres:
            raise self.postgres

    async def _http_status(self, url: str) -> int:
        self.http_calls.append(url)
        answer = self.http.get(url, 200)
        if isinstance(answer, Exception):
            raise answer
        return answer

    async def _voxtral_reachable(self, base_url: str) -> bool:
        self.voxtral_calls.append(base_url)
        if isinstance(self.voxtral, Exception):
            raise self.voxtral
        return self.voxtral

    async def _msgraph_has_account(self) -> bool:
        self.msgraph_checks += 1
        if isinstance(self.msgraph_account, Exception):
            raise self.msgraph_account
        return self.msgraph_account

    def deps(self) -> HealthDependencies:
        return HealthDependencies(
            postgres_ping=self._postgres_ping,
            http_status=self._http_status,
            voxtral_reachable=self._voxtral_reachable,
            msgraph_has_account=self._msgraph_has_account,
            fixture_mode=lambda: self.fixture,
            route=lambda: self.route,
            env=self.env,
        )


class ProductionUpstreams:
    """Fakes *beneath* `default_dependencies()`: the process environment, the
    analysis route, `httpx` (a mock transport), the Postgres pool and the MSAL
    client. Used to prove the production wiring end to end."""

    def __init__(
        self,
        monkeypatch: pytest.MonkeyPatch,
        *,
        env: Mapping[str, str] = ENV,
        route: analysis_route.AnalysisRoute | None = None,
        http: Mapping[str, int | Exception] | None = None,
        postgres: Exception | None = None,
        msgraph_account: bool = True,
        fixture: bool = False,
    ) -> None:
        self.requests: list[httpx.Request] = []
        self.timeouts: list[object] = []
        self.queries: list[str] = []
        self._http = dict(http or {})
        self._postgres = postgres
        self._msgraph_account = msgraph_account

        for name in ("MSGRAPH_FIXTURE_MODE", *ENV):
            monkeypatch.delenv(name, raising=False)
        for name, value in env.items():
            monkeypatch.setenv(name, value)
        if fixture:
            monkeypatch.setenv("MSGRAPH_FIXTURE_MODE", "1")
        monkeypatch.setattr(analysis_route, "_active", route or local_route())

        transport = httpx.MockTransport(self._handle)
        real_client = httpx.AsyncClient
        upstreams = self

        class Client(real_client):
            def __init__(self, *args, **kwargs):
                upstreams.timeouts.append(kwargs.get("timeout"))
                kwargs["transport"] = transport
                super().__init__(*args, **kwargs)

        monkeypatch.setattr(httpx, "AsyncClient", Client)
        monkeypatch.setattr(db, "get_pool", self._get_pool)
        monkeypatch.setattr(msgraph_client, "get_client", self._get_msgraph_client)

    @property
    def urls(self) -> list[str]:
        return [str(r.url) for r in self.requests]

    def _handle(self, request: httpx.Request) -> httpx.Response:
        self.requests.append(request)
        answer = self._http.get(str(request.url), 200)
        if isinstance(answer, Exception):
            raise answer
        return httpx.Response(answer)

    async def _get_pool(self) -> "_Pool":
        return _Pool(self)

    async def _get_msgraph_client(self) -> "_Graph":
        return _Graph(self._msgraph_account)


class _Conn:
    def __init__(self, upstreams: ProductionUpstreams) -> None:
        self._upstreams = upstreams

    async def execute(self, query: str) -> None:
        self._upstreams.queries.append(query)
        if self._upstreams._postgres:
            raise self._upstreams._postgres


class _Acquire:
    def __init__(self, upstreams: ProductionUpstreams) -> None:
        self._upstreams = upstreams

    async def __aenter__(self) -> _Conn:
        return _Conn(self._upstreams)

    async def __aexit__(self, *exc: object) -> None:
        return None


class _Pool:
    def __init__(self, upstreams: ProductionUpstreams) -> None:
        self._upstreams = upstreams

    def acquire(self) -> _Acquire:
        return _Acquire(self._upstreams)


class _Graph:
    def __init__(self, has_account: bool) -> None:
        self._app = self
        self._has_account = has_account

    def get_accounts(self) -> list[dict]:
        return [{"home_account_id": "x"}] if self._has_account else []
