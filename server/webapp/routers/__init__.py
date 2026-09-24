"""iOS-facing FastAPI routers.

Mounted from `webapp/main.py` alongside the legacy review/admin routes,
which live in `main.py` on their own `legacy_router`. Both groups share one
published port, so both carry `Depends(require_bearer)` at the router level
(SEC-2 in `docs/REVIEW-2026-07-04.md`). `/health` is the only open route,
so the iOS app can probe reachability before onboarding.
"""
