"""Shared test environment.

db.py deliberately refuses to import without DATABASE_URL (SEC-4: no
hardcoded credential fallback), and main.py imports db at module level.
Any test that boots the real app — e.g. the SEC-1 bind-guard lifespan
test — therefore needs a DATABASE_URL present even though it never
touches Postgres. Provide an obviously-fake one; per-test overrides via
monkeypatch still apply on top of it.
"""

import os

os.environ.setdefault("DATABASE_URL", "postgresql://test:test@localhost:5432/test")