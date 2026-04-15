#!/bin/bash
set -euo pipefail

APP_NAME="VoiceType"
SOURCE_APP="dist/$APP_NAME.app"
INSTALL_DIR="$HOME/Applications"
TARGET_APP="$INSTALL_DIR/$APP_NAME.app"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
LEGACY_APP_DIRS=(
    "$(pwd)/.build/release/$APP_NAME.app"
    "$(pwd)/.build/arm64-apple-macosx/release/$APP_NAME.app"
    "$(pwd)/dist/$APP_NAME.app"
)

echo "🔨 Building fresh app bundle..."
./build-app.sh

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
