#!/bin/bash
set -euo pipefail

APP_NAME="VoiceType"
BUNDLE_ID="com.voicetype.app"
SOURCE_APP="dist/$APP_NAME.app"
INSTALL_DIR="$HOME/Applications"
TARGET_APP="$INSTALL_DIR/$APP_NAME.app"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
LEGACY_APP_DIRS=(
    "$(pwd)/.build/release/$APP_NAME.app"
    "$(pwd)/.build/arm64-apple-macosx/release/$APP_NAME.app"
    "$(pwd)/dist/$APP_NAME.app"
)

./build-app.sh

# Detect signing identity to determine if TCC reset is needed
SIGNING_TEAM_ID=$(codesign -dv "$SOURCE_APP" 2>&1 | grep "TeamIdentifier=" | cut -d= -f2)

if [ -z "$SIGNING_TEAM_ID" ]; then
    # Ad-hoc signed: TCC permissions are bound to binary hash, which changes on every rebuild
    echo "♻️  Ad-hoc signed build detected — resetting stale TCC entries..."
    tccutil reset Accessibility "$BUNDLE_ID" 2>/dev/null || true
    tccutil reset Microphone "$BUNDLE_ID" 2>/dev/null || true
    echo ""
else
    # Developer signed: TCC permissions are bound to Team ID, which persists across rebuilds
    echo "🔏 Developer signed (Team ID: $SIGNING_TEAM_ID) — permissions will persist across rebuilds"
fi

echo "📥 Installing $APP_NAME to $INSTALL_DIR..."
mkdir -p "$INSTALL_DIR"
rm -rf "$TARGET_APP"
cp -R "$SOURCE_APP" "$TARGET_APP"

if [ -x "$LSREGISTER" ]; then
    for legacy_dir in "${LEGACY_APP_DIRS[@]}"; do
        "$LSREGISTER" -u "$legacy_dir" >/dev/null 2>&1 || true
    done

    "$LSREGISTER" -f "$TARGET_APP" >/dev/null 2>&1 || true
fi

echo "✅ Installed at: $TARGET_APP"
echo "🚀 Launch with: open \"$TARGET_APP\""
