# VoiceType

Lightweight macOS menu bar voice typing app powered by `whisper.cpp` and optimized for Apple Silicon.

![macOS 13+](https://img.shields.io/badge/macOS-13%2B-black?logo=apple)
![Swift 5.9+](https://img.shields.io/badge/Swift-5.9%2B-orange?logo=swift)
![Local First](https://img.shields.io/badge/Privacy-Local%20First-2ea44f)
![License MIT](https://img.shields.io/badge/License-MIT-blue.svg)

VoiceType records audio with a global shortcut, transcribes it locally on your Mac, and inserts the resulting text into the currently focused app.

## Installation

### Option 1: Download a release (recommended)

Go to the [Releases page](https://github.com/Informat1on/VoiceType/releases), download the latest `VoiceType-<version>.dmg`, open it, and drag `VoiceType.app` to your `Applications` folder.

For public releases, use a Developer ID-signed build. That keeps TCC permissions (Microphone, Accessibility) stable across app updates.

## Release Pipeline

For end users, distribute only the GitHub Release DMG.

The repository now supports both a safe prepare step and a one-command publish flow.

Build artifacts only:

```bash
./release.sh 1.0.2 --prepare
```

One-button draft GitHub release:

```bash
./release.sh 1.0.2 --draft
```

Public GitHub release:

```bash
./release.sh 1.0.2 --publish
```

The script:

1. Updates `VERSION`.
2. Builds `dist/VoiceType.app`.
3. Creates `dist/VoiceType-1.0.2.dmg`.
4. Notarizes and staples the DMG if `NOTARY_PROFILE` is configured in `.signing-env`.
5. Generates `dist/RELEASE_NOTES-v1.0.2.md`.
6. In `--draft` / `--publish` mode: commits the version bump, creates the git tag, pushes branch + tag, and creates the GitHub release automatically.

For a dry run without notarization, use:

```bash
SKIP_NOTARIZATION=1 ./release.sh 1.0.2 --prepare
```

Recommended `.signing-env` for public releases:

```bash
SIGN_IDENTITY="Developer ID Application: your@email.com (TEAMID)"
NOTARY_PROFILE="voicetype-notary"
```

Create the notarization profile once on your Mac:

```bash
xcrun notarytool store-credentials "voicetype-notary" \
  --apple-id "your-apple-id@example.com" \
  --team-id "TEAMID" \
  --password "app-specific-password"
```

For `--draft` and `--publish`, start from a clean git worktree. The script intentionally refuses to release from a dirty tree, so you do not accidentally ship unrelated local changes.

### Option 2: Build from source

Clone the repo and run the installer:

```bash
git clone https://github.com/Informat1on/VoiceType.git
cd VoiceType
./install-app.sh
```

Then launch `VoiceType.app` from `~/Applications`, or run:

```bash
open "$HOME/Applications/VoiceType.app"
```

For most people, `./install-app.sh` is the only command that matters.

It will:

1. Build the release app bundle.
2. Generate and embed the app icon.
3. Copy the app to `~/Applications/VoiceType.app`.
4. Register the installed bundle with macOS Launch Services.

After that, the remaining setup is just granting permissions and choosing a model.

## Highlights

- Fast local transcription with `whisper.cpp`
- CoreML acceleration support on Apple Silicon
- Global shortcut with single-press and hold-to-record modes
- English and Russian support, plus auto language detection
- Menu bar workflow with floating recording indicator
- Configurable text insertion, model choice, and recording UI
- Local-first design: audio stays on-device during transcription

## Screenshots

The current UI includes:

- Menu bar workflow with a floating recording indicator
- Refreshed Settings window with grouped controls
- Custom About window with app status and privacy details

Public screenshots can be added here once you export final captures from your Mac.

## Privacy

- Audio is transcribed locally on your Mac.
- VoiceType does not send audio or transcription text to a remote server.
- Whisper models are downloaded from Hugging Face on demand and stored in `~/Library/Application Support/VoiceType/Models/`.
- The app needs Accessibility permission only to simulate paste or typing into the active app.

## Requirements

- macOS 13 or later
- Apple Silicon recommended for the best performance
- Xcode Command Line Tools installed

Install Command Line Tools if needed:

```bash
xcode-select --install
```

## Install From Source

### 1. Clone the repository

```bash
git clone https://github.com/Informat1on/VoiceType.git
cd VoiceType
```

### 2. Build the app bundle

```bash
./build-app.sh
```

This creates a signed app bundle at:

```bash
dist/VoiceType.app
```

### 3. Install it into `~/Applications`

```bash
./install-app.sh
```

This does three things:

1. Builds the app bundle.
2. Copies it to `~/Applications/VoiceType.app`.
3. Registers the installed bundle with Launch Services.

Installing the app into a stable location is important. It helps macOS associate permissions and icons with the app correctly.

Note: local source builds are ad-hoc signed by default. After rebuilding and reinstalling a new bundle, macOS may ask for Microphone or Accessibility permission again.

If you only want one command for local setup, use `./install-app.sh`.

### 4. Launch the app

```bash
open "$HOME/Applications/VoiceType.app"
```

## First Launch Setup

1. Start VoiceType.
2. Trigger recording once to prompt for Microphone access.
3. Open the menu bar item and go to `Settings`.
4. Grant Accessibility in `System Settings -> Privacy & Security -> Accessibility`.
5. Pick your preferred model in `Settings -> Model`.

On first real use, VoiceType may also download the selected Whisper model if it is not already available locally.

## Usage

Default shortcut: `Option + Command + V`

### Single Press mode

1. Press the shortcut once to start recording.
2. Press it again to stop recording.
3. VoiceType transcribes the audio and inserts the text into the active field.

### Hold mode

1. Hold the shortcut to record.
2. Release it to stop recording.
3. VoiceType transcribes the audio and inserts the text into the active field.

## Settings Overview

### Hotkey

- Change the global shortcut
- Switch between single-press and hold mode

### Model

- Choose the transcription model
- Check model and CoreML availability
- Download or remove models

### General

- Select transcription language
- Change recording indicator style
- Choose text insertion mode
- Optionally press Enter after insertion

## Models

Available model presets:

- `tiny`: fastest, lowest accuracy
- `base`: good speed, good quality
- `small-q5_1`: balanced speed and quality
- `small`: higher quality, larger download
- `medium`: best quality, slowest

Approximate model storage sizes are shown directly in the app.

## Updating

If you installed VoiceType from source, update it like this:

```bash
git pull
./install-app.sh
open "$HOME/Applications/VoiceType.app"
```

This will rebuild the app, reinstall it into `~/Applications`, and refresh the registered app bundle used by macOS.

Permission behavior depends on how the app is signed:

- **Developer-signed** (release builds): permissions persist, no reset needed
- **Ad-hoc signed** (local builds from source): macOS may ask you to grant permissions again after reinstalling

## Troubleshooting

### The app appears without an icon in System Settings

This usually happens when macOS permissions were granted to a transient build artifact or to the inner executable instead of the installed `.app` bundle.

Use this flow:

```bash
./install-app.sh
open "$HOME/Applications/VoiceType.app"
```

If you previously granted permissions to an older build inside `.build/`, you can manually reset them:

```bash
./reset-permissions.sh
```

Then relaunch the installed app and grant permissions again.

If you launched `dist/VoiceType.app` before installing, run `./install-app.sh` again so the installed bundle becomes the primary Launch Services entry.

### The shortcut does nothing

- Make sure Accessibility is enabled for VoiceType.
- Check that the chosen shortcut is not being intercepted by another app.
- Re-record the shortcut in `Settings -> Hotkey`.

### Transcription is slow

- Use `base` or `small-q5_1` for better speed.
- Make sure the CoreML encoder is available for the selected model when supported.
- Prefer Apple Silicon hardware for the best performance.

### What do I need to run after cloning?

Usually just this:

```bash
./install-app.sh
open "$HOME/Applications/VoiceType.app"
```

Then:

1. grant Microphone permission,
2. grant Accessibility permission,
3. choose a model in Settings.

## Development

Run in development mode:

```bash
swift run
```

Build release executable only:

```bash
swift build -c release
```

Create the app bundle:

```bash
./build-app.sh
```

Install the app locally:

```bash
./install-app.sh
```

See `DEVELOPMENT.md` for the developer-oriented guide.

## Architecture

```text
Sources/VoiceType/
├── AppDelegate.swift
├── VoiceTypeApp.swift
├── Models/
├── Services/
├── Utilities/
└── Views/
    ├── About/
    ├── MenuBar/
    ├── Recording/
    ├── Settings/
    └── Shared/
```

## Code Signing & Permissions

macOS TCC (Transparency, Consent, Control) binds permissions to the app's code signature.

| Scenario | Signing | Permission behavior |
|----------|---------|-------------------|
| **Download from Releases** | Developer-signed | Permissions persist across updates — grant once |
| **Build from source** | Ad-hoc (default) | macOS may ask for permissions again after reinstalling |
| **Developer with certificate** | Developer-signed | Create `.signing-env` with `SIGN_IDENTITY="..."` to persist permissions |

To use your own developer certificate for local builds:

```bash
# Find your signing identity
security find-identity -v -p codesigning

# Create a local config file (gitignored, never committed)
echo 'SIGN_IDENTITY="Apple Development: your@email.com (TEAMID)"' > .signing-env
```

## License

MIT. See `LICENSE`.
