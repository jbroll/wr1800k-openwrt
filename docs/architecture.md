# Architecture

## The two halves

The install has two parts:

1. Build a sysupgrade image with the root password and Wi-Fi credentials baked
   in, using the OpenWrt ImageBuilder. `provision.sh` is the first-boot logic;
   the flasher prepends a header of `creds.json` values and installs the result
   as `/etc/uci-defaults/99-provision`, which OpenWrt runs once and deletes.
2. Flash it through the stock U-Boot's network-boot recovery: TFTP a RAM-boot
   image, then `sysupgrade` the credentialed image onto NAND.

The result boots straight into OpenWrt with the credentials already set.

## What the flasher does on the host

All of it is reverted by an `EXIT` trap.

The router's default `192.168.1.1` collides with a typical home LAN, so the
script:

- Takes the wired NIC out of NetworkManager (`nmcli device set <if> managed no`)
  so the static address is not stripped.
- Adds `192.168.1.254/32` to the NIC. A `/32`, not a `/24`: a `/24` would add
  a connected `192.168.1.0/24` route on the wired NIC that steals every
  `192.168.1.x` host (for example the smart-plug host behind `power_off_cmd`)
  away from Wi-Fi.
- Pins `192.168.1.1/32` and the U-Boot IP `/32` as routes on that NIC. These
  are more specific than any existing `192.168.1.0/24` on another interface,
  so the router is always reached over the wire and the TFTP replies do not
  leave over Wi-Fi.
- Inserts one `iptables` rule accepting UDP 69 in on that interface. Only port
  69 is needed: the firmware push and the `nc` probes are host-initiated, so
  their replies ride the host's existing ESTABLISHED rule. Accepting everything
  on the interface would expose the host to the whole segment whenever the wire
  is not the isolated link the flow asks for.
- Starts `in.tftpd -L -u <user> -a 192.168.1.254:69 -s build/tftproot`. The
  `-u` matters: tftpd drops to `nobody` by default, which cannot traverse a
  `0700` home directory, and U-Boot reports that as
  `TFTP error: 'Permission denied'`.

The flashed image comes up on `lan_ipaddr` (default `192.168.9.1`), so the
installed router does not sit on `192.168.1.1` and can share a bench with a
home LAN.

### U-Boot IP auto-discovery

The U-Boot factory-boot IP varies per unit. Rather than requiring it in
config, the flasher runs `tcpdump` on the wired NIC in the background waiting
for the first packet to `192.168.1.254` on UDP 69, takes its source address,
and adds a `/32` route for it. U-Boot retries the read request every ~5 s for
many rounds, so routing it mid-retry completes the transfer.

It keys off the TFTP read request, not ARP. A unit being reflashed still runs
its old relayd (and the upstream router) which proxy-ARPs the recovery address,
so a `who-has .254 tell .1` would be mistaken for the router. The read request
for `factory.bin` is the only packet whose source is unambiguously the
bootloader.

`OPENWRT_UBOOT_IP` remains as an explicit fallback.

### Telling a RAM boot from a NAND boot

The factory-boot TFTP window is short; if the wired link has not renegotiated
in time the router boots NAND instead. Passwordless root SSH works only on the
stock initramfs, so the flasher uses it to tell the two apart and, on a NAND
boot, asks for another power-cycle rather than failing. Six tries.

### The flash itself

The stock initramfs has no `sftp-server`, so the image is streamed over
`ssh 'cat > /tmp/fw.bin'` and its byte count checked. The TFTP server is
killed before `sysupgrade` so the post-flash reboot falls through to NAND.
`sysupgrade` is run under `setsid` and detached, otherwise it kills its own SSH
session before handing off to stage 2 (`ubus "Connection failed"`) and never
flashes.

## The U-Boot environment

The bootloader's compiled-in defaults are `ipaddr=192.168.1.1`,
`serverip=192.168.1.2`, `netmask=255.255.255.0`, `bootdelay=0`. The values in
NAND were written at the factory and differ.

Which ones the recovery actually reads, from a bench boot with serial attached:

| Variable | Effect |
|---|---|
| `netmask` | Honored. Ships as `192.168.1.254`, which is not a netmask. |
| `serverip` | Ignored by `factoryboot`, which uses `192.168.1.254` regardless. Setting it to `.253` changed nothing. |
| `ipaddr` | Ignored by `factoryboot`. |
| `bootdelay` | Honored. `0` as shipped; `3` makes the boot menu reachable. |
| `bootmenu_delay` | Honored. Unset as shipped, giving a 2-second countdown to pick an entry; `5` is workable. |

`factoryboot` reads the `factory` partition (mtd2, NAND offset `0x100000`) for
the MAC, then logs `Factory: using ipaddr <addr>`. The address is computed, not
stored: neither of the two units examined has an IP address in its `factory`
partition in any form.

The bootloader holds `192.168.1.124`, `255.255.255.0` and `192.168.1.254` as
literal strings and derives the device octet as the base plus the sum of the
six MAC bytes mod 256 (`124 + 605%256 = 217` on one unit, `124 + 610%256 = 222`
on the other). All three are compiled in, which is why setting `serverip` in
the environment changes nothing.

So both ends of the recovery transfer are fixed in the bootloader and its MAC,
and nothing in the environment moves them. On a LAN where the boot-time TFTP
matters, claim `192.168.1.254` on a host you control, or set `factory_boot=0`
on a unit whose serial console works.

### The netmask bug

Fix the netmask on any unit you care about recovering:

```sh
fw_setenv netmask 255.255.255.0
```

With the factory value the recovery logs `gatewayip needed but not set` four
times and dies at `ARP Retry count exceeded`, because U-Boot treats a server on
its own subnet as off-link. Corrected, the same boot transfers the image at
3.5 MiB/s.

Other variables the binary knows but the environment does not set: `bootfile`,
`bootfile.firmware`, `bootfile.bootloader` (TFTP filenames for the menu's
upgrade paths), `bootmenu_delay`, `gatewayip`, `autoload`, `loadaddr`,
`ethaddr`.

## Boot-time TFTP exposure

On every power-up the bootloader claims its computed address and broadcasts
for `factory.bin` at `192.168.1.254`, and it will RAM-boot whatever any host
answering there hands it. There is no signature check.

Every ethernet port is live for this, not just the LAN ports. Captured on the
WAN port with the wire moved there:

```
02:xx:xx:xx:xx:xx > ff:ff:ff:ff:ff:ff  ARP Request who-has 192.168.1.254 tell 192.168.1.217
```

U-Boot brings the switch up flat, so putting a wired backhaul on WAN instead
of a LAN port buys nothing. Wireless clients cannot reach it, since the
bootloader has no Wi-Fi, which is why a relayd or proxy repeater with empty
ports is not exposed at all.

### Threat assessment

The attack needs a device already under someone else's control on the wired
LAN, serving a valid image for this board, at the moment a unit powers up.
Anyone with that foothold can already intercept traffic by ARP-spoofing the
gateway, so taking the bootloader buys them persistence rather than access.
Whether that is worth mitigating depends on the network. A wireless-backhaul
repeater with nothing plugged into its ports has no exposure; a wired unit does.

Options and their trade-offs:

- **An isolated VLAN or port-isolated switch port** for the uplink works, and
  is the right answer where a managed switch is already in place. On a flat
  home network it means adding and administering one.
- **Parking `192.168.1.254` on a host you control** loses a race it cannot
  win. A power event reboots that host and the routers together; the router
  reaches TFTP in about four seconds and a Raspberry Pi takes a minute, so the
  address is free exactly when it is solicited. A microcontroller booting in
  under a second would win that race, at the cost of a gadget to maintain.
- **`factory_boot=0`** closes it outright but gives up network boot, and cannot
  be undone without a booting OS (see Recovery). On a unit without a working
  serial console a bad flash is then unrecoverable.
- **Replacing U-Boot** with mainline (`mt7621_nand_rfb_defconfig` plus the
  mtk-openwrt DDR blob) would give a working console and full control of these
  settings. It also means re-establishing the whole boot path on a reference
  config that knows nothing about this board's NAND, DDR timings or OpenWrt's
  FIT layout, with `mtd0` as the one irreversible write and no proven recovery
  beneath it.

## Recovery

Four paths, most to least convenient:

1. **Serial shell**, for anything the OS survives. The console answers after
   boot, and `fw_setenv` from there can undo any environment change, including
   putting `factory_boot` back.
2. **Failsafe**, for a bad config that stops the OS coming up normally. Press
   `f` and enter when the console offers it, or hold reset as the LED flashes.
3. **Network boot**, for bad firmware. Re-serve the initramfs as `factory.bin`
   at `192.168.1.254` and power cycle; it RAM-boots OpenWrt and you can
   `sysupgrade` again. This is the path the flasher drives and the only one
   that needs no serial.
4. **SPL serial load**, if U-Boot itself is gone. The SPL prints "Please
   transmit a valid U-Boot image through this serial console." Untested, and
   doubtful: it needs the bootloader to receive over a UART that does not
   accept input in U-Boot proper. The SPL initializes the port separately, so
   it may or may not share the fault.

The first three all require something on flash to boot. Nothing here recovers
a NAND image too broken to reach a console, except network boot, which is the
reason to leave `factory_boot=1`.

U-Boot is not touched by the flash procedure, so the board stays recoverable.

### Serial input in U-Boot

Setting `bootdelay` non-zero makes the boot menu render, and it lists "Upgrade
firmware" (`mtkupgrade fw`), "Load image", "Main system" and a U-Boot console.

Serial input reaches the board: the OpenWrt console answers after boot and
gives a shell, which is enough to run `fw_setenv`. The bootloader is a
different story, and it splits in two:

- **The `bootdelay` countdown ignores keys entirely.** Nothing stops autoboot,
  by script or by hand, with printable characters, arrow sequences, ENTER or
  CTRL+C.
- **The menu does read keys, but treats any byte as ENTER** and immediately
  runs the highlighted entry. The highlight cannot be moved, so the only
  reachable entry is the first one, and pressing a key only skips the wait.

The net effect is that no menu entry other than the default, and no U-Boot
prompt, can be reached. A working `getc()` beside a `tstc()` that never
reports data fits: the menu blocks on a read, while `abortboot` polls.

None of this is a vendor lockout. The whole chain (`abortboot`, `tstc`,
`ftstc`, `_serial_tstc`, and `serial_mtk`'s `pending` and `probe`)
disassembles to unmodified upstream 2018.09, the UART is initialized with its
FIFO enabled, and U-Boot's own control DTB has the port correct
(`reg-shift = <2>`, 50 MHz clock, `status = "okay"`). Other routers show the
same asymmetry with no published root cause, including a Creality WiFi Box
(MT7688AN) whose U-Boot CLI could not be reached while Linux serial input
worked normally.

Do not bother editing `bootmenu_0`...`bootmenu_7`. They sit in the environment
but the menu ignores them; its entries are string literals compiled into the
bootloader. Relabelling `bootmenu_7` changed nothing on screen.

A serial rig may echo sent bytes back even with the board unpowered, when host
TX and host RX share a node somewhere in the harness. Echo therefore proves
nothing about whether the board heard you; only a response does.

### Host-side traps

Two host-side traps when serving the recovery image, both of which look like
the router's fault:

- A restrictive host firewall drops the read request and U-Boot prints
  `T T T T ...` then `Retry count exceeded`. Allow UDP 69 in on the wired
  interface.
- `in.tftpd` drops to `nobody` and cannot traverse a `0700` directory, which
  U-Boot reports as `TFTP error: 'Permission denied'`. Serve from a
  world-traversable path or pass `-u <user>`.

## Flash layout

`/proc/mtd`:

| Partition | Contents |
|---|---|
| `u-boot` | bootloader (do not write) |
| `u-boot-env` | bootloader environment |
| `factory` | MAC and radio calibration (see below) |
| `firmware` / `kernel` / `ubi` | OpenWrt kernel + rootfs + overlay |

Inside `factory` (512 KiB, identical shape on both units examined, everything
past `0x802e` erased to `0xff`):

| Offset | Contents |
|---|---|
| `0x0000` | mt7915 radio EEPROM, chip id `0x7915` little-endian in the first two bytes |
| `0x0004` | radio and bootloader MAC |
| `0x8004` | OS MAC, one higher than the radio MAC, the one the hostname is built from |
| `0x8028` | a second MAC-shaped value from an unrelated OUI |

No IP addresses, serial number, or configuration. `mtd0` is byte-identical
between the two units (md5 `6e87c754a64a372571949e3761ad193c`), so they run the
same bootloader build and differ only in `factory` and the environment.
