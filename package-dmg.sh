#!/bin/bash
set -euo pipefail

# package-dmg.sh — Creates a distributable .dmg from the built .app
# Usage: ./package-dmg.sh
# The resulting .dmg is placed in dist/VoiceType.dmg

APP_NAME="VoiceType"
DIST_DIR="dist"
APP_DIR="$DIST_DIR/$APP_NAME.app"
DMG_FILE="$DIST_DIR/$APP_NAME.dmg"
DMG_TEMP_DIR="$DIST_DIR/.dmg-build"

# Build first if app doesn't exist
if [ ! -d "$APP_DIR" ]; then
    echo "🔨 Building $APP_NAME first..."
    ./build-app.sh
fi

echo "📦 Creating .dmg..."
rm -rf "$DMG_TEMP_DIR" "$DMG_FILE"
mkdir -p "$DMG_TEMP_DIR"

# Copy app into temp directory
cp -R "$APP_DIR" "$DMG_TEMP_DIR/"

# Create symlink to Applications folder (standard macOS pattern)
ln -s /Applications "$DMG_TEMP_DIR/Applications"

# Create .dmg with standard macOS layout
echo "Creating disk image..."
hdiutil create \
    -volname "$APP_NAME" \
    -srcfolder "$DMG_TEMP_DIR" \
    -ov \
    -format UDZO \
    -fs HFS+ \
    -size 200m \
    "$DMG_FILE" 2>/dev/null

# Clean up temp
rm -rf "$DMG_TEMP_DIR"

# Show signing info
echo ""
echo "📋 Signing info:"
codesign -dv "$APP_DIR" 2>&1 | grep -E "Authority|TeamIdentifier" | head -3

echo ""
echo "✅ DMG created at: $DMG_FILE"
echo "📏 Size: $(du -h "$DMG_FILE" | cut -f1)"
