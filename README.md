# tuxedo-tlp

A TLP battery-care plugin for TUXEDO laptops on the **Uniwill EC path**: boards where
charge protection is a coarse 3-level "charging profile", not the percentage
`charge_control_start/end_threshold` pair TLP already supports for Clevo-chassis TUXEDOs.

Written for and validated on a **TUXEDO InfinityBook Pro AMD Gen9** (board `GXxHRXx`,
Ryzen 7 8845HS) running CachyOS. Other Uniwill-based TUXEDO models may work but are
unverified, see [Caveats](#caveats).

## Why this exists

TLP (as shipped, 1.10.2) ships `bat.d/70-tuxedo`, which only knows the Clevo-chassis
mechanism (`/sys/class/power_supply/BAT0/charge_control_start_threshold`, from the
out-of-tree `clevo_acpi` module). It also claims **any** TUXEDO-vendor machine
unconditionally (matches on `sys_vendor == TUXEDO`), so on Uniwill hardware it silently
reports `tlp-stat -b` as "Supported features: none available" and blocks every other
plugin from running. There was no path to charge protection through TLP at all on this
hardware, even though the kernel driver supports it.

## What the hardware exposes

`tuxedo-drivers`' Uniwill path (`uniwill_keyboard.h`) creates:

```
/sys/devices/platform/tuxedo_keyboard/charging_profile/charging_profile            (rw)
/sys/devices/platform/tuxedo_keyboard/charging_profile/charging_profiles_available (ro)
```

with three values, confirmed live on the reference board and cross-checked against
[`infinitybook-acpi`](../infinitybook-acpi) (the NixOS-side config for the same physical
machine, which already ships this as a native `hardware.tuxedo-drivers.settings.charging-profile`
option):

| profile         | ceiling | use                          |
|-----------------|---------|------------------------------|
| `high_capacity` | 100%    | driver default (most wear)   |
| `balanced`      | 90%     | mixed battery + AC           |
| `stationary`    | 80%     | mostly docked, max lifespan  |

## The catch: two kernel drivers fight for the same hardware

That sysfs group only appears if `uniwill_wmi.ko` (from `tuxedo-drivers`) binds. It
registers for the same ACPI-WMI GUIDs as the **in-tree mainline `uniwill_laptop`**
module (which only provides `fn_lock`/hotkeys, no charging control): whichever loads
first at boot wins, and it's normally the in-tree one.

`tuxedo-drivers` already ships the fix: a modprobe blacklist for `uniwill_laptop`
(`/usr/lib/modprobe.d/tuxedo-drivers-backlist-upstream-conflicts.conf`, installed
automatically with the package). With that blacklist in place before boot, normal
kernel module autoloading picks `uniwill_wmi` instead, and the `charging_profile` group
appears with no manual steps.

If you're retrofitting onto an already-booted system (installed `tuxedo-drivers` without
rebooting), you can swap it live instead of rebooting:

```sh
sudo rmmod uniwill_laptop
sudo modprobe uniwill_wmi
```

## Install

**Arch/CachyOS (AUR):** `yay -S tuxedo-tlp-git` pulls in `tlp` and `tuxedo-drivers-dkms`
automatically and sets an 80% charge ceiling out of the box; see [`aur/`](aur) for the
PKGBUILD.

**Manual:** requires [`tuxedo-drivers`](https://gitlab.com/tuxedocomputers/development/packages/tuxedo-drivers)
(AUR: `tuxedo-drivers-dkms`) installed and bound as above, and `tlp` installed.

```sh
sudo install -m 644 tlp/bat.d/65-tuxedo-uniwill /usr/share/tlp/bat.d/65-tuxedo-uniwill
sudo install -m 644 tlp.d/01-tuxedo-charge.conf /etc/tlp.d/01-tuxedo-charge.conf
sudo tlp start
```

The `65` prefix matters: TLP's plugin loader (`select_batdrv` in `tlp-func-base`) tries
`bat.d/[0-9][0-9]-*` in numeric order and stops at the first plugin whose `batdrv_init`
succeeds. `65` sorts before the stock `70-tuxedo`, so on hardware where this plugin
matches, it wins the match and `70-tuxedo` is never reached.

## Usage

Once installed, it's just TLP:

```sh
tlp-stat -b                    # shows current profile + plugin status
sudo tlp setcharge 0 80 BAT0   # -> stationary (80%)
sudo tlp setcharge 0 90 BAT0   # -> balanced (90%)
sudo tlp setcharge 0 100 BAT0  # -> high_capacity (100%, no cap)
```

Or set it declaratively in `/etc/tlp.d/`:

```ini
STOP_CHARGE_THRESH_BAT0=80
```

`START_CHARGE_THRESH_BAT0` is accepted (won't error) but has no effect: this EC exposes
one enum knob, not an independent start/stop pair. `80`/`90`/`100` are the only valid
`STOP_CHARGE_THRESH` values; anything else is rejected the same way TLP rejects an
out-of-range value on any other plugin.

## Power-saver mirrors TCC's "Powersave extreme"

TUXEDO Control Center and TLP both want to own the CPU. Left alone, `tccd`'s CpuWorker
checks EPP and frequency limits every minute and rewrites them to its active profile,
undoing whatever TLP applied. Split the work like this:

- **TLP owns the CPU.** Turn off TCC's CPU control (TCC GUI: Settings > CPU settings, or
  `"cpuSettingsEnabled":false` in `/etc/tcc/settings` with `tccd` stopped).
- **TCC keeps fans, ODM profile, keyboard backlight and display brightness.**

TCC's legacy "Powersave extreme" profile pins the CPU's max frequency to its minimum,
sets silent fans and drops the display to 60%. `tlp.d/02-tuxedo-powersave-extreme.conf`
applies the CPU half of that in TLP's power-saver profile (`_ON_SAV`), and also sets
explicit limits for balanced/performance so the cap is lifted when you leave power-saver.
The frequencies in that file are for the 8845HS; check yours with
`cat /sys/devices/system/cpu/cpu0/cpufreq/{cpuinfo_min_freq,amd_pstate_max_freq}`.

`tuxedo-tlp-tcc-sync` handles fans and brightness. It follows `tlp-pd`'s
`ActiveProfile` over D-Bus and asks `tccd` for the "Powersave extreme" temp profile while
TLP is in power-saver, and for the profile TCC's own power-source map picks otherwise. It
rechecks a few seconds after every change (`tccd` resets its temp profile on AC/battery
switches, racing TLP's own auto-switch) and every 60 seconds.

```sh
sudo systemctl enable --now tuxedo-tlp-tcc-sync.service
powerprofilesctl set power-saver   # or the KDE/GNOME power applet
journalctl -u tuxedo-tlp-tcc-sync
```

`TCC_SAV_PROFILE` in the unit's environment picks a different TCC profile id. Leaving
power-saver does not restore brightness, because TCC's default profile doesn't set one.

## Caveats

- Verified on exactly one board (InfinityBook Pro AMD Gen9, `GXxHRXx`). Other Uniwill
  TUXEDO models may use different EC RAM layouts. The driver itself gates on
  `uw_has_charging_profile()` (EC RAM `0x078e` bit 3, with a DMI denylist for a few known
  Uniwill boards that don't support it: `PF5PU1G`, `LAPQC71A`, `LAPQC71B`, `A60 MUV`), so
  the plugin should correctly report "no charge API" there rather than misbehave, but
  that's not the same as validated.
- Only one fan/EC controller should manage a TUXEDO Uniwill board's `tuxedo_io` device at
  a time (TCC's `tccd`, `tuxedo-rs`'s `tailord`, or a custom daemon). This plugin doesn't
  touch `/dev/tuxedo_io` at all, it's a separate sysfs group, so it's safe to run
  alongside any of those. It's TLP's own `bat.d/70-tuxedo` it's meant to pre-empt, not a
  fan controller.

## Related

- [`tuxedo-control-nix`](../tuxedo-control-nix): a from-scratch Rust daemon + NixOS
  module for the same board's `/dev/tuxedo_io` ioctl interface (fan control, performance
  profiles). Different control surface (ioctl vs. this plugin's plain sysfs), no overlap.
- [`infinitybook-acpi`](../infinitybook-acpi): NixOS-side ACPI fixes and EC power tuning
  for the same physical machine's NixOS boot, including the native
  `hardware.tuxedo-drivers.settings.charging-profile` option this plugin's percentage
  table was cross-checked against.

## AI assistance

This project (the plugin, the writeup, and the reverse-engineering of the
`uniwill_wmi`/`uniwill_laptop` conflict) was developed with AI assistance (Claude Code),
working from `tuxedo-drivers`' GPL kernel source and live verification on the reference
machine. I reviewed and tested the plugin (including a live `tlp setcharge` round trip)
before committing it. The TCC power-saver sync was written the same way and tested by
cycling power profiles on the reference machine.

## License

[MIT](LICENSE).
