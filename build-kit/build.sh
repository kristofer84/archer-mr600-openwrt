#!/usr/bin/env bash
# Build OpenWrt for the TP-Link Archer MR600 v1 (EU).
#
#   TREE=~/openwrt-mr600 ./build.sh
#
# Produces, in $TREE/bin/targets/ramips/mt7621/:
#   *-initramfs-kernel.bin      -> TFTP-boot this to verify BEFORE writing anything
#   *-squashfs-sysupgrade.bin   -> what you commit with sysupgrade once verified
#   *-squashfs-factory.bin      -> the stock-layout image, for raw writes
set -euo pipefail

KIT="$(cd "$(dirname "$0")" && pwd)"
TREE="${TREE:-$HOME/openwrt-mr600}"
# shellcheck source=upstream.lock
. "$KIT/upstream.lock"

echo "==> checking prerequisites"
missing=0
for c in git make gcc g++ python3 rsync unzip gawk curl; do
  command -v "$c" >/dev/null || { echo "   MISSING: $c" >&2; missing=1; }
done
for h in ncurses.h openssl/ssl.h zlib.h; do
  found=$(find /usr/include -name "$(basename "$h")" 2>/dev/null | head -1)
  [ -n "$found" ] || { echo "   MISSING header: $h  (apt install libncurses-dev libssl-dev zlib1g-dev)" >&2; missing=1; }
done
[ "$missing" = 0 ] || { echo "install the above, then re-run" >&2; exit 1; }
echo "   ok"

echo "==> clone or reuse $TREE"
if [ ! -d "$TREE/.git" ]; then
  git clone https://git.openwrt.org/openwrt/openwrt.git "$TREE"
  git -C "$TREE" -c advice.detachedHead=false checkout "$OPENWRT_COMMIT"
else
  echo "   reusing existing checkout"
  [ "$(git -C "$TREE" rev-parse HEAD)" = "$OPENWRT_COMMIT" ] ||
    echo "   WARNING: $TREE is not at the pinned $OPENWRT_COMMIT (upstream.lock)" >&2
fi
cd "$TREE"
echo "   openwrt at $(git rev-parse HEAD)"

echo "==> apply PR #25074 (v1-additive, 4 files)"
if git apply --check "$KIT/patches/0001-pr25074-v1-additive.patch" 2>/dev/null; then
  git apply "$KIT/patches/0001-pr25074-v1-additive.patch"
  echo "   applied cleanly"
elif git apply -3 "$KIT/patches/0001-pr25074-v1-additive.patch" 2>/dev/null; then
  echo "   applied with a 3-way merge - CHECK the result before building"
else
  cat >&2 <<'MSG'
   ERROR: the PR patch does not apply. Upstream main has moved.
   Fall back to hand-editing, which is 4 files:
     1. copy patches/mt7621_tplink_mr600-v1-eu.dts to
        target/linux/ramips/dts/mt7621_tplink_mr600-v1-eu.dts
     2. add the Device/tplink_mr600-v1-eu block to
        target/linux/ramips/image/mt7621.mk  (see patches/mr600-mk-block.txt)
     3. add the tplink,mr600-v1-eu case to board.d/01_leds
     4. add tplink,mr600-v1-eu to the two lists in board.d/02_network
   Then re-run this script; it will skip step 1 if the file already exists.
MSG
  exit 1
fi

echo "==> apply this project's changes"
python3 "$KIT/apply-local-changes.py"

echo "==> feeds (needed before the package symbols resolve)"
# Written from upstream.lock, not copied from feeds.conf.default, so every feed is at a fixed commit.
cat > feeds.conf <<FEEDS
src-git packages https://git.openwrt.org/feed/packages.git^$FEED_PACKAGES
src-git luci https://git.openwrt.org/project/luci.git^$FEED_LUCI
src-git routing https://git.openwrt.org/feed/routing.git^$FEED_ROUTING
src-git telephony https://git.openwrt.org/feed/telephony.git^$FEED_TELEPHONY
src-git video https://github.com/openwrt/video.git^$FEED_VIDEO
FEEDS
./scripts/feeds update -a
for f in packages luci routing telephony video; do
  echo "   feed $f at $(git -C "feeds/$f" rev-parse HEAD)"
done
./scripts/feeds install -a

echo "==> configure"
# Seed FIRST, then defconfig. The other order lets the tree resolve for the default target
# (mediatek/filogic), and the later switch to ramips leaves stale selections behind: the first
# images out of this kit had no WiFi drivers at all because of exactly that.
touch .config
cat "$KIT/config.seed" >> .config
# Optional local variant: extra packages without touching the tracked, published seed.
if [ -f "$KIT/config.seed.local" ]; then
  echo "   LOCAL VARIANT: applying config.seed.local"
  cat "$KIT/config.seed.local" >> .config
  # Record what was applied, so verify-image.sh can judge the artifact later even if the
  # seed file has moved on. The .config says what survived; this says what was intended.
  cp "$KIT/config.seed.local" .config.seed.local.applied
else
  echo "   GENERIC image: no config.seed.local present (this is the published variant)"
  rm -f .config.seed.local.applied
fi
make defconfig
grep -q "CONFIG_TARGET_ramips_mt7621=y" .config || {
  echo "   ERROR: target did not resolve to ramips/mt7621" >&2; exit 1; }
grep -q "DEVICE_tplink_mr600-v1-eu=y" .config || {
  echo "   ERROR: the mr600 device is not selected" >&2; exit 1; }
echo "   target ok"
echo "   target is:"
grep -E "CONFIG_TARGET_ramips_mt7621_DEVICE_tplink_mr600-v1-eu|CONFIG_PACKAGE_(luci|sms-tool)" .config | sed 's/^/     /'

echo "==> toolchain"
# Needed before the rootfs is packaged, because at-tty has to be compiled and
# placed in the target's base-files first.
make -j"$(nproc)" toolchain/install

BLF="$TREE/target/linux/ramips/mt7621/base-files"
echo "==> at-tty (the AT helper - this busybox has no stty and no microcom)"
TC=$(ls -d "$TREE"/staging_dir/toolchain-*/bin/mipsel-openwrt-linux-musl-gcc 2>/dev/null | head -1)
{
  [ -n "$TC" ] && [ -x "$TC" ]
} || { echo "   ERROR: no OpenWrt toolchain found under staging_dir" >&2; exit 1; }
mkdir -p "$BLF/usr/bin"
"$TC" -static -Os -o "$BLF/usr/bin/at-tty" "$KIT/files/usr/bin/at-tty.c"
[ -x "$BLF/usr/bin/at-tty" ] || { echo "   ERROR: at-tty did not build" >&2; exit 1; }
echo "   ok  $BLF/usr/bin/at-tty"

echo "==> build (long: kernel and packages)"
make -j"$(nproc)"

echo "==> verifying what the image contains"
# Kept in its own script so it can be run against a built tree at any time, without
# rebuilding - see verify-image.sh. The guards there are the ones that catch a silent
# failure, so they are worth being able to re-run.
TREE="$TREE" "$KIT/verify-image.sh"
cat <<'MSG'

Next, and do not skip it: TFTP-boot the initramfs-kernel.bin and verify on the device BEFORE
writing anything. See README.md, "Verifying". Copy it into the TFTP root as test.bin.
MSG
