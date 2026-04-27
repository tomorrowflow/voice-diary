"""iOS-facing FastAPI routers.

Mounted from `webapp/main.py` alongside the existing review/admin routes.
Bearer-token authentication is applied per-router via FastAPI `Depends`,
not globally — internal-only routes stay open on the Docker network.
"""
