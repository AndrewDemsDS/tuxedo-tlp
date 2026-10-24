#!/bin/sh
# Exercise tlp/bat.d/65-tuxedo-uniwill against a fake sysfs, using TLP's real helper
# functions (read_sysf, write_sysf, wordinlist, is_uint, ...) from tlp-func-base.
#
# Usage: sh tests/plugin-test.sh [path/to/tlp-func-base]
# Needs TLP installed (default /usr/share/tlp/tlp-func-base). Run it under dash as well as
# bash: TLP runs its plugins with /bin/sh.
#
# SPDX-License-Identifier: GPL-2.0-or-later

# The plugin, sourced below, reads the settings this script assigns (SC2034) and sets the
# globals it checks (SC2154); shellcheck cannot follow that across the dynamic source.
# shellcheck disable=SC2034,SC2154

# No set -u: tlp-func-base reads optional settings that are unset here.
FUNC_BASE=${1:-/usr/share/tlp/tlp-func-base}
PLUGIN=$(dirname "$0")/../tlp/bat.d/65-tuxedo-uniwill
FAKE=$(mktemp -d)
trap 'rm -rf "$FAKE"' EXIT

# shellcheck disable=SC1090
. "$FUNC_BASE"
# shellcheck disable=SC1090
. "$PLUGIN"

# DMID is readonly in tlp-func-base, so point read_dmi at the fake tree instead.
read_dmi () {
    read_sysf "$FAKE/dmi/$1"
}
ACPIBATDIR="$FAKE/power_supply"
UNIWILL_CHARGE_FILE="$FAKE/charging_profile"
X_BAT_PLUGIN_SIMULATE=""
X_BAT_PLUGIN_DENYLIST=""

fails=0
pass () { printf 'ok   %s\n' "$1"; }
fail () { printf 'FAIL %s\n' "$1"; fails=$((fails + 1)); }
check () {
    # $1: name, $2: expected, $3: actual
    if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (expected '$2', got '$3')"; fi
}

reset_hw () {
    rm -rf "$FAKE/dmi" "$FAKE/power_supply" "$UNIWILL_CHARGE_FILE"
    mkdir -p "$FAKE/dmi" "$FAKE/power_supply/BAT0"
    printf 'TUXEDO\n' > "$FAKE/dmi/sys_vendor"
    printf '1\n' > "$FAKE/power_supply/BAT0/present"
    printf 'high_capacity\n' > "$UNIWILL_CHARGE_FILE"
}

# --- detection

reset_hw
batdrv_init; check "init matches a TUXEDO board with charging_profile" 0 $?
check "init finds BAT0" "BAT0" "$_batteries"

reset_hw
printf 'Other\n' > "$FAKE/dmi/sys_vendor"
batdrv_init; check "init skips other vendors" 1 $?

reset_hw
rm "$UNIWILL_CHARGE_FILE"
batdrv_init; check "init skips a board without charging_profile" 1 $?

reset_hw
printf '0\n' > "$FAKE/power_supply/BAT0/present"
batdrv_init; check "init reports no batteries" 2 $?

reset_hw
X_BAT_PLUGIN_DENYLIST="tuxedo-uniwill"
batdrv_init; check "init honours the denylist" 1 $?
X_BAT_PLUGIN_DENYLIST=""

# --- reading

reset_hw
batdrv_init
batdrv_select_battery BAT0; check "select BAT0" 0 $?
batdrv_select_battery BAT1; check "select a missing BAT1 fails" 1 $?
batdrv_select_battery DEF
for pair in stationary:80 balanced:90 high_capacity:100; do
    printf '%s\n' "${pair%%:*}" > "$UNIWILL_CHARGE_FILE"
    check "read stop for ${pair%%:*}" "${pair##*:}" "$(batdrv_read_threshold stop 0)"
done
check "read start is always 0" "0" "$(batdrv_read_threshold start 0)"

# --- writing

for pair in 80:stationary 90:balanced 100:high_capacity DEF:high_capacity; do
    reset_hw; batdrv_init; batdrv_select_battery BAT0
    printf 'balanced\n' > "$UNIWILL_CHARGE_FILE"
    [ "${pair%%:*}" = 90 ] && printf 'stationary\n' > "$UNIWILL_CHARGE_FILE"
    batdrv_write_thresholds 0 "${pair%%:*}" 0
    rc=$?
    check "write ${pair%%:*} returns 0" 0 "$rc"
    check "write ${pair%%:*} sets ${pair##*:}" "${pair##*:}" "$(cat "$UNIWILL_CHARGE_FILE")"
done

for bad in 85 50 abc 1000; do
    reset_hw; batdrv_init; batdrv_select_battery BAT0
    batdrv_write_thresholds 0 "$bad" 0
    check "write $bad is rejected" 2 $?
    check "write $bad leaves the profile alone" high_capacity "$(cat "$UNIWILL_CHARGE_FILE")"
done

reset_hw; batdrv_init; batdrv_select_battery BAT0
printf 'stationary\n' > "$UNIWILL_CHARGE_FILE"
chmod a-w "$UNIWILL_CHARGE_FILE"
batdrv_write_thresholds 0 80 0
check "write of the current profile is a no-op" 0 $?
chmod u+w "$UNIWILL_CHARGE_FILE"

reset_hw
X_BAT_PLUGIN_SIMULATE="tuxedo-uniwill"
batdrv_init; batdrv_select_battery BAT0
batdrv_write_thresholds 0 80 0
check "simulated write returns 0" 0 $?
check "simulated write leaves sysfs alone" high_capacity "$(cat "$UNIWILL_CHARGE_FILE")"
X_BAT_PLUGIN_SIMULATE=""

reset_hw; batdrv_init; batdrv_select_battery BAT0
batdrv_write_thresholds 0 "" 0 config
check "an unset configured stop is skipped" 1 $?

if [ "$fails" -gt 0 ]; then
    printf '%d check(s) failed\n' "$fails"
    exit 1
fi
printf 'all checks passed\n'
