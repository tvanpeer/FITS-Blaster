#!/bin/bash
# build-release.sh -- Full release build: archive -> export -> DMG -> (optional) notarise
#
# Mirrors the GitHub Actions release workflow exactly.
#
# Requirements:
#   Xcode (Developer ID certificate in your login keychain)
#   create-dmg  ->  brew install create-dmg
#
# Usage:
#   bash scripts/build-release.sh               # build + DMG only
#   bash scripts/build-release.sh --notarise    # also notarise and staple
#
# The finished DMG is written to ~/Desktop as FITS-Blaster-<version>.dmg.

set -euo pipefail
cd "$(dirname "$0")/.."   # always run from project root

NOTARISE=false
for arg in "$@"; do
    case "$arg" in
        --notarise|--notarize) NOTARISE=true ;;
    esac
done

PROJECT="FITS Blaster.xcodeproj"
SCHEME="FITS Blaster"
ARCHIVE_PATH="$TMPDIR/FITS Blaster.xcarchive"
EXPORT_PATH="$TMPDIR/FITSBlasterExport"
LOG_PATH="/tmp/xcodebuild.log"

# Step 1: Archive
echo "==> Archiving (this takes a minute)..."
xcodebuild archive \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration Release \
    -archivePath "$ARCHIVE_PATH" \
    ARCHS="arm64 x86_64" \
    ONLY_ACTIVE_ARCH=NO \
    2>&1 | tee "$LOG_PATH"
echo "==> Archive written to $ARCHIVE_PATH"

# Step 2: Export .app
echo "==> Exporting app..."
xcodebuild -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportOptionsPlist ExportOptions.plist \
    -exportPath "$EXPORT_PATH"

APP_PATH="$EXPORT_PATH/FITS Blaster.app"
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" \
    "$APP_PATH/Contents/Info.plist")
DMG_NAME="FITS-Blaster-${VERSION}.dmg"
DMG_PATH="$HOME/Desktop/$DMG_NAME"
echo "==> Exported FITS Blaster $VERSION"

# Step 3: Create DMG
echo "==> Creating $DMG_NAME..."
[ -f "$DMG_PATH" ] && rm "$DMG_PATH"

create-dmg \
    --volname "FITS Blaster Installer" \
    --volicon "resources/Book of Galaxies.icns" \
    --background "resources/installer-background.png" \
    --window-pos 200 120 \
    --window-size 800 400 \
    --icon "FITS Blaster.app" 200 185 \
    --app-drop-link 600 185 \
    "$DMG_PATH" \
    "$APP_PATH"

# Stamp the custom icon onto the DMG so Finder shows it before mounting.
ICON_PATH="$(pwd)/resources/Book of Galaxies.icns"
osascript - "$ICON_PATH" "$DMG_PATH" << 'APPLESCRIPT'
use framework "AppKit"
use scripting additions
on run argv
    set iconPath to item 1 of argv
    set dmgPath to item 2 of argv
    set theImage to current application's NSImage's alloc()'s initWithContentsOfFile_(iconPath)
    current application's NSWorkspace's sharedWorkspace()'s setIcon_forFile_options_(theImage, dmgPath, 0)
end run
APPLESCRIPT

# Step 4: Notarise (optional)
if [ "$NOTARISE" = true ]; then
    TEAM_ID="6GBJ9SAJ6Y"
    echo ""
    echo "==> Notarising..."
    printf "Apple ID (email): "
    read -r APPLE_ID
    printf "App-specific password: "
    read -rs APPLE_PASSWORD
    echo ""

    xcrun notarytool submit "$DMG_PATH" \
        --apple-id "$APPLE_ID" \
        --password "$APPLE_PASSWORD" \
        --team-id "$TEAM_ID" \
        --wait

    xcrun stapler staple "$DMG_PATH"
    echo "==> Notarised and stapled."
fi

echo ""
echo "==> Done: $DMG_PATH"
