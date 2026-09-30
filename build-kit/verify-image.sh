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

echo "==> the SMS app and its MR600 glue, in the rootfs that gets packed"
# These are package files, so they live in the build_dir rootfs rather than in base-files. Every
# path here fails silently when it is missing: no view file and the page is simply absent, no
# ACL file and the page renders while every button fails, no menu file and the entry never
# appears. The app is the vendored luci-app-sms-tool-js; the rest is the mr600-sms glue.
sms_files="
www/luci-static/resources/view/modem/readsms.js
www/luci-static/resources/view/modem/sendsms.js
www/luci-static/resources/view/modem/sendussd.js
www/luci-static/resources/view/modem/sendat.js
www/luci-static/resources/view/status/include/10_my_sms_info.js
www/luci-static/resources/icons/redrawsms.svg
usr/share/luci/menu.d/luci-app-sms-tool-js.json
usr/share/rpcd/acl.d/luci-app-sms-tool-js.json
etc/config/sms_tool_js
etc/uci-defaults/99-mr600-sms
etc/init.d/sms-mqtt
etc/config/sms_mqtt
usr/sbin/sms-mqtt-poll
usr/bin/sms_tool"
sms_found=0
sms_expected=0
for f in $sms_files; do
	sms_expected=$((sms_expected + 1))
	[ -n "$(find build_dir -path "*/root-ramips/$f" -print -quit 2>/dev/null || true)" ] &&
		sms_found=$((sms_found + 1)) || bad "MISSING from the rootfs: $f"
done
if [ "$sms_found" -eq "$sms_expected" ]; then
	ok "all $sms_expected SMS files are in the rootfs"
fi

# The four port options and the storage area are the failure that looks like a working page with
# nothing in it. An empty port option makes sms_tool use its compiled-in /dev/ttyUSB0, which DOES
# exist on this router - `option` binds the modem's interfaces 0-3 as ttyUSB0-3 - but interface 0
# is not the AT port, so the inbox, send, USSD and AT pages all come up empty and say nothing.
smsdefaults=$(find build_dir -path '*/root-ramips/etc/uci-defaults/99-mr600-sms' -print -quit 2>/dev/null || true)
if [ -n "$smsdefaults" ]; then
	grep -q 'for o in readport sendport ussdport atport' "$smsdefaults" ||
		bad "99-mr600-sms does not set all four ports; an unset one falls back to /dev/ttyUSB0"
	grep -q 'AT=/dev/ttyUSB2' "$smsdefaults" ||
		bad "99-mr600-sms does not point the app at /dev/ttyUSB2"
	for opt in 'storage=ME' 'mergesms=1' 'ontopsms=1'; do
		grep -q "$opt" "$smsdefaults" || bad "99-mr600-sms does not set $opt"
	done
	grep -q 'sms_tool_calllogd.*disable' "$smsdefaults" ||
		bad "the call-log daemon is not disabled - it holds the AT port open and polls AT+CLCC"
	sh -n "$smsdefaults" || bad "99-mr600-sms is not valid shell"
	ok "the MR600 SMS defaults are the ones this device needs"
fi

# The app never sets AT+CNMI itself and never sets the storage area's routing; it relies on
# lte-reset having done it. If that line is ever dropped, sending still works, the inbox still
# lists what is already stored, and arriving SMS are silently dropped by the modem - a failure
# with no symptom anywhere in the UI.
grep -q 'AT+CNMI=2,1,0,0,0' "$BLF/etc/init.d/lte-reset" ||
	bad "lte-reset no longer sets AT+CNMI=2,1,0,0,0 - the SMS app depends on it silently"

# A ucode syntax error in the poller is invisible until the service runs and fails every pass.
# Two things make this subtler than it looks, both learned the hard way:
#   * `ucode -c` resolves module imports WHILE COMPILING, and the host ucode has no uci module -
#     the poller imports `uci`, so a plain `-c` fails on a file that is perfectly fine on the
#     target. `dynlink=uci` is what luci.mk passes for exactly this reason: it emits a runtime
#     link instead of resolving the import at compile time.
#   * the candidate has to be proven runnable first, by running it. The tree also contains the
#     target's mipsel ucode, which cannot execute on the build host, and a check that takes it
#     would report a failure that is really "wrong binary".
#   * where it lives: ucode/host installs to staging_dir/hostpkg/bin/ucode (STAGING_DIR_HOSTPKG),
#     not staging_dir/host/bin - looking only in host/bin is why this check reported a note on the
#     first two builds instead of checking anything.
sms_poller=$(find build_dir -path '*/root-ramips/usr/sbin/sms-mqtt-poll' -print -quit 2>/dev/null || true)
if [ -n "$sms_poller" ]; then
	host_ucode=""
	for cand in "$TREE/staging_dir/hostpkg/bin/ucode" "$TREE/staging_dir/host/bin/ucode" \
	            $(find "$TREE/staging_dir/hostpkg" "$TREE/staging_dir/host" -maxdepth 3 -type f -name ucode -perm -u+x 2>/dev/null); do
		if [ -x "$cand" ] && "$cand" -e 'exit(0)' >/dev/null 2>&1; then
			host_ucode="$cand"
			break
		fi
	done
	if [ -n "$host_ucode" ]; then
		# Keep the compiler's message: without it a failure here says "it does not compile" and
		# leaves no way to find out why, which is how the wrong flags above stayed hidden.
		if ucode_err=$("$host_ucode" -cno-interp,dynlink=uci -o /dev/null "$sms_poller" 2>&1); then
			ok "sms-mqtt-poll compiles (checked with ${host_ucode#$TREE/})"
		else
			bad "sms-mqtt-poll does not compile - the MQTT service would fail on every pass"
			printf '%s\n' "$ucode_err" | head -5 | sed 's/^/          /' >&2
		fi
	else
		echo "   note    no runnable ucode on this build host: the poller was NOT syntax-checked"
		echo "           (build.sh builds one deliberately; see $TREE/.host-ucode.build.log)"
	fi
fi

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
