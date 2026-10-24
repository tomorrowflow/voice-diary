# Coding Standards — Voice Diary

Loaded on every review. Distilled from `CLAUDE.md` and `SPEC.md`, which stay authoritative.

## Hard rules (blocking, never relax without re-reading SPEC.md)

1. **Design tokens are the only source of style.** No hard-coded colours, spacing, radius, or font
   sizes in feature code. iOS goes through `Theme.*` and `DSButtonStyle`; server CSS through
   `var(--*)`. Never hand-edit generated token files (`DSColor.swift`, `DSMetrics.swift`,
   `DSSemantic.swift`, `tokens.css`, `tokens-semantic.css`); edit the JSON in
   `docs/design-system/tokens/` and rerun `scripts/build_design_system.sh`.
2. **No n8n. Anywhere.** Remove any n8n reference found in copied code.
3. **No telemetry, ever.** Errors log locally only. No outbound traffic except to the user's own
   server over Tailscale.
4. **No secrets committed or introduced.** `server/.env`, Keychain entries, and
   `data/msal_cache.bin` stay out of git and out of prompts; code must not assume a `.env` exists.
   Never hard-code the bearer token or a tailnet hostname.
5. **All Microsoft Graph access is server-side.** No MSAL or OAuth UI on the phone.
6. **Audio is never chopped** except the single walkthrough advance/finish trim (SPEC §7.4). Add
   no new audio-trimming path.
7. **Tailscale, not public endpoints.** The server must never become publicly reachable.
8. **Segmented ingest.** Per-calendar-event segments with explicit `calendar_ref`; AI prompts live
   in `ai_prompts[]`, never in narrative transcripts.

## iOS

- Swift 6, SwiftUI App lifecycle, iOS 26 SDK; iOS 26 APIs need no availability guards.
- UI strings in German (primary) and English (first-class), via the string catalog (EN source, DE
  translation). Copy explains the feature, never dev history or internals. Code and comments in
  English.
- Buttons use `DSButtonStyle`. If one doesn't fit, propose extending
  `docs/design-system/specs/components/button.json` instead of ad-hoc styling.
- New components register at `Theme.*`; feature code must not reach into `DSColor`/`DSMetrics`.
- Anything CoreAudio touches uses `.completeUntilFirstUserAuthentication` file protection.

## Server

- Python 3.12, FastAPI, Pydantic v2, asyncpg. Plain dicts and manual parameterized SQL are the
  existing style; follow it and introduce no ORM.
- Bearer-token `Depends` is per-router, not global.
- Extract new external seams in the style of `voxtral_client.py` / `msgraph_client.py`: injectable
  transport, typed errors, constructor config.
- Check preconditions and raise before any side effect. A request that will fail must fail before
  it writes files or rows, queues work, or calls Whisper, so a rejection leaves nothing behind.
  Example: BUG-112 (`6b01d15`) moved `SessionNotRetryable` ahead of the resume/Whisper work in the
  retry path (then `session_processing`, now `SessionProcessor` in `session_ingest.py`).

## Tests

Commands live only in `DEVELOPMENT.md` §7.4; run them, don't copy them here. Server: test client
per router, mock MSAL, LightRAG, Ollama, Whisper; every new public function or route gets a test.
iOS: unit-test pure logic (opener selection, manifest encoding, state machine, wake-word matcher);
`xcodebuild` runs on a Mac host only, so review iOS statically.

- No real-time waits over 1 s; wait on an event with a short cap. Synchronize on an
  `asyncio.Event` (or equivalent) and bound the wait by a timeout of at most 1 s. Never sleep until
  something has probably finished. Example: BUG-116 (`1638467`) holds the background vector write
  open on an `asyncio.Event` and sets it, instead of sleeping, in `test_review_vector_tasks.py`.

## Commits and docs

- Short, imperative subject. No Claude/AI attribution; no `RALPH:` or other prefix.
- A changed manifest field or endpoint shape updates `SPEC.md` (§10) in the same commit.

## Architecture

- Prefer deep modules (small interface, deep implementation) over shallow pass-throughs, and the
  simpler implementation.
- **One track per change.** A change to the `ios/` ↔ `server/` contract is two cards. The server
  card lands first and updates SPEC §10. The iOS card names that server card/PR and follows. Block
  a diff that edits the contract on one side without that SPEC update, or an iOS change to the
  contract that names no server card/PR.
