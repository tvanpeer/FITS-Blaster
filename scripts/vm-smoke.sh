#!/usr/bin/env bash
# vm-smoke.sh — smoke-test a FITS Blaster DMG inside a test VM over SSH.
#
# Copies the DMG and the M31 sample set into the VM, installs the app, checks
# signing and notarisation, launches it and checks it stays up without crashes
# or layout exceptions, and runs command-line mode on the sample set. Beta builds
# also render the sample set (CLI --render); the PNGs come back in out/render/.
# See docs/internal/testing.md — including what you must do before and after.
#
# Usage:
#   scripts/vm-smoke.sh <ssh-host> <dmg-path>         test a local DMG
#   scripts/vm-smoke.sh <ssh-host> <app-path>         test a locally built .app (packed into a DMG)
#   scripts/vm-smoke.sh <ssh-host> --tag <tag>        download the DMG from a GitHub release
#
# Options:
#   --sample <zip>   sample set zip (default: the website sample on the shared volume)
#   --wait <sec>     how long the app must stay up after launch (default 30)
#   --dev-build      local development build: skip the notarisation check
#   --quit           close the app at the end (default: leave it open for the visual check)
#
# Examples:
#   scripts/vm-smoke.sh fitsvm-b3 --tag v1.23-beta.10
#   scripts/vm-smoke.sh fitsvm ~/Downloads/FITS-Blaster-1.23.1-beta.1.dmg --quit
#   scripts/vm-smoke.sh fitsvm "$(scripts/build-beta.sh)" --dev-build
#
# Results go to tests/smoke-results/<time>-<host>-<dmg>/ (not committed).
# Exit status: 0 when every check passed, 1 otherwise.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DEFAULT_SAMPLE="/Volumes/FITS Blaster/Test Data/Sample set (website)/FITS-Blaster-Sample-M31.zip"

usage() { sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; exit 1; }

# ── Arguments ────────────────────────────────────────────────────────────────

[[ $# -lt 2 ]] && usage
HOST="$1"; shift
DMG=""
TAG=""
SAMPLE="$DEFAULT_SAMPLE"
WAIT=30
DEV_BUILD=0
QUIT_AFTER=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --tag)       TAG="$2"; shift 2 ;;
        --sample)    SAMPLE="$2"; shift 2 ;;
        --wait)      WAIT="$2"; shift 2 ;;
        --dev-build) DEV_BUILD=1; shift ;;
        --quit)      QUIT_AFTER=1; shift ;;
        -h|--help)   usage ;;
        -*)          echo "Unknown option: $1" >&2; exit 1 ;;
        *)           DMG="$1"; shift ;;
    esac
done

if [[ -z "$DMG" && -z "$TAG" ]] || [[ -n "$DMG" && -n "$TAG" ]]; then
    echo "Give either a DMG path or --tag <tag>." >&2
    exit 1
fi
[[ -f "$SAMPLE" ]] || { echo "Sample set not found: $SAMPLE (use --sample)" >&2; exit 1; }

# ── Reach the VM ─────────────────────────────────────────────────────────────

if ! ssh -o BatchMode=yes -o ConnectTimeout=5 "$HOST" true 2>/dev/null; then
    echo "Cannot reach '$HOST' over SSH. Is the VM running, Remote Login on, and the key installed?" >&2
    exit 1
fi

STAMP="$(date '+%Y%m%d-%H%M%S')"

# ── Get the DMG ──────────────────────────────────────────────────────────────

if [[ -n "$TAG" ]]; then
    RESULTS="$REPO_ROOT/tests/smoke-results/$STAMP-$HOST-$TAG"
    mkdir -p "$RESULTS"
    echo "Downloading the DMG for ${TAG}…"
    gh release download "$TAG" --repo tvanpeer/FITS-Blaster --pattern '*.dmg' --dir "$RESULTS" --clobber
    DMG="$(ls "$RESULTS"/*.dmg | head -1)"
    EXPECTED="$(gh release view "$TAG" --repo tvanpeer/FITS-Blaster --json assets \
        --jq '.assets[] | select(.name | endswith(".dmg")) | .digest' | sed 's/^sha256://')"
    ACTUAL="$(shasum -a 256 "$DMG" | cut -d' ' -f1)"
    if [[ "$EXPECTED" != "$ACTUAL" ]]; then
        echo "FAIL  DMG checksum $ACTUAL does not match the release ($EXPECTED)" >&2
        exit 1
    fi
    echo "PASS  DMG checksum matches the GitHub release"
else
    if [[ -d "$DMG" && "$DMG" == *.app ]]; then
        # A locally built app: pack it into a DMG so the VM installs it the same way.
        RESULTS="$REPO_ROOT/tests/smoke-results/$STAMP-$HOST-$(basename "$DMG" .app | tr ' ' '-')"
        mkdir -p "$RESULTS"
        PACKED="$RESULTS/local-build.dmg"
        hdiutil create -quiet -volname "FITS Blaster" -srcfolder "$DMG" -format UDZO "$PACKED"
        DMG="$PACKED"
        echo "Packed the app into $(basename "$DMG")"
    else
        [[ -f "$DMG" ]] || { echo "DMG not found: $DMG" >&2; exit 1; }
        RESULTS="$REPO_ROOT/tests/smoke-results/$STAMP-$HOST-$(basename "$DMG" .dmg)"
        mkdir -p "$RESULTS"
    fi
    echo "DMG sha256 $(shasum -a 256 "$DMG" | cut -d' ' -f1)"
fi

# ── Run in the VM ────────────────────────────────────────────────────────────

REMOTE_DIR="fb-smoke/$STAMP"
echo "Copying the DMG and sample set to ${HOST}…"
ssh "$HOST" "mkdir -p '$REMOTE_DIR'"
scp -q "$DMG" "$SAMPLE" "$SCRIPT_DIR/vm-smoke-remote.sh" "$HOST:$REMOTE_DIR/"

set +e
ssh "$HOST" "bash '$REMOTE_DIR/vm-smoke-remote.sh' \"\$HOME/$REMOTE_DIR\" '$(basename "$DMG")' '$(basename "$SAMPLE")' '$WAIT' '$DEV_BUILD' '$QUIT_AFTER'" \
    | tee "$RESULTS/smoke.log"
STATUS=${PIPESTATUS[0]}
set -e

scp -q -r "$HOST:$REMOTE_DIR/out/" "$RESULTS/" 2>/dev/null || true
# Remove the copied DMG and zip from the VM. The unpacked sample set stays for the visual check.
ssh "$HOST" "rm -rf '$REMOTE_DIR/mnt' '$REMOTE_DIR'/*.dmg '$REMOTE_DIR'/*.zip" || true

echo
echo "Results: $RESULTS"
if [[ $STATUS -eq 0 ]]; then
    echo "All automatic checks passed. Now do the manual checks in docs/internal/testing.md."
else
    echo "Some checks FAILED — see the lines marked FAIL above."
fi
exit "$STATUS"
