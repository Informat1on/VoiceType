# Hotkey Modifier Constants: Correcting Carbon Values

- Status: ACCEPTED
- Date: 2026-04-24

## Context

`AppSettings.swift` declared four global Carbon modifier constants used across
hotkey registration (`HotkeyService`), UI display (`modifiersToString`), the
hotkey recorder (`SettingsView`), and keyboard layout resolution
(`TextInjectionService`). The values were wrong relative to Apple's canonical
`HIToolbox/Events.h`.

### What the code had (wrong)

```swift
let cmdKey: Int    = 256   // 1 << 8  — correct
let optionKey: Int = 512   // 1 << 9  — WRONG; this is Carbon shiftKey
let controlKey: Int = 1024 // 1 << 10 — WRONG; this is Carbon alphaLock
let shiftKey: Int  = 2048  // 1 << 11 — WRONG; this is Carbon optionKey
```

### Apple's canonical HIToolbox/Events.h

| Bit | Hex    | Dec  | Carbon name |
|-----|--------|------|-------------|
| 8   | 0x0100 | 256  | cmdKey      |
| 9   | 0x0200 | 512  | shiftKey    |
| 10  | 0x0400 | 1024 | alphaLock   |
| 11  | 0x0800 | 2048 | optionKey   |
| 12  | 0x1000 | 4096 | controlKey  |

### What users have actually been pressing

`RegisterEventHotKey` receives raw bit values and registers with the OS exactly
those bits. The OS fires the hotkey when the physical keys matching those bits
are held. Because the OS has always operated on correct bit values:

- A user who configured "Option+X" in the UI (stored `modifiers = 512`, labelled
  ⌥X) was actually registering Carbon `shiftKey`. They physically pressed
  Shift+X and it worked. The ⌥ symbol in the UI was a lie.
- The historical factory default `⌥⌘V` stored `768 = 256 + 512 = cmdKey +
  (wrong-optionKey)`. Carbon fired on Cmd+Shift+V (512 = real shiftKey). Users
  pressed Cmd+Shift+V and the UI said ⌥⌘V.
- `controlKey = 1024` (really alphaLock) was never a useful hotkey modifier.
  The real Control (4096) was not represented at all.

## Decision

Correct the constant values to match Apple's canonical definitions:

```swift
// Carbon modifier constants per HIToolbox/Events.h
let cmdKey: Int     = 256   // 1 << 8  — unchanged, was already correct
let shiftKey: Int   = 512   // 1 << 9  — was named optionKey in old code
let optionKey: Int  = 2048  // 1 << 11 — was named shiftKey in old code
let controlKey: Int = 4096  // 1 << 12 — was alphaLock (1024) in old code
```

`alphaLock = 1024` is omitted — it is not a useful hotkey modifier.

### Factory default preservation

The initializer fallback for `hotkeyModifiers` (line ~179 of AppSettings.swift) previously used `optionKey | cmdKey` which evaluated to 768 with the wrong constants. Carbon has always listened on bit 768 (= Cmd+Shift+V per Apple), so factory-default users have been pressing Cmd+Shift+V successfully even though the UI labeled it "Option+Cmd+V".

After the constants fix, using `optionKey | cmdKey` = `2048 | 256` = 2304 = Cmd+Option+V would change the physical shortcut those users have learned. To preserve their experience, the fallback is literal `shiftKey | cmdKey` = 768, matching the pre-fix physical default. The UI label now correctly reads "Cmd+Shift+V" — the visible behavior catches up to what users were physically doing.

Noted: a sibling commit will change the factory default to `⌥ Space` (Option+Space per new constants) as an intentional spec change. That supersedes this fallback for new installs. Users on factory defaults at upgrade time will experience a default change Cmd+Shift+V → Option+Space; this is a separate, intentional breakage per spec audit.

### No UserDefaults migration required

Bit values persisted in UserDefaults are unchanged; only names and UI labels
change to match physical reality:

- Existing users' physical keystrokes continue to work unchanged (Carbon has
  always listened on the correct bits).
- The Settings UI label for a stored modifier value now displays the correct
  symbol (e.g., a user who was pressing Shift+F1 now sees ⇧F1 instead of ⌥F1).
- New installs benefit from a correct default and correct UI labels from day one.

### TextInjectionService impact

`TextInjectionService.KeyboardLayoutKeyResolver` uses the same constants in
`lookupModifiers` and `eventFlags(for:)` to probe UCKeyTranslate for keyboard
layout character resolution. UCKeyTranslate receives `modifiers >> 8`:

- `shiftKey = 512`; `512 >> 8 = 2` = UCKeyTranslate Shift bit. Correct before
  and after the fix (value unchanged).
- `optionKey = 2048`; `2048 >> 8 = 8` = UCKeyTranslate Option bit. Previously
  the code had `512 >> 8 = 2` (= Shift), so Option-modified characters were
  never found during layout probing. After the fix, `2048 >> 8 = 8` correctly
  probes Option-shifted keys. This is an improvement.
- `shiftKey | optionKey = 512 | 2048 = 2560`; `2560 >> 8 = 10` = Shift+Option
  combined. Correct per UCKeyTranslate convention.

## Consequences

- All four constants now match Apple's documentation.
- `modifiersToString` displays correct symbols for stored modifier values.
- `RegisterEventHotKey` registers the intended physical key combinations.
- The hotkey recorder in SettingsView stores correct Carbon bits from
  `NSEvent.ModifierFlags` → Carbon conversion (this conversion was already
  structurally correct; it just used wrong destination values).
- `TextInjectionService` now correctly probes Option-shifted keyboard layout
  characters (previously only Shift and Shift+Option were effectively probed;
  Option alone was probed with the wrong bit value = Shift).
- `HotkeyModifierConstantsTests` in the test suite asserts all four values and
  will catch any future regression.

## Alternatives considered

1. **Keep wrong values, rename to match reality** — would require renaming
   `optionKey` → `shiftKey` everywhere, which is a larger diff with the same
   semantic outcome. Rejected: values matching Apple's header is cleaner and
   allows future code to use Carbon headers without confusion.

2. **Remove constants, use Carbon header symbols directly** — Carbon header
   symbols require `import Carbon` at every use site and some are typed
   differently. Rejected: project already uses these as module-level globals;
   keeping them is idiomatic for this codebase.

3. **Add UserDefaults migration** — not needed because bit values in storage are
   unchanged; only our interpretation of the names was wrong. Rejected for the
   general case. However, the `controlKey` constant changed value (1024 → 4096),
   so users who stored a Control-based hotkey DO need a targeted migration (see
   below).

## Migration

### Legacy Control bit migration

Pre-fix, the `controlKey` constant was `1024`, which per Carbon is actually `alphaLock` (CapsLock state modifier, not a hotkey modifier). Users who customized a Control-containing hotkey stored bit `1024` in UserDefaults, but Carbon never fired those shortcuts — they've been non-functional all along.

Additionally, pre-fix the recorder stored physical Option as bit `512` and physical Shift as bit `2048`. Post-fix, bit `512` is Shift and bit `2048` is Option — the two bits swap semantic meaning. For hotkeys WITHOUT legacy Control, this is fine because Carbon has been physically firing on the stored bits (users have muscle memory). Migrating those would break them.

For hotkeys WITH legacy Control (1024), Carbon never fired, so users developed NO muscle memory. We honor their ORIGINAL recorded intent by performing a full remap when loading those values:
1. Strip bit `1024`
2. Swap bits `512` ↔ `2048` (companion bits get remapped)
3. Add bit `4096` (new Carbon controlKey)

So Ctrl+Option (stored `1024|512` = 1536) correctly migrates to `4096|2048` = 6144 (physical Ctrl+Option). Similarly Ctrl+Shift (`1024|2048` = 3072) migrates to `4096|512` = 4608 (physical Ctrl+Shift).

Persisted back to UserDefaults on first encounter so subsequent launches skip the remap.
