# Blindfolded cloud egress is an explicit opt-in, default local

**Status:** accepted (2026-07-08)

voice-diary has had zero cloud-AI egress: STT, analysis, and TTS all run locally. We
are introducing the first exception: the once-per-session `document_processor`
narrative analysis MAY be routed through the Blindfold proxy to a frontier cloud
model — **only when the operator explicitly enables it in config; the default remains
local Ollama**. Blindfold pseudonymizes entities (names, orgs, contact PII) but the
journal *content* — events, feelings, relationships — still leaves the machine.
Entity-level protection is the accepted bar for this step; the operator of this
single-user system is also its data subject and accepts content-level exposure for
the sessions they route through it.

## Considered options

- **Stay fully local** — rejected for this step: local models are materially worse at
  the narrative analysis, and the operator wants frontier quality here.
- **Content-level protection first** (summarize-then-send / PAPILLON-style local
  pre-processing) — rejected as a prerequisite: an open research problem that would
  block the integration indefinitely; may come later as a per-session opt-in UX.

## Consequences

- The "fully local" claim in README/SPEC must be qualified wherever it appears.
- Dates in diary prose currently egress **unblindfolded** (Blindfold's L1 covers
  emails/phones/IBANs/IDs; its date-shift is designed but not wired — Blindfold
  ADR-0005/#25). Dates are quasi-identifiers; this is inside the accepted
  pseudonymization bar, but it is a known exposure, not an oversight.
- Per-session or per-segment egress granularity is deliberately out of scope for the
  first slice; the switch is global diary config.
- The Blindfold side treats the diary as an ordinary client (configurable base URL);
  no diary-specific mechanism exists in Blindfold (its ADR-0012: concepts + data
  seed, never code coupling).
