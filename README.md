# VoiceType

Lightweight macOS menu bar voice typing app powered by `whisper.cpp` and optimized for Apple Silicon.

![macOS 13+](https://img.shields.io/badge/macOS-13%2B-black?logo=apple)
![Swift 5.9+](https://img.shields.io/badge/Swift-5.9%2B-orange?logo=swift)
![Local First](https://img.shields.io/badge/Privacy-Local%20First-2ea44f)
![License MIT](https://img.shields.io/badge/License-MIT-blue.svg)

VoiceType records audio with a global shortcut, transcribes it locally on your Mac, and inserts the resulting text into the currently focused app.

## Highlights

- **Local-first.** Audio never leaves your machine. No cloud, no tracking.
- **Apple Silicon native.** CoreML-accelerated `whisper.cpp` with `large-v3-turbo` quality on M-series.
- **Three model presets.** Fast, Balanced, Max Quality — pick once, the app handles the rest. Power users get the full 7-model picker in Advanced.
- **Bilingual RU+EN mode.** Code-switched speech (Russian sentences with inline English identifiers) handled reliably via a bilingual seed prompt.
- **Custom vocabulary.** Bias the model toward project names, technical terms, or jargon you actually use.
- **History.** Last 100 transcriptions kept locally; re-insert any of them with one click. Activates the original target app first so the text lands in the right place.
- **Signed and notarized.** Public DMG releases install with a single double-click — no Gatekeeper warnings.

## Install

### Recommended: download the DMG

1. Go to the [Releases page](https://github.com/Informat1on/VoiceType/releases) and download the latest `VoiceType-<version>.dmg`.
2. Open the DMG and drag `VoiceType.app` to your `Applications` folder.
3. Launch the app from Spotlight or Finder.

Releases are signed with an Apple Developer ID and notarized by Apple, so macOS opens them without warnings or right-click workarounds. TCC permissions (Microphone, Accessibility) persist across updates.

### Build from source

You'll need macOS 13+, Apple Silicon (recommended), and Xcode Command Line Tools:

```bash
xcode-select --install
```

Then:

```bash
git clone https://github.com/Informat1on/VoiceType.git
cd VoiceType
./install-app.sh
open "$HOME/Applications/VoiceType.app"
```

`install-app.sh` builds the release binary, creates the app bundle, copies it to `~/Applications/`, and registers it with Launch Services. Source builds are ad-hoc signed by default, so macOS may re-prompt for Microphone and Accessibility permissions after every rebuild. To persist permissions across rebuilds, see [DEVELOPMENT.md](DEVELOPMENT.md#local-signing) for setting up a local `.signing-env`.

## First-time setup

1. Launch VoiceType.
2. Press the recording shortcut once (default: **`Option + Space`**) — macOS prompts for **Microphone** permission. Allow it.
3. Open the menu bar item → **Settings** → **Shortcuts** tab. Click **Open Privacy Settings** and grant **Accessibility** to VoiceType in `System Settings → Privacy & Security → Accessibility`.
4. Open **Settings → Models**. The default preset (Balanced — `large-v3-turbo-q5`, ~547 MB) downloads on first transcription. Wait for the download to complete, or pick **Fast** for a smaller, faster model.

Done. Press the shortcut, speak, release — the text appears in whichever app you're focused on.

## Usage

Default shortcut: **`Option + Space`** (customize in Settings → Shortcuts).

**Single Press mode** — press once to start, press again to stop. Best for longer dictation.

**Hold mode** — hold the shortcut while speaking, release to stop. Best for short, walkie-talkie style insertions.

After you stop, VoiceType transcribes locally and types the result into the active text field of the currently focused app.

## Settings overview

- **General** — language (Auto / RU / EN / RU+EN), recording indicator style, text insertion mode, optional auto-Enter after insert.
- **Models** — three presets (Fast / Balanced / Max Quality) plus an Advanced expander for the full 7-model list. Shows download status, disk usage, and CoreML availability.
- **Shortcuts** — global shortcut recorder, single-press vs hold mode, links to permission panes.
- **Advanced** — Custom Vocabulary, transcription history, eval collector hotkey for capturing problem cases.

## Models

Three presets cover almost everyone:

| Preset | Model | Size | Notes |
|---|---|---|---|
| **Fast** | `small-q5_1` | ~190 MB | Lowest latency. Decent on common English; weaker on Russian and identifiers. |
| **Balanced** *(Recommended)* | `large-v3-turbo-q5_0` | ~547 MB | Quality of full Turbo at ~⅓ the disk size. Default for fresh installs. |
| **Max Quality** | `large-v3-turbo` | ~810 MB | Top quality, slightly slower than Balanced on M-series. |

Power users can pick any of the seven supported models (`tiny`, `base`, `small-q5_1`, `small`, `medium`, `large-v3-turbo-q5_0`, `large-v3-turbo`) from the **Advanced** expander in Settings → Models. Models are downloaded from Hugging Face on demand and stored in `~/Library/Application Support/VoiceType/Models/`.

CoreML encoder bundles are downloaded alongside the GGML weights when available, giving a noticeable speed-up on Apple Silicon.

## Custom Vocabulary

Settings → Advanced → **Custom Vocabulary** lets you bias the speech model toward words it commonly mishears — technical terms, project names, your own jargon. The text is passed as Whisper's `initial_prompt` parameter on every transcription.

It is **not** a find-replace dictionary. It nudges the decoder; it does not guarantee replacement.

### Example

```
Sonnet, Codex, Claude, GitHub, server.js, react-query, useQuery, ffmpeg,
Whisper, TranscriptionService, MenuBarView, AppSettings, AVAudioRecorder
```

Use any separators — Whisper consumes the whole string as context. Keep it under ~200 characters; Whisper's `initial_prompt` cap is 224 tokens and earlier terms get truncated past that.

### Bilingual mode

When language is set to **RU+EN**, VoiceType prepends a short bilingual seed prompt (a few mixed Russian/English sentences) ahead of your custom vocabulary. This stabilizes code-switched speech where Russian sentences carry inline English code identifiers — the common case when dictating commit messages, comments, or chat.

### What it does NOT do

If you want guaranteed text replacement (e.g. "always write `server.js` even if Whisper outputs `сервер точка джейэс`"), that's a separate feature called a replacement dictionary. Not yet implemented in VoiceType — on the roadmap, will live alongside Custom Vocabulary, not replace it.

## Privacy

- Audio is transcribed locally on your Mac.
- VoiceType does not send audio or transcription text to a remote server.
- Whisper models are downloaded from Hugging Face on first use of each model and cached at `~/Library/Application Support/VoiceType/Models/`.
- Transcription history is stored locally at `~/Library/Application Support/VoiceType/history.jsonl` (last 100 entries, rolling).
- Error logs go to `~/Library/Logs/VoiceType/errors.log`.
- Accessibility permission is used only to simulate paste/typing into the active app.

## Updating

**DMG install:** download the latest DMG from Releases and drag the new `VoiceType.app` over the existing one in `Applications`. Permissions persist (signed builds keep the same TCC identity across versions).

**Source install:** rebuild with `./install-app.sh`. Because source builds are ad-hoc signed by default, macOS may re-prompt for Microphone/Accessibility after a rebuild. See [DEVELOPMENT.md](DEVELOPMENT.md#local-signing) for keeping permissions sticky on local builds.

## Troubleshooting

### The shortcut does nothing

- Check Accessibility is granted: `System Settings → Privacy & Security → Accessibility` → VoiceType is enabled.
- Check the shortcut isn't intercepted by another app (Spotlight, Raycast, third-party shortcut managers).
- Re-record the shortcut in `Settings → Shortcuts`.

### App appears without an icon in System Settings

Permissions were probably granted to a transient build artifact. Run:

```bash
./install-app.sh
open "$HOME/Applications/VoiceType.app"
```

If you previously granted permissions to a `.build/` binary, reset and re-grant:

```bash
./reset-permissions.sh
```

### Transcription is slow

- Switch to **Fast** preset (`small-q5_1`).
- Make sure CoreML is available for the selected model (Settings → Models shows status per model).
- Apple Silicon is strongly recommended; Intel Macs run noticeably slower.

### Microphone or Accessibility prompts keep coming back after rebuilds

You're on a source build. Set up a local `.signing-env` with your own Apple Development cert — see [DEVELOPMENT.md](DEVELOPMENT.md#local-signing).

## Development

See [DEVELOPMENT.md](DEVELOPMENT.md) for the developer guide: project layout, local build commands, signing/notarization setup, release pipeline, and manual QA checklist.

Quick start:

```bash
swift run                # Run in development mode
swift build -c release   # Build release binary
./build-app.sh           # Create dist/VoiceType.app
./install-app.sh         # Install to ~/Applications
```

## License

MIT. See `LICENSE`.
