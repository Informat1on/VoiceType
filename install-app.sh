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

# Only rebuild if the source app doesn't exist or source files changed
NEEDS_BUILD=false
if [ ! -d "$SOURCE_APP" ]; then
    NEEDS_BUILD=true
elif [ -d "$TARGET_APP" ]; then
    # Check if any .swift file is newer than the installed binary
    TARGET_MTIME=$(stat -f %m "$TARGET_APP/Contents/MacOS/$APP_NAME" 2>/dev/null || echo 0)
    SOURCE_NEWER=$(find Sources -name "*.swift" -newer "$TARGET_APP/Contents/MacOS/$APP_NAME" -type f 2>/dev/null | head -1)
    if [ -n "$SOURCE_NEWER" ]; then
        NEEDS_BUILD=true
    fi
else
    NEEDS_BUILD=true
fi

if [ "$NEEDS_BUILD" = true ]; then
    echo "🔨 Source changed — rebuilding..."
    ./build-app.sh
else
    echo "✅ Build up to date — skipping build (permissions will persist)"
fi

echo "📥 Installing $APP_NAME to $INSTALL_DIR..."
mkdir -p "$INSTALL_DIR"

# Use ditto instead of rm+cp — ditto updates in-place preserving filesystem
# metadata that macOS TCC uses to track the application.
ditto "$SOURCE_APP" "$TARGET_APP"

if [ -x "$LSREGISTER" ]; then
    for legacy_dir in "${LEGACY_APP_DIRS[@]}"; do
        "$LSREGISTER" -u "$legacy_dir" >/dev/null 2>&1 || true
    done

    "$LSREGISTER" -f "$TARGET_APP" >/dev/null 2>&1 || true
fi

echo "✅ Installed at: $TARGET_APP"
echo "🚀 Launch with: open \"$TARGET_APP\""
