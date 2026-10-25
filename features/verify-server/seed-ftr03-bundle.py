"""Seed the on-disk bundles of the `ftr03-saved` and `ftr03-unsaved` sessions
(features/sessions-interrupted-recovery.md).

Run inside the webapp container, which owns the stack's `/data` volume:

    ... exec -T webapp python - < features/verify-server/seed-ftr03-bundle.py

Each manifest lists one segment, s01, with a stub audio file that is never transcribed (the stack
has no Whisper, and a restart must not ask for one anyway).
"""

import json
import os
from pathlib import Path

for session_id in ("ftr03-saved", "ftr03-unsaved"):
    session_dir = Path(os.environ.get("DATA_DIR", "/data")) / "sessions" / session_id
    manifest = {
        "session_id": session_id,
        "date": "2026-07-01",
        "device": "iPhone17,2",
        "app_version": "1.0",
        "audio_codec": {"codec": "aac-lc", "sample_rate": 16000, "channels": 1, "bitrate": 64000},
        "segments": [
            {
                "segment_id": "s01",
                "segment_type": "drive_by",
                "audio_file": "segments/s01.m4a",
                "captured_at": "2026-07-01T10:00:00Z",
            }
        ],
    }
    (session_dir / "segments").mkdir(parents=True, exist_ok=True)
    (session_dir / "manifest.json").write_text(json.dumps(manifest))
    (session_dir / "segments" / "s01.m4a").write_bytes(b"verify-server-not-real-audio")
    print(f"seeded {session_dir}")
