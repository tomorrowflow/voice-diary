# Sandcastle Issue Plan — grill target

**Status: proposed, NOT yet filed.** This is the plan to turn `docs/REVIEW-2026-07-04.md`
findings into GitHub issues that the sandcastle environment can work. Per the review's intended
workflow (validate via `/grill-me`, then triage into issues), **grill this plan first** — then
file the survivors.

- The env is already built and durable: `.sandcastle/` (Containerfile, `main.mts`, prompts,
  CODING_STANDARDS), `scripts/verify_agent_branch.sh`, `docs/SANDCASTLE-RUNBOOK.md`, and the
  `/phase` skill + `implement`/`verify` agents in `.claude/`.
- The issue content is the **editable manifest** in `scripts/sandcastle_create_issues.py`
  (the `F` list) — one tuple per finding. Editing that list is how grill outcomes get applied.
- Nothing has been filed on GitHub yet. Labels `track:server`, `track:ios`, `priority:high`
  are created by the script on run (the `Sandcastle` label already exists).

## Proposed set — 51 issues (all actionable findings; UX-8 excluded, resolved)

Each issue is titled `[FINDING-ID] <imperative summary>`, labelled `Sandcastle` + `track:*`
(+ `priority:high` where noted). Track drives the merge gate: **server** auto-merges after the
pytest + review gate; **ios** parks for the macOS host build gate (never auto-merged).

| ID | Track | Prio | Strength/Sev | Title |
|----|-------|------|--------------|-------|
| IOS-A1 | ios | | Strong | Decompose WalkthroughCoordinator god module |
| IOS-A2 | ios | | Strong | Wire or delete AudioEngine.wasInterrupted dead member |
| IOS-A3 | ios | | Strong | Stream multipart upload body to a temp file |
| IOS-A4 | ios | | Strong | Upload queue: don't drop whole session on one missing file |
| IOS-A5 | ios | | Worth exploring | Collapse ChainDialogLLM pass-through |
| IOS-A6 | ios | | Strong | Extract OpenerPrefetcher |
| IOS-A7 | ios | | Strong | Extract PickupResolver |
| IOS-A8 | ios | | Strong | Extract TranscriptExcerpt + TodoConfirmationFlow |
| IOS-A9 | ios | | Worth exploring | Deepen Segment enum |
| IOS-A10 | ios | | Worth exploring | View intent onto WalkthroughState props |
| IOS-A11 | ios | **high** | Strong (bug?) | Wire TTSFallbackPolicy into live speak path |
| IOS-A12 | ios | | Worth exploring | Extract SessionMutations + HistoryGrouping from VerlaufView |
| IOS-A13 | ios | | Worth exploring | De-duplicate AudioEngine resample body |
| IOS-A14 | ios | | Worth exploring | AudioCapturing + SessionTransport test seams |
| IOS-A15 | ios | | Speculative | Parameterize preference resolution |
| SRV-A1 | server | | Strong | OllamaClient adapter |
| SRV-A2 | server | | Strong | Shared Whisper+ffmpeg module |
| SRV-A3 | server | | Worth exploring | Centralize scattered config |
| SRV-A4 | server | | Worth exploring | Standardize HTTP error interface |
| SRV-A5 | server | | Strong (low risk) | Relocate ~30 CRUD routes out of main.py |
| SRV-A6 | server | | Strong | Persist session ingest status |
| SRV-A7 | server | | Worth exploring | Unify two ingest pipelines |
| SRV-A8 | server | | Worth exploring | Stop raw SQL leaking out of db.py |
| SRV-A9 | server | | Speculative | Harden Qdrant seam |
| SRV-A10 | server | | Strong (through-line) | Codify good adapter template |
| SRV-A11 | server | | Strong (5 min) | Delete last n8n comment |
| SEC-1 | server | **high** | High | Bind port 8000 to tailnet IP |
| SEC-2 | server | **high** | High | Authenticate legacy HTMX/admin/data API |
| SEC-3 | ios | | Medium | Stop exporting audio with URLFileProtection.none |
| SEC-4 | server | | Low | Generate Postgres password |
| SEC-5 | server | | Low | Parameterize SQL in nocodb import tool |
| SEC-6 | server | | Low | Validate LLM output from transcripts |
| SEC-7 | ios | | Info | Log spoken command token as .private |
| UX-1 | ios | | Medium | Surface recording interruption |
| UX-2 | ios | | Low | Map disk-full to localized message |
| UX-3 | ios | | Low | Distinguish enrichment failure copy |
| UX-4 | ios | | Low | Treat upload 409 as success |
| UX-5 | ios | | Low | 'Repeat this opener' affordance |
| UX-6 | ios | **high** | High | Implement onboarding (SPEC §14) |
| UX-7 | ios | | Medium | URL validation + onboarding entry to server setup |
| UX-9 | ios | | Medium | DisplayTimer Dynamic Type |
| UX-10 | ios | | Medium | VoiceOver coverage on custom chrome |
| UX-11 | ios | | Low | Reduced-motion support |
| UX-12 | server | | Medium | HTMX review UI empty states + save feedback |
| UX-13 | ios | | Medium | Reconcile Settings surface with SPEC §12 |
| DOC-1 | server | **high** | High | Fix stale "implementation about to begin" docs |
| DOC-2 | server | | Medium | Add Voxtral TTS to CLAUDE.md stack tables |
| DOC-3 | server | | Medium | Gemma is implemented + primary for German |
| DOC-4 | server | | Medium | Refresh stale Voxtral PRD |
| DOC-5 | server | | Medium | Mark unmet DEVELOPMENT.md M11 exit criterion |
| DOC-6 | server | | Low | Reconcile deploy env-var docs |

Full bodies (files + problem + solution) are in `scripts/sandcastle_create_issues.py`.

## Open decisions for the grill (resolve these before filing)

1. **Scope / prune.** File all 51, or drop the low-confidence ones? Candidates to cut or defer:
   `IOS-A15`, `SRV-A9` (Speculative); the "Worth exploring" cluster (`IOS-A5/A9/A10/A12/A13/A14`,
   `SRV-A3/A4/A7/A8`). The setup plan's own Phase 1 is a *single* server pilot — filing 51 at
   once is the opposite; decide the real intake.
2. **Confirm the "behaves-like-a-bug" ones before filing as bugs.** `IOS-A11` (TTS fallback
   claimed unwired) needs verification against SPEC §15 — is it actually a live bug, or is
   fallback applied somewhere the reviewer missed? Same question links `IOS-A2` ↔ `UX-1`.
3. **Merge vs split.**
   - `SEC-1` + `SEC-2` are called out as "fix the pair together, smallest effort / largest risk
     reduction" — one issue or two linked?
   - `SRV-A5` should be done *with* `SEC-2` (moved routes gain auth) — sequence or combine?
   - `IOS-A2` and `UX-1` share a root — one issue or two?
   - Split the oversized ones into tracer-bullet slices? `IOS-A1` (4,859-line god module),
     `UX-6` (onboarding, 10 SPEC steps), `UX-13` (whole settings surface) are too big for one
     red-green-refactor slice as written.
4. **Dependencies for the planner.** Encode "blocked by" so the autonomous planner serializes
   conflicts: `IOS-A6/A7/A8` **before** `IOS-A1`; `SRV-A1` **before** its 7 callers; `SRV-A2`
   before `SRV-A7`; `SRV-A6` before `UX-4`. Also: everything touching
   `WalkthroughCoordinator.swift` (`IOS-A1/A6/A7/A8`, `UX-3/A5`) conflicts on one file — must not
   run concurrently. Capture this as issue text or a dependency label the planner can read.
5. **Product decisions, not code decisions.** Several findings are "implement OR amend the spec":
   `UX-13` (which §12 settings are really wanted vs intentionally dropped), `UX-3` (exact failure
   copy), `UX-5`/`UX-11` (worth doing at all for a single-user tool?). These need your call, not
   an agent's.
6. **Track edge cases.** Docs are filed `track:server` (sandboxable, no host build) — OK? `UX-4`
   touches both client + server but is filed `ios` (the fix is client-side); confirm.
7. **Severity/priority.** Only 5 carry `priority:high` (`SEC-1`, `SEC-2`, `IOS-A11`, `UX-6`,
   `DOC-1`). Is that the right "do first" set, or promote/demote?

## Resume procedure (after grilling, clean context)

1. Read this file + `docs/REVIEW-2026-07-04.md` + `docs/SANDCASTLE-SETUP-PLAN.md`.
2. Apply the grill outcomes by editing the `F` list in `scripts/sandcastle_create_issues.py`
   (drop rows, split a row into slices, add `Blocked by:` lines to bodies, retitle, re-track).
3. Dry-run: `python3 scripts/sandcastle_create_issues.py --dry-run`.
4. File: `python3 scripts/sandcastle_create_issues.py` (idempotent — re-runnable; skips `[ID]`s
   already filed).
5. Then work them via `/phase <id>` (interactive) or `npm run sandcastle` from an integration
   branch (autonomous) — see `docs/SANDCASTLE-RUNBOOK.md`.

## Grill kickoff prompt (paste into a fresh, clean-context session)

> `/grill-me`
>
> Grill me on the plan to file GitHub issues from a code review. Read these first, in order:
> `docs/SANDCASTLE-ISSUE-PLAN.md` (the plan under test — 51 proposed issues + the open
> decisions), `docs/REVIEW-2026-07-04.md` (the findings themselves, with confidence grades),
> and `docs/SANDCASTLE-SETUP-PLAN.md` (how the issues get worked). The editable manifest is the
> `F` list in `scripts/sandcastle_create_issues.py` — do not run it; the point of this session
> is to decide what it should contain.
>
> Don't accept "file all 51" as a default. Drive the decision tree in the plan's "Open decisions"
> section to resolution, one branch at a time, and push hardest on:
> 1. **Prune vs keep** each Speculative / "Worth exploring" finding — make me justify why a
>    low-confidence refactor is worth an agent's time on a single-user personal tool, or cut it.
> 2. **Bug vs not** — before `IOS-A11` is filed as a bug, make me verify against SPEC §15 whether
>    TTS fallback is genuinely unwired in the live speak path (check the actual code, not the
>    review's claim). Same for `IOS-A2`/`UX-1`.
> 3. **Merge/split/sequence** — `SEC-1`+`SEC-2`, `SRV-A5`+`SEC-2`, `IOS-A2`+`UX-1`; and whether
>    `IOS-A1`, `UX-6`, `UX-13` are too big for one tracer-bullet slice and must be split.
> 4. **Dependency graph** — pin the "blocked by" edges the autonomous planner needs, and the
>    files that force serialization (everything touching `WalkthroughCoordinator.swift`).
> 5. **Product calls, not code** — force a decision on the implement-vs-amend-SPEC items
>    (`UX-13`, `UX-3`, `UX-5`, `UX-11`).
>
> As decisions land, keep a running edit list keyed to the `F` manifest (drop / split-into-N /
> retitle / re-track / add "Blocked by:") so I can apply them after. Don't file anything —
> filing happens in a later session per the plan's Resume procedure.
