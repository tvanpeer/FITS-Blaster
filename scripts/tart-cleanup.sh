#!/usr/bin/env bash
# tart-cleanup.sh — stop and delete the smoke-test clones (Tart VMs named *-smoke-*), for
# example after the manual checks on a clone started with vm-smoke.sh --keep.
# Base VMs are never touched.
#
# Usage:
#   scripts/tart-cleanup.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/tart-lib.sh"

CLONES="$(tart list | awk 'NR > 1 && $2 ~ /-smoke-[0-9]{8}-[0-9]{6}$/ { print $2 }')"
if [[ -z "$CLONES" ]]; then
    echo "No smoke-test clones."
    exit 0
fi
for clone in $CLONES; do
    if [[ "$(tart_state "$clone")" == "running" ]]; then
        tart stop "$clone"   # hard stop: fine for a throwaway clone
    fi
    tart delete "$clone"
    echo "Deleted $clone"
done
