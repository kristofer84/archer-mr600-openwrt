#!/usr/bin/env bash
# Verify a tree that has already been built: does the image contain what this device needs?
#
#   TREE=~/openwrt-mr600 ./verify-image.sh
#
# No rebuild and no reconfiguration, so this can be run at any time - including against a tree
# built by something other than build.sh, which is exactly how the guards below went unexercised
# for a while. build.sh calls it as its last step.
#
# Every check here exists because its failure is silent:
#   * an image built for the wrong target boots with no WiFi at all - no mt7603e/mt76x2e;
#   * an image missing the LTE payload boots with no modem: no lease, and no error either;
#   * an APN that never reaches uci brings the link up at boot and then fails on the first
#     interface restart, which nobody notices until something restarts it.
set -euo pipefail

KIT="$(cd "$(dirname "$0")" && pwd)"
TREE="${TREE:-$HOME/openwrt-mr600}"
BLF="$TREE/target/linux/ramips/mt7621/base-files"

cd "$TREE"
if [ ! -d "$BLF" ]; then
	echo "error: $BLF does not exist, so $TREE is not a built OpenWrt tree" >&2
	echo "       run build.sh first, or point TREE at the right checkout" >&2
	exit 1
fi

fail=0
ok()   { echo "   ok      $*"; }
bad()  { echo "   ERROR:  $*" >&2; fail=1; }

echo "==> WiFi drivers, in the rootfs that gets packed"
for m in mt7603e mt76x2e; do
	# '|| true' because set -e would otherwise end the script on a find that fails or finds
	# nothing, which is the opposite of reporting it.
	mod=$(find build_dir -path "*root-ramips/lib/modules/*/$m.ko" 2>/dev/null | head -1 || true)
	if [ -n "$mod" ]; then
		ok "$m.ko"
	else
		bad "$m.ko is not in the built rootfs - this image would boot with no WiFi"
		elsewhere=$(find build_dir -name "$m.ko" 2>/dev/null | head -1 || true)
		if [ -n "$elsewhere" ]; then
			echo "          it does exist at ${elsewhere#build_dir/}," >&2
			echo "          so the target is right and it is simply not being installed" >&2
		fi
	fi
done

echo "==> the LTE payload, in base-files"
for f in etc/init.d/lte-reset etc/hotplug.d/iface/30-lte-apn etc/uci-defaults/99-mr600-lte \
         etc/mr600-apn-table usr/bin/at-tty; do
	if [ -e "$BLF/$f" ]; then ok "base-files/$f"; else bad "MISSING base-files/$f"; fi
done

echo "==> the APN lookup, which fails silently into an empty APN"
# Two things went wrong here once: a fix in tools/ never reached the payload (tools/ and
# files/ are separate copies), and a fallback lost its zero padding so `240`,`8` concatenated
# to `2408` instead of `24008`. Both produced an empty APN on a network that accepts one, so
# the link still came up and nothing announced the mistake.
grep -q '%02d' "$BLF/etc/init.d/lte-reset" ||
	bad "the init script's PLMN fallback has no zero padding (240+8 would become 2408)"
for fn in resolve_apn home_mccmnc apn_from_table persist_apn mark_apn_applied; do
	grep -q "^$fn()" "$BLF/etc/init.d/lte-reset" ||
		bad "the init script does not define $fn() - an undefined call yields an EMPTY APN, and
          sh -n cannot see it"
done
if [ "$(wc -l < "$BLF/etc/mr600-apn-table")" -gt 500 ]; then
	ok "the APN table is $(wc -l < "$BLF/etc/mr600-apn-table") rows"
else
	bad "the APN table looks empty or truncated"
fi
awk -F'\t' '$1 == "24008" { found=1 } END { exit !found }' "$BLF/etc/mr600-apn-table" 2>/dev/null ||
	bad "the APN table has no 24008 entry - the lookup would miss on this SIM"

# The APN has to reach uci. The qmi proto passes --apn only when the option exists, and this
# module consumes AT+CGDCONT rather than storing it, so without the uci copy the link comes up
# at boot and every re-activation after that fails. Invisible until something restarts wwan0.
grep -q 'persist_apn "$apn"' "$BLF/etc/init.d/lte-reset" ||
	bad "lte-reset does not write the derived APN into uci; re-activation would fail"
awk -F'\t' '$1 == "24008" { print $2 }' "$BLF/etc/mr600-apn-table" | grep -q . ||
	bad "the 24008 row has no APN"
ok "the APN reaches uci"

echo "==> variant"
# Judged from what was seeded into THIS tree, not from whether the seed file happens to be
# present now: the file can be moved aside, and a tree can be configured by something other
# than build.sh. .config.seed.local.applied is build.sh's record of what it applied, and the
# .config is what survived it - check both, so the statement is true of the artifact.
#
# The record's existence is what makes it a local variant, not whether it enables anything:
# a seed that only disables packages changes the image just as much.
local_seed="$TREE/.config.seed.local.applied"
if [ -f "$local_seed" ]; then
	missing=0
	while read -r line; do
		case "$line" in
			CONFIG_*=y) grep -qxF "$line" "$TREE/.config" || missing=1 ;;
		esac
	done < "$local_seed"
	if [ "$missing" = 0 ]; then
		echo "   note    LOCAL variant: config.seed.local was applied; every package it enables is in .config"
	else
		bad "a local seed was applied but its packages are not all in .config - a release must not ship this"
	fi
else
	echo "   ok      generic image: no config.seed.local was applied to this tree"
fi

echo "==> calibration policy"
if [ -e "$BLF/root/radio-cal.bin" ]; then
	echo "   note    a calibration blob is baked in as a fallback (non-generic build)"
else
	echo "   ok      generic build: no calibration blob baked in; first boot keeps the unit's own"
fi

echo "==> artifacts"
if ls bin/targets/ramips/mt7621/ 2>/dev/null | grep -q "mr600-v1-eu"; then
	ls -la bin/targets/ramips/mt7621/ | grep -E "mr600-v1-eu" | sed 's/^/   /'
else
	bad "no mr600 artifacts under bin/targets/ramips/mt7621"
fi

[ "$fail" = 0 ] || { echo >&2; echo "verification FAILED - do not flash this" >&2; exit 1; }
echo
echo "all checks passed"
