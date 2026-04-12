# VoiceType Developer Guide

## Project Layout

```text
VoiceType/
├── Package.swift
├── build-app.sh
├── install-app.sh
├── README.md
├── DEVELOPMENT.md
├── artwork/
└── Sources/VoiceType/
    ├── AppDelegate.swift
    ├── VoiceTypeApp.swift
    ├── Models/
    ├── Services/
    ├── Utilities/
    └── Views/
```

## Local Development

Run directly with SwiftPM:

```bash
swift run
```

Build a release binary:

```bash
swift build -c release
```

Create a macOS app bundle in `dist/`:

```bash
./build-app.sh
```

Install the app to `~/Applications`:

```bash
./install-app.sh
```

## Opening In Xcode

```bash
open -a Xcode Package.swift
```

Use the `VoiceType` scheme. For transcription testing, prefer the `Release` build configuration because `whisper.cpp` runs noticeably slower in debug builds.

## Runtime Notes

- VoiceType is a menu bar app.
- It requests Microphone permission when recording starts for the first time.
- It requires Accessibility permission to simulate paste or typing events.
- Whisper models are stored in `~/Library/Application Support/VoiceType/Models/`.

## Models

Current model presets:

- `tiny`
- `base`
- `small-q5_1`
- `small`
- `medium`

CoreML encoder support is available for all built-in presets except `small-q5_1`.

## Packaging

`build-app.sh` currently:

1. Builds the release binary with SwiftPM.
2. Creates `dist/VoiceType.app`.
3. Generates `VoiceType.icns` from the artwork source.
4. Writes the bundle `Info.plist`.
5. Ad-hoc signs the resulting app bundle.

`install-app.sh` then copies the app to `~/Applications/VoiceType.app` and registers it with Launch Services.

This stable install path helps macOS show the correct app identity and icon in privacy panes.

Because the bundle is ad-hoc signed, a rebuilt app may need Microphone or Accessibility permission to be granted again after reinstalling.

## Useful Commands

Clean local build artifacts:

```bash
swift package clean
rm -rf .build dist
```

Reset permissions for local testing:

```bash
tccutil reset Microphone com.voicetype.app
tccutil reset Accessibility com.voicetype.app
```

Verify the installed app bundle:

```bash
plutil -p "$HOME/Applications/VoiceType.app/Contents/Info.plist"
codesign --verify --deep --strict --verbose=2 "$HOME/Applications/VoiceType.app"
```

## Manual QA Checklist

- App launches from `~/Applications/VoiceType.app`
- App icon appears in Finder and in System Settings privacy panes
- Menu bar item appears and opens Settings/About
- Microphone permission prompt appears when needed
- Accessibility permission enables text insertion
- Recording starts and stops reliably across repeated runs
- Transcription works in English and Russian
- Settings and About windows render correctly in light and dark mode

## Dependency Note

The project currently uses `SwiftWhisper` from the upstream `master` branch and relies on `Package.resolved` for the pinned revision.
