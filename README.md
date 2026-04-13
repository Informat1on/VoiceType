# VoiceType

Lightweight macOS menu bar voice typing app powered by `whisper.cpp` and optimized for Apple Silicon.

![macOS 13+](https://img.shields.io/badge/macOS-13%2B-black?logo=apple)
![Swift 5.9+](https://img.shields.io/badge/Swift-5.9%2B-orange?logo=swift)
![Local First](https://img.shields.io/badge/Privacy-Local%20First-2ea44f)
![License MIT](https://img.shields.io/badge/License-MIT-blue.svg)

VoiceType records audio with a global shortcut, transcribes it locally on your Mac, and inserts the resulting text into the currently focused app.

## Installation

### Option 1: Download a release (recommended)

Go to the [Releases page](https://github.com/Informat1on/VoiceType/releases), download `VoiceType.dmg`, open it, and drag `VoiceType.app` to your `Applications` folder.

This build is developer-signed — TCC permissions (Microphone, Accessibility) will persist across app updates. You only grant them once.

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

Note: local source builds are ad-hoc signed by default. After rebuilding and reinstalling a new bundle, macOS may ask for Microphone or Accessibility permission again. The installer automatically handles this by resetting stale TCC entries before installing.

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

The installer automatically detects the signing type and handles permissions:

- **Developer-signed** (release builds): permissions persist, no reset needed
- **Ad-hoc signed** (local builds from source): stale TCC entries are reset automatically, and macOS will re-prompt on next launch

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
| **Build from source** | Ad-hoc (default) | Installer auto-resets stale entries, re-prompts on launch |
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
