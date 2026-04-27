"""One-time MSAL device-code OAuth bootstrap.

Usage:
    docker compose run --rm webapp python scripts/msgraph_bootstrap.py

Prints a device-code URL + 9-character code. The user signs in once and
grants delegated `Calendars.Read` + `Mail.Read` (`offline_access` is implicit
for public clients). The refresh token is persisted to
`server/data/msal_cache.bin` with file mode 0600.

Idempotent: re-run replaces the cached account.
"""

from __future__ import annotations

import os
import sys
from pathlib import Path

# Make the webapp module importable. Host layout has it under
# `server/webapp/`; the docker-compose volume mounts this script at
# `/app/scripts/` with the webapp code already on `/app/`.
SCRIPT_DIR = Path(__file__).resolve().parent
for candidate in (SCRIPT_DIR.parent / "webapp", SCRIPT_DIR.parent):
    if (candidate / "msgraph_client.py").exists():
        sys.path.insert(0, str(candidate))
        break
else:
    print(
        "ERROR: could not locate msgraph_client.py near this script.",
        file=sys.stderr,
    )
    sys.exit(2)

from dotenv import load_dotenv  # noqa: E402

# .env may live in `server/.env` (host) or be sourced from compose env_file.
for env_candidate in (
    SCRIPT_DIR.parent / ".env",
    Path("/app/.env"),
):
    if env_candidate.exists():
        load_dotenv(env_candidate)
        break

import msal  # noqa: E402

from msgraph_client import (  # noqa: E402
    GRAPH_AUTHORITY,
    GRAPH_SCOPES,
    _cache_path,
    _load_cache,
    _persist_cache,
)


def main() -> int:
    client_id = os.getenv("MSGRAPH_CLIENT_ID", "").strip()
    tenant_id = os.getenv("MSGRAPH_TENANT_ID", "").strip()
    if not client_id or not tenant_id:
        print(
            "ERROR: MSGRAPH_CLIENT_ID and MSGRAPH_TENANT_ID must be set in .env.",
            file=sys.stderr,
        )
        return 2

    cache_path = _cache_path()
    cache = _load_cache(cache_path)
    app = msal.PublicClientApplication(
        client_id=client_id,
        authority=f"{GRAPH_AUTHORITY}/{tenant_id}",
        token_cache=cache,
    )

    flow = app.initiate_device_flow(scopes=GRAPH_SCOPES)
    if "user_code" not in flow:
        print("ERROR: failed to start device-code flow:", flow, file=sys.stderr)
        return 3

    print()
    print("=" * 60)
    print("Microsoft Graph device-code sign-in")
    print("=" * 60)
    print(flow["message"])
    print("=" * 60)
    print()
    print("Waiting for sign-in (this script will block until done)...")

    result = app.acquire_token_by_device_flow(flow)

    if "access_token" not in result:
        print("ERROR: device-code flow failed:", file=sys.stderr)
        # Don't print the full result — it may contain auth artefacts.
        print(f"  error: {result.get('error', '?')}", file=sys.stderr)
        print(f"  description: {result.get('error_description', '?')[:300]}", file=sys.stderr)
        return 4

    _persist_cache(cache, cache_path)
    print(f"OK — refresh token persisted to {cache_path}")
    accounts = app.get_accounts()
    if accounts:
        print(f"Signed in as: {accounts[0].get('username', '<unknown>')}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
