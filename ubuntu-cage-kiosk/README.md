# Ubuntu + cage + Chrome kiosk

`install-kiosk.sh` turns an Ubuntu 24.04 LTS (amd64) machine into a kiosk that shows one
web page full-screen, with no desktop and no browser controls. The same script works on
laptops (built-in screen) and on small desktops with an external touch monitor.

For the hardware it has been run on, see [EXAMPLE-SETUP.md](EXAMPLE-SETUP.md).

## What it sets up

| Piece | What it does |
|---|---|
| `kiosk` user | Locked-password account that runs the browser |
| `kiosk.service` | Starts **cage** (a compositor that runs one app full-screen) on tty1 at boot, running Chrome; restarts it if it exits. If memory runs short, the kernel kills other processes before the browser (`OOMScoreAdjust`). If the machine also runs containers, give them memory limits too. |
| Boot target `multi-user.target` | Boots to text mode so the GNOME login screen (GDM) never starts. GDM stays installed and untouched. |
| `/usr/local/bin/kiosk-browser` | Chrome `--kiosk` with autoplay allowed, no first-run or translate prompts, no "Restore pages?" after power loss, no swipe-back or pinch-zoom |
| Start page + `kiosk-watchdog.service` | Server-down recovery; see "When the server is down" below |
| `/etc/opt/chrome/policies/managed/kiosk.json` | Chrome policies: `AutoplayAllowed` (backup in case the flag ever stops working), no translate/password/sign-in prompts, and keyboard escapes closed off: no incognito or guest windows, new profiles, printing, ending processes from the task manager, or `chrome://` pages (history, downloads, settings, ...). |
| `/etc/default/kiosk` | **Settings**: URL, day/night times and brightness, extra Chrome flags, lid action (see "Settings") |
| `kiosk-brightness` + timer | Every 5 min, applies the day/night level. Laptop: sysfs backlight. External monitor: `ddcutil` (DDC/CI). A manual change sticks until the next day/night switch. If the screen has neither, it says so once in its log and pauses until reboot; `DIMMING='no'` turns scheduled dimming off. |
| `kiosk-volume` + `triggerhappy` | Keyboard volume/mute keys work without a desktop (see "Volume keys" below) |
| `kiosk-restart` + timer | At `RESTART_TIME` (default 04:30), restarts the browser: every day, or with `RESTART_DAILY='no'` only if Chrome was updated since it started |
| `/etc/apt/apt.conf.d/51kiosk-chrome-updates` | With `AUTO_UPDATE_CHROME='yes'` (default), Ubuntu's automatic updates also update Chrome. Without it they never do: they only cover Ubuntu's own packages. |
| logind drop-in + sleep targets | Never suspends from inactivity. Laptops suspend when the lid closes and resume when it opens; machines without a lid never sleep. Set `LID_SWITCH_ACTION` in `/etc/default/kiosk` (`suspend`/`ignore`) and re-run the installer to change it. With an external monitor attached, closing the lid is ignored. |

## Install

Start from a fresh Ubuntu 24.04 LTS Desktop install with `openssh-server` installed, so you
can manage the machine remotely.

Clone this repository on the machine and run the installer:

```sh
ssh <machine>
sudo apt install git                       # not part of a default Ubuntu Desktop install
git clone https://github.com/cassandra/kiosk.git
sudo ./kiosk/ubuntu-cage-kiosk/install-kiosk.sh 'http://<server>:<port>/<path>'
sudo reboot
```

Quote the URL: query strings contain `&`. Re-running the script is safe, and keeps the
existing settings unless you override them (see "Settings").

To update later:

```sh
cd kiosk && git pull
sudo ./ubuntu-cage-kiosk/install-kiosk.sh && sudo reboot
```

The installer needs the whole directory (it installs the files under `rootfs/`), so if you
copy it rather than clone it, copy all of `ubuntu-cage-kiosk/`.

If the page needs a sign-in, sign in once on the machine itself. Chrome keeps cookies and
sessions in `~kiosk/.config/kiosk-chrome`, so they survive restarts and reboots. On a
touch-only machine with no keyboard, either the web app provides its own on-screen input or
you plug in a USB keyboard for this step.

## Settings

All settings live in `/etc/default/kiosk`. The defaults, with a comment for each setting, are
in [`rootfs/etc/default/kiosk`](rootfs/etc/default/kiosk). Each setting is marked with when a
change takes effect: `[restart]` (restart the kiosk), `[timer]` (the next time its timer
runs) or `[install]` (re-run the installer).

To choose settings at install time, write a file with just the settings you want to change
(see the defaults file for the names), and pass it in. From `kiosk/ubuntu-cage-kiosk`:

```sh
mkdir -p local                              # local/ is git-ignored
cat > local/<machine>.conf <<'EOF'
KIOSK_URL='http://<server>:<port>/<path>'
AUDIO_PROFILE='output:hdmi-stereo'
EOF
sudo ./install-kiosk.sh --config local/<machine>.conf
```

List only what you change rather than copying the whole defaults file: a `--config` file
overrides the defaults, so a full copy would keep old values even after a default improves.
Keeping one file per machine makes re-installs repeatable. Each setting comes from, in
order: the `<url>` argument (for `KIOSK_URL` only), the `--config` file, the existing
`/etc/default/kiosk`, then the default. The installer rewrites `/etc/default/kiosk` from the
template each time, keeping values but not comments you added, and adding any new settings
with their defaults. It warns about settings it doesn't recognize, such as typos.

## Files

`rootfs/` holds every file the installer puts on the system, at the same path it gets there
(`rootfs/usr/local/bin/kiosk-browser` becomes `/usr/local/bin/kiosk-browser`). Files ending
in `.in` are templates: the installer fills in placeholders such as `@KIOSK_USER@` and
drops the `.in`. `etc/default/kiosk` is the settings template described above.

## Verify

After installing, check the things a kiosk is for:

1. **Boot:** `systemctl get-default` shows `multi-user.target`, `systemctl status kiosk`
   is active, and the page fills the screen.
2. **Touch:** taps work, and swiping or pinching does not navigate away from the page.
3. **Sound with nobody touching it:** after a reboot, without touching the screen,
   trigger something on the page that plays audio. This is what the autoplay settings are for.
4. **Brightness:** `sudo kiosk-brightness 20`, then `sudo kiosk-brightness auto --force`.
5. **Power loss:** pull the plug and restore it. The machine should boot unattended to the
   page, with sound still on the right output. On desktops this needs the BIOS/UEFI
   "After Power Loss" setting set to "Power On".
6. **Lid (laptops):** close the lid, wait about 30 seconds, open it. The page comes back.
   To confirm it really suspended:
   `journalctl -b --no-pager | grep -E "Lid (closed|opened)|PM: suspend (entry|exit)" | tail`

## When the server is down

A web app can handle an outage itself while its page stays loaded (many keep polling and
show a message). What it can't recover from is a page that failed to load: if the server is
unreachable when the browser loads a page (someone taps a link during an outage, or the
browser starts during one), the browser shows its own error page and the app's code is gone.
Two pieces recover from this without anyone logging in:

- **Start page** (`/usr/local/share/kiosk/start.html`): Chrome always starts here, not at
  `KIOSK_URL` directly. It checks every 5 seconds whether the server answers, then loads
  `KIOSK_URL`. It shows what it is waiting for and since when; **START** loads the page
  right away.
- **`kiosk-watchdog`**: every 5 seconds, closes any extra tabs, then asks Chrome what the tab shows. If it is the
  browser's error page, or a 502/503/504 page (e.g. a proxy in front of an app that is
  still starting), it sends the browser to the start page. Pages that loaded normally are
  never touched, including ones showing the app's own outage message. If the tab stops
  responding (it crashed, "Aw, Snap!", or its script is stuck) for 3 checks in a row, about
  20 seconds, it is restarted at the start page too.

The watchdog talks to Chrome through its DevTools port (`WATCHDOG_PORT`, default 9222),
which Chrome only opens on 127.0.0.1: other machines can't reach it, but any program on
the kiosk itself can control the browser through it. Set `WATCHDOG_PORT=''` to turn the
watchdog off. Its log: `journalctl -u kiosk-watchdog -b`.

The start page can only tell whether the server answers, not with what status. If it
answers with an error page while the app is starting, the browser goes back and forth
between that page and the start page every 5-10 seconds until the app is ready.

## Day-to-day

```sh
sudoedit /etc/default/kiosk                # change URL / schedule / levels
sudo systemctl restart kiosk               # reload: restarts Chrome on KIOSK_URL (~5 s, no reboot)
sudo kiosk-brightness auto --force         # re-apply brightness now
sudo kiosk-brightness 40                   # one-off level (sticks until next day/night switch)
journalctl -u kiosk -b                     # browser/cage logs
journalctl -u kiosk-watchdog -b            # server-down recovery
```

`sudo systemctl restart kiosk` is also the way out if the page ever reaches a dead end with
no in-page way back: the kiosk has no browser controls.

**Keyboard shortcuts:** on a kiosk with a keyboard, Chrome's shortcuts still work, but the
policies above turn the risky ones into no-ops or a "blocked" page, and `kiosk-watchdog`
closes any tab other than the kiosk's own within about 5 seconds (new tab, history, a new
window or split view). What remains: Ctrl+W or Alt+F4 closes the browser, and it restarts
at the start page about 5 seconds later; Alt+Left goes back within the page's history;
Ctrl+L does nothing in kiosk mode. With no keyboard attached none of
this applies. A web app that opens pop-ups or new tabs will have them closed too.
Ctrl+Shift+I shows a dismissable "not allowed" message. Don't add Chrome's
`DeveloperToolsAvailability` policy to block developer tools: it also blocks the DevTools
connection `kiosk-watchdog` needs to read the page.

**Getting to a text console:** press Ctrl+Alt+F2 to switch to a login terminal
(cage is started with `-s` to allow this), and Ctrl+Alt+F1 to return.
On a Mac keyboard you may need Fn as well.

**Volume keys:** keyboard volume up/down/mute keys work (on a MacBook, the speaker
keys on the top row). cage has no desktop to handle them, so `triggerhappy` reads the keys
directly and runs `kiosk-volume`. There's no on-screen indicator, so a click sound plays
about a quarter second after the last press, at the new level (rapid presses or a held key
give one click at the end). Steps are applied one at a time, so none are lost. Volume is
capped at 100%. To see which key codes a keyboard sends:
`sudo systemctl stop triggerhappy; sudo thd --dump /dev/input/event*` (Ctrl-C, then
`sudo systemctl start triggerhappy`).

**Sound check / volume over ssh** (while the kiosk is up):

```sh
sudo kiosk-volume                          # show current volume
sudo kiosk-volume 70                       # set 70%; also: up, down, mute (toggle)
KU=$(id -u kiosk)
sudo -u kiosk XDG_RUNTIME_DIR=/run/user/$KU wpctl status
sudo -u kiosk XDG_RUNTIME_DIR=/run/user/$KU wpctl set-default <sink-id>   # e.g. pick an HDMI/DP sink
```

Run these as the kiosk user as shown: your own ssh login has its own audio session that
can't reach the sound hardware (the logged-in screen user owns it), so a plain `wpctl status`
shows only "Dummy Output".

**Sound out of a monitor's speakers (HDMI/DP audio):** if `wpctl status` shows only an
"Analog Stereo" sink, the sound card is in an analog-only *profile*. WirePlumber picks the
highest-priority available profile, and analog usually ranks above HDMI. On a machine with
a built-in speaker (common on small desktops), analog is always "available", so it wins.
Find the profile the monitor needs, then set it as `AUDIO_PROFILE`:

```sh
KU=$(id -u kiosk)
sudo -u kiosk XDG_RUNTIME_DIR=/run/user/$KU pactl list cards | grep -E 'Name:|output:|Active Profile'
# pick the hdmi profile with "available: yes" (the port the monitor is on), e.g. output:hdmi-stereo
sudoedit /etc/default/kiosk                # AUDIO_PROFILE='output:hdmi-stereo'
sudo ~/kiosk/install-kiosk.sh && sudo reboot
sudo kiosk-volume 100                      # then set loudness with the monitor's own buttons
```

The setting installs a WirePlumber rule, so the profile is chosen again after a rebuild.
A profile chosen by hand (`pactl set-card-profile`) is remembered for the kiosk user and
takes precedence over the setting until `~kiosk/.local/state/wireplumber` is cleared. To try
a profile right away without reinstalling:
`sudo -u kiosk XDG_RUNTIME_DIR=/run/user/$KU pactl set-card-profile <card-name> <profile>`.

## Testing touch

`touch-test.html` shows how the kiosk browser turns touches into clicks: pointer type,
how long the finger was down, and whether a click followed (and how fast). Left box =
a normal page; right box = `touch-action: none`, as used by pages with their own pan, zoom
or gesture handling. Use it to tell browser or hardware touch problems apart from a web
app's own touch handling.

```sh
# on the kiosk: show the test page instead of the normal URL
sudo install -D -m 644 ~/kiosk/ubuntu-cage-kiosk/touch-test.html /usr/local/share/kiosk/touch-test.html
sudo cp /etc/default/kiosk /etc/default/kiosk.bak
sudo sed -i "s|^KIOSK_URL=.*|KIOSK_URL='file:///usr/local/share/kiosk/touch-test.html'|" /etc/default/kiosk
sudo systemctl restart kiosk
# ... tap each box quickly and slowly; read the counts ...
sudo mv /etc/default/kiosk.bak /etc/default/kiosk     # back to the normal URL
sudo systemctl restart kiosk
```

Raw touch events, no browser involved (Ctrl-C to stop):
`sudo libinput debug-events | grep -i touch`.
Which device is the touchscreen: `sudo libinput list-devices | grep -E '^Device|^Kernel|^Capabilities'`.

## Reverting to the normal desktop

```sh
cd ~/kiosk/ubuntu-cage-kiosk
sudo ./uninstall-kiosk.sh            # back to the desktop; keeps the kiosk user, settings, packages
sudo ./uninstall-kiosk.sh --purge    # also removes those: as if never installed
sudo reboot
```

Without `--purge`, re-running the installer later picks up where it was: the same settings
and the same signed-in browser sessions. `--purge` removes the `kiosk` user and its Chrome
profile, `/etc/default/kiosk`, and the packages only the kiosk uses (Google Chrome and its
apt source, cage, ddcutil, triggerhappy). It is also the way to start a test install from
scratch.
