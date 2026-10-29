#!/usr/bin/env bash
# tart-upgrade-base.sh — upgrade a base VM in place with Apple's full installer
# (InstallAssistant.pkg), for majors that get no newer VM installer (IPSW): 15 and 26.
#
# Usage:
#   scripts/tart-upgrade-base.sh <vm> <InstallAssistant.pkg> <expected-version>
#   e.g. scripts/tart-upgrade-base.sh fb-26 "$TART_EXTERNAL/ipsw/InstallAssistant_26.7.2_25G332.pkg" 26.7.2
#
# Starts the VM with a window and the pkg's folder shared read-only, installs the
# "Install macOS" app from the pkg, runs its startosinstall (the VM restarts and installs,
# 20–40 minutes), waits for the VM to come back on <expected-version>, removes the
# installer app, turns every automatic update off again, waits until macOS is quiet and
# shuts down properly. No clicks needed.
#
# The VM needs about 67 GB in its system container (the installer app plus the upgrade):
# give it a 120 GB disk first (scripts/tart-resize-base.sh). Upgrade a resized copy, not
# the base itself, and replace the base only after a smoke test.
# See docs/internal/testing.md (VMs, Update a base VM).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
usage() { sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; exit 1; }

[[ $# -ne 3 ]] && usage
source "$SCRIPT_DIR/tart-lib.sh"
VM="$1"; PKG="$2"; WANT="$3"
[[ -f "$PKG" ]] || { echo "No installer at $PKG — is the drive 'FITS Blaster External' connected?" >&2; exit 1; }
tart_use "$VM"
[[ "$(tart_state "$VM")" == "stopped" ]] || { echo "$VM is not stopped." >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
step() { echo "$(date +%T)  $*"; }
pw() { security find-generic-password -s "$TART_KEYCHAIN_SERVICE" -a "$TART_USER" -w; }

tart run "$VM" --dir="installer:$(dirname "$PKG"):ro" > "$WORK/run.log" 2>&1 &
IP="$(tart ip "$VM" --wait 300)"
tart_ssh_config "$VM" "$IP" "$WORK/ssh_config"
S=(ssh -F "$WORK/ssh_config" -o BatchMode=yes "$VM")
tart_wait_desktop "$WORK/ssh_config" "$VM" 600
step "$VM up at $IP: $("${S[@]}" 'sw_vers -productVersion; sw_vers -buildVersion' | xargs)"
"${S[@]}" 'df -h / | tail -1'

GUEST_PKG="/Volumes/My Shared Files/installer/$(basename "$PKG")"
step "Installing the installer app from the pkg"
pw | "${S[@]}" "sudo -S -p '' installer -pkg '$GUEST_PKG' -target / | tail -2"
APP="$("${S[@]}" 'ls -d /Applications/Install\ macOS*.app | tail -1')"
step "Installer app: $APP"
"${S[@]}" 'df -h / | tail -1'

step "Running startosinstall (the VM restarts, takes 20–40 minutes)"
# Two lines on stdin: one for sudo, one for --stdinpass.
{ pw; pw; } | "${S[@]}" "sudo -S -p '' '$APP/Contents/Resources/startosinstall' --agreetolicense --forcequitapps --user $TART_USER --stdinpass" \
    > "$WORK/startosinstall.log" 2>&1 || true
# Its progress ("Preparing: 12.3%") is one long line with carriage returns: keep the rest.
tr '\r' '\n' < "$WORK/startosinstall.log" | grep -v '^ *Preparing: [0-9]' | tail -5
# The SSH session ends with the restart; a usage or error message means it never started.
if grep -qE '^Usage:|[Ee]rror' "$WORK/startosinstall.log"; then
    echo "startosinstall did not start the upgrade. $VM left running." >&2; exit 1
fi

# Wait for the VM to come back on the new version.
deadline=$(( $(date +%s) + 5400 ))
ver=""
while (( $(date +%s) < deadline )); do
    sleep 30
    [[ "$(tart_state "$VM")" == "running" ]] || { echo "$VM stopped during the upgrade:" >&2; tail -20 "$WORK/run.log" >&2; exit 1; }
    IP="$(tart ip "$VM" --wait 10 2>/dev/null || true)"
    [[ -n "$IP" ]] || continue
    tart_ssh_config "$VM" "$IP" "$WORK/ssh_config"
    ver="$("${S[@]}" 'sw_vers -productVersion' 2>/dev/null || true)"
    [[ "$ver" == "$WANT" ]] && break
done
[[ "$ver" == "$WANT" ]] || { echo "Not on $WANT after 90 minutes (now '${ver}'). $VM left running." >&2; exit 1; }
tart_wait_desktop "$WORK/ssh_config" "$VM" 600
step "$VM is on $("${S[@]}" 'sw_vers -productVersion; sw_vers -buildVersion' | xargs)"

pw | "${S[@]}" "sudo -S -p '' rm -rf '$APP'"
"${S[@]}" 'df -h / | tail -1'
P=/Library/Preferences/com.apple.SoftwareUpdate
# The upgrade removes AutomaticCheckEnabled (seen 26.6.2 → 26.7.2): turn every automatic
# update off again, as tart-create-base.sh does.
pw | "${S[@]}" "sudo -S -p '' sh -c '
    softwareupdate --schedule off >/dev/null
    for k in AutomaticCheckEnabled AutomaticDownload AutomaticallyInstallMacOSUpdates ConfigDataInstall CriticalUpdateInstall; do
        defaults write $P \$k -bool false
    done
    defaults write /Library/Preferences/com.apple.commerce AutoUpdate -bool false'"
step "Updates:$("${S[@]}" "for k in AutomaticCheckEnabled AutomaticDownload AutomaticallyInstallMacOSUpdates ConfigDataInstall CriticalUpdateInstall; do printf '%s=%s ' \$k \$(defaults read $P \$k 2>/dev/null || echo unset); done")"
step "Waiting until macOS is quiet"
tart_wait_quiet "$WORK/ssh_config" "$VM" 60
step "Shutting down"
tart_shutdown "$WORK/ssh_config" "$VM"
step "Done: $VM is on $WANT"
