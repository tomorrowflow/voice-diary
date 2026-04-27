"""Generate a fresh iOS bearer token.

Usage:
    docker compose run --rm webapp python scripts/issue_ios_token.py

Prints a 256-bit hex string. Paste it into `server/.env` as
`IOS_BEARER_TOKEN=...` and into the iOS app's onboarding screen.

No state is written by this script — it is a stateless secret generator.
"""

from __future__ import annotations

import secrets


def main() -> int:
    token = secrets.token_hex(32)  # 256 bits
    print(token)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
