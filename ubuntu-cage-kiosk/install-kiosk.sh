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
#   - Waits for the server at start, and recovers from a page that failed to
#     load during a server outage (start page + kiosk-watchdog).
#   - Scheduled day/night brightness (laptop backlight or DDC/CI monitor).
#   - Scheduled browser restart (daily, or only after a Chrome update), and
#     Chrome updated by Ubuntu's automatic updates.
#   - Keyboard volume/mute keys work (triggerhappy -> kiosk-volume).
#
# The files it installs are under rootfs/, at the same paths they get on the
# system. Files ending in .in are templates: @KIOSK_USER@, @LID_SWITCH_ACTION@
# and @RESTART_TIME@ are filled in, and the .in suffix is dropped.
#
# Usage:   sudo ./install-kiosk.sh [--config <file>] [<url>]
#   <url>            the page to show; overrides KIOSK_URL from any config file.
#   --config <file>  settings to use (see rootfs/etc/default/kiosk for all of them).
#                    Each setting comes from, in order: <url> (KIOSK_URL only),
#                    --config <file>, the existing /etc/default/kiosk, the default.
# Re-run:  safe; keeps existing settings unless overridden.
# Revert:  sudo ./uninstall-kiosk.sh [--purge]  (see README.md)
#
set -euo pipefail

KIOSK_USER=kiosk
CONFIG=/etc/default/kiosk
ROOTFS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/rootfs"
CONFIG_TEMPLATE="$ROOTFS/etc/default/kiosk"

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
        -e "s|@RESTART_TIME@|$RESTART_TIME|g" \
        "$ROOTFS/$2.in" > "/$2"
    chmod "$1" "/$2"
}

# config_keys <file>: the setting names assigned in <file>.
config_keys() {
    sed -n 's/^\([A-Z_][A-Z0-9_]*\)=.*/\1/p' "$1"
}

# config_get <file> <key>: print <key>'s value from <file>; fails if <file>
# doesn't set it.
config_get() {
    # shellcheck disable=SC1090
    ( set +u; . "$1"; [ -n "${!2+x}" ] || exit 1; printf '%s' "${!2}" )
}

# config_value <key>: the value <key> gets, by the precedence in the header.
config_value() {
    local f
    if [ "$1" = KIOSK_URL ] && [ -n "$URL" ]; then
        printf '%s' "$URL"
        return
    fi
    for f in "$CONFIG_FILE" "$CONFIG" "$CONFIG_TEMPLATE"; do
        [ -n "$f" ] && [ -f "$f" ] && config_get "$f" "$1" && return
    done
}

# warn_unknown_settings <file>: report settings in <file> that aren't in the
# template (typos, or settings that no longer exist). They are not kept.
warn_unknown_settings() {
    local key
    for key in $(config_keys "$1"); do
        grep -q "^$key=" "$CONFIG_TEMPLATE" || echo "WARNING: ignoring unknown setting $key in $1" >&2
    done
}

# write_config: rewrite $CONFIG from the template, with each setting's value
# from config_value. New settings get their defaults; comments come from the
# template.
write_config() {
    local tmp line key value
    tmp=$(mktemp)
    while IFS= read -r line; do
        if [[ $line =~ ^([A-Z_][A-Z0-9_]*)= ]]; then
            key=${BASH_REMATCH[1]}
            value=$(config_value "$key")
            printf "%s='%s'\n" "$key" "${value//\'/\'\\\'\'}" >> "$tmp"
        else
            printf '%s\n' "$line" >> "$tmp"
        fi
    done < "$CONFIG_TEMPLATE"
    install -m 644 "$tmp" "$CONFIG"
    rm -f "$tmp"
}

usage() { echo "usage: sudo $0 [--config <file>] [<url>]" >&2; exit 2; }

URL=''
CONFIG_FILE=''
while [ $# -gt 0 ]; do
    case "$1" in
        --config) [ $# -ge 2 ] || usage; CONFIG_FILE=$2; shift 2 ;;
        -*)       usage ;;
        *)        [ -z "$URL" ] || usage; URL=$1; shift ;;
    esac
done

[ "$(id -u)" -eq 0 ] || die "run with sudo"
[ -d "$ROOTFS" ] || die "missing $ROOTFS: copy the whole ubuntu-cage-kiosk directory, not just this script"
[ -z "$CONFIG_FILE" ] || [ -f "$CONFIG_FILE" ] || die "no such config file: $CONFIG_FILE"
KIOSK_URL=$(config_value KIOSK_URL)
[ -n "$KIOSK_URL" ] || die "no URL: pass <url>, or set KIOSK_URL in the --config file"

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
apt-get install -y cage ddcutil curl python3 \
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
for f in "$CONFIG_FILE" "$CONFIG"; do
    [ -n "$f" ] && [ -f "$f" ] && warn_unknown_settings "$f"
done
write_config

# Lid action: the setting, or auto-detected when blank.
LID_SWITCH_ACTION=$(config_get "$CONFIG" LID_SWITCH_ACTION)
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

# Restart check time: HHMM in the settings, HH:MM for systemd; blank = none.
RESTART_TIME=$(config_get "$CONFIG" RESTART_TIME)
if [ -n "$RESTART_TIME" ]; then
    [[ $RESTART_TIME =~ ^([01][0-9]|2[0-3])[0-5][0-9]$ ]] \
        || die "RESTART_TIME must be 24h HHMM or blank (got '$RESTART_TIME')"
    RESTART_TIME="${RESTART_TIME:0:2}:${RESTART_TIME:2:2}"
fi

AUTO_UPDATE_CHROME=$(config_get "$CONFIG" AUTO_UPDATE_CHROME)
case "$AUTO_UPDATE_CHROME" in
    yes|no) ;;
    *) die "AUTO_UPDATE_CHROME must be 'yes' or 'no' (got '$AUTO_UPDATE_CHROME')" ;;
esac

# ---------------------------------------------------------------------------
step "Installing the browser launcher, start page, watchdog and Chrome policy"
install_file 755 usr/local/bin/kiosk-browser
install_file 644 usr/local/share/kiosk/start.html
install_file 755 usr/local/bin/kiosk-watchdog
# Policy: belt-and-suspenders for autoplay, and quiet the prompts.
install_file 644 etc/opt/chrome/policies/managed/kiosk.json

# ---------------------------------------------------------------------------
step "Chrome updates: AUTO_UPDATE_CHROME=$AUTO_UPDATE_CHROME"
if [ "$AUTO_UPDATE_CHROME" = yes ]; then
    install_file 644 etc/apt/apt.conf.d/51kiosk-chrome-updates
else
    rm -f /etc/apt/apt.conf.d/51kiosk-chrome-updates
fi

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
install_template 644 etc/systemd/system/kiosk-watchdog.service
install_file 644 etc/systemd/system/kiosk-brightness.service
install_file 644 etc/systemd/system/kiosk-brightness.timer
install_file 755 usr/local/bin/kiosk-restart
install_file 644 etc/systemd/system/kiosk-restart.service
if [ -n "$RESTART_TIME" ]; then
    install_template 644 etc/systemd/system/kiosk-restart.timer
else
    systemctl disable --now kiosk-restart.timer 2>/dev/null || true
    rm -f /etc/systemd/system/kiosk-restart.timer
fi

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
systemctl enable kiosk-watchdog.service                   # runs alongside kiosk.service
systemctl enable kiosk-brightness.timer
if [ -n "$RESTART_TIME" ]; then
    systemctl enable kiosk-restart.timer
    systemctl restart kiosk-restart.timer     # pick up a changed time now
fi
systemctl enable triggerhappy.service >/dev/null 2>&1 || true
systemctl restart triggerhappy.service

echo
echo "Done. Kiosk URL: $KIOSK_URL"
echo "Reboot to start the kiosk:  sudo reboot"
