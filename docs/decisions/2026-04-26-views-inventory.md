# SwiftUI Views Inventory — Week 0 Spike

**Date:** 2026-04-26
**Spike for:** v1.1 Track 1 (Brand + UX Polish) kickoff
**Status:** RESOLVED
**Purpose:** Map current SwiftUI surface area before `/design-consultation` so the
designer brief is grounded in what actually exists, not what we imagine.

---

## TL;DR

7 view files, ~1,145 lines total. Two distinct visual worlds already in the app:

1. **Window chrome world** (About + Settings): WindowSurface + SettingsSectionCard +
   StatusBadge — relatively polished, consistent, uses `.ultraThinMaterial` and rounded
   cards. Already feels like a design system, but has zero centralized tokens.
2. **Recording overlay world** (floating capsule indicator): cyan/blue/purple palette,
   live audio waveform, animated border, two indicator styles (dot / waveform). Highly
   polished standalone, but **disconnected from window chrome palette**.

The biggest gap is **no design tokens file**. Colors, spacing, radii, and typography
are hardcoded inline across 7 files. This is the #1 blocker for systematic polish.

The `WaveformView.swift` audit (planned as separate Spike 3) is now answered inline
below — **verdict: skip rebuild, minor polish only**. The component is already live-audio
driven, animated, two-mode, well-structured. Saves us a `/codex consult` call.

---

## File-by-file

### `Views/MenuBar/MenuBarView.swift` (41 L)

**Purpose:** Three-button menu bar dropdown — Settings, About, Quit.
**Polish:** `functional`. Plain SwiftUI `Button` + `Label` + `Divider`. No styling.
**Tokens used:** none.
**Refactor candidates:** none — this is what a macOS menu bar should look like.
Keep it boring. (Polish opportunity: a small VoiceType glyph at the top of the menu,
but optional.)
**Notes:** Has stray `print("[MenuBarView] openSettings() called")` — remove during polish pass.

### `Views/About/AboutView.swift` (92 L)

**Purpose:** About window with build info, current setup snapshot, permissions
status, privacy statement.
**Polish:** `polished`. Uses every shared component: WindowSurface, SettingsSectionCard,
SettingsValueRow, StatusBadge, InfoChip (via WindowSurface chips param).
**Tokens used:** indirectly via shared components only. Direct: `Color.white.opacity(0.08)` once for shortcut badge.
**Refactor candidates:**
- Shortcut badge is duplicated inline (also lives in Settings hotkey tab) — extract to a `ShortcutBadge` view in Shared.
- Frame `.frame(width: 460, height: 560)` is a magic number; centralize window sizes.

### `Views/Settings/SettingsView.swift` (405 L) — **largest file, mixed concerns**

**Purpose:** TabView with 3 tabs:
- **Hotkey** — shows current shortcut, hosts HotkeyRecorder
- **Model** — model picker, download/CoreML state, footnotes about acceleration
- **General** — activation mode, language, indicator style, text injection, permissions

**Polish:** `polished` for chrome, `functional` for content. Heavy use of shared
components. Logic and presentation are intertwined (e.g., `modelFootnote` /
`modelFootnoteTone` computed inside the view).

**Tokens used:**
- `Color.white.opacity(0.06|0.08)` repeated 3+ times — clearly should be a token
- Corner radius `16` and `22` — should be `.surface` / `.card` tokens
- Inset font sizes via `.system(.subheadline, design: .monospaced)` for shortcut badge

**Refactor candidates:**
- Extract `HotkeyRecorderView` + `HotkeyRecorderRepresentable` (~50 lines) to its own
  file under `Views/Settings/HotkeyRecorder.swift`. Currently buries 12% of the file in
  AppKit bridging.
- `modelFootnote` / `modelFootnoteTone` should live on `TranscriptionModel` enum or a
  small ViewModel — pulls business logic out of presentation.
- Centralize TabView frame `(620, 520)`.
- The "Custom Vocabulary" textarea for v1.1 Track 2 W1 lands in Model tab as a new
  SettingsSectionCard — fits cleanly without restructuring.

### `Views/Recording/RecordingWindow.swift` (75 L)

**Purpose:** Borderless `NSWindow` floating overlay positioned 80px from top-center
of main screen. Hosts the indicator capsule.
**Polish:** `functional`. Pure infrastructure — window config + positioning + content swap.
**Tokens used:** Window metrics defined in sibling file (`VoiceTypeIndicatorMetrics`).
**Refactor candidates:**
- `topOffset: CGFloat = 80` is a magic number — move to metrics enum.
- Multi-screen handling: uses `NSScreen.main` only. v1.1+ should walk all screens
  for the screen with keyboard focus, or remember user-chosen screen.
- `setContent(state:)` rebuilds the entire `NSHostingView` on every state change —
  fine for two-state machines, but wasteful if we add idle/inserted states.

### `Views/Recording/WaveformView.swift` (230 L) — **misnamed, this is the main indicator**

**Purpose:** Despite the file name, this contains the entire recording overlay UI:
- `VoiceTypeIndicatorMetrics` (capsule sizing constants — the only token-like file in the project)
- `VoiceTypeIndicatorView` (the actual capsule overlay)
- `AnimatedCapsuleBorder` (live-audio-modulated angular gradient stroke)
- `PulsingDotView` (dot indicator style)
- `MiniWaveformView` (8-bar waveform indicator style)

**Polish:** `polished`. Live audio reactivity via `audioService.audioLevel`, two
indicator styles, animated border that pulses with audio, smooth state transition
(recording ↔ processing) with scale + opacity, monospaced duration counter.

**Tokens used:** Inline color literals everywhere — `.cyan`, `.blue`, `.purple`,
`.white.opacity(...)`, `Color(red: 0.4, green: 0.4, blue: 1.0)`. This is the prime
example of "needs design tokens NOW".

**State coverage (relevant to Spike 3 verdict):**
- `idle` — implicitly: the window is hidden via `RecordingWindow.hide()`. No persistent UI.
- `recording` — full live UI ✅
- `processing` (== "transcribing") — spinner + text ✅
- `inserted` — does NOT exist. Window is hidden the moment text is injected. A brief "✓ Inserted" flash (300-500ms) would close the loop visually.

**Refactor candidates:**
- **Rename file** to `RecordingIndicator.swift` (or split into 4 files).
- **Add `inserted` micro-state** — small green check + "Inserted" with 400ms fade,
  then hide. Closes the feedback loop.
- **Extract palette** to design tokens (cyan / blue / purple / accent gradients) so
  the recording overlay can either match or contrast the window chrome intentionally.

### `Views/Shared/WindowChrome.swift` (244 L) — **design system core, currently un-tokenized**

**Purpose:** Shared building blocks for all window-style screens:
- `WindowSurface<Content>` — page container with background + scrollable content + header
- `WindowBackground` — base + two radial accent gradients
- `WindowHeroHeader` — VoiceType artwork + title + subtitle + chips
- `SettingsSectionCard<Content>` — labeled card container
- `SettingsValueRow<Value>` — left label / right value layout
- `InfoChip` — pill-shaped tag
- `StatusBadge` with `.neutral / .positive / .warning / .accent` tones
- `FlowLayout` — used once for chips

**Polish:** `polished` chrome but **zero design tokens**:
- Corner radius literals: `26` (hero, surface), `22` (section card), Capsule (chips)
- Padding literals: `20, 24, 16, 14, 10, 6, 8, 4`
- Color literals: `Color.white.opacity(0.06|0.08|0.12)`, plus the radial accent
  `Color(red: 0.38, green: 0.70, blue: 0.95)` and `Color(red: 0.53, green: 0.84, blue: 0.78)`
- Material literals: `.thinMaterial`, `.regularMaterial`, `.ultraThinMaterial` — used
  inconsistently across hero (thin), section (regular), and recording capsule (ultraThin)
- Typography: `.headline`, `.subheadline`, `.caption.weight(.medium|.semibold)` —
  semantic-ish but no Type scale

**Refactor candidates:**
- Create `Views/DesignSystem/Tokens.swift` (or `DesignTokens.swift`) with:
  - `Spacing` (xs/s/m/l/xl)
  - `Radius` (button/card/surface)
  - `Surfaces` (hero/card/inline materials)
  - `Palette` (background/accent/recording/status family)
  - `Typography` (display/title/body/caption + monospaced)
- Replace literals in WindowChrome.swift first (highest impact, smallest blast radius).
- Decide on a deliberate brand color — currently the accents (cyan/blue) leak in from
  recording capsule, but window chrome doesn't share that identity.

### `Views/Shared/VoiceTypeArtwork.swift` (58 L)

**Purpose:** App artwork — rounded square with microphone glyph + 5 waveform bars
+ blue radial light accent. Used in WindowHeroHeader at 86px and could be used
elsewhere (menu bar icon? About hero? AppIcon?).
**Polish:** `polished` decorative asset with parameterized `size`.
**Tokens used:** all literals. Two key brand colors live here:
- `Color(red: 0.14, green: 0.16, blue: 0.28) → Color(red: 0.07, green: 0.08, blue: 0.14)` (dark navy gradient)
- `Color(red: 0.58, green: 0.93, blue: 0.95) → Color(red: 0.18, green: 0.60, blue: 0.92)` (cyan-blue glow)
- `Color(red: 0.52, green: 0.82, blue: 0.97)` (waveform bar accent)

These should become part of `Palette` tokens — they're the de facto VoiceType brand
colors but only used in this artwork component.

**Refactor candidates:**
- Promote the cyan/blue gradient to brand palette token.
- Currently rendered live every paint; consider rendering once to PNG for AppIcon
  pipeline (separate task — `xcassets` work).

---

## Cross-cutting findings

### Two design vocabularies, no shared identity

The window chrome world (About + Settings) uses muted materials + warm radial
accents (38/70/95 cyan + 53/84/78 mint green). The recording overlay world uses
saturated cyan/blue/purple animated gradients on dark capsule. They look like
different apps. The artwork bridges them via the cyan/blue gradient, but neither
view system fully claims it.

**Design consultation question:** lean into the recording capsule's identity
(saturated cyan-blue) and bring it into window chrome accents? Or pull the recording
overlay back toward the muted window aesthetic? Either is defensible; pick one.

### No design tokens — single biggest improvement opportunity

7 files, ~30+ color literals, ~50+ spacing literals, ~10+ corner radius literals,
material choice scattered. This is the highest-leverage refactor before any
`/design-review` polish pass — without tokens we'll be playing whack-a-mole.

### Logic-in-views

`SettingsView.swift` has model status logic (`modelFootnote`, `modelFootnoteTone`)
inside the view. Not breaking anything, but if the view grows we'll regret it.
ViewModel or extension on `TranscriptionModel`.

### Recording state machine is incomplete

`VoiceTypeState` has `recording` and `processing`. Missing:
- `inserted` (success flash) — small win, closes feedback loop
- `error` (mic failed / transcription failed) — currently silent fail

---

## Refactor priority for v1.1

**Tier A (do first, blocks design polish):**

1. Create `Views/DesignSystem/Tokens.swift` with `Spacing` + `Radius` + `Palette`
   + `Typography` enums.
2. Replace literals in `WindowChrome.swift` (highest reuse, lowest risk).
3. Replace literals in `WaveformView.swift` (recording overlay palette → tokens).

**Tier B (do during design polish weekends):**

4. Extract `HotkeyRecorder` from `SettingsView.swift`.
5. Rename `WaveformView.swift` → `RecordingIndicator.swift` (or split).
6. Add `inserted` and `error` micro-states to recording overlay.
7. Centralize window dimensions (`AboutView.swift` 460×560, `SettingsView.swift` 620×520).

**Tier C (defer to v1.2 unless trivial):**

8. Multi-screen support in `RecordingWindow.swift`.
9. Move `modelFootnote` logic to `TranscriptionModel` extension.
10. AppIcon pipeline using `VoiceTypeArtwork`.

---

## Inputs for `/design-consultation`

When kicking off Track 1 design, the brief should include:

- This inventory document (passed as context)
- Reference: MacWhisper aesthetic (clean / modern / laconic), explicitly NOT a clone
- The two-vocabulary tension: chrome world vs recording overlay — designer should
  resolve into one identity
- Required outputs: `DESIGN.md` with palette, typography, spacing, radii, motion
  language, iconography
- Hard constraint: must be implementable as `Tokens.swift` without re-architecting
  views (Tier A refactor will follow design output)

---

## Spike 3 — answered inline

The roadmap planned a separate Spike 3 (`/codex consult` audit of `WaveformView.swift`).
Reading the file directly answered all three questions:

| Question | Answer |
|----------|--------|
| Live audio or decorative? | **Live audio** — `audioService.audioLevel` drives bar heights, dot pulse, border opacity, and stroke width in real time. |
| Two visual styles? | Yes — `IndicatorStyle.dot` (PulsingDotView) and `IndicatorStyle.waveform` (MiniWaveformView), user-selectable in Settings → General. |
| State machine for idle → recording → transcribing → inserted? | Partial — recording + processing exist; idle = hidden window; **inserted state missing** (recommend adding 400ms green-check flash). |
| Verdict | **Skip rebuild, minor polish only.** Tier A token migration covers the palette work. Tier B adds the inserted micro-state. |

This avoids the planned `/codex consult` call. ~10 min saved.

---

## Files inspected

- `Sources/VoiceType/Views/MenuBar/MenuBarView.swift`
- `Sources/VoiceType/Views/About/AboutView.swift`
- `Sources/VoiceType/Views/Settings/SettingsView.swift`
- `Sources/VoiceType/Views/Recording/RecordingWindow.swift`
- `Sources/VoiceType/Views/Recording/WaveformView.swift`
- `Sources/VoiceType/Views/Shared/WindowChrome.swift`
- `Sources/VoiceType/Views/Shared/VoiceTypeArtwork.swift`
