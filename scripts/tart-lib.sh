#!/usr/bin/env bash
# tart-lib.sh — shared helpers for the Tart test VMs. Sourced by tart-create-base.sh,
# vm-smoke.sh (--tart) and vm-test-all.sh; not run on its own.
#
# Base VMs (fb-15, fb-26, fb-27, fb-27-beta) are never used for tests directly: each
# test runs on a throwaway clone (APFS copy-on-write, instant, almost no space).
# See docs/internal/testing.md.
#
# Facts these helpers rely on (checked 2026-10-14/15, Tart 2.41.0, macOS 27 host):
# - `tart stop` is a hard power-off (VZVirtualMachine.stop). Fine for clones; base VMs
#   are shut down with `sudo shutdown` over SSH (allowed without a password by
#   /etc/sudoers.d/fitstester-shutdown in the VM).
# - At most 2 macOS VMs can run at the same time (system limit, VirtualBuddy included).
# - Clones get a new MAC address, so a new IP: always ask `tart ip`.
# - The SSH account works before first-boot setup has finished; wait for the desktop.

export TART_HOME="${TART_HOME:-/Volumes/FITS Blaster/Tart}"
export TART_NO_AUTO_PRUNE=1          # never let `tart clone` delete anything by itself

TART_USER=fitstester
TART_KEY="$HOME/.ssh/fitsvm_ed25519"
TART_KEYCHAIN_SERVICE=fb-test-vm     # security add-generic-password -s fb-test-vm -a fitstester -w

command -v tart >/dev/null || { echo "tart not found (see docs/internal/testing.md, VMs)" >&2; exit 1; }

# tart_state <vm> — prints running / stopped / suspended, or nothing if the VM doesn't exist.
tart_state() { tart list | awk -v v="$1" '$2 == v { print $NF }'; }

tart_exists() { [[ -n "$(tart_state "$1")" ]]; }

# tart_ssh_config <vm> <ip> <file> — writes an SSH config with Host <vm>, so plain
# `ssh -F <file> <vm>` and `scp -F <file>` work. Known hosts go next to the file: clones
# share the base VM's host key but get new IPs.
tart_ssh_config() {
    cat > "$3" <<EOF
Host $1
  HostName $2
  User $TART_USER
  IdentityFile $TART_KEY
  IdentitiesOnly yes
  StrictHostKeyChecking accept-new
  UserKnownHostsFile $3.known_hosts
  ConnectTimeout 10
EOF
}

# tart_wait_desktop <ssh-config> <vm> <seconds> — waits until the user is logged in at
# the desktop with Finder running. Returns 1 on timeout.
tart_wait_desktop() {
    local deadline=$(( $(date +%s) + $3 )) state=""
    while (( $(date +%s) < deadline )); do
        state="$(ssh -F "$1" -o BatchMode=yes "$2" \
            'echo "$(stat -f %Su /dev/console) $(pgrep -x Finder >/dev/null && echo finder)"' 2>/dev/null || true)"
        [[ "$state" == "$TART_USER finder" ]] && return 0
        sleep 3
    done
    echo "desktop not reached after $3 s (state: '${state}')" >&2
    return 1
}

# tart_shutdown <ssh-config> <vm> — proper shutdown from inside macOS, then waits.
tart_shutdown() {
    ssh -F "$1" -o BatchMode=yes "$2" 'sudo -n /sbin/shutdown -h now' >/dev/null 2>&1 || true
    local i
    for i in $(seq 1 60); do
        [[ "$(tart_state "$2")" == "stopped" ]] && return 0
        sleep 2
    done
    echo "$2 did not shut down within 120 s" >&2
    return 1
}
