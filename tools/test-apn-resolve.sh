#!/bin/sh
# Exercise the real resolve_apn() from lte-reset against the real tables in this repo, with the
# AT port, QMI and uci stubbed out. No router and no SIM needed: the point is that the *shipped*
# code path answers correctly, including the cases that are hard to reproduce on hardware - an
# IMSI override, an SPN override, and a US SPN that must not answer for a Swedish SIM.
#
# Run from anywhere: tools/test-apn-resolve.sh
#
# Why this exists: the APN is derived at boot from the SIM, and every way it can go wrong is
# silent. A wrong answer here is not an error message, it is a link that comes up and then fails
# on the first re-activation, or attaches with another network's APN. verify-image.sh runs this
# as a gate before an image is trusted.

set -u

HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(dirname "$HERE")
SCRIPT="$REPO/build-kit/files/etc/init.d/lte-reset"
TABLE="$REPO/build-kit/files/etc/mr600-apn-table"
MVNO="$REPO/build-kit/files/etc/mr600-apn-mvno-table"

[ -r "$SCRIPT" ] || { echo "cannot read $SCRIPT" >&2; exit 1; }
[ -r "$TABLE" ]  || { echo "cannot read $TABLE" >&2; exit 1; }
[ -r "$MVNO" ]   || { echo "cannot read $MVNO" >&2; exit 1; }

TMP=$(mktemp -d) || exit 1
trap 'rm -rf "$TMP"' EXIT

# The script defines its own at(), so the stub has to be ATCMD rather than a shell function.
cat > "$TMP/at-tty-stub" <<'STUB'
#!/bin/sh
# mimic: at-tty <dev> <baud> <cmd>
for a in "$@"; do cmd="$a"; done
case "$cmd" in
  AT+CIMI)   [ -n "${STUB_CIMI:-}" ] && echo "$STUB_CIMI" ;;
  AT+CRSM=*) if [ -n "${STUB_SPN:-}" ]; then echo "+CRSM: 144,0,\"$STUB_SPN\""; else echo "+CRSM: 103,0,\"\""; fi ;;
esac
STUB
chmod +x "$TMP/at-tty-stub"

export STUB_CIMI="" STUB_SPN="" STUB_PLMN=""
uqmi() { # only --get-serving-system is used by the PLMN fallback
	[ -n "$STUB_PLMN" ] || return 0
	printf '{\n"plmn_mcc":%s,\n"plmn_mnc":%s\n}\n' "${STUB_PLMN%??}" "$(printf '%s' "${STUB_PLMN#???}" | sed 's/^0//')"
}
uci() { return 1; }   # no explicit override configured
logger() { :; }

# shellcheck disable=SC1090
. "$SCRIPT"
ATCMD="$TMP/at-tty-stub"; CTL=/dev/null
APN_TABLE=$TABLE
# Work on a COPY of the MVNO table: the "longest wins" case below adds rows to it, and the repo
# tree may be read-only - build.sh runs this from a read-only kit in the build container, where
# writing the tracked file fails and takes the case with it. Never mutate the repo.
cp "$MVNO" "$TMP/mvno"
APN_MVNO_TABLE=$TMP/mvno

# EF_SPN exactly as the bench SIM returns it: display-condition 00, "Telenor SE", 0xFF padding.
SPN_TELENOR_SE=0054656c656e6f72205345FFFFFFFFFFFF
# "C Spire" as ASCII bytes, for an SPN the vendor does disambiguate.
SPN_C_SPIRE=0043205370697265FFFFFFFFFFFFFFFF

pass=0; fail=0
check() { # check <label> <expected> <actual>
	if [ "$2" = "$3" ]; then
		printf '  ok    %-54s -> %s\n' "$1" "$3"; pass=$((pass + 1))
	else
		printf '  FAIL  %-54s -> %-22s want %s\n' "$1" "$3" "$2"; fail=$((fail + 1))
	fi
}

echo "== the bench unit: 24008 Telenor, which the vendor table does not discriminate =="
STUB_CIMI=240081234567890 STUB_SPN=$SPN_TELENOR_SE STUB_PLMN=
check "24008 + SPN 'Telenor SE' -> plain table" "internet.telenor.se" "$(resolve_apn)"

echo "== an IMSI override (pattern 204043914x, key 20404, APN truphone.com) =="
STUB_CIMI=204043914123456 STUB_SPN= STUB_PLMN=
check "IMSI 204043914123456" "truphone.com" "$(resolve_apn)"

echo "== an SPN override (key 20404, 'C Spire' -> internet.cs4glte.com) =="
STUB_CIMI=204041234567890 STUB_SPN=$SPN_C_SPIRE STUB_PLMN=
check "IMSI 20404... + SPN 'C Spire'" "internet.cs4glte.com" "$(resolve_apn)"

echo "== the key guard: an SPN carries no MCC/MNC, so it must not answer for another network =="
STUB_CIMI=240081234567890 STUB_SPN=$SPN_C_SPIRE STUB_PLMN=
check "24008 + SPN 'C Spire' -> must NOT match" "internet.telenor.se" "$(resolve_apn)"

echo "== no IMSI at all: the PLMN fallback still resolves =="
STUB_CIMI= STUB_SPN= STUB_PLMN=24008
check "PLMN 240/08, no IMSI" "internet.telenor.se" "$(resolve_apn)"

echo "== ambiguity is refused, not guessed =="
# 20416 'BEN NL' has two APNs in the vendor file, so the generator dropped the override and the
# plain table's single answer has to survive rather than one of the two being picked arbitrarily.
STUB_CIMI=204161234567890 STUB_SPN=0062656e206e6cFFFFFFFFFFFFFFFFFF STUB_PLMN=
check "20416 + SPN 'BEN NL' -> dropped, plain table" "internet" "$(resolve_apn)"

echo "== longest matching pattern wins =="
{
	printf 'SPN\t62656e206e6c\t20416\tshort.entry\n'
	printf 'SPN\t62656e206e6c3132\t20416\tlong.entry\n'
} >> "$APN_MVNO_TABLE"
STUB_CIMI=204161234567890 STUB_SPN=0062656e206e6c3132FFFFFFFFFFFFFF STUB_PLMN=
check "SPN 'BEN NL12' matches both, longest wins" "long.entry" "$(resolve_apn)"

echo "== an unknown carrier is refused, loudly and non-fatally =="
STUB_CIMI=999991234567890 STUB_SPN= STUB_PLMN=
out=$(resolve_apn); rc=$?
check "IMSI 99999..." "" "$out"
if [ $rc -ne 0 ]; then
	printf '  ok    %-54s -> exit %s\n' "non-zero exit" "$rc"; pass=$((pass + 1))
else
	printf '  FAIL  %-54s -> exit 0\n' "non-zero exit"; fail=$((fail + 1))
fi

echo
echo "passed $pass, failed $fail"
[ $fail -eq 0 ]
