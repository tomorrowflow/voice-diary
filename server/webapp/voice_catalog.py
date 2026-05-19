"""Catalog of Voxtral voice references — bundled + filesystem.

Three voice families live behind one `VoiceCatalog` surface:

  1. **Bundled** — the 20 preset voices that ship in
     `Voxtral-4B-TTS-2603`'s `voice_embedding/` directory. Static
     manifest in code; tied to the model version. Used by name in
     vLLM (`voice: "de_male"`).

  2. **LibriVox-seeded** — reference clips fetched by
     `scripts/seed_voxtral_refs.py` from public-domain LibriVox
     audiobooks, trimmed to a 5–10 s snippet, with the known
     transcript as `ref_text`. Filesystem-backed under
     `voxtral_refs_dir()/<id>/`. id pattern: `librivox_<slug>`.

  3. **User-recorded** — clips uploaded via
     `POST /api/tts/voices/custom` from the iOS app. Same on-disk
     layout as LibriVox. id pattern: `custom_<8-char-hex>`.

The router queries `list_grouped()` to populate `/api/tts/voices`,
and `get()` during synth so it knows whether to pass the voice name
through directly (bundled) or as `task_type: "Base"` + `ref_audio:
file://...` + `ref_text` (filesystem-backed).

Source of truth for the bundled list:
    https://huggingface.co/mistralai/Voxtral-4B-TTS-2603/tree/main/voice_embedding
"""

from __future__ import annotations

import json
import logging
from dataclasses import asdict, dataclass, field
from pathlib import Path
from typing import Literal

logger = logging.getLogger(__name__)


VoiceSource = Literal["bundled", "librivox", "user"]


@dataclass(frozen=True)
class VoiceDescriptor:
    """One Voxtral reference voice. `language` is the *source* language
    of the reference clip — picking `de_male` for German output produces
    natural German prosody; picking an English-sourced voice for German
    output produces German rendered with an English speaker's accent.

    `source` is `"bundled"` for the in-Voxtral preset names, or
    `"librivox"` / `"user"` for filesystem-backed reference clips.
    `ref_text` carries the optional transcript that the cloning path
    sends to vLLM as `ref_text`; only meaningful for non-bundled voices.
    """

    id: str
    language: str           # ISO-like: "DE", "EN", "FR", … (matches our route's accepted values)
    label: str              # Display name for the picker row
    description: str        # One-line description shown under the label
    source: VoiceSource = "bundled"
    ref_text: str | None = None

    def to_dict(self) -> dict[str, str | None]:
        return asdict(self)


# --- the catalog ---------------------------------------------------------
#
# Order within each language is the order voices appear in the picker.
# Male before female is arbitrary — adjust to taste; the iOS UI just
# preserves whatever order the route returns.

_VOICES: tuple[VoiceDescriptor, ...] = (
    # ── Native German references ────────────────────────────────────
    VoiceDescriptor(
        id="de_male",
        language="DE",
        label="Deutsch — männlich",
        description="Native deutsche Stimme, neutral.",
    ),
    VoiceDescriptor(
        id="de_female",
        language="DE",
        label="Deutsch — weiblich",
        description="Native deutsche Stimme, neutral.",
    ),
    # ── English-leaning "preset" voices ─────────────────────────────
    # Mistral's README example uses `casual_male` to render English
    # text. These voices have no language prefix in the model repo,
    # which marks them as the default English-trained set.
    VoiceDescriptor(
        id="casual_male",
        language="EN",
        label="Casual (männlich)",
        description="Englische Stimme, locker.",
    ),
    VoiceDescriptor(
        id="casual_female",
        language="EN",
        label="Casual (weiblich)",
        description="Englische Stimme, locker.",
    ),
    VoiceDescriptor(
        id="cheerful_female",
        language="EN",
        label="Cheerful (weiblich)",
        description="Englische Stimme, lebhaft.",
    ),
    VoiceDescriptor(
        id="neutral_male",
        language="EN",
        label="Neutral (männlich)",
        description="Englische Stimme, sachlich.",
    ),
    VoiceDescriptor(
        id="neutral_female",
        language="EN",
        label="Neutral (weiblich)",
        description="Englische Stimme, sachlich.",
    ),
    # ── Other bundled languages (not surfaced by /api/tts/voices) ───
    # Listed here so `exists()` still validates them and we don't
    # need a catalog change if VD ever ships FR/IT/etc.
    VoiceDescriptor(id="fr_male",     language="FR", label="Français — masculin",  description="Voix française native."),
    VoiceDescriptor(id="fr_female",   language="FR", label="Français — féminin",   description="Voix française native."),
    VoiceDescriptor(id="es_male",     language="ES", label="Español — masculino",  description="Voz española nativa."),
    VoiceDescriptor(id="es_female",   language="ES", label="Español — femenino",   description="Voz española nativa."),
    VoiceDescriptor(id="it_male",     language="IT", label="Italiano — maschile",  description="Voce italiana nativa."),
    VoiceDescriptor(id="it_female",   language="IT", label="Italiano — femminile", description="Voce italiana nativa."),
    VoiceDescriptor(id="pt_male",     language="PT", label="Português — masculino", description="Voz portuguesa nativa."),
    VoiceDescriptor(id="pt_female",   language="PT", label="Português — feminino",  description="Voz portuguesa nativa."),
    VoiceDescriptor(id="nl_male",     language="NL", label="Nederlands — man",      description="Nederlandse stem."),
    VoiceDescriptor(id="nl_female",   language="NL", label="Nederlands — vrouw",    description="Nederlandse stem."),
    VoiceDescriptor(id="ar_male",     language="AR", label="العربية — ذكر",         description="صوت عربي."),
    VoiceDescriptor(id="hi_male",     language="HI", label="हिन्दी — पुरुष",          description="हिन्दी आवाज़."),
    VoiceDescriptor(id="hi_female",   language="HI", label="हिन्दी — स्त्री",          description="हिन्दी आवाज़."),
)


# Curated cross-language additions. Voxtral's "voice-as-instruction"
# model lets any speaker render any language; the speaker just imposes
# their accent on the output. After dogfooding `de_male` and finding
# it Austrian-leaning, the user picked these four as "promising
# non-native options" — Dutch (phonologically closest to German) and
# the neutral English-trained speakers. Each entry is paired with a
# German accent hint that overrides the native descriptor's text when
# the voice is shown in the DE picker, so the user knows what they're
# auditioning before tapping play.
#
# Slice 07's cloning work proved that *new* voice embeddings can't be
# generated from the open-source Voxtral checkpoint (encoder weights
# withheld by Mistral — see PRD addendum). This curated list is the
# only practical way to expand the picker beyond the seven native
# DE/EN voices Mistral ships pre-computed.
_CROSS_LANGUAGE_EXTRAS: dict[str, tuple[tuple[str, str], ...]] = {
    "DE": (
        ("nl_male",        "Niederländischer Akzent — am nächsten zu Hochdeutsch"),
        ("nl_female",      "Niederländischer Akzent — am nächsten zu Hochdeutsch"),
        ("neutral_male",   "Englischer Akzent — neutral, sachlich"),
        ("neutral_female", "Englischer Akzent — neutral, sachlich"),
    ),
    # EN already has casual/cheerful/neutral natively; no extras needed.
    "EN": (),
}


# --- deep-module surface --------------------------------------------------


# Allow only id-shaped strings to be used in filesystem paths. Defeats
# path traversal at the catalog boundary so the router doesn't have to
# re-validate. `librivox_<slug>` uses lowercase ASCII + digits +
# underscore; `custom_<hex>` is `custom_` + 8 lowercase hex chars.
_ID_PATTERN = "[a-z0-9_]+"


def _is_valid_filesystem_id(voice_id: str) -> bool:
    import re
    if not voice_id or len(voice_id) > 128:
        return False
    return bool(re.fullmatch(_ID_PATTERN, voice_id))


class VoiceCatalog:
    """Union of bundled (static) + filesystem (custom / librivox) voices.

    Bundled voices come from `_VOICES` and never change. Filesystem
    voices are walked from `refs_root` on each query so an upload or
    delete is visible without a webapp restart. The directory layout
    is one subdir per voice id: `<refs_root>/<voice_id>/audio.wav` +
    `<refs_root>/<voice_id>/metadata.json`.

    Walks are stateless and re-read the filesystem each call — the
    directory holds at most a few dozen entries in normal use and a
    full walk is sub-millisecond.
    """

    def __init__(
        self,
        bundled: tuple[VoiceDescriptor, ...] = _VOICES,
        refs_root: Path | None = None,
    ) -> None:
        self._bundled = bundled
        self._bundled_by_id: dict[str, VoiceDescriptor] = {v.id: v for v in bundled}
        self._refs_root = refs_root

    # -- read surface ------------------------------------------------------

    def list(self, language: str) -> list[VoiceDescriptor]:
        lang = language.upper()
        return [v for v in self._all_voices() if v.language == lang]

    def list_grouped(self, *, languages: tuple[str, ...] | None = None) -> dict[str, list[dict[str, str | None]]]:
        """Used by the `/api/tts/voices` route. `languages` filters the
        output; passing `None` returns every language we have a voice
        for. Custom/librivox entries appear in the same language groups
        as bundled."""
        grouped: dict[str, list[VoiceDescriptor]] = {}
        for v in self._all_voices():
            grouped.setdefault(v.language, []).append(v)
        keys = tuple(lang.upper() for lang in languages) if languages else tuple(grouped.keys())
        return {lang: [v.to_dict() for v in grouped.get(lang, [])] for lang in keys}

    def list_for_picker(self, language: str) -> list[dict[str, str | None]]:
        """Assemble the picker for a given speech-output language.

        Returns native bundled voices for that language first, then a
        curated set of non-native voices (from `_CROSS_LANGUAGE_EXTRAS`)
        with a German/English accent hint substituted into the
        description. Filesystem-backed sources (custom + librivox) are
        excluded entirely — the open-source Voxtral checkpoint can't
        actually clone from a reference, so any non-bundled voice in
        the picker would silently fall back to Piper at synth time.

        The catalog's other read methods (`list`, `list_grouped`,
        `get`, `exists`) stay unchanged so existing tests + internal
        callers continue to see the full set.
        """
        lang = language.upper()
        out: list[VoiceDescriptor] = []
        for v in self._bundled:
            if v.language == lang:
                out.append(v)
        for extra_id, accent_hint in _CROSS_LANGUAGE_EXTRAS.get(lang, ()):
            native = self._bundled_by_id.get(extra_id)
            if native is None:
                continue
            out.append(VoiceDescriptor(
                id=native.id,
                language=lang,                  # re-tag for picker context
                label=native.label,
                description=accent_hint,
                source="bundled",
                ref_text=None,
            ))
        return [v.to_dict() for v in out]

    def exists(self, voice_id: str) -> bool:
        return self.get(voice_id) is not None

    def get(self, voice_id: str) -> VoiceDescriptor | None:
        if voice_id in self._bundled_by_id:
            return self._bundled_by_id[voice_id]
        # Filesystem lookup. Only walk if the id matches the safe shape
        # — guards against `..` and similar traversal attempts.
        if not _is_valid_filesystem_id(voice_id):
            return None
        if self._refs_root is None:
            return None
        return self._read_filesystem_voice(voice_id)

    # -- write surface (filesystem only) -----------------------------------

    def add_filesystem_voice(
        self,
        voice_id: str,
        *,
        language: str,
        label: str,
        description: str,
        ref_text: str | None,
        source: VoiceSource,
        audio_bytes: bytes,
    ) -> VoiceDescriptor:
        """Write a new reference clip + metadata to the filesystem.

        Caller is responsible for ensuring `voice_id` is unique and
        well-formed. Raises `ValueError` for shape violations and
        `FileExistsError` if the slot is already taken.
        """
        if not _is_valid_filesystem_id(voice_id):
            raise ValueError(f"invalid voice id shape: {voice_id!r}")
        if source not in ("librivox", "user"):
            raise ValueError(f"only librivox/user voices live on the filesystem (got {source!r})")
        if self._refs_root is None:
            raise RuntimeError("voice catalog has no refs_root configured")

        target_dir = self._refs_root / voice_id
        if target_dir.exists():
            raise FileExistsError(f"voice id already exists: {voice_id}")
        target_dir.mkdir(parents=True, exist_ok=False)

        audio_path = target_dir / "audio.wav"
        metadata_path = target_dir / "metadata.json"

        # Atomic-ish write: tmp file + rename so a partial write can't
        # produce an entry the catalog sees in a half-baked state.
        audio_tmp = audio_path.with_suffix(".wav.tmp")
        audio_tmp.write_bytes(audio_bytes)
        audio_tmp.replace(audio_path)

        descriptor = VoiceDescriptor(
            id=voice_id,
            language=language.upper(),
            label=label,
            description=description,
            source=source,
            ref_text=ref_text,
        )
        metadata_tmp = metadata_path.with_suffix(".json.tmp")
        metadata_tmp.write_text(json.dumps(descriptor.to_dict(), ensure_ascii=False, indent=2))
        metadata_tmp.replace(metadata_path)

        return descriptor

    def delete_filesystem_voice(self, voice_id: str) -> bool:
        """Remove a filesystem-backed voice. Returns True on success,
        False if the id doesn't exist on disk. Refuses to operate on
        ids that fail the safe-shape check (defeats traversal)."""
        if not _is_valid_filesystem_id(voice_id):
            return False
        if self._refs_root is None:
            return False
        target_dir = self._refs_root / voice_id
        if not target_dir.is_dir():
            return False
        # Resolve and re-check that target_dir is still under refs_root
        # — defends against symlink escapes inside the directory tree.
        resolved = target_dir.resolve()
        if self._refs_root.resolve() not in resolved.parents:
            return False
        for child in target_dir.iterdir():
            child.unlink(missing_ok=True)
        target_dir.rmdir()
        return True

    def reference_audio_path(self, voice_id: str) -> Path | None:
        """On-disk path to the WAV for a filesystem-backed voice, or
        `None` for bundled / unknown / mis-shaped ids. Used by the
        synth route to construct the `file://` URI passed to vLLM."""
        if not _is_valid_filesystem_id(voice_id):
            return None
        if self._refs_root is None:
            return None
        candidate = self._refs_root / voice_id / "audio.wav"
        return candidate if candidate.is_file() else None

    # -- internals ---------------------------------------------------------

    def _all_voices(self) -> list[VoiceDescriptor]:
        out: list[VoiceDescriptor] = list(self._bundled)
        if self._refs_root and self._refs_root.is_dir():
            for entry in sorted(self._refs_root.iterdir()):
                if not entry.is_dir():
                    continue
                voice = self._read_filesystem_voice(entry.name)
                if voice is not None:
                    out.append(voice)
        return out

    def _read_filesystem_voice(self, voice_id: str) -> VoiceDescriptor | None:
        if self._refs_root is None:
            return None
        metadata_path = self._refs_root / voice_id / "metadata.json"
        if not metadata_path.is_file():
            return None
        try:
            data = json.loads(metadata_path.read_text())
        except (OSError, json.JSONDecodeError) as exc:
            logger.warning("voice catalog: bad metadata at %s: %s", metadata_path, exc)
            return None
        try:
            return VoiceDescriptor(
                id=data["id"],
                language=str(data["language"]).upper(),
                label=data["label"],
                description=data.get("description", ""),
                source=data.get("source", "user"),
                ref_text=data.get("ref_text"),
            )
        except KeyError as exc:
            logger.warning("voice catalog: missing key %s in %s", exc, metadata_path)
            return None


# Module-level singleton — bundled stays static; filesystem voices are
# re-walked on each query so uploads land without a webapp restart.
def _make_default_catalog() -> VoiceCatalog:
    # Late import keeps the module side-effect-free until first use,
    # and avoids a circular import: paths.py is dependency-free.
    from paths import voxtral_refs_dir
    refs = voxtral_refs_dir()
    refs.mkdir(parents=True, exist_ok=True)
    return VoiceCatalog(refs_root=refs)


catalog: VoiceCatalog = _make_default_catalog()
