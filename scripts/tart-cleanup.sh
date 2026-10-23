#!/usr/bin/env bash
# tart-cleanup.sh — stop and delete the smoke-test clones (Tart VMs named *-smoke-*), for
# example after the manual checks on a clone started with vm-smoke.sh --keep.
# Base VMs are never touched. Looks in every Tart home that is there (the FITS Blaster
# volume, and the external SSD when it is connected).
#
# Usage:
#   scripts/tart-cleanup.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/tart-lib.sh"

FOUND=0
for home in "${TART_HOMES[@]}"; do
    export TART_HOME="$home"
    CLONES="$(tart list | awk 'NR > 1 && $2 ~ /-smoke-[0-9]{8}-[0-9]{6}$/ { print $2 }')"
    for clone in $CLONES; do
        FOUND=1
        if [[ "$(tart_state "$clone")" == "running" ]]; then
            tart stop "$clone"   # hard stop: fine for a throwaway clone
        fi
        tart delete "$clone"
        echo "Deleted $clone"
    done
done
[[ $FOUND == 1 ]] || echo "No smoke-test clones."
tart_external_connected || [[ -n "$TART_FIXED_HOME" ]] || echo "(The drive 'FITS Blaster External' isn't connected; clones there weren't checked.)"
