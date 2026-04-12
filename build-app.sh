#!/bin/bash
set -euo pipefail

APP_NAME="VoiceType"
DIST_DIR="dist"
APP_DIR="$DIST_DIR/$APP_NAME.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
BUILD_PRODUCTS_DIR="$(swift build -c release --show-bin-path)"
BUILD_TEMP_DIR=".build/voicetype-bundle"
ICON_ART_SOURCE="artwork/image_voice_transparent.png"
ICON_SOURCE="$BUILD_TEMP_DIR/app-icon-cropped.png"
ICONSET_DIR="$BUILD_TEMP_DIR/AppIcon.iconset"
ICON_FILE="$RESOURCES_DIR/$APP_NAME.icns"
LEGACY_APP_DIRS=(
    ".build/release/$APP_NAME.app"
    ".build/arm64-apple-macosx/release/$APP_NAME.app"
)

echo "🔨 Building $APP_NAME..."
for legacy_dir in "${LEGACY_APP_DIRS[@]}"; do
    rm -rf "$legacy_dir"
done

swift build -c release

echo "📦 Creating app bundle..."
rm -rf "$APP_DIR" "$BUILD_TEMP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR" "$BUILD_TEMP_DIR"

if [ -f "$ICON_ART_SOURCE" ]; then
    echo "🎨 Generating app icon..."
    sips -c 760 760 "$ICON_ART_SOURCE" --out "$ICON_SOURCE" >/dev/null
    mkdir -p "$ICONSET_DIR"

    sips -z 16 16 "$ICON_SOURCE" --out "$ICONSET_DIR/icon_16x16.png" >/dev/null
    sips -z 32 32 "$ICON_SOURCE" --out "$ICONSET_DIR/icon_16x16@2x.png" >/dev/null
    sips -z 32 32 "$ICON_SOURCE" --out "$ICONSET_DIR/icon_32x32.png" >/dev/null
    sips -z 64 64 "$ICON_SOURCE" --out "$ICONSET_DIR/icon_32x32@2x.png" >/dev/null
    sips -z 128 128 "$ICON_SOURCE" --out "$ICONSET_DIR/icon_128x128.png" >/dev/null
    sips -z 256 256 "$ICON_SOURCE" --out "$ICONSET_DIR/icon_128x128@2x.png" >/dev/null
    sips -z 256 256 "$ICON_SOURCE" --out "$ICONSET_DIR/icon_256x256.png" >/dev/null
    sips -z 512 512 "$ICON_SOURCE" --out "$ICONSET_DIR/icon_256x256@2x.png" >/dev/null
    sips -z 512 512 "$ICON_SOURCE" --out "$ICONSET_DIR/icon_512x512.png" >/dev/null
    cp "$ICON_SOURCE" "$ICONSET_DIR/icon_512x512@2x.png"

    iconutil -c icns "$ICONSET_DIR" -o "$ICON_FILE"
fi

# Copy executable
cp "$BUILD_PRODUCTS_DIR/$APP_NAME" "$MACOS_DIR/$APP_NAME"

# Create Info.plist
cat > "$CONTENTS_DIR/Info.plist" << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleName</key>
    <string>VoiceType</string>
    <key>CFBundleDisplayName</key>
    <string>VoiceType</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleIdentifier</key>
    <string>com.voicetype.app</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
    <key>CFBundleExecutable</key>
    <string>VoiceType</string>
    <key>CFBundleIconFile</key>
    <string>VoiceType</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleSignature</key>
    <string>????</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>NSMicrophoneUsageDescription</key>
    <string>VoiceType needs access to your microphone to transcribe your voice into text.</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
</dict>
</plist>
EOF

# Create entitlements
cat > "$BUILD_TEMP_DIR/entitlements.plist" << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.device.audio-input</key>
    <true/>
</dict>
</plist>
EOF

# Ad-hoc sign the app
codesign --force --deep --entitlements "$BUILD_TEMP_DIR/entitlements.plist" --sign - "$APP_DIR"

echo "✅ App bundle created at: $APP_DIR"
echo "🚀 Run with: open $APP_DIR"
