#!/usr/bin/env bash
# Rebuild files/root/radio-cal.bin, which is deliberately not committed (vendor calibration
# data). Verifiable either way - the digest assertion below must pass.
#
#   ./make-radio-cal.sh /path/to/mtd2.bin             (a stock rootfs partition dump)
#   ./make-radio-cal.sh /path/to/extracted-rootfs     (a tree with etc/MT76*E_EEPROM.bin)
#
# You do NOT need this for a normal install. It exists only to bake one unit's calibration into
# an image as a fallback for a unit whose radio region is erased. See README.md.
set -euo pipefail
KIT="$(cd "$(dirname "$0")" && pwd)"
SRC="${1:?usage: make-radio-cal.sh <mtd2.bin|extracted-rootfs-dir>}"
WANT=f5efdc7e14fd18564eef8b188b8a016b23338fde045376789b0d8fd1363f27e7

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
if [ -d "$SRC" ]; then
  ROOT="$SRC"
else
  command -v unsquashfs >/dev/null || {
    echo "unsquashfs not found - install squashfs-tools, or pass an already-extracted rootfs" >&2
    exit 1; }
  echo "==> unsquashfs $SRC"
  unsquashfs -q -f -d "$WORK/root" "$SRC" >/dev/null
  ROOT="$WORK/root"
fi

for f in etc/MT7603E_EEPROM.bin etc/MT7612E_EEPROM.bin; do
  [ -f "$ROOT/$f" ] || { echo "missing $ROOT/$f - is this the stock rootfs?" >&2; exit 1; }
done

python3 - "$ROOT" "$KIT/files/root/radio-cal.bin" "$WANT" <<'PY'
import hashlib, sys
root, out, want = sys.argv[1], sys.argv[2], sys.argv[3]
blob = bytearray(b'\xff' * 0x10000)
blob[0x0000:0x0200] = open(f"{root}/etc/MT7603E_EEPROM.bin", 'rb').read()
blob[0x8000:0x8200] = open(f"{root}/etc/MT7612E_EEPROM.bin", 'rb').read()
got = hashlib.sha256(blob).hexdigest()
if got != want:
    sys.exit(f"digest mismatch:\n  got  {got}\n  want {want}\n"
             "This is not this unit's calibration. Do NOT use it.")
open(out, 'wb').write(bytes(blob))
print(f"  ok  wrote {out}\n      sha256 {got}")
PY
