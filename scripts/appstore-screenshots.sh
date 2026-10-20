#!/usr/bin/env bash
# appstore-screenshots.sh — Mac App Store screenshots of FITS Blaster at an exact 16:10 size.
#
# Window mode (default): sets the FITS Blaster main window to 1440 × 900 points, centred on
# the main screen, and captures exactly that area each time you press Enter. On a Retina
# screen that gives 2880 × 1800 pixels, the largest size App Store Connect accepts.
# Because it captures an area and not a window, popovers, sheets and the Settings window
# are included when they are inside that area.
#
# Full-screen mode (--fullscreen): put FITS Blaster in full screen (⌃⌘F) first. Each capture
# is the whole main screen, scaled to 2880 × 1800. The main screen must be 16:10, so
# nothing is cropped or stretched. Gives the app more room than the 1440 × 900 window.
#
# Each capture is saved without an alpha channel, which App Store Connect can refuse
# (appstore-flatten.swift; colour profile unchanged).
#
# Run it in Terminal (it waits for your key presses). The first time, macOS asks to let
# Terminal control the computer (Accessibility), which is needed to size the window.
#
# Usage:
#   scripts/appstore-screenshots.sh [--fullscreen] [output folder]
#     default folder: ~/Pictures/FITS Blaster App Store/<date>
#   DELAY=8 scripts/appstore-screenshots.sh    a longer countdown (default 5 seconds)
#
# Keys while it runs:
#   Enter    bring FITS Blaster to the front, count down, then capture the next
#            screenshot (01.png, 02.png, …). Open a popover or menu during the countdown;
#            it closes when you switch to Terminal.
#   f Enter  fit the main window again (window mode; make it the front window first)
#   q Enter  quit
#
# Tips:
#   - Use the App Store build for the real set: the direct build shows Check for Updates
#     and the Software Updates settings, which the App Store version doesn't have.
#   - Window mode: the window's rounded corners show a little of the desktop; a black or
#     dark grey wallpaper (System Settings → Wallpaper → Colours) keeps them invisible.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP="FITS Blaster"
WIDTH=1440            # window mode, points
HEIGHT=900
SHOT_W=2880           # full-screen mode, output pixels
SHOT_H=1800
DELAY="${DELAY:-5}"   # countdown in seconds before each capture
FULLSCREEN=0
[[ "${1:-}" == "--fullscreen" ]] && { FULLSCREEN=1; shift; }
OUT="${1:-$HOME/Pictures/FITS Blaster App Store/$(date +%Y-%m-%d)}"

# Main screen (the one with the menu bar) in points, and the top-left corner that centres
# the window on it, in the global coordinates that both System Events and screencapture use.
read -r SCREEN_W SCREEN_H X Y < <(osascript -l JavaScript -e "
    ObjC.import('AppKit');
    const f = \$.NSScreen.screens.objectAtIndex(0).frame;
    const vf = \$.NSScreen.screens.objectAtIndex(0).visibleFrame;
    const menuBar = f.size.height - vf.size.height - vf.origin.y;
    const x = Math.round((f.size.width - $WIDTH) / 2);
    const y = Math.max(menuBar, Math.round((f.size.height - $HEIGHT) / 2));
    [f.size.width, f.size.height, x, y].join(' ');")

fit_window() {
    osascript >/dev/null <<EOF
tell application "System Events" to tell process "$APP"
    set frontmost to true
    set position of window 1 to {$X, $Y}
    set size of window 1 to {$WIDTH, $HEIGHT}
end tell
EOF
    local got
    got="$(osascript -e "tell application \"System Events\" to tell process \"$APP\" to get {position, size} of window 1" | tr -d ' ')"
    if [[ "$got" != "$X,$Y,$WIDTH,$HEIGHT" ]]; then
        echo "⚠️  The window is at $got (position, size) instead of $X,$Y,$WIDTH,$HEIGHT."
        echo "    Make the main window the front window, or make it smaller first, and press f."
        return 1
    fi
    echo "Main window: ${WIDTH} × ${HEIGHT} points at ($X, $Y)."
}

if ! pgrep -xq "$APP"; then
    echo "Start $APP first." >&2
    exit 1
fi
if [[ $FULLSCREEN == 1 ]] && (( SCREEN_W * 10 != SCREEN_H * 16 )); then
    echo "The main screen is $SCREEN_W × $SCREEN_H points, not 16:10; use window mode." >&2
    exit 1
fi

mkdir -p "$OUT"

# Compile the flatten helper once per run (swift script mode takes several seconds per file).
FLATTEN="$(mktemp -d)/appstore-flatten"
trap 'rm -rf "$(dirname "$FLATTEN")"' EXIT
xcrun swiftc -O -o "$FLATTEN" "$SCRIPT_DIR/appstore-flatten.swift"

if [[ $FULLSCREEN == 1 ]]; then
    echo "Full-screen mode: whole main screen ($SCREEN_W × $SCREEN_H points) → $SHOT_W × $SHOT_H."
    echo "Put $APP in full screen (⌃⌘F) if it isn't yet."
    prompt='Set up the view, then Enter = capture, q = quit: '
else
    fit_window || true
    prompt='Set up the view, then Enter = capture, f = fit window, q = quit: '
fi
echo "Screenshots go to: $OUT"

n=$(find "$OUT" -maxdepth 1 -name '[0-9][0-9].png' | wc -l | tr -d ' ')
while true; do
    printf '\n%s' "$prompt"
    read -r key
    case "$key" in
        q) break ;;
        f) [[ $FULLSCREEN == 1 ]] && echo "Not in full-screen mode." || fit_window || true ;;
        "")
            osascript -e "tell application \"System Events\" to set frontmost of process \"$APP\" to true"
            for ((i = DELAY; i > 0; i--)); do printf '%d… ' "$i"; sleep 1; done
            echo
            n=$((n + 1))
            file="$OUT/$(printf '%02d' "$n").png"
            if [[ $FULLSCREEN == 1 ]]; then
                screencapture -x -m -t png "$file.capture.png"
                "$FLATTEN" "$file.capture.png" "$file" "$SHOT_W" "$SHOT_H"
            else
                screencapture -x -t png -R "$X,$Y,$WIDTH,$HEIGHT" "$file.capture.png"
                "$FLATTEN" "$file.capture.png" "$file"
            fi
            rm "$file.capture.png"
            size="$(sips -g pixelWidth -g pixelHeight "$file" | awk '/pixel/ { print $2 }' | paste -sd x -)"
            case "$size" in
                2880x1800|1440x900) echo "✅ $(basename "$file") — $size" ;;
                *) echo "⚠️  $(basename "$file") is $size, not an App Store size" ;;
            esac
            ;;
        *) echo "Unknown key: $key" ;;
    esac
done
echo "Done: $n screenshot(s) in $OUT"
