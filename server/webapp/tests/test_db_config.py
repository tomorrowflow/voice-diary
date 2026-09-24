"""SEC-4: db.py must not fall back to a hardcoded `diary:diary` credential
when DATABASE_URL is unset. docker-compose.yml already fails loudly via
`${POSTGRES_PASSWORD:?...}`, but that guard is bypassed whenever webapp
runs outside compose (bare `python`, ad-hoc scripts). The module must
fail the same way instead of silently connecting with a guessable
password.
"""

import importlib

import pytest


def test_database_url_has_no_hardcoded_default(monkeypatch):
    monkeypatch.setenv("DATABASE_URL", "postgresql://test:test@localhost/test")
    import db

    importlib.reload(db)

    monkeypatch.delenv("DATABASE_URL", raising=False)
    with pytest.raises(RuntimeError):
        importlib.reload(db)

    # Leave a valid DATABASE_URL in place so module state is sane for any
    # later test that imports db.
    monkeypatch.setenv("DATABASE_URL", "postgresql://test:test@localhost/test")
    importlib.reload(db)
