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
- **Meta labels (uppercase, tracked):** Geist — `11/14`, Medium, letter-spacing `0.04em`, uppercase
- **Mono / timer / hotkey / model ID:** Geist Mono — `12/16`, Medium, with `font-feature-settings: 'tnum', 'zero'`
- **Loading:** Google Fonts initially (zero-config). For an offline build, vendor
  the variable woff2 files into `Resources/Fonts/` and register via
  `Bundle.main.url(forResource:withExtension:)`. SwiftUI `Font.custom("Geist", size: ...)` after registration.
- **Cyrillic fallback:** if Geist Cyrillic glyph coverage proves weak in practice
  (test verified `запушил коммит` rendering during preview on 2026-04-24), fall
  back to `.system(.body, design: .default)` only for Cyrillic strings via SwiftUI's
  font fallback chain. Do NOT switch the entire UI to system font — that defeats
  the typographic identity.

### Numerals

All numbers (timer, sizes, durations, percentages) use Geist Mono with tabular
figures so digits don't reflow on each tick. Apply via SwiftUI's
`.monospacedDigit()` modifier or directly via `Geist Mono` with
`font-feature-settings: 'tnum'`.

---

## Color

**Approach:** restrained. Single accent (electric cyan) carries interactivity,
focus, active state, and links across the entire app. The recording capsule
operates in its own world with one signature exception (red tally light) that no
other surface uses — this is what makes the capsule feel like a hardware status
LED, not a UI notification.

### Dark mode (primary)

```
bg / app           #0B1015   deep ink, app background
bg / window        #10171F   window surfaces
surface / card     #151D26   settings cards, group containers
surface / inset    #0E141B   inputs, code blocks, segmented control bg
stroke / subtle    rgba(255,255,255,0.08)   default borders, dividers
stroke / strong    rgba(143,207,255,0.20)   focus, active emphasis
text / primary     #EEF3F7
text / secondary   #C7D2DC
text / muted       #7F90A1
accent             #59C7FF   electric cyan, used sparingly
accent / strong    #1AA7F6
accent / soft      rgba(89,199,255,0.12)   badge backgrounds, soft fills
focus-ring         rgba(89,199,255,0.40)
success            #27B7A4
warning            #E8A93A
error              #FF7A6B
```

### Light mode (secondary, must work)

```
bg / app           #F3F6F8
bg / window        #FBFCFD
surface / card     #F0F4F7
surface / inset    #E2E9EE
stroke / subtle    rgba(14,23,32,0.08)
stroke / strong    rgba(21,159,225,0.20)
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

The recording capsule is the signature object. It uses an opaque dark surface
darker than any window background, regardless of system theme. The red tally
light is universal across themes.

```
capsule / bg              #0D0D0C   deeper than any window — opaque, signature
capsule / text            #F0EDE8
capsule / timer           #9E9A94
capsule / recording       #E8423A   RED — tally-light reference (camera, studio mic)
capsule / recording-glow  rgba(232,66,58,0.35)
capsule / border-idle     rgba(255,255,255,0.07)
capsule / border-rec      rgba(232,66,58,0.40)
```

**Why red for recording (taste decision, locked):** every competitor uses green
(MacWhisper) or cyan/blue (Wispr). Red is unclaimed in the category. It's the
camera tally light, the microphone-active LED on a studio console, the universal
"this device is recording you right now" signal. It's also the one color that
creates genuine visual urgency — glance at the screen, you know.

**Why opaque (taste decision, locked):** glassmorphism / `.ultraThinMaterial`
on the capsule weakens the object — it borrows from Control Center and dilutes
identity. The capsule is the one surface in the app that should be opaque and
confident. Window surfaces (Settings, About) may use tinted opaque colors with
subtle inner contrast, but never broad frosted-glass treatment.

---

## Spacing

Base unit: **4px**. Density: comfortable (between Linear's compact and Apple's
generous default).

```
2xs   2px
xs    4px
sm    8px
md   12px
lg   16px
xl   24px
2xl  32px
3xl  48px
4xl  64px
```

Window padding: `xl` (24px). Card padding: `xl` (20-24px depending on density).
Row vertical padding: `sm` (8px). Section gap: `xl` (24px). Button padding:
`7px 14px` (slightly tighter than the 4-base — buttons read denser at this scale).

---

## Layout

- **Approach:** grid-disciplined for app surfaces (Settings, About, menu bar
  dropdown). Composition-first for the recording capsule (it's a single
  unconventional object that defines the rest of the system).
- **Window dimensions:** Settings `620 × 520`. About `460 × 560`. Both centralized
  in `Tokens.WindowSize` so we stop sprinkling magic numbers across views.
- **Max content width inside a window:** matches window width (no extra clamping).
  These windows are deliberately small — content density is the polish.
- **Border radius scale:**
  - Capsule (recording overlay) → `14`
  - Buttons → `8`
  - Pickers, inputs → `8`
  - Section cards → `12`
  - Window surfaces (rounded corners on titlebar-less windows) → `12`
  - Chips / badges → full pill (`999`)
  - App artwork rounded square → `28%` of size

### Settings layout — left-aligned, content-first (Departure 2)

- No app artwork at the top of any Settings tab.
- No subtitle re-introducing the product on every tab open.
- Each tab opens directly to its content. Section header inside the card uses the
  meta-label type (uppercase, tracked, muted) — not a hero.
- Active section card gets a 2px accent rule on the left edge (only when the
  section is genuinely interactive — picker open, download in progress).
- Tabs read like tool sections, not App Store categories.

### About layout — the only place the app artwork lives

- Artwork at left, 64px (smaller than the previous 86px).
- Title + subtitle to the right, left-aligned.
- All other Settings-style cards below (build info, current setup, permissions,
  privacy).

### Recording capsule layout — three zones

```
┌─────────────────────────────────────────────┐
│  ●  RU/EN     ▮▮▮▮▮▮     0:14              │  300 × 44, radius 14
└─────────────────────────────────────────────┘
   left zone     center        right
   - tally dot   - waveform    - timer
   - lang chip
```

- **Width:** `300px` (current `240px` → +60). **Height:** `44px` (current `48px` → -4).
- **Padding:** `14px` horizontal, no vertical padding (height is fixed).
- **Background:** `capsule/bg` (`#0D0D0C`) at `100%` opacity, no material blur.
- **Border:** `1px` `capsule/border-idle` when idle; `1px` `capsule/border-rec` (red 40%) when recording.
- **Shadow:** `0 2px 8px rgba(0,0,0,0.5), 0 0 16px capsule/recording-glow` (red ambient halo, only perceptible against dark content).
- **Position:** top-center of the screen with the focused window, `80px` from the screen top. Multi-screen handling deferred to v1.2 (see views inventory).

---

## Motion

**Approach:** minimal-functional. Movement carries information; it never
decorates. The category default is "always animate to reduce anxiety." We
deliberately reject that — see Departure 1.

- **Easing:** enter `ease-out`, exit `ease-in`, move `ease-in-out`
- **Duration:** micro `100ms`, short `200ms`, medium `300ms`, long `500ms`
- **Capsule appear:** `scale 0.95 → 1.0` + `opacity 0 → 1`, `200ms` ease-out
- **Capsule disappear (after inserted-state flash):** `scale 1.0 → 0.96` + `opacity 1 → 0`, `200ms` ease-in
- **Recording dot:** ONE `scale 1.0 → 1.4 → 1.0` pulse over `200ms` when audio level crosses `0.15`. No continuous breathing.
- **Border during active recording:** static at `red 40%` opacity. No angular gradient sweep, no continuous animation.
- **Inserted-state flash (NEW state to add):** `400ms` cyan-to-teal checkmark with text "Inserted", then capsule dismisses.
- **Tab switching, picker opening:** native macOS animations (`200ms`).

---

## Bilingual RU/EN — first-class operational parameter (Departure 3)

The product exists because of code-switching. Make this visible in UI structure,
not buried in a dropdown.

- **Recording capsule:** `RU/EN` chip in left zone, equal weight, slash separator
  (Geist Mono, 10/14, letter-spacing 0.06em). Both languages get the same
  visual prominence.
- **Settings → General → Language:** segmented control with `RU | RU+EN | EN | AUTO`,
  not a buried Picker dropdown. Equal-width segments, active state uses the
  window-bg fill so the active option reads as "raised." Default to `RU+EN`.
- **About window:** first paragraph mentions bilingual code-switching as the core
  positioning, not a feature note buried in capabilities list.

---

## Three Deliberate Departures

These break category convention on purpose. Each must be defended in the Decisions
Log if challenged.

### Departure 1: Honest waveform (silent during silence)

Every direct competitor (MacWhisper, Wispr, Superwhisper) animates the recording
waveform continuously, even when the user is not speaking, to reassure them that
the mic is "listening." This is reassurance theater. VoiceType shows a flat
waveform during silence and only animates bars when audio level crosses a
threshold (≥ 0.15). When the bars finally move, they mean something.

This is technically honest — the model is not "always thinking," it is waiting.
It treats the user as someone who knows what silence looks like on an audio
buffer. MacWhisper's user research says "always show activity to reduce anxiety."
VoiceType's user wrote the build script — they have no such anxiety.

### Departure 2: Settings without a hero

Every Settings tab in the current build opens with `WindowHeroHeader` — app
artwork at 86px, subtitle text, chip labels. That pattern is a direct import from
the iOS App Store / first-launch onboarding aesthetic. It's warm but it's
borrowed. Linear and Raycast settings panels open straight to the model picker,
the hotkey field, the permission status. Remove the hero header from every
Settings tab. Put a small uppercase meta-label section header at the top
left. The user is here to change something, not be re-introduced 20 times a day.

The `VoiceTypeArtwork` component still belongs in About — that's the right
context for it.

### Departure 3: Bilingual visible in the UI

See section above. The category convention is to bury language preference in a
dropdown. VoiceType makes language a first-class operational parameter visible
on every recording.

---

## Iconography

- **App icon (`VoiceTypeArtwork`):** keep the existing rounded-square + microphone
  + waveform composition, but migrate the inline color literals to design tokens.
  Dark navy gradient stays as the "brand identity" surface — it predates this
  document and works well as the app icon. Cyan glow accent stays.
- **System glyphs:** SF Symbols throughout. No custom icons unless absolutely
  required (e.g., capsule waveform bars are not glyphs, they're shapes).
- **Tally dot:** custom 8px filled `Circle` with red fill. Not an icon.

---

## Anti-Slop Hard Rules

Do not generate any of these in code, mockups, or future design iterations.
If a future skill or designer proposes one, refuse and reference this section.

- ✗ Purple gradients anywhere (signals "AI app" / dating app / Notion plugin)
- ✗ Centered hero compositions (signals marketing site, not tool)
- ✗ Glassmorphism / broad frosted-glass treatment as default surface
- ✗ Decorative animated blobs in window backgrounds
- ✗ Rainbow / angular gradient borders on the capsule
- ✗ Continuous waveform animation during silence (UX theater)
- ✗ Uniform bubble border-radius on every element (use the radius scale)
- ✗ system-ui / -apple-system as the primary display or body font
- ✗ Inter, Roboto, Space Grotesk as primary font (overused, signals lack of
  taste investment)
- ✗ Stock SaaS dashboard look (3-column feature grid, gradient CTA buttons)
- ✗ "Built for X" / "Designed for Y" tagline aesthetic
- ✗ Apple App Store hero treatment in Settings windows
- ✗ Warm mint radial accents in window chrome (legacy from current build)

---

## Implementation Plan (Tier A refactor)

This DESIGN.md is the spec. The Tier A refactor implements it in code.

1. **Create `Sources/VoiceType/Views/DesignSystem/Tokens.swift`** with `Spacing`,
   `Radius`, `Palette`, `Typography`, `WindowSize`, `Motion` enums.
2. **Replace literals in `Views/Shared/WindowChrome.swift`** with token references.
3. **Replace literals in `Views/Recording/WaveformView.swift`** with capsule
   tokens, change palette from cyan/blue/purple → opaque dark + red tally,
   migrate to three-zone layout with RU/EN chip.
4. **Remove hero header from `SettingsView.swift` tabs** (Departure 2). Keep
   only the small uppercase section label.
5. **Replace Language Picker in `SettingsView.swift` General tab** with segmented
   control (Departure 3).
6. **Add `inserted` micro-state** to `VoiceTypeIndicatorView` (400ms cyan-to-teal
   flash), with corresponding `setContent(state:)` update in `RecordingWindow`.
7. **Vendor Geist + Geist Mono woff2/otf** into `Resources/Fonts/` and register
   via Bundle. Add `.font(Tokens.Typography.body)` etc. across all views.

Sequence per the v1.1 roadmap: this Tier A refactor lands as one or two PRs
during Weekend 3-4 (Track 1 polish weekends), AFTER the hotwords feature lands
on Weekend 1 (Track 2). Hotwords are insertion-only; they don't depend on the
new design tokens.

---

## Decisions Log

| Date       | Decision                                                            | Rationale |
|------------|---------------------------------------------------------------------|-----------|
| 2026-04-24 | Initial design system created via /design-consultation              | Three voices (Claude main + Codex + Claude subagent UI Designer) converged on Linear/Raycast neighborhood, Geist family, opaque capsule, no glassmorphism, content-first Settings. |
| 2026-04-24 | Memorable thing finalized in English: "A tool for people who just build things, with the polish of commercial software." | Originally captured in Russian during /office-hours; translated and tightened for the design system compass — single source of truth, English so it travels through the codebase, README, and any future contributor docs. |
| 2026-04-24 | Recording dot color: RED `#E8423A` (over Codex's cyan `#36C8FF`)     | Tally light cultural reference (camera, studio mic, hardware indicator). Unclaimed in category. Subagent's argument won on differentiation and screenshot-ability. |
| 2026-04-24 | Base palette: cool ink-steel (Codex's) over warm paper (subagent's)  | Aligns with macOS-native feel and electric cyan accent. "Machined precision" matches the builder-tool framing more cleanly than hand-crafted dotfiles vibe. |
| 2026-04-24 | Capsule size: 300×44 hybrid (between subagent's 220×36 and Codex's 392×64) | Three-zone structure (Codex) for RU/EN chip visibility, but tighter dimensions and smaller radius (subagent) for instrument-not-bubble feel. |
| 2026-04-24 | Capsule material: solid opaque, no .ultraThinMaterial (subagent's)   | The signature object should be confident, not borrow Control Center frosted glass. |
| 2026-04-24 | Three departures from category locked: silent waveform, no Settings hero, bilingual visible | Each departure independently serves the memorable thing: "tool for builders, with commercial polish." Each is technically honest. |
| 2026-04-24 | Bilingual RU/EN promoted to first-class UI element (Codex's)         | The product exists because of code-switching. Burying it in a dropdown denies the unique value proposition. |
| 2026-04-24 | Apple App Store hero pattern explicitly removed from Settings tabs   | Linear / Raycast convention: settings open to content. The `WindowHeroHeader` stays in About only. |
