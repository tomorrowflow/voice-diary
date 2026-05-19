# 07 · Voxtral custom voice cloning from 3 s references

Labels: needs-triage, type/feature, area/tts, area/server, area/ios, area/settings
Type: AFK

## Parent

[Voxtral TTS Integration PRD — Slice 07 addendum](../../prd/voxtral-tts-integration.md#addendum--slice-07-custom-voice-cloning-2026-05-19)

## What to build

Reopen the "custom voice cloning" item the original PRD parked as out-of-scope. After slice 02 shipped, the user found Voxtral's two bundled German voices (`de_male`, `de_female`) regionally biased — `de_male` sounds Austrian/Bavarian, not Hochdeutsch. Voxtral's underlying model supports zero-shot voice cloning from a 3-second reference, and vLLM Omni's `/v1/audio/speech` endpoint exposes it via three optional fields (`task_type: "Base"`, `ref_audio`, `ref_text`). This slice makes that capability usable end-to-end inside the walkthrough.

After this slice, the user can: (a) get a curated set of additional voices for free, seeded from public-domain LibriVox recordings via a server-side script; (b) record their own reference clip on the phone in 5–10 seconds, have it auto-transcribed by Parakeet, and have it appear as a selectable voice in the language they tagged it with; (c) delete custom voices they no longer want. All clones flow through the same `voxtral:` voice-id prefix and the same fallback policy as bundled voices.

## Acceptance criteria

- [ ] **Server compose**: new docker volume `voxtral_refs` mounted read-write at `/data/voxtral-refs` on `webapp` and read-only at `/voxtral-refs` on `voxtral`. The `voxtral` sidecar's command includes `--allowed-local-media-path /voxtral-refs` so vLLM can read `file://` URIs from that path.
- [ ] **LibriVox seeding**: `server/scripts/seed_voxtral_refs.py` is idempotent — running it twice produces the same set of clips, identified by stable ids `librivox_<slug>`. It hardcodes a small set of public-domain German tracks (initial set: 2 male, 2 female, all Hochdeutsch where possible) with verified `start_sec` / `duration_sec` trims and curated `ref_text` strings. Skips any clip whose target dir already exists.
- [ ] **Server voice catalog**: `voice_catalog` extended to read the `voxtral-refs/` directory in addition to the static manifest. Combined catalog returns bundled + librivox + user-recorded voices grouped by language. `GET /api/tts/voices` reflects this.
- [ ] **Server upload route**: `POST /api/tts/voices/custom` accepts a multipart upload with fields `label`, `language`, `ref_text`, `audio` (the WAV file). Validates: language is `DE` or `EN`; audio is ≤ 10 MB, ≤ 15 seconds, decodable; label is non-empty. Generates a `custom_<uuid>` id, writes `voxtral-refs/<id>/audio.wav` + `metadata.json` (label, language, ref_text, created_at, source: "user"). Returns the new `VoiceDescriptor`.
- [ ] **Server delete route**: `DELETE /api/tts/voices/custom/{id}` removes the directory. Refuses to delete `librivox_*` or bundled-Mistral entries (`source != "user"`). Returns 404 on unknown id.
- [ ] **Server synth integration**: `POST /api/tts/synthesize` recognises any voice id with prefix `custom_` or `librivox_`, looks up the metadata, and forwards `task_type: "Base"`, `ref_audio: file:///voxtral-refs/<id>/audio.wav`, `ref_text: <stored>` to vLLM. Unknown reference-backed voice ids still return `unknown_voice` 400.
- [ ] **iOS recording UI**: new `VoxtralCloneRecorderView` accessible from `VoiceSettingsView` via "Eigene Stimme aufnehmen" buttons under each language section. Includes: record button, audio-level meter, stop, preview playback, name field, language indicator (set by the entry point — DE button → DE, EN button → EN), auto-transcribe via the already-loaded `ParakeetManager`, editable `ref_text` field pre-filled with the transcript, save button that uploads to the server.
- [ ] **iOS recorder constraints**: max 15 seconds of capture, AVAudioRecorder writing WAV at 24 kHz mono (matching Voxtral output). Audio session correctly leaves the walkthrough's session untouched (uses its own dedicated recorder instance).
- [ ] **iOS catalog refresh**: after a successful upload or delete, the local `VoiceCatalogClient` cache invalidates and the picker reflects the new state without an app restart.
- [ ] **iOS delete affordance**: in `VoiceSettingsView`, user-recorded voices (and only those) show a small delete button. Tapping confirms via alert, then calls `DELETE /api/tts/voices/custom/{id}`.
- [ ] **`.gitignore` covers `server/data/voxtral-refs/`** (already covered by the broader `server/data/` rule, but verify).
- [ ] **No design-system violations**: all new UI uses `Theme.*` and existing button styles.

## Blocked by

- [01 · Hello, Voxtral — first end-to-end utterance](./01-hello-voxtral.md) — shipped
- [02 · Voice catalog + per-language voice picker](./02-voice-catalog-picker.md) — shipped

## Notes

- **LibriVox quality is a known gamble.** The user accepted this trade. The fallback when the seeded clips disappoint is the recording UI itself — record your own.
- **Voice-id format choices.** `custom_<uuid>` for user uploads (uuid keeps ids opaque + collision-free), `librivox_<slug>` for seeded clips (stable across re-runs of the seed script so the catalog is reproducible). Both flow through `voxtral:<id>` in `VoicePreferences` and route via the existing `VoiceRegistry` voxtral branch.
- **No cross-language clones in this slice.** Each clip is tagged with one language and only appears in that language's picker section. The off-language render quality is unpredictable and was the original bug that motivated this whole project.
- **Server-side validation is the security layer.** The webapp owns the `voxtral-refs/` directory; vLLM only reads. No path traversal, no symlink escapes, only id-shaped strings allowed in path lookups.
- **The fallback policy still applies.** If a custom voice synth fails on the server side, `TTSFallbackPolicy` re-dispatches to Piper or Apple just like for bundled voices. The fallback runs in the user's other language's voice if the per-language preference is set — same behaviour as today.
