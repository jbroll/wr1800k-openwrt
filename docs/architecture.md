# Architecture

## Overview

`flash-wr1800k.sh` installs OpenWrt in two steps:

1. **Build.** The OpenWrt ImageBuilder makes a `sim_simax1800t` sysupgrade
   image. Its overlay holds `/etc/uci-defaults/99-provision`, which is
   `provision.sh` with the `creds.json` values prepended. OpenWrt runs it once
   on first boot and then deletes it. The overlay also carries SSH keys, umdns
   service records, and either the relayd hotplug script or `pstad`, depending
   on the backhaul.
2. **Flash.** The stock U-Boot network-boots the stock OpenWrt initramfs over
   TFTP. The flasher copies the built image to it over SSH and runs
   `sysupgrade`, which writes NAND.

U-Boot is never written.

## Host setup during a flash

U-Boot's recovery uses fixed addresses on `192.168.1.0/24`, which usually
collides with the host's own LAN. The flasher changes the host as follows, and
an `EXIT` trap reverts every change:

- Tells NetworkManager to stop managing the wired NIC, so it does not strip the
  static address.
- Adds `192.168.1.254/32` to the NIC. A `/24` would add a connected route that
  pulls every `192.168.1.x` host onto the wire, including a smart-plug host
  used by `power_off_cmd`.
- Adds `/32` routes on the NIC for the initramfs at `192.168.1.1` and for
  U-Boot's address. They are more specific than any other `192.168.1.0/24`
  route, so replies to the router go over the wire and not over Wi-Fi.
- Inserts an `iptables` rule accepting UDP 69 on the NIC. Everything else the
  flasher sends is host-initiated, so the replies are allowed by the host's
  existing ESTABLISHED rule. Opening the whole interface would expose the host
  if the wire is not isolated.
- Runs `in.tftpd -u <user>` serving `factory.bin`. Without `-u`, tftpd runs
  as `nobody` and cannot enter a `0700` home directory, which U-Boot reports as
  `TFTP error: 'Permission denied'`.

### Finding U-Boot's address

U-Boot's recovery address differs per unit (see below). A background `tcpdump`
waits for the first TFTP read request to `192.168.1.254` and adds a `/32` route
to its source. U-Boot retries every 5 s or so, so a route added mid-retry
completes the transfer. `OPENWRT_UBOOT_IP` (default `192.168.1.222`) gets a
route too.

The flasher watches for the read request instead of ARP. A unit being
reflashed may still run relayd, which answers ARP for the recovery address,
so an ARP request can come from something other than the bootloader.

### RAM boot or NAND boot

U-Boot's TFTP window is short. If the wired link has not come up in time, the
router boots NAND instead. Passwordless root SSH works only on the stock
initramfs, so the flasher uses it to tell the two apart. After a NAND boot it
asks for another power cycle, up to six tries.

### The flash

The initramfs has no `sftp-server`, so the image goes over
`ssh 'cat > /tmp/fw.bin'` and its size is checked. The flasher stops tftpd
first so the reboot after flashing falls through to NAND. `sysupgrade` runs
detached under `setsid`. Otherwise it kills its own SSH session before stage 2
(`ubus "Connection failed"`) and never flashes.

In `ap` mode the unit comes back on `lan_ipaddr` (default `192.168.9.1`), and
the flasher verifies it over SSH with its own key. In `bridge` mode the unit
joins the upstream LAN and cannot be reached over the recovery wire.

## The U-Boot recovery

On every power-up the stock U-Boot runs "Factory Network Boot". It takes an
address on `192.168.1.0/24`, requests `factory.bin` from `192.168.1.254` over
TFTP, and boots whatever it receives in RAM.

Both addresses are compiled into the bootloader. The unit's address is
`192.168.1.124` plus the sum of its six MAC bytes, mod 256. That gave `.217`
on one unit and `.222` on the other. Neither unit's `factory` partition holds
an IP address.

Environment variables, tested on a bench boot with serial attached:

| Variable | Shipped | Effect |
|---|---|---|
| `netmask` | `192.168.1.254` | Honored. The shipped value breaks recovery (see below) |
| `serverip` | factory value | Ignored by `factoryboot` |
| `ipaddr` | factory value | Ignored by `factoryboot` |
| `bootdelay` | `0` | Honored. `3` shows the boot menu |
| `bootmenu_delay` | unset | Honored. Unset gives a 2 s countdown |
| `factory_boot` | `1` | `0` skips network boot and removes it from the menu |
| `bootmenu_0`..`bootmenu_7` | set | Ignored. The menu entries are compiled in |

### The netmask bug

With the shipped netmask, recovery logs `gatewayip needed but not set` and
fails with `ARP Retry count exceeded`, because U-Boot treats a server on its
own subnet as off-link. Fix it on any unit you want to be able to recover:

```sh
fw_setenv netmask 255.255.255.0
```

With that fixed, the same boot transferred the image at 3.5 MiB/s.

### Serial input

Serial output works throughout, and the OpenWrt console accepts input. U-Boot
does not:

- The `bootdelay` countdown ignores every key, including ENTER and CTRL+C.
- The boot menu treats any byte as ENTER and runs the highlighted first entry.

No U-Boot prompt and no menu entry other than the first can be reached. This
fits a `tstc()` that never reports data beside a working `getc()`. The serial
code disassembles to unmodified upstream U-Boot 2018.09, and the control DTB
describes the UART correctly, so the cause is not a vendor lockout. Other
MediaTek boards show the same behavior with no published cause.

A serial harness can echo sent bytes back even with the board off, when host
TX and RX share a node. Echo does not show the board received anything.

## Boot-time TFTP exposure

Any host that answers at `192.168.1.254` while a unit powers up can RAM-boot
its own image on it. There is no signature check. U-Boot brings the switch up
with no VLANs, so every Ethernet port is exposed, WAN included. The bootloader
has no Wi-Fi, so a wireless repeater with nothing plugged into its ports is not
exposed.

An attacker needs a device on the wired LAN, serving an image for this board,
at the moment a unit powers up. A device in that position can already ARP-spoof
the gateway, so the bootloader gives it persistence, not new access.

Mitigations:

- **Put the uplink on an isolated VLAN or port.** Works wherever a managed
  switch already exists.
- **Keep a host of your own on `192.168.1.254`.** A power outage restarts that
  host along with the routers. The router requests TFTP about four seconds
  after power-up, and a Raspberry Pi takes a minute to boot, so the address is
  unclaimed when it matters. Only a device that boots in under a second helps.
- **`fw_setenv factory_boot 0`.** Closes the exposure and removes network boot.
  With no reachable U-Boot prompt, only a booting OS can set it back, so a bad
  flash afterwards cannot be recovered.
- **Replace U-Boot** with mainline (`mt7621_nand_rfb_defconfig` plus the
  mtk-openwrt DDR blob). That would fix the console as well, but it means
  rebuilding the boot path for this board's NAND, DDR and FIT layout, and
  writing `mtd0` with no proven recovery beneath it.

## Recovery

| Failure | Path |
|---|---|
| Bad environment, OS boots | `fw_setenv` from the OpenWrt serial console or SSH |
| Bad config, OS boots | Failsafe: press `f` then ENTER when the console offers it, or hold reset while the LED flashes |
| Bad firmware | Network boot: serve the initramfs as `factory.bin` at `192.168.1.254`, power cycle, `sysupgrade`. Needs `factory_boot=1` and a correct `netmask` |
| U-Boot gone | The SPL asks for a U-Boot image over serial. Untested, and it may share U-Boot's serial input fault |

## Flash layout

| Partition | Contents |
|---|---|
| `mtd0` `u-boot` | Bootloader. Byte-identical on both units examined (md5 `6e87c754a64a372571949e3761ad193c`) |
| `mtd1` `u-boot-env` | Environment, one copy with no redundant second copy |
| `mtd2` `factory` | Radio calibration and MACs |
| `firmware`, `kernel`, `ubi` | OpenWrt kernel, rootfs and overlay |

`factory` is 512 KiB and has the same layout on both units. Everything past
`0x802e` is `0xff`.

| Offset | Contents |
|---|---|
| `0x0000` | MT7915 EEPROM, chip id `0x7915` little-endian |
| `0x0004` | Radio and bootloader MAC |
| `0x8004` | OS MAC, one higher than the radio MAC. The hostname suffix comes from it |
| `0x8028` | A second MAC-shaped value with an unrelated OUI |
