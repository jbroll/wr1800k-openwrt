# Backlog

- **SPL serial load is untested.** The SPL prints "Please transmit a valid
  U-Boot image through this serial console." Whether it can actually receive
  over the UART is unknown, since U-Boot proper never sees input on it. Until
  someone tests it, treat `mtd0` as a write with no recovery beneath it.
- **U-Boot `tstc` root cause unresolved.** The countdown ignores keys and the
  menu treats any byte as ENTER. The serial chain disassembles to unmodified
  upstream 2018.09 with a correct DTB, so the fault is somewhere below that.
  Other MediaTek boards show the same asymmetry with no published explanation.
- **Replacing U-Boot with mainline** (`mt7621_nand_rfb_defconfig` plus the
  mtk-openwrt DDR blob) would fix the console and the TFTP exposure at once.
  Needs a proven SPL recovery path first (see above).
- **`HEXLEN` in the flasher is unused.** The hostname suffix length is
  hard-coded as `tail -c 6` in `provision.sh`.
- **Proxy backhaul limits** (the 18-client association ceiling and its
  workarounds) are tracked in the `openwrt-pstad` repository's backlog, not
  here.
