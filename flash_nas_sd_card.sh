#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# CM3588 NAS SD-card image flasher
###############################################################################

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_PATH="$SCRIPT_DIR/$(basename -- "${BASH_SOURCE[0]}")"
OUTPUT_DIR="${OUTPUT_DIR:-$SCRIPT_DIR/output}"
IMAGE_PATH="${IMAGE_PATH:-}"
TARGET_DEVICE="${TARGET_DEVICE:-}"
LOG_FILE="${LOG_FILE:-}"

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

setup_stdout_log() {
  local image_name

  image_name="$(basename -- "$IMAGE_PATH")"
  LOG_FILE="${LOG_FILE:-$OUTPUT_DIR/$image_name.flash.log}"
  mkdir -p "$(dirname -- "$LOG_FILE")"
  exec > >(tee "$LOG_FILE")
  printf 'Flash log: %s\n' "$LOG_FILE"
}

reexec_as_root() {
  local sudo_error

  if command -v sudo >/dev/null 2>&1; then
    sudo_error="$(sudo -n true 2>&1)" || true
    case "$sudo_error" in
      *"must be owned by uid 0 and have the setuid bit set"* | \
      *"effective uid is not 0"*)
        ;;
      *)
        exec sudo --preserve-env env PATH="$PATH" OUTPUT_DIR="$OUTPUT_DIR" \
          IMAGE_PATH="$IMAGE_PATH" TARGET_DEVICE="$TARGET_DEVICE" \
          LOG_FILE="$LOG_FILE" "$SCRIPT_PATH" "$@"
        ;;
    esac
  fi

  if command -v doas >/dev/null 2>&1; then
    exec doas env PATH="$PATH" OUTPUT_DIR="$OUTPUT_DIR" \
      IMAGE_PATH="$IMAGE_PATH" TARGET_DEVICE="$TARGET_DEVICE" \
      LOG_FILE="$LOG_FILE" "$SCRIPT_PATH" "$@"
  fi

  if command -v pkexec >/dev/null 2>&1; then
    exec pkexec env PATH="$PATH" OUTPUT_DIR="$OUTPUT_DIR" \
      IMAGE_PATH="$IMAGE_PATH" TARGET_DEVICE="$TARGET_DEVICE" \
      LOG_FILE="$LOG_FILE" "$SCRIPT_PATH" "$@"
  fi

  die "Root privileges are required, but no working escalation tool was found."
}

choose_image() {
  local -a images
  local selected

  shopt -s nullglob
  images=("$OUTPUT_DIR"/*.img "$OUTPUT_DIR"/*.img.zst)
  shopt -u nullglob

  (( ${#images[@]} > 0 )) || die "No .img or .img.zst files found in $OUTPUT_DIR."

  printf 'Select the image to flash:\n'
  select selected in "${images[@]}" "Cancel"; do
    [[ "$selected" == "Cancel" ]] && die "Cancelled."
    [[ -n "$selected" ]] || {
      printf 'Invalid selection.\n' >&2
      continue
    }
    IMAGE_PATH="$selected"
    return
  done
}

choose_target_device() {
  local -a devices labels
  local device selected root_source root_disk

  root_source="$(findmnt -n -o SOURCE / 2>/dev/null || true)"
  root_disk="$(lsblk -n -o PKNAME "$root_source" 2>/dev/null || true)"

  while read -r device; do
    [[ -n "$device" ]] || continue
    [[ "$device" != "$root_disk" ]] || continue
    devices+=("$device")
    labels+=("$(lsblk -d -n -o PATH,SIZE,MODEL,TRAN "$device" | xargs)")
  done < <(lsblk -d -n -p -o PATH,TYPE,RM | awk '$2 == "disk" && $3 == "1" { print $1 }')

  (( ${#devices[@]} > 0 )) ||
    die "No removable block devices found. Insert the SD card and rerun, or set TARGET_DEVICE explicitly."

  printf 'Select the SD-card device to erase and flash:\n'
  select selected in "${labels[@]}" "Cancel"; do
    [[ "$selected" == "Cancel" ]] && die "Cancelled."
    if [[ "$REPLY" =~ ^[0-9]+$ ]] &&
      (( REPLY >= 1 && REPLY <= ${#devices[@]} )); then
      TARGET_DEVICE="${devices[REPLY - 1]}"
      return
    fi
    {
      printf 'Invalid selection.\n' >&2
      continue
    }
  done
}

[[ -n "$IMAGE_PATH" ]] || choose_image
[[ -f "$IMAGE_PATH" ]] || die "Image not found: $IMAGE_PATH"

[[ -n "$TARGET_DEVICE" ]] || choose_target_device
[[ -b "$TARGET_DEVICE" ]] || die "Target is not a block device: $TARGET_DEVICE"

if [[ "$EUID" -ne 0 ]]; then
  log "Requesting root privileges"
  reexec_as_root "$@"
fi

setup_stdout_log

for tool in blockdev dd findmnt lsblk mountpoint partprobe sha256sum sync tee udevadm umount; do
  require_tool "$tool"
done

case "$IMAGE_PATH" in
  *.img) ;;
  *.img.zst) require_tool zstd ;;
  *) die "IMAGE_PATH must end in .img or .img.zst" ;;
esac

log "Selected flash target"
printf '  Image:  %s\n' "$IMAGE_PATH"
printf '  Device: %s\n' "$TARGET_DEVICE"
lsblk -o NAME,SIZE,MODEL,TRAN,RM,TYPE,MOUNTPOINT "$TARGET_DEVICE"

printf '\nWARNING: All data on %s will be permanently erased.\n' "$TARGET_DEVICE"
read -r -p "Type the exact device path to continue: " confirmation
[[ "$confirmation" == "$TARGET_DEVICE" ]] || die "Confirmation did not match; nothing was written."

log "Unmounting target partitions"
while read -r device mountpoint_path; do
  [[ -n "$mountpoint_path" ]] || continue
  umount "$device"
done < <(lsblk -n -r -p -o PATH,MOUNTPOINT "$TARGET_DEVICE")

blockdev --flushbufs "$TARGET_DEVICE"

log "Flashing image"
case "$IMAGE_PATH" in
  *.img.zst)
    zstd --decompress --stdout "$IMAGE_PATH" |
      dd of="$TARGET_DEVICE" bs=4M conv=fsync status=progress
    ;;
  *)
    dd if="$IMAGE_PATH" of="$TARGET_DEVICE" bs=4M conv=fsync status=progress
    ;;
esac

sync
blockdev --flushbufs "$TARGET_DEVICE"
partprobe "$TARGET_DEVICE"
udevadm settle

log "Flash completed"
lsblk -o NAME,SIZE,MODEL,TRAN,RM,TYPE,MOUNTPOINT "$TARGET_DEVICE"
printf '\nRemove the SD card safely before inserting it into the NAS.\n'
