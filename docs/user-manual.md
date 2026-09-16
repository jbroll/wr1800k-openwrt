# User manual

## The flasher

```sh
sudo ./flash-wr1800k.sh [creds.json] <wired-iface>
./flash-wr1800k.sh [creds.json] build
```

`creds.json` defaults to `./creds.json`. With an interface, the flasher builds
the image, network-boots the router over that NIC, flashes NAND, and verifies.
It prompts for a power cycle, or runs `power_off_cmd` and `power_on_cmd` if
both are set. [architecture.md](architecture.md) describes each step.

With `build`, it stops after building and prints the image path under
`build/`. This needs no root and no router. Use it to rebuild after changing
`provision.sh` or the `psta/` submodule, then install the image with
`sysupgrade` on a running unit or with a full flash.

Keep real credentials in a `*.local.json` file, which git ignores. `build/` is
ignored too. It holds the ImageBuilder, the images, and the flasher's own SSH
key.

## creds.json fields

`config-builder.html` writes this file from a form that shows only the fields a
mode uses and warns about common mistakes.

| Field | Default | Purpose |
|---|---|---|
| `mode` | `ap` | `ap` or `bridge`. See [Modes](#modes) |
| `backhaul` | `relayd` | `bridge` uplink: `relayd`, `proxy`, `wds` or `wired`. See [Modes](#modes) |
| `root_password` | | Root password. `""` disables password login |
| `ssh_authorized_keys` | `[]` | Public keys for root. At least one of these or `root_password` is required |
| `main_ssid` | | In `ap`, the SSID broadcast. With a wireless backhaul, the upstream network to join, and the SSID broadcast unless `ap_ssid` is set. Unused for `wired` |
| `ap_ssid` | | SSID to broadcast, overriding `main_ssid`. `{mac}` expands to the unit's MAC suffix, so `WR1800K-test-{mac}` is unique per unit |
| `wifi_password` | | WPA key, 8 or more characters. Also used to join the upstream network |
| `wifi_encryption` | `sae-mixed` | `sae-mixed` (WPA2/WPA3) or `psk2` (WPA2 only) |
| `backhaul_band` | `5` | Wireless backhaul radio, `5` or `2` GHz. The other radio broadcasts |
| `country` | `US` | Regulatory domain |
| `hostname_prefix` | `WR1800K` | The hostname becomes `<prefix>-<last 3 MAC bytes>` |
| `lan_ipaddr` | `192.168.9.1` | `ap` mode LAN address, away from the common `192.168.1.0/24` |
| `power_off_cmd`, `power_on_cmd` | | Host commands that power the router off and on, such as a smart plug. Environment variables of the same names override them |

SSIDs and keys may not contain `"`, `'`, `` ` `` or a backslash.

## Modes

**ap** is a standalone router on `lan_ipaddr` with its own DHCP server, and
both radios broadcast. Use it on a bench or an isolated network. It is the
only mode the flasher can verify over the recovery wire.

**bridge** is an extender that puts clients on the upstream subnet. The LAN
gets its address from upstream by DHCP, runs no DHCPv4 server, and has router
advertisements and DHCPv6 disabled, so odhcpd does not hand out addresses
from the unit's own ULA prefix. dnsmasq's DNS listener is off as well
(`dhcp.@dnsmasq[0].port='0'`), because clients get their resolver from the
upstream router and a bridge unit sits on the same subnet as every other host,
so its resolver would answer them all. The unit resolves through
`/tmp/resolv.conf.d/resolv.conf.auto`, which `/etc/resolv.conf` is symlinked
to: netifd leaves `/etc/resolv.conf` pointing at `127.0.0.1` when the port
goes to 0, and without the symlink the unit cannot resolve names for `opkg`
or NTP. `backhaul` picks the uplink:

| Backhaul | Uplink | Clients upstream | Hostname lookup from the LAN |
|---|---|---|---|
| `wired` | Ethernet or coax into a LAN port | Own MACs | `<name>.local` |
| `wds` | 4-address station bridged into the LAN. Needs an upstream AP that accepts 4-address frames, which most ISP routers do not | Own MACs | `<name>.local` |
| `relayd` | 3-address station plus relayd | All share the station's MAC | `<name>` through the upstream router's DNS |
| `proxy` | 3-address station plus `pstad`, one station per client, 18 clients at most | Own MACs | `<name>.local` |

With a wireless backhaul, the `backhaul_band` radio joins `main_ssid` and the
other radio broadcasts.

`relayd` works with any upstream AP. `br-lan` has no address, and relayd,
started by `/etc/hotplug.d/iface/99-relayd` when the `wwan` station comes up,
uses the station's DHCP lease. That lease is the unit's only address, where SSH
and LuCI answer. relayd does not forward mDNS, so `<name>.local` resolves only
for clients of that repeater. Elsewhere use the plain hostname, which the
upstream router registers in its DNS.

`proxy` ships `pstad` from the `psta/` submodule instead of relayd, with
`/etc/psta/allow` set to `*`. The
[openwrt-pstad](https://github.com/jbroll/openwrt-pstad) README explains the
trade-off with relayd.

## Environment overrides

| Variable | Default | Effect |
|---|---|---|
| `OPENWRT_VERSION` | `24.10.0` | ImageBuilder and initramfs release |
| `OPENWRT_UBOOT_IP` | `192.168.1.222` | U-Boot's recovery address. The flasher also detects the real one |
| `POWER_OFF_CMD`, `POWER_ON_CMD` | | Override the `creds.json` fields |

## Flashing by hand

Use this when the stock initramfs does not accept passwordless root SSH, or to
watch each step on a serial console. Do it on an isolated wired link.

### Serial console

Use a USB-to-TTL adapter with 3.3 V logic. A 5 V adapter can damage the
MT7621 UART, so check that its TX idles near 3.3 V. Connect GND to GND, adapter
RX to board TX, and adapter TX to board RX. Leave VCC unconnected and power the
router from its own adapter. Settings are 115200 8N1 with no flow control.

The console shows boot output but U-Boot accepts no input. See
[Serial input](architecture.md#serial-input).

### Build the image

```sh
./flash-wr1800k.sh creds.local.json build
VER=24.10.0
curl -O https://downloads.openwrt.org/releases/$VER/targets/ramips/mt7621/openwrt-$VER-ramips-mt7621-sim_simax1800t-initramfs-kernel.bin
```

### Network-boot the initramfs

On the host, with `IF` the wired NIC:

```sh
sudo ip addr add 192.168.1.254/24 dev $IF
mkdir -p /srv/tftp
cp openwrt-$VER-ramips-mt7621-sim_simax1800t-initramfs-kernel.bin /srv/tftp/factory.bin
sudo in.tftpd -L -a 192.168.1.254:69 -s /srv/tftp
```

Allow UDP 69 in on `$IF` if the host has a firewall. Without it, U-Boot prints
`T T T T` and then `Retry count exceeded`. If U-Boot reports
`TFTP error: 'Permission denied'`, serve from a directory `nobody` can read or
pass `-u <user>` to `in.tftpd`.

Power the router on. U-Boot fetches `factory.bin` and boots it, and the console
opens a passwordless root shell.

### Flash NAND

Serve the image to the router from a second subnet on the host:

```sh
sudo ip addr add 192.168.9.2/24 dev $IF
cd build/openwrt-imagebuilder-*/bin/targets/ramips/mt7621
python3 -m http.server 8080 --bind 192.168.9.2
```

On the router's console:

```sh
ip addr add 192.168.9.1/24 dev br-lan
uclient-fetch -O /tmp/fw.bin http://192.168.9.2:8080/openwrt-24.10.0-ramips-mt7621-sim_simax1800t-squashfs-sysupgrade.bin
```

Stop TFTP on the host so the next boot uses NAND:

```sh
sudo pkill in.tftpd
sudo ip addr del 192.168.1.254/24 dev $IF
```

On the router:

```sh
sysupgrade -n /tmp/fw.bin
```

### Verify

After the reboot, on the console:

```sh
grep REVISION /etc/openwrt_release
mount | grep overlay
logread | grep -i uci-defaults
```

An overlay on `ubifs` at `/dev/ubi0_1` means the unit booted from NAND.

## Bootloader backups

`u-boot-env` has no second copy, so an interrupted `fw_setenv` leaves nothing
to fall back on. Back up both bootloader partitions before changing the
environment:

```sh
ssh root@<host> 'dd if=/dev/mtd0 bs=64k' > backup/<mac-suffix>-mtd0-u-boot.bin
ssh root@<host> 'dd if=/dev/mtd1 bs=64k' > backup/<mac-suffix>-mtd1-u-boot-env.bin
```

Check them against `md5sum` of the partitions on the device. Restore the
environment with `mtd write <file> u-boot-env`. Do not write `mtd0` on a unit
without a working serial console.
