# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and
this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.0] - 2026-10-24

First tagged release.

### Added
- TLP battery plugin `bat.d/65-tuxedo-uniwill` for TUXEDO boards on the Uniwill EC path. It
  maps `STOP_CHARGE_THRESH_BAT0` 80/90/100 to the driver's `charging_profile` enum
  (`stationary`/`balanced`/`high_capacity`) and sorts before TLP's stock `70-tuxedo`, which
  reports no supported features on this hardware.
- `tlp.d/01-tuxedo-charge.conf`: an 80% charge ceiling by default.
- `tlp.d/02-tuxedo-powersave-extreme.conf`: TLP's power-saver profile mirrors TCC's
  "Powersave extreme" (CPU max frequency pinned to the minimum, boost off), with explicit
  balanced/performance limits so the cap lifts again when you leave power-saver.
- `tuxedo-tlp-tcc-sync`: follows `tlp-pd`'s active profile over D-Bus and switches TCC's
  temperature profile to match.
- `tuxedo-tlp-controld-sync`: the same for [Tuxedo Control](https://github.com/AndrewDemsDS/tuxedo-control)'s
  `tuxedo-controld` in place of TCC (power-saver to Max Energy Save, balanced to Quiet,
  performance to High Performance).
- Arch packaging as `tuxedo-tlp-git` (`aur/PKGBUILD`, ready for the AUR but not published there).

### Fixed
- Leaving power-saver turns CPU boost back on (`CPU_BOOST_ON_AC/BAT=1` set explicitly).
- `tuxedo-tlp-controld-sync` applies a profile change only after TLP has held it for
  `SETTLE_DELAY` seconds (default 10). Rapid balanced/performance flips used to swap the fan
  curve every few seconds and start and stop the fan.

[Unreleased]: https://github.com/AndrewDemsDS/tuxedo-tlp/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/AndrewDemsDS/tuxedo-tlp/releases/tag/v0.1.0
