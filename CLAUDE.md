# CLAUDE.md

Guidance for Claude Code when working in this repository. This file is navigation only; the
linked documents are authoritative.

Voice Diary is a monorepo with two independently deployed components: `ios/` (Swift 6 / SwiftUI app,
iPhone 17 Pro, iOS 26) and `server/` (FastAPI backend, Python 3.12, Docker). Both tracks are in
active implementation. Trust `git log` and the source trees over any status table.

## Where to look

- `SPEC.md` — product + technical spec, single source of truth for behaviour (state machine,
  manifest, endpoints, settings). Read it before changing behaviour; update it in the same commit
  as any manifest field or endpoint change.
- `DEVELOPMENT.md` — repo layout, prerequisites, milestone plan, **deployment (§4.4)**, and the
  **canonical test commands (§7.4)**. Do not copy test or deploy recipes into other files.
- `DESIGN.md` — design system; tokens come from `docs/design-system/tokens/` via
  `scripts/build_design_system.sh`.
- `CODING_STANDARDS.md` — coding conventions and the reviewer's hard rules.
- `CONTEXT.md` + `docs/adr/` — domain language and decisions; see `docs/agents/domain.md`.
- Architecture map: docs/architecture/*.json (SeeCode specs, evidence-linked; rules in docs/architecture/README.md).
- `ios/README.md` — iOS setup, signing, device builds, manual test plan.
- `server/README.md` — server setup, environment, operations.
- `docs/agents/issue-tracker.md`, `docs/agents/triage-labels.md` — issue tracker and label rules.

## Working rules

- Stay inside one component's directory. A change to the `ios/` ↔ `server/` contract is two cards:
  the server half plus SPEC.md first, then the iOS half naming the server PR (detail in
  `CODING_STANDARDS.md`).
- Read existing code before changing it; prefer the simpler implementation.
- Commit messages: short, imperative, no Claude attribution.
- Never hard-code colours, spacing, radius, or font sizes; never hand-edit generated token files.
- Secrets (`.env`, Keychain entries, `data/msal_cache.bin`) never get committed.
- Run the tests in `DEVELOPMENT.md` §7.4 before claiming a change is done.

## Non-negotiables (details in SPEC.md)

- Audio is never chopped, except the walkthrough advance/finish command word (SPEC §7.4).
- Max one follow-up question per event; todos are confirmed only at CLOSING.
- All Microsoft Graph access is server-side; no MSAL on the phone.
- Enrichment is the only mid-session network path; no telemetry, ever.
- Tailscale only — the server is never publicly reachable.
- No n8n anywhere.
- German is the primary language; English is first-class, not a fallback.
