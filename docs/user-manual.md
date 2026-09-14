# User manual

## The flasher

```sh
sudo ./flash-wr1800k.sh [creds.json] <wired-iface>
```

`creds.json` defaults to `./creds.json`. The wired interface is required and
must be cabled to a LAN port on the router. The script builds the credentialed
image, arms TFTP recovery on the host, power-cycles the router (prompting for a
manual unplug/replug, or running `power_off_cmd`/`power_on_cmd` if configured),
flashes NAND over SSH, and verifies. It prints the device address and hostname.

Keep real credentials in `creds.local.json` (or any `*.local.json`), which is
gitignored. The `build/` tree is gitignored too: it holds the ImageBuilder, the
generated images, and the script's ephemeral SSH key.

## creds.json fields

| Field | Purpose |
|---|---|
| `mode` | `ap` (standalone router, default) or `bridge` (extender onto the upstream subnet). See Modes below. |
| `backhaul` | `bridge` uplink: `relayd` (wireless proxy-ARP, works with any upstream; default), `proxy` (wireless, per-client proxy STA, each client keeps its own MAC upstream, drops relayd), `wds` (wireless 4-address, needs a WDS-capable upstream), or `wired` (Ethernet/coax into a LAN port). |
| `root_password` | Root login password. Optional if `ssh_authorized_keys` is set; leave `""` to disable password login. |
| `ssh_authorized_keys` | Array of public keys added to root's `authorized_keys`. Optional if `root_password` is set. At least one of the two is required. |
| `main_ssid` | In `ap`, the SSID broadcast on both radios. In `bridge` with a wireless backhaul (`relayd`/`wds`/`proxy`), the upstream network to join (and, unless `ap_ssid` is set, the SSID rebroadcast). Not needed for `wired`. |
| `ap_ssid` | Optional. SSID to broadcast; overrides `main_ssid`. A `{mac}` token expands to the unit's MAC suffix (`WR1800K-test-{mac}` gives a unique SSID per unit). Use a distinct SSID for bench testing so nothing roams onto the bench unit; leave `""` to rebroadcast `main_ssid` for deployment. |
| `wifi_password` | WPA key, 8+ characters (also the key used to join the upstream on a wireless backhaul). |
| `wifi_encryption` | `sae-mixed` (WPA2/WPA3) or `psk2` (WPA2-only). Defaults to `sae-mixed`. |
| `backhaul_band` | Wireless backhaul only: `5` or `2` (GHz), which radio joins the upstream; the other rebroadcasts. Defaults to `5`. |
| `country` | Regulatory domain, e.g. `US`. |
| `hostname_prefix` | Hostname/mDNS prefix; the name becomes `<prefix>-<last 3 MAC bytes>`. |
| `lan_ipaddr` | `ap` mode only: LAN address the router comes up on. Defaults to `192.168.9.1`, off the usual `192.168.1.0/24`. In `bridge` the LAN joins the upstream subnet instead. |
| `power_off_cmd`, `power_on_cmd` | Optional host commands to power the router off/on (e.g. a smart plug). If both are set, the flasher power-cycles automatically instead of prompting. Env vars of the same name override creds.json. |

`config-builder.html` fills these in without hand-editing JSON. It shows only
the fields each mode needs, warns on the common mistakes, and downloads a
matching `creds.json`.

## Modes

The first-boot logic lives in `provision.sh`; the flasher bakes the
`creds.json` values into a header above it.

- **ap** (default): a standalone router. LAN on `lan_ipaddr` with its own DHCP,
  both radios broadcasting `main_ssid`/`ap_ssid`. Good for a bench or an
  isolated network, and the only mode the flasher can verify over the recovery
  wire.
- **bridge**: an extender that puts clients on the upstream subnet. `backhaul`
  selects the uplink:
  - **wired**: Ethernet/coax uplink into a LAN port, a true L2 dumb AP. Most
    reliable where a wire reaches.
  - **relayd** (default): a plain 3-address station joins `main_ssid` on the
    `backhaul_band` radio; relayd proxy-ARPs and DHCP-relays between the LAN
    and the station. Works with any upstream AP, including ISP routers such as
    Verizon Fios that do not bridge WDS frames. `br-lan` takes no IP of its
    own; relayd anchors on the station's DHCP lease, so nothing is hand-picked
    and nothing can collide with the upstream pool. The other radio
    rebroadcasts. relayd is launched by an iface hotplug
    (`/etc/hotplug.d/iface/99-relayd`) when the `wwan` station comes up. Manage
    the router through its lease address (see below).
  - **wds**: a 4-address (WDS) station bridged straight into the LAN. Simplest,
    but only works if the upstream AP accepts 4-address frames. Most ISP
    routers, Fios included, do not.
  - **proxy**: a wireless backhaul like relayd, but each client gets its own
    station on the backhaul radio carrying its own MAC, via the per-client
    proxy daemon `pstad`; no relayd is used, and every client keeps its own
    layer-2 identity upstream. One association slot per client, so a repeater
    is capped at 18 clients (measured). The daemon, its init script and its
    documentation live in the `openwrt-pstad` repository, included here as the
    `psta/` submodule (`git submodule update --init`). The allowlist at
    `/etc/psta/allow` defaults to `*`, meaning all clients.

In `bridge` mode the device joins the upstream LAN by DHCP, so it is not
reachable on the isolated recovery wire.

## Reaching the device by name

How the hostname resolves depends on the backhaul:

- **wired**, **wds**, and **proxy** put the device's own MAC on the upstream
  segment, so mDNS works everywhere on the LAN: `ssh root@<prefix>-<mac>.local`.
- **relayd** does not forward multicast, and mDNS runs over multicast, so
  `<prefix>-<mac>.local` only resolves for a client associated to that
  repeater's own AP. From elsewhere on the LAN, use the plain DHCP hostname
  without `.local`: the upstream router registers it in its own DNS, so
  `ssh root@<prefix>-<mac>` resolves to the station's lease address. That lease
  address is the router's only address, and where LuCI and SSH answer.

## Environment overrides

| Variable | Effect |
|---|---|
| `OPENWRT_VERSION` | ImageBuilder and initramfs release to use. Default `24.10.0`. |
| `OPENWRT_UBOOT_IP` | Pin the U-Boot factory-boot IP explicitly instead of auto-discovering it. Default `192.168.1.222`; the flasher sniffs the real one and adds a route for it anyway. |
| `POWER_OFF_CMD`, `POWER_ON_CMD` | Override the `creds.json` fields of the same name. |

## Manual walkthrough

The sections below describe what the script does, and are the reference for
doing it by hand over a serial console.

### What you need

- A USB-to-TTL serial adapter, 3.3 V logic. The MT7621 UART is 3.3 V; a 5 V
  adapter can damage it. Verify the adapter's TX idles at about 3.3 V before
  wiring.
- A wired Ethernet interface on the host.
- Host packages: `openssl`, `tar`, `gzip`, a TFTP server (`tftp-hpa`), and
  Python 3 (for a throwaway HTTP server). The ImageBuilder needs a normal Linux
  build host with `zstd`/`xz`.
- The board opened enough to reach its 4-pin serial header.

### Serial console

Wire three lines only; leave the header's VCC pin unconnected and power the
router from its normal adapter.

| Adapter | Board |
|---|---|
| GND | GND |
| RX | TX |
| TX | RX |

Console settings: 115200 8N1, no flow control. On the host the adapter
appears as `/dev/ttyUSB0`.

The stock environment ships `bootdelay=0`, so `mtkautoboot` runs its default
action before a keypress can land and the console looks dead through boot even
when the wiring is right. From a running OpenWrt:

```sh
fw_setenv bootdelay 3        # time to interrupt autoboot
fw_setenv bootmenu_delay 5   # time to pick a menu entry
```

The menu's entries are already defined in the environment
(`bootmenu_0`...`bootmenu_7`), including "Main system" and "Upgrade firmware".
There are two countdowns, one per variable, and both print "Hit any key to stop
autoboot". Neither accepts input; see the architecture notes on serial input.

### Build a credentialed image

Download and unpack the ImageBuilder for this target (adjust the version as
needed):

```sh
VER=24.10.0
curl -O https://downloads.openwrt.org/releases/$VER/targets/ramips/mt7621/openwrt-imagebuilder-$VER-ramips-mt7621.Linux-x86_64.tar.zst
tar --zstd -xf openwrt-imagebuilder-$VER-ramips-mt7621.Linux-x86_64.tar.zst
cd openwrt-imagebuilder-$VER-ramips-mt7621.Linux-x86_64
```

Create a `files/` overlay with a first-boot provisioning script. It sets the
root password from a precomputed hash, configures both radios, and removes
itself after running.

Precompute the root password hash on the host:

```sh
mkpasswd -m sha-512 'YOUR_ROOT_PASSWORD'      # or: openssl passwd -6 'YOUR_ROOT_PASSWORD'
```

`files/etc/uci-defaults/99-provision`:

```sh
#!/bin/sh
# --- root password (precomputed sha-512 crypt hash) ---
ROOT_HASH='$6$REPLACE_WITH_MKPASSWD_OUTPUT'
sed -i "s#^root:[^:]*:#root:${ROOT_HASH}:#" /etc/shadow

# --- hostname / mDNS name: <prefix>-<last 3 bytes of MAC>, e.g. WR1800K-0a1b2c ---
PREFIX='WR1800K'
MAC=$(tr -d ':' < /sys/class/net/eth0/address)
uci set system.@system[0].hostname="${PREFIX}-$(printf '%s' "$MAC" | tail -c 6)"
uci commit system

# --- Wi-Fi ---
SSID='YOUR_SSID'
KEY='YOUR_WIFI_PASSWORD'          # >= 8 chars
COUNTRY='US'

for dev in $(uci show wireless | sed -n "s/^wireless\.\(radio[0-9]*\)=wifi-device/\1/p"); do
	uci set wireless.$dev.country="$COUNTRY"
	uci set wireless.$dev.disabled='0'
done
for ifc in $(uci show wireless | sed -n "s/^wireless\.\(default_radio[0-9]*\)=wifi-iface/\1/p"); do
	uci set wireless.$ifc.ssid="$SSID"
	uci set wireless.$ifc.encryption='sae-mixed'   # WPA2/WPA3; use 'psk2' for WPA2-only
	uci set wireless.$ifc.key="$KEY"
done
uci commit wireless

exit 0
```

For mDNS discovery, advertise the SSH and HTTP services so the router appears
in Bonjour/avahi browsers as well as answering `<hostname>.local`.
`files/etc/umdns/router.json`:

```json
{
	"router_ssh":  { "service": "_ssh._tcp.local",  "port": 22 },
	"router_http": { "service": "_http._tcp.local", "port": 80 }
}
```

Make the script executable and build, pulling in the mDNS responder, the LuCI
web UI, and (for a repeater) relayd:

```sh
chmod +x files/etc/uci-defaults/99-provision
make image PROFILE=sim_simax1800t FILES=files/ PACKAGES="umdns relayd luci"
```

A `proxy`-backhaul image needs `tc` and its kernel modules instead of relayd,
and the `psta/` overlay: `PACKAGES="umdns luci tc-full kmod-sched-core
kmod-sched-flower ip-bridge"`. `flash-wr1800k.sh` selects that package set and
overlay automatically from `backhaul: "proxy"` in `creds.json`.

The build writes to `bin/targets/ramips/mt7621/`:

- `openwrt-*-sim_simax1800t-squashfs-sysupgrade.bin`, the credentialed image
  that lands on NAND.

For the RAM-boot step, use the stock initramfs (no credentials needed there;
it is transient and gives a passwordless serial shell). Download it once:

```sh
curl -O https://downloads.openwrt.org/releases/$VER/targets/ramips/mt7621/openwrt-$VER-ramips-mt7621-sim_simax1800t-initramfs-kernel.bin
```

### Flash

The stock U-Boot's default boot action is "Factory Network Boot": on every
power-up it takes a per-unit address on `192.168.1.0/24` (for example
`192.168.1.222`), looks for a TFTP server at `192.168.1.254`, downloads
`factory.bin`, and boots it in RAM. Serve the initramfs as `factory.bin` and
it RAM-boots OpenWrt with no keypress or menu timing required. It expects a raw
bootable image; do not wrap or encrypt it.

Host: static recovery IP and TFTP server.

```sh
IF=eth0                                  # the wired NIC connected to the router
sudo ip addr add 192.168.1.254/24 dev $IF
mkdir -p /srv/tftp
cp openwrt-$VER-ramips-mt7621-sim_simax1800t-initramfs-kernel.bin /srv/tftp/factory.bin
sudo in.tftpd -L -a 192.168.1.254:69 -s /srv/tftp
```

If the host runs a firewall, allow traffic on this interface for the duration.

Connect the host NIC to a LAN port on the router, open the serial console
(`115200`), and power on. U-Boot TFTPs `factory.bin` and boots it; the console
lands at a passwordless `root@OpenWrt` shell.

Transfer the credentialed sysupgrade to the device. OpenWrt's default LAN is
`192.168.1.1`, which collides with many home gateways, so use a private link
subnet between host and device. On the host:

```sh
sudo ip addr add 192.168.9.2/24 dev $IF
cd bin/targets/ramips/mt7621
python3 -m http.server 8080 --bind 192.168.9.2
```

On the device (over serial):

```sh
ip addr add 192.168.9.1/24 dev br-lan
uclient-fetch -O /tmp/fw.bin http://192.168.9.2:8080/openwrt-*-sim_simax1800t-squashfs-sysupgrade.bin
```

Stop the network boot from recurring, then flash. Before the device reboots it
must not find a TFTP server, or it will RAM-boot again instead of booting NAND.
On the host:

```sh
sudo pkill in.tftpd
sudo ip addr del 192.168.1.254/24 dev $IF
```

On the device:

```sh
sysupgrade -n /tmp/fw.bin
```

`sysupgrade` writes NAND and reboots. U-Boot's TFTP attempt now fails (no
server) and it falls through to the freshly flashed firmware. The device comes
up with your root password set and Wi-Fi broadcasting.

### Verify

On the serial console after reboot:

```sh
cat /etc/openwrt_release | grep REVISION
mount | grep overlay        # /overlay is ubifs on /dev/ubi0_1  => persistent NAND install
logread | grep -i uci-defaults
```

A `ubifs` overlay on `/dev/ubi0_1` confirms it booted from NAND rather than
RAM.

### Optional: skip the boot-time TFTP wait

U-Boot still runs "Factory Network Boot" on every power-up and waits a few
seconds for a TFTP server before falling through to NAND. To boot NAND
directly, clear the factory flag in the U-Boot environment from the running
OpenWrt. `uboot-envtools` is already in the image and ships a working
`/etc/fw_env.config` (`/dev/mtd1 0x0 0x20000 0x20000`), so nothing needs
creating:

```sh
fw_printenv | grep -i factory        # inspect first
fw_setenv factory_boot 0
```

Tested on one unit and reverted. It does what it promises: the boot goes
straight to `Select Firmware1 to start` with no TFTP attempt, and the only
`Factory:` line left is `using factory mac` during network init. But the flag
does not merely change the default action, it removes "Factory Network Boot"
from the boot menu entirely, leaving seven entries instead of eight. Since no
menu entry can actually be selected (see Recovery in the architecture notes),
clearing the flag gives up network boot with nothing to replace it. The escape
hatch would be a U-Boot prompt to `setenv factory_boot 1`, and that prompt is
unreachable.

Leave `factory_boot=1`. To stop the router soliciting an unsigned image on a
LAN you don't trust, claim `192.168.1.254` on a host you control instead.

### Bootloader backups

`u-boot-env` holds a single copy with no redundant second copy, so an
interrupted `fw_setenv` has nothing to fall back on. Back both partitions up
before touching the environment (see `backup/README.md`):

```sh
ssh root@<host> 'dd if=/dev/mtd0 bs=64k' > backup/<suf>-mtd0-u-boot.bin
ssh root@<host> 'dd if=/dev/mtd1 bs=64k' > backup/<suf>-mtd1-u-boot-env.bin
```

Compare `md5sum` on the device against the local copies before trusting them.
Restore the environment with `mtd write <file> u-boot-env`. Do not write `mtd0`
on a unit without a working serial console.
