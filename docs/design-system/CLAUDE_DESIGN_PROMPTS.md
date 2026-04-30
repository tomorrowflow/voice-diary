# Voice Diary — Claude Design + Claude Code prompt library

This file contains tested prompts for working with [Claude Design](https://claude.com/design) and Claude Code on Voice Diary's UI. Copy a prompt, paste into the relevant tool, adapt the *Context-this-iteration* block, and ship.

The system prompt baseline is always the repo's `DESIGN.md` and `CLAUDE.md`. Both files are loaded automatically when you run Claude Code in the repo root; for Claude Design, paste the relevant section as a system message at the start of the conversation.

---

## How to use this file

1. **Skim the gap inventory** at the bottom — the open visual problems are listed. Pick one.
2. **Copy the matching prompt template** (e.g. *Walkthrough redesign*).
3. **Fill the `Context-this-iteration` block** with the specific screenshot/file/symptom you're addressing.
4. **Run.** For Claude Design, attach the screenshot too.
5. **Take the output bundle** and follow `HANDOFF_GUIDE.md` to integrate without breaking the Style Dictionary pipeline.

---

## Universal preface (paste once at the top of any new Claude Design session)

```
You are designing a screen for Voice Diary, a single-user iOS 26 app for an
evening voice-reflection ritual. The user is a CTO who records sensitive
personal reflections on his day; the aesthetic is calm-tech editorial — no
AI fingerprints (no teal, no cyan, no glow, no decorative gradients).

Hard rules:

1. Use ONLY tokens from DESIGN.md (attached). Never invent new colors,
   spacing values, radii, or font sizes.
2. text-link (#1570EF) is reserved for genuine interactive primitives.
   Don't use it for decoration.
3. status-destructive (#EC2222) means "the mic is open" or "you're about
   to lose work" — nowhere else.
4. Geist for prose, Geist Mono for IDs/timers. Tabular figures on every
   numeric column.
5. Cards are flat: fill + 1px subdued stroke. No shadows in feature
   surfaces.
6. One primary action per screen, stacked vertically by default.
7. Voice principle: editor, not therapist. Short declarative German;
   English mirrors the same register, not American cheerfulness.
8. Dark mode is a first-class target (default during the evening session).

The output should be a single screen mocked at 393 × 852 (iPhone 17 Pro)
in BOTH light and dark mode. When you hand off, name the tokens you used
exactly as they appear in DESIGN.md so the implementation can use Theme.*
without translation.
```

---

## Prompt 1 — Walkthrough redesign (the *Abend* tab in flow)

Use when: the live walkthrough screen feels cluttered, button hierarchy is unclear, or the timer is fighting with the AI's spoken line.

```
Redesign the in-session walkthrough screen for Voice Diary's *Abend* tab.

Current behaviour (from SPEC.md §6.2):
  - The screen represents one event being walked through.
  - Top: state header (Aufnahme/Speaking/Listening) with status dot.
  - Middle: card showing the current event (title, time, attendees).
  - Below: the AI's most recently spoken line (italic-ish, calm).
  - Live recording timer (mm:ss) in tabular Geist Mono.
  - Listening hint text when the 15s lull threshold fires.
  - Bottom: primary "Weiter" + secondary "Überspringen" + ghost "Ich bin fertig".
  - An "Frage stellen" enrichment trigger (ghost button) above the controls.

Design constraints:
  - One primary action per screen. "Weiter" is it.
  - The recording dot must be unambiguous — status-destructive at 10×10px
    is the floor.
  - Tabular timer never reflows.
  - Spoken-line card uses card-inset (no stroke), text-secondary color.
  - Don't introduce a progress bar, percentage, or "step 2 of 5" header
    inside the walkthrough — it makes the user feel rushed. Use the
    EventCard "Termin 2 / 5" caption only.

Context-this-iteration:
  [paste a screenshot of the current state OR describe the symptom in
  one sentence — e.g. "the spoken-line card and timer feel like they're
  competing for attention"]

Output:
  - Light + dark mocks at 393×852.
  - Token list: name every Theme.color / Theme.spacing / Theme.radius /
    Theme.font you used.
  - One short note on what changed and why.
```

---

## Prompt 2 — Day overview (the *Abend* start screen with date picker)

Use when: the chronological list of events for the chosen day looks dense, the all-day section is fighting the timed list, or the date picker placement feels off.

```
Design the start-of-session screen for Voice Diary's *Abend* tab.

Composition:
  - Title "Bereit für die Abend-Reflexion?" + helper copy.
  - Date picker (compact, max=today) — drives manifest.date for catch-up
    sessions on missed days.
  - DayOverview: a chronological list of timed events for the selected
    day (RSVP-keyed colour bar, time column, attendee count) + a separate
    "Ganztägig" header for all-day events.
  - Primary "Sitzung starten (N Termine)" CTA at the bottom.

Constraints:
  - The date picker is a quiet utility, not the hero — it should sit
    above the day overview, not steal attention.
  - All-day events are visually demoted (no time column, sun.horizon
    icon, container-inset background).
  - Empty states ("Keine zugesagten Termine.") use text-subdued + a
    relevant SF Symbol — never an illustration.
  - The CTA caption changes with the event count: "Sitzung starten",
    "Sitzung starten (1 Termin)", "Sitzung starten (3 Termine)".

Context-this-iteration:
  [paste screenshot OR describe symptom]

Output:
  - Three states in light mode + dark: "no events", "1 all-day + 3 timed",
    "5 timed back-to-back".
  - Token map.
```

---

## Prompt 3 — Implicit-todo confirmation card (CLOSING flow, M8 phase B-2)

Use when: the new TodoConfirmationCard feels off — the candidate text doesn't read clearly, the listening cue competes with the buttons, or the refine editor looks like an afterthought.

```
Design the implicit-todo confirmation card for Voice Diary's CLOSING flow.

Behaviour:
  - After the user finishes the free-reflection segment, Apple Foundation
    Models has surfaced 0..N implicit todos.
  - For each, the AI speaks: "Eine Sache noch: '[task]' — ja, nein, oder
    anders?" then opens the mic for ~7s.
  - The card shows: "Aufgabe N / M" caption, the candidate text in
    title3, optional "höre dich" red-dot cue while the mic is open,
    three buttons: primary Ja → secondary Nein → ghost Anders.
  - "Anders" reveals an inline TextField with the candidate pre-filled,
    plus "Abbrechen" / "Übernehmen" controls.

Constraints:
  - The candidate text is the centerpiece. It should read like a single
    line of a notebook, not like an alert dialog.
  - The listening cue is small, low-contrast (text-subdued + 8×8 red
    dot). Easy to ignore if the user prefers buttons.
  - "Nein" is destructive in *intent* but not in *visual weight* — it
    uses the secondary variant, not destructive. (Destructive is reserved
    for "you're about to lose work".)
  - The refine editor expands inline; never a sheet.

Context-this-iteration:
  [paste screenshot of current TodoConfirmationCard]

Output:
  - Three states: idle (just landed), listening (mic open), refining
    (text field expanded). Light + dark.
  - Token map.
```

---

## Prompt 4 — Voice picker (Settings → Stimmen)

Use when: the per-language voice picker added in M8.5 needs polish — quality badges feel mis-weighted, the preview button is hard to discover, or the empty state ("no voices installed") doesn't link the user to the iOS Settings deep-link clearly.

```
Design the voice-picker screen for Voice Diary's Settings tab.

Composition:
  - Two sections: "Deutsch" and "English".
  - Each section: an "Automatisch" row (radio + helper "Beste verfügbare
    Premium-Stimme") plus a row per installed AVSpeechSynthesisVoice.
  - Each voice row: radio circle, voice name, quality badge
    (Premium / Enhanced / Standard), language locale (e.g. "de-DE") in
    Geist Mono caption, play-button preview on the right.
  - When no voices are installed for a language: a helper line linking
    out to "iOS-Einstellungen → Bedienungshilfen → Gesprochene Inhalte
    → Stimmen".
  - Footer note explaining Premium voices need a one-time download.

Constraints:
  - The Premium badge uses text-link bg @ 10% + text-link foreground.
    Enhanced uses status-success. Standard uses container-inset + subdued
    text. This is the ONLY exception to "no extra colour" — the user
    needs to glance and know which is the high-quality voice.
  - The preview button is a 24px circle play.fill in text-link, not a
    text button. It must coexist with the radio without crowding.
  - The radio uses checkmark.circle.fill (selected) / circle (unselected).
  - Selecting a row commits immediately — no "Save" button. Toast feedback
    is unnecessary; the next walkthrough utterance proves it worked.

Context-this-iteration:
  [paste screenshot]

Output:
  - 2 states (rich list, sparse list) × light + dark.
  - Token map.
```

---

## Prompt 5 — Done / completed-session card

Use when: the success state after upload feels anticlimactic, or the session-id stamp is too prominent.

```
Design the post-session "fertig" state for Voice Diary's *Abend* tab.

Composition:
  - A success indicator (checkmark.circle.fill in status-success at
    36-48pt).
  - "Sitzung abgeschlossen" headline.
  - Session ID in Geist Mono caption (text-subdued).
  - Optional: a one-line summary "N Termine, M Aufgaben übernommen" if
    the data is available from the coordinator.
  - "Neue Sitzung" secondary button.

Constraints:
  - The check is celebratory but quiet — no animation beyond a brief
    spring on appearance, no confetti, no copy in the imperative
    ("Großartig!", "Geschafft!").
  - The session-id stamp is for debugging. It should NEVER feel like the
    most important thing on the screen. text-subdued, mono-caption,
    centred.
  - One CTA. "Neue Sitzung" is secondary because the user just finished
    — they don't need to be pushed into another session. The primary
    action of this screen is "let the user breathe".

Context-this-iteration:
  [paste screenshot]

Output:
  - Done card with summary line / done card without summary line. Light
    + dark.
  - Token map.
```

---

## Prompt 6 — Drive-by capture surface (the *Aufnahme* tab)

Use when: the always-on capture surface (lock-screen widget host, mic open / closed states) is visually unclear or the timer placement is wrong.

```
Design Voice Diary's *Aufnahme* tab — the drive-by capture surface.

Behaviour:
  - The user can tap a button, hit the Action Button physical key, or
    use the lock-screen widget to start an ad-hoc 30-90s capture.
  - "hey voice diary" wake-word splits the capture into a regular
    drive-by + an enrichment branch (server round-trip, summary spoken
    back).
  - Recording / idle are the two main states.
  - The visible timer counts UP from 00:00.
  - On stop, the capture is staged and uploaded asynchronously.

Composition:
  - Idle: a single tap target — large pill button "Aufnahme starten",
    plus a one-line helper explaining the Action Button shortcut.
  - Recording: a status-destructive recording dot + state pill, the
    upward-counting timer in Geist Mono 36pt, a primary "Stopp" CTA,
    a hint "Sage \"hey voice diary\" für Frage" in text-subdued.

Constraints:
  - This is the only screen where the recording state can dominate.
    Use a centred composition, not a list.
  - The "Aufnahme starten" button is large (lg, full-width) but doesn't
    look like an alarm. Status-destructive only when the mic is open;
    text-primary when idle.

Context-this-iteration:
  [paste screenshot]

Output:
  - Idle + recording, light + dark.
  - Token map.
```

---

## Prompt 7 — Onboarding (M11 — not yet implemented)

Use when: planning M11. Paste this when starting the onboarding sequence design.

```
Design Voice Diary's first-launch onboarding (3 screens, no skip).

Screens:
  1. **Tailscale connection.** Helper copy explaining the user must be on
     their tailnet. A "Server prüfen" primary action that pings /health.
     Status state below: ok (success) / down (destructive) / degraded
     (warning, list which upstream is unhappy).
  2. **Bearer token paste.** SecureField for the bearer, the matching
     server URL is shown above (read-only, from step 1). Primary
     "Speichern" + a secondary "Im Wiki nachschlagen" that opens a
     /docs/onboarding.md anchor.
  3. **Voice preview.** Plays a one-line German + English sample with
     the auto-selected voice and offers a "Stimmen anpassen" link to the
     full voice picker.

Constraints:
  - No images, no illustrations, no welcome animations.
  - The user can't proceed past step 1 if reachability is .down or
    .authInvalid — the primary action stays disabled.
  - One primary CTA per screen, stacked vertically. Helper copy is
    text-secondary at callout size.
  - This is a 90-second flow. It should feel like setting up a wifi
    printer, not "starting your journey".

Context-this-iteration:
  None yet — this is greenfield. Use SPEC.md §14 for behavioural detail.

Output:
  - 3 screens × light + dark.
  - Token map.
```

---

## Prompt 8 — Server review UI (HTMX entity correction)

Use when: the existing review templates in `server/webapp/templates/` need to align with the same design language as the iOS app.

```
Redesign the entity-review HTMX screen at /review/sessions/{id}.

The page exists already at server/webapp/templates/review/session.html. It
shows a transcript with detected entities highlighted; the user clicks
each entity to confirm / correct / skip. HTMX swaps the highlight in place
when the user picks a person from the dictionary.

Constraints:
  - Use ONLY var(--*) variables from server/webapp/static/tokens.css. The
    palette is the same as DESIGN.md — DON'T introduce a separate "web
    palette".
  - Geist Sans for prose, Geist Mono for entity strings.
  - Detected entities highlight in a soft container-inset background
    with a 1px text-link stroke; confirmed entities switch to
    status-success at 10% opacity. Rejected entities lose all styling.
  - Keep the page single-column, max-width 720px. This is a reading task,
    not a dashboard.
  - Sticky bottom bar with "Fertig" primary + "Verwerfen" ghost — never
    inline at the bottom of a long transcript.

Context-this-iteration:
  [paste screenshot of /review/sessions/{id}]

Output:
  - Two states: in-progress (some entities confirmed, some pending),
    completed.
  - Light + dark (server uses prefers-color-scheme).
  - Map every var(--*) you use.
```

---

## Gap inventory — current open visual problems

Snapshot of what feels off as of the last dogfood pass. Re-prioritise; don't try to do all at once.

| # | Surface | Symptom | Suggested prompt |
|---|---|---|---|
| 1 | Walkthrough during a long event | Spoken-line card and timer compete; "Frage stellen" feels orphaned | Prompt 1 |
| 2 | Day overview when 5+ back-to-back meetings | All-day section pushes the timed list below the fold | Prompt 2 |
| 3 | TodoConfirmationCard | Listening hint wraps awkwardly on long candidate text | Prompt 3 |
| 4 | VoiceSettingsView preview button | Hard to spot; users default to selecting a voice without previewing | Prompt 4 |
| 5 | DoneCard | Session ID feels like the most important thing on screen | Prompt 5 |
| 6 | CaptureView (Aufnahme tab) | The "talk to me" intent isn't clear before the user has read the docs | Prompt 6 |
| 7 | Onboarding — not yet implemented | M11 placeholder | Prompt 7 |
| 8 | Server review templates | Drift from iOS look-and-feel; old grey palette | Prompt 8 |

---

## Tips for working with Claude Design specifically

- **Always attach `DESIGN.md` as the first message** of a Claude Design conversation. The model uses it as the live token reference.
- **Ask for token names, not hex values** in the output. "I used `text-link` and `spacing.md`" is portable; "#1570EF and 16px" is not.
- **Iterate small.** One screen, one state, one mode at a time. Claude Design is best at "tweak this" not "design from scratch given a 200-line spec".
- **For dark mode**, ask explicitly. Claude Design defaults to light unless prompted.
- **Reject AI fingerprints fast.** If the output has teal, cyan, gradient text, or animated bokeh — reject and re-prompt with "no decorative gradients, no teal, refer to DESIGN.md Don'ts".

## Tips for handing off to Claude Code

- Once Claude Design produces a bundle, follow `HANDOFF_GUIDE.md`. Do **not** paste raw hex values into Swift. Always run them back through `Theme.color.*`.
- The hand-written extension points are `Theme.swift` (iOS) and `style.css` (server). Generated files (`DSColor.swift`, `DSMetrics.swift`, `tokens.css`) are off-limits — token edits go in `docs/design-system/tokens/*.json`.
