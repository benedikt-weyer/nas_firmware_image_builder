#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# CM3588 NAS network image installer
#
# Streams a selected local image through SSH to the NAS eMMC. The NAS must be
# booted from SD card; the eMMC is detected from its MMC device type remotely.
###############################################################################

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT_DIR="${OUTPUT_DIR:-$SCRIPT_DIR/output}"
IMAGE_PATH="${IMAGE_PATH:-}"
SSH_REMOTE="${SSH_REMOTE:-}"
LOG_FILE="${LOG_FILE:-}"
CONFIRMATION="INSTALL-IMAGE-ON-EMMC"

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

choose_image() {
  local -a images
  local selected

  shopt -s nullglob
  images=("$OUTPUT_DIR"/*.img "$OUTPUT_DIR"/*.img.zst)
  shopt -u nullglob

  (( ${#images[@]} > 0 )) || die "No .img or .img.zst files found in $OUTPUT_DIR"

  printf 'Select the image to install on eMMC:\n'
  select selected in "${images[@]}" "Cancel"; do
    [[ "$selected" == "Cancel" ]] && die "Cancelled"
    [[ -n "$selected" ]] || {
      printf 'Invalid selection.\n' >&2
      continue
    }
    IMAGE_PATH="$selected"
    return
  done
}

setup_stdout_log() {
  local image_name

  image_name="$(basename -- "$IMAGE_PATH")"
  LOG_FILE="${LOG_FILE:-$OUTPUT_DIR/$image_name.emmc-ssh-install.log}"
  mkdir -p "$(dirname -- "$LOG_FILE")"
  exec > >(tee "$LOG_FILE")
  printf 'Install log: %s\n' "$LOG_FILE"
}

detect_remote_emmc() {
  ssh -T "$SSH_REMOTE" 'sudo -n bash -s' <<'REMOTE_SCRIPT'
set -euo pipefail

for tool in findmnt lsblk sed; do
  command -v "$tool" >/dev/null 2>&1 || {
    printf 'Missing remote tool: %s\n' "$tool" >&2
    exit 1
  }
done

emmc_devices=()
for sys_device in /sys/block/mmcblk*; do
  name="${sys_device##*/}"
  [[ "$name" =~ ^mmcblk[0-9]+$ ]] || continue
  [[ -r "$sys_device/device/type" ]] || continue
  [[ "$(<"$sys_device/device/type")" == "MMC" ]] || continue
  emmc_devices+=("/dev/$name")
done

(( ${#emmc_devices[@]} == 1 )) || {
  printf 'Expected exactly one eMMC device, found: %s\n' "${emmc_devices[*]:-none}" >&2
  exit 1
}

root_source="$(findmnt -n -o SOURCE /)"
root_disk="$(lsblk -npo PKNAME "$root_source")"
target_device="${emmc_devices[0]}"

[[ "$target_device" != "$root_disk" ]] || {
  printf 'Refusing to overwrite the active root disk: %s\n' "$target_device" >&2
  exit 1
}

[[ -z "$(lsblk -nrpo MOUNTPOINT "$target_device" | sed '/^$/d')" ]] || {
  printf 'Refusing to overwrite eMMC with mounted partitions: %s\n' "$target_device" >&2
  exit 1
}

printf '%s\n' "$target_device"
REMOTE_SCRIPT
}

[[ -n "$IMAGE_PATH" ]] || choose_image
[[ -f "$IMAGE_PATH" ]] || die "Image not found: $IMAGE_PATH"

case "$IMAGE_PATH" in
  *.img) image_format="raw" ;;
  *.img.zst) image_format="zstd" ;;
  *) die "Image must end in .img or .img.zst" ;;
esac

[[ -n "$SSH_REMOTE" ]] || read -r -p "SSH destination (for example nas@192.168.1.50): " SSH_REMOTE
[[ -n "$SSH_REMOTE" ]] || die "SSH destination is required"

setup_stdout_log

for tool in dd ssh tee; do
  require_tool "$tool"
done
[[ "$image_format" != "zstd" ]] || require_tool zstd

log "Authorizing remote sudo"
ssh -tt "$SSH_REMOTE" 'sudo -v'

log "Detecting remote eMMC"
TARGET_DEVICE="$(detect_remote_emmc)" || die "Could not safely identify an unmounted eMMC target"
[[ "$TARGET_DEVICE" =~ ^/dev/mmcblk[0-9]+$ ]] || die "Unexpected remote target device: $TARGET_DEVICE"

printf '  SSH destination: %s\n' "$SSH_REMOTE"
printf '  Image:           %s\n' "$IMAGE_PATH"
printf '  Remote eMMC:     %s\n' "$TARGET_DEVICE"

printf '\nWARNING: This permanently erases %s on %s.\n' "$TARGET_DEVICE" "$SSH_REMOTE"
read -r -p "Type $CONFIRMATION to continue: " confirmation
[[ "$confirmation" == "$CONFIRMATION" ]] || die "Confirmation did not match; nothing was written"

log "Streaming image to remote eMMC"
case "$image_format" in
  zstd)
    zstd --decompress --stdout "$IMAGE_PATH" |
      ssh -T "$SSH_REMOTE" "sudo -n dd of=$TARGET_DEVICE bs=16M conv=fsync status=progress"
    ;;
  raw)
    dd if="$IMAGE_PATH" bs=16M status=progress |
      ssh -T "$SSH_REMOTE" "sudo -n dd of=$TARGET_DEVICE bs=16M conv=fsync status=progress"
    ;;
esac

log "Expanding remote eMMC root filesystem"
ssh -T "$SSH_REMOTE" "sudo -n bash -s -- $TARGET_DEVICE" <<'REMOTE_SCRIPT'
set -euo pipefail

target_device="$1"
target_root="${target_device}p2"

for tool in blkid blockdev e2fsck findmnt lsblk partprobe resize2fs sfdisk sync udevadm; do
  command -v "$tool" >/dev/null 2>&1 || {
    printf 'Missing remote tool: %s\n' "$tool" >&2
    exit 1
  }
done

root_source="$(findmnt -n -o SOURCE /)"
root_disk="$(lsblk -npo PKNAME "$root_source")"
[[ "$target_device" != "$root_disk" ]] || {
  printf 'Refusing to resize the active root disk: %s\n' "$target_device" >&2
  exit 1
}

sync
blockdev --flushbufs "$target_device"
partprobe "$target_device"
udevadm settle

[[ -b "$target_root" ]] || {
  printf 'Expected root partition was not found: %s\n' "$target_root" >&2
  exit 1
}
[[ "$(blkid -o value -s TYPE "$target_root")" == "ext4" ]] || {
  printf 'Expected an ext4 root filesystem on %s\n' "$target_root" >&2
  exit 1
}

echo ',+,' | sfdisk -N2 "$target_device"
partprobe "$target_device"
udevadm settle
e2fsck -f -y "$target_root"
resize2fs "$target_root"
sync
lsblk -o NAME,SIZE,TYPE,MOUNTPOINTS "$target_device"
REMOTE_SCRIPT

log "Installation complete"
printf 'Shut down the NAS, remove the SD card, then boot from eMMC.\n'
