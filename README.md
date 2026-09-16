# wr1800k-openwrt

OpenWrt installer for the Fenvi WR1800K, an AX1800 router on a MediaTek
MT7621AT with 256 MB RAM and 128 MB NAND, sold with carrier (CMCC) firmware.
OpenWrt has no `wr1800k` profile, but the board is the SIM AX18T reference
design, and the `sim_simax1800t` profile runs the switch, both radios and the
`factory` partition.

`flash-wr1800k.sh` builds an image with the root login, SSH keys and Wi-Fi
settings included, network-boots OpenWrt through the stock U-Boot's TFTP
recovery, writes the image to NAND, and verifies it. No serial console is
needed. The image can be a standalone router or an extender over a wired,
WDS, relayd or per-client proxy STA backhaul.

```sh
sudo ./flash-wr1800k.sh creds.local.json eth0   # build and flash over the wire
./flash-wr1800k.sh creds.local.json build       # build only
```

## Documentation

- [docs/quickstart.md](docs/quickstart.md): requirements and a first flash.
- [docs/user-manual.md](docs/user-manual.md): `creds.json` fields, modes, flashing by hand, bootloader backups.
- [docs/architecture.md](docs/architecture.md): how the flasher works, U-Boot findings, TFTP exposure, recovery.
- [docs/development.md](docs/development.md): layout, provisioning header, bench testing.
- [docs/backlog.md](docs/backlog.md): open work.

The `proxy` backhaul uses the `psta/` submodule,
[openwrt-pstad](https://github.com/jbroll/openwrt-pstad). Run
`git submodule update --init` after cloning.

MIT licensed. See [LICENSE](LICENSE).
