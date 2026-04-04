#!/bin/sh
# build-dmg.sh — Package a notarized FITS Blaster.app into a DMG.
#
# Requirements:
#   brew install create-dmg
#
# Usage:
#   sh scripts/build-dmg.sh
#
# Place the notarized "FITS Blaster.app" on your Desktop before running.
# The DMG is written to the Desktop as FITS-Blaster-<version>.dmg.

set -e
cd "$(dirname "$0")/.."   # run from project root regardless of where the script is called from

APP_PATH="$HOME/Desktop/FITS Blaster.app"

if [ ! -d "$APP_PATH" ]; then
    echo "ERROR: 'FITS Blaster.app' not found on the Desktop." >&2
    exit 1
fi

# Read version from the app's Info.plist so the filename is always correct.
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP_PATH/Contents/Info.plist")
DMG_NAME="FITS-Blaster-$VERSION.dmg"
DMG_PATH="$HOME/Desktop/$DMG_NAME"

echo "==> Found FITS Blaster $VERSION"
echo "==> Creating $DMG_NAME…"
test -f "$DMG_PATH" && rm "$DMG_PATH"

create-dmg \
    --volname "FITS Blaster Installer" \
    --volicon "resources/Book of Galaxies.icns" \
    --window-pos 200 120 \
    --window-size 800 400 \
    --icon "FITS Blaster.app" 200 185 \
    --app-drop-link 600 185 \
    "$DMG_PATH" \
    "$APP_PATH"

# Stamp the custom icon onto the DMG file itself so Finder shows it before mounting.
ICON_PATH="$(pwd)/resources/Book of Galaxies.icns"
osascript - "$ICON_PATH" "$DMG_PATH" << 'EOF'
use framework "AppKit"
use scripting additions
on run argv
    set iconPath to item 1 of argv
    set dmgPath to item 2 of argv
    set theImage to current application's NSImage's alloc()'s initWithContentsOfFile_(iconPath)
    current application's NSWorkspace's sharedWorkspace()'s setIcon_forFile_options_(theImage, dmgPath, 0)
end run
EOF

echo "==> Done: $DMG_PATH"
