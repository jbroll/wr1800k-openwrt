# wr1800k-openwrt

OpenWrt installer for the Fenvi WR1800K, an AX1800 Wi-Fi 6 router built on a
MediaTek MT7621AT with 256 MB RAM and 128 MB NAND. It ships with a
carrier-customized (CMCC) firmware. Mainline OpenWrt has no `wr1800k` profile,
but the board is the SIM AX18T reference design and the `sim_simax1800t`
profile runs on it correctly: switch, both radios, and the `factory` partition
all work.

`flash-wr1800k.sh` builds a sysupgrade image with the root login, SSH keys and
Wi-Fi credentials baked in, RAM-boots the stock initramfs through the stock
U-Boot's TFTP recovery, writes the credentialed image to NAND over SSH, and
verifies. No serial console is needed for the automated path.

```sh
sudo ./flash-wr1800k.sh creds.json eth0
```

Requirements: a Linux host with a wired NIC cabled to a LAN port on the router,
plus `jq openssl curl tar zstd tftp-hpa openssh sshpass nc tcpdump iproute2`.

- [docs/quickstart.md](docs/quickstart.md): from an unopened box to a flashed router.
- [docs/user-manual.md](docs/user-manual.md): every `creds.json` field, the modes and backhauls, the manual walkthrough.
- [docs/architecture.md](docs/architecture.md): what the flasher does on the host, the U-Boot findings, the boot-time TFTP exposure, recovery.
- [docs/development.md](docs/development.md): repo layout, bench testing.
- [docs/backlog.md](docs/backlog.md): open questions.

The `proxy` backhaul needs the per-client proxy STA daemon from
[openwrt-pstad](https://github.com/jbroll/openwrt-pstad), included here as the
`psta/` submodule: `git submodule update --init`. That repo explains why a
plain station cannot bridge and how one association per client gets around it.

MIT licensed. See [LICENSE](LICENSE).
