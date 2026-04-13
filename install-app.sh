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

echo "📥 Installing $APP_NAME to $INSTALL_DIR..."

# Reset stale TCC entries before copying the new binary.
# macOS TCC (Transparency, Consent, Control) binds Accessibility permissions
# to the code signature hash. Since we use ad-hoc signing (--sign -), the
# hash changes on every rebuild, orphaning the old permission entry.
# Resetting ensures the app will re-prompt on next launch.
tccutil reset Accessibility "$BUNDLE_ID" 2>/dev/null || true
tccutil reset Microphone "$BUNDLE_ID" 2>/dev/null || true

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
