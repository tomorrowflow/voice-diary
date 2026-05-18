# 02 · Voice catalog + per-language voice picker

Labels: needs-triage, type/feature, area/tts, area/server, area/ios, area/settings
Type: AFK

## Parent

[Voxtral TTS Integration PRD](../../prd/voxtral-tts-integration.md)

## What to build

Make Voxtral voices selectable as first-class peers to Apple and Piper in the Settings voice picker, independently per language. On the server, expose a voice catalog endpoint backed by the deep `voice_catalog` module so adding a voice on the server side does not require an iOS release. On iOS, fetch and cache the catalog, render a "Voxtral (Server)" section per language in `VoiceSettingsView`, and route `"voxtral:<id>"` voice IDs through `VoiceRegistry` to the engine built in slice 01.

After this slice a user can open Settings, see the bundled Mistral voices listed per language, pick one for German and one for English, tap preview on each, and have those selections persist across an app restart. Walkthrough integration is **not** in scope here — the debug button from slice 01 (or the Settings preview itself) is the verification surface.

## Acceptance criteria

- [ ] `GET /api/tts/voices` returns voices grouped by language in the shape `{ "DE": [VoiceDescriptor, …], "EN": [VoiceDescriptor, …] }` where each descriptor has at least `id`, `name`, and an optional `description`; bearer auth required.
- [ ] The `voice_catalog` server module is implemented as a deep module with an injectable `voxtral_client`, an in-memory cache, and a clean `list(language)` / `exists(voice_id)` surface. It is independent of FastAPI and contains no synthesis logic.
- [ ] `VoiceCatalogClient` on iOS fetches `/api/tts/voices` on first need, caches the JSON in `UserDefaults`, and survives an app restart (the cached list is shown immediately on next launch, refreshed in the background).
- [ ] `VoiceSettingsView` shows a "Voxtral (Server)" section per language, populated from the catalog client, with one radio row per voice and a per-row preview button.
- [ ] Tapping a row updates `VoicePreferences` for that language with the value `"voxtral:<id>"`; the selection is persisted and reflected after an app restart.
- [ ] Tapping a preview button synthesizes a sample utterance in that specific voice via `VoxtralTTS` and plays it through the speaker, regardless of which voice is currently selected for the walkthrough.
- [ ] `VoiceRegistry.engine(for:)` routes `"voxtral:"`-prefixed voice IDs to `VoxtralTTS.shared` above the Piper branch; Apple and Piper routing is unchanged.
- [ ] Empty state: when no server URL or bearer token is configured, the Voxtral section shows an explanatory message ("Kein Server konfiguriert" / equivalent), not a spinner or a crash.
- [ ] Server unreachable: when the catalog cannot be fetched and no cache exists, the section shows a one-tap retry, not a stuck spinner.
- [ ] All new UI honors the design-system rule: `Theme.*` and existing button styles only, no hard-coded colour, spacing, radius, or font size.

## Blocked by

- [01 · Hello, Voxtral — first end-to-end utterance](./01-hello-voxtral.md)
