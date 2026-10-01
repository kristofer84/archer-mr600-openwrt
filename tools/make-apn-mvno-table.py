#!/usr/bin/env python3
"""Derive two small tables from the modem's own APN database.

Input is the vendor's `NetIspInfo.ini` - the file the modem itself carries at
`/etc/NetIspInfo.ini` and `/router/lib/NetIspInfo.ini`, and which the stock router pulls from the
module after `extract_isp` (see firmware.md). It is a *catalog*, not a lookup table: several brands
share one MCC/MNC and are separated only by a `Name`, so it cannot replace
`/etc/mr600-apn-table` (which is keyed `mccmnc -> apn`, one row per network, and is what
`lte-reset` uses by default). What it can do is supply the two things that table structurally
cannot express:

  1. `mr600-apn-mvno-table` - the entries the vendor disambiguates with `MVNOType`/`MVNOData`.
     `lte-reset` consults this FIRST, and falls back to the plain mccmnc table.
  2. `mr600-apn-catalog`    - the full `mccmnc -> Name/APN` catalog, for the LuCI dropdown, so
     the manual override is "pick your operator" rather than "know your APN".

Why this is worth doing even though `[240,08]` - this bench unit's network - gains nothing from
it: the vendor's discriminators cover MVNO-heavy markets where the plain table is not merely
imprecise but *wrong for every MVNO on the network*. `31000` carries 17 of them, `21403` 16,
`311500` 8, `20810` 6.

**`MVNOType` is not one thing, and the counts matter:**

    SPN   174 entries / 66 keys   -> readable via AT+CRSM EF_SPN 0x6F46
    GID1   60 entries / 34 keys   -> EF_GID1 0x6F3F; NOT implemented (see below)
    IMSI   25 entries             -> readable from AT+CIMI, which lte-reset already reads

All three were counted as one thing in an earlier analysis and the capability was overstated by
an order of magnitude. GID1 is left out deliberately: it needs EF_GID1 to exist (this bench SIM
answers `+CRSM: 103,0`, i.e. no such file), it is hex-matched rather than name-matched, and
nothing here can test it.

**SPN is matched as bytes, not as text.** `MVNOData` for an SPN entry is a display name, and the
SIM stores EF_SPN in GSM 7-bit (one septet per byte) or, in practice, sometimes UCS2 - the
catalog even carries a UCS2-only name (`中国电信`). Decoding either of those in busybox shell on
the boot path would be the fragile part of this design, so it is not done: the name is converted
to hex here, in *both* encodings where each fits in the 16-byte EF_SPN field, and `lte-reset` does
a prefix comparison on the hex bytes it read. That reduces to the same rule as the IMSI case - the
value must start with the pattern - so one comparison covers both.

Usage:
    tools/make-apn-mvno-table.py NetIspInfo.ini -o build-kit/files/etc

Writes `mr600-apn-mvno-table` and `mr600-apn-catalog` into the output directory. The source is a
vendor artifact and is not committed; these derived tables are, with the source's revision line
and digest recorded in their headers (see LESSONS.md, "Reconstruct against a digest, and then you
need not commit the blob").
"""

import argparse
import hashlib
import re
import sys
from collections import Counter

SECTION = re.compile(r"^\[(\d+),(\d+)\]$")
EF_SPN_BYTES = 16  # the name field is 16 bytes; the whole EF is 17, byte 1 being display condition


def parse(path):
    """Yield the sections of an INI-ish NetIspInfo.ini in file order."""
    sections, cur, revision = [], None, ""
    with open(path, "r", encoding="utf-8", errors="replace") as fh:
        for line in fh:
            line = line.rstrip("\n").strip()
            if not revision and re.fullmatch(r"\d{8}", line):
                revision = line
                continue
            m = SECTION.match(line)
            if m:
                cur = {"key": m.group(1) + m.group(2).zfill(2), "f": {}, "line": 0}
                sections.append(cur)
                continue
            if cur is not None and "=" in line:
                k, v = line.split("=", 1)
                cur["f"][k.strip()] = v.strip()
    for i, s in enumerate(sections):
        s["line"] = i
    return revision, sections


def spn_patterns(name):
    """Hex byte prefixes for a display name, in every encoding a SIM might have used."""
    out = []
    # GSM 7-bit / one septet per byte: identical to ASCII for the printable ASCII range.
    if all(ord(c) < 0x80 for c in name) and len(name) <= EF_SPN_BYTES:
        out.append(name.encode("ascii").hex())
    # UCS2 (UTF-16BE), which some SIMs use even for ASCII names.
    u = name.encode("utf-16-be")
    if len(u) <= EF_SPN_BYTES:
        out.append(u.hex())
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("source", help="NetIspInfo.ini from the modem")
    ap.add_argument("-o", "--outdir", required=True)
    args = ap.parse_args()

    raw = open(args.source, "rb").read()
    digest = hashlib.sha256(raw).hexdigest()
    blob = raw.decode("utf-8", errors="replace")
    revision, sections = parse(args.source)
    if not sections:
        sys.exit(f"{args.source}: no [mcc,mnc] sections found - wrong file?")

    kinds = Counter(s["f"].get("MVNOType") for s in sections if s["f"].get("MVNOType"))
    print(f"source revision {revision}, sha256 {digest[:16]}…, {len(sections)} sections")
    print(f"MVNOType: {dict(kinds)}")

    # ---- 1. the MVNO override table -------------------------------------------------
    # One row per (type, pattern, mccmnc). Rows that disagree on the APN for the same key are
    # dropped rather than guessed at: an ambiguous override is worse than no override, because
    # the plain table is at least a considered answer.
    rows, conflicts, skipped = {}, 0, Counter()
    for s in sections:
        t = s["f"].get("MVNOType")
        data = s["f"].get("MVNOData", "").strip()
        apn = s["f"].get("APN", "").strip()
        if not t or not data or not apn:
            continue
        if t == "IMSI":
            # every vendor IMSI pattern is <its own mccmnc><digits>x, and all end in 'x', so the
            # pattern is a digit prefix. Verified: 0 of 25 disagree with their section key.
            if not re.fullmatch(r"\d+x?", data):
                skipped["IMSI pattern not a digit prefix"] += 1
                continue
            if not data.rstrip("x").startswith(s["key"]):
                skipped["IMSI pattern does not start with its own mccmnc"] += 1
                continue
            pats = [data.rstrip("x")]
        elif t == "SPN":
            pats = spn_patterns(data)
            if not pats:
                skipped[f"SPN name does not fit in {EF_SPN_BYTES} bytes in any encoding"] += 1
                continue
        else:
            skipped[f"{t} (not implemented)"] += 1
            continue

        for p in pats:
            row = (t, p.lower(), s["key"], apn, s["f"].get("UserName", ""), s["f"].get("UserPass", ""))
            key = row[:3]
            if key in rows and rows[key][3] != apn:
                conflicts += 1
                del rows[key]  # ambiguous: drop the override, keep the plain table's answer
                continue
            if key not in rows:
                rows[key] = row

    mvno = f"{args.outdir}/mr600-apn-mvno-table"
    with open(mvno, "w", encoding="utf-8") as fh:
        fh.write("# MVNO overrides for lte-reset, derived from the modem's own NetIspInfo.ini\n")
        fh.write(f"# source revision {revision}  sha256 {digest}\n")
        fh.write("# regenerate: tools/make-apn-mvno-table.py NetIspInfo.ini -o <dir>\n")
        fh.write("# TYPE\tPATTERN\tMCCMNC\tAPN\tUSER\tPASS\n")
        fh.write("# TYPE=IMSI: PATTERN is a digit prefix of the IMSI.\n")
        fh.write("# TYPE=SPN : PATTERN is a lower-case hex byte prefix of EF_SPN with the\n")
        fh.write("#            display-condition byte removed. Matched against the IMSI's own\n")
        fh.write("#            mccmnc only, since EF_SPN does not carry one.\n")
        fh.write("# Longest matching PATTERN wins; no match falls back to /etc/mr600-apn-table.\n")
        for row in sorted(rows.values(), key=lambda r: (r[0], -len(r[1]), r[2])):
            fh.write("\t".join(row) + "\n")

    # ---- 2. the catalog, for the LuCI dropdown --------------------------------------
    cat = f"{args.outdir}/mr600-apn-catalog"
    seen = set()
    with open(cat, "w", encoding="utf-8") as fh:
        fh.write("# operator catalog for the LuCI APN picker, from the modem's NetIspInfo.ini\n")
        fh.write(f"# source revision {revision}  sha256 {digest}\n")
        fh.write("# MCCMNC\tNAME\tAPN\tUSER\tPASS\tCOUNTRY\n")
        for s in sections:
            apn = s["f"].get("APN", "").strip()
            name = s["f"].get("Name", "").strip()
            if not apn or not name:
                continue
            row = (s["key"], name, apn, s["f"].get("UserName", ""), s["f"].get("UserPass", ""),
                   s["f"].get("Country", ""))
            if row in seen:
                continue
            seen.add(row)
            fh.write("\t".join(row) + "\n")

    n_mvno = len(rows)
    print(f"wrote {mvno}: {n_mvno} rows "
          f"({sum(1 for r in rows.values() if r[0] == 'IMSI')} IMSI, "
          f"{sum(1 for r in rows.values() if r[0] == 'SPN')} SPN)")
    print(f"wrote {cat}: {len(seen)} rows")
    if conflicts:
        print(f"dropped {conflicts} ambiguous override(s) - same key, different APN")
    for why, n in skipped.most_common():
        print(f"skipped {n}: {why}")


if __name__ == "__main__":
    main()
