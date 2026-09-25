"""iOS-facing FastAPI routers, plus the relocated legacy admin CRUD routers.

Mounted from `webapp/main.py` alongside the legacy review routes, which
live in `main.py` on their own `legacy_router`. `admin.py` and
`dictionary.py` hold the ~30 shallow CRUD routes mechanically relocated
out of `main.py` (SRV-A5 in `docs/REVIEW-2026-07-04.md`). All of these
groups share one published port, so all carry `Depends(require_bearer)`
at the router level (SEC-2). `/health` is the only open route, so the
iOS app can probe reachability before onboarding.
"""
