#!/bin/bash
# reset-permissions.sh
# Resets Microphone and Accessibility permissions for VoiceType.
# Useful for troubleshooting permission-related issues.

set -e

BUNDLE_ID="com.voicetype.app"

echo "=== VoiceType Permission Reset ==="
echo ""

# Check if VoiceType is running
if pgrep -f "VoiceType" > /dev/null 2>&1; then
    echo "VoiceType is running. Quitting..."
    killall VoiceType 2>/dev/null || true
    sleep 1
fi

echo "Resetting Microphone permission..."
tccutil reset Microphone "$BUNDLE_ID"

echo "Resetting Accessibility permission..."
tccutil reset AppleEvents "$BUNDLE_ID"

echo ""
echo "Permissions reset successfully."
echo ""
echo "Next steps:"
echo "1. Launch VoiceType from ~/Applications/VoiceType.app"
echo "2. Grant Microphone permission when prompted"
echo "3. Grant Accessibility permission when prompted"
echo "   (or go to System Settings → Privacy & Security → Accessibility)"
echo ""
echo "To verify current permissions, run:"
echo "  tccutil reset --list Microphone | grep $BUNDLE_ID"
echo "  tccutil reset --list AppleEvents | grep $BUNDLE_ID"
