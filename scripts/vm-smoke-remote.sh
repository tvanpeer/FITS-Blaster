#!/bin/bash
# vm-smoke-remote.sh — runs INSIDE a test VM; started by scripts/vm-smoke.sh.
#
# Installs a FITS Blaster DMG, checks signing, launches the app and checks it
# stays up without crashes or layout exceptions, then runs the command-line
# mode on the sample set. Prints one PASS / WARN / FAIL / SKIP line per check
# and exits 1 if any check failed.
#
# Usage (normally not called by hand):
#   vm-smoke-remote.sh <work-dir> <dmg-file> <sample-zip> <wait-seconds> <dev-build 0|1> <quit-after 0|1>
#
# Written for /bin/bash 3.2 (the version macOS ships).

set -u

WORK="$1"
DMG="$2"
SAMPLE_ZIP="$3"
WAIT="$4"
DEV_BUILD="$5"
QUIT_AFTER="$6"

FAILS=0
WARNS=0

pass() { echo "PASS  $1"; }
warn() { echo "WARN  $1"; WARNS=$((WARNS + 1)); }
fail() { echo "FAIL  $1"; FAILS=$((FAILS + 1)); }
skip() { echo "SKIP  $1"; }
section() { echo; echo "== $1"; }

cd "$WORK" || { echo "FAIL  work directory $WORK missing"; exit 1; }

# ── Environment ──────────────────────────────────────────────────────────────
section "Environment"
echo "macOS $(sw_vers -productVersion) ($(sw_vers -buildVersion)), $(uname -m)"
CONSOLE_USER="$(stat -f %Su /dev/console)"
if [ "$CONSOLE_USER" = "$USER" ]; then
    pass "$USER is logged in at the desktop (needed for the GUI check)"
    GUI_OK=1
else
    fail "desktop user is '$CONSOLE_USER', not '$USER' — log in as $USER in the VM window"
    GUI_OK=0
fi

# ── Install ──────────────────────────────────────────────────────────────────
section "Install"
MNT="$WORK/mnt"
mkdir -p "$MNT"
if ! hdiutil attach -nobrowse -readonly -mountpoint "$MNT" "$DMG" >/dev/null 2>&1; then
    fail "could not mount $DMG"
    exit 1
fi
SRC_APP=""
for candidate in "$MNT"/*.app; do
    [ -d "$candidate" ] && [ ! -L "$candidate" ] && SRC_APP="$candidate" && break
done
if [ -z "$SRC_APP" ]; then
    hdiutil detach "$MNT" >/dev/null 2>&1
    fail "no .app found in the DMG"
    exit 1
fi
APP_NAME="$(basename "$SRC_APP")"
APP="/Applications/$APP_NAME"
EXE="$APP/Contents/MacOS/FITS Blaster"

# Quit a running copy before replacing it.
pkill -f "$EXE" 2>/dev/null
rm -rf "$APP"
ditto "$SRC_APP" "$APP"
hdiutil detach "$MNT" >/dev/null 2>&1
if [ -x "$EXE" ]; then
    pass "installed $APP_NAME"
else
    fail "install failed: $EXE not found"
    exit 1
fi

PLIST="$APP/Contents/Info.plist"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$PLIST")"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$PLIST")"
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$PLIST")"
echo "version $VERSION, build $BUILD, bundle ID $BUNDLE_ID"

# ── Signing ──────────────────────────────────────────────────────────────────
section "Signing"
if codesign --verify --deep --strict "$APP" 2>/dev/null; then
    pass "code signature valid (deep, strict)"
else
    fail "code signature invalid: $(codesign --verify --deep --strict "$APP" 2>&1 | head -2)"
fi
SPCTL="$(spctl -a -vvv -t exec "$APP" 2>&1)"
if echo "$SPCTL" | grep -q "source=Notarized Developer ID"; then
    pass "Gatekeeper accepts it as Notarized Developer ID"
elif [ "$DEV_BUILD" = "1" ]; then
    skip "notarisation (local development build)"
else
    fail "Gatekeeper: $(echo "$SPCTL" | tr '\n' ' ')"
fi

# ── Bundle contents ──────────────────────────────────────────────────────────
section "Bundle contents"
if [ -d "$APP/Contents/Frameworks/Sparkle.framework" ]; then
    pass "Sparkle.framework included"
else
    fail "Sparkle.framework missing (website builds must include it)"
fi
for appex in FITSBlasterQL.appex FITSBlasterQLThumb.appex; do
    if [ -d "$APP/Contents/PlugIns/$appex" ]; then
        pass "$appex included"
    else
        fail "$appex missing"
    fi
done

# ── GUI launch ───────────────────────────────────────────────────────────────
section "GUI launch (${WAIT}s)"
if [ "$GUI_OK" = "1" ]; then
    MARKER="$WORK/launch-marker"
    touch "$MARKER"
    START="$(date '+%Y-%m-%d %H:%M:%S')"
    open "$APP"
    sleep "$WAIT"
    PID="$(pgrep -f "$EXE" | head -1)"
    if [ -n "$PID" ]; then
        pass "app still running after ${WAIT}s (pid $PID, up $(ps -o etime= -p "$PID" | tr -d ' '))"
    else
        fail "app is not running ${WAIT}s after launch"
    fi
    CRASHES="$(find "$HOME/Library/Logs/DiagnosticReports" -newer "$MARKER" -iname '*FITS Blaster*' 2>/dev/null)"
    if [ -z "$CRASHES" ]; then
        pass "no new crash reports"
    else
        fail "new crash report(s): $CRASHES"
        mkdir -p "$WORK/out"
        echo "$CRASHES" | while read -r report; do cp "$report" "$WORK/out/"; done
    fi
    mkdir -p "$WORK/out"
    /usr/bin/log show --start "$START" --style compact \
        --predicate 'process == "FITS Blaster" AND (messageType == fault OR messageType == error OR eventMessage CONTAINS "Update Constraints" OR eventMessage CONTAINS "uncaught exception" OR eventMessage CONTAINS "NSGenericException")' \
        > "$WORK/out/app-log.txt" 2>/dev/null
    if grep -q -E "Update Constraints|uncaught exception|NSGenericException" "$WORK/out/app-log.txt"; then
        fail "exception or constraint loop in the log (see app-log.txt)"
    else
        pass "no exceptions or constraint loops in the log"
    fi
    FAULTS="$(grep -c ' Fa ' "$WORK/out/app-log.txt")"
    ERRORS="$(grep -c ' E  ' "$WORK/out/app-log.txt")"
    if [ "$FAULTS" -gt 0 ]; then
        warn "$FAULTS fault message(s) in the log — review app-log.txt"
    else
        pass "no fault messages in the log"
    fi
    echo "      ($ERRORS error-level message(s) logged; usually system noise, listed in app-log.txt)"
else
    skip "GUI launch (nobody logged in at the desktop as $USER)"
fi

# ── Command-line mode ────────────────────────────────────────────────────────
section "Command-line mode"
rm -rf "$WORK/sample"
mkdir -p "$WORK/sample" "$WORK/out"
unzip -q -o "$SAMPLE_ZIP" -d "$WORK/sample"
SAMPLE_DIR="$(dirname "$(find "$WORK/sample" -iname '*.fits' | head -1)")"
FRAME_COUNT="$(find "$SAMPLE_DIR" -maxdepth 1 -iname '*.fits' | wc -l | tr -d ' ')"
echo "sample set: $FRAME_COUNT frames"

HELP="$("$EXE" -h 2>&1)"
if [ $? -eq 0 ] && echo "$HELP" | grep -q "^Usage:"; then
    pass "--help prints usage and exits 0"
else
    fail "--help did not print usage or exit 0"
fi

# Rows in a CSV that may lack a trailing newline (awk counts the last line either way).
data_rows() { awk 'END { print NR - 1 }' "$1"; }

"$EXE" "$SAMPLE_DIR" -o "$WORK/out/all.csv" >/dev/null 2>"$WORK/out/all.stderr"
STATUS=$?
if [ $STATUS -eq 0 ] && [ -f "$WORK/out/all.csv" ]; then
    ROWS="$(data_rows "$WORK/out/all.csv")"
    if [ "$ROWS" = "$FRAME_COUNT" ] && head -1 "$WORK/out/all.csv" | grep -q "^path,"; then
        pass "unfiltered run: exit 0, $ROWS of $FRAME_COUNT frames in the CSV"
    else
        fail "unfiltered run: $ROWS rows for $FRAME_COUNT frames, header: $(head -1 "$WORK/out/all.csv" | cut -c1-60)"
    fi
else
    fail "unfiltered run: exit $STATUS (see all.stderr)"
fi

"$EXE" "$SAMPLE_DIR" -f 1.5 -e 0.5 -p 0.5 -o "$WORK/out/filtered.csv" >/dev/null 2>"$WORK/out/filtered.stderr"
STATUS=$?
if [ $STATUS -eq 0 ] && [ -f "$WORK/out/filtered.csv" ]; then
    ROWS="$(data_rows "$WORK/out/filtered.csv")"
    KEPT="$(awk -F, 'NR > 1 { printf "%s ", $1 }' "$WORK/out/filtered.csv")"
    if [ "$ROWS" -ge 1 ] && [ "$ROWS" -le "$FRAME_COUNT" ]; then
        pass "filtered run (-f 1.5 -e 0.5 -p 0.5): exit 0, kept $ROWS: $KEPT"
    else
        fail "filtered run kept $ROWS of $FRAME_COUNT frames"
    fi
else
    fail "filtered run: exit $STATUS (see filtered.stderr)"
fi

# ── Rendering (beta builds only) ─────────────────────────────────────────────
# The CLI --render option exists only in beta builds (BETA compilation condition);
# stable builds ignore it like any unknown option and write no backgrounds.csv.
# Limits are the same as in RenderingTests.swift — change both together.
section "Rendering (CLI --render, beta builds only)"
TARGET_LEVEL=63
MAX_SPREAD=4
MAX_OFFSET=6
RENDER="$WORK/out/render"
"$EXE" "$SAMPLE_DIR" --render "$RENDER" -o "$WORK/out/render.csv" >/dev/null 2>"$WORK/out/render.stderr"
STATUS=$?
if [ ! -f "$RENDER/backgrounds.csv" ]; then
    if [ $STATUS -eq 0 ]; then
        skip "--render is not in this build (only beta builds have it)"
    else
        fail "render run: exit $STATUS (see render.stderr)"
    fi
else
    BG="$RENDER/backgrounds.csv"
    # Fields are counted from the end: folder and frame names may contain commas.
    ROWS="$(data_rows "$BG")"
    PNGS="$(find "$RENDER" -name '*.png' | wc -l | tr -d ' ')"
    if [ "$ROWS" = "$FRAME_COUNT" ] && [ "$PNGS" = "$FRAME_COUNT" ]; then
        pass "render run: exit $STATUS, $ROWS frames measured, $PNGS PNGs"
    else
        fail "render run: $ROWS frames measured and $PNGS PNGs for $FRAME_COUNT frames"
    fi
    if cmp -s "$WORK/out/all.csv" "$WORK/out/render.csv"; then
        pass "metrics CSV with --render is identical to the unfiltered run"
    else
        fail "metrics CSV with --render differs from the unfiltered run (compare all.csv and render.csv)"
    fi
    GREY="$(awk -F, 'NR > 1 && $(NF-4) == "grey"' "$BG" | wc -l | tr -d ' ')"
    if [ "$GREY" = "0" ]; then
        pass "every colour frame has a colour render"
    else
        fail "$GREY colour frame(s) without a colour render (view 'grey' in backgrounds.csv)"
    fi
    TYPICAL="$(awk -F, 'NR > 1 && $NF == "yes" { print $(NF-3), $(NF-2), $(NF-1) }' "$BG" | head -1)"
    if [ -z "$TYPICAL" ]; then
        fail "no typical frame in backgrounds.csv"
    else
        set -- $TYPICAL
        R=$1; G=$2; B=$3
        VERDICT="$(awk -v r="$R" -v g="$G" -v b="$B" -v t="$TARGET_LEVEL" -v s="$MAX_SPREAD" -v o="$MAX_OFFSET" 'BEGIN {
            max = r; if (g > max) max = g; if (b > max) max = b
            min = r; if (g < min) min = g; if (b < min) min = b
            msg = ""
            if (max - min > s) msg = msg sprintf("channels differ by %d (allowed %d); ", max - min, s)
            if (max > t + o || min < t - o) msg = msg sprintf("level outside %d ± %d; ", t, o)
            sub(/; $/, "", msg)
            print msg
        }')"
        if [ -z "$VERDICT" ]; then
            pass "typical frame background R/G/B $R/$G/$B (target $TARGET_LEVEL ± $MAX_OFFSET, spread ≤ $MAX_SPREAD)"
        else
            fail "typical frame background R/G/B $R/$G/$B: $VERDICT"
        fi
    fi
    echo "      PNGs for the visual check are copied to this Mac (out/render/)"
fi

# ── Finish ───────────────────────────────────────────────────────────────────
section "Result"
if [ "$QUIT_AFTER" = "1" ]; then
    pkill -f "$EXE" 2>/dev/null
    echo "app closed (--quit)"
elif [ "$GUI_OK" = "1" ]; then
    echo "app left open for the visual check"
fi
echo "sample set for the visual check: $SAMPLE_DIR"
echo "$VERSION ($BUILD) on macOS $(sw_vers -productVersion) ($(sw_vers -buildVersion)): $FAILS failed, $WARNS warning(s)"
[ "$FAILS" -eq 0 ]
