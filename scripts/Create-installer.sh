#!/bin/sh
# Always run from the directory containing this script so relative paths work.
cd "$(dirname "$0")"

DMG_NAME="FITS-Blaster-1.19.6.dmg"

test -f "$DMG_NAME" && rm "$DMG_NAME"

create-dmg \
  --volname "FITS Blaster Installer" \
  --volicon "Book of Galaxies.icns" \
  --window-pos 200 120 \
  --window-size 800 400 \
  --icon "FITS Blaster.app" 200 185 \
  --app-drop-link 600 185 \
  "$DMG_NAME" \
  "bin/FITS Blaster.app"

# Apply the custom icon to the DMG file itself so Finder shows it
# before the DMG is mounted. create-dmg only sets the mounted volume
# icon; this step stamps the Finder icon on the file via NSWorkspace.
ICON_PATH="$(pwd)/Book of Galaxies.icns"
DMG_PATH="$(pwd)/$DMG_NAME"
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

echo "Done: $DMG_NAME"
