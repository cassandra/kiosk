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
# Usage:   sudo ./install-kiosk.sh <url>
# Re-run:  safe; re-running with a new URL updates it.
# Revert:  see README.md ("Reverting to the normal desktop").
#
set -euo pipefail

KIOSK_USER=kiosk
CONFIG=/etc/default/kiosk

die() { echo "ERROR: $*" >&2; exit 1; }
step() { echo; echo "==> $*"; }

[ "$(id -u)" -eq 0 ] || die "run with sudo"
URL="${1:-}"
[ -n "$URL" ] || die "usage: sudo $0 <url>"

# shellcheck disable=SC1091
. /etc/os-release
[ "${ID:-}" = ubuntu ] || die "this script targets Ubuntu"
[ "${VERSION_ID%%.*}" -ge 24 ] || die "Ubuntu $VERSION_ID is too old; this script targets 24.04 LTS"
[ "$(dpkg --print-architecture)" = amd64 ] || die "amd64 only (Google Chrome)"

# ---------------------------------------------------------------------------
step "Installing packages (cage, ddcutil, Google Chrome)"
add-apt-repository -y universe >/dev/null 2>&1 || true
apt-get update
apt-get install -y cage ddcutil curl
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
    cat > "$CONFIG" <<'EOF'
# Kiosk settings. Sourced by /usr/local/bin/kiosk-*.
# After editing:  sudo systemctl restart kiosk          (URL / Chrome flags)
#                 sudo kiosk-brightness auto --force     (brightness)

KIOSK_URL=''

# Brightness schedule (24h HHMM) and levels (percent, 1-100).
DAY_START=0630
NIGHT_START=2355
DAY_BRIGHTNESS=100
NIGHT_BRIGHTNESS=15

# Laptop backlight device under /sys/class/backlight (blank = auto-detect).
# If there is no backlight device, ddcutil (DDC/CI) is used instead.
BACKLIGHT_DEVICE=''

# Extra Chrome flags, space separated (e.g. '--force-device-scale-factor=1.25').
EXTRA_CHROME_FLAGS=''

# Laptop lid: 'suspend' (sleep when closed, wake when opened) or 'ignore'.
# Blank = auto: 'suspend' if the machine has a lid, else 'ignore'.
# Applied by re-running install-kiosk.sh. Nothing else ever suspends the kiosk.
LID_SWITCH_ACTION=''
EOF
fi
# Set/replace the URL line without disturbing other settings.
grep -v '^KIOSK_URL=' "$CONFIG" > "$CONFIG.tmp"
printf "KIOSK_URL='%s'\n" "$URL" >> "$CONFIG.tmp"
mv "$CONFIG.tmp" "$CONFIG"
if ! grep -q '^LID_SWITCH_ACTION=' "$CONFIG"; then     # added in a later version
    cat >> "$CONFIG" <<'EOF'

# Laptop lid: 'suspend' (sleep when closed, wake when opened) or 'ignore'.
# Blank = auto: 'suspend' if the machine has a lid, else 'ignore'.
# Applied by re-running install-kiosk.sh. Nothing else ever suspends the kiosk.
LID_SWITCH_ACTION=''
EOF
fi
chmod 644 "$CONFIG"

# ---------------------------------------------------------------------------
step "Installing /usr/local/bin/kiosk-browser"
cat > /usr/local/bin/kiosk-browser <<'EOF'
#!/usr/bin/env bash
# Launched by cage (via kiosk.service) as the kiosk user.
set -u
# shellcheck disable=SC1091
. /etc/default/kiosk

DATA="$HOME/.config/kiosk-chrome"
PREFS="$DATA/Default/Preferences"

# After a power loss/crash, Chrome would show a "Restore pages?" bubble.
# Mark the previous session as cleanly exited so it never appears.
if [ -f "$PREFS" ]; then
    sed -i -e 's/"exited_cleanly":false/"exited_cleanly":true/' \
           -e 's/"exit_type":"[^"]*"/"exit_type":"Normal"/' "$PREFS"
fi

# shellcheck disable=SC2086  # EXTRA_CHROME_FLAGS is intentionally word-split
exec /usr/bin/google-chrome-stable \
    --user-data-dir="$DATA" \
    --ozone-platform=wayland \
    --kiosk \
    --autoplay-policy=no-user-gesture-required \
    --no-first-run \
    --no-default-browser-check \
    --noerrdialogs \
    --disable-infobars \
    --hide-crash-restore-bubble \
    --password-store=basic \
    --check-for-update-interval=31536000 \
    --overscroll-history-navigation=0 \
    --disable-pinch \
    --disable-features=Translate,TouchpadOverscrollHistoryNavigation \
    ${EXTRA_CHROME_FLAGS:-} \
    "$KIOSK_URL"
EOF
chmod 755 /usr/local/bin/kiosk-browser

# Chrome policies: belt-and-suspenders for autoplay, and quiet the prompts.
install -d -m 755 /etc/opt/chrome/policies/managed
cat > /etc/opt/chrome/policies/managed/kiosk.json <<'EOF'
{
  "AutoplayAllowed": true,
  "TranslateEnabled": false,
  "PasswordManagerEnabled": false,
  "BrowserSignin": 0,
  "MetricsReportingEnabled": false,
  "DefaultBrowserSettingEnabled": false,
  "PromotionalTabsEnabled": false
}
EOF

# ---------------------------------------------------------------------------
step "Installing /usr/local/bin/kiosk-brightness"
cat > /usr/local/bin/kiosk-brightness <<'EOF'
#!/usr/bin/env bash
# kiosk-brightness [auto|day|night|<percent>] [--force]
#   auto: pick day/night level from the schedule in /etc/default/kiosk.
#   Only touches the hardware when the target level changes (so a manual
#   adjustment sticks until the next day/night transition), unless --force.
set -eu
# shellcheck disable=SC1091
. /etc/default/kiosk

mode="${1:-auto}"; force="${2:-}"
now=$((10#$(date +%H%M)))
day=$((10#$DAY_START)); night=$((10#$NIGHT_START))

case "$mode" in
    auto)  if [ "$now" -ge "$day" ] && [ "$now" -lt "$night" ]; then pct=$DAY_BRIGHTNESS
           else pct=$NIGHT_BRIGHTNESS; fi ;;
    day)   pct=$DAY_BRIGHTNESS ;;
    night) pct=$NIGHT_BRIGHTNESS ;;
    *[!0-9]*|'') echo "usage: $0 [auto|day|night|<percent>] [--force]" >&2; exit 2 ;;
    *)     pct=$mode ;;
esac
[ "$pct" -lt 1 ] && pct=1
[ "$pct" -gt 100 ] && pct=100

state=/run/kiosk-brightness
if [ "$mode" = auto ] && [ "$force" != --force ] && [ "$(cat "$state" 2>/dev/null)" = "$pct" ]; then
    exit 0
fi

bl=""
if [ -n "${BACKLIGHT_DEVICE:-}" ]; then
    bl="/sys/class/backlight/$BACKLIGHT_DEVICE"
elif [ -d /sys/class/backlight/intel_backlight ]; then
    bl=/sys/class/backlight/intel_backlight
else
    bl=$(find /sys/class/backlight -mindepth 1 -maxdepth 1 2>/dev/null | head -n1)
fi

if [ -n "$bl" ] && [ -w "$bl/brightness" ]; then
    max=$(cat "$bl/max_brightness")
    raw=$(( max * pct / 100 )); [ "$raw" -lt 1 ] && raw=1
    echo "$raw" > "$bl/brightness"
    echo "backlight $(basename "$bl") -> ${pct}% ($raw/$max)"
else
    ddcutil setvcp 10 "$pct"
    echo "DDC/CI monitor -> ${pct}%"
fi
echo "$pct" > "$state"
EOF
chmod 755 /usr/local/bin/kiosk-brightness
echo i2c-dev > /etc/modules-load.d/kiosk-i2c.conf     # needed by ddcutil
modprobe i2c-dev 2>/dev/null || true

# ---------------------------------------------------------------------------
step "Installing /usr/local/bin/kiosk-volume + volume keys (triggerhappy)"
# cage has no desktop to handle the volume keys (GNOME normally does) and Chrome
# ignores them, so triggerhappy reads the keys straight from the input devices
# and calls kiosk-volume. Works for any keyboard with volume/mute keys.
cat > /usr/local/bin/kiosk-volume <<'EOF'
#!/usr/bin/env bash
# kiosk-volume: change the kiosk session's audio volume (PipeWire, default output).
#   kiosk-volume up | down | mute | <percent>   e.g. kiosk-volume 60
#   kiosk-volume                                 show current volume
# Runs as the kiosk user (volume keys) or via root (sudo kiosk-volume 60).
set -u
U=kiosk
uid=$(id -u "$U") || exit 1
if [ "$(id -u)" -ne "$uid" ]; then          # always run as the kiosk user
    exec runuser -u "$U" -- env XDG_RUNTIME_DIR="/run/user/$uid" "$0" "$@"
fi
export XDG_RUNTIME_DIR=/run/user/$uid
SINK=@DEFAULT_AUDIO_SINK@
STEP=5%
SOUND=/usr/share/sounds/freedesktop/stereo/audio-volume-change.oga

# One change at a time: a relative step (5%+) reads then writes the volume, so
# overlapping key presses could otherwise lose steps.
exec 9>"$XDG_RUNTIME_DIR/kiosk-volume.lock"
flock 9

click_later() {
    # No on-screen indicator under cage, so a click confirms the new level.
    # Debounced: one click ~0.25 s after the LAST press, so rapid presses or a
    # held key give one clean click at the final level instead of a jumble.
    [ -r "$SOUND" ] && command -v pw-play >/dev/null || return 0
    local seqf="$XDG_RUNTIME_DIR/kiosk-volume.seq" me
    me=$(date +%s%N); echo "$me" > "$seqf"
    ( sleep 0.25
      [ "$(cat "$seqf" 2>/dev/null)" = "$me" ] && pw-play "$SOUND"
    ) 9>&- </dev/null >/dev/null 2>&1 &     # 9>&-: don't hold the lock while waiting
}

case "${1:-}" in
    up)      wpctl set-mute "$SINK" 0; wpctl set-volume -l 1.0 "$SINK" "$STEP+"; click_later ;;
    down)    wpctl set-mute "$SINK" 0; wpctl set-volume "$SINK" "$STEP-"; click_later ;;
    mute)    wpctl set-mute "$SINK" toggle ;;
    "")      wpctl get-volume "$SINK" ;;
    *[0-9]*) wpctl set-mute "$SINK" 0; wpctl set-volume -l 1.0 "$SINK" "${1%\%}%" ;;
    *)       echo "usage: kiosk-volume [up|down|mute|<percent>]" >&2; exit 2 ;;
esac
EOF
chmod 755 /usr/local/bin/kiosk-volume

apt-get install -y triggerhappy pipewire-bin sound-theme-freedesktop pulseaudio-utils  # pactl: README audio steps
mkdir -p /etc/triggerhappy/triggers.d
cat > /etc/triggerhappy/triggers.d/kiosk-volume.conf <<'EOF'
# key           value  command     (value 1 = press, 2 = held/auto-repeat)
KEY_VOLUMEUP    1      /usr/local/bin/kiosk-volume up
KEY_VOLUMEUP    2      /usr/local/bin/kiosk-volume up
KEY_VOLUMEDOWN  1      /usr/local/bin/kiosk-volume down
KEY_VOLUMEDOWN  2      /usr/local/bin/kiosk-volume down
KEY_MUTE        1      /usr/local/bin/kiosk-volume mute
EOF
# Run triggerhappy's commands as the kiosk user (owner of the PipeWire session)
# instead of the packaged default 'nobody'.
mkdir -p /etc/systemd/system/triggerhappy.service.d
cat > /etc/systemd/system/triggerhappy.service.d/kiosk.conf <<EOF
[Service]
ExecStart=
ExecStart=/usr/sbin/thd --triggers /etc/triggerhappy/triggers.d/ --socket /run/thd.socket --user $KIOSK_USER --deviceglob /dev/input/event*
EOF

# ---------------------------------------------------------------------------
step "Installing systemd units"
cat > /etc/pam.d/kiosk <<'EOF'
# PAM stack for kiosk.service: gives the kiosk user a real logind session
# on seat0/tty1 (device access, XDG_RUNTIME_DIR, PipeWire user services).
auth     required pam_unix.so nullok
account  required pam_unix.so
session  required pam_loginuid.so
session  required pam_unix.so
session  required pam_systemd.so
EOF

cat > /etc/systemd/system/kiosk.service <<EOF
[Unit]
Description=Kiosk (cage + Chrome on tty1)
After=systemd-user-sessions.service plymouth-quit-wait.service network-online.target
Wants=network-online.target dbus.socket systemd-logind.service
After=dbus.socket systemd-logind.service
ConditionPathExists=/dev/tty1
Conflicts=getty@tty1.service
After=getty@tty1.service

[Service]
Type=simple
User=$KIOSK_USER
PAMName=kiosk
Environment=XDG_SESSION_TYPE=wayland
ExecStart=/usr/bin/cage -s -- /usr/local/bin/kiosk-browser
Restart=always
RestartSec=5
UtmpIdentifier=tty1
UtmpMode=user
TTYPath=/dev/tty1
TTYReset=yes
TTYVHangup=yes
TTYVTDisallocate=yes
StandardInput=tty-fail
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/kiosk-brightness.service <<'EOF'
[Unit]
Description=Apply kiosk day/night brightness

[Service]
Type=oneshot
ExecStart=/usr/local/bin/kiosk-brightness auto
EOF

cat > /etc/systemd/system/kiosk-brightness.timer <<'EOF'
[Unit]
Description=Check kiosk day/night brightness every 5 minutes

[Timer]
OnBootSec=45s
OnCalendar=*:0/5
AccuracySec=30s

[Install]
WantedBy=timers.target
EOF

cat > /etc/systemd/system/kiosk-restart.service <<'EOF'
[Unit]
Description=Daily kiosk browser restart

[Service]
Type=oneshot
ExecStart=/usr/bin/systemctl restart kiosk.service
EOF

cat > /etc/systemd/system/kiosk-restart.timer <<'EOF'
[Unit]
Description=Restart kiosk browser daily at 04:30

[Timer]
OnCalendar=*-*-* 04:30:00

[Install]
WantedBy=timers.target
EOF

# ---------------------------------------------------------------------------
step "Power: never idle-suspend; lid behavior"
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
echo "lid close -> $LID_SWITCH_ACTION"

install -d -m 755 /etc/systemd/logind.conf.d
cat > /etc/systemd/logind.conf.d/kiosk.conf <<EOF
[Login]
HandleLidSwitch=$LID_SWITCH_ACTION
HandleLidSwitchExternalPower=$LID_SWITCH_ACTION
# Lid closed with an external monitor attached: keep running on that monitor.
HandleLidSwitchDocked=ignore
IdleAction=ignore
EOF

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
