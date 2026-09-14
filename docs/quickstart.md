# Quickstart

## Hardware

- The WR1800K and its own power adapter.
- A wired Ethernet interface on the host (built-in NIC or USB adapter) and a
  cable into one of the router's LAN ports.
- Optional: a USB-to-TTL serial adapter with 3.3 V logic. The automated path
  does not need it; it is for watching the boot or for recovery. The MT7621
  UART is 3.3 V and a 5 V adapter can damage it. See the user manual for wiring.

## Host packages

`jq`, `openssl`, `curl`, `tar`, `zstd`, `in.tftpd` (from `tftp-hpa`), `ssh`,
`ssh-keygen`, `sshpass`, `nc`, `ip`, `tcpdump`. The ImageBuilder needs a normal
Linux build host with `xz` as well. The flasher checks for each and stops at the
first one missing.

## Fill in creds.json

Copy `creds.json` to `creds.local.json` (gitignored) and edit it, or open
`config-builder.html` in a browser: it shows only the fields each mode needs,
warns on the common mistakes (no login set, short Wi-Fi key), and downloads a
matching file. The fields are listed in the [user manual](user-manual.md).

The minimum is one login (`root_password` or `ssh_authorized_keys`), an SSID
and an 8+ character `wifi_password`.

For a first bench flash use `"mode": "ap"`. That is the only mode the flasher
can verify over the recovery wire, and the unit comes up on `lan_ipaddr`
(default `192.168.9.1`) where you can log in and check it.

## Flash on an isolated link

During network-boot the router's U-Boot uses a fixed per-unit IP on
`192.168.1.0/24` and TFTPs over that one interface. Run the flash on a
point-to-point link: the host's wired NIC straight into a LAN port on the
router, or a switch that is not bridged to a live LAN. On a live
`192.168.1.0/24` the U-Boot's fixed IP collides with existing hosts and DHCP and
its brief TFTP is disrupted. That is an L2 conflict no host-side routing can
fix; one unit failed every attempt on a bridged segment and flashed on the first
try once isolated. Only the network-boot minute needs the isolation. A deployed
bridge runs over its backhaul afterwards.

If the host runs a VPN dispatcher keyed on the default route, disable it for
the duration. The flasher churns the routing table and puts a second box on
`192.168.1.1`; a dispatcher that reads "away" from that will bring a VPN up and
its `192.168.1.0/24` route swallows the LAN, including any host that runs
`power_off_cmd`/`power_on_cmd`. The flash then fails at "initramfs never
network-booted" looking like a TFTP problem.

## Run it

```sh
sudo ./flash-wr1800k.sh creds.local.json eth0
```

The flasher downloads the ImageBuilder on first use (into `build/`), builds the
image, sets up the host NIC and TFTP server, and then asks you to power-cycle
the router (or does it itself when `power_off_cmd` and `power_on_cmd` are set).
Unplug the router's power and plug it back in. U-Boot fetches `factory.bin`,
RAM-boots the stock initramfs, and the flasher pushes the credentialed image
and runs `sysupgrade`.

If the wired link does not renegotiate before U-Boot's short TFTP window the
router boots its old firmware instead. The flasher notices (passwordless root
SSH only works on the stock initramfs) and asks for another power-cycle, up to
six tries.

## What success looks like

In `ap` mode the flasher waits for the unit on `lan_ipaddr` and prints:

```
=== RESULT ===
mode:             ap (standalone router)
OpenWrt:          24.10.0-r28427-6df0e3d02a
overlay:          ubifs-overlay
hostname:         WR1800K-0a1b2c
MAC:              02:xx:xx:0a:1b:2c
Wi-Fi ifaces up:  2
umdns:            running
root password set:yes   (SSH key auth: yes)
address (bench):  192.168.9.1
mDNS name:        WR1800K-0a1b2c.local
```

`overlay: ubifs-overlay` is the line that matters: it means the unit booted
from NAND, not from the RAM image.

In `bridge` mode the unit joins the upstream network by DHCP and is not
reachable on the recovery wire, so the flasher prints how to find it on the
upstream LAN and exits. See "Reaching the device by name" in the user manual.

All host-side changes (NetworkManager state, addresses, routes, firewall rule,
TFTP server) are reverted when the script exits.
