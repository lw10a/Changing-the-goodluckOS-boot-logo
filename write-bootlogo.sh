#!/usr/bin/env bash
#
# write-bootlogo.sh - replace the boot logo on a goodluckOS SD card
#
# The boot logo (bootlogo.bmp) lives in a hidden FAT16 partition that is NOT
# listed in the MBR, so it never shows up as /dev/sdX3 and file managers can't
# see it. This script finds that partition inside the first 128 MiB of the card,
# loop-mounts it at the right byte offset and swaps the file.
#
# Tested on: R36S clone (GA36-MB v1.1, Allwinner A23) running goodluckOS.
# Use at your own risk. Always double-check the device name.
#
# Usage:   sudo ./write-bootlogo.sh /dev/sdX my_bootlogo.bmp
#          (/dev/sdX = the WHOLE SD card, e.g. /dev/sdb, NOT /dev/sdb1)
#
# Requirements for the BMP: 640x480, 24-bit, uncompressed, exactly 921654 bytes.
# See GUIDE.md for how to create one.

set -euo pipefail

DEV="${1:-}"
BMP="${2:-}"
BACKUP_MB=128
EXPECTED_SIZE=921654

die()  { echo "ERROR: $*" >&2; exit 1; }
info() { echo "==> $*"; }

[ "$(id -u)" -eq 0 ] || die "Run as root (use sudo)."
[ -n "$DEV" ] && [ -n "$BMP" ] || die "Usage: sudo $0 /dev/sdX bootlogo.bmp"
[ -b "$DEV" ] || die "$DEV is not a block device."
[ -f "$BMP" ] || die "$BMP not found."
for t in lsblk dd grep mount umount cmp od; do
  command -v "$t" >/dev/null || die "Missing tool: $t"
done

# --- Validate the target device --------------------------------------------
[ "$(lsblk -ndo TYPE "$DEV")" = "disk" ] \
  || die "$DEV is a partition. Pass the whole disk (e.g. /dev/sdb, not /dev/sdb1)."

if lsblk -nro MOUNTPOINTS "$DEV" | grep -qE '^(/|/boot|/boot/efi)$'; then
  die "$DEV contains your system partitions. Wrong disk?"
fi

# --- Validate the BMP --------------------------------------------------------
u32() { od -An -tu4 -j"$2" -N4 "$1" | tr -d ' '; }
u16() { od -An -tu2 -j"$2" -N2 "$1" | tr -d ' '; }

[ "$(head -c2 "$BMP")" = "BM" ] || die "$BMP is not a BMP file."
W=$(u32 "$BMP" 18); H=$(u32 "$BMP" 22); BPP=$(u16 "$BMP" 28); COMP=$(u32 "$BMP" 30)
SIZE=$(stat -c %s "$BMP")
[ "$W" = 640 ] && [ "$H" = 480 ] || die "Image must be 640x480 (got ${W}x${H})."
[ "$BPP" = 24 ] || die "Image must be 24-bit (got ${BPP}-bit)."
[ "$COMP" = 0 ] || die "Image must be uncompressed BMP."
[ "$SIZE" = "$EXPECTED_SIZE" ] || die "File must be $EXPECTED_SIZE bytes (got $SIZE). See GUIDE.md."
info "BMP looks good: 640x480, 24-bit, $SIZE bytes."

# --- Confirm -----------------------------------------------------------------
echo
lsblk -o NAME,SIZE,RM,TYPE,MODEL,MOUNTPOINTS "$DEV"
echo
if [ "$(lsblk -ndo RM "$DEV")" != "1" ]; then
  echo "WARNING: $DEV is NOT flagged as removable. Make sure it is really your SD card!"
fi
read -r -p "Write the new logo to $DEV ? Type 'yes' to continue: " ANS
[ "$ANS" = "yes" ] || die "Aborted."

# --- Unmount any mounted partitions of the card ------------------------------
for p in $(lsblk -nrpo NAME,MOUNTPOINTS "$DEV" | awk 'NF>1 {print $1}'); do
  info "Unmounting $p"
  umount "$p"
done

# --- Backup the first 128 MiB ------------------------------------------------
STAMP=$(date +%Y%m%d-%H%M%S)
OUTDIR="./bootlogo-backup-$STAMP"
mkdir -p "$OUTDIR"
IMG="$OUTDIR/first${BACKUP_MB}MiB.img"
info "Backing up the first ${BACKUP_MB} MiB of $DEV to $IMG (this can take a while)..."
dd if="$DEV" of="$IMG" bs=1M count="$BACKUP_MB" status=progress

# --- Find the hidden FAT16 partition ------------------------------------------
# "FAT16   " sits at byte 54 of a FAT16 boot sector, which must be sector aligned.
MNT=$(mktemp -d)
cleanup() { mountpoint -q "$MNT" && umount "$MNT" || true; rmdir "$MNT" 2>/dev/null || true; }
trap cleanup EXIT

info "Searching for the hidden FAT16 partition..."
FOUND=""
while IFS= read -r pos; do
  off=$((pos - 54))
  (( off >= 0 && off % 512 == 0 )) || continue
  if mount -o loop,ro,offset="$off" "$IMG" "$MNT" 2>/dev/null; then
    if [ -f "$MNT/bootlogo.bmp" ]; then FOUND=$off; umount "$MNT"; break; fi
    umount "$MNT"
  fi
done < <(grep -obUaP 'FAT16   ' "$IMG" | cut -d: -f1)

[ -n "$FOUND" ] || die "No FAT16 partition containing bootlogo.bmp found. Nothing was written. Backup is in $OUTDIR."
info "Found it at byte offset $FOUND (sector $((FOUND / 512)))."

# --- Swap the logo -------------------------------------------------------------
mount -o loop,offset="$FOUND" "$DEV" "$MNT"
cp "$MNT/bootlogo.bmp" "$OUTDIR/bootlogo.original.bmp"
info "Original logo saved to $OUTDIR/bootlogo.original.bmp"
cp "$BMP" "$MNT/bootlogo.bmp"
sync
if cmp -s "$BMP" "$MNT/bootlogo.bmp"; then
  info "Verified: the logo on the card matches your file."
else
  die "Verification FAILED. Restore from $OUTDIR."
fi
umount "$MNT"
sync

info "Done. Remove the card and boot your console."
info "To restore the stock logo, run: sudo $0 $DEV $OUTDIR/bootlogo.original.bmp"
