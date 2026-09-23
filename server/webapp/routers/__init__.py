"""iOS-facing FastAPI routers.

Mounted from `webapp/main.py` alongside the legacy review/admin routes
(which live directly in `main.py` on their own `legacy_router` and carry
the same `Depends(require_bearer)`). Bearer-token authentication is
applied per-router, not globally, because both groups share one published
port — see SEC-2 in `docs/REVIEW-2026-07-04.md`. `/health` is the only
route that stays open, so the iOS app can probe reachability before
onboarding.
"""
