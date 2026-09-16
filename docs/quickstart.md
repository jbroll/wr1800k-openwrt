# Quickstart

## You need

- The WR1800K and its power adapter.
- A Linux host with a wired NIC, cabled straight to a LAN port on the router.
- On the host: `jq openssl curl tar zstd xz tftp-hpa openssh sshpass nc tcpdump
  iptables iproute2`. The flasher checks for most of them at start and stops at
  the first one missing.
- For a `proxy` backhaul: `git submodule update --init`.

A serial adapter is optional. See the
[user manual](user-manual.md#serial-console).

## Write creds.json

Copy `creds.json` to `creds.local.json` and edit it, or fill in
`config-builder.html` in a browser and save the result. The minimum is a login
(`root_password` or `ssh_authorized_keys`), `main_ssid`, and a `wifi_password`
of 8 or more characters.

Use `"mode": "ap"` for a first flash. It is the only mode the flasher can
verify over the wire.

## Isolate the link

During network boot, U-Boot uses a fixed address on `192.168.1.0/24`. On a
segment bridged to a live network of that range, it collides with other hosts
and the transfer fails, and no host-side routing fixes that. Connect the host
directly to the router, or through a switch that goes nowhere else. The link
needs to be isolated only during the flash.

If the host brings up a VPN automatically when its network changes, turn that
off for the flash. A VPN's `192.168.1.0/24` route hides the router, and the
flash fails with `initramfs never network-booted`.

## Flash

```sh
sudo ./flash-wr1800k.sh creds.local.json eth0
```

The flasher downloads the ImageBuilder on first use, builds the image, and
prompts you to unplug the router's power and plug it back in. If the router
boots its old firmware instead, it asks again, up to six times.

## Check the result

In `ap` mode it ends with:

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
mDNS name:        WR1800K-0a1b2c.local   (after deployment: ssh root@WR1800K-0a1b2c.local)
```

`overlay: ubifs-overlay` means the unit booted from NAND. Log in with
`ssh root@192.168.9.1`.

In `bridge` mode the unit joins the upstream network and is not reachable over
the wire. The flasher prints how to find it there. See
[Modes](user-manual.md#modes).
