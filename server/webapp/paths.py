"""Runtime path helpers.

The Docker image's WORKDIR is `/app/`, with all webapp code copied in.
On the host `server/data/` is the conventional location, and inside the
container `/data/` is volume-mounted there. `DATA_DIR` env var lets either
work without `..` gymnastics.
"""

from __future__ import annotations

import os
from pathlib import Path


def data_dir() -> Path:
    """Resolve the runtime data directory.

    Order:
      1. `$DATA_DIR` (set in docker-compose.yml to `/data`).
      2. `<repo>/server/data/` when running outside Docker (fallback).
    """
    explicit = os.getenv("DATA_DIR", "").strip()
    if explicit:
        return Path(explicit)
    return Path(__file__).resolve().parent.parent / "data"


def sessions_dir() -> Path:
    return data_dir() / "sessions"


def msal_cache_path() -> Path:
    return data_dir() / "msal_cache.bin"
