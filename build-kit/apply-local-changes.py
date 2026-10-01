#!/usr/bin/env python3
"""Apply this project's changes on top of PR #25074.

Everything here is deliberate and each edit asserts it matched exactly once, so a silently
missed change is a hard error rather than a subtly different image.

Run from the OpenWrt tree root. Assumes the PR patch has already been applied.
"""
import os, re, shutil, sys

HERE = os.path.dirname(os.path.abspath(__file__))
DTS = "target/linux/ramips/dts/mt7621_tplink_mr600-v1-eu.dts"
NET = "target/linux/ramips/mt7621/base-files/etc/board.d/02_network"

if not os.path.isfile(DTS):
    sys.exit(f"error: {DTS} not found - apply patches/0001 first, and run from the tree root")

# 1. Replace the DTS with ours: radio made writable, filler partition added, led_enable hog.
shutil.copyfile(os.path.join(HERE, "mr600-v1-eu.dts.local"), DTS)
dts = open(DTS).read()
for needle, why in [
    ('label = "filler"', "the filler@0xfe0000 partition"),
    ("led_enable", "the GPIO3 led_enable hog"),
    ('reg = <0xff0000 0x10000>;\n\t\t\t\t/* Deliberately writable', "radio made writable"),
]:
    print(f"  ok  DTS contains {why}" if needle in dts else f"  ERR DTS missing {why}")
    if needle not in dts:
        sys.exit(1)

# 2. Give v1 its own wwan MAC. The PR routes v1 into the v2 case, which derives wwan0 as
#    eth0+1; our review asked for +2 so the two devices cannot collide on a shared LAN.
net = open(NET).read()
old = "\ttplink,mr600-v1-eu|\\\n\ttplink,mr600-v2-eu)\n"
new = ("\ttplink,mr600-v1-eu)\n"
       "\t\twwan_mac=$(macaddr_add $(cat /sys/class/net/eth0/address) 2)\n"
       '\t\tucidef_set_interface "wwan0" device "/dev/cdc-wdm0" protocol "qmi" macaddr "$wwan_mac"\n'
       "\t\t;;\n"
       "\ttplink,mr600-v2-eu)\n")
hits = net.count(old)
if hits == 0:
    # Already applied on this tree (re-running the kit on an existing checkout). The new form
    # must be present, or the tree is in neither state and we should stop rather than guess.
    if "tplink,mr600-v1-eu)\n\t\twwan_mac=" in net:
        print("  ok  02_network: v1 wwan MAC already applied")
    else:
        sys.exit("error: 02_network has neither the stock v1-in-v2-case hunk nor this kit's"
                 " replacement. Upstream may have moved - fix the anchor by hand.")
elif hits != 1:
    sys.exit(f"error: expected exactly one v1-in-v2-case hunk in 02_network, found {hits}."
             " Upstream may have moved - fix the anchor by hand rather than guessing.")
else:
    open(NET, "w").write(net.replace(old, new))
    print("  ok  02_network: v1 given its own wwan0 = eth0+2")

# 3. Rootfs payload: the first-boot calibration script, and the calibration blob if present.
#
#    GENERIC BUILD (the default here): no blob is committed, because it is vendor calibration
#    data and it is PER UNIT. It is not needed for the normal install. This script still
#    installs 99-mr600-radiocal, which PRESERVES whatever the target unit's `radio` region
#    already holds and only falls back to a shipped blob when that region is blank. Any unit
#    that has booted stock firmware already has its own calibration there, so a generic image
#    boots with correct WiFi on any MR600 v1.
#
#    If you want a specific unit's blob baked in as the fallback (e.g. a unit with an erased
#    radio region, or a release built for one unit), build it with
#      ./make-radio-cal.sh <mtd2.bin | extracted-rootfs>
#    and re-run this kit. The digest assertion in that script must pass.
base = os.path.dirname(os.path.dirname(DTS))          # target/linux/ramips
dst_root = os.path.join(base, "mt7621/base-files/root")
dst_ud = os.path.join(base, "mt7621/base-files/etc/uci-defaults")
os.makedirs(dst_root, exist_ok=True)
os.makedirs(dst_ud, exist_ok=True)
blob = os.path.join(HERE, "files/root/radio-cal.bin")
if os.path.isfile(blob):
    shutil.copyfile(blob, os.path.join(dst_root, "radio-cal.bin"))
    print("  ok  installed radio-cal.bin (a shipped fallback blob) and 99-mr600-radiocal")
else:
    print("  ..  no files/root/radio-cal.bin: GENERIC build. The image ships no calibration")
    print("      blob and first boot keeps the target unit's own radio calibration. This is")
    print("      the correct default for any unit that has booted stock firmware.")
shutil.copyfile(os.path.join(HERE, "files/etc/uci-defaults/99-mr600-radiocal"),
                os.path.join(dst_ud, "99-mr600-radiocal"))
os.chmod(os.path.join(dst_ud, "99-mr600-radiocal"), 0o755)
print("  ok  installed 99-mr600-radiocal into mt7621 base-files")
print("\nNOTE: base-files are per-subtarget, so these land in every mt7621 image.")
print("      The script checks board_name and exits on anything else, so it is inert there.")

# 4. LTE modem payload. Four pieces, and all are needed for the built-in M9645
#    to carry traffic unattended (see build-kit/README.md, "The LTE modem"):
#      etc/init.d/lte-reset      - prepares the module before the network comes up
#      etc/hotplug.d/iface/30-lte-apn - re-attaches the modem when the APN changes, because a
#                                  live bearer keeps the APN it attached with
#      etc/uci-defaults/99-mr600-lte - the wwan interface, the firewall zone, MM disabled
#      etc/mr600-apn-table       - mcc+mnc -> APN, so no carrier is baked in
#      etc/mr600-apn-mvno-table  - the vendor's own MVNO discriminators, derived from the modem's
#                                  NetIspInfo.ini and consulted BEFORE the plain table; that table
#                                  cannot express "which brand on this network", and for e.g. 31000
#                                  (17 entries) its single answer is wrong for every MVNO there
#      etc/mr600-apn-catalog     - the vendor's operator catalog, for the LuCI APN picker
#      usr/bin/at-tty            - set a line speed and speak AT; busybox here has neither
#                                  stty nor microcom. The binary is built by build.sh from
#                                  files/usr/bin/at-tty.c with the just-built toolchain.
for src, dst, mode in [
    ("files/etc/init.d/lte-reset", "etc/init.d/lte-reset", 0o755),
    ("files/etc/hotplug.d/iface/30-lte-apn", "etc/hotplug.d/iface/30-lte-apn", 0o755),
    ("files/etc/uci-defaults/99-mr600-lte", "etc/uci-defaults/99-mr600-lte", 0o755),
    ("files/etc/mr600-apn-table", "etc/mr600-apn-table", 0o644),
    ("files/etc/mr600-apn-mvno-table", "etc/mr600-apn-mvno-table", 0o644),
    ("files/etc/mr600-apn-catalog", "etc/mr600-apn-catalog", 0o644),
    ("files/usr/share/luci/menu.d/luci-app-mr600-apn.json",
     "usr/share/luci/menu.d/luci-app-mr600-apn.json", 0o644),
    ("files/usr/share/rpcd/acl.d/luci-app-mr600-apn.json",
     "usr/share/rpcd/acl.d/luci-app-mr600-apn.json", 0o644),
    ("files/www/luci-static/resources/view/mr600/apn.js",
     "www/luci-static/resources/view/mr600/apn.js", 0o644),
]:
    s = os.path.join(HERE, src)
    if not os.path.isfile(s):
        sys.exit(f"error: {src} is missing from the build kit")
    d = os.path.join(base, "mt7621/base-files", dst)
    os.makedirs(os.path.dirname(d), exist_ok=True)
    shutil.copyfile(s, d)
    os.chmod(d, mode)
    print(f"  ok  installed {dst}")
print("  ..  at-tty is built by build.sh from files/usr/bin/at-tty.c (needs the toolchain)")
