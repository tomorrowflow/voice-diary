"""Tests for `voice_catalog.VoiceCatalog`'s filesystem-merging surface.

Run inside the webapp container:

    docker compose run --rm webapp pytest tests/test_voice_catalog.py
"""

from __future__ import annotations

import json
from pathlib import Path

import pytest

from voice_catalog import VoiceCatalog, VoiceDescriptor


_MIN_WAV = b"RIFF\x24\x00\x00\x00WAVEfmt \x10\x00\x00\x00\x01\x00\x01\x00\x40\x1f\x00\x00\x80\x3e\x00\x00\x02\x00\x10\x00data\x00\x00\x00\x00"


def _catalog(tmp_path: Path) -> VoiceCatalog:
    # Drop the bundled set down to a known subset so assertions can be
    # specific without depending on the production voice list.
    bundled = (
        VoiceDescriptor(id="de_male",   language="DE", label="Deutsch — m", description="bundled"),
        VoiceDescriptor(id="casual_male", language="EN", label="Casual",     description="bundled"),
    )
    return VoiceCatalog(bundled=bundled, refs_root=tmp_path)


# --- bundled-only -------------------------------------------------------


def test_empty_refs_dir_returns_only_bundled(tmp_path: Path) -> None:
    cat = _catalog(tmp_path)
    grouped = cat.list_grouped(languages=("DE", "EN"))
    assert {v["id"] for v in grouped["DE"]} == {"de_male"}
    assert {v["id"] for v in grouped["EN"]} == {"casual_male"}


def test_existing_bundled_voice_has_bundled_source(tmp_path: Path) -> None:
    cat = _catalog(tmp_path)
    descriptor = cat.get("de_male")
    assert descriptor is not None
    assert descriptor.source == "bundled"


# --- add a filesystem voice --------------------------------------------


def test_add_filesystem_voice_appears_in_list(tmp_path: Path) -> None:
    cat = _catalog(tmp_path)
    cat.add_filesystem_voice(
        "custom_abc12345",
        language="DE",
        label="Mein Test",
        description="Eigene Aufnahme",
        ref_text="Hallo, ich bin eine Testaufnahme.",
        source="user",
        audio_bytes=_MIN_WAV,
    )
    grouped = cat.list_grouped(languages=("DE",))
    ids = {v["id"] for v in grouped["DE"]}
    assert "custom_abc12345" in ids
    descriptor = cat.get("custom_abc12345")
    assert descriptor is not None
    assert descriptor.source == "user"
    assert descriptor.ref_text == "Hallo, ich bin eine Testaufnahme."
    assert descriptor.language == "DE"


def test_add_writes_audio_and_metadata_files(tmp_path: Path) -> None:
    cat = _catalog(tmp_path)
    cat.add_filesystem_voice(
        "custom_deadbeef",
        language="EN",
        label="Test",
        description="Eigene Aufnahme",
        ref_text=None,
        source="user",
        audio_bytes=_MIN_WAV,
    )
    audio = tmp_path / "custom_deadbeef" / "audio.wav"
    metadata = tmp_path / "custom_deadbeef" / "metadata.json"
    assert audio.is_file()
    assert audio.read_bytes() == _MIN_WAV
    data = json.loads(metadata.read_text())
    assert data["id"] == "custom_deadbeef"
    assert data["source"] == "user"
    assert data["ref_text"] is None


def test_reference_audio_path_returns_existing_wav(tmp_path: Path) -> None:
    cat = _catalog(tmp_path)
    cat.add_filesystem_voice(
        "custom_aaaaaaaa",
        language="DE",
        label="x",
        description="x",
        ref_text=None,
        source="user",
        audio_bytes=_MIN_WAV,
    )
    p = cat.reference_audio_path("custom_aaaaaaaa")
    assert p is not None
    assert p.is_file()


def test_reference_audio_path_returns_none_for_bundled(tmp_path: Path) -> None:
    cat = _catalog(tmp_path)
    assert cat.reference_audio_path("de_male") is None


# --- delete ------------------------------------------------------------


def test_delete_filesystem_voice_removes_dir(tmp_path: Path) -> None:
    cat = _catalog(tmp_path)
    cat.add_filesystem_voice(
        "custom_11111111",
        language="DE",
        label="x",
        description="x",
        ref_text=None,
        source="user",
        audio_bytes=_MIN_WAV,
    )
    assert (tmp_path / "custom_11111111").is_dir()
    assert cat.delete_filesystem_voice("custom_11111111") is True
    assert not (tmp_path / "custom_11111111").exists()
    assert cat.get("custom_11111111") is None


def test_delete_returns_false_for_unknown_id(tmp_path: Path) -> None:
    cat = _catalog(tmp_path)
    assert cat.delete_filesystem_voice("custom_doesntexist") is False


# --- path-traversal defence -------------------------------------------


@pytest.mark.parametrize("bad_id", [
    "../etc/passwd",
    "custom_aa/../bb",
    "voice with space",
    "voice;rm -rf",
    "",
    "VOICE_WITH_UPPERCASE",
    "voice-with-dash",
])
def test_invalid_ids_rejected_on_add(tmp_path: Path, bad_id: str) -> None:
    cat = _catalog(tmp_path)
    with pytest.raises(ValueError):
        cat.add_filesystem_voice(
            bad_id,
            language="DE",
            label="x",
            description="x",
            ref_text=None,
            source="user",
            audio_bytes=_MIN_WAV,
        )


@pytest.mark.parametrize("bad_id", [
    "../etc/passwd",
    "custom_aa/../bb",
    "VOICE_WITH_UPPERCASE",
])
def test_invalid_ids_rejected_on_get(tmp_path: Path, bad_id: str) -> None:
    cat = _catalog(tmp_path)
    assert cat.get(bad_id) is None
    assert cat.reference_audio_path(bad_id) is None
    assert cat.delete_filesystem_voice(bad_id) is False


def test_add_refuses_bundled_source(tmp_path: Path) -> None:
    cat = _catalog(tmp_path)
    with pytest.raises(ValueError):
        cat.add_filesystem_voice(
            "custom_99999999",
            language="DE",
            label="x",
            description="x",
            ref_text=None,
            source="bundled",  # type: ignore[arg-type]
            audio_bytes=_MIN_WAV,
        )


def test_add_collision_raises_file_exists(tmp_path: Path) -> None:
    cat = _catalog(tmp_path)
    cat.add_filesystem_voice(
        "custom_22222222",
        language="DE",
        label="x",
        description="x",
        ref_text=None,
        source="user",
        audio_bytes=_MIN_WAV,
    )
    with pytest.raises(FileExistsError):
        cat.add_filesystem_voice(
            "custom_22222222",
            language="DE",
            label="other",
            description="x",
            ref_text=None,
            source="user",
            audio_bytes=_MIN_WAV,
        )
