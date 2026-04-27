# Design System — VoiceType

> **Compass.** A tool for people who just build things, with the polish of
> commercial software. Builder DNA outside, commercial polish inside. Every
> decision in this document serves that one thing.

> **Always read this file before making any visual or UI decision.** Tokens, colors,
> typography, spacing, and aesthetic direction are defined here. Do not deviate
> without explicit user approval. Record every change in the Decisions Log at the
> bottom of this file with date + rationale.

---

## Product Context

- **What this is:** Open-source local voice-to-text macOS menu bar app. Records
  with a global shortcut, transcribes locally via whisper.cpp + CoreML on Apple
  Silicon, inserts the resulting text into the active app. 100% local, no cloud,
  free, MIT.
- **Who it's for:** Bilingual RU+EN developers who dictate every day into Claude
  Code, Slack, Notes, browser. Primary user is the author, dogfooded daily.
- **Space/industry:** Productivity tooling, dictation. Direct neighbors:
  MacWhisper (paid, closed), Wispr Flow (cloud), Superwhisper (paid). Aesthetic
  reference neighborhood: Linear, Raycast, Cursor (NOT clones).
- **Project type:** Native macOS desktop app (menu bar). SwiftUI on macOS 13+.
  NSWindow + SwiftUI hybrid. Both light and dark mode required.

---

## Aesthetic Direction

- **Direction:** Machined desktop instrument. Smoked graphite surfaces, razor-clean
  typography, one electric cyan signal language that wakes up under input. Looks
  like an instrument left on a workbench — purposeful, slightly worn-in, zero
  decoration that doesn't earn its presence.
- **Decoration level:** intentional. No decorative blobs, no glassmorphism cliche,
  no centered everything. Replace radial blobs with directional edge light: a
  faint cyan highlight from top-left, never a floating glow cloud.
- **Mood:** Quiet competence. Reaction in the first 3 seconds: "whoever built this
  also uses it." Not "this is beautiful" (consumer-app reaction), not "this is
  minimal" (design-student reaction). The user feels they could fork the repo
  and ship a fix tonight.
- **Reference sites:** Linear (linear.app), Raycast (raycast.com), Cursor.
  Conscious counter-references (what we're NOT): Wispr Flow (warm/emotional
  marketing), Superwhisper (AI-SaaS slop pattern), MacWhisper (Apple-default).

---

## Typography

One family, two cuts. No serif, no character font. Geist is MIT-licensed (Vercel),
ships with builder-adjacent recognition, and renders Cyrillic clean enough for
settings labels and status text. Geist Mono is the operational font: timers,
hotkeys, model IDs, anything that should read as a tool readout.

- **Display / window title:** Geist — `23/28`, Medium
- **Section title:** Geist — `15/20`, Medium
- **Body:** Geist — `13/18`, Regular
- **Button label:** Geist — `12/16`, Medium (`Typography.buttonLabel`)
- **Meta labels (uppercase, tracked):** Geist — `11/14`, Medium, letter-spacing `0.04em`, uppercase
- **Mono / timer / hotkey / model ID:** Geist Mono — `12/16`, Medium, with `font-feature-settings: 'tnum', 'zero'`
- **Loading:** Google Fonts initially. For offline build, vendor the variable woff2 files into `Resources/Fonts/` and register via `Bundle.main.url(forResource:withExtension:)`. SwiftUI `Font.custom("Geist", size: ...)` after registration.
- **Cyrillic fallback:** if Geist Cyrillic glyph coverage proves weak (test-verified `запушил коммит` rendering during preview on 2026-04-24 passed), fall back to `.system(.body, design: .default)` only for Cyrillic strings via SwiftUI's font fallback chain. Do NOT switch the entire UI to system font — that defeats the typographic identity.

### Numerals

All numbers (timer, sizes, durations, percentages) use Geist Mono with tabular figures via `.monospacedDigit()` or `font-feature-settings: 'tnum'`.

---

## Color

**Approach:** restrained. Single accent (electric cyan) carries interactivity, focus, active state, and links across the app. The recording capsule operates in its own world with one signature exception (red tally light).

### Dark mode (primary)

```
bg / app           #0B1015
bg / window        #10171F
surface / inset    #0E141B
stroke / subtle    rgba(255,255,255,0.08)   default borders
stroke / strong    rgba(143,207,255,0.20)   active section 2px left-edge accent + focused control outlines
divider            rgba(255,255,255,0.06)   row dividers in native row layout
text / primary     #EEF3F7
text / secondary   #C7D2DC                  subtitles under row labels, body copy
text / muted       #7F90A1                  meta-labels ONLY (uppercase tracked 11/14)
accent             #59C7FF                  electric cyan, used sparingly
accent / strong    #1AA7F6                  capsule border full-recording + accent-hover
accent / soft      rgba(89,199,255,0.12)
focus-ring         rgba(89,199,255,0.40)
success            #27B7A4
warning            #E8A93A
error              #FF7A6B
```

### Light mode

```
bg / app           #F3F6F8
bg / window        #FBFCFD
surface / inset    #E2E9EE
stroke / subtle    rgba(14,23,32,0.08)
stroke / strong    rgba(21,159,225,0.20)
divider            rgba(14,23,32,0.06)
text / primary     #0E1720
text / secondary   #314253
text / muted       #6E7F90
accent             #099DDF
accent / strong    #007FC0
accent / soft      rgba(9,157,223,0.10)
focus-ring         rgba(9,157,223,0.40)
success            #1FB9A7
warning            #D5972A
error              #D95C4F
```

### Capsule — its own world (both modes identical)

Opaque dark surface darker than any window background. Universal across themes.

```
capsule / bg              #0D0D0C
capsule / text            #F0EDE8
capsule / timer           #9E9A94
capsule / recording       #E8423A            RED — tally-light reference
capsule / recording-glow  rgba(232,66,58,0.35)
capsule / border-idle     rgba(255,255,255,0.07)
capsule / border-rec      rgba(232,66,58,0.40)
capsule / border-err      rgba(255,122,107,0.50)
```

**Why red (locked):** unclaimed in category; MacWhisper uses green, Wispr uses cyan/blue. Red is the camera tally / studio mic / "recording now" universal signal.

**Why opaque (locked):** glassmorphism borrows from Control Center and dilutes identity. Signature object should be confident. Window surfaces use tinted opaque colors; never broad frosted glass.

---

## Spacing

Base unit: **4px**.

```
xs    4px
sm    8px
md   12px
lg   16px
xl   24px
2xl  32px
3xl  48px
4xl  64px
```

- Window padding: `xl` (24px)
- Prefs-row horizontal padding: `lg` (16px); vertical: `md` (12px); min-height 40px
- Section gap between prefs-groups: `2xl` (32px)
- Button padding: `7px 14px` — locked off-scale exception (`Tokens.ButtonPadding`). Battle-tested rhythm at 12/16 label size.
- Capsule horizontal padding: `14px`

`2xs 2px` removed — no component needed it.

---

## Layout

- **Approach:** native macOS convention for Settings and About windows — no boxed cards. Grouped rows separated by `1px` dividers, uppercase meta-label as group header. Cards only when the card IS the interaction (model-download row with progress, error toast, first-launch checklist).
- **Window dimensions:** Settings `620 × 520`. About `460 × 560`. Capsule `300 × 44`. Centralized in `Tokens.WindowSize` and `Tokens.CapsuleSize`.
- **Border radius scale:**
  - Capsule → `14` (`Tokens.Radius.capsule`)
  - Buttons, pickers, inputs → `8`
  - Window surfaces → `12`
  - Chips / badges → full pill
  - App artwork → `28%` of size (`Tokens.Radius.artworkPercent`)

### Settings layout — native rows, content-first (Departure 2, corrected 2026-04-24)

Tab order: **General → Models → Shortcuts → Advanced**. Default: **General**.
Sidebar left (`160px`), content right. No app artwork, no hero header, no subtitle.

**Row layout** (replaces boxed cards after Codex hard rejection 2026-04-24):
- Group header: uppercase meta-label (11/14 Medium letter-spacing 0.08em muted), `8px` below → `1px divider` → rows
- Rows: left `prefs-row-label` (body 13/18 primary, optional subtitle 11/14 **secondary**), right `prefs-row-control` (segmented / select / switch / button / mono readout)
- Rows separated by `1px divider` lines, not box borders
- Active section: `2px` left-edge accent using `stroke/strong`, only when actively edited

**Tab 1 — General:** LANGUAGE (segmented RU/RU+EN/EN/AUTO, default RU+EN) · INSERTION (Insert toggle, Trim whitespace, Paste method) · MICROPHONE (device select + inline permission hint row).

**Tab 2 — Models:** MODEL (row per model with size, speed rating, quality rating, recommended-for subtitle; download states per row) · CORE ML (CoreML encoder toggle, download CoreML variants).

**Tab 3 — Shortcuts:** RECORDING (current hotkey chip + "Record new" button) · inline accessibility permission hint row.

**Tab 4 — Advanced:** CUSTOM VOCABULARY (hotwords textarea) · TRANSCRIPTION HISTORY (Open history button + count readout) · DIAGNOSTICS (Open error log row · Build info).

Permissions live **inline** where they're needed (microphone in General, accessibility in Shortcuts), not as a dedicated Permissions tab.

### About layout — the only place the app artwork lives

- Dimensions: `460 × 560`
- Artwork left, `64px`
- Title + version string right of artwork, left-aligned
- First paragraph: bilingual RU+EN positioning
- Below intro: three native row-groups in order:
  1. **BUILD** — Version · macOS version
  2. **CURRENT SETUP** — Model · Language · Hotkey
  3. **PRIVACY** — "Your voice never leaves this Mac" + subtitle (no network during recording)
- No tabs, no buttons beyond Close

### MenuBar dropdown layout

`280px` wide, radius `10`:
- **Status line** (top, `1px divider` below):
  - Left: tally dot (gray idle / red recording / red on blocker)
  - Right: two-line readout — title + Geist Mono sub-line (model + language, or `N SETUP STEPS REMAINING`)
- **Not Ready:** header `N SETUP STEPS REMAINING` (red sub-line) + task-rows ("→ Grant microphone access", "→ Grant accessibility access", "→ Download model")
- **Idle:** Start recording (⌥ SPACE) · Open Settings… (⌘ ,) · About · divider · Quit (⌘ Q)
- **Recording:** Status shows "Recording · 0:14"

### Recording capsule — three zones

```
┌─────────────────────────────────────────────┐
│  ●  REC  RU/EN     ▮▮▮▮▮▮     0:14          │  300 × 44, radius 14
└─────────────────────────────────────────────┘
   left zone             center        right
   - tally dot           - waveform    - timer
   - REC label (during recording only — a11y)
   - RU/EN chip (display only)
```

- **Width:** `300px`. **Height:** `44px`. **Padding:** `14px` horizontal.
- **Background:** `capsule/bg` `#0D0D0C` at `100%` opacity, no material blur.
- **Border:** `1px` idle/rec/err per state.
- **Shadow:** `0 2px 8px rgba(0,0,0,0.5), 0 0 16px capsule/recording-glow`.
- **Position (v1.0):** top-center of screen containing focused window at hotkey press, `80px` from screen top. Fallback: `NSScreen.main`. Multi-screen preferences + mid-recording screen change deferred to v1.2.
- **RU/EN chip:** display only in v1.1. Not clickable. Change language via Settings.

---

## Interaction States

### Capsule

| State | Trigger | What the user sees | Duration |
|-------|---------|--------------------|----------|
| idle | no active recording | tally gray, RU/EN chip, flat waveform, timer 0:00, dismissed | — |
| recording | hotkey pressed, voice active | tally RED, **"REC" text label** left zone (Geist Mono 10/14 600 letter-spacing 0.08em), RU/EN chip, waveform bars audio-driven, timer counting, red border 40% + glow | until hotkey release |
| transcribing | hotkey released, whisper processing | tally gray, RU/EN chip, 3-dot breathing center (ease-in-out), timer frozen, border returns to idle | 1-8 seconds |
| inserted | text inserted into previous app | tally green check ✓ 14×14, RU/EN chip, center: "Inserted · N chars → AppName" (11/14 Medium) | 400ms flash then dismiss |
| error (inline) | solvable error (mic denied, accessibility denied, model not loaded, download failed) | tally light-red, RU/EN chip, center: short error text `"Mic denied · Open Privacy"`, red-pink border | 4s auto-dismiss, click to fix |
| error (toast) | unsolvable error (whisper crashed, OOM) | capsule dismisses first; toast at same position: 320px, dark-red bg `#2A1A1A`, 12px padding, icon + title + body + "View log" link | 6s auto-dismiss |
| empty-result | whisper returned "" | tally gray, RU/EN chip, center: "Nothing heard" | 400ms flash then dismiss |

**Transcribing state is NEW** — fills the gap between hotkey release and text insertion.

### Settings — permission row states (microphone, accessibility)

- **Granted:** green dot · "Granted" label · ghost "Open Privacy" button
- **Denied:** red dot · primary-danger "Grant Access" button (opens System Settings)
- **Not yet requested:** gray dot · "Grant once and you're set" subtitle · primary accent "Request" button

### Settings — model download row states

- **Not downloaded:** model name + size subtitle · primary "Download" button
- **Downloading:** model name + "Downloading · N MB / M MB" · inline progress bar + percent (Geist Mono tabular)
- **Failed:** red dot · error reason inline · ghost-danger "Retry" button
- **Downloaded:** green check · size on disk + "CoreML compiled" subtitle · ghost "Delete" button

### First launch

Blockers (must-do before VoiceType works):
1. microphone permission
2. accessibility permission (required for synthesized ⌘V; insertion fails silently without it)
3. at least one downloaded model

Nice-to-have:
4. custom hotkey (default ⌥ SPACE works out of the box)

**Surface:** checklist window, 480px wide, titlebar-less modal on first launch. Title: "Four steps and you're typing with your voice". Rows = numbered badge (Geist Mono 10/14 600 cyan-soft bg) + step-title + step-subtitle + action link. When all four green, window auto-closes. Reopenable via menubar → "Run setup checklist".

**Menubar mirror (safety net):** while ANY blocker is unresolved, menubar tally stays red and dropdown shows `N SETUP STEPS REMAINING` with inline task rows. If user closes the checklist early, the menubar keeps the status visible.

### Reduced motion

When `@Environment(\.accessibilityReduceMotion)` is true:
- Capsule appear: `opacity 0 → 1` only (no scale), `Motion.short` (200ms).
- Capsule dismiss: `opacity 1 → 0` only.
- Recording tally: static red dot, no pulse, no audio-driven animation.
- Inserted-state flash: 200ms opacity-only (shortened from 400ms).

### Focus state

`focus-ring` applied as `2px outline, 2px offset` on all interactive elements:
- Segmented control (focused segment)
- Select, button, switch, hotkey-chip
- Model-row (entire row focusable)

Respects macOS Full Keyboard Access.

---

## Accessibility

### Contrast (WCAG AA)

- `text/muted #7F90A1` on `bg/window #10171F` = 4.1:1 — **fails AA for body text**. Restricted to uppercase tracked meta-labels (11/14, which pass large-text AA).
- Subtitles under prefs-row labels use `text/secondary #C7D2DC` (11.5:1 AAA pass).
- `text/primary` on every background: AAA.
- Light mode: all pairings pass AA without restriction.

### VoiceOver announcements

Capsule is a floating NSWindow — invisible to screen readers without explicit posts. On state transitions, post `NSAccessibilityNotificationAnnouncement`:

- **appear:** "VoiceType recording. Speak now."
- **transcribing:** "Transcribing."
- **inserted:** "Inserted {N} characters into {appName}."
- **empty-result:** "Nothing heard."
- **error (inline):** "{error text}. {action hint}."
- **error (toast):** toast title + toast body

All Settings controls accessibility-labeled:
- Segmented language: `.accessibilityLabel("Preferred language")`, `.accessibilityValue("{RU | RU+EN | EN | AUTO}")`
- Model rows: `.accessibilityLabel("{modelName}")`, `.accessibilityValue("{state, size}")`
- Permission rows: describe current state + available action

### Colorblind — secondary signal for recording

Red tally alone loses contrast under protanopia (~8% of males). Secondary signal: **"REC" text label** in left zone during recording (Geist Mono 10/14 600 letter-spacing 0.08em, recording red). Triple-encoding: color + motion (waveform) + text.

### Full keyboard access

All custom SwiftUI controls respond to keyboard selection in Full Keyboard Access mode (⌘F7). Custom views (segmented, model row list) use `.focusable(true)` + focus-ring visual.

### Tab order

Settings window:
- Sidebar: General (default) → Models → Shortcuts → Advanced, arrow-key navigable
- Main content: top-to-bottom, left-to-right within each prefs-row
- Escape / ⌘W closes window

---

## Motion

**Approach:** minimal-functional. Movement carries information; it never decorates.

**Motion tokens (named, locked):**
- `Motion.micro` = `100ms` — hover feedback, color transitions
- `Motion.short` = `200ms` — capsule appear/dismiss, tab switching
- `Motion.medium` = `300ms` — picker opening, segmented transitions
- `Motion.long` = `500ms` — rare, cross-surface transitions only

**Behavior:**
- Easing: enter `ease-out`, exit `ease-in`, move `ease-in-out`
- Capsule appear: `scale 0.95 → 1.0` + `opacity 0 → 1`, `Motion.short` ease-out
- Capsule disappear: `scale 1.0 → 0.96` + `opacity 1 → 0`, `Motion.short` ease-in
- Recording dot pulse: ONE `scale 1.0 → 1.4 → 1.0` over `Motion.short` when audio crosses `Tokens.Motion.waveformActivationThreshold = 0.15`. No continuous breathing.
- Border during active recording: static at `red 40%`. No sweep.
- Inserted-state flash: `400ms` green-to-teal + "Inserted · N chars → AppName", then dismiss.
- Transcribing-state dots: 3 dots, ease-in-out scale, `Motion.long` per cycle.
- Tab switching, picker opening: native macOS (`Motion.short`).
- Reduced motion: opacity-only, no scale, no pulse.

---

## Iconography

- **App icon (`VoiceTypeArtwork`):** rounded-square + microphone + waveform. Migrate color literals to tokens. Dark navy gradient + cyan glow stay.
- **Menubar icon:** template SF Symbol, same shape at all times. Color: default `text/primary` (template, follows menubar theme); red `capsule/recording` when recording. No pulse, no animation.
- **System glyphs:** SF Symbols throughout. No custom icons unless required (waveform bars are shapes, not glyphs).
- **Tally dot:** custom 8px `Circle` red fill during recording.

---

## Bilingual RU/EN — first-class (Departure 3)

The product exists because of code-switching. Visible in UI structure.

- **Recording capsule:** `RU/EN` chip in left zone, equal weight, slash separator (Geist Mono 10/14 letter-spacing 0.06em). **Display only** — not clickable in v1.1.
- **Settings → General → Language:** segmented control `RU | RU+EN | EN | AUTO`, equal-width segments. Active uses window-bg fill ("raised"). Default `RU+EN`.
- **Language change:** takes effect on the **next recording**. Active recording continues with its mode. Protects whisper decoder from mid-buffer switches.
- **About:** first paragraph names bilingual code-switching as core positioning.

---

## User Journey

### 1. First launch arc

| Step | User does | User sees | User feels |
|------|-----------|-----------|------------|
| 1 | Opens VoiceType.app first time | Checklist window, 4 steps (3 red / 1 neutral) | "OK, clear what's required." |
| 2 | Clicks "Grant microphone access" | System Settings → Privacy → Microphone opens | Familiar, no friction |
| 3 | Toggles on, returns | Step 1 green | "One down." |
| 4 | Clicks "Grant accessibility access" | System Settings → Privacy → Accessibility opens | "Makes sense." |
| 5 | Toggles on, returns | Step 2 green | "Halfway." |
| 6 | Clicks "Download a model" | Row shows progress | "I see progress." |
| 7 | Download completes | Step 3 green | "Three down." |
| 8 | Sets custom hotkey or skips | Checklist closes | Ready. |
| 9 | Presses ⌥ SPACE | Capsule appears | "It's listening." |
| 10 | Speaks, releases | Transcribing dots, insert → focused field | "It just worked." |

Total time to first dictation: **≈2-3 minutes** (dominated by model download).

### 2. Daily use arc (100×/day)

| Frame | Time | What happens | User feeling |
|-------|------|--------------|--------------|
| T+0 | — | User typing in Cursor | flow |
| T+50ms | ⌥ SPACE pressed | Intent | decide |
| T+200ms | — | Capsule appears, scale 0.95→1.0, tally gray | "listening" |
| T+varies | recording | Red tally + REC + waveform active | speak |
| release | — | Capsule enters transcribing (dots) | short wait |
| +1-3s | whisper done | Text inserted, 400ms flash "Inserted · N chars → Cursor" | done |
| +400ms | — | Capsule dismisses, focus returns | back to flow |

Total UI ceremony per dictation: ≈800ms. 100×/day = ~80s total overhead, should feel invisible.

### 3. Error recovery arc

| Trigger | User sees | Path forward |
|---------|-----------|--------------|
| Mic permission denied | Capsule error: "Mic denied · Open Privacy" | Click → System Settings |
| Accessibility denied | Capsule error: "Accessibility denied · Open" | Click → System Settings |
| Model not downloaded | Capsule error: "No model · Download" | Click → Settings → Models |
| Whisper crashed | Toast: "Transcription failed unexpectedly. Model has been reloaded. [View log]" | Click "View log" → errors.log |
| Text insertion failed (wrong focus) | Transcription is in history | Settings → Advanced → Transcription history → Re-insert or Copy |

Every error is logged. Every transcription is saved. **Nothing is ever truly lost.**

---

## Error Handling & Logging

### Log file

Path: `~/Library/Logs/VoiceType/errors.log`
Format: `[ISO8601] [severity] [type] message | context`
Rotation: daily, keep 7 days, delete older.

Every error logged before UI surface appears.

### UI treatment rule

- **Solvable errors** (one-click fix): inline in capsule, 4s auto-dismiss, clickable text opens the fix. Examples: mic denied, accessibility denied, model not downloaded, download failed.
- **Unsolvable errors** (need explanation): toast, 6s auto-dismiss, "View log" link. Examples: whisper crash, OOM, unknown runtime error.

### Settings access

Settings → Advanced → **Error log** row:
- Title "Error log"
- Subtitle: `~/Library/Logs/VoiceType/errors.log · N entries` (Geist Mono, secondary)
- Actions: `Reveal in Finder` · `Clear`

---

## Transcription History

**Why this exists (user-stated 2026-04-24):** transcriptions can be lost when focus changes mid-recording — the user starts dictating in Cursor, clicks into another window, finishes, and the insert goes to the wrong place. Transcriptions are expensive (user's speech, 1-8s of work each). Losing them is unacceptable.

### Storage

Path: `~/Library/Application Support/VoiceType/history.jsonl`
Format: one JSON object per line:
- `id` (UUID)
- `timestamp` (ISO 8601)
- `durationSeconds` (float)
- `language` (RU | EN | mixed | auto-detected)
- `model` (model name used)
- `text` (full transcription)
- `targetApp` (bundle identifier at insert time)
- `targetWindowTitle` (best-effort window title at insert time)
- `insertSuccess` (bool)

Retention: last **100 entries** with rolling rotation (oldest dropped on limit hit). Limit tokenizable in future.

### UI surface

Settings → Advanced → **Transcription History** row:
- Title "Transcription history"
- Subtitle: `{N} entries saved · oldest from {date}` (Geist Mono, secondary)
- Actions: `Open history` (primary) opens a sheet

**History sheet** (800 × 560 modal):
- Left: chronological list, newest first. Row: timestamp (Geist Mono) + language chip + duration + target-app name
- Right: selected entry detail: full text, timestamp header, target-app, insert-success badge
- Actions per entry: `Copy text` · `Re-insert into current app` (warns if target app differs from original) · `Delete entry`

### v1.1 scope

- Storage layer writes on every successful or failed transcription
- Settings row: count + Open history button
- History sheet: list + detail + Copy + Re-insert + Delete
- **NOT in v1.1:** search, filter, export, cross-device sync

---

## Focus Return (mandatory behavior)

**On hotkey press:**
1. Capture `NSRunningApplication.currentApplication()` = `previousApp`
2. Capture focused window via `AXUIElementCopyAttributeValue` + `kAXFocusedApplicationAttribute` = `previousWindow`
3. Show capsule without stealing focus

**On capsule dismiss (after inserted-flash or any error state):**
1. Activate `previousApp`
2. Raise `previousWindow`
3. User's cursor blinks in the same field they left

**Guarantee:** user can hotkey → speak → continue typing without touching the mouse. This is the reason VoiceType exists. Breaking this = shipping a toy.

---

## Four Deliberate Departures

### Departure 1: Honest waveform (silent during silence)

Competitors animate the waveform continuously to reassure users. That's theatre. VoiceType shows a flat waveform during silence; bars move only when audio level crosses `Tokens.Motion.waveformActivationThreshold = 0.15`. When bars move, they mean something.

### Departure 2: Settings without a hero, native rows not cards

No app artwork on any Settings tab. No subtitle re-introducing the product. Native rows separated by dividers, not boxed cards (per 2026-04-24 Codex hard rejection). Cards only for discrete interactions. Linear / Raycast / System Settings convention.

### Departure 3: Bilingual visible in the UI

Segmented control in first tab, not dropdown. Chip in recording capsule. See Bilingual section.

### Departure 4 (new 2026-04-24): Transcription history as safety net

Competitors silently lose transcriptions when focus changes. VoiceType keeps every transcription in `~/Library/Application Support/VoiceType/history.jsonl`. Not a "power user feature" — the answer to "I just dictated 30 seconds into the wrong window."

---

## Anti-Slop Hard Rules

- ✗ Purple gradients anywhere
- ✗ Centered hero compositions
- ✗ Glassmorphism / frosted-glass as default surface
- ✗ Decorative animated blobs in window backgrounds
- ✗ Rainbow / angular gradient borders on the capsule
- ✗ Continuous waveform animation during silence
- ✗ Uniform bubble border-radius on every element
- ✗ system-ui / -apple-system as primary display or body font
- ✗ Inter, Roboto, Space Grotesk as primary font
- ✗ Stock SaaS dashboard look (3-column feature grid, gradient CTA)
- ✗ "Built for X" / "Designed for Y" tagline aesthetic
- ✗ Apple App Store hero treatment in Settings
- ✗ Warm mint radial accents in window chrome
- ✗ **Boxed card stacks in preferences** (Codex hard rejection 2026-04-24). Native rows + 1px dividers. Cards only for discrete interactive moments.
- ✗ **Onboarding wizard with icons-in-colored-circles** (SaaS template). Numbered-badge checklist with native typography.

---

## Implementation Plan (Tier A refactor)

### Pre-Tier A: Track 2 W1 (Weekend 1, independent of Tier A)

0a. Add `enum Language: String, Codable, CaseIterable` to `AppSettings.swift`:
    cases `ru`, `en`, `auto`, `bilingualRuEn = "ru+en"`. Computed props:
    `var whisperLanguage: WhisperLanguage? { .ru / .en / nil / .ru }` and
    `var usesBilingualPrompt: Bool`. Replaces `preferredLanguage: String`.
    **Tests:** `LanguageEnumTests.swift` — Codable round-trip, whisperLanguage mapping.

0b. Add `customVocabulary: String` to `AppSettings`. Add Custom Vocabulary
    textarea to current General tab with `// TODO Tier A: move to Advanced tab`.

0c. Add `TranscriptionService.setInitialPrompt(_ text: String?)` with
    `_initialPrompt: UnsafeMutablePointer<CChar>?` lifetime management (strdup/free,
    deinit). Call `setInitialPrompt` at end of `loadModel()` to re-apply after
    model reload. `applyRuntimeConfiguration` takes `Language` not `String`.
    **Tests:** `TranscriptionServiceInitialPromptTests.swift` — ptr lifecycle,
    re-apply after reload, empty string = nil ptr.

### Tier A (Weekends 3-4)

1. Create `Sources/VoiceType/Views/DesignSystem/Tokens.swift` with `Spacing`,
   `Radius`, `Palette`, `Typography`, `WindowSize`, `CapsuleSize`, `Motion`,
   `ButtonPadding`. Include `Color(light:dark:)` extension via
   `NSColor(name:dynamicProvider:)` for automatic dark/light adaptation.
   **Tests:** `TokensTests.swift` — regression guard: spot-check 5+ token values
   against DESIGN.md spec.

2. Replace literals in `WindowChrome.swift` with token references.

3. Rewrite `SettingsView.swift`: sidebar, tab order (General → Models → Shortcuts
   → Advanced), native-rows (no `SettingsSectionCard`), no hero header, segmented
   `Language` control (RU / RU+EN / EN / AUTO), inline permission rows. Move
   Custom Vocabulary from General to Advanced tab (completing W1 TODO).

4. Create `FirstLaunchWindow.swift`: 4-step checklist per First Launch spec.
   **Remove `permissionManager.requestInitialPermissionsIfNeeded()` from
   `applicationDidFinishLaunching()` — FirstLaunchWindow is now the sole
   onboarding surface.** Subsequent launches skip checklist via
   `hasCompletedOnboarding` UserDefaults flag.

5. Update `MenuBarView.swift` with three-state dropdown (Idle / Recording / Not
   Ready). Status line + tally + two-line readout. Menubar icon → red during
   recording.

6. Rewrite `WaveformView.swift` (capsule): token-based, three-zone layout
   (tally + REC + RU/EN chip), opaque dark surface, red tally. Replace
   `VoiceTypeState` enum with `CapsuleState` (6 cases with associated values:
   `recording`, `transcribing`, `inserted(charCount:Int, targetAppName:String)`,
   `errorInline(message:String)`, `errorToast(title:String, body:String)`,
   `emptyResult`). `VoiceTypeWindow` gets `@Published var capsuleState: CapsuleState`;
   `RecordingWindow.setContent()` removed — single `NSHostingView` created once at
   init. `AppDelegate` mutates `capsuleState` instead of calling `setContent()`.

7. Add capsule states to `VoiceTypeIndicatorView`: `transcribing` (3-dot breathing,
   `Motion.long` per cycle), `errorInline` (4s auto-dismiss), `errorToast` (separate
   NSWindow, 6s auto-dismiss + "View log" link), `emptyResult` ("Nothing heard"
   400ms flash). **Explicitly remove `AppDelegate.showError()` / `NSAlert.runModal()`
   from all 4 failure paths** (mic denied, empty capture, transcription failed,
   insertion failed) — route all errors through `CapsuleState.errorInline` or
   `.errorToast` per DESIGN.md solvable/unsolvable rule.

8. Add `inserted` state: char-count + target-app name 400ms flash, green tally.

9. Implement Transcription History: `Services/HistoryStore.swift` (history.jsonl,
   100-entry rolling, thread-safe writes), `Views/Settings/HistorySheet.swift`.
   `HistoryStore.reinsert(entry:)` **activates
   `NSRunningApplication(bundleIdentifier: entry.targetApp)` before calling
   `TextInjectionService.injectText()`**; shows toast if target app not running:
   "App not running — copied to clipboard".
   **Tests:** `HistoryStoreTests.swift` — write/read/rolling limit/concurrent
   writes/delete/reinsert-activates-correct-app.

10. Implement Error Log: `Services/ErrorLogger.swift` (daily rotation, 7-day
    retention). **Create `~/Library/Logs/VoiceType/` if missing on first write.**
    Rotation check once at app launch (not on every write). Row in Advanced tab.
    **Tests:** `ErrorLoggerTests.swift` — write/rotation/retention/directory
    auto-creation.

11. Implement Focus Return: `Services/FocusCaptureService.swift` captures
    `previousApp` + `previousWindow` at hotkey press. On restore: activate
    `previousApp`, raise window. **Guard `kAXErrorInvalid` on stale AX element —
    if previous app quit, save text to history only + toast "App closed — saved
    to history" (T6 edge case).**
    **Tests:** `FocusCaptureServiceTests.swift` — capture/restore/nil-when-no-focus/
    stale-AX-no-crash.

12. Implement Accessibility announcements: `NSAccessibilityPostNotification` on all
    6 `CapsuleState` transitions (not just recording). See VoiceOver section.

13. Implement Reduced Motion branch: `accessibilityDisplayShouldReduceMotion`;
    opacity-only, no scale, no pulse.

14. Vendor Geist + Geist Mono into `Resources/Fonts/`, register via Bundle.
    `.font(Tokens.Typography.body)` across views.

Sequence per v1.1 roadmap:
- Weekend 1 (Track 2): steps 0a-0c — unblocked, no token dependency
- Weekend 3-4 (Track 1, parallel): steps 1-8 (Views/) ‖ steps 9-11 (Services/ new files)
- Weekend 4 (after lanes merge): steps 12-14 (need CapsuleState from step 6)
- If Tier A runs long: History (step 9) can split to Weekend 5 as self-contained module

---

## Decisions Log

| Date       | Decision                                                            | Rationale |
|------------|---------------------------------------------------------------------|-----------|
| 2026-04-24 | Initial design system created via /design-consultation              | Three voices (Claude main + Codex + Claude subagent UI Designer) converged on Linear/Raycast neighborhood, Geist family, opaque capsule, no glassmorphism. |
| 2026-04-24 | Compass in English: "A tool for people who just build things, with the polish of commercial software." | Originally captured in Russian during /office-hours; translated and tightened. |
| 2026-04-24 | Recording dot color: RED `#E8423A` (over Codex's cyan)              | Tally-light cultural reference. Unclaimed in category. |
| 2026-04-24 | Base palette: cool ink-steel (Codex's) over warm paper (subagent's) | macOS-native feel. User confirmed visually via `v1-cool-inksteel.html` vs `v2-warm-paper.html` in /plan-design-review. |
| 2026-04-24 | Capsule size: 300×44 hybrid                                         | Three-zone structure (Codex) + tighter dims (subagent). |
| 2026-04-24 | Capsule material: solid opaque, no .ultraThinMaterial              | Signature object should be confident. |
| 2026-04-24 | Three departures locked                                             | Silent waveform, no Settings hero, bilingual visible. |
| 2026-04-24 | Bilingual RU/EN promoted to first-class UI element                  | Product exists because of code-switching. |
| 2026-04-24 | Apple App Store hero pattern removed from Settings                  | Linear/Raycast convention. Artwork stays in About. |
| 2026-04-24 | **Native rows (not boxed cards) in Settings and About**             | Codex hard rejection via /plan-design-review: boxed cards ship web-dashboard look. System Settings / Linear / Raycast use grouped rows + meta-labels + 1px dividers. Cards only for discrete interactions. |
| 2026-04-24 | **Settings tab order: General → Models → Shortcuts → Advanced, default = General** | Frequency-ordered per macOS convention. Permissions inline (mic in General, accessibility in Shortcuts). |
| 2026-04-24 | **About order: BUILD → CURRENT SETUP → PRIVACY**                   | Version check → config check → privacy reassurance exit. |
| 2026-04-24 | **MenuBar IA: Status + Record + Settings + About + divider + Quit** | Record stays for users who don't remember hotkey. No mini-control-panel (don't duplicate Settings). |
| 2026-04-24 | **Capsule transcribing state added**                                | Fills 1-8s gap between hotkey release and insert. Was missing. |
| 2026-04-24 | **Error UI: hybrid (inline solvable / toast long-form) + persistent error log** | Inline for quick fixes. Toast for explanations. All errors to `~/Library/Logs/VoiceType/errors.log` daily rotation. User concern: "don't lose errors" → solved by always-log. |
| 2026-04-24 | **Empty-result: "Nothing heard" 400ms flash**                       | Not silent dismiss — confirms app ran when hotkey fired accidentally. |
| 2026-04-24 | **First-launch: 4-step checklist window + menubar mirror**          | Mic + Accessibility + Model + Hotkey. Accessibility promoted to blocker (without it, insertion fails silently). Menubar mirrors remaining steps as safety net. |
| 2026-04-24 | **Inserted state: "Inserted · N chars → AppName"**                  | Subagent recommendation. Catches wrong-window-focus bugs. |
| 2026-04-24 | **Contrast fix: restrict text/muted to meta-labels only**           | text/muted on bg/window = 4.1:1 fails AA body. Subtitles use text/secondary (11.5:1 AAA). |
| 2026-04-24 | **Colorblind secondary signal: "REC" text label**                   | Red tally loses contrast under protanopia. Geist Mono "REC" in left zone. Triple-encoding. |
| 2026-04-24 | **VoiceOver announcements locked**                                  | Capsule invisible to screen readers without explicit posts. All transitions announced. |
| 2026-04-24 | **Multi-screen v1.0: screen of focused window, NSScreen.main fallback** | Zero ambiguity. v1.2 adds preferences + mid-recording-screen-change. |
| 2026-04-24 | **Menubar icon: red when recording, no pulse**                      | Glanceable. Consistent with capsule. No animation avoids notification-anxiety. |
| 2026-04-24 | **RU/EN chip: display only (v1.1)**                                 | Capsule is recording UI, not control. Switching via Settings only. |
| 2026-04-24 | **Language change: next recording only**                            | Predictable. Protects whisper decoder from mid-buffer switches. |
| 2026-04-24 | **Post-insert focus return mandatory**                              | Capture previousApp + previousWindow on hotkey; restore on dismiss. The reason VoiceType exists. |
| 2026-04-24 | **Transcription History in v1.1 scope (Departure 4)**               | User pain: current build loses transcriptions on focus change. Storage in history.jsonl (100 entries rolling), Settings → Advanced, in-app sheet Copy/Re-insert/Delete. Not deferred. |
| 2026-04-24 | **Motion tokens named: `Motion.micro/short/medium/long = 100/200/300/500ms`** | Pre-empts magic-number drift. `waveformActivationThreshold = 0.15` tokenized. |
| 2026-04-24 | **Reduced Motion: opacity-only, no scale, static red dot**          | Respects macOS accessibility preference. |
| 2026-04-24 | **Token hygiene:** removed `2xs 2px`; assigned `accent/strong` to capsule-border-emphasis + hover; `stroke/strong` to active-section-edge + focus-ring | Unused tokens drift. Assigned or removed. |
| 2026-04-24 | **Button padding 7px 14px as locked off-scale exception**           | Battle-tested rhythm. `Tokens.ButtonPadding` with Decisions Log entry so future maintainers know it's intentional. |
| 2026-04-24 | **Prefs-row padding: lg 16px horizontal, md 12px vertical, min-height 40px** | Replaces ambiguous "20-24px depending on density". Single rhythm. |
| 2026-04-24 | **Language enum replaces preferredLanguage: String** | `enum Language` with `whisperLanguage: WhisperLanguage?` and `usesBilingualPrompt: Bool` computed props. Compile-time safety, explicit RU+EN mapping. `/plan-eng-review` D5. |
| 2026-04-24 | **RU+EN = language=ru + bilingual initial_prompt** | Auto-detect picks "en" on heavy code-switching, mangling Russian. Primary use case is Russian text + English tech terms; "ru" as base decoder + prompt bias is correct. NOT language=nil/auto. Cross-model (Codex confirmed). `/plan-eng-review` D1, D10. |
| 2026-04-24 | **Color tokens via NSColor(name:dynamicProvider:)** | Dynamic dark/light adaptation without asset catalog files or @Environment boilerplate. `Color(light:dark:)` extension in Tokens.swift. `/plan-eng-review` D4. |
| 2026-04-24 | **RecordingWindow: single NSHostingView + @Published CapsuleState** | setContent() rebuild breaks state-transition animations and wastes memory across 6 states. One view, mutation via @Published. `/plan-eng-review` D2. |
| 2026-04-24 | **FirstLaunchWindow replaces requestInitialPermissionsIfNeeded()** | Auto-request + onboarding checklist = duplicate prompts + focus theft + undefined first-run state. Checklist is the sole onboarding surface. Codex finding. `/plan-eng-review` D8. |
| 2026-04-24 | **HistoryStore.reinsert() activates targetApp before inject** | Re-inserting from Settings sheet without activating target app injects text into Settings. Fix: activate NSRunningApplication(bundleIdentifier:) + 50ms delay before injectText(). Codex finding. `/plan-eng-review` D9. |
| 2026-04-24 | **Custom Vocabulary lands in General tab on W1, Advanced on Tier A** | Keeps W1 and Tier A as parallel independent tracks. General tab temporary placement marked with TODO comment. `/plan-eng-review` D3. |
| 2026-04-24 | **SwiftLint live with custom rules guarding DESIGN.md tokens** | `.swiftlint.yml` added with custom rules `inline_color_rgb`, `inline_color_hex`, `inline_nscolor_rgb`, `ultra_thin_material_on_capsule`, `nsalert_runmodal`. All WARNING until Tokens.swift lands in Tier A (Weekend 3-4); bump to ERROR after. Baseline: 54 warnings, 0 errors. Token drift is now enforceable, not aspirational. |
| 2026-04-24 | **Tokens.swift live — canonical design system foundation** | `Sources/VoiceType/Views/DesignSystem/Tokens.swift` (318→332 L after review fixes) captures every Spacing/Radius/Palette/Typography/Motion/WindowSize/CapsuleSize/ButtonPadding value from DESIGN.md exactly. `Color.dynamic(light:dark:)` extension wraps `NSColor(name:dynamicProvider:)` per D4. `NSColor(hex:)` parser uses strict `UInt64(_, radix: 16)` + `fatalError` on bad input — no silent fallbacks. 38/38 tests including 8-char RRGGBBAA regression guard. Independent review caught 2 P1 (silent parser failures), 3 P2 (missing line-heights, doc clarity), 2 P3 (test gaps) — all addressed. Commits `0834fe8` + `fc93c77`. |
| 2026-04-24 | **SwiftLint custom rules partial bump to ERROR** | `inline_color_hex` + `inline_nscolor_rgb` bumped WARNING → ERROR (0 current violations — Tokens.swift is sole consumer and uses file-level disable). Any new hex or NSColor RGB literal in Views/ outside DesignSystem/ is now a compile-time fail. `inline_color_rgb` stays WARNING until Tier A Step 2 migrates the 8 known legacy violations (WaveformView/VoiceTypeArtwork/WindowChrome) — then it joins ERROR. `nsalert_runmodal` + `ultra_thin_material_on_capsule` remain WARNING until Step 7. |
| 2026-04-25 | **First-launch celebration arc — 200ms tick bounce + 200ms "All set" fade + 400ms hold + 300ms dismiss; Reduced Motion shrinks all to opacity-only over ~200ms.** `FirstLaunchCelebrationViewModel` extracted for testability; `hasCelebrated` + `hadUnsatisfiedBlockerAtOpen` guard against re-fire and re-open-when-complete edge cases. |
| 2026-04-25 | **Phase 2.5 follow-up chunks L–S (9 chunks, 13 commits, 232 tests)** | Round-1 parallel: L perm-3-state migration (`PermissionState` enum {notDetermined, denied, granted}; SettingsView shows accent-soft "Allow…" on first launch instead of error-tinted "denied"); N AboutView padding aligned to v1 prototype (`aboutContentTop=28`, `aboutContentHorizontal=28`, RowDivider reuse from SettingsView); Q FocusCaptureService AX wrapper (`AXAttr.value<T>` replaces 3 `as!` force-casts, fail-soft instead of crash); R HistoryStore stress tests (rapid-fire append, corrupt JSONL line drop, ZWJ unicode round-trip, 100-cap on append). Round-2 sequential: M GeistMono-SemiBold vendored from vercel/geist-font (OFL-1.1 attribution at `Resources/Fonts/OFL.txt`); O trim toggle wired (TranscriptionService.conditionallyTrim, trailing-only per prototype label "Trim trailing whitespace") + errorToast stacking test; P Reduced Motion branch (capsule labelTransition opacity-only, bar height instant snap, BreathingMod opacity-fade for transcribing dots, inserted-flash 200ms vs 400ms via NSWorkspace flag). Round-3: S SettingsView split — 8 presentational primitives (GroupHeader, PrefsRow, RowDivider, SectionGap, PermissionDot, SegmentedControl, PermHintPanel, SidebarItem) extracted to SettingsComponents.swift; SettingsView 1013 → 699 LOC; SegmentedControl/PermHintPanel/SidebarItem promoted private→internal. Pipeline pattern (no codex until Mon): Senior Developer Sonnet impl in isolated worktree → independent Code Reviewer Sonnet audit → P1/P2 inline fixes → FF-merge to main. Tests 194 → 232 (+38). Lint 54 → 49 warnings, 0 errors. |
| 2026-04-25 | **Initial-prompt UAF race fix (chunk AA).** | Defer `setInitialPrompt` while `isTranscribing`; store change in `_pendingPrompt: String??`; apply via `_flushPendingPrompt()` in `transcribe()` defer block. Nil-clears also defer. Last-write-wins for multiple deferred calls. 5 new tests in `InitialPromptRaceTests.swift`. Test seam: `_testFlushPendingPrompt()` internal method. |
| 2026-04-24 | **Tier A Step 6 + design polish shipped** | Geist fonts vendored + registered (Step 14 accelerated): Geist-Regular/Medium/SemiBold + GeistMono-Regular/Medium via CTFontManagerRegisterFontsForURL(.process) in AppDelegate before any view renders. MenuBar panel: clipShape + strokeBorder(strokeSubtle) + shadow(black 30%, r20 y8); hover states on MenuActionRow + SetupTaskRow (white 4% bg, Motion.micro); status padding asymmetric 14/10/12pt; notReady colors use Palette.error (not Palette.Capsule.recording); hotkey hint .tracking(0.44); MenuBar.dividerGap = 2pt. FirstLaunchWindow: blocker rows (mic/a11y/model) upgraded to ChecklistPrimaryButtonStyle (filled Palette.accent, black text for WCAG AAA contrast), hotkey stays ChecklistLinkButtonStyle; ButtonStyles.swift added to DesignSystem/. CapsuleState enum (6 cases) replaces VoiceTypeState; CapsuleStateModel (@Published, ObservableObject) owned by VoiceTypeWindow — single NSHostingView created once, never rebuilt. WaveformView rewritten: 3-zone layout (tally+REC+RU/EN chip / audio waveform / MM:SS timer); transcribing = 3-dot breathing (Motion.long); inserted/error/emptyResult = centered label with state-specific foreground; waveform bars use Palette.Capsule.text (active) / Palette.Capsule.timer (silent) per prototype; state-conditional ambient glow; Palette.Capsule.borderOk added for inserted state; last inline_color_rgb violation in WaveformView closed. Independent review caught 2 P1 (centeredLabel color propagation dead, white-on-accent 1.9:1 WCAG fail) + 5 P2 (waveform bar red, Typography.badge semibold fallback, red glow bleed, missing borderOk, dividerGap wrong namespace) + 2 P3 (dead ChecklistButtonStyle, log count drift) — all addressed. Tests: 76 → 111 (FontRegistrationTests, CapsuleStateTests, RecordingWindowTests added). SwiftLint: 50 → 49 warnings (net -1 after trailing-newline cleanup; 2 TODO warnings remain for Step 7 toast deferral), 0 errors. |
| 2026-04-25 | **Add large-v3-turbo as opt-in model (fp16, ~810 MB, CoreML-supported, position last in picker).** | Distilled-v3 fast model: ~7-8x faster than large-v3 with comparable quality. Chunk W. |
| 2026-04-27 | **Toast queue (FIFO max=3) + min-visible-time 2.5s + persistent pre-emption** | Errors were flashing for milliseconds when rapid replacements happened, and `showErrorToast()` wrote only to os.Logger, not `errors.log`. Fix: log via `ErrorLogger.shared.log()` inside `ErrorToastWindow.show()` so every caller benefits; FIFO queue (max 3, oldest drops with warning) preserves order while a toast is on screen; persistent toasts (e.g. restart-required from `PermissionManager`) BYPASS the queue and pre-empt the current toast — they are urgent and the caller may act on a 600ms delay. Three Codex review rounds caught: (1) FIFO broken when queue non-empty after minVisibleTime, (2) `persistent` flag dropped on queue round-trip, (3) persistent toasts queued behind visible non-persistent → user misses critical notifications. Final state: 8 ErrorToastQueueTests covering log integration, FIFO, queue-drop, persistent-flag round-trip, and pre-emption. v1.3.0. |
| 2026-04-27 | **3 model presets (Fast / Balanced / Max Quality) as primary Settings → Models UI; full 7-model list moves into "Advanced" DisclosureGroup** | The 7-model list was a wall of jargon ("large-v3-turbo-q5_0") that punished new users. Bench data established a clean 3-tier story: Fast=`smallQ5` (~190 MB), Balanced=`largeV3TurboQ5` (~547 MB, marked "Recommended"), Max Quality=`largeV3Turbo` (~810 MB). Native rows + dividers (no boxed cards), `RecommendedBadge` as full-pill Capsule with `Palette.accentSoft`, "Custom" indicator when user has selected something outside the 3 presets via Advanced, single shared persistence key (no state fragmentation). DisclosureGroup uses `.accentColor(Palette.accent)` for the chevron. v1.3.0. |
| 2026-04-27 | **Codex review is now a hard gate before merge for any feature ≥ ~50 LOC.** | Pipeline: Sonnet implements in isolated worktree → `codex review --commit <SHA>` (P0/P1 block, P2 must be addressed, P3 noted) → fixup commits on the same branch → re-review → merge `--no-ff` to preserve iteration history. v1.2.2 retro showed Codex caught 6 real bugs across 2 rounds that Claude alone missed. v1.3.0 caught 4 more across 4 streams (P2 FIFO, P2 persistent flag, P2 persistent pre-emption, P3 annotated-tag peel). `scripts/codex-review.sh` standardizes the invocation with 24h SHA-keyed caching to avoid re-paying ~17K-token Codex CLI startup overhead on identical reviews. |
