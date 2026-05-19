#!/usr/bin/env python3
"""Seed Voxtral reference clips from LibriVox public-domain recordings.

Usage (from the repo root, runs inside the webapp container so the
shared bind mount + ffmpeg are in scope):

    docker compose run --rm webapp python scripts/seed_voxtral_refs.py

Behavior:
    For each entry in CLIPS, downloads the source MP3 from
    archive.org, trims a `[start_sec, start_sec + duration_sec]`
    window via ffmpeg, transcodes to 24 kHz mono 16-bit PCM WAV
    (matching the format VoxtralCloneRecorderView uploads), and
    writes:

        /data/voxtral-refs/<voice_id>/audio.wav
        /data/voxtral-refs/<voice_id>/metadata.json

    The voice id is `librivox_<slug>`. Idempotent: any voice id whose
    target directory already exists is skipped silently, so re-running
    the script never duplicates or clobbers existing entries.

    A failure on one clip does not stop the rest — partial seeding is
    a valid outcome. The script exits 0 even with failures so it can
    be wired into `docker compose up`-style flows without breaking
    the surrounding lifecycle.

Curation notes:
    The CLIPS list ships with three German tracks pulled from the
    Multilingual Fairy Tale Collection volume 1 on archive.org:
    Andersen's "Das Feuerzeug", Alberti's "List geht über Gewalt",
    and Perrault's "Der gestiefelte Kater". All public domain. Two
    different readers (hok, mw) for variety.

    Quality is a known gamble — LibriVox volunteer recordings vary
    wildly. If the seeded voices don't sound right after listening
    in Settings, swap individual entries: either edit this file and
    re-run (after `rm -rf data/voxtral-refs/librivox_<slug>` to
    re-seed), or delete the clip on disk and record your own via
    the iOS Settings flow instead.

    `ref_text` ships empty — Voxtral works without it, just at
    slightly lower clone quality. To fill it in: listen to
    `data/voxtral-refs/librivox_<slug>/audio.wav`, transcribe the
    speech, edit `metadata.json` directly. The catalog re-reads on
    every list call.

Adding more clips:
    Browse https://librivox.org/search?primary_key=2 (German) for
    titles. For each, find the project page on archive.org, copy
    the direct .mp3 URL pattern
    `https://archive.org/download/<identifier>/<file>.mp3`, and
    append a dict to CLIPS. Slugs must match `[a-z0-9_]+`.
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
import urllib.error
import urllib.request
from pathlib import Path


# ---------------------------------------------------------------------------
# Curated clip list. Edit / extend this. Slugs must match `[a-z0-9_]+` per the
# voice_catalog's filesystem-id check. Voice ids on disk will be prefixed with
# `librivox_<slug>` so they group with other LibriVox entries in the picker.
# ---------------------------------------------------------------------------

CLIPS: list[dict[str, object]] = [
    {
        "slug": "andersen_feuerzeug",
        "label": "Andersen · Das Feuerzeug",
        "description": "LibriVox · Multilingual Fairy Tale Collection · Reader: hok",
        "language": "DE",
        "url": "https://archive.org/download/multilingual_fairy_tales001_0901_librivox/01_fairytale001_feuerzeug_andersen_hok.mp3",
        "start_sec": 28,
        "duration_sec": 8,
        "ref_text": "",
    },
    {
        "slug": "alberti_list",
        "label": "Alberti · List geht über Gewalt",
        "description": "LibriVox · Multilingual Fairy Tale Collection · Reader: mw",
        "language": "DE",
        "url": "https://archive.org/download/multilingual_fairy_tales001_0901_librivox/06_fairytale001_listgehtuebergewalt_alberti_mw.mp3",
        "start_sec": 28,
        "duration_sec": 8,
        "ref_text": "",
    },
    {
        "slug": "perrault_kater",
        "label": "Perrault · Der gestiefelte Kater",
        "description": "LibriVox · Multilingual Fairy Tale Collection · Reader: hok",
        "language": "DE",
        "url": "https://archive.org/download/multilingual_fairy_tales001_0901_librivox/09_fairytale001_gestiefeltekater_perrault_hok.mp3",
        "start_sec": 28,
        "duration_sec": 8,
        "ref_text": "",
    },
]


# ---------------------------------------------------------------------------


def _refs_dir() -> Path:
    """Path to the shared voxtral-refs directory inside the webapp
    container. Resolves DATA_DIR first (set in docker-compose.yml to
    /data) so the script does the right thing both inside and outside
    Docker."""
    explicit = os.getenv("DATA_DIR", "").strip()
    if explicit:
        return Path(explicit) / "voxtral-refs"
    return Path(__file__).resolve().parent.parent / "data" / "voxtral-refs"


def _is_complete(target_dir: Path) -> bool:
    """A target dir counts as complete only when both files exist —
    so a half-failed previous run doesn't poison-pill future re-runs."""
    return (target_dir / "audio.wav").is_file() and (target_dir / "metadata.json").is_file()


def _cleanup_incomplete(target_dir: Path) -> None:
    """Remove any stale artifacts from a previous failed attempt so
    the next pass can start fresh without manual rm -rf."""
    if not target_dir.exists():
        return
    for entry in target_dir.iterdir():
        try:
            entry.unlink()
        except OSError:
            pass
    try:
        target_dir.rmdir()
    except OSError:
        pass


def _seed_clip(clip: dict[str, object], refs_root: Path) -> bool:
    slug = str(clip["slug"])
    voice_id = f"librivox_{slug}"
    target_dir = refs_root / voice_id

    if _is_complete(target_dir):
        print(f"  skip  {voice_id} (already present)")
        return True

    # Either fresh or a previous-attempt corpse — clean either way.
    _cleanup_incomplete(target_dir)
    print(f"  seed  {voice_id}")

    with tempfile.TemporaryDirectory() as tmp:
        mp3_path = Path(tmp) / "source.mp3"
        url = str(clip["url"])
        try:
            req = urllib.request.Request(url, headers={"User-Agent": "voice-diary-seed/1.0"})
            with urllib.request.urlopen(req, timeout=60) as resp:
                mp3_path.write_bytes(resp.read())
        except (urllib.error.URLError, TimeoutError) as exc:
            print(f"    FAILED download: {exc}")
            return False

        # Stage outputs into the target dir, then atomic-rename so a
        # half-written entry is never visible to the catalog. The
        # trailing extension on the temp file is `.wav` (not `.tmp.wav`
        # or similar) because ffmpeg uses the *trailing* extension to
        # pick the output container format. Belt-and-suspenders: also
        # pass `-f wav` explicitly so even unconventional filenames work.
        target_dir.mkdir(parents=True, exist_ok=True)
        wav_tmp = target_dir / "audio.partial.wav"
        wav_path = target_dir / "audio.wav"

        ffmpeg_args = [
            "ffmpeg", "-y", "-loglevel", "error",
            "-i", str(mp3_path),
            "-ss", str(clip["start_sec"]),
            "-t", str(clip["duration_sec"]),
            "-ar", "24000",
            "-ac", "1",
            "-f", "wav",
            "-c:a", "pcm_s16le",
            str(wav_tmp),
        ]
        try:
            result = subprocess.run(ffmpeg_args, capture_output=True, text=True, check=False)
        except FileNotFoundError:
            print("    FAILED ffmpeg: binary not on PATH (run inside webapp container)")
            _cleanup_incomplete(target_dir)
            return False
        if result.returncode != 0:
            print(f"    FAILED ffmpeg: {result.stderr.strip()[:200]}")
            _cleanup_incomplete(target_dir)
            return False

        wav_tmp.replace(wav_path)

        metadata = {
            "id": voice_id,
            "language": str(clip["language"]).upper(),
            "label": clip["label"],
            "description": clip["description"],
            "source": "librivox",
            "ref_text": clip["ref_text"] or None,
        }
        meta_tmp = target_dir / "metadata.partial.json"
        meta_tmp.write_text(json.dumps(metadata, ensure_ascii=False, indent=2))
        meta_tmp.replace(target_dir / "metadata.json")
        return True


def main() -> int:
    refs_root = _refs_dir()
    refs_root.mkdir(parents=True, exist_ok=True)
    print(f"seeding voxtral references into {refs_root}")

    ok = 0
    skipped = 0
    failed = 0
    for clip in CLIPS:
        target_dir = refs_root / f"librivox_{clip['slug']}"
        was_present = target_dir.exists()
        success = _seed_clip(clip, refs_root)
        if success and was_present:
            skipped += 1
        elif success:
            ok += 1
        else:
            failed += 1

    print(f"done. seeded={ok} skipped={skipped} failed={failed}")
    # Always exit 0 — partial seeding is a valid state. CI / compose
    # lifecycle hooks shouldn't fail because one LibriVox URL went
    # cold for a moment.
    return 0


if __name__ == "__main__":
    sys.exit(main())
