# Handoff 02: Opener prefetch

Read [README.md](README.md) first (shared context, vocabulary, process rules).

**2026-09-23 strength:** Worth exploring. **Dependency category:** local-substitutable
(`DialogLLM` and `TTSEngine` protocols, 3 adapters each).

## The candidate in one line

Pull the opener prefetch/scheduling (~450 lines of caches, dedupe and two-tier scheduling) out of
`WalkthroughCoordinator` into an **OpenerPrefetch** module behind a small interface, e.g.
`prepare(plan)` / `script(for: segmentID) async -> PrefetchedScript?` / `clear()`, with
`DialogLLM` and `TTSEngine` injected.

## Friction found (as of `7ad3de1`, `ios/Sources/Dialog/WalkthroughCoordinator.swift`)

- Opener composition, LLM calls and prefetch sit at ~4022-4432, with 5 caches/task maps exposed as
  coordinator state: `prefetchedOpeners`, `prefetchTasks`, `openerScriptCache`,
  `openerTextTasks`, `noteSummaryCache/Tasks` (note summaries at ~2073-2140). Two-tier fan-out is
  at ~4310. Commits `d0b2eaa` and `9a4294d` show the history.
- **Prompt text leaks outside `OpenerTemplates`.** Inline DE/EN strings sit in
  `composeOpeningIntro` (~4441), `composeNotesIntro` (~2263), `composeNotePrompt` (~2142-2173),
  pickup `preIntro`/`bridge` (~942/~962), enrichment cue/fallback (~2302/~2318) and `hint`
  (~3799). `EventOpenerContext` is built at ~4057-4100. `OpenerTemplates` itself is pure and
  tested.
- `DialogLLMResolver.current()` is called inline 4×, so tests can't substitute a fake LLM.
- Its coupling to the rest of the coordinator is only `plan` plus the segment-ID scheme. After #46
  the segment-ID scheme belongs to `SessionBundle`.

## Overlapping issue: start here

**#5 (IOS-A6) "Extract OpenerPrefetcher from the coordinator"** is **already implemented** on
`sandcastle/issue-5` (3 commits as of 2026-09-25) and parked with `sandcastle:needs-host-verify`.
Its proposed interface was `prefetch(segmentID:spans:)`, `consume(segmentID:) -> Prefetched?`
and `cancelAll()`.

So this grill is mostly **reviewing #5 against the deep-module bar** before it's host-verified
and merged:
- `git log main..sandcastle/issue-5`, `git diff main...sandcastle/issue-5`
- host gate: `scripts/verify_agent_branch.sh sandcastle/issue-5`

## Open questions for the grill (not decided)

1. Does #5's interface hide the scheduling, or does the coordinator still orchestrate the tiers
   (`prefetch` per segment = caller knows the order)? `prepare(plan)` would hide it; per-segment
   calls wouldn't.
2. Should the inline DE/EN prompt strings move into `OpenerTemplates` as part of this, or separately?
3. Are note summaries (`noteSummaryCache/Tasks`) part of the same module?
4. How is the LLM injected? The resolver reads UserDefaults per call (IOS-A15); inject the
   resolver or a resolved `DialogLLM`?
5. Should the **Speaker** module (handoff 06) be folded in here? The review recommended doing 06
   as part of 02.
6. Merge order with #46 (SessionBundle) and #7 (todo flow): all three rewrite the same file.

## Suggested skills

`mattpocock-skills:grilling`, `mattpocock-skills:codebase-design` (DESIGN-IT-TWICE.md if #5's
interface is contested), `mattpocock-skills:code-review` against `sandcastle/issue-5` (spec =
#5 + this handoff), then `mattpocock-skills:to-issues` for follow-ups only (`track:ios`).
