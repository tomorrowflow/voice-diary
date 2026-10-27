"""Seed the on-disk bundle of the `ftr07-general` session (features/sessions-general-section.md).

Run inside the webapp container, which owns the stack's `/data` volume:

    ... exec -T webapp python - < features/verify-server/seed-ftr07-bundle.py

The manifest lists one `general_section` segment, s01, with a stub audio file that is never
transcribed (the stack has no Whisper).
"""

import json
import os
from pathlib import Path

session_dir = Path(os.environ.get("DATA_DIR", "/data")) / "sessions" / "ftr07-general"
manifest = {
    "session_id": "ftr07-general",
    "date": "2026-07-01",
    "device": "iPhone17,2",
    "app_version": "1.0",
    "audio_codec": {"codec": "aac-lc", "sample_rate": 16000, "channels": 1, "bitrate": 64000},
    "segments": [
        {
            "segment_id": "s01",
            "segment_type": "general_section",
            "section_id": "5f0c2a52-7d58-4b8c-9c1e-0d6f4a3a9b11",
            "title": "Abendreflexion",
            "prompt_text": "Was hat dich heute am meisten beschäftigt?",
            "audio_file": "segments/s01.m4a",
            "transcript": "",
            "language": "de-DE",
        }
    ],
}
(session_dir / "segments").mkdir(parents=True, exist_ok=True)
(session_dir / "manifest.json").write_text(json.dumps(manifest), encoding="utf-8")
(session_dir / "segments" / "s01.m4a").write_bytes(b"verify-server-not-real-audio")
print(f"seeded {session_dir}")
