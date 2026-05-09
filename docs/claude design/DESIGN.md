---
version: "alpha"
name: Voice Diary
description: "Quiet, structured reflection — a private notebook for the founder's hour after work."
colors:
  text-primary: "#171717"
  text-secondary: "#737373"
  text-subdued: "#9E9E9E"
  text-inverse: "#FFFFFF"
  text-link: "#1570EF"
  surface: "#F7F7F7"
  surface-hover: "#F0F0F0"
  surface-inset: "#F0F0F0"
  container: "#FFFFFF"
  container-hover: "#F7F7F7"
  container-inset: "#F7F7F7"
  border-primary: "#0B0B0B"
  border-secondary: "#363636"
  border-subdued: "#E7E7E7"
  status-success: "#10A861"
  status-warning: "#DC6803"
  status-destructive: "#EC2222"
  accent-record: "#EC2222"
  text-primary-dark: "#FFFFFF"
  text-secondary-dark: "#9E9E9E"
  surface-dark: "#0B0B0B"
  container-dark: "#171717"
  container-inset-dark: "#242424"
  border-subdued-dark: "rgba(255,255,255,0.10)"
typography:
  display:
    fontFamily: "Geist"
    fontSize: "2.25rem"
    fontWeight: 600
    lineHeight: 1.25
    letterSpacing: "-0.01em"
  title:
    fontFamily: "Geist"
    fontSize: "1.75rem"
    fontWeight: 600
    lineHeight: 1.25
  headline:
    fontFamily: "Geist"
    fontSize: "1.0625rem"
    fontWeight: 600
    lineHeight: 1.375
  body:
    fontFamily: "Geist"
    fontSize: "1.0625rem"
    fontWeight: 400
    lineHeight: 1.5
  callout:
    fontFamily: "Geist"
    fontSize: "1rem"
    fontWeight: 400
    lineHeight: 1.5
  subheadline:
    fontFamily: "Geist"
    fontSize: "0.9375rem"
    fontWeight: 500
    lineHeight: 1.4
  caption:
    fontFamily: "Geist"
    fontSize: "0.75rem"
    fontWeight: 500
    lineHeight: 1.375
    letterSpacing: "0.01em"
  mono-body:
    fontFamily: "Geist Mono"
    fontSize: "0.9375rem"
    fontWeight: 400
    lineHeight: 1.5
  mono-caption:
    fontFamily: "Geist Mono"
    fontSize: "0.75rem"
    fontWeight: 400
    lineHeight: 1.4
rounded:
  none: "0px"
  sm: "4px"
  md: "8px"
  lg: "10px"
  xl: "12px"
  2xl: "16px"
  pill: "9999px"
spacing:
  xxs: "4px"
  xs: "8px"
  sm: "12px"
  md: "16px"
  lg: "20px"
  xl: "24px"
  xxl: "32px"
  xxxl: "40px"
motion:
  fast: "150ms cubic-bezier(0.4, 0, 0.2, 1)"
  default: "300ms cubic-bezier(0.4, 0, 0.2, 1)"
  decelerate: "300ms cubic-bezier(0, 0, 0.2, 1)"
  spring-snappy: "response 0.30, dampingFraction 0.78"
  spring-soft: "response 0.45, dampingFraction 0.85"
components:
  button-primary:
    backgroundColor: "{colors.text-primary}"
    textColor: "{colors.text-inverse}"
    typography: "{typography.callout}"
    rounded: "{rounded.lg}"
    padding: "0px 20px"
    height: "48px"
  button-primary-hover:
    backgroundColor: "#363636"
  button-secondary:
    backgroundColor: "{colors.container}"
    textColor: "{colors.text-primary}"
    border: "1px solid {colors.border-secondary}"
    typography: "{typography.callout}"
    rounded: "{rounded.md}"
    padding: "0px 16px"
    height: "40px"
  button-ghost:
    backgroundColor: "transparent"
    textColor: "{colors.text-primary}"
    typography: "{typography.callout}"
    rounded: "{rounded.md}"
    padding: "0px 16px"
    height: "40px"
  button-destructive:
    backgroundColor: "{colors.status-destructive}"
    textColor: "{colors.text-inverse}"
    typography: "{typography.callout}"
    rounded: "{rounded.md}"
    padding: "0px 16px"
    height: "40px"
  card:
    backgroundColor: "{colors.container}"
    border: "1px solid {colors.border-subdued}"
    rounded: "{rounded.lg}"
    padding: "16px"
  card-inset:
    backgroundColor: "{colors.container-inset}"
    rounded: "{rounded.lg}"
    padding: "16px"
  badge:
    backgroundColor: "transparent"
    textColor: "{colors.text-secondary}"
    typography: "{typography.caption}"
    rounded: "{rounded.pill}"
    padding: "2px 8px"
  state-pill-recording:
    backgroundColor: "rgba(236, 34, 34, 0.10)"
    textColor: "{colors.status-destructive}"
    typography: "{typography.caption}"
    rounded: "{rounded.pill}"
    padding: "2px 12px"
  status-dot-recording:
    backgroundColor: "{colors.status-destructive}"
    width: "10px"
    height: "10px"
    rounded: "{rounded.pill}"
  status-dot-speaking:
    backgroundColor: "{colors.status-warning}"
    width: "10px"
    height: "10px"
    rounded: "{rounded.pill}"
  event-row:
    backgroundColor: "rgba(21, 112, 239, 0.06)"
    border: "1px solid rgba(21, 112, 239, 0.20)"
    rounded: "{rounded.md}"
    padding: "12px"
  event-row-time-column:
    width: "56px"
    alignment: "trailing"
    typography: "{typography.caption}"
    fontFeature: "tabular-nums"
  event-row-bar:
    width: "3px"
    rounded: "{rounded.sm}"
---

## Overview

Voice Diary is a single-person tool for an evening reflection ritual. The aesthetic is **calm-tech editorial**: high-contrast neutrals, no rainbow accents, no AI fingerprints (no teal gradients, no cyan glows, no animated bokeh). The phone surfaces should feel like a leather-bound notebook, not a chat app.

Core moods, in order of priority: **focused → quiet → trustworthy → human.** The user is recording sensitive personal reflections that touch on direct reports, customer health, and family. Anything decorative undermines that contract.

The system supports both light and dark mode equally — dark is not a "theme variant", it's the default during the evening session because the user is winding down.

## Colors

The palette is deliberately constrained. One ink, four neutrals, one trust accent, three status colors. No brand palette beyond this.

- **`text-primary` (#171717):** Ink for headlines, primary copy, primary-button fills. The single darkest non-black.
- **`text-secondary` (#737373):** Subtitle, metadata, longer-form descriptions.
- **`text-subdued` (#9E9E9E):** Captions, timestamps, "no events today" empty states. Never use for anything the user has to read precisely.
- **`text-link` / interactive accent (#1570EF):** A reserved blue. Used **only** for genuine interactive primitives (links, selected-row checkmarks, calendar event bars). Never as decoration.
- **`status-destructive` (#EC2222):** The single red. Used for the recording dot, the active-recording state pill, and destructive buttons. Seeing red anywhere should mean "the mic is open" or "you're about to lose work" — nothing else.
- **`status-success` / `status-warning`:** Reserved for ingest state and lull cues respectively. Do not use them as decoration.

The **calendar event bar** uses `text-link` (organizer), `status-success` (accepted), `status-warning` (tentative), `text-subdued` (default) — these are the only RSVP encoding.

## Typography

**Geist** for everything that's not code; **Geist Mono** for tokens, IDs, hashes, bearer summaries, monospace timers. Both are bundled in the iOS app via `UIAppFonts` and on the server via `@font-face` (SIL OFL 1.1).

The type scale follows iOS Human Interface Guidelines: `display → title → headline → body → callout → subheadline → caption`. Body is **17pt** (iOS body), not 16 — this app does a lot of read-aloud / read-along work and must be comfortable at arm's length.

Tabular figures (`fontFeature: "tnum"`) are mandatory for: timer displays, bearer length summaries, calendar time columns, duration labels.

Never go below 12px for any text the user might need to read. Captions at 12px are the floor; anything smaller is decoration only.

## Layout

Spacing is a 4-unit scale (xxs=4 → xxxl=40). Cards sit at 16px internal padding. Sections separate by 20px. The screen edge gutter is 16px on iOS.

Vertical rhythm beats horizontal density: when in doubt, add space, not a divider.

The walkthrough screen has a deliberate "one card per moment" structure — there should never be more than 2-3 concurrent affordances visible. Buttons are stacked vertically when there's room; horizontal pairs only for `secondary + ghost` (Skip / Finish).

## Elevation & Depth

There is no shadow elevation in feature surfaces. Cards are differentiated by **fill** (`container` on `surface`) and **stroke** (1px `border-subdued`). The only shadows live in modal overlays (sheet presentation), and those are managed by the platform — never hand-rolled.

This is deliberate: shadows in the wrong density read as "AI dashboard" and break the editorial feel.

## Shapes

Three radii used in 95% of cases:

- `md` (8px) — buttons, inline controls, secondary cards
- `lg` (10px) — primary cards, list rows
- `pill` (9999px) — status badges, the recording dot, the lock-screen button

Sharp corners (`none`) are reserved for full-bleed images. `2xl` (16px) is for the optional "hero" card on the start-of-session screen.

## Components

The component library is intentionally small. Five button variants × three sizes, two card flavours, one badge, one event-row pattern. Adding a new visual primitive requires updating `docs/design-system/specs/components/*.json` and rebuilding tokens — see `CLAUDE.md` Design system rules.

### Buttons (5 × 3 = 15 styles total)

| Variant | Use |
|---|---|
| `primary` | One per screen. The single highest-intent action ("Sitzung starten", "Weiter"). |
| `secondary` | Lower-intent action paired with primary, e.g. "Überspringen". |
| `outline` | Filter or selection toggle. |
| `ghost` | Tertiary / dismiss. "Abbrechen", "Ich bin fertig". |
| `destructive` | Reject / discard / cancel-with-loss. Used on the **No** button in todo confirmation. |

Sizes: `sm` (32px) for tab toolbars, `md` (40px) for forms, `lg` (48px) for primary CTAs.

### Cards

- `card` — white container on grey surface, 1px subdued stroke. Default container for content sections.
- `card-inset` — inset card, no stroke, used inside sheets and modals where there's already a container above.

### State pills

The recording-state pill is the only "always-visible-when-active" component. Red dot + "Aufnahme läuft" / "Recording" text. Never animated beyond the platform-native pulse.

### Event rows (calendar)

Three-column row: `time column (56px)` / `colour bar (3px)` / `details column`. Background is the bar colour at 6% opacity, stroke is the bar colour at 20%. This pattern is reused for the *Tagesübersicht*, the in-session event card, and (later) the review screen.

## Voice & Copy

**Voice principle:** the AI is the user's editor, not their therapist. Short, declarative, never effusive. German is primary; English mirrors the German voice, not American customer-success cheerfulness.

- ✓ "Heute hattest du 3 Termine. Los geht's mit dem ersten."
- ✗ "Bereit für deine wundervolle Reflexion? Lass uns gemeinsam tief eintauchen!"

- ✓ "Eine Sache noch: Stephan morgen anrufen — ja, nein, oder anders?"
- ✗ "Großartig! Möchtest du diese fantastische Aufgabe vielleicht behalten?"

Never use exclamation marks except in error toasts. Never use emojis in app copy. The diary is a tool, not a friend.

## Do's and Don'ts

**Do**

- Use `text-link` (#1570EF) sparingly — it should be rare enough that the user notices when it appears.
- Render time labels with tabular figures, every time.
- Stack buttons vertically by default. Pairs only for `secondary + ghost`.
- Treat dark mode as a first-class design target (it's the default in the evening session).
- Keep one primary action per screen.

**Don't**

- ~~Hard-code colours, spacing, radii, or font sizes in feature code.~~ Always go through `Theme.*` (Swift) or `var(--*)` (CSS).
- ~~Use teal, cyan, or animated gradients anywhere.~~ Those are AI-tool fingerprints and break the editorial mood.
- ~~Add custom button variants in feature code.~~ Extend `specs/components/button.json` and rebuild instead.
- ~~Pile shadow elevation into card surfaces.~~ Cards are flat — fill + stroke only.
- ~~Render the recording dot as anything other than `status-destructive`.~~ It's the user's "is the mic open?" signal — it has to be unambiguous.
- ~~Translate copy literally between DE/EN.~~ Mirror the *intent* and tone, not the words. The English voice is its own register.

## Implementation contract

This `DESIGN.md` is a **read-only spec** that pairs with the executable token sources in `docs/design-system/tokens/` (Style Dictionary). Claude Design and Claude Code read this file when generating new screens. Token edits go in the JSON sources, not this file — then `bash scripts/build_design_system.sh` regenerates `Theme.swift` (iOS) + `tokens.css` (server).

Hand-written extension points:

- **iOS:** `ios/Sources/DesignSystem/Theme.swift` (`Theme.color.*`, `Theme.spacing.*`, etc.) and `DSButtonStyle.swift`.
- **Server:** `server/webapp/static/style.css` (the alias layer above `tokens.css`).

Anything else (`DSColor.swift`, `DSMetrics.swift`, `DSSemantic.swift`, `tokens.css`, `tokens-semantic.css`) is generated and must not be edited by hand.
