#!/bin/bash
# make-dmg.sh — the FITS Blaster installer DMG: the app next to a link to Applications,
# with the background picture and the volume icon. One layout for the release workflow
# and for build-release.sh (step 14e; before, each had its own copy and build-dmg.sh had
# lost the background).
#
# Usage:
#   scripts/make-dmg.sh <app> <dmg>
#
# <app> keeps its name in the DMG ("FITS Blaster.app", or "FITS Blaster Beta.app" for a
# beta). An existing <dmg> is replaced. Requires create-dmg (brew install create-dmg).

set -euo pipefail

if [ $# -ne 2 ]; then
    echo "usage: $0 <app> <dmg>" >&2
    exit 1
fi
APP="$1"
DMG="$2"
REPO="$(cd "$(dirname "$0")/.." && pwd)"

if [ ! -d "$APP" ]; then
    echo "error: '$APP' is not an app" >&2
    exit 1
fi
rm -f "$DMG"

create-dmg \
    --volname "FITS Blaster Installer" \
    --volicon "$REPO/resources/Book of Galaxies.icns" \
    --background "$REPO/resources/installer-background.png" \
    --window-pos 200 120 \
    --window-size 800 400 \
    --icon "$(basename "$APP")" 200 185 \
    --app-drop-link 600 185 \
    "$DMG" \
    "$APP"
