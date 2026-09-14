# CLAUDE.md

Guidance for Claude Code when working in this repository.

## Purpose

An OpenWrt flasher for the Fenvi WR1800K (MT7621AT, `sim_simax1800t` profile).
Two shell scripts do the work; the rest is documentation of the board's stock
U-Boot and its recovery path. This repository is public.

## File map

| Path | Purpose |
|---|---|
| `flash-wr1800k.sh` | Builds the credentialed image, arms TFTP, network-boots, flashes NAND, verifies |
| `provision.sh` | First-boot `uci-defaults` logic; the flasher prepends a header of `creds.json` values |
| `config-builder.html` | Browser form that writes a `creds.json` |
| `creds.json` | Template with placeholder values |
| `psta/` | Submodule (`openwrt-pstad`) holding `pstad` and `pstad.init` for the `proxy` backhaul |
| `backup/` | Where bootloader MTD dumps go; the dumps themselves are gitignored |
| `docs/quickstart.md` | Shortest path to a flashed unit |
| `docs/user-manual.md` | Fields, modes, manual walkthrough, environment overrides |
| `docs/architecture.md` | Host-side mechanics, U-Boot environment findings, TFTP exposure, recovery |
| `docs/development.md` | Layout, bench loop, provisioning header |
| `docs/backlog.md` | Open items |

## Conventions

- Do not number section headings.
- Plain words, no marketing, no filler. Keep exact values, commands and code.
- No em-dashes. Use periods or commas.
- Docs change in the same commit as the code they describe.
- No changelog file; git history is the record.
- `flash-wr1800k.sh` and `provision.sh` must stay functionally paired: the
  header the flasher emits is the variable set `provision.sh` documents at its top.

## Never commit

- `creds.local.json` or any `*.local.json` (real credentials)
- `build/` (ImageBuilder tree, generated images, the flasher's ephemeral SSH key)
- `backup/*.bin` (bootloader dumps from real units; they carry MACs)
- Anything identifying a specific home network: SSIDs, hostnames, lease
  addresses, real MAC addresses.
