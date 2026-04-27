"""Bearer-token Depends for iOS-facing routers.

Reads `IOS_BEARER_TOKEN` from the environment at request time (not at import
time) so token rotation via `.env` reload doesn't require an image rebuild.

Usage:

    from routers.auth import require_bearer
    router = APIRouter(dependencies=[Depends(require_bearer)])
"""

from __future__ import annotations

import hmac
import os

from fastapi import Header, HTTPException, status


def _expected_token() -> str:
    return os.getenv("IOS_BEARER_TOKEN", "").strip()


async def require_bearer(authorization: str | None = Header(default=None)) -> None:
    expected = _expected_token()
    if not expected:
        # Fail closed: a server with no bearer set must not accept iOS calls.
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="ios_bearer_not_configured",
        )
    if not authorization or not authorization.startswith("Bearer "):
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="missing_bearer_token",
            headers={"WWW-Authenticate": "Bearer"},
        )
    presented = authorization.removeprefix("Bearer ").strip()
    if not hmac.compare_digest(presented, expected):
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="invalid_bearer_token",
            headers={"WWW-Authenticate": "Bearer"},
        )
