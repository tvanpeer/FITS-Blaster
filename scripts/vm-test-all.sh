#!/usr/bin/env bash
# vm-test-all.sh — run the automatic smoke test on every Tart base VM, then print the
# commands for the manual checks on the fully tested macOS versions.
#
# Usage:
#   scripts/vm-test-all.sh <app-path|dmg-path> [--dev-build]
#   scripts/vm-test-all.sh --tag <tag>
#
# Support levels (docs/internal/testing.md):
#   automatically tested   fb-15, fb-26          — this script only
#   fully tested           fb-27, fb-27-beta     — this script, then 👤 manual checks
# Base VMs that don't exist yet are reported as SKIP. Runs two VMs at a time (the most
# macOS allows); a VM from another app that is running takes one of the two places.
#
# Results: tests/smoke-results/<time>-<base>-<build>/ per VM; the console log of each
# run in tests/smoke-results/<time>-all/.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/tart-lib.sh"

AUTOMATIC=(fb-15 fb-26)
FULL=(fb-27 fb-27-beta)

[[ $# -lt 1 ]] && { sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; exit 1; }
ARGS=("$@")

# Which bases exist, and are shut down?
BASES=()
for base in "${AUTOMATIC[@]}" "${FULL[@]}"; do
    case "$(tart_state "$base")" in
        stopped) BASES+=("$base") ;;
        "")      echo "SKIP  $base: no such base VM yet" ;;
        *)       echo "SKIP  $base: it is running (base VMs must be shut down)" ;;
    esac
done
[[ ${#BASES[@]} -eq 0 ]] && { echo "No base VMs to test." >&2; exit 1; }

RUNNING_VMS="$(pgrep -f com.apple.Virtualization.VirtualMachine | wc -l | tr -d ' ')"
SLOTS=$(( 2 - RUNNING_VMS ))
if (( SLOTS < 1 )); then
    echo "$RUNNING_VMS VMs are already running (Tart or another VM app); shut one down first." >&2
    exit 1
fi
echo "Testing ${BASES[*]}, $SLOTS at a time."

LOGS="$(mktemp -d)"
FAILED=()
run_one() {
    "$SCRIPT_DIR/vm-smoke.sh" --tart "$1" "${ARGS[@]}" --quit > "$LOGS/$1.log" 2>&1
    echo $? > "$LOGS/$1.status"
}

i=0
while (( i < ${#BASES[@]} )); do
    batch=("${BASES[@]:i:SLOTS}")
    echo "$(date +%T)  starting ${batch[*]}"
    for base in "${batch[@]}"; do
        run_one "$base" &
        sleep 5   # stagger the clones' start
    done
    wait
    for base in "${batch[@]}"; do
        status="$(cat "$LOGS/$base.status")"
        summary="$(grep -E "failed, [0-9]+ warning" "$LOGS/$base.log" | tail -1)"
        if [[ "$status" == 0 ]]; then
            echo "PASS  $base: $summary"
        else
            echo "FAIL  $base: ${summary:-see log}"
            FAILED+=("$base")
        fi
        grep -E "^(FAIL|WARN) " "$LOGS/$base.log" | sed 's/^/        /'
        grep -E "^Results: " "$LOGS/$base.log" | sed 's/^/      /'
    done
    i=$(( i + SLOTS ))
done

SUMMARY_DIR="$REPO_ROOT/tests/smoke-results/$(date +%Y%m%d-%H%M%S)-all"
mkdir -p "$SUMMARY_DIR" && cp "$LOGS"/*.log "$SUMMARY_DIR/" 2>/dev/null || true
rm -rf "$LOGS"

echo
echo "Logs of this run: $SUMMARY_DIR"
if [[ ${#FAILED[@]} -eq 0 ]]; then
    echo "All automatic checks passed on: ${BASES[*]}"
else
    echo "FAILED on: ${FAILED[*]} — see the result folders above."
fi

echo
echo "👤 Manual checks (fully tested level), one VM at a time:"
for base in "${FULL[@]}"; do
    [[ "$(tart_state "$base")" == "stopped" ]] &&
        echo "  scripts/vm-smoke.sh --tart $base $(printf '%q ' "${ARGS[@]}")--keep"
done
echo "Then do the checks in docs/internal/testing.md and run scripts/tart-cleanup.sh."

[[ ${#FAILED[@]} -eq 0 ]]
