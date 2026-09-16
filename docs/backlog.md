# Backlog

- **Test the SPL serial load.** Until someone does, a write to `mtd0` has no
  known recovery. See [Recovery](architecture.md#recovery).
- **Find why U-Boot ignores serial input.** See
  [Serial input](architecture.md#serial-input).
- **Replace U-Boot with mainline.** It would fix the console and the TFTP
  exposure, but needs a tested SPL recovery first. See
  [Boot-time TFTP exposure](architecture.md#boot-time-tftp-exposure).
- **Remove `HEXLEN` from the flasher.** It is unused. `provision.sh` hard-codes
  the hostname suffix as `tail -c 6`.
