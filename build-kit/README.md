# MR600 v1 (EU): OpenWrt build kit

Builds OpenWrt for the TP-Link Archer MR600 v1 (EU), with the built-in LTE modem working
unattended. The install procedure is in [../INSTALL.md](../INSTALL.md); this file is how the image
is made and what is in it.

## Run it

```sh
cd build-kit
./build.sh                      # builds into ~/openwrt-mr600
# or:  TREE=/some/path ./build.sh
```

It clones upstream OpenWrt at the commit pinned in [upstream.lock](upstream.lock) (the feeds are
pinned there too), applies PR #25074, applies this kit's changes, seeds the config,
fetches the feeds and builds. Expect roughly 20 GB of disk and a few hours; the toolchain download
and build dominate, the target is quick after that.

The last step is [verify-image.sh](verify-image.sh), kept separate so it can also be run against a
tree that is already built - `TREE=~/openwrt-mr600 ./verify-image.sh`, no rebuild:

```
==> WiFi drivers, in the rootfs that gets packed
   ok      mt7603e.ko
   ok      mt76x2e.ko
==> the LTE payload, in base-files
   ok      base-files/etc/init.d/lte-reset
   ...
all checks passed
```

Every check there catches a failure that is otherwise *silent*: an image with no WiFi drivers
boots with no WiFi, one without the LTE payload boots with no modem and simply never takes a
lease, and an APN that never reaches uci brings the link up at boot and then fails on the first
interface restart. Treat a failed verification as "do not flash".

Outputs land in `$TREE/bin/targets/ramips/mt7621/`:

| artifact | what it is for |
|---|---|
| `*-initramfs-kernel.bin` | **TFTP-boot this first.** Runs entirely in RAM, writes nothing |
| `*-squashfs-sysupgrade.bin` | what you commit once the initramfs has been verified |
| `*-squashfs-factory.bin` | stock-layout image, for a raw write (not needed for the normal install) |

### Local variants, and why the version string cannot identify one

`build.sh` reads an optional `build-kit/config.seed.local` (gitignored) after the tracked seed, so a
local image can add packages without diverging the published one. It copies what it applied to
`$TREE/.config.seed.local.applied`, and `verify-image.sh` requires every `CONFIG_...=y` line in
that record to be present in the built `.config` - a mismatch is a hard failure, because a release
must not ship one.

**A local variant is invisible in the running system.** `DISTRIB_REVISION` comes from the tree, so
a generic build and a variant of the same commit report the *same* `r...-<hash>`. Measured on this
device on 2026-09-30: generic and local-variant builds both read `r36672-138fabb79f`. Neither the
version string nor an attestation naming the commit tells you which you have. The only records are
the seed pair (`config.seed.local` and its `.applied` copy) and the build log, which ends with an
explicit `LOCAL VARIANT` or `GENERIC image` line. Keep those with the image, or "same revision"
becomes "same image" in someone's head and the packages are simply gone.

**Size, measured rather than estimated.** A local set of `qmi-utils`, `openvpn-openssl`,
`mosquitto-client-ssl`, `tcpdump` and `curl` took the rootfs squashfs from **4.5 MB to 8.5 MB - +4.0
MB compressed**, which is about **2.2:1** on installed size, not the ~3:1 a general xz figure
suggests. glib/libqmi-heavy sets compress worse than the average, so budget by 2:1 and the estimate
stays conservative. The firmware partition is 15.6 MB, so a 3.5 MB kernel plus an 8.5 MB squashfs
leaves ~3.5 MB - it fits, with less room than a 3:1 assumption would have predicted.

## Calibration: generic by default, per unit by nature

The WiFi calibration is **per unit** - it carries that unit's RF calibration and a MAC seed - so
one unit's blob must never be written to another. The kit therefore does not commit a blob, and
the default build is **generic**:

* `99-mr600-radiocal` runs on first boot and **preserves whatever the target unit's `radio`
  region already holds**. Any unit that has booted stock firmware has its own calibration there,
  which is the normal case.
* Only if that region is blank does it write a blob baked into the image - and a generic build has
  none, so a unit with an erased radio region needs a non-generic build instead.

**Why this matters for a release:** a baked blob would publish one unit's calibration. Keep
releases generic.

To bake a specific unit's blob in as the fallback (for a unit whose region is erased):

```sh
./make-radio-cal.sh /path/to/mtd2.bin             # a stock rootfs dump
./make-radio-cal.sh /path/to/extracted-rootfs     # or a tree with etc/MT76*E_EEPROM.bin
```

It assembles the 64K blob (MT7603E EEPROM at `0x0`, MT7612E at `0x8000`, `0xFF` elsewhere) and
**asserts a fixed SHA-256** before writing `files/root/radio-cal.bin`. The blob is gitignored; only
commit it never. Re-running `build.sh` then bakes it into the image.

### The two 64K regions, which are easy to confuse

| region | what it actually is |
|---|---|
| `0xfe0000` | where the **stock kernel** registers its `radio` partition. Blank on a stock unit. OpenWrt calls it `filler` and ignores it. |
| `0xff0000` | the last 64K of the chip, covered by **no** stock partition, where the **stock WiFi driver** keeps its calibration behind a hardcoded base. Not blank on a unit that has booted stock firmware. |

OpenWrt's DTS calls `0xff0000` `radio` and reads the EEPROM from it via `eeprom@0`/`eeprom@8000`,
which is why `radio` has to be writable and why the blob lives there.

## What is in the image, and how sure I am

**From PR #25074, verbatim** (`patches/0001-pr25074-v1-additive.patch`, 4 files):

* `dts/mt7621_tplink_mr600-v1-eu.dts`
* `image/mt7621.mk` - the `Device/tplink_mr600-v1-eu` block
* `board.d/01_leds`, `board.d/02_network`

The PR's LED and button map agrees pin for pin with the map read independently from the vendor
GPL's `ralink_gpio_logic.h` - two independent sources on one device is the best confidence
available here.

**This kit's changes** (`apply-local-changes.py`, each edit asserted so a missed change is a hard
error):

| change | why |
|---|---|
| `radio` partition made writable | stock marks it read-only; the calibration write fails with `EROFS` otherwise |
| `filler@0xfe0000` added | completes the partition map; the PR leaves a 64K hole between `config` and `radio` |
| `led_enable` hog on GPIO 3, active low | the board gates every LED on this pin; without it the LEDs stay dark even though the nodes are right |
| `wwan0` MAC = `eth0+2` | the PR routes v1 into the v2 case, which uses `eth0+1`; separate values keep two devices on one LAN from colliding |

## The LTE modem

Driven by the **standard `qmi` proto (uqmi)**, with the module prepared first by an init script.
The module has four requirements, and skipping any one produces a symptom that does not name its
cause:

### 1. A warm boot wedges it; a USB re-enumeration resets it

The module is powered independently of the SoC, so a router reboot does not reset it: after a warm
boot it enumerates and `/dev/cdc-wdm0` exists, but QMI answers `Unknown error` or a malformed
message. A USB re-enumeration clears that, and `lte-reset` does it on every boot.

That is the **soft** wedge. There is a harder one - what ModemManager or an unprepared `qmi` proto
leaves behind (*ModemManager is not installed* below) - and it does not answer to the same cure: a
re-enumeration, a `CFUN` cycle and `AT+CFUN=1,1` all fail on it, and only a full power cycle clears
it. The two are easy to confuse, because both show the same symptom: QMI failing while AT answers.

### 2. It can be left at `CFUN=0` (radio off)

`lte-reset` issues `AT+CFUN=1` on every boot.

### 3. Its stored APN is empty, and `AT+CGDCONT` is RAM-only

The always-on default bearer (CID 1) has an **empty** stored APN, and `AT+CGDCONT` is RAM-only on
this module **and consumed by the activation** - so the stored value reads empty again afterwards.
Without a copy in uci, any later re-activation runs against an empty profile, fails with
`Unable to connect IPv4`, and leaves the interface flapping. So `lte-reset` sets the APN over AT
and **writes it into `network.wwan0.apn`** when it differs. The qmi proto passes `--apn` only when
the option exists, which is why the derived value is persisted there - and why the APN is visible
and editable in LuCI.

The APN is **derived from the SIM's MCC/MNC** through `/etc/mr600-apn-table`, so one image works on
any carrier. A value you set in uci overrides the lookup.

### 4. `raw_ip` must be set while `wwan0` is down

`qmi_wwan`'s `raw_ip=Y` is set by `lte-reset`; the driver refuses while the interface is up.

### Bringing it up, and keeping it up

* **`/etc/init.d/lte-reset`** (START=18, before the network) does the four things above.
* **`/etc/hotplug.d/iface/30-lte-apn`** re-attaches the module when uci's APN changes. A live
  bearer keeps the APN it attached with, so a plain restart gives a new PDN with a new address and
  the *old* APN; only a `CFUN` cycle applies a new one, in about 40 s. This is what makes the APN
  field in LuCI do what it looks like it does.
* **The `qmi` proto** brings up `wwan0` and takes a **DHCP lease from the module's own default
  bearer**. The address is *not* configured from QMI's `--get-current-settings` - the module is a
  DHCP server on the bearer.
* **ModemManager is not installed and must stay that way.** It takes `/dev/cdc-wdm0`, and its
  probing drives this module's QMI processor into a state that **only a full power cycle clears**;
  it also costs ~2.4 MB of a 16 MB image. `99-mr600-lte` disables it defensively. SMS goes over
  the AT port instead - see "The SMS app" below - which is also why ModemManager is not needed
  for it.
* `comgt` (the AT/PPP fallback) is likewise not installed - the QMI path is the working one.
* The AT port that answers is **interface 2** (`/dev/ttyUSB2`), not the `ff/42` interface 1, and
  `option` does not list `05c6:9025`, so the init script adds the id at runtime.

## The SMS app

The image carries an SMS / USSD / AT interface in LuCI: `luci-app-sms-tool-js` (a LuCI JS
front-end to `sms_tool`) plus this kit's glue for it, `mr600-sms`. Both are built from
[`packages/`](packages/README.md), which is a **local feed** (`src-link mr600` in `feeds.conf`):
the SMS code is committed in this repository, next to the image config that ships it, so a build
does not depend on a third-party repo still existing - and "which code is in this image?" is
answerable from the image's own commit. `packages/README.md` also has the two commands that check
the vendored app against the upstream commit it came from.

What it does: list and read stored messages, delete one or all, send (GSM-7 and UCS-2, split into
concatenated parts when long), send USSD codes, type raw AT commands, and a dashboard tile with
the operator, signal and a new-SMS count.

What it does **not** do, because these are easy to assume from the screenshots:

* **forwarding on arrival is not in the app.** Its only forwarding target is e-mail, and only for
a message someone picks by hand. The MQTT forwarding below is this kit's, in `mr600-sms`.
* **it does not set `AT+CNMI`, or the storage area's routing.** `sms_tool` exposes neither, so the
app inherits what `/etc/init.d/lte-reset` sets at boot (`AT+CNMI=2,1,0,0,0`, `AT+CPMS="ME"`). If
that line ever disappears, sending keeps working, the inbox keeps listing what is already stored,
and arriving SMS are dropped by the modem with no symptom anywhere. `verify-image.sh` fails the
image if it goes.
* **the new-SMS count is a delta, not read/unread state.** `sms_tool recv` asks for `AT+CMGL=4`
and throws away each entry's `stat` field, so nothing downstream can tell read from unread, or
inbound from sent. The tile compares the storage area's used count now against the count saved
when the inbox was last opened: "messages that arrived since I last looked", not "unread".
* **the recipient picker reads a static file** (`/etc/modem/phonebook.user`), not the SIM's own
phonebook (`AT+CPBR`).
* **opening the inbox writes to flash.** The view persists that saved count with `uci.save()` +
`uci.apply()` on every load, and again after each delete. It is a few KB of overlay per visit; it
was left alone because removing it means forking the app, and the delta above depends on it.

### The MR600 defaults the kit applies

`mr600-sms` ships `/etc/uci-defaults/99-mr600-sms`, which sets only what is wrong on this device.
Each one fails silently if left at the app's own default:

| app option | this kit sets | what the default would do here |
|---|---|---|
| `readport`, `sendport`, `ussdport`, `atport` | `/dev/ttyUSB2` (all four) | empty means `sms_tool` uses its compiled-in `/dev/ttyUSB0`. That device **does exist** on this router - `option` binds the modem's interfaces 0-3 as ttyUSB0-3 - but interface 0 is not the AT port, so the inbox, send, USSD and AT pages all come up empty and say nothing |
| `storage` | `ME` | `SM` is empty here; the modem stores in ME (`lte-reset` sets `CPMS="ME"` for the same reason), so a correct port with the wrong area still reads nothing |
| `mergesms` | `1` | each part of a long message is shown as its own row |
| `ontopsms` | `1` | no dashboard tile, so no new-SMS count at all |
| the call-log daemon | stopped and disabled | it holds `/dev/ttyUSB2` open and polls `AT+CLCC` every ~2 s, fighting `lte-reset` and every `sms_tool` call |

The kit also ships a `defmodems`-free configuration on purpose: with no such config the dashboard
tile runs in SMS-only mode off `readport` and never calls the `md_*` helpers, which come from the
third-party `modemdata` package that this kit deliberately does not install.

### SMS over MQTT

New SMS are published to an MQTT broker by `/usr/sbin/sms-mqtt-poll`, run every 30 s by
`/etc/init.d/sms-mqtt`. **It is off by default and has no broker**: the published image is
for any MR600 v1, and a broker address is site-specific. To switch it on:

```sh
uci set sms_mqtt.main.broker='192.168.2.100'
uci set sms_mqtt.main.topic='mr600/sms'
uci set sms_mqtt.main.enabled='1'
uci commit sms_mqtt
/etc/init.d/sms-mqtt enable && /etc/init.d/sms-mqtt start
```

One message per MQTT message, as JSON:

```json
{ "event": "sms", "device": "/dev/ttyUSB2", "storage": "ME", "index": 7,
  "sender": "+46701234567", "timestamp": "2026-09-30T11:00:00Z", "text": "..." }
```

A segment of a concatenated message adds `part`, `total` and `reference`, so a consumer can join
them; a single-part message has none of the three.

Before enabling it, run it once by hand - one pass, printing what it would publish and changing
nothing (`/etc/config/sms_mqtt` says what every option does):

```sh
/usr/sbin/sms-mqtt-poll -n      # dry run: prints the payloads, publishes nothing
/usr/sbin/sms-mqtt-poll         # one real pass
logread -e sms-mqtt
```

The first real pass records the inbox as its **baseline and publishes none of it**, so installing
this on a modem that already holds messages does not announce all of them as if they had just
arrived. After that, delivery is *at-least-once*: a message is only recorded as announced once
`mosquitto_pub` reported success, so a broker that is down means the next pass retries rather than
drops it, and a read that fails leaves the state file untouched (an empty read must never look
like "everything was deleted and then re-received").

It **polls** rather than listening on the AT port even though `AT+CNMI=2,1` would let it publish at
the instant of arrival: `/dev/ttyUSB2` is shared with `lte-reset` and with every SMS/USSD/AT action
in LuCI, and a process holding it open takes bytes from those and they from it - a failure that
looks like a modem fault. Polling costs up to one interval of latency and keeps the port free
otherwise.

MQTT publishing needs a mosquitto client, which is **not** a dependency of `mr600-sms`: the two
variants (`mosquitto-client-ssl`, `mosquitto-client-nossl`) provide the same binaries and conflict
with each other, so the choice belongs to the image. The local variant seed installs
`mosquitto-client-ssl`; a pass without one says so and exits non-zero rather than looking like a
modem that never receives anything.

## Configuration

`config.seed` is appended before `defconfig` and reproduces the intent: target `ramips/mt7621`,
device `tplink_mr600-v1-eu`, plus `luci`, `luci-proto-qmi`, `sms-tool`, the SMS app and its glue
(`luci-app-sms-tool-js`, `mr600-sms`), and the two radio drivers pinned explicitly (they were once
silently absent when the target resolved wrongly, and the failure is invisible until the device
boots with no WiFi). It is not a byte-copy of any original config.

## Verifying on the device - do not skip this

Set up a TFTP server serving the initramfs as **`test.bin`**, with the server's wired interface at
**192.168.0.5/24** on the router's LAN. U-Boot already expects that:
`ipaddr=192.168.0.1`, `serverip=192.168.0.5`.

At the U-Boot prompt (which is `MT7621 #`):

```
tftpboot 0x82000000 test.bin
bootm 0x82000000
```

**`bootm` takes the plain load address, NOT `+0x200`.** The file carries a 512-byte TP-Link header,
so the uImage magic only appears at offset `0x200` - but this U-Boot adds that offset itself,
doing `addr = addr + TAG_LEN` inside `do_bootm` without parsing the tag. A real boot confirms it:
`bootm 0x82000000` reports `## Booting image at 82000200`. `bootm 0x82000200` would land 512 bytes
past the uImage and fail.

### Two hard rules

* **Never `saveenv`. Never boot-menu option 1.** Stock U-Boot writes its environment block to flash
  `0x20000`, the start of the kernel partition, so either one overwrites the kernel. `printenv` is
  safe.
* **You do not need `saveenv` to override anything for one boot.** `setenv` at the prompt changes
  the environment in RAM only; run `bootm` and it applies, flash untouched.

### The console port

This board's console is **`ttyS0`** in OpenWrt (the stock firmware calls the same physical UART
`ttyS1`). You normally do **not** need to set `bootargs`: U-Boot passes its own, and its defaults
already use `console=ttyS0,115200`. Only if the console is silent should you force it per-boot,
without touching flash:

```
setenv bootargs 'console=ttyS0,115200'
bootm 0x82000000
```

### What to verify while it is running

Nothing is written at this point, so this is free:

1. Does it come up, and does the console work.
2. Ethernet and WiFi.
3. **The LTE modem:** `logread | grep 'lte:'`, then `ifstatus wwan`, `ip -4 addr show wwan0`,
   `ping -c3 8.8.8.8`. It is normal to wait ~25 s; `lte-reset` delays the network on purpose.
4. `/proc/mtd` - does the partition map look right (`boot`, `firmware` at `0x20000`, `romfile`,
   `config`, `filler`, `radio`).
5. Only then `sysupgrade` the sysupgrade image, and reboot into it.

[../INSTALL.md](../INSTALL.md) has the full flash procedure and the recovery path.

## If `build.sh` stops at the configure step

Seeding a **completely empty** `.config` and running `make defconfig` can abort on a recursive
dependency in the feeds (e.g. `PACKAGE_squeezelite-custom` <-> `SQUEEZELITE_WMA_ALAC`). The intent
is still achieved and the resulting `.config` is usable, but `set -e` stops the script because
kconfig exits non-zero after printing the error. Either re-run `./build.sh` (the second pass finds
a fuller `.config` and resolves), or remove the offending feed package. It does not affect the
image.

## bbk - a speed test, built on demand rather than shipped

`make-bbk.sh` cross-compiles Bredbandskollen's CLI (`bbk`) from source with this tree's own
toolchain, verifies the result, and leaves it at `/tmp/bbk`. With `--install` it also copies it to
`$TREE/files/usr/bin/`, so the next image carries it. It is deliberately not part of `build.sh`: it
needs the network to clone the source, and it is a diagnostic rather than something the router
needs to work.

The vendor's prebuilt `mipsel` static-musl binary does **not** run here: the architecture matches
but the float ABI does not. This CPU (MT7621) has no FPU and the kernel is built with
`CONFIG_MIPS_FP_SUPPORT` off, so any hard-float program gets `SIGILL`. `make-bbk.sh` builds
soft-float and **counts coprocessor-1 instructions** to prove it, rather than trusting a label.

```sh
./make-bbk.sh                          # build + verify -> /tmp/bbk
./make-bbk.sh --install                # ... and put it in the next image
scp -O /tmp/bbk root@192.168.1.1:/tmp/bbk
ssh root@192.168.1.1 /tmp/bbk --duration=2
```

The link needs two toolchain details: this gcc's `-static` spec pulls in `-lgcc` but not
`-lgcc_eh`, so `libgcc_eh` must be named explicitly after the objects and inside an archive group;
and 64-bit atomics on 32-bit MIPS need `-latomic`.

## What is still uncertain

* **How the vendor U-Boot sizes the initramfs load.** Upstream U-Boot's `bootm` takes the size from
  the uImage header (`ih_size`), not from a partition size, so an initramfs should not be limited by
  the stock 2 MB kernel slot. This is not exercised: booting an initramfs from flash was never
  tried. It is also moot for the install, which boots the initramfs over TFTP and flashes
  `factory.bin` remotely.
* **`config.seed`** reproduces the intent, not a byte-copy of any particular `.config`; `build.sh`
  appends it to `.config` and runs `make defconfig`.

## What is verified

* **The rootfs split in a raw write.** The PR declares one `firmware` partition at `0x20000` sized
  `0xfa0000`, with `openwrt,offset = <512>` (DTS: `compatible = "openwrt,uimage"`).
  `tplink-v2-image -a 0x10000` aligns the rootfs to the next 64 KiB after the kernel. In the
  released image (16,318,464 B, `0xf90000`), the squashfs magic (`hsqs`) sits at **`0x370000`**
  (3,604,480 B). Writing `factory.bin` in one piece at `0x20000` booted OpenWrt end to end. Do not
  re-use an old two-part split.
