#!/bin/bash
# install-app.sh — fresh install pipeline for iterative development.
#
# What it does:
#   1. Kills any running VoiceType process (so we never test stale binary)
#   2. Removes /Applications + ~/Applications copies (avoids old version lurking)
#   3. Builds dist/VoiceType.app via build-app.sh (or skip with --no-build)
#   4. Copies to /Applications and registers with LaunchServices
#   5. Verifies the installed version, then opens the fresh app
#
# Usage:
#   ./install-app.sh             # full pipeline: kill → build → install → open
#   ./install-app.sh --no-build  # skip build, install whatever is in dist/
#   ./install-app.sh --no-open   # install but do not launch (CI-friendly)
#
# After this script, you can be 100% sure /Applications/VoiceType.app is the
# latest code, and any running window is the fresh build (not a stale process).
set -euo pipefail

APP_NAME="VoiceType"
SOURCE_APP="dist/$APP_NAME.app"
INSTALL_DIR="/Applications"
USER_INSTALL_DIR="$HOME/Applications"
TARGET_APP="$INSTALL_DIR/$APP_NAME.app"
USER_TARGET_APP="$USER_INSTALL_DIR/$APP_NAME.app"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
LEGACY_APP_DIRS=(
    "$(pwd)/.build/release/$APP_NAME.app"
    "$(pwd)/.build/arm64-apple-macosx/release/$APP_NAME.app"
    "$USER_TARGET_APP"
)

# ---------------------------------------------------------------------------
# Args
# ---------------------------------------------------------------------------
DO_BUILD=1
DO_OPEN=1
for arg in "$@"; do
    case "$arg" in
        --no-build) DO_BUILD=0 ;;
        --no-open)  DO_OPEN=0 ;;
        -h|--help)
            grep '^#' "$0" | sed 's/^# \{0,1\}//' | head -20
            exit 0
            ;;
        *) echo "Unknown arg: $arg" >&2; exit 1 ;;
    esac
done

# ---------------------------------------------------------------------------
# Step 1: kill any running VoiceType process
# ---------------------------------------------------------------------------
echo "🛑 Stopping any running $APP_NAME process..."
osascript -e "tell application \"$APP_NAME\" to quit" >/dev/null 2>&1 || true
pkill -9 -f "$APP_NAME.app/Contents/MacOS/$APP_NAME" 2>/dev/null || true
sleep 0.5

# ---------------------------------------------------------------------------
# Step 2: clean old install copies (both /Applications and ~/Applications)
# ---------------------------------------------------------------------------
echo "🧹 Removing old installations..."
[ -d "$TARGET_APP" ]      && rm -rf "$TARGET_APP"
[ -d "$USER_TARGET_APP" ] && rm -rf "$USER_TARGET_APP"

# ---------------------------------------------------------------------------
# Step 3: build (unless --no-build)
# ---------------------------------------------------------------------------
if [ "$DO_BUILD" = "1" ]; then
    echo "🔨 Building fresh app bundle..."
    ./build-app.sh
else
    echo "⏭️  Skipping build (--no-build). Using existing $SOURCE_APP."
fi

if [ ! -d "$SOURCE_APP" ]; then
    echo "❌ $SOURCE_APP not found. Run without --no-build to compile." >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Step 4: install to /Applications + register with LaunchServices
# ---------------------------------------------------------------------------
echo "📥 Installing to $INSTALL_DIR..."
cp -R "$SOURCE_APP" "$TARGET_APP"

if [ -x "$LSREGISTER" ]; then
    # Unregister stale paths (build dir, user-Applications, anywhere)
    for legacy in "${LEGACY_APP_DIRS[@]}"; do
        "$LSREGISTER" -u "$legacy" >/dev/null 2>&1 || true
    done
    # Force-register the new bundle
    "$LSREGISTER" -f "$TARGET_APP" >/dev/null 2>&1 || true
fi

# ---------------------------------------------------------------------------
# Step 5: verify + open
# ---------------------------------------------------------------------------
INSTALLED_VERSION=$(defaults read "$TARGET_APP/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null || echo "?")
INSTALLED_BUILD=$(stat -f '%Sm' -t '%Y-%m-%d %H:%M:%S' "$TARGET_APP/Contents/MacOS/$APP_NAME" 2>/dev/null || echo "?")

echo ""
echo "✅ Installed:"
echo "   Path:    $TARGET_APP"
echo "   Version: $INSTALLED_VERSION"
echo "   Built:   $INSTALLED_BUILD"
echo ""

if [ "$DO_OPEN" = "1" ]; then
    echo "🚀 Launching $APP_NAME..."
    open "$TARGET_APP"
else
    echo "ℹ️  Skipping launch (--no-open). Open with: open \"$TARGET_APP\""
fi
