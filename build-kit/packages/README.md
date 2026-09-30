# `packages/` - the SMS packages this kit builds

This directory is a **local OpenWrt feed**, wired into `build.sh` as `src-link mr600`. Being a
feed and not a copy step matters: `scripts/feeds` handles the symlinking, the package symbols
resolve like any other package's, and the build log names it (`feed mr600 is local (...)`).

| package | what it is |
|---|---|
| `luci-app-sms-tool-js/` | the SMS/USSD/AT front-end for LuCI. **Vendored verbatim** from an upstream commit - not our code |
| `mr600-sms/` | this kit's own glue: the MR600 defaults for the app, and MQTT forwarding of arriving SMS |

SMS transport itself is not here: `sms-tool` (the `obsy/sms_tool` fork) comes from the packages
feed, pinned in [`../upstream.lock`](../upstream.lock) like every other feed.

## The vendored app

`luci-app-sms-tool-js` is [4IceG/luci-app-sms-tool-js](https://github.com/4IceG/luci-app-sms-tool-js),
a LuCI JS interface over `sms_tool`. It gives the image its inbox, send, USSD, AT-console and
settings pages, plus a dashboard tile. Their licence is the **GPL-3.0** (the kit's own files are
GPL-2.0-only, see [`../../LICENSE`](../../LICENSE)); the built image therefore contains GPL-3.0
software.

It was taken at the commit in `../upstream.lock` (`SMSJS_COMMIT`), which records *why* it is a
vendored copy rather than a feed: a feed entry would make the image depend on a third-party
repository staying reachable and unchanged, and would put the SMS code in a different repository
from the image config that ships it. The cost of that decision is paid here, by keeping the
vendored tree unmodified so it can be compared.

### Is the vendored app unmodified?

Yes, and this is how to check - no output from `diff` means byte-identical. From this directory:

```sh
cd build-kit/packages
git clone --depth 1 https://github.com/4IceG/luci-app-sms-tool-js /tmp/smsjs
git -C /tmp/smsjs fetch --depth 1 origin "$(sed -n 's/^SMSJS_COMMIT=//p' ../upstream.lock)"
git -C /tmp/smsjs checkout FETCH_HEAD
diff -r /tmp/smsjs/luci-app-sms-tool-js luci-app-sms-tool-js
```

Every MR600-specific change lives in `mr600-sms` or in `../files/`, never in this directory, so a
difference here is either an upstream update that was applied on purpose or a mistake.

### Updating it

1. `git clone` upstream, `git log` to a commit worth taking, `diff -r` the two trees and read what
   changed.
2. Replace the directory wholesale (`rm -rf packages/luci-app-sms-tool-js`, copy the new one) -
   do not hand-merge, the point is that this is upstream's tree.
3. Update `SMSJS_COMMIT` in `../upstream.lock`.
4. Recheck the assumptions `mr600-sms` makes, because they are about *this app's* behaviour and a
   new version can move them: the four port option names, `storage`, `mergesms`, `ontopsms`, the
   `sms_tool` invocations, and the status tile's `md_*` calls. `../README.md`, "The SMS app", lists
   each one and what it costs to get wrong.
5. Rebuild and run `../verify-image.sh` - it checks the files are in the rootfs and that the
   defaults this kit applies are still the ones the device needs.

### What it does not do

Worth knowing before it is trusted in the field; each one is also in `../README.md`:

* no automatic forwarding of any kind - its e-mail forwarding is manual, per selected message;
* no `AT+CNMI` or storage routing of its own, so it depends on `/etc/init.d/lte-reset` having set
  them (a silent dependency - arriving SMS are simply dropped if it has not);
* the new-SMS count is a count *delta*, not read/unread state, because `sms_tool recv` discards
  each entry's `stat` field;
* the recipient picker reads a static file, not the SIM phonebook;
* opening the inbox commits uci (a flash write per visit);
* `LUCI_DEPENDS` pulls in `comgt`, which it never calls, and which this device does not use. Left
  as upstream has it, so the vendored tree stays diffable; the cost is small and it is the only
  thing about this package that is knowingly unnecessary.

## `mr600-sms` - the glue

Two jobs, both specific to this device, both in files that are ours:

* `files/etc/uci-defaults/99-mr600-sms` - the MR600 defaults for the app (all four ports on AT port
  `/dev/ttyUSB2`, storage `ME`, `mergesms`, `ontopsms`) and the call-log daemon left stopped and
  disabled, because it would hold the AT port open. Each choice and the silent failure it prevents
  is in that file's header and in the table in `../README.md`.
* `files/usr/sbin/sms-mqtt-poll`, `files/etc/init.d/sms-mqtt`, `files/etc/config/sms_mqtt` - MQTT
  forwarding of arriving SMS, disabled until a broker is configured. The poller is deliberately a
  **single pass** (the service loops it) so it can be run by hand: `/usr/sbin/sms-mqtt-poll -n`.

The polling model, the state file and the at-least-once delivery guarantee are documented at the
top of `sms-mqtt-poll`, and from the outside in `../README.md`, "SMS over MQTT".

`DEPENDS` on `sms-tool`, `ucode`, `ucode-mod-fs` and `ucode-mod-uci` is explicit even though
`luci-base` drags all of them in: the poller should keep working if it is installed on a system
where the app is not. A mosquitto client is deliberately **not** a dependency - see
`../README.md`.
