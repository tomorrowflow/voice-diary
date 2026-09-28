# Coding Standards — Voice Diary

The reviewer agent loads this during code review (`@.sandcastle/CODING_STANDARDS.md`) so
these standards are enforced without costing implementer tokens. They are distilled from
`CLAUDE.md` and `SPEC.md` — those remain the source of truth; when in doubt, read them.

## Load-bearing hard rules (never relax without re-reading SPEC.md)

1. **Design tokens are the only source of style.** No hard-coded colours, spacing, radius,
   or font sizes in feature code. iOS goes through `Theme.*` and `DSButtonStyle`; server CSS
   through `var(--*)`. Never hand-edit generated token files (`DSColor.swift`, `DSMetrics.swift`,
   `DSSemantic.swift`, `tokens.css`, `tokens-semantic.css`) — edit the source JSON in
   `docs/design-system/tokens/` and rerun `scripts/build_design_system.sh`.
2. **No n8n. Anywhere.** If you find an n8n reference in copied code, remove it.
3. **No telemetry, ever.** Errors log locally only. No outbound traffic except to the user's
   own server over Tailscale.
4. **Secrets never committed / never introduced.** `server/.env`, Keychain entries, and
   `data/msal_cache.bin` stay out of git and out of prompts. The sandbox has no `.env`; code
   must not assume one exists. Never hard-code the bearer token or a tailnet hostname.
5. **All Microsoft Graph access is server-side.** No MSAL on the phone, no OAuth UI on the phone.
6. **Audio is never chopped** except the single documented walkthrough advance/finish trim
   (SPEC §7.4). Do not add new audio-trimming paths.
7. **Tailscale, not public endpoints.** The server must never become publicly reachable.
8. **Segmented ingest, not monolithic.** Per-calendar-event segments with explicit
   `calendar_ref`; AI prompts live in `ai_prompts[]`, never in narrative transcripts.

## iOS style

- Swift 6, SwiftUI App lifecycle, iOS 26 SDK. iOS 26 APIs may be used without availability guards.
- UI strings in German (primary) + English (first-class fallback), all via the string catalog
  (EN source, DE translation). User-facing copy explains the feature — never dev history or
  internals. Code and comments in English.
- Buttons go through `DSButtonStyle` (five variants × three sizes). If a button doesn't fit,
  propose extending `specs/components/button.json` rather than ad-hoc styling.
- New components register at `Theme.*`; feature code must not reach into `DSColor`/`DSMetrics`.
- Anything CoreAudio touches must use `.completeUntilFirstUserAuthentication` file protection.

## Server style

- Python 3.12, FastAPI, Pydantic v2, asyncpg. The existing codebase uses plain dicts and
  manual (parameterized) SQL in places — **follow the existing style; do not introduce
  SQLAlchemy or any other ORM.**
- Match the existing router pattern: bearer-token `Depends` is per-router, not global.
- Prefer the established deep-adapter template (`voxtral_client.py`, `msgraph_client.py`:
  injectable transport, typed errors, constructor config) when extracting a new external seam.

## Testing

- Server: FastAPI test client per router; mock MSAL, LightRAG, Ollama, Whisper. Every new
  public function/route gets at least one test. Run `python -m pytest server/webapp/tests/`.
- iOS: unit tests for pure logic (opener selection, manifest encoding, state-machine
  transitions, wake-word matcher). Builds and device/simulator tests happen on the host only.

## Commits

- Short, imperative subject. **No Claude/AI attribution. No `RALPH:` or other prefix.**
- Update docs alongside code: a changed manifest field or endpoint shape must update `SPEC.md`
  in the same commit.

## Architecture

- Keep modules focused; prefer deep modules (small interface, deep implementation) over
  shallow pass-throughs. Prefer the simpler implementation — the spec already rejected several
  over-engineered options.
- Changes crossing the `ios/` ↔ `server/` boundary must touch both sides in the same commit
  and update `SPEC.md` if the contract changes.
