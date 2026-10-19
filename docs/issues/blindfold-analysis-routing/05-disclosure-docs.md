# 05 · Disclose the first egress in the docs

Track: server
Type: AFK

## Parent

[Opt-in Blindfold Analysis Routing PRD](../../prd/blindfold-analysis-routing.md)

## What to build

Stop describing analysis as local-only and say plainly what the opt-in sends. Qualify the "local Ollama" and local-first claims in the README, SPEC (§1 and §3, the §10 narrative stage), DEVELOPMENT.md (server environment) and `server/README.md` (prerequisites, common failure modes with the three `blindfold_*` codes), and finish the `.env.example` block started in ticket 01. Add one limits section, linked from each place, listing what still leaves the machine or may: the transcript and journal content, dates (Blindfold's date shift is not wired), relationships, the local context summary, the author's name, role and company, and entities Blindfold does not detect (nicknames, unlisted companies). State that the default sends nothing, that the route is a restart-time setting, that there is no fallback, and that the route must not be enabled until the operator-run checks in ticket 07 pass, including Blindfold #69, #76 and #79 being deployed. Add the PRD to the SPEC's related references where the pipeline is described.

## Acceptance criteria

- [ ] No remaining sentence in the README, SPEC, DEVELOPMENT.md, `server/README.md` or `.env.example` says analysis is local-only without the qualification (checked by a search for the local claims and read against the PRD).
- [ ] The limits section lists every item above and says entity pseudonymization is not content-level privacy.
- [ ] The five settings, their defaults, and which are required when routed are documented once and consistent with the PRD's settings table.
- [ ] The gate on the first enable (ticket 07) and the ADR 0001 / 0004 references are stated.
- [ ] Docs only; no code, test or config change beyond `.env.example` comments.

## Blocked by

- [02 · Blindfold failure codes](./02-blindfold-failure-codes.md)
- [03 · `/health` Blindfold entry](./03-health-blindfold-entry.md)
- [04 · Record `analysis_route`](./04-record-analysis-route.md)
