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
#   scripts/vm-smoke.sh <vm> <dmg-path>               test a local DMG
#   scripts/vm-smoke.sh <vm> <app-path>               test a locally built .app (packed into a DMG)
#   scripts/vm-smoke.sh <vm> --tag <tag>              download the DMG from a GitHub release
#
# <vm> is either --tart <base> (a Tart base VM such as fb-27-beta: the test runs on a
# fresh clone, started without a window and deleted afterwards) or an SSH host name of
# a VM that is already running (any host in ~/.ssh/config).
#
# Options:
#   --keep           (with --tart) start the clone with a window and leave it running for
#                    the manual checks; delete it afterwards with scripts/tart-cleanup.sh
#   --sample <zip>   sample set zip (default: the website sample on the shared volume)
#   --wait <sec>     how long the app must stay up after launch (default 30)
#   --dev-build      local development build: skip the notarisation check
#   --quit           close the app at the end (default: leave it open for the visual check)
#
# Examples:
#   scripts/vm-smoke.sh --tart fb-26 --tag v1.23.1-beta.1
#   scripts/vm-smoke.sh --tart fb-27-beta "$(scripts/build-beta.sh)" --dev-build --keep
#   scripts/vm-smoke.sh <ssh-host> ~/Downloads/FITS-Blaster-1.23.1-beta.1.dmg --quit
#   scripts/vm-smoke.sh <ssh-host> "$(scripts/build-beta.sh)" --dev-build
#
# Results go to tests/smoke-results/<time>-<host>-<dmg>/ (not committed). With --tart the
# metrics are also compared with the stored baselines (scripts/metric-baselines.py).
# Exit status: 0 when every check passed, 1 otherwise.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DEFAULT_SAMPLE="/Volumes/FITS Blaster/Test Data/Sample set (website)/FITS-Blaster-Sample-M31.zip"

usage() { sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; exit 1; }

# ── Arguments ────────────────────────────────────────────────────────────────

[[ $# -lt 2 ]] && usage
TART_BASE=""
if [[ "$1" == "--tart" ]]; then
    TART_BASE="$2"; shift 2
    HOST=""
else
    HOST="$1"; shift
fi
KEEP=0
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
        --keep)      KEEP=1; shift ;;
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
[[ $KEEP == 1 && -z "$TART_BASE" ]] && { echo "--keep only works with --tart." >&2; exit 1; }

STAMP="$(date '+%Y%m%d-%H%M%S')"

# ssh/scp go through these, so a Tart clone can use its own temporary SSH config.
SSH_OPTS=()
vm_ssh() { ssh ${SSH_OPTS[@]+"${SSH_OPTS[@]}"} "$@"; }
vm_scp() { scp ${SSH_OPTS[@]+"${SSH_OPTS[@]}"} "$@"; }

# ── Start a Tart clone ───────────────────────────────────────────────────────

if [[ -n "$TART_BASE" ]]; then
    source "$SCRIPT_DIR/tart-lib.sh"
    tart_exists "$TART_BASE" || { echo "No Tart VM '$TART_BASE' (tart list)." >&2; exit 1; }
    [[ "$(tart_state "$TART_BASE")" == "stopped" ]] || { echo "$TART_BASE is running; base VMs must be shut down." >&2; exit 1; }
    HOST="$TART_BASE-smoke-$STAMP"
    TART_WORK="$(mktemp -d)"
    cleanup_clone() {
        if [[ $KEEP == 0 ]]; then
            tart stop "$HOST" >/dev/null 2>&1 || true   # hard stop is fine for a throwaway clone
            tart delete "$HOST" >/dev/null 2>&1 || true
            rm -rf "$TART_WORK"
        fi
    }
    trap cleanup_clone EXIT
    tart clone "$TART_BASE" "$HOST"
    if [[ $KEEP == 1 ]]; then
        # Start at 1440×900 (16:10, fits a 1680×1050 screen) and let the clone's display
        # follow its window, so the desktop stays readable when the window is resized.
        tart set "$HOST" --display 1440x900 --display-refit
        tart run "$HOST" > "$TART_WORK/run.log" 2>&1 &
    else
        tart run "$HOST" --no-graphics > "$TART_WORK/run.log" 2>&1 &
    fi
    IP="$(tart ip "$HOST" --wait 180)"
    tart_ssh_config "$HOST" "$IP" "$TART_WORK/ssh_config"
    SSH_OPTS=(-F "$TART_WORK/ssh_config")
    echo "Started clone $HOST of $TART_BASE ($IP); waiting for the desktop…"
    tart_wait_desktop "$TART_WORK/ssh_config" "$HOST" 300
fi

# Results folders are named after the base VM (Tart) or the SSH host.
VM_LABEL="${TART_BASE:-$HOST}"

# ── Reach the VM ─────────────────────────────────────────────────────────────

# A few attempts: with two VMs starting at once, a single quick try can miss (2026-10-15).
REACHED=0
for attempt in 1 2 3 4 5 6; do
    if vm_ssh -o BatchMode=yes -o ConnectTimeout=10 "$HOST" true 2>/dev/null; then REACHED=1; break; fi
    sleep 5
done
if [[ $REACHED == 0 ]]; then
    echo "Cannot reach '$HOST' over SSH. Is the VM running, Remote Login on, and the key installed?" >&2
    exit 1
fi

# ── Get the DMG ──────────────────────────────────────────────────────────────

if [[ -n "$TAG" ]]; then
    RESULTS="$REPO_ROOT/tests/smoke-results/$STAMP-$VM_LABEL-$TAG"
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
        RESULTS="$REPO_ROOT/tests/smoke-results/$STAMP-$VM_LABEL-$(basename "$DMG" .app | tr ' ' '-')"
        mkdir -p "$RESULTS"
        PACKED="$RESULTS/local-build.dmg"
        hdiutil create -quiet -volname "FITS Blaster" -srcfolder "$DMG" -format UDZO "$PACKED"
        DMG="$PACKED"
        echo "Packed the app into $(basename "$DMG")"
    else
        [[ -f "$DMG" ]] || { echo "DMG not found: $DMG" >&2; exit 1; }
        RESULTS="$REPO_ROOT/tests/smoke-results/$STAMP-$VM_LABEL-$(basename "$DMG" .dmg)"
        mkdir -p "$RESULTS"
    fi
    echo "DMG sha256 $(shasum -a 256 "$DMG" | cut -d' ' -f1)"
fi

# ── Run in the VM ────────────────────────────────────────────────────────────

REMOTE_DIR="fb-smoke/$STAMP"
echo "Copying the DMG and sample set to ${HOST}…"
vm_ssh "$HOST" "mkdir -p '$REMOTE_DIR'"
vm_scp -q "$DMG" "$SAMPLE" "$SCRIPT_DIR/vm-smoke-remote.sh" "$HOST:$REMOTE_DIR/"

set +e
vm_ssh "$HOST" "bash '$REMOTE_DIR/vm-smoke-remote.sh' \"\$HOME/$REMOTE_DIR\" '$(basename "$DMG")' '$(basename "$SAMPLE")' '$WAIT' '$DEV_BUILD' '$QUIT_AFTER'" \
    | tee "$RESULTS/smoke.log"
STATUS=${PIPESTATUS[0]}
set -e

vm_scp -q -r "$HOST:$REMOTE_DIR/out/" "$RESULTS/" 2>/dev/null || true
# Remove the copied DMG and zip from the VM. The unpacked sample set stays for the visual check.
vm_ssh "$HOST" "rm -rf '$REMOTE_DIR/mnt' '$REMOTE_DIR'/*.dmg '$REMOTE_DIR'/*.zip" || true

# Metrics against the stored baselines (sample set). A difference here on another macOS
# version is a finding: the same files should give the same metrics everywhere.
if [[ -n "$TART_BASE" ]]; then
    echo
    echo "== Metric baselines"
    BASELINE_STATUS=0
    BASELINE_OUT="$(python3 "$SCRIPT_DIR/metric-baselines.py" --smoke-results "$RESULTS" 2>&1)" || BASELINE_STATUS=$?
    echo "$BASELINE_OUT" | grep -E "^(PASS|FAIL) |^      " | tee -a "$RESULTS/smoke.log" || echo "$BASELINE_OUT"
    [[ $BASELINE_STATUS -eq 0 ]] || STATUS=1
fi

echo
echo "Results: $RESULTS"
if [[ $KEEP == 1 ]]; then
    echo
    echo "Clone $HOST is left running with its window for the manual checks."
    echo "Afterwards delete it with: scripts/tart-cleanup.sh"
fi
if [[ $STATUS -eq 0 ]]; then
    echo "All automatic checks passed. Now do the manual checks in docs/internal/testing.md."
else
    echo "Some checks FAILED — see the lines marked FAIL above."
fi
exit "$STATUS"
