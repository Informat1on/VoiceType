# VoiceType Developer Guide

## Project Layout

```text
VoiceType/
├── Package.swift
├── build-app.sh
├── install-app.sh
├── package-dmg.sh
├── release.sh
├── README.md
├── DEVELOPMENT.md
├── DESIGN.md
├── CHANGELOG.md
├── artwork/
└── Sources/VoiceType/
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
- Transcription history is stored at `~/Library/Application Support/VoiceType/history.jsonl`.
- Error logs go to `~/Library/Logs/VoiceType/errors.log`.

## Models

Seven supported models grouped into three presets in the Settings UI:

| Preset (UI) | Model ID | Size | CoreML encoder |
|---|---|---|---|
| Fast | `small-q5_1` | ~190 MB | yes |
| — | `tiny` | ~75 MB | yes |
| — | `base` | ~150 MB | yes |
| — | `small` | ~480 MB | yes |
| — | `medium` | ~1.5 GB | yes |
| Balanced *(default for fresh installs)* | `large-v3-turbo-q5_0` | ~547 MB | yes (shared with full Turbo) |
| Max Quality | `large-v3-turbo` | ~810 MB | yes |

The fresh-install default is `large-v3-turbo-q5_0` (Balanced). Existing users with an explicit selection are not migrated. The Advanced expander in Settings → Models exposes the full list for power users.

## Local Signing

Source builds via `build-app.sh` are ad-hoc signed by default. Because TCC binds permissions to the code signature, ad-hoc rebuilds may re-prompt for Microphone and Accessibility every time you reinstall.

To keep permissions sticky across rebuilds, create `.signing-env` in the project root with your **Apple Development** identity:

```bash
# Find your signing identity
security find-identity -v -p codesigning

# Create local config (gitignored, never committed)
cat > .signing-env <<'EOF'
SIGN_IDENTITY="Apple Development: your@email.com (TEAMID)"
EOF
```

`build-app.sh` and `package-dmg.sh` both source `.signing-env` at the top of the script. Once `SIGN_IDENTITY` is set, every rebuild re-signs the bundle with the same identity and TCC keeps the granted permissions.

Apple Development is fine for local development. For public distribution, you need a different cert — see [Releasing](#releasing).

## Packaging

`build-app.sh`:

1. Builds the release binary with SwiftPM.
2. Generates and embeds `VoiceType.icns` from `artwork/`.
3. Writes the bundle `Info.plist`.
4. Signs the bundle with `SIGN_IDENTITY` from `.signing-env` if set, otherwise ad-hoc.

`install-app.sh` then copies `dist/VoiceType.app` to `~/Applications/VoiceType.app` and registers it with Launch Services.

`package-dmg.sh` wraps `dist/VoiceType.app` into a distributable `.dmg` (compressed UDZO, with `Applications` symlink for drag-install). Also signs the DMG with `SIGN_IDENTITY` if set.

## Releasing

Public releases need:

1. **Developer ID Application** certificate (different from Apple Development — get it from https://developer.apple.com/account/resources/certificates).
2. **Notarization profile** stored in keychain so `notarytool` can submit DMGs to Apple non-interactively.

### One-time setup

Create the notarization profile (asks for an app-specific password from https://appleid.apple.com → App-Specific Passwords):

```bash
xcrun notarytool store-credentials voicetype-notary \
  --apple-id your-apple-id@example.com \
  --team-id TEAMID
```

Update `.signing-env` to use the Developer ID identity and reference the profile:

```bash
SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)"
NOTARY_PROFILE="voicetype-notary"
```

### Cutting a release

`release.sh` orchestrates the full flow. Three modes:

```bash
./release.sh 1.4.0 --prepare   # Build artifacts only — no git, no GitHub
./release.sh 1.4.0 --draft     # Build + commit version bump + tag + push + GitHub draft release
./release.sh 1.4.0 --publish   # Same as --draft, published immediately
```

The script:

1. Updates `VERSION`.
2. Builds `dist/VoiceType.app` (signed with `SIGN_IDENTITY`).
3. Creates `dist/VoiceType-<version>.dmg` (signed with `SIGN_IDENTITY`).
4. Submits the DMG to Apple's notary service, waits for `Accepted`, staples the ticket. Skipped if `NOTARY_PROFILE` is unset or `SKIP_NOTARIZATION=1`.
5. Generates `dist/RELEASE_NOTES-v<version>.md` from git log since the last tag.
6. In `--draft` / `--publish` mode: commits the VERSION bump, creates the tag, pushes branch + tag, creates the GitHub release with the DMG attached.

For `--draft` and `--publish`, the working tree must be clean. The script refuses to release from a dirty tree so unrelated local changes don't ship by accident.

### Dry run without notarization

Useful when iterating on the build/package scripts:

```bash
SKIP_NOTARIZATION=1 ./release.sh 1.4.0 --prepare
```

### Verifying a release DMG

```bash
xcrun stapler validate dist/VoiceType-<version>.dmg
spctl -a -t open --context context:primary-signature -vv dist/VoiceType-<version>.dmg
```

A correctly notarized DMG reports `accepted` and `source=Notarized Developer ID`.

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

The repo also ships `./reset-permissions.sh` which does the same plus a few related caches.

Verify the installed app bundle:

```bash
plutil -p "$HOME/Applications/VoiceType.app/Contents/Info.plist"
codesign --verify --deep --strict --verbose=2 "$HOME/Applications/VoiceType.app"
```

## Manual QA Checklist

- App launches from `~/Applications/VoiceType.app`
- App icon appears in Finder and in System Settings privacy panes
- Menu bar item appears and opens Settings/About
- Microphone permission prompt appears on first record
- Accessibility permission enables text insertion
- Recording starts and stops reliably across repeated runs
- Transcription works in English, Russian, and bilingual RU+EN mode
- Hot reload of model selection in Settings → Models works
- History reinsertion (last 100) restores focus to the original target app
- Settings and About windows render correctly in light and dark mode
- For release builds: DMG passes `xcrun stapler validate` and `spctl --assess`

## Dependency Note

The project uses a fork of `SwiftWhisper` at `https://github.com/Informat1on/SwiftWhisper` (whisper.cpp v1.7.5 with a cherry-picked CoreML scheduler reset fix). Pin lives in `Package.resolved`.
