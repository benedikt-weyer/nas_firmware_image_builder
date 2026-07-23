#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# CM3588 NAS image SSH-key derivation builder
###############################################################################

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_PATH="$SCRIPT_DIR/$(basename -- "${BASH_SOURCE[0]}")"
OUTPUT_DIR="${OUTPUT_DIR:-$SCRIPT_DIR/output}"
WORK_DIR="${WORK_DIR:-$SCRIPT_DIR/work-ssh-key-image}"
SOURCE_IMAGE="${SOURCE_IMAGE:-}"
TARGET_USER="${TARGET_USER:-nas}"
KEY_DIRECTORY="${KEY_DIRECTORY:-$HOME/.ssh}"
LOG_FILE="${LOG_FILE:-$OUTPUT_DIR/cm3588-nas-ssh-key-image.log}"
PUBLIC_KEY="${PUBLIC_KEY:-}"

LOOP_DEVICE=""
ROOT_MOUNT="$WORK_DIR/root"
UDEV_RULE_PATH="/run/udev/rules.d/99-nas-image-builder-loop-devices.rules"

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
  command -v tee >/dev/null 2>&1 || die "Missing required tool: tee"
  mkdir -p "$(dirname -- "$LOG_FILE")"
  exec > >(tee "$LOG_FILE")
  printf 'Build log: %s\n' "$LOG_FILE"
}

disable_loop_automount() {
  mkdir -p "$(dirname -- "$UDEV_RULE_PATH")"
  cat > "$UDEV_RULE_PATH" <<'EOF'
SUBSYSTEM=="block", KERNEL=="loop[0-9]*", ENV{UDISKS_IGNORE}="1", ENV{UDISKS_AUTO}="0"
EOF
  udevadm control --reload-rules
}

enable_loop_automount() {
  rm -f "$UDEV_RULE_PATH"
  udevadm control --reload-rules
}

unmount_image() {
  if mountpoint -q "$ROOT_MOUNT"; then
    umount -R -l "$ROOT_MOUNT" || true
  fi
  if [[ -n "$LOOP_DEVICE" ]]; then
    losetup -d "$LOOP_DEVICE" || true
  fi
  enable_loop_automount || true
}

cleanup() {
  local exit_status=$?

  unmount_image
  exit "$exit_status"
}

trap cleanup EXIT INT TERM

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
          WORK_DIR="$WORK_DIR" SOURCE_IMAGE="$SOURCE_IMAGE" \
          TARGET_USER="$TARGET_USER" KEY_DIRECTORY="$KEY_DIRECTORY" \
          LOG_FILE="$LOG_FILE" PUBLIC_KEY="$PUBLIC_KEY" "$SCRIPT_PATH" "$@"
        ;;
    esac
  fi

  if command -v doas >/dev/null 2>&1; then
    exec doas env PATH="$PATH" OUTPUT_DIR="$OUTPUT_DIR" WORK_DIR="$WORK_DIR" \
      SOURCE_IMAGE="$SOURCE_IMAGE" TARGET_USER="$TARGET_USER" \
      KEY_DIRECTORY="$KEY_DIRECTORY" LOG_FILE="$LOG_FILE" \
      PUBLIC_KEY="$PUBLIC_KEY" "$SCRIPT_PATH" "$@"
  fi

  if command -v pkexec >/dev/null 2>&1; then
    exec pkexec env PATH="$PATH" OUTPUT_DIR="$OUTPUT_DIR" WORK_DIR="$WORK_DIR" \
      SOURCE_IMAGE="$SOURCE_IMAGE" TARGET_USER="$TARGET_USER" \
      KEY_DIRECTORY="$KEY_DIRECTORY" LOG_FILE="$LOG_FILE" \
      PUBLIC_KEY="$PUBLIC_KEY" "$SCRIPT_PATH" "$@"
  fi

  die "Root privileges are required, but no working escalation tool was found."
}

choose_source_image() {
  local -a candidates
  local selected

  shopt -s nullglob
  candidates=("$OUTPUT_DIR"/*.img "$OUTPUT_DIR"/*.img.zst)
  shopt -u nullglob

  (( ${#candidates[@]} > 0 )) ||
    die "No .img or .img.zst files found in $OUTPUT_DIR. Set SOURCE_IMAGE explicitly."

  printf 'Select the source image:\n'
  select selected in "${candidates[@]}" "Cancel"; do
    [[ "$selected" == "Cancel" ]] && die "Cancelled."
    [[ -n "$selected" ]] || {
      printf 'Invalid selection.\n' >&2
      continue
    }
    SOURCE_IMAGE="$selected"
    return
  done
}

choose_public_key() {
  local -a key_files choices
  local selected

  shopt -s nullglob
  key_files=("$KEY_DIRECTORY"/*.pub)
  shopt -u nullglob

  choices=("Enter a public key manually")
  choices+=("${key_files[@]}")
  choices+=("Cancel")

  printf 'Select an SSH public key:\n'
  select selected in "${choices[@]}"; do
    case "$selected" in
      "Enter a public key manually")
        read -r -p "Paste the SSH public key: " PUBLIC_KEY
        ;;
      "Cancel")
        die "Cancelled."
        ;;
      "")
        printf 'Invalid selection.\n' >&2
        continue
        ;;
      *)
        PUBLIC_KEY="$(<"$selected")"
        ;;
    esac

    printf '%s\n' "$PUBLIC_KEY" | ssh-keygen -lf /dev/stdin >/dev/null 2>&1 || {
      printf 'That is not a valid SSH public key.\n' >&2
      continue
    }
    return
  done
}

[[ -n "$SOURCE_IMAGE" ]] || choose_source_image
[[ -f "$SOURCE_IMAGE" ]] || die "Source image not found: $SOURCE_IMAGE"

require_tool ssh-keygen
SOURCE_BASENAME="$(basename -- "$SOURCE_IMAGE")"
case "$SOURCE_BASENAME" in
  *.img.zst) OUTPUT_BASENAME="${SOURCE_BASENAME%.zst}" ;;
  *.img) OUTPUT_BASENAME="$SOURCE_BASENAME" ;;
  *) die "SOURCE_IMAGE must end in .img or .img.zst" ;;
esac
OUTPUT_BASENAME="${OUTPUT_BASENAME%.img}-ssh-key.img"
OUTPUT_IMAGE="$OUTPUT_DIR/$OUTPUT_BASENAME"
OUTPUT_COMPRESSED="$OUTPUT_IMAGE.zst"

[[ -n "$PUBLIC_KEY" ]] || choose_public_key

if [[ "$SOURCE_BASENAME" == *nixos*.img || "$SOURCE_BASENAME" == *nixos*.img.zst ]]; then
  KEY_FILE="$WORK_DIR/authorized-key.pub"
  mkdir -p "$WORK_DIR"
  printf '%s\n' "$PUBLIC_KEY" > "$KEY_FILE"

  # NixOS regenerates authorized_keys from its derivation. Rebuild it with the
  # selected key instead of making an edit that a later system switch removes.
  exec env \
    AUTHORIZED_KEYS_FILE="$KEY_FILE" \
    IMAGE_NAME="${OUTPUT_BASENAME}.zst" \
    OUTPUT_DIR="$OUTPUT_DIR" \
    WORK_DIR="$WORK_DIR/nixos" \
    LOG_FILE="$LOG_FILE" \
    "$SCRIPT_DIR/build_nas_nixos_image.sh"
fi

if [[ "$EUID" -ne 0 ]]; then
  log "Requesting root privileges"
  reexec_as_root "$@"
fi

setup_stdout_log

for tool in cp losetup mount mountpoint sha256sum udevadm umount zstd; do
  require_tool "$tool"
done

mkdir -p "$OUTPUT_DIR" "$WORK_DIR"
[[ "$SOURCE_IMAGE" != "$OUTPUT_IMAGE" ]] || die "Source and output images must differ."

log "Creating SSH-key image derivation"
printf '  Source image: %s\n' "$SOURCE_IMAGE"
printf '  Output image: %s\n' "$OUTPUT_IMAGE"
printf '  Target user:  %s\n' "$TARGET_USER"

rm -f "$OUTPUT_IMAGE" "$OUTPUT_COMPRESSED" "$OUTPUT_IMAGE.SHA256SUMS"
case "$SOURCE_IMAGE" in
  *.zst)
    zstd --decompress --stdout "$SOURCE_IMAGE" > "$OUTPUT_IMAGE"
    ;;
  *)
    cp --reflink=auto --sparse=always "$SOURCE_IMAGE" "$OUTPUT_IMAGE"
    ;;
esac

log "Mounting copied root filesystem"

disable_loop_automount
LOOP_DEVICE="$(losetup --find --show --partscan "$OUTPUT_IMAGE")"
udevadm settle

ROOT_PARTITION="${LOOP_DEVICE}p2"
[[ -b "$ROOT_PARTITION" ]] || die "Root partition did not appear: $ROOT_PARTITION"

mkdir -p "$ROOT_MOUNT"
mount "$ROOT_PARTITION" "$ROOT_MOUNT"

TARGET_ACCOUNT="$(awk -F: -v user_name="$TARGET_USER" \
  '$1 == user_name { print; exit }' "$ROOT_MOUNT/etc/passwd")"
[[ -n "$TARGET_ACCOUNT" ]] || die "User '$TARGET_USER' does not exist in the image."

IFS=: read -r _ _ TARGET_UID TARGET_GID _ TARGET_HOME _ <<< "$TARGET_ACCOUNT"
[[ -d "$ROOT_MOUNT$TARGET_HOME" ]] ||
  die "Home directory does not exist in the image: $TARGET_HOME"

AUTHORIZED_KEYS="$ROOT_MOUNT$TARGET_HOME/.ssh/authorized_keys"
mkdir -p "$ROOT_MOUNT$TARGET_HOME/.ssh"
chmod 0700 "$ROOT_MOUNT$TARGET_HOME/.ssh"
chown "$TARGET_UID:$TARGET_GID" "$ROOT_MOUNT$TARGET_HOME/.ssh"

touch "$AUTHORIZED_KEYS"
chmod 0600 "$AUTHORIZED_KEYS"
chown "$TARGET_UID:$TARGET_GID" "$AUTHORIZED_KEYS"

if grep -Fqx -- "$PUBLIC_KEY" "$AUTHORIZED_KEYS"; then
  log "SSH public key is already authorized"
else
  printf '%s\n' "$PUBLIC_KEY" >> "$AUTHORIZED_KEYS"
  log "SSH public key added"
fi

sync
unmount_image
trap - EXIT INT TERM

log "Compressing and checksumming image"
zstd --force --threads=0 -19 "$OUTPUT_IMAGE" -o "$OUTPUT_COMPRESSED"
(
  cd "$OUTPUT_DIR"
  sha256sum "$OUTPUT_BASENAME" "$(basename -- "$OUTPUT_COMPRESSED")" \
    > "$(basename -- "$OUTPUT_IMAGE").SHA256SUMS"
)

log "SSH-key image derivation completed"
ls -lh "$OUTPUT_IMAGE" "$OUTPUT_COMPRESSED" "$OUTPUT_IMAGE.SHA256SUMS"
