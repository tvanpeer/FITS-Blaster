#!/usr/bin/env bash
# tart-resize-base.sh — give a base VM a larger disk, as a new VM next to it.
#
# Usage:
#   scripts/tart-resize-base.sh <base> <new-name> <disk-GB>
#
# Runs Packer with scripts/tart-resize.pkr.hcl: clones <base> to <new-name>, grows the
# disk, moves the recovery partition to the end (so macOS updates keep working) and lets
# macOS take the new space. <base> is not changed; replace it yourself once <new-name> has
# passed a smoke test (tart delete <base>; tart rename <new-name> <base>). Takes 1–2 minutes.
#
# Needs: Packer (HashiCorp, ~/.local/bin/packer) and its Tart plugin (`packer init`
# installs it), the key ~/.ssh/fitsvm_ed25519. See docs/internal/testing.md (VMs).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
usage() { sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; exit 1; }

[[ $# -ne 3 ]] && usage
source "$SCRIPT_DIR/tart-lib.sh"
BASE="$1"; NEW="$2"; SIZE="$3"
command -v packer >/dev/null || { echo "Packer is not installed (see docs/internal/testing.md)." >&2; exit 1; }
tart_use "$BASE"
[[ "$(tart_state "$BASE")" == "stopped" ]] || { echo "$BASE is not stopped." >&2; exit 1; }
tart_exists "$NEW" && { echo "$NEW already exists (tart list)." >&2; exit 1; }

TEMPLATE="$SCRIPT_DIR/tart-resize.pkr.hcl"
packer init "$TEMPLATE" >/dev/null
packer build -color=false -var "base=$BASE" -var "name=$NEW" -var "disk_gb=$SIZE" "$TEMPLATE"
echo "Done: $NEW has a $SIZE GB disk. Smoke-test it before it replaces $BASE."
