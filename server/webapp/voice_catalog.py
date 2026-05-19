"""Static catalog of bundled Voxtral voice references.

`Voxtral-4B-TTS-2603` ships 20 reference voices in `voice_embedding/`
(one `.pt` file per voice). The catalog encodes that list as a tied-to-
model-version constant: vLLM Omni does not expose a `/v1/voices`
endpoint and the OpenAI-compatible audio API has no list operation
either, so embedding the manifest in code is simpler than a live probe.

The catalog itself is language-agnostic — it contains all 20 voices.
The `tts` router filters to the languages Voice Diary supports (DE+EN)
when serving `/api/tts/voices`, so adding French openers later would
only need a router change, not a catalog one.

Source of truth for the voice list:
    https://huggingface.co/mistralai/Voxtral-4B-TTS-2603/tree/main/voice_embedding
"""

from __future__ import annotations

from dataclasses import asdict, dataclass


@dataclass(frozen=True)
class VoiceDescriptor:
    """One Voxtral reference voice. `language` is the *source* language
    of the reference clip — picking `de_male` for German output produces
    natural German prosody; picking an English-sourced voice for German
    output produces German rendered with an English speaker's accent."""

    id: str
    language: str           # ISO-like: "DE", "EN", "FR", … (matches our route's accepted values)
    label: str              # Display name for the picker row
    description: str        # One-line description shown under the label

    def to_dict(self) -> dict[str, str]:
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


# --- deep-module surface --------------------------------------------------


class VoiceCatalog:
    """In-memory grouping of `_VOICES` with O(1) lookup by id."""

    def __init__(self, voices: tuple[VoiceDescriptor, ...] = _VOICES) -> None:
        self._voices = voices
        self._by_id: dict[str, VoiceDescriptor] = {v.id: v for v in voices}
        self._by_language: dict[str, list[VoiceDescriptor]] = {}
        for v in voices:
            self._by_language.setdefault(v.language, []).append(v)

    def list(self, language: str) -> list[VoiceDescriptor]:
        return list(self._by_language.get(language.upper(), ()))

    def list_grouped(self, *, languages: tuple[str, ...] | None = None) -> dict[str, list[dict[str, str]]]:
        """Used by the `/api/tts/voices` route. `languages` filters the
        output; passing `None` returns every language we know about."""
        keys = tuple(lang.upper() for lang in languages) if languages else tuple(self._by_language.keys())
        return {
            lang: [v.to_dict() for v in self._by_language.get(lang, ())]
            for lang in keys
        }

    def exists(self, voice_id: str) -> bool:
        return voice_id in self._by_id

    def get(self, voice_id: str) -> VoiceDescriptor | None:
        return self._by_id.get(voice_id)


# Module-level singleton — the catalog is immutable, no reason to
# instantiate per request.
catalog: VoiceCatalog = VoiceCatalog()
