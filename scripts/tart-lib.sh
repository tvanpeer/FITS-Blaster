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
# - At most 2 macOS VMs can run at the same time (system limit, VMs from other apps included).
# - Clones get a new MAC address, so a new IP: always ask `tart ip`.
# - The SSH account works before first-boot setup has finished; wait for the desktop.

# The VMs live in two Tart homes (since 2026-10-23): fb-27-beta on the FITS Blaster volume
# for quick tests, the others on the external SSD, which is only connected for releases.
# Each VM exists in one home only; its clones are made next to it (APFS copy-on-write
# only works within a volume). A TART_HOME set by the caller is used on its own.
# Tart would quietly start an empty ~/.tart, so stop when no home is there.
TART_INTERNAL="/Volumes/FITS Blaster/Tart"
TART_EXTERNAL="/Volumes/FITS Blaster External/Tart"
TART_FIXED_HOME="${TART_HOME:-}"
if [[ -n "$TART_FIXED_HOME" ]]; then
    TART_HOMES=("$TART_FIXED_HOME")
else
    TART_HOMES=()
    for home in "$TART_INTERNAL" "$TART_EXTERNAL"; do
        [[ -d "$home/vms" ]] && TART_HOMES+=("$home")
    done
fi
[[ ${#TART_HOMES[@]} -gt 0 && -d "${TART_HOMES[0]}/vms" ]] || { echo "No Tart VMs in ${TART_FIXED_HOME:-$TART_INTERNAL or $TART_EXTERNAL}." >&2; exit 1; }
export TART_NO_AUTO_PRUNE=1          # never let `tart clone` delete anything by itself

TART_USER=fitstester
TART_KEY="$HOME/.ssh/fitsvm_ed25519"
TART_KEYCHAIN_SERVICE=fb-test-vm     # security add-generic-password -s fb-test-vm -a fitstester -w

command -v tart >/dev/null || { echo "tart not found (see docs/internal/testing.md, VMs)" >&2; exit 1; }

# tart_external_connected — true when the external SSD with its VMs is there.
tart_external_connected() { [[ -d "$TART_EXTERNAL/vms" ]]; }

# tart_home_of <vm> — prints the Tart home that holds the VM; returns 1 if none does.
tart_home_of() {
    local home
    for home in "${TART_HOMES[@]}"; do
        [[ -d "$home/vms/$1" ]] && { echo "$home"; return 0; }
    done
    return 1
}

# tart_use <vm> — exports TART_HOME for the VM's home, so the plain `tart` calls that
# follow (clone, run, ip, stop, delete) act there.
tart_use() {
    local home
    home="$(tart_home_of "$1")" || { echo "No Tart VM '$1' in ${TART_HOMES[*]}." >&2; return 1; }
    export TART_HOME="$home"
}

# tart_state <vm> — prints running / stopped / suspended, or nothing if the VM doesn't exist.
tart_state() {
    local home
    home="$(tart_home_of "$1")" || return 0
    TART_HOME="$home" tart list | awk -v v="$1" '$2 == v { print $NF }'
}

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

# tart_wait_quiet <ssh-config> <vm> [max-minutes] — waits until the VM's 1-minute load has
# stayed under 1.5 for 5 minutes (default maximum 120 minutes; returns 1 then). After its
# first boot or an update, macOS downloads and unpacks components (Apple Intelligence,
# widgets, Shortcuts) for 10–15 minutes. A base VM shut down before that has finished
# makes every clone start the work again: on fb-27 (2026-10-23) the load in a clone went
# past 170, runs took over 10 minutes and Gatekeeper's online check failed.
tart_wait_quiet() {
    local max="${3:-120}" quiet=0 i load
    for (( i = 1; i <= max; i++ )); do
        load="$(ssh -F "$1" -o BatchMode=yes "$2" 'sysctl -n vm.loadavg' 2>/dev/null | awk '{ print $2 }')"
        if [[ -n "$load" ]] && awk -v l="$load" 'BEGIN { exit !(l < 1.5) }'; then
            quiet=$(( quiet + 1 ))
        else
            quiet=0
        fi
        echo "      $(date +%T)  load ${load:-?}"
        (( quiet >= 5 )) && return 0
        sleep 60
    done
    echo "$2 still busy after $max minutes" >&2
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
