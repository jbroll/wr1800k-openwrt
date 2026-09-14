# Bootloader backups

Raw MTD dumps pulled from a running unit before editing the U-Boot
environment. Named `<mac-suffix>-mtd<n>-<partition>.bin`. The `.bin` files are
gitignored; this directory is where they go, not a copy of them.

| Partition | Size | Contents |
|---|---|---|
| `mtd0` | 0x80000 | `u-boot`, the bootloader itself |
| `mtd1` | 0x80000 | `u-boot-env`, single env copy, no redundant second copy |

`mtd1` has no backup copy on the device, so an interrupted `fw_setenv` leaves
nothing to fall back on. Restore from here with `mtd write <file> u-boot-env`.

Do not write `mtd0` on a unit without a working serial console.
