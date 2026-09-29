# Install OpenWrt on a TP-Link Archer MR600 v1 (EU)

A linear procedure. Every step below has been done on real hardware. If something fails, the
detailed notes are in [build-kit/README.md](build-kit/README.md) - this file keeps only what you
need to get it done.

Read this whole page once before starting. §1 opens the case and is destructive.

---

## 0. Check that this is the right device

| | |
|---|---|
| **Supported** | Archer MR600 **v1 (EU)** only. |
| **Not supported** | v2 and v3. They have different hardware and different OpenWrt support. Do not flash this image on them. |

Confirm the version on the label under the router, or in the stock web UI under *Status*. If you
are unsure, stop.

**This router is a whole uplink if it is your only one.** The install is recoverable over UART
(§9), but only if you have the UART connection working. Do §1-§2 before you write anything.

### You need

* A **3.3V** USB-to-TTL serial adapter. **Do not use a 5V adapter** - it can damage the SoC.
* Wires or a probe for the back-side UART header (2.54 mm pitch), and a plastic pry tool + a
  Phillips screwdriver for the case.
* An Ethernet cable and a computer that can run a **TFTP server** on its wired NIC.
  If your computer runs WSL2, run the TFTP server on the Windows host - a server inside WSL2 is
  NATed and the router cannot reach it.
* The image (§0.1 or §0.2).

---

## 0.1 Get the image - prebuilt

Download from this repo's **Releases** page:

| file | what it is |
|---|---|
| `*-initramfs-kernel.bin` | boots entirely in RAM, **writes nothing**. This is what you TFTP first. Rename it `test.bin`. |
| `*-squashfs-sysupgrade.bin` | what you commit once the initramfs is verified. |

Verify what you downloaded:

```sh
sha256sum -c SHA256SUMS     # runs against the names in the file
```

The released image is a **generic** build: it ships **no** WiFi calibration blob, so it contains
no per-unit data. First boot keeps the target unit's own calibration (§7).

## 0.2 Or build it yourself

See [build-kit/README.md](build-kit/README.md). Roughly 20 GB of disk and a few hours, and it
reproduces. The output lands in `bin/targets/ramips/mt7621/`; take the same two files as above.

---

## 1. Open the case and connect UART

Opening the case is **destructive**: a screw is hidden under the front silver plastic fin, and the
fin/cover tend to break when removed. This is the accepted cost of a reliable install. The UART
header is on the **back** of the PCB.

Pinout, measured on hardware (the header on the back means pin numbers can read **mirrored** -
anchor on **GND = pin 2**, never on a pin-1 marking):

| pin | signal |
|---|---|
| 2 | **GND** |
| 4 | **console TX** (router → your adapter's RX) |
| 1 or 3 | **router RX** (your adapter's TX → this pin). Not recorded which of the two; see below. |

Wiring to **read** the console:

```
adapter GND -> pin 2
adapter RX  -> pin 4
```

Serial settings: **115200 8N1**. In OpenWrt this UART is `ttyS0`; the stock firmware calls the
same physical port `ttyS1` - that difference is expected, not a problem.

To **type** at the U-Boot prompt you must also connect the adapter's TX to the router's RX. Which
of pin 1 or 3 that is was not recorded, so confirm it: connect to one, power on, press Enter, and
see whether the prompt echoes your keystrokes. If not, move it to the other pin. On some units the
router will not boot with the adapter's TX connected - if so, power on first, then connect TX.

Start a serial capture before you touch anything and keep the log. It is the only record if a
write goes wrong.

---

## 2. Back up stock (do this, and keep the files)

With the case open, you can boot stock firmware and dump the flash over the network. This is your
way back.

1. Power on into **stock** firmware. On the serial console, log in as `admin` / `1234` (the stock
   console credential; the web password may differ).
2. Note the partition map and dump the kernel and rootfs to your TFTP server:

```sh
cat /proc/mtd
tftp -l /dev/mtd1 -r mtd1-kernel.bin -p <your-pc-ip>
tftp -l /dev/mtd2 -r mtd2-rootfs.bin -p <your-pc-ip>
```

`mtd1` (kernel) and `mtd2` (rootfs) are the two that matter for a restore. Keep the TFTP server
running and the files somewhere safe.

> **How the two files restore stock:** concatenate them and write the result over OpenWrt's single
> `firmware` partition - the stock layout is kernel (`0x20000`) + rootfs (`0x220000`) inside
> OpenWrt's `firmware` at `0x20000`. §9 has the exact commands. Keep the two files in the order
> dumped.

---

## 3. Serve the initramfs and enter U-Boot

1. Put the **initramfs** image in your TFTP root renamed **`test.bin`**.
2. Give your computer's wired NIC a static address on the router's LAN, e.g. `192.168.0.5/24`.
   Stock U-Boot already expects `ipaddr=192.168.0.1` and `serverip=192.168.0.5`, so this works
   with no client setup. (Any on-link subnet is fine; change both sides together.)
3. Start the TFTP server on that interface.
4. Power the router on and **spam `t`** on the serial console to break into U-Boot. The v1 prompt
   is **`MT7621 #`**.

> **Two rules that brick the device if broken:**
> * **Never `saveenv`.** Stock U-Boot writes its environment to flash `0x20000`, the start of the
>   kernel partition.
> * **Never choose boot-menu option 1.** It calls `saveenv` before booting.
>
> `setenv` is safe: it changes RAM only, for the next boot. `printenv` is safe.

---

## 4. Boot the initramfs (this writes nothing)

At the `MT7621 #` prompt:

```
setenv ipaddr 192.168.0.1
setenv serverip 192.168.0.5
tftpboot 0x82000000 test.bin
bootm 0x82000000
```

That is the whole sequence - **no `setenv bootargs` is needed.** U-Boot passes its own, and its
defaults already use `console=ttyS0,115200`, which is the right console for OpenWrt. Only if the
console is silent after `bootm` should you force it for one boot:

```
setenv bootargs 'console=ttyS0,115200'
bootm 0x82000000
```

> `bootm` takes the **plain** load address. Do **not** add `+0x200`. The file has a 512-byte
> TP-Link tag at the front, but this U-Boot adds that offset itself; `bootm 0x82000000` correctly
> reports `## Booting image at 82000200`.

You should land at an OpenWrt shell `root@OpenWrt:~#`. Nothing has been written to flash.

---

## 5. Verify before committing anything (still write-free)

At the initramfs shell, check in this order:

```sh
cat /proc/mtd                                   # partitions: boot, firmware, kernel, rootfs, romfile, config, filler, radio
ip link                                         # eth0 and the wifi devices
dmesg | grep -i mt76                            # radios loading firmware
ls /dev/cdc-wdm0                                # the LTE modem's QMI port
logread | grep 'lte:'                           # LTE prep lines
```

You may need to bring Ethernet up manually. Confirm you can reach the router and that the radios
appear. If `/dev/cdc-wdm0` is missing, stop - do not commit; the modem will not work. Work
through §7's checks from the initramfs first.

---

## 6. Commit the install

From the initramfs, fetch and write the sysupgrade image. Put it in the same TFTP root:

```sh
cd /tmp
tftp -g -r sysupgrade.bin -l sysupgrade.bin <your-pc-ip>
sysupgrade -n /tmp/sysupgrade.bin
```

`-n` means "do not keep existing config" - correct for a first install from stock. The router
writes `firmware` and reboots into OpenWrt.

**If the write fails or the unit will not boot, go to §9.** Do not power-cycle mid-write.

---

## 7. First boot: LTE should come up by itself

The first boot takes a little longer on purpose - the init script delays the network ~25 s while
it prepares the modem. Expect `lte:` lines on the console, ending with a working `wwan0`:

```sh
logread | grep 'lte:'            # "QMI unhealthy; re-enumerating" -> "APN set" (or similar)
ifstatus wwan | grep '"up"'      # "up": true
ip -4 addr show wwan0            # an inet address (a DHCP lease from the modem)
ping -c3 8.8.8.8
```

**The APN is derived from your SIM's MCC/MNC and written into `network.wwan0.apn`.** You do not
set it. It is visible and editable in LuCI; changing it re-attaches the modem (~1 minute).

The WiFi calibration is **per unit**. On first boot the image keeps whatever your radio region
already holds (any unit that has booted stock firmware has its own). A generic released image
therefore does not overwrite your calibration.

### If there is no lease

Work down this list - each check rules out one thing:

1. **APN.** `uci get network.wwan0.apn` must be non-empty and match the *active* context:
   `AT+CGCONTRDP` on `/dev/ttyUSB2` (use `at-tty`). Note `AT+CGDCONT?` reads empty even when the
   link works - the module consumes it and does not store it.
2. **Radio on.** `AT+CFUN?` must be `1`. The init script sets it; if the AT port was not ready it
   could not - check `logread | grep 'lte:'` for a warning.
3. **QMI alive.** `uqmi -d /dev/cdc-wdm0 --get-serving-system`. If that fails while AT answers,
   the module's QMI processor is wedged and needs a **full power cycle** (unplug power, not just a
   reboot).
4. **Firewall.** `uci show firewall | grep 'zone\[1\].network'` must include `wwan`, or LAN
   clients get no internet even though the router does.
5. **`raw_ip`.** `cat /sys/class/net/wwan0/qmi/raw_ip` should be `Y`; the init script sets it.

---

## 8. WiFi as an access point (manual, not fully verified)

The radios load with firmware, but the stock OpenWrt default leaves the interfaces disabled. To
turn on an AP:

```sh
uci set wireless.radio0.disabled=0
uci set wireless.radio1.disabled=0
uci set wireless.default_radio0.disabled=0
uci set wireless.default_radio1.disabled=0
uci set wireless.default_radio0.ssid='your-ssid'
uci set wireless.default_radio0.encryption='psk2'
uci set wireless.default_radio0.key='your-key'
uci commit wireless
wifi reload
```

This is the least-verified part of this repo - the modem uplink is the part proven unattended. If
WiFi misbehaves, the build kit's [README](build-kit/README.md) has the radio details, and if it
is dead after an install check `dmesg | grep -i radio` and the `radio` partition first.

---

## 9. Recovery

### Restore stock OpenWrt -> stock firmware

Boot the initramfs again (§3-§4, write-free), then put the two backup files back. **Note the
partition names differ from stock:** in the OpenWrt map the whole `firmware` region is one
partition, so the two stock dumps are concatenated and written there as a unit.

```sh
cd /tmp
tftp -g -r mtd1-kernel.bin -l mtd1-kernel.bin <your-pc-ip>
tftp -g -r mtd2-rootfs.bin -l mtd2-rootfs.bin <your-pc-ip>
cat mtd1-kernel.bin mtd2-rootfs.bin > stock-firmware.bin
mtd erase firmware
mtd write stock-firmware.bin firmware
```

Then reboot. Your unit's WiFi calibration at flash `0xff0000` is outside these two partitions and
was preserved by the install (§7), so it is not part of the restore.

### Restore from the running OpenWrt (no initramfs boot)

If the installed OpenWrt still boots and you can reach it over SSH, you can skip §3-§4 and write
the concatenated stock image directly - the `firmware` partition is writable and `mtd` is present
on the running system. On your PC:

```sh
cat mtd1-kernel.bin mtd2-rootfs.bin > stock-firmware.bin   # exactly 16,384,000 B
```

Copy it to the router, verify its sha256 matches, then on the router:

```sh
mtd write /tmp/stock-firmware.bin firmware
mtd verify /tmp/stock-firmware.bin firmware   # must print "Success" before you reboot
reboot
```

This writes over a mounted rootfs and overlay, so it is marginally less safe than the initramfs
route above - but it has been done on hardware and verified byte-for-byte. Prefer the initramfs
route if anything about the running system is in doubt.

### If U-Boot will not reach a prompt

U-Boot itself is rarely damaged by an image write of the `firmware` partition. If the device will
not boot at all, capture full serial output from power-on (see §1) before anything else.

### If the router will not boot the initramfs

Capture, in order: the full serial output from power-on; `printenv` at the U-Boot prompt; the
`bootm` error if any. The usual causes are the TFTP server being unreachable (check `printenv`
for `ipaddr`/`serverip` and re-`setenv`), the wrong `bootm` address, or a bad download.

---

## What is verified, and what is not

**Verified on hardware:** the UART boot path, the TFTP initramfs boot, the `sysupgrade` install,
the partition map, the persistent overlay surviving reboot, both radios loading, `/dev/cdc-wdm0`,
and LTE carrying traffic across cold and warm boots with automatic APN derivation.

**Verified only on one physical unit:** the LTE recipe (the init script and its four modem
requirements). The build kit's checks catch the silent failure modes, but a second unit is not
yet confirmed.

**Not verified:** WiFi AP mode end-to-end (§8).
