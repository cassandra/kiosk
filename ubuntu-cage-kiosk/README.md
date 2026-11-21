# Ubuntu + cage + Chrome kiosk

`install-kiosk.sh` turns an Ubuntu 24.04 LTS (amd64) machine into a kiosk that shows one
web page full-screen, with no desktop and no browser controls. The same script works on
laptops (built-in screen) and on small desktops with an external touch monitor.

For the hardware it has been run on, see [EXAMPLE-SETUP.md](EXAMPLE-SETUP.md).

## What it sets up

| Piece | What it does |
|---|---|
| `kiosk` user | Locked-password account that runs the browser |
| `kiosk.service` | Starts **cage** (a compositor that runs one app full-screen) on tty1 at boot, running Chrome; restarts it if it exits. |
| Boot target `multi-user.target` | Boots to text mode so the GNOME login screen (GDM) never starts. GDM stays installed and untouched. |
| `/usr/local/bin/kiosk-browser` | Chrome `--kiosk` with autoplay allowed, no first-run or translate prompts, no "Restore pages?" after power loss, no swipe-back or pinch-zoom |
| `/etc/opt/chrome/policies/managed/kiosk.json` | Chrome policy `AutoplayAllowed` (backup in case the flag ever stops working) |
| `/etc/default/kiosk` | **Settings**: URL, day/night times and brightness, extra Chrome flags |
| `kiosk-brightness` + timer | Every 5 min, applies the day/night level. Laptop: sysfs backlight. External monitor: `ddcutil` (DDC/CI). A manual change sticks until the next day/night switch. |
| `kiosk-volume` + `triggerhappy` | Keyboard volume/mute keys work without a desktop (see "Volume keys" below) |
| `kiosk-restart.timer` | Restarts the browser daily at 04:30 |
| logind drop-in + sleep targets | Never suspends from inactivity. Laptops suspend when the lid closes and resume when it opens; machines without a lid never sleep. Set `LID_SWITCH_ACTION` in `/etc/default/kiosk` (`suspend`/`ignore`) and re-run the installer to change it. With an external monitor attached, closing the lid is ignored. |

## Install

Start from a fresh Ubuntu 24.04 LTS Desktop install with `openssh-server` installed, so you
can manage the machine remotely.

Copy this whole directory to the machine (the installer uses the files under `rootfs/`),
then run the installer:

```sh
scp -r ubuntu-cage-kiosk <machine>:
ssh <machine>
sudo ./ubuntu-cage-kiosk/install-kiosk.sh 'http://<server>:<port>/<path>'
sudo reboot
```

Or `git clone` this repository on the machine instead of copying.

Quote the URL: query strings contain `&`. Re-running the script is safe; re-running with a
new URL replaces it.

## Files

`rootfs/` holds every file the installer puts on the system, at the same path it gets there
(`rootfs/usr/local/bin/kiosk-browser` becomes `/usr/local/bin/kiosk-browser`). Files ending
in `.in` are templates: the installer fills in `@KIOSK_USER@` and `@LID_SWITCH_ACTION@` and
drops the `.in`. `etc/default/kiosk` is only installed when it doesn't exist yet, so
re-running keeps your settings.

If the page needs a sign-in, sign in once on the machine itself. Chrome keeps cookies and
sessions in `~kiosk/.config/kiosk-chrome`, so they survive restarts and reboots. On a
touch-only machine with no keyboard, either the web app provides its own on-screen input or
you plug in a USB keyboard for this step.

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

## Day-to-day

```sh
sudoedit /etc/default/kiosk                # change URL / schedule / levels
sudo systemctl restart kiosk               # reload: restarts Chrome on KIOSK_URL (~5 s, no reboot)
sudo kiosk-brightness auto --force         # re-apply brightness now
sudo kiosk-brightness 40                   # one-off level (sticks until next day/night switch)
journalctl -u kiosk -b                     # browser/cage logs
```

`sudo systemctl restart kiosk` is also the way out if the page ever reaches a dead end with
no in-page way back: the kiosk has no browser controls.

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
Switch the card to its HDMI profile once:

```sh
KU=$(id -u kiosk)
sudo -u kiosk XDG_RUNTIME_DIR=/run/user/$KU pactl list cards | grep -E 'Name:|output:|Active Profile'
# pick the hdmi profile with "available: yes" (the port the monitor is on), then:
sudo -u kiosk XDG_RUNTIME_DIR=/run/user/$KU pactl set-card-profile <card-name> output:hdmi-stereo
sudo kiosk-volume 100                      # then set loudness with the monitor's own buttons
```

WirePlumber remembers the choice for the kiosk user across reboots. If it ever reverts
(rebuild, or `~kiosk/.local/state/wireplumber` cleared), repeat this; a WirePlumber rule
disabling the analog output would make it permanent if needed.

## Testing touch

`touch-test.html` shows how the kiosk browser turns touches into clicks: pointer type,
how long the finger was down, and whether a click followed (and how fast). Left box =
a normal page; right box = `touch-action: none`, as used by pages with their own pan, zoom
or gesture handling. Use it to tell browser or hardware touch problems apart from a web
app's own touch handling.

```sh
# from your workstation
scp touch-test.html <machine>:
# on the kiosk: show the test page instead of the normal URL
sudo install -D -m 644 ~/touch-test.html /usr/local/share/kiosk/touch-test.html
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
sudo systemctl disable kiosk.service kiosk-brightness.timer kiosk-restart.timer triggerhappy.service
sudo systemctl set-default graphical.target
sudo reboot
```
