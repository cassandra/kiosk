#!/usr/bin/env bash
#
# uninstall-kiosk.sh - Undo install-kiosk.sh and return to the normal desktop.
#
#   Default: stop and remove everything the installer put on the system (the
#            files under rootfs/ say what that is), restore suspend and the
#            desktop login. Keeps the 'kiosk' user and its Chrome profile
#            (signed-in sessions), the settings in /etc/default/kiosk, and the
#            installed packages, so a later re-install picks up where it was.
#
#   --purge: also remove the 'kiosk' user and its home directory, the settings,
#            the packages only the kiosk uses (Google Chrome and its apt source,
#            cage, ddcutil, triggerhappy), and leftovers from the README's manual
#            steps. Leaves the machine as if the kiosk was never installed.
#
# Usage:   sudo ./uninstall-kiosk.sh [--purge]
#          then: sudo reboot
#
set -euo pipefail

KIOSK_USER=kiosk
CONFIG=/etc/default/kiosk
ROOTFS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/rootfs"
# Packages installed only for the kiosk. The others the installer asks for
# (curl, pipewire-bin, sound-theme-freedesktop, pulseaudio-utils) are part of
# a normal Ubuntu desktop and stay.
KIOSK_PACKAGES=(google-chrome-stable cage ddcutil triggerhappy)
# Directories the installer creates; removed only if empty. Never the shared
# parents (/usr/local/bin, /etc/opt, ...).
KIOSK_DIRS=(
    /etc/systemd/system/triggerhappy.service.d
    /etc/systemd/logind.conf.d
    /etc/opt/chrome/policies/managed
    /etc/opt/chrome/policies
    /etc/opt/chrome
)

die() { echo "ERROR: $*" >&2; exit 1; }
step() { echo; echo "==> $*"; }

[ "$(id -u)" -eq 0 ] || die "run with sudo"
PURGE=false
case "${1:-}" in
    --purge) PURGE=true ;;
    "")      ;;
    *)       die "usage: sudo $0 [--purge]" ;;
esac
[ -d "$ROOTFS" ] || die "missing $ROOTFS: copy the whole ubuntu-cage-kiosk directory, not just this script"

# ---------------------------------------------------------------------------
step "Stopping the kiosk"
systemctl disable --now kiosk.service kiosk-brightness.timer kiosk-restart.timer 2>/dev/null || true

# ---------------------------------------------------------------------------
step "Removing installed files"
while IFS= read -r rel; do
    path="/${rel%.in}"
    if [ "$path" = "$CONFIG" ] && ! $PURGE; then
        echo "keeping $CONFIG (settings; --purge removes it)"
        continue
    fi
    if [ -e "$path" ]; then
        rm -f "$path"
        echo "removed $path"
    fi
done < <(cd "$ROOTFS" && find . -type f | sed 's|^\./||' | sort)
for d in "${KIOSK_DIRS[@]}"; do
    rmdir --ignore-fail-on-non-empty "$d" 2>/dev/null || true
done
rm -f /run/kiosk-brightness

# Older versions aliased kiosk.service as the display manager.
if [ "$(readlink /etc/systemd/system/display-manager.service 2>/dev/null)" = /etc/systemd/system/kiosk.service ]; then
    rm -f /etc/systemd/system/display-manager.service
    systemctl enable gdm3.service >/dev/null 2>&1 || true
fi

# ---------------------------------------------------------------------------
step "Restoring suspend and the desktop login"
systemctl unmask sleep.target suspend.target hibernate.target hybrid-sleep.target >/dev/null
systemctl daemon-reload
systemctl set-default graphical.target
# triggerhappy goes back to its packaged defaults (no kiosk triggers).
systemctl try-restart triggerhappy.service 2>/dev/null || true

if $PURGE; then
    # -----------------------------------------------------------------------
    step "Removing the '$KIOSK_USER' user and its home directory"
    if id "$KIOSK_USER" >/dev/null 2>&1; then
        loginctl terminate-user "$KIOSK_USER" 2>/dev/null || true
        systemctl stop "user@$(id -u "$KIOSK_USER").service" 2>/dev/null || true
        userdel -r "$KIOSK_USER" || true     # warns if there is no mail spool
        id "$KIOSK_USER" >/dev/null 2>&1 && die "could not remove user $KIOSK_USER"
        echo "removed user $KIOSK_USER"
    fi

    # -----------------------------------------------------------------------
    step "Removing leftovers from the README's manual steps"
    rm -f "$CONFIG.bak"
    rm -rf /usr/local/share/kiosk

    # -----------------------------------------------------------------------
    step "Removing kiosk-only packages: ${KIOSK_PACKAGES[*]}"
    installed=()
    for p in "${KIOSK_PACKAGES[@]}"; do
        dpkg-query -W -f='${Status}' "$p" 2>/dev/null | grep -q 'ok installed' && installed+=("$p")
    done
    if [ "${#installed[@]}" -gt 0 ]; then
        apt-get purge -y --autoremove "${installed[@]}"
    fi
    # Google's apt source, added by the Chrome package.
    rm -f /etc/apt/sources.list.d/google-chrome.sources /etc/apt/sources.list.d/google-chrome.list
fi

echo
echo "Done. Reboot to return to the desktop:  sudo reboot"
