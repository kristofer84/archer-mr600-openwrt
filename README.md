# OpenWrt on the TP-Link Archer MR600 v1 (EU)

Install OpenWrt on a stock Archer MR600 **v1 (EU)** and get the built-in LTE modem working
automatically, without re-deriving anything.

* **[INSTALL.md](INSTALL.md) - start here.** The linear, start-to-finish procedure.
* **[build-kit/](build-kit/)** - build the image from source, or rebuild it reproducibly.
* **[Releases](../../releases)** - prebuilt images, so you can skip the build.

## What you get

An installed, persistent OpenWrt where the internal modem comes up on its own: it is prepared
before the network starts, derives the APN from the SIM, takes a DHCP lease off its own default
bearer, and carries traffic across cold and warm boots. The APN is visible and editable in LuCI.
One image is safe on any MR600 v1 - it keeps the unit's own WiFi calibration.

## What it costs

* **You must open the case.** The UART header is on the back of the PCB, and opening is
  destructive: a screw is hidden under the front silver fin. This is the one physical price.
* **The LTE recipe is verified on one physical unit** (the author's). The install path itself is
  UART + TFTP + `sysupgrade`, which is standard.
* **WiFi as an AP is not fully verified.** The radios load with firmware; the stock OpenWrt
  default leaves the interfaces disabled, so enabling them is a manual step (see INSTALL.md §8).
  The modem uplink is the part that works unattended.

## Deep detail

The build kit's [README](build-kit/README.md) documents the why behind every change it makes to
the upstream port: the writable `radio` partition, the calibration policy, the LTE modem's
preparation and its four requirements, and the guards that catch silent failures. Start there if
a step misbehaves.

## Licence

GPL-2.0 (`LICENSE`). The built image contains OpenWrt and is governed by its own licences. The
vendor `mt_wifi` source is not published by TP-Link, which is why that driver is not included.
