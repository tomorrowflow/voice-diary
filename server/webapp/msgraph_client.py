"""Microsoft Graph client for Voice Diary.

- MSAL device-code public client (no client secret).
- Persistent token cache backed by `data/msal_cache.bin`, file mode 0600.
- Silent acquisition for refresh; one retry on 401 by clearing the access
  token and forcing a fresh acquisition from the cache.
- Never logs tokens — strips Authorization headers from any logged context.

The bootstrap script (`scripts/msgraph_bootstrap.py`) is the *only* way to
populate the cache. The webapp itself never prompts the user for a code.
"""

from __future__ import annotations

import asyncio
import logging
import os
from pathlib import Path
from typing import Any

import httpx
import msal

logger = logging.getLogger(__name__)


GRAPH_AUTHORITY = "https://login.microsoftonline.com"
GRAPH_BASE_URL = "https://graph.microsoft.com/v1.0"
GRAPH_SCOPES = ["Calendars.Read", "Mail.Read"]  # offline_access is implicit for public clients


class MSGraphNotBootstrapped(RuntimeError):
    """Raised when the MSAL cache has no usable account.

    Surfaced as HTTP 503 by the routers; the user must run
    `scripts/msgraph_bootstrap.py` and sign in once.
    """


class MSGraphError(RuntimeError):
    """Generic Graph failure (network, 5xx, parsing)."""


def _cache_path() -> Path:
    """Resolve the MSAL cache file path. Default: $DATA_DIR/msal_cache.bin."""
    explicit = os.getenv("MSGRAPH_CACHE_PATH")
    if explicit:
        return Path(explicit)
    from paths import msal_cache_path
    return msal_cache_path()


def _load_cache(path: Path) -> msal.SerializableTokenCache:
    cache = msal.SerializableTokenCache()
    if path.exists():
        try:
            cache.deserialize(path.read_text())
        except Exception as exc:
            logger.warning("MSAL cache at %s is unreadable (%s); treating as empty.", path, exc)
    return cache


def _persist_cache(cache: msal.SerializableTokenCache, path: Path) -> None:
    if not cache.has_state_changed:
        return
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(cache.serialize())
    try:
        os.chmod(tmp, 0o600)
    except OSError:
        pass
    os.replace(tmp, path)
    try:
        os.chmod(path, 0o600)
    except OSError:
        pass


class MSGraphClient:
    """Singleton-ish wrapper around an MSAL public client + httpx."""

    def __init__(
        self,
        client_id: str,
        tenant_id: str,
        cache_path: Path | None = None,
    ) -> None:
        if not client_id or not tenant_id:
            raise RuntimeError(
                "MSGRAPH_CLIENT_ID and MSGRAPH_TENANT_ID must be set in .env"
            )
        self._client_id = client_id
        self._tenant_id = tenant_id
        self._cache_path = cache_path or _cache_path()
        self._cache = _load_cache(self._cache_path)
        self._app = msal.PublicClientApplication(
            client_id=client_id,
            authority=f"{GRAPH_AUTHORITY}/{tenant_id}",
            token_cache=self._cache,
        )
        self._cache_lock = asyncio.Lock()
        self._http: httpx.AsyncClient | None = None

    # --- token handling ----------------------------------------------------

    async def _acquire_token_silently(self) -> str:
        """Return a valid access token; refresh silently if needed."""
        async with self._cache_lock:
            accounts = self._app.get_accounts()
            if not accounts:
                raise MSGraphNotBootstrapped(
                    "msgraph_not_bootstrapped: no accounts in cache; "
                    "run scripts/msgraph_bootstrap.py once."
                )
            # Use the first (and, for this single-user app, only) account.
            result = await asyncio.to_thread(
                self._app.acquire_token_silent,
                scopes=GRAPH_SCOPES,
                account=accounts[0],
            )
            _persist_cache(self._cache, self._cache_path)
        if not result or "access_token" not in result:
            raise MSGraphNotBootstrapped(
                "msgraph_not_bootstrapped: silent refresh failed; "
                "the refresh token may be revoked. Re-run bootstrap."
            )
        return result["access_token"]

    # --- transport ---------------------------------------------------------

    @property
    def _client(self) -> httpx.AsyncClient:
        if self._http is None:
            self._http = httpx.AsyncClient(timeout=30.0)
        return self._http

    async def close(self) -> None:
        if self._http is not None:
            await self._http.aclose()
            self._http = None

    async def _request(
        self,
        method: str,
        url: str,
        *,
        params: dict[str, Any] | None = None,
    ) -> httpx.Response:
        """Perform an authenticated Graph request, retrying once on 401."""
        token = await self._acquire_token_silently()
        headers = {"Authorization": f"Bearer {token}", "Accept": "application/json"}
        resp = await self._client.request(method, url, headers=headers, params=params)
        if resp.status_code == 401:
            # Drop cached access token by forcing a silent reacquire.
            token = await self._acquire_token_silently()
            headers["Authorization"] = f"Bearer {token}"
            resp = await self._client.request(method, url, headers=headers, params=params)
        return resp

    async def get_json(
        self,
        path: str,
        *,
        params: dict[str, Any] | None = None,
    ) -> dict[str, Any]:
        """GET a Graph endpoint and return JSON. Honours Retry-After on 429
        with up to two retries (1 s + 2 s default), then surfaces 503.
        """
        url = path if path.startswith("http") else f"{GRAPH_BASE_URL}{path}"
        backoff = [1.0, 2.0]
        for attempt in range(len(backoff) + 1):
            try:
                resp = await self._request("GET", url, params=params)
            except (httpx.NetworkError, httpx.TimeoutException) as exc:
                raise MSGraphError(f"network_error: {exc}") from exc
            if resp.status_code == 429 and attempt < len(backoff):
                try:
                    retry_after = float(resp.headers.get("Retry-After", "0"))
                except ValueError:
                    retry_after = 0.0
                wait = max(retry_after, backoff[attempt])
                logger.warning("Graph 429; sleeping %.1fs before retry", wait)
                await asyncio.sleep(wait)
                continue
            if resp.status_code == 429:
                raise MSGraphError("rate_limited: backoff_exhausted")
            if resp.status_code >= 500:
                raise MSGraphError(f"upstream_5xx: status={resp.status_code}")
            if resp.status_code >= 400:
                try:
                    err = resp.json().get("error", {})
                except Exception:
                    err = {"message": resp.text[:200]}
                raise MSGraphError(
                    f"graph_error: status={resp.status_code} "
                    f"code={err.get('code', '?')} "
                    f"message={err.get('message', '')[:200]}"
                )
            return resp.json()
        raise MSGraphError("rate_limited: backoff_exhausted")  # pragma: no cover


# --- module-level lazy singleton ------------------------------------------

_instance: MSGraphClient | None = None
_instance_lock = asyncio.Lock()


async def get_client() -> MSGraphClient:
    """Return the process-wide MSGraphClient, instantiating on first call."""
    global _instance
    if _instance is not None:
        return _instance
    async with _instance_lock:
        if _instance is None:
            _instance = MSGraphClient(
                client_id=os.getenv("MSGRAPH_CLIENT_ID", ""),
                tenant_id=os.getenv("MSGRAPH_TENANT_ID", ""),
            )
    return _instance


async def close_client() -> None:
    global _instance
    if _instance is not None:
        await _instance.close()
        _instance = None
