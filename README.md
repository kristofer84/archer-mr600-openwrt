# OpenWrt on the TP-Link Archer MR600 v1 (EU)

Instructions for installing OpenWrt on a stock Archer MR600 **v1 (EU)** and getting the built-in LTE modem to work automatically.

* **[INSTALL.md](INSTALL.md)**: the start-to-finish procedure. Requires opening the case.
* **[REMOTE-INSTALL.md](REMOTE-INSTALL.md)**: install over the LAN through the stock firmware's factory daemon, without opening the case. Tested on hardware. Use it only if you can't open the case.
* **[build-kit/](build-kit/)**: build the image from source, or rebuild it reproducibly.
* **[Releases](../../releases)**: prebuilt images, if you'd rather skip the build.

## What it does

After installation, OpenWrt is persistent and the internal modem comes up on its own. It is prepared before the network starts, gets the APN from the SIM, takes a DHCP lease from its default bearer, and carries traffic across cold and warm boots. The APN is visible and editable in LuCI. The same image works on any MR600 v1, since it keeps each unit's own WiFi calibration.

## Limitations

* **The documented install requires opening the case**
  ([annotated UART header](images/archer_mr600_v1_uart.jpg),
  [motherboard](images/archer_mr600_v1_mb.jpg)). The UART header is on the back of the PCB, and opening the case damages it: a screw is hidden under the front silver fin.
  [REMOTE-INSTALL.md](REMOTE-INSTALL.md) avoids this, but depends on the stock firmware's factory daemon.
* **The LTE setup has only been tested on one unit**, the author's. The install path itself (UART, TFTP, `sysupgrade`) is standard.
* **WiFi as an access point is not fully tested.** The radios load their firmware, but the default OpenWrt config leaves the interfaces disabled, so you need to enable them manually (see INSTALL.md §8). Only the modem uplink works without intervention.

## Further detail

The build kit's [README](build-kit/README.md) explains the reasoning behind each change to the upstream port: the writable `radio` partition, the calibration policy, the modem preparation and its four requirements, and the checks that catch silent failures. Start there if a step goes wrong.

## Licence

GPL-2.0 (`LICENSE`). The built image contains OpenWrt and is covered by its own licences. TP-Link does not publish the vendor `mt_wifi` source, so that driver is not included.
