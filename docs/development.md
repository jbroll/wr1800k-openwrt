# Development

## Layout

| Path | Purpose |
|---|---|
| `flash-wr1800k.sh` | The flasher, bash, run with `sudo` |
| `provision.sh` | First-boot `uci-defaults` logic, POSIX sh for BusyBox ash |
| `config-builder.html` | Static page that writes a `creds.json` |
| `creds.json` | Template. Real credentials go in `*.local.json`, which git ignores |
| `psta/` | Submodule of `openwrt-pstad`, copied into `proxy` images |
| `backup/` | Bootloader dumps. `*.bin` is ignored |
| `build/` | Created by the flasher: ImageBuilder, `files/` overlay, `tftproot/`, `initramfs.bin`, `id_flash` key. Ignored |

## The provisioning header

The flasher writes `build/files/etc/uci-defaults/99-provision` as `#!/bin/sh`,
one single-quoted assignment per value (`MODE`, `BACKHAUL`, `ROOT_HASH`,
`PREFIX`, `UPSTREAM_SSID`, `AP_SSID`, `ENC`, `KEY`, `COUNTRY`, `LAN_IPADDR`,
`BACKHAUL_BAND`), a blank line, and `provision.sh` without its shebang.

Single quotes stop the router's shell from expanding a `$` in a hash, key or
SSID, which is also why the flasher rejects quotes, backticks and backslashes
in SSIDs and keys. A new field goes in both the flasher's header and the
variable list at the top of `provision.sh`.

## Testing

There are no automated tests. Check the scripts with `sh -n` and `shellcheck`.
The remaining shellcheck notes are SC2086 on deliberate word splitting of
`uci` paths and `$SSH_OPTS`, and the unused `HEXLEN`.

To inspect an image without a router, run
`./flash-wr1800k.sh creds.local.json build` and look at `build/files/` and the
package list.

On a bench unit:

1. Write a `creds.local.json` in `ap` mode with an `ap_ssid` such as
   `WR1800K-test-{mac}`, so nothing roams onto the unit and two bench units do
   not collide.
2. Cable the NIC straight to a LAN port.
3. Run `sudo ./flash-wr1800k.sh creds.local.json <iface>`. The ImageBuilder in
   `build/` is reused between runs.
4. Check `overlay: ubifs-overlay` in the `RESULT` block.
5. Log in with `ssh -i build/id_flash root@192.168.9.1` and check
   `logread | grep uci-defaults`, `uci show wireless` and `iwinfo`.

`bridge` modes leave the wire after flashing, so check them from the upstream
LAN. Setting `power_off_cmd` and `power_on_cmd` to drive a smart plug makes
repeated flashes hands-off. A serial console shows U-Boot's TFTP attempt,
which separates a wiring or timing problem from a host-side one.

## Releasing

There is no release process. Tag when the flasher's behavior changes.
