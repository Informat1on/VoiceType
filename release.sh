#!/bin/bash
set -euo pipefail

usage() {
    cat <<'EOF'
Usage:
  ./release.sh <version> [--prepare|--draft|--publish]

Example:
  ./release.sh 1.0.2 --draft

What it does:
  1. Updates VERSION
  2. Builds VoiceType.app
  3. Creates dist/VoiceType-<version>.dmg
  4. Optionally notarizes and staples the DMG if NOTARY_PROFILE is configured
  5. Generates dist/RELEASE_NOTES-v<version>.md

Modes:
  --prepare  Build artifacts only, do not touch git or GitHub (default)
  --draft    Build artifacts, commit VERSION bump, tag, push, create draft GitHub release
  --publish  Build artifacts, commit VERSION bump, tag, push, create published GitHub release

Optional .signing-env values:
  SIGN_IDENTITY="Developer ID Application: you@example.com (TEAMID)"
  NOTARY_PROFILE="voicetype-notary"

Optional environment override:
  SKIP_NOTARIZATION=1
EOF
}

ensure_clean_worktree() {
    if [ -n "$(git status --porcelain)" ]; then
        echo "Working tree must be clean before --draft or --publish." >&2
        echo "Commit or stash your current changes first." >&2
        exit 1
    fi
}

if [ "${1:-}" = "" ] || [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
    usage
    exit 0
fi

VERSION="$1"
MODE="prepare"

for arg in "${@:2}"; do
    case "$arg" in
        --prepare)
            MODE="prepare"
            ;;
        --draft)
            MODE="draft"
            ;;
        --publish)
            MODE="publish"
            ;;
        *)
            echo "Unknown option: $arg" >&2
            usage
            exit 1
            ;;
    esac
done

APP_NAME="VoiceType"
VERSION_FILE="VERSION"
DIST_DIR="dist"
DMG_FILE="$DIST_DIR/$APP_NAME-$VERSION.dmg"
RELEASE_NOTES_FILE="$DIST_DIR/RELEASE_NOTES-v$VERSION.md"
TAG="v$VERSION"
BRANCH="$(git branch --show-current)"

if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "Version must use semantic versioning, for example: 1.0.2" >&2
    exit 1
fi

if [ -z "$BRANCH" ]; then
    echo "Release script must be run from a checked-out branch." >&2
    exit 1
fi

if git rev-parse "$TAG" >/dev/null 2>&1; then
    echo "Tag $TAG already exists." >&2
    exit 1
fi

if [ "$MODE" != "prepare" ]; then
    ensure_clean_worktree
    gh auth status >/dev/null
fi

if [ -f ".signing-env" ]; then
    # shellcheck source=/dev/null
    source ".signing-env"
fi

mkdir -p "$DIST_DIR"
printf '%s\n' "$VERSION" > "$VERSION_FILE"

echo "📝 Updated $VERSION_FILE to $VERSION"

./build-app.sh
APP_VERSION="$VERSION" ./package-dmg.sh

if [ -n "${NOTARY_PROFILE:-}" ] && [ "${SKIP_NOTARIZATION:-0}" != "1" ]; then
    echo "🛡️ Notarizing $DMG_FILE with profile $NOTARY_PROFILE..."
    xcrun notarytool submit "$DMG_FILE" --keychain-profile "$NOTARY_PROFILE" --wait
    echo "📎 Stapling notarization ticket..."
    xcrun stapler staple "$DMG_FILE"
else
    echo "⚠️ Skipping notarization. Set NOTARY_PROFILE or unset SKIP_NOTARIZATION to enable it."
fi

LAST_TAG="$(git describe --tags --abbrev=0 2>/dev/null || true)"

{
    echo "# VoiceType $TAG"
    echo
    if [ -n "$LAST_TAG" ]; then
        echo "Changes since $LAST_TAG:"
        echo
        git log --reverse --pretty='- %s (%h)' "$LAST_TAG"..HEAD
    else
        echo "Initial public release."
    fi
    echo
    echo "## Install"
    echo
    echo "1. Download \`$(basename "$DMG_FILE")\`."
    echo "2. Open the DMG."
    echo "3. Drag \`VoiceType.app\` into \`Applications\`."
    echo "4. Launch the app and grant Microphone and Accessibility permissions."
} > "$RELEASE_NOTES_FILE"

if [ "$MODE" = "prepare" ]; then
    echo
    echo "✅ Release assets are ready"
    echo "Mode: $MODE"
    echo "Version: $VERSION"
    echo "DMG: $DMG_FILE"
    echo "Notes: $RELEASE_NOTES_FILE"
    echo
    echo "To publish as a draft release:"
    echo "  ./release.sh $VERSION --draft"
    exit 0
fi

git add "$VERSION_FILE"
git commit -m "Release $TAG"
git tag -a "$TAG" -m "Release $TAG"

echo "🚀 Pushing branch $BRANCH and tag $TAG..."
git push origin "$BRANCH"
git push origin "$TAG"

GH_ARGS=(
    "$TAG"
    "$DMG_FILE"
    --title "VoiceType $TAG"
    --notes-file "$RELEASE_NOTES_FILE"
)

if [ "$MODE" = "draft" ]; then
    GH_ARGS+=(--draft)
fi

RELEASE_URL="$(gh release create "${GH_ARGS[@]}")"

echo
echo "✅ Release is ready"
echo "Mode: $MODE"
echo "Version: $VERSION"
echo "DMG: $DMG_FILE"
echo "Notes: $RELEASE_NOTES_FILE"
echo "Git tag: $TAG"
echo "Release URL: $RELEASE_URL"
