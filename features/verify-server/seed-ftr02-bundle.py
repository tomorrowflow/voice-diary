"""Seed the on-disk bundle of the `ftr02-recoverable` session (features/sessions-retry-transcription.md).

Run inside the webapp container, which owns the stack's `/data` volume:

    ... exec -T webapp python - < features/verify-server/seed-ftr02-bundle.py

The manifest lists s01, s02 and s03; only s01 and s02 get an audio file, so s03 reads back
`recoverable: false`. The audio is a stub, never transcribed (the stack has no Whisper).
"""

import json
import os
from pathlib import Path

session_dir = Path(os.environ.get("DATA_DIR", "/data")) / "sessions" / "ftr02-recoverable"
manifest = {
    "session_id": "ftr02-recoverable",
    "date": "2026-07-01",
    "device": "iPhone17,2",
    "app_version": "1.0",
    "audio_codec": {"codec": "aac-lc", "sample_rate": 16000, "channels": 1, "bitrate": 64000},
    "segments": [
        {
            "segment_id": segment_id,
            "segment_type": "drive_by",
            "audio_file": f"segments/{segment_id}.m4a",
            "captured_at": "2026-07-01T10:00:00Z",
        }
        for segment_id in ("s01", "s02", "s03")
    ],
}
(session_dir / "segments").mkdir(parents=True, exist_ok=True)
(session_dir / "manifest.json").write_text(json.dumps(manifest))
for segment_id in ("s01", "s02"):
    (session_dir / "segments" / f"{segment_id}.m4a").write_bytes(b"verify-server-not-real-audio")
print(f"seeded {session_dir}")
