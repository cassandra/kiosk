#!/usr/bin/env bash
#
# install-kiosk.sh - Turn an Ubuntu 24.04 LTS (amd64) machine into a full-screen
# single-URL kiosk:
#
#   - Dedicated 'kiosk' user, auto-started at boot on tty1 by systemd.
#   - cage (single-app Wayland compositor): no desktop, no panels, no chrome.
#   - Google Chrome in --kiosk mode with audio autoplay allowed.
#   - Never idle-sleeps; laptops suspend on lid close (configurable).
#   - Restarts Chrome if it exits.
#   - Scheduled day/night brightness (laptop backlight or DDC/CI monitor).
#   - Daily 04:30 browser restart (clears leaks, picks up Chrome updates).
#   - Keyboard volume/mute keys work (triggerhappy -> kiosk-volume).
#
# The files it installs are under rootfs/, at the same paths they get on the
# system. Files ending in .in are templates: @KIOSK_USER@ and
# @LID_SWITCH_ACTION@ are filled in, and the .in suffix is dropped.
#
# Usage:   sudo ./install-kiosk.sh <url>
# Re-run:  safe; re-running with a new URL updates it.
# Revert:  see README.md ("Reverting to the normal desktop").
#
set -euo pipefail

KIOSK_USER=kiosk
CONFIG=/etc/default/kiosk
ROOTFS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/rootfs"

die() { echo "ERROR: $*" >&2; exit 1; }
step() { echo; echo "==> $*"; }

# install_file <mode> <path>: copy rootfs/<path> to /<path>.
install_file() {
    install -D -m "$1" "$ROOTFS/$2" "/$2"
}

# install_template <mode> <path>: fill in rootfs/<path>.in and write /<path>.
install_template() {
    install -d -m 755 "$(dirname "/$2")"
    sed -e "s|@KIOSK_USER@|$KIOSK_USER|g" \
        -e "s|@LID_SWITCH_ACTION@|$LID_SWITCH_ACTION|g" \
        "$ROOTFS/$2.in" > "/$2"
    chmod "$1" "/$2"
}

[ "$(id -u)" -eq 0 ] || die "run with sudo"
URL="${1:-}"
[ -n "$URL" ] || die "usage: sudo $0 <url>"
[ -d "$ROOTFS" ] || die "missing $ROOTFS: copy the whole ubuntu-cage-kiosk directory, not just this script"

# shellcheck disable=SC1091
. /etc/os-release
[ "${ID:-}" = ubuntu ] || die "this script targets Ubuntu"
[ "${VERSION_ID%%.*}" -ge 24 ] || die "Ubuntu $VERSION_ID is too old; this script targets 24.04 LTS"
[ "$(dpkg --print-architecture)" = amd64 ] || die "amd64 only (Google Chrome)"

# ---------------------------------------------------------------------------
step "Installing packages (cage, ddcutil, Google Chrome, triggerhappy)"
add-apt-repository -y universe >/dev/null 2>&1 || true
apt-get update
# pulseaudio-utils: pactl, used by the README's audio steps.
apt-get install -y cage ddcutil curl \
    triggerhappy pipewire-bin sound-theme-freedesktop pulseaudio-utils
if ! command -v google-chrome-stable >/dev/null 2>&1; then
    tmp=$(mktemp -d); chmod 755 "$tmp"
    curl -fsSL -o "$tmp/chrome.deb" \
        https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb
    # The .deb's postinst adds Google's apt repo, so Chrome updates with apt.
    apt-get install -y "$tmp/chrome.deb"
    rm -rf "$tmp"
fi

# ---------------------------------------------------------------------------
step "Creating '$KIOSK_USER' user"
if ! id "$KIOSK_USER" >/dev/null 2>&1; then
    useradd -m -s /bin/bash -c "Kiosk browser" "$KIOSK_USER"   # password locked
fi
for g in audio video render input; do
    getent group "$g" >/dev/null && usermod -aG "$g" "$KIOSK_USER"
done

# ---------------------------------------------------------------------------
step "Writing $CONFIG"
if [ ! -f "$CONFIG" ]; then
    install_file 644 etc/default/kiosk
fi
# Set/replace the URL line without disturbing other settings.
grep -v '^KIOSK_URL=' "$CONFIG" > "$CONFIG.tmp"
printf "KIOSK_URL='%s'\n" "$URL" >> "$CONFIG.tmp"
mv "$CONFIG.tmp" "$CONFIG"
if ! grep -q '^LID_SWITCH_ACTION=' "$CONFIG"; then     # added in a later version
    { echo; sed -n '/^# Laptop lid:/,/^LID_SWITCH_ACTION=/p' "$ROOTFS/etc/default/kiosk"; } >> "$CONFIG"
fi
chmod 644 "$CONFIG"

# Lid action: the setting, or auto-detected when blank.
# shellcheck disable=SC1090
LID_SWITCH_ACTION=$( . "$CONFIG"; echo "${LID_SWITCH_ACTION:-}" )
if [ -z "$LID_SWITCH_ACTION" ]; then
    if compgen -G '/proc/acpi/button/lid/*/state' >/dev/null; then
        LID_SWITCH_ACTION=suspend
    else
        LID_SWITCH_ACTION=ignore
    fi
fi
case "$LID_SWITCH_ACTION" in
    suspend|ignore) ;;
    *) die "LID_SWITCH_ACTION must be 'suspend' or 'ignore' (got '$LID_SWITCH_ACTION')" ;;
esac

# ---------------------------------------------------------------------------
step "Installing the browser launcher and Chrome policy"
install_file 755 usr/local/bin/kiosk-browser
# Policy: belt-and-suspenders for autoplay, and quiet the prompts.
install_file 644 etc/opt/chrome/policies/managed/kiosk.json

# ---------------------------------------------------------------------------
step "Installing kiosk-brightness"
install_file 755 usr/local/bin/kiosk-brightness
install_file 644 etc/modules-load.d/kiosk-i2c.conf     # i2c-dev, needed by ddcutil
modprobe i2c-dev 2>/dev/null || true

# ---------------------------------------------------------------------------
step "Installing kiosk-volume + volume keys (triggerhappy)"
# cage has no desktop to handle the volume keys (GNOME normally does) and Chrome
# ignores them, so triggerhappy reads the keys straight from the input devices
# and calls kiosk-volume. Works for any keyboard with volume/mute keys.
install_template 755 usr/local/bin/kiosk-volume
install_file 644 etc/triggerhappy/triggers.d/kiosk-volume.conf
# Run triggerhappy's commands as the kiosk user (owner of the PipeWire session)
# instead of the packaged default 'nobody'.
install_template 644 etc/systemd/system/triggerhappy.service.d/kiosk.conf

# ---------------------------------------------------------------------------
step "Installing systemd units"
# PAM stack for kiosk.service: gives the kiosk user a real logind session.
install_file 644 etc/pam.d/kiosk
install_template 644 etc/systemd/system/kiosk.service
install_file 644 etc/systemd/system/kiosk-brightness.service
install_file 644 etc/systemd/system/kiosk-brightness.timer
install_file 644 etc/systemd/system/kiosk-restart.service
install_file 644 etc/systemd/system/kiosk-restart.timer

# ---------------------------------------------------------------------------
step "Power: never idle-suspend; lid close -> $LID_SWITCH_ACTION"
install_template 644 etc/systemd/logind.conf.d/kiosk.conf

# No desktop session runs, so nothing else will suspend the machine.
# Hibernate/hybrid-sleep stay masked; suspend only if the lid may trigger it.
systemctl mask hibernate.target hybrid-sleep.target >/dev/null
if [ "$LID_SWITCH_ACTION" = suspend ]; then
    systemctl unmask sleep.target suspend.target >/dev/null
else
    systemctl mask sleep.target suspend.target >/dev/null
fi

# ---------------------------------------------------------------------------
step "Booting to text mode (multi-user.target) so the desktop login never starts"
# The login screen (GDM) is only started by graphical.target. Booting to
# multi-user.target keeps it from starting, without touching GDM itself, so
# package upgrades can't undo this (gdm3 upgrades rewrite display-manager.service).
#
# Clean up the older approach (kiosk aliased as display-manager.service).
if [ "$(readlink /etc/systemd/system/display-manager.service 2>/dev/null)" = /etc/systemd/system/kiosk.service ]; then
    rm -f /etc/systemd/system/display-manager.service
    systemctl enable gdm3.service >/dev/null 2>&1 || true    # restore normal state for reverting
fi
systemctl daemon-reload
systemctl set-default multi-user.target
systemctl reenable kiosk.service                          # drops old graphical.target link
systemctl enable kiosk-brightness.timer kiosk-restart.timer
systemctl enable triggerhappy.service >/dev/null 2>&1 || true
systemctl restart triggerhappy.service

echo
echo "Done. Kiosk URL: $URL"
echo "Reboot to start the kiosk:  sudo reboot"
