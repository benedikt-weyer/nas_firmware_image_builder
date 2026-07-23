#!/usr/bin/env bash
set -euo pipefail

# Clone a running CM3588 NixOS SD card to the onboard eMMC and grow its root.

SOURCE_DISK="/dev/mmcblk1"
TARGET_DISK="/dev/mmcblk0"
TARGET_ROOT_PARTITION="${TARGET_DISK}p2"
CONFIRMATION="COPY-SD-TO-EMMC"

log() {
  printf '\n==> %s\n' "$*"
}

die() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

require_tool() {
  command -v "$1" >/dev/null 2>&1 || die "Missing required tool: $1"
}

if (( EUID != 0 )); then
  exec sudo --preserve-env "$0" "$@"
fi

for tool in blkid blockdev dd e2fsck findmnt lsblk partprobe resize2fs sfdisk sync udevadm; do
  require_tool "$tool"
done

[[ -b "$SOURCE_DISK" ]] || die "SD card not found at $SOURCE_DISK"
[[ -b "$TARGET_DISK" ]] || die "eMMC not found at $TARGET_DISK"

root_source="$(findmnt -n -o SOURCE /)"
root_disk="$(lsblk -npo PKNAME "$root_source")"

[[ "$root_disk" == "$SOURCE_DISK" ]] || die "Root filesystem is on $root_disk, not $SOURCE_DISK"
[[ -z "$(lsblk -nrpo MOUNTPOINT "$TARGET_DISK" | sed '/^$/d')" ]] || die "Unmount every eMMC partition before continuing"

source_size="$(blockdev --getsize64 "$SOURCE_DISK")"
target_size="$(blockdev --getsize64 "$TARGET_DISK")"
(( target_size >= source_size )) || die "eMMC is smaller than the SD card"

log "Source and target"
lsblk -o NAME,SIZE,TYPE,MOUNTPOINTS "$SOURCE_DISK" "$TARGET_DISK"

printf '\nThis permanently erases all data on %s.\n' "$TARGET_DISK"
read -r -p "Type $CONFIRMATION to continue: " confirmation
[[ "$confirmation" == "$CONFIRMATION" ]] || die "Confirmation did not match"

log "Cloning SD card to eMMC"
dd \
  if="$SOURCE_DISK" \
  of="$TARGET_DISK" \
  bs=16M \
  iflag=fullblock \
  conv=fsync \
  status=progress
sync

log "Refreshing the eMMC partition table"
partprobe "$TARGET_DISK"
udevadm settle

[[ -b "$TARGET_ROOT_PARTITION" ]] || die "Expected cloned root partition $TARGET_ROOT_PARTITION was not found"
[[ "$(blkid -o value -s TYPE "$TARGET_ROOT_PARTITION")" == "ext4" ]] || die "Expected an ext4 root filesystem on $TARGET_ROOT_PARTITION"

log "Expanding the eMMC root partition"
echo ',+,' | sfdisk -N2 "$TARGET_DISK"
partprobe "$TARGET_DISK"
udevadm settle

log "Checking and growing the eMMC root filesystem"
e2fsck -f -y "$TARGET_ROOT_PARTITION"
resize2fs "$TARGET_ROOT_PARTITION"
sync

log "Migration complete"
lsblk -o NAME,SIZE,TYPE,MOUNTPOINTS "$TARGET_DISK"
printf '\nShut down, remove the SD card, then boot from eMMC.\n'
