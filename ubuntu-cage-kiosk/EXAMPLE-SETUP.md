# Example setup

The machines this script has been run on, and what was learned along the way. These are
examples to ground the general instructions, not requirements.

## Why a dedicated kiosk

The starting point was a wall-mounted iPad showing a home-monitoring web app. Three things
pushed toward something else:

1. **Sound needs a tap.** iOS will not let a web page play audio until someone touches it,
   and this applies to every browser on iOS, not only Safari. For a page whose main job is
   to sound alerts while nobody is using it, that is a deal-breaker.
2. **Screen size.** A larger display is easier to read from across the room, and large
   tablets cost a lot more than a monitor of the same size.
3. **Browser chrome.** iOS browsers always keep some browser UI on screen.

A small PC running Chrome under cage fixes all three: autoplay can be allowed outright, any
monitor can be used, and the page gets the whole screen.

## Wall console: mini PC + touch monitor

**Requirements:** touch screen, built-in speakers (or a simple way to add one), no more than
20 inches wide, as flat to the wall as possible, around $500.

| Part | Choice |
|---|---|
| Computer | Lenovo ThinkCentre M920x Tiny (8th-gen Core i5), refurbished |
| Display | ViewSonic TD2230: 22" touch (USB HID), built-in speakers, external power brick |
| Connections | HDMI (video and audio), USB-A to USB-B (touch), DC power |

**The M920x is more than a kiosk needs.** Almost any small x86 PC that runs Ubuntu 24.04
will do. This one was chosen to also run other services: it records 8 cameras with Frigate
alongside the kiosk.

Notes:

- **Install:** the computer sits in a closet behind the wall, on the UPS. Only the HDMI, USB
  and the monitor's low-voltage DC cord pass through the wall; the monitor's power brick stays
  in the closet. The monitor hangs on a thin VESA 100 bracket on a plywood plate across two studs.
- **BIOS:** After Power Loss = Power On; fan/thermal mode set to its quiet option.
- **Touch:** works out of the box (USB HID). Swipe and pinch do not navigate away.
- **Cursor:** the TD2230's touch controller (Weida Hi-Tech CoolTouch) also has a "Mouse"
  interface, which made cage draw a cursor. With `IGNORE_TOUCHSCREEN_MOUSE` there is no
  cursor; a USB mouse plugged in for debugging shows one, and it goes away when unplugged
  (see the README, "Mouse cursor on a touchscreen").
- **Audio:** the card defaulted to analog, because the Tiny's internal speaker makes analog
  always available. Switching to the HDMI profile fixed it (see the README, "Sound out of a
  monitor's speakers"). Volume set to 100% on the PC; loudness set with the monitor's buttons.
- **Brightness:** `ddcutil` controls the TD2230 over HDMI, so scheduled dimming works.
- **Sharing the machine with other workloads:**
  - Chrome uses about 1.6 GiB of memory. Give containers memory limits, so that when memory
    runs short the kernel's out-of-memory killer picks a container rather than Chrome. If
    Chrome is killed anyway, systemd restarts it after a few seconds of blank screen.
  - Chrome and video decoding (Frigate's VAAPI) share the integrated GPU. Occasional decode
    errors ("Failed to sync surface") were seen once; they recovered on their own.

## Laptops: older MacBook Airs

The same script runs on old MacBook Airs with Ubuntu 24.04. They have a keyboard and
trackpad but no touch screen, which is fine for a display you mostly look at.

- **Battery:** an old battery that stays plugged in 24/7 can swell. Check it now and then:
  look for a bulging bottom case or a trackpad that no longer clicks properly. Removing it
  isn't a clean fix, because Macs slow the CPU way down with no battery.
- **Pointer:** with the trackpad, the mouse pointer stays visible on screen.
- **Old graphics:** Chrome may turn off graphics acceleration on the 2011 Air's Intel HD 3000.
  Video will work but use more CPU.
- **Volume keys:** the speaker keys on the top row work (see the README, "Volume keys").
- **Lid:** closing the lid suspends; opening it resumes to the page.
- **Ubuntu version:** the script requires 24.04 and stops with an error on anything older.
