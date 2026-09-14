# Development

## Repo layout

| Path | Purpose |
|---|---|
| `flash-wr1800k.sh` | The flasher. Bash; runs as root or via `sudo`. |
| `provision.sh` | First-boot `uci-defaults` logic, POSIX sh (runs on the router under BusyBox ash). |
| `config-builder.html` | Static page, no dependencies, that produces a `creds.json`. |
| `creds.json` | Template. Real credentials go in `*.local.json`, which is gitignored. |
| `psta/` | Git submodule of `openwrt-pstad`. Provides `psta/pstad` and `psta/pstad.init`, which the flasher copies into the image for the `proxy` backhaul. `git submodule update --init` after cloning. |
| `backup/` | Bootloader MTD dumps from units you own. `*.bin` is gitignored. |
| `build/` | Created by the flasher: ImageBuilder tree, `tftproot/`, `files/` overlay, `initramfs.bin`, the ephemeral `id_flash` key. Gitignored. |
| `docs/` | This documentation. |

## The provisioning header

The flasher does not template `provision.sh`. It writes
`build/files/etc/uci-defaults/99-provision` as:

1. `#!/bin/sh`
2. One single-quoted assignment per value: `MODE`, `BACKHAUL`, `ROOT_HASH`,
   `PREFIX`, `UPSTREAM_SSID`, `AP_SSID`, `ENC`, `KEY`, `COUNTRY`, `LAN_IPADDR`,
   `BACKHAUL_BAND`.
3. A blank line.
4. `provision.sh` with its shebang line stripped.

Single quotes keep a `$` in a password hash, key or SSID from expanding on the
device. The flasher refuses an SSID or key containing `"`, `'`, `` ` `` or a
backslash for the same reason. If you add a field, add it to the header list in
the flasher and to the variable comment block at the top of `provision.sh`.

## Testing

There are no automated tests. The scripts are checked with `sh -n` and
`shellcheck`; shellcheck reports a handful of SC2086 unquoted-variable notes on
`uci` paths and `$SSH_OPTS` (deliberate word splitting) and one unused
variable. Testing is a bench loop against a real unit.

The bench loop:

1. Make a `creds.local.json` in `ap` mode. Give `ap_ssid` a bench-only value
   with the `{mac}` token, for example `WR1800K-test-{mac}`, so the unit
   broadcasts a unique SSID that nothing in the room will roam onto, and so two
   bench units do not collide.
2. Cable the wired NIC straight into a LAN port. No switch shared with a live
   `192.168.1.0/24`.
3. `sudo ./flash-wr1800k.sh creds.local.json <iface>`. The ImageBuilder is
   downloaded once into `build/` and reused. `./flash-wr1800k.sh
   creds.local.json build` runs only the build step, for checking the overlay
   under `build/files/` and the package manifest without touching a unit.
4. Read the `RESULT` block. `overlay: ubifs-overlay` means NAND; anything else
   means the unit is still on the RAM image or the previous firmware.
5. Log in on `lan_ipaddr` with the flasher's key (`ssh -i build/id_flash
   root@192.168.9.1`) or the configured password, and check `logread | grep
   uci-defaults`, `uci show wireless`, `iwinfo`.

For `bridge` modes the unit leaves the recovery wire after flashing, so verify
from the upstream LAN instead. A `power_off_cmd`/`power_on_cmd` pair driving a
smart plug removes the one manual step and makes repeated flashes hands-off.

A serial console at 115200 8N1 shows the U-Boot TFTP attempt and is the
fastest way to tell a wiring or timing problem from a host-side one. See the
user manual for the header pinout.

## Releasing

There is no release process. Tag when the flasher changes behavior. Update the
documentation in the same commit as the code.
