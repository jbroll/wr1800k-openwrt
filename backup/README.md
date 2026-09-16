# Bootloader backups

MTD dumps taken from a unit before changing its U-Boot environment, named
`<mac-suffix>-mtd<n>-<partition>.bin`. Git ignores the `.bin` files.

| File | Size | Partition |
|---|---|---|
| `*-mtd0-u-boot.bin` | 0x80000 | The bootloader |
| `*-mtd1-u-boot-env.bin` | 0x80000 | The environment |

How to take and restore them is in
[docs/user-manual.md](../docs/user-manual.md#bootloader-backups).
