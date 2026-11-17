#!/usr/bin/env bash
# Checks that the firmware build produced images the ESP32-C6 ROM can boot:
# an ELF32 RISC-V executable, a bootloader image, and a partition table.
set -euo pipefail

elf="$1"
bootloader="$2"
partition_table="$3"

# Prints $3 bytes of $1 starting at byte offset $2, as a lowercase hex string.
bytes() {
    od -An -tx1 -j "$2" -N "$3" "$1" | tr -d ' \n'
}

[[ $(bytes "$elf" 0 4) == 7f454c46 ]] || { echo "$elf: not an ELF file"; exit 1; }
[[ $(bytes "$elf" 4 1) == 01 ]] || { echo "$elf: not ELF32"; exit 1; }
[[ $(bytes "$elf" 18 2) == f300 ]] || { echo "$elf: not RISC-V"; exit 1; }

[[ $(bytes "$bootloader" 0 1) == e9 ]] || { echo "$bootloader: not an ESP bootloader image"; exit 1; }
[[ $(bytes "$partition_table" 0 2) == aa50 ]] || { echo "$partition_table: not an ESP partition table"; exit 1; }

echo "firmware ok: ELF32 RISC-V executable, ESP bootloader 0xe9, partition table 0xaa50"
