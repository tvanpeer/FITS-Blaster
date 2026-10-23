#!/usr/bin/env bash
# tart-create-base.sh — create a base VM for the smoke tests from a macOS installer (IPSW).
#
# Usage:
#   scripts/tart-create-base.sh <name> <ipsw-file-or-url>            macOS 27 and later
#   scripts/tart-create-base.sh <name> <ipsw-file-or-url> --manual   macOS 15 and 26
#
# macOS 27+: Apple's guest provisioning (tart run --provisioning-opts) creates the user,
#   automatic login and Remote Login on first boot. With a beta installer, 👤 you click
#   the licence agreement (Agree, Agree) and Get Started in the VM window; release
#   installers need no clicks (checked with 27.0.1, 27.2 beta 3 and 27.2 RC 26B118).
# --manual: older macOS has no provisioning. 👤 You go through Setup Assistant in the VM
#   window (instructions are printed); the script waits and does the rest.
#
# Then, over SSH: installs the SSH key, allows `sudo shutdown` without a password, turns
# all automatic updates off, turns screen lock, sleep and screensaver off, checks the
# settings and shuts the VM down properly.
#
# Needs: Tart, the key ~/.ssh/fitsvm_ed25519, and the fitstester password in the Keychain:
#   security add-generic-password -s fb-test-vm -a fitstester -w
# See docs/internal/testing.md (VMs).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
usage() { sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; exit 1; }

[[ $# -lt 2 ]] && usage
source "$SCRIPT_DIR/tart-lib.sh"   # after the usage, which works without the external drive
VM="$1"; IPSW="$2"; MANUAL=0
[[ "${3:-}" == "--manual" ]] && MANUAL=1
tart_exists "$VM" && { echo "$VM already exists (tart list)." >&2; exit 1; }

PASSWORD="$(security find-generic-password -s "$TART_KEYCHAIN_SERVICE" -a "$TART_USER" -w)" || {
    echo "No password in the Keychain. Run: security add-generic-password -s $TART_KEYCHAIN_SERVICE -a $TART_USER -w" >&2
    exit 1
}
[[ "$PASSWORD" == *,* ]] && { echo "The password contains a comma, which --provisioning-opts can't take." >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
# ssh gets the password from this helper, so it never appears on a command line.
printf '#!/bin/sh\nsecurity find-generic-password -s %s -a %s -w\n' "$TART_KEYCHAIN_SERVICE" "$TART_USER" > "$WORK/askpass"
chmod 700 "$WORK/askpass"

step() { echo "$(date +%T)  $*"; }

step "Creating $VM from $IPSW (about 6 minutes)"
# 80 GB: macOS updates need about 22 GB free inside the VM (26.7.1 refused to install on
# Tart's default 50 GB). The disk is sparse; on this Mac it only takes what macOS writes.
# Enlarging a disk later is impractical: the recovery partition sits behind the system
# container, and deleting it breaks softwareupdate.
tart create "$VM" --from-ipsw "$IPSW" --disk-size 80 > "$WORK/create.log" 2>&1 || { cat "$WORK/create.log" >&2; exit 1; }

# The first boot gets a window: without one, Setup Assistant waits on screens nobody sees.
if [[ $MANUAL == 1 ]]; then
    tart run "$VM" > "$WORK/run.log" 2>&1 &
    cat <<EOF

👤 In the $VM window, go through Setup Assistant:
   - account: full name "FITS Tester", account name $TART_USER, the password from the Keychain
   - no Apple ID; skip or decline everything optional
   - FileVault: do NOT turn it on
   Then in System Settings, in this order (Remote Login last: the script starts as soon as it can log in):
   - Users & Groups → Automatically log in as: $TART_USER
   - General → Software Update → Automatic Updates (ⓘ): everything off
   - General → Sharing → Remote Login: on
   The script continues when $TART_USER is logged in and reachable over SSH (waits up to 60 minutes).

EOF
    DESKTOP_WAIT=3600
else
    tart run "$VM" --provisioning-opts="fullName=FITS Tester,username=$TART_USER,password=$PASSWORD,logsInAutomatically=true,enablesRemoteLogin=true" \
        > "$WORK/run.log" 2>&1 &
    step "First boot with provisioning. 👤 Beta installers only: in the VM window, Agree (twice) and Get Started."
    DESKTOP_WAIT=1200
fi
unset PASSWORD

IP="$(tart ip "$VM" --wait 600)"
step "IP $IP"
tart_ssh_config "$VM" "$IP" "$WORK/ssh_config"
ssh_pw() { SSH_ASKPASS="$WORK/askpass" SSH_ASKPASS_REQUIRE=force \
    ssh -F "$WORK/ssh_config" -o PubkeyAuthentication=no "$VM" "$@" < /dev/null; }

# Wait until password login works and the user is at the desktop. The account exists
# before first-boot setup is done; shutting down earlier brings Setup Assistant back.
deadline=$(( $(date +%s) + DESKTOP_WAIT ))
state=""
while (( $(date +%s) < deadline )); do
    state="$(ssh_pw 'echo "$(stat -f %Su /dev/console) $(pgrep -x Finder >/dev/null && echo finder)"' 2>/dev/null || true)"
    [[ "$state" == "$TART_USER finder" ]] && break
    sleep 5
done
[[ "$state" == "$TART_USER finder" ]] || { echo "Desktop not reached (state: '$state'). $VM is left running for a look." >&2; exit 1; }
step "$TART_USER is at the desktop"
sleep 30   # let the login settle before changing settings

ssh_pw "mkdir -p ~/.ssh && chmod 700 ~/.ssh && echo '$(cat "$TART_KEY.pub")' >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys"
ssh -F "$WORK/ssh_config" -o BatchMode=yes "$VM" true
step "SSH key installed"

# sudo reads the password from stdin (-S -p ''); it is never printed.
security find-generic-password -s "$TART_KEYCHAIN_SERVICE" -a "$TART_USER" -w |
    ssh -F "$WORK/ssh_config" -o BatchMode=yes "$VM" "sudo -S -p '' sh -c '
        echo \"$TART_USER ALL=(root) NOPASSWD: /sbin/shutdown\" > /etc/sudoers.d/$TART_USER-shutdown &&
        chmod 440 /etc/sudoers.d/$TART_USER-shutdown &&
        visudo -c -q &&
        softwareupdate --schedule off >/dev/null &&
        P=/Library/Preferences/com.apple.SoftwareUpdate &&
        defaults write \$P AutomaticCheckEnabled -bool false &&
        defaults write \$P AutomaticDownload -bool false &&
        defaults write \$P AutomaticallyInstallMacOSUpdates -bool false &&
        defaults write \$P ConfigDataInstall -bool false &&
        defaults write \$P CriticalUpdateInstall -bool false &&
        defaults write /Library/Preferences/com.apple.commerce AutoUpdate -bool false
    '"
step "Shutdown rule added, automatic updates off"

# No screen lock, no sleep, no screensaver. Without this the display sleeps, the screen
# locks, and macOS remembers it: after the next automatic login the screen is locked
# again (seen on fb-15, 2026-10-15). The tests still pass behind a locked screen, but the
# manual checks would need the password, and a locked screen isn't what a user sees.
security find-generic-password -s "$TART_KEYCHAIN_SERVICE" -a "$TART_USER" -w |
    ssh -F "$WORK/ssh_config" -o BatchMode=yes "$VM" 'pw=$(cat)
        sysadminctl -screenLock off -password "$pw" >/dev/null 2>&1
        printf "%s\n" "$pw" | sudo -S -p "" sh -c "pmset -a displaysleep 0 sleep 0 && defaults write /Library/Preferences/com.apple.screensaver loginWindowIdleTime 0"
        defaults -currentHost write com.apple.screensaver idleTime 0'
step "Screen lock, sleep and screensaver off"

# Check: a base VM must look like a normal user's Mac, apart from the settings above.
CHECK="$(ssh -F "$WORK/ssh_config" -o BatchMode=yes "$VM" '
    echo "macOS        $(sw_vers -productVersion) ($(sw_vers -buildVersion))"
    echo "FileVault    $(fdesetup status)"
    echo "Auto-login   $(defaults read /Library/Preferences/com.apple.loginwindow autoLoginUser 2>&1)"
    echo "SIP          $(csrutil status)"
    echo "Gatekeeper   $(spctl --status)"
    echo "Updates      $(defaults read /Library/Preferences/com.apple.SoftwareUpdate AutomaticallyInstallMacOSUpdates 2>&1)/$(defaults read /Library/Preferences/com.apple.SoftwareUpdate CriticalUpdateInstall 2>&1)/$(defaults read /Library/Preferences/com.apple.SoftwareUpdate ConfigDataInstall 2>&1) (macOS/security/system files; 0 = off)"
    echo "Shutdown     $(sudo -n -l /sbin/shutdown 2>&1)"
    echo "Screen lock  $(sysadminctl -screenLock status 2>&1 | grep -o "screenLock is .*")"
    echo "Sleep        $(pmset -g | awk "/^ sleep/ {print \$2}")/$(pmset -g | awk "/displaysleep/ {print \$2}") (system/display; 0 = never)"')"
echo "$CHECK"
PROBLEMS=""
grep -q "FileVault is Off" <<<"$CHECK"                     || PROBLEMS+=" FileVault"
grep -q "Auto-login   $TART_USER$" <<<"$CHECK"             || PROBLEMS+=" auto-login"
grep -q "status: enabled" <<<"$CHECK"                      || PROBLEMS+=" SIP"
grep -q "assessments enabled" <<<"$CHECK"                  || PROBLEMS+=" Gatekeeper"
grep -q "Updates      0/0/0" <<<"$CHECK"                   || PROBLEMS+=" updates"
grep -q "Shutdown     /sbin/shutdown" <<<"$CHECK"          || PROBLEMS+=" shutdown-rule"
grep -q "Screen lock  screenLock is off" <<<"$CHECK"        || PROBLEMS+=" screen-lock"
grep -q "Sleep        0/0" <<<"$CHECK"                      || PROBLEMS+=" sleep"
if [[ -n "$PROBLEMS" ]]; then
    echo "Not as expected:$PROBLEMS. $VM is left running so you can fix it." >&2
    exit 1
fi

step "Shutting down"
tart_shutdown "$WORK/ssh_config" "$VM"
step "Done: $VM is ready as a base VM. Never start it for tests; vm-smoke.sh --tart clones it."
