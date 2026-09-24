# Voice Diary design system

Tokens, specs, and the toolchain that turns them into Swift + CSS for both consumers (iOS app + server HTMX UI). For the *applied* design rationale (palette, voice, do's and don'ts) see [`/DESIGN.md`](../../DESIGN.md) at the repo root — that's the file Claude Design reads.

## File map

| Path | Purpose | Editable? |
|---|---|---|
| [`/DESIGN.md`](../../DESIGN.md) | Brand spec consumed by Claude Design (Google Labs Code schema). YAML frontmatter mirrors the JSON token sources; prose covers rationale, voice, do's/don'ts. | ✓ when you change tokens or component variants |
| [`tokens/color/*.json`](./tokens/color) | Base palette + semantic mappings (light + dark). | ✓ — single source of truth |
| [`tokens/typography/font.json`](./tokens/typography/font.json) | Font families, weights, sizes, line heights, iOS HIG ramp. | ✓ |
| [`tokens/layout/{spacing,radius,motion,shadow}.json`](./tokens/layout) | Layout primitives. | ✓ |
| [`specs/components/*.json`](./specs/components) | Component contracts (Button so far). Stack-agnostic — implementers map to their target. | ✓ |
| [`config.js`](./config.js) + [`scripts/`](./scripts) | Style Dictionary build configuration. | ✓ rarely; run via `bash scripts/build_design_system.sh` |
| `build/`, `node_modules/` | Generated / installed. | ✗ (gitignored except where consumed) |
| [`CLAUDE_DESIGN_PROMPTS.md`](./CLAUDE_DESIGN_PROMPTS.md) | Ready-to-paste prompts for Claude Design / Claude Code, screen-by-screen. | ✓ — extend as new screens land |
| [`HANDOFF_GUIDE.md`](./HANDOFF_GUIDE.md) | How to integrate a Claude Design output bundle without breaking the pipeline. | ✓ rarely |

## Common tasks

**Add a colour, spacing value, radius, or font size:** edit the matching JSON in `tokens/`, run `bash scripts/build_design_system.sh` from the repo root, commit the regenerated outputs in both consumer trees, mirror the change in `/DESIGN.md`. Full walkthrough in [`HANDOFF_GUIDE.md`](./HANDOFF_GUIDE.md) Workflow B.

**Add a button variant:** edit `specs/components/button.json`, add the matching SwiftUI ButtonStyle in `ios/Sources/DesignSystem/DSButtonStyle.swift`, update `/DESIGN.md` Components. Workflow C.

**Redesign a screen with Claude Design:** copy the matching prompt from [`CLAUDE_DESIGN_PROMPTS.md`](./CLAUDE_DESIGN_PROMPTS.md), attach `/DESIGN.md` and the current screenshot, run, then follow [`HANDOFF_GUIDE.md`](./HANDOFF_GUIDE.md) for integration.

**Sanity-check that a feature isn't drifting:** grep for hex literals or raw spacing values in feature code:

```bash
# iOS
grep -rn "Color(red:\\|Color(\"#\\|.frame(width: [0-9]\\|.padding([0-9]" ios/Sources/UI

# Server
grep -rn "#[0-9A-Fa-f]\\{6\\}\\|: [0-9]*px\\|font-size: [0-9]" server/webapp/static
```

Anything that turns up should be replaced with a `Theme.*` / `var(--*)` reference.

## Build pipeline summary

```
tokens/*.json          ──┐
specs/components/*.json ─┤   bash scripts/build_design_system.sh
DESIGN.md (read-only) ───┘            │
                                      ▼
   ios/Sources/DesignSystem/{DSColor,DSMetrics,DSSemantic}.swift
   server/webapp/static/{tokens.css,tokens-semantic.css}
```

Both consumers ship the generated files in their build artefacts. Style Dictionary itself is not a runtime dependency.

## Why a separate `DESIGN.md` if we already have JSON tokens?

Different audiences:

- **JSON tokens** are consumed by Style Dictionary at build time. They are unambiguous, machine-readable, and lossy on intent ("this `#1570EF` is a *trust accent*, not a brand colour").
- **`DESIGN.md`** is consumed by Claude Design and by humans onboarding the design language. It carries the *why* — palette intent, copy voice, do's/don'ts, component usage rules — none of which fits cleanly in JSON.

Keep them paired: any token change means both the JSON and the matching `DESIGN.md` line move together.

## Anti-FAQ

> *"Can we just let Claude Design generate hex values directly into Swift?"*

No. The design system is the contract; if Claude Design hands you a hex that's not in the palette, decide whether to add it to `tokens/color/*.json` or push back on the design.

> *"Why both `Theme.spacing.md` and `var(--spacing-md)`? Can't we share?"*

Different runtimes (Swift vs. CSS), but the same source. Style Dictionary generates both from the JSON. The two access paths are deliberately parallel; you should never have to translate values between them.

> *"What if I just want to ship a quick visual fix?"*

If the fix uses existing tokens — go ahead, no token change needed. If it doesn't — pause, decide if a new token is justified, and if it is, run through the pipeline (Workflow B).
