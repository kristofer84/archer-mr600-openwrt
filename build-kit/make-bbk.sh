#!/usr/bin/env bash
# Build Bredbandskollen's CLI (bbk) for the MR600 from source, with this tree's own toolchain.
#
# Why build it instead of using the vendor's binary. They publish a static musl build for "MIPS
# little-endian ... e.g. ramips (mt76x8/mt7621)" - this router's exact family - and it cannot run
# here at all. It is compiled HARD FLOAT: the MT7621's CPU has no FPU, and this kernel is built
# with CONFIG_MIPS_FP_SUPPORT unset, so the first floating-point instruction it reaches is a
# SIGILL. On the router that is the whole error message: "Illegal instruction", with nothing in
# the log. Built soft-float with the same toolchain as the rest of the image, the binary contains
# no coprocessor-1 instruction at all - which is what the guards below assert, rather than
# trusting the filename.
#
#   ./make-bbk.sh                    build + verify, leave the binary at /tmp/bbk
#   OUT=/somewhere/bbk ./make-bbk.sh
#   ./make-bbk.sh --install          also put it in $TREE/files/usr/bin/, so the next image has it
#
# Env: TREE (OpenWrt build tree), WORK (source checkout), SRC_URL, SRC_REV, OUT.
#
# Deliberately not built by build.sh: it needs the network to clone the source, and it is a
# diagnostic tool rather than something the router needs in order to work, so it does not belong
# in every image by default.
set -euo pipefail

KIT="$(cd "$(dirname "$0")" && pwd)"
TREE="${TREE:-$HOME/openwrt-mr600}"
WORK="${WORK:-/tmp/mr600-bbk}"
OUT="${OUT:-/tmp/bbk}"
SRC_URL="${SRC_URL:-https://gitlab.com/internetstiftelsen-oss/bredbandskollen.git}"
# Pinned to VERSION 5.1.0, "Initial open-source release: CLI client and shared measurement engine".
SRC_REV="${SRC_REV:-f2794692d6ae70d92068ae8e9a1e8981ec5a83ae}"
# What this revision built to with this tree's GCC 14.4.0. Reported rather than enforced: another
# toolchain gives another digest, and the properties that decide whether it *runs* are the two
# guards below, not this number.
KNOWN_DIGEST=17c29286a3353a535179323e3328a263552b44776e5ffb06c5398671f97fbef1

INSTALL=0
for a in "$@"; do
	[ "$a" = --install ] && INSTALL=1
done

# ---- toolchain -------------------------------------------------------------
TCBIN="$(ls -d "$TREE"/staging_dir/toolchain-mipsel_24kc_*_musl/bin 2>/dev/null | head -1 || true)"
if [ -z "$TCBIN" ]; then
	echo "no mipsel_24kc_*_musl toolchain under $TREE/staging_dir" >&2
	echo "run build.sh once first - it builds the toolchain before the image" >&2
	exit 1
fi
CXX="$TCBIN/mipsel-openwrt-linux-musl-g++"
STRIP="$TCBIN/mipsel-openwrt-linux-musl-strip"
READELF="$TCBIN/mipsel-openwrt-linux-readelf"
OBJDUMP="$TCBIN/mipsel-openwrt-linux-objdump"
for t in "$CXX" "$STRIP" "$READELF" "$OBJDUMP"; do
	[ -x "$t" ] || { echo "missing $t" >&2; exit 1; }
done
command -v git >/dev/null || { echo "git not found - needed to fetch the source" >&2; exit 1; }
# The toolchain wrapper reads this to find its sysroot, and warns on every compile without it.
export STAGING_DIR="${STAGING_DIR:-$TREE/staging_dir}"

# ---- source ----------------------------------------------------------------
if [ -d "$WORK/bredbandskollen/.git" ]; then
	git -C "$WORK/bredbandskollen" fetch --quiet origin
elif [ -e "$WORK/bredbandskollen" ]; then
	echo "$WORK/bredbandskollen exists and is not a git checkout - move it aside or set WORK" >&2
	exit 1
else
	echo "==> cloning $SRC_URL"
	mkdir -p "$WORK"
	git clone --quiet "$SRC_URL" "$WORK/bredbandskollen"
fi
echo "==> $SRC_REV (VERSION $(cat "$WORK/bredbandskollen/VERSION" 2>/dev/null || echo '?'))"
git -C "$WORK/bredbandskollen" checkout --quiet "$SRC_REV"

# ---- build -----------------------------------------------------------------
# Two things this link needs, both found the hard way, both specific to this toolchain:
#   * its -static spec pulls in -lgcc but NOT -lgcc_eh, so C++ exception handling is left
#     undefined (_Unwind_Resume, referenced from libstdc++). It has to be named explicitly, after
#     the objects and inside an archive group, so the scan order does not matter.
#   * 64-bit atomics on 32-bit MIPS (__atomic_load_8/__atomic_store_8, in framework/logger.cpp)
#     need libatomic.
cd "$WORK/bredbandskollen/cli"
make clean >/dev/null 2>&1 || true
echo "==> building with $CXX"
make -j"$(nproc)" \
	CXX="$CXX" \
	EXTRA_CXXFLAGS="-ffunction-sections -fdata-sections" \
	EXTRA_LDFLAGS="-static" \
	LIBS="-Wl,--start-group -lstdc++ -lgcc_eh -lgcc -latomic -Wl,--end-group"

[ -f bbk ] || { echo "the build produced no bbk" >&2; exit 1; }

# ---- the guards ------------------------------------------------------------
# These are the point of the script: they check the property that decides whether the binary
# runs on this router, instead of the property its filename advertises.
#
# Note the shape: each check captures the tool's output and then matches it, rather than piping
# into `grep -q`. Under `set -o pipefail` a `producer | grep -q` reports the producer's SIGPIPE
# (141) as the pipeline's status, so `if ! ...` fires on a *successful* match. That is not a
# hypothetical - the first version of this script refused a binary it had just described as
# soft-float.
ABI="$("$READELF" -A bbk)"
case "$ABI" in
*"FP ABI: Soft float"*) ;;
*)
	echo "refusing: the ELF does not declare a soft-float ABI:" >&2
	printf '%s\n' "$ABI" | grep "FP ABI" >&2 || true
	exit 1 ;;
esac

# The decisive one: these are the instructions that fault, whatever the labels say.
FPU_INSNS="$("$OBJDUMP" -d bbk | grep -cE '^[[:space:]]+[0-9a-f]+:[[:space:]]+[0-9a-f]{8}[[:space:]]+(lwc1|swc1|ldc1|sdc1|mfc1|mtc1|cfc1|ctc1|[a-z]+\.[sd])' || true)"
case "$FPU_INSNS" in
0) ;;
*)
	echo "refusing: the binary has $FPU_INSNS floating-point (coprocessor-1) instructions." >&2
	echo "On this router those are SIGILL: the CPU has no FPU and the kernel will not emulate one." >&2
	exit 1 ;;
esac

DYNAMIC="$("$READELF" -d bbk 2>&1 || true)"
case "$DYNAMIC" in
*"no dynamic section"*) ;;
*)
	echo "refusing: not statically linked - it would want libraries the image does not carry" >&2
	exit 1 ;;
esac

# ---- result ----------------------------------------------------------------
"$STRIP" bbk
GOT="$(sha256sum bbk | cut -d' ' -f1)"
SIZE="$(wc -c < bbk)"
echo
echo "ok: soft-float, static, $SIZE bytes"
echo "    sha256 $GOT"
[ "$GOT" = "$KNOWN_DIGEST" ] || echo "    note: not the digest this kit recorded ($KNOWN_DIGEST) - expected from a"$'\n'"    different gcc; the guards above are what decide whether it runs"

cp -f bbk "$OUT"
echo "==> written to $OUT"

if [ "$INSTALL" = 1 ]; then
	mkdir -p "$TREE/files/usr/bin"
	cp -f bbk "$TREE/files/usr/bin/bbk"
	chmod 0755 "$TREE/files/usr/bin/bbk"
	echo "==> installed to $TREE/files/usr/bin/bbk - the next build.sh will include it"
	echo "    over LTE it is worth keeping an eye on the data it spends: --duration=2 spends far"
	echo "    less than the default 10, and --speedlimit=N caps the average"
fi
