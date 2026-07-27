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
APP_VERSION="${APP_VERSION:-$(tr -d '[:space:]' < VERSION)}"
APP_BUILD_VERSION="${APP_BUILD_VERSION:-$APP_VERSION}"
LEGACY_APP_DIRS=(
    ".build/release/$APP_NAME.app"
    ".build/arm64-apple-macosx/release/$APP_NAME.app"
)

echo "🔨 Building $APP_NAME $APP_VERSION..."
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

# Copy SwiftPM resource bundles.  Without them the app is missing the Geist fonts
# (VoiceType_VoiceType.bundle) and — more importantly — ggml-metal.metal
# (SwiftWhisper_whisper_metal.bundle), in which case ggml cannot compile the Metal
# shader at runtime and whisper silently falls back to the CPU backend.
#
# Their *contents* are flattened into Contents/Resources rather than copied as
# nested .bundle directories, for two reasons:
#   * the resource accessors SwiftPM generates look for
#     Bundle.main.bundleURL/<Name>.bundle — i.e. the bundle root, next to
#     Contents/ — and codesign rejects that with "unsealed contents present in
#     the bundle root";
#   * flat Contents/Resources is what Bundle.main.url(forResource:) and ggml's
#     GGML_METAL_PATH_RESOURCES both expect (see AppDelegate.configureGGMLResourcePath).
for bundle in "$BUILD_PRODUCTS_DIR"/*.bundle; do
    [ -e "$bundle" ] || continue
    find "$bundle" -type f -exec cp {} "$RESOURCES_DIR/" \;
    echo "   • $(basename "$bundle") → Contents/Resources"
done

# Fail loudly rather than shipping a build that silently loses the GPU or the fonts.
# A dangling symlink also lands here: -f follows the link.
METAL_SHADER="$RESOURCES_DIR/ggml-metal.metal"
if [ ! -f "$METAL_SHADER" ]; then
    echo "❌ ggml-metal.metal missing or dangling at $METAL_SHADER — Metal backend would fall back to CPU" >&2
    exit 1
fi

# The shipped shader must be self-contained: the runtime Metal compiler has no
# include search path, so a leftover local #include means a CPU fallback.
if grep -qE '^[[:space:]]*#include[[:space:]]*"' "$METAL_SHADER"; then
    echo "❌ $METAL_SHADER still has local #include directives — regenerate it with the fork's scripts/sync-metal-shader.sh" >&2
    exit 1
fi

FONT_COUNT=$(find "$RESOURCES_DIR" -maxdepth 1 -name "*.ttf" | wc -l | tr -d ' ')
if [ "$FONT_COUNT" -ne 6 ]; then
    echo "❌ Expected 6 Geist TTFs in Contents/Resources, found $FONT_COUNT" >&2
    exit 1
fi

# --- Metal shader library precompilation ------------------------------------
#
# Without this, ggml compiles ggml-metal.metal at runtime on first launch —
# measured ~5.8s on a cold Metal shader compiler cache (see report for the
# repeated measurement). Precompiling default.metallib here moves that cost to
# build time.
#
# Source: the already-validated, already-#include-free copy at $METAL_SHADER
# (Contents/Resources/ggml-metal.metal, flattened from the SwiftPM bundle
# above) rather than the fork's Sources/whisper_metal/ggml-metal.metal —
# using the in-bundle copy means this step has no dependency on the SwiftWhisper
# checkout living at any particular sibling path, and it's the exact source
# this same script already verified is self-contained.
#
# Built WITHOUT feature macros — upstream's own recipe (ggml/src/ggml-metal/
# CMakeLists.txt:94-96) — because GGML_METAL_HAS_TENSOR does not add kernels,
# it swaps 7 existing kernels between a Metal-4-tensor implementation and a
# simdgroup one, and the runtime picks dispatch geometry from a live
# has_tensor probe (ggml-metal-device.cpp:698) independent of which one was
# actually compiled in. One library cannot correctly serve both an M5 (tensor)
# and an M1-M4 (simdgroup) device, so we ship the simdgroup build for
# everyone and force has_tensor off at runtime instead
# (AppDelegate.configureGGMLResourcePath sets GGML_METAL_TENSOR_DISABLE) so the
# shipped library and the runtime's dispatch choice always agree.
#
# -mmacosx-version-min=13.0 matches Info.plist's LSMinimumSystemVersion above:
# without it the AIR bytecode inherits the build machine's SDK deployment
# target (e.g. 26.5) and may refuse to load on older macOS.
#
# Placed here — after resource copy, before Info.plist/signing — so the file
# exists before codesign seals the bundle; a file added after signing would
# make codesign --verify fail.
#
# Graceful skip (not a hard failure) when the Metal Toolchain isn't installed:
# ggml-metal.metal stays in Contents/Resources as the runtime-compile fallback
# (checked above), so a release build must still succeed on a machine that
# never ran `xcodebuild -downloadComponent MetalToolchain`.
METALLIB_BUILT=0
if command -v xcrun >/dev/null 2>&1 \
    && xcrun -sdk macosx metal --version >/dev/null 2>&1 \
    && xcrun -sdk macosx metallib --version >/dev/null 2>&1; then
    echo "⚙️  Precompiling default.metallib..."
    if xcrun -sdk macosx metal -O3 -mmacosx-version-min=13.0 -c "$METAL_SHADER" -o - \
        | xcrun -sdk macosx metallib - -o "$MACOS_DIR/default.metallib"; then
        METALLIB_BUILT=1
        echo "   • default.metallib → Contents/MacOS ($(du -h "$MACOS_DIR/default.metallib" | cut -f1 | tr -d ' '))"
    else
        echo "⚠️  default.metallib compilation failed — shipping ggml-metal.metal only (runtime compile, ~5.8s cold start)" >&2
        rm -f "$MACOS_DIR/default.metallib"
    fi
else
    echo "⚠️  Metal Toolchain not found (xcrun metal/metallib unavailable) — shipping ggml-metal.metal only (runtime compile, ~5.8s cold start)"
fi

# Create Info.plist
cat > "$CONTENTS_DIR/Info.plist" << EOF
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
    <string>$APP_BUILD_VERSION</string>
    <key>CFBundleShortVersionString</key>
    <string>$APP_VERSION</string>
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

# Sign the app
# For open-source: default is ad-hoc signing (no secrets in repo)
# For personal/dev: create a .signing-env file in the project root with:
#   SIGN_IDENTITY="Apple Development: your@email.com (TEAMID)"
# For user-facing releases, prefer:
#   SIGN_IDENTITY="Developer ID Application: your@email.com (TEAMID)"
# This file is .gitignored and will not appear in the repository.
# For release builds: the CI or maintainer sets SIGN_IDENTITY before building

# Load local signing config if present
if [ -f ".signing-env" ]; then
    # shellcheck source=/dev/null
    source ".signing-env"
fi

if [ -n "${SIGN_IDENTITY:-}" ]; then
    echo "🔏 Signing with developer identity: $SIGN_IDENTITY"
    codesign --force --deep --entitlements "$BUILD_TEMP_DIR/entitlements.plist" --sign "$SIGN_IDENTITY" --options runtime "$APP_DIR"
else
    echo "🔏 Signing with ad-hoc identity (set SIGN_IDENTITY for dev signing)"
    codesign --force --deep --entitlements "$BUILD_TEMP_DIR/entitlements.plist" --sign - "$APP_DIR"
fi

# Never report success for an artifact that would be rejected at launch — e.g. if
# anything touched the bundle between the copy step and codesign.
if ! codesign --verify --deep --strict "$APP_DIR"; then
    echo "❌ codesign --verify --deep --strict failed for $APP_DIR" >&2
    exit 1
fi

# --- Self-containment check -------------------------------------------------
#
# The generated SwiftPM resource accessors carry an absolute fallback path into
# *this machine's* .build directory. That fallback makes a badly packaged .app
# look healthy on the build machine and only on the build machine: it loads
# ggml-metal.metal out of .build instead of out of itself.
#
# That is not hypothetical. On 2026-07-26 the installed /Applications copy had
# nothing but an icon in Contents/Resources and had been running off .build for
# who knows how long. It kept working until a dependency bump rewrote the file
# in .build, and then it died at launch with
# "computeFunction must not be nil" — a crash with no obvious link to packaging.
#
# So: hide the .build bundles, actually launch the binary, and require it to
# report a resource path *inside* the .app. Checking that the files exist is not
# enough — that check passed the whole time the installed copy was broken.
echo "🧪 Verifying the bundle does not depend on .build..."
HIDDEN_BUNDLES=()
for bundle in "$BUILD_PRODUCTS_DIR"/*.bundle; do
    [ -e "$bundle" ] || continue
    mv "$bundle" "$bundle.selfcheck-hidden"
    HIDDEN_BUNDLES+=("$bundle")
done

restore_hidden_bundles() {
    for bundle in "${HIDDEN_BUNDLES[@]:-}"; do
        [ -e "$bundle.selfcheck-hidden" ] && mv "$bundle.selfcheck-hidden" "$bundle"
    done
}
trap restore_hidden_bundles EXIT

SELFCHECK_LOG="$BUILD_TEMP_DIR/selfcheck.log"
"$MACOS_DIR/$APP_NAME" > "$SELFCHECK_LOG" 2>&1 &
SELFCHECK_PID=$!
# Long enough to load a model and initialise Metal on a cold shader cache.
sleep 30
if kill -0 "$SELFCHECK_PID" 2>/dev/null; then
    kill "$SELFCHECK_PID" 2>/dev/null || true
    wait "$SELFCHECK_PID" 2>/dev/null || true
else
    # A background menu-bar app (LSUIElement) has no reason to exit on its own —
    # if it's already gone, that's a crash, not a clean shutdown.
    echo "⚠️  App process had already exited before the self-check timeout — possible crash, see $SELFCHECK_LOG" >&2
fi

restore_hidden_bundles
trap - EXIT

# Error check MUST run before the path-resolution check below: a broken
# default.metallib still logs "loading '.../default.metallib'" right before it
# fails (ggml-metal-device.m:172-181 does NOT fall back to compiling from
# source on failure — a broken/incompatible library kills Metal outright), so
# checking the positive marker first would print a false "loaded fine" line
# ahead of catching the real failure. Verified live: a deliberately corrupted
# default.metallib produces exactly "failed to create library" +
# "failed to initialize the Metal library" here, with no other symptom before
# the process later aborts trying to schedule a graph on the dead backend.
#
# Real ggml v1.9.1 error strings (the previous three — "metal library is nil",
# "failed to initialize Metal backend", "computeFunction must not be nil" —
# do not exist in this submodule version and would never fire):
#   ggml-metal-device.m:863  "failed to create library"        (library load/compile failed)
#   ggml-metal-device.m:405  "failed to compile pipeline"       (a kernel failed to build)
#   ggml-metal-context.m:120 "failed to initialize the Metal library"
if grep -qE "failed to create library|failed to compile pipeline|failed to initialize the Metal library" "$SELFCHECK_LOG"; then
    echo "❌ Metal backend failed to initialise without .build present." >&2
    echo "   See $SELFCHECK_LOG" >&2
    exit 1
fi

# ggml v1.9.1 resolves the Metal shader library one of two ways, and this
# check must recognise whichever one this build actually took:
#   * default.metallib built above → loaded via newLibraryWithURL, which logs
#     "loading '<path ending in default.metallib>'" (ggml-metal-device.m:175).
#   * no default.metallib → compiled from source, which logs
#     "GGML_METAL_PATH_RESOURCES = <path>" (ggml-metal-device.m:188) — the
#     invariant the old version of this check already relied on.
if [ "$METALLIB_BUILT" -eq 1 ]; then
    if grep -qE "loading '.*default\.metallib'" "$SELFCHECK_LOG"; then
        echo "   • Metal loaded the precompiled default.metallib from inside the .app"
    else
        echo "❌ default.metallib was built into the bundle but the app did not load it from there." >&2
        echo "   See $SELFCHECK_LOG" >&2
        exit 1
    fi
else
    if grep -q "GGML_METAL_PATH_RESOURCES = $(cd "$RESOURCES_DIR" && pwd)" "$SELFCHECK_LOG"; then
        echo "   • Metal resources resolved inside the .app (compiled from source — no default.metallib)"
    else
        echo "❌ The app did not load its Metal resources from inside the bundle." >&2
        echo "   Expected GGML_METAL_PATH_RESOURCES = $(cd "$RESOURCES_DIR" && pwd)" >&2
        echo "   See $SELFCHECK_LOG" >&2
        exit 1
    fi
fi
# "loaded in %.3f sec" (ggml-metal-device.m:249) only prints once
# ggml_metal_library_init reaches the end with a non-nil MTLLibrary — i.e. it
# is proof the library actually came up, not just that no error string
# happened to appear.
if ! grep -q "loaded in" "$SELFCHECK_LOG"; then
    echo "❌ No 'loaded in ... sec' line — the Metal library never finished initialising." >&2
    echo "   See $SELFCHECK_LOG" >&2
    exit 1
fi
echo "   • Metal backend initialised standalone"

echo "✅ App bundle created at: $APP_DIR"

# --- Optional install -------------------------------------------------------
#
# Offered here because the failure above was caused by a *stale install*, not by
# a bad build: dist/ was fine while /Applications held a months-old copy with the
# packaging bug. Building and installing in one step keeps the two from drifting.
if [ "${1:-}" = "--install" ]; then
    INSTALL_PATH="/Applications/$APP_NAME.app"
    echo "📥 Installing to $INSTALL_PATH..."
    pkill -f "$INSTALL_PATH/Contents/MacOS/$APP_NAME" 2>/dev/null || true
    sleep 1
    rm -rf "$INSTALL_PATH"
    cp -R "$APP_DIR" "$INSTALL_PATH"
    if ! codesign --verify --deep --strict "$INSTALL_PATH"; then
        echo "❌ codesign --verify failed for the installed copy" >&2
        exit 1
    fi
    echo "✅ Installed. Launch with: open $INSTALL_PATH"
else
    echo "🚀 Run with: open $APP_DIR"
    echo "📥 Install with: ./build-app.sh --install"
fi
