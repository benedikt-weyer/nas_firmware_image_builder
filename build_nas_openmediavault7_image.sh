#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# CM3588 NAS OpenMediaVault 7 image builder
###############################################################################

SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
SCRIPT_PATH="$SCRIPT_DIR/$(basename -- "$0")"
OUTPUT_DIR="${OUTPUT_DIR:-$SCRIPT_DIR/output}"
WORK_DIR="${WORK_DIR:-$SCRIPT_DIR/work-openmediavault7}"

SOURCE_IMAGE="${SOURCE_IMAGE:-$OUTPUT_DIR/cm3588-nas-debian-bookworm.img}"
IMAGE_NAME="${IMAGE_NAME:-cm3588-nas-openmediavault7.img}"
IMAGE_PATH="$OUTPUT_DIR/$IMAGE_NAME"

OMV_ADMIN_USER="${OMV_ADMIN_USER:-nas}"
OMV_REPOSITORY="${OMV_REPOSITORY:-https://packages.openmediavault.org/public}"

LOOP_DEVICE=""
ROOT_MOUNT="$WORK_DIR/root"

log() {
  printf '\n==> %s\n' "$*"
}

die() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

require_tool() {
  command -v "$1" >/dev/null 2>&1 ||
    die "Missing required tool: $1"
}

run_in_target() {
  chroot "$ROOT_MOUNT" /usr/bin/env \
    -i \
    PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    HOME=/root \
    DEBIAN_FRONTEND=noninteractive \
    DEBCONF_NONINTERACTIVE_SEEN=true \
    UCF_FORCE_CONFFOLD=1 \
    NEEDRESTART_MODE=a \
    "$@"
}

ensure_target_group() {
  if ! run_in_target getent group "$1" >/dev/null; then
    run_in_target groupadd --system "$1"
  fi
}

ensure_target_user() {
  if ! run_in_target id "$1" >/dev/null 2>&1; then
    run_in_target useradd \
      --system \
      --no-create-home \
      --gid "$1" \
      --shell /usr/sbin/nologin \
      "$1"
  fi
}

unmount_image() {
  set +e

  rm -f "$ROOT_MOUNT/usr/sbin/policy-rc.d"

  for mount_path in run sys proc dev/pts dev; do
    if mountpoint -q "$ROOT_MOUNT/$mount_path"; then
      umount -R -l "$ROOT_MOUNT/$mount_path"
    fi
  done

  if mountpoint -q "$ROOT_MOUNT"; then
    umount -l "$ROOT_MOUNT"
  fi

  if [[ -n "$LOOP_DEVICE" ]]; then
    losetup -d "$LOOP_DEVICE"
  fi

}

cleanup() {
  local exit_status=$?

  unmount_image
  exit "$exit_status"
}

trap cleanup EXIT INT TERM

reexec_as_root() {
  if command -v sudo >/dev/null 2>&1 && sudo true >/dev/null 2>&1; then
    exec sudo --preserve-env env PATH="$PATH" OUTPUT_DIR="$OUTPUT_DIR" \
      WORK_DIR="$WORK_DIR" SOURCE_IMAGE="$SOURCE_IMAGE" IMAGE_NAME="$IMAGE_NAME" \
      OMV_ADMIN_USER="$OMV_ADMIN_USER" OMV_REPOSITORY="$OMV_REPOSITORY" \
      "$SCRIPT_PATH" "$@"
  fi

  if command -v doas >/dev/null 2>&1; then
    exec doas env PATH="$PATH" OUTPUT_DIR="$OUTPUT_DIR" WORK_DIR="$WORK_DIR" \
      SOURCE_IMAGE="$SOURCE_IMAGE" IMAGE_NAME="$IMAGE_NAME" \
      OMV_ADMIN_USER="$OMV_ADMIN_USER" OMV_REPOSITORY="$OMV_REPOSITORY" \
      "$SCRIPT_PATH" "$@"
  fi

  if command -v pkexec >/dev/null 2>&1; then
    exec pkexec env PATH="$PATH" OUTPUT_DIR="$OUTPUT_DIR" WORK_DIR="$WORK_DIR" \
      SOURCE_IMAGE="$SOURCE_IMAGE" IMAGE_NAME="$IMAGE_NAME" \
      OMV_ADMIN_USER="$OMV_ADMIN_USER" OMV_REPOSITORY="$OMV_REPOSITORY" \
      "$SCRIPT_PATH" "$@"
  fi

  die "Root privileges are required, but no working escalation tool was found. Re-run this script as root."
}

if [[ "$EUID" -ne 0 ]]; then
  log "Requesting root privileges"
  reexec_as_root "$@"
fi

###############################################################################
# Validation and source-image copy
###############################################################################

for tool in \
  chroot \
  cp \
  losetup \
  mount \
  mountpoint \
  partprobe \
  sha256sum \
  systemctl \
  udevadm \
  umount \
  zstd
do
  require_tool "$tool"
done

[[ -f "$SOURCE_IMAGE" ]] ||
  die "Source image not found: $SOURCE_IMAGE"

[[ "$SOURCE_IMAGE" != "$IMAGE_PATH" ]] ||
  die "SOURCE_IMAGE and output image must differ."

mkdir -p "$OUTPUT_DIR" "$WORK_DIR"

log "Copying Debian image"

rm -f \
  "$IMAGE_PATH" \
  "$IMAGE_PATH.zst" \
  "$IMAGE_PATH.SHA256SUMS"

cp --reflink=auto --sparse=always "$SOURCE_IMAGE" "$IMAGE_PATH"

###############################################################################
# Mount the copied root filesystem
###############################################################################

log "Mounting copied root filesystem"

LOOP_DEVICE="$(losetup --find --show --partscan "$IMAGE_PATH")"
partprobe "$LOOP_DEVICE"
udevadm settle

[[ -b "$LOOP_DEVICE"p2 ]] ||
  die "Root partition did not appear: $LOOP_DEVICE"p2

if mountpoint -q "$ROOT_MOUNT"; then
  umount -R -l "$ROOT_MOUNT"
fi

rm -rf "$ROOT_MOUNT"
mkdir -p "$ROOT_MOUNT"
mount "$LOOP_DEVICE"p2 "$ROOT_MOUNT"

mkdir -p \
  "$ROOT_MOUNT/dev/pts" \
  "$ROOT_MOUNT/proc" \
  "$ROOT_MOUNT/sys" \
  "$ROOT_MOUNT/run"

mount --bind /dev "$ROOT_MOUNT/dev"
mount --bind /dev/pts "$ROOT_MOUNT/dev/pts"
mount -t proc proc "$ROOT_MOUNT/proc"
mount -t sysfs sysfs "$ROOT_MOUNT/sys"
mount --bind /run "$ROOT_MOUNT/run"
mount --make-rslave "$ROOT_MOUNT/run"

rm -f "$ROOT_MOUNT/etc/resolv.conf"
cp -L /etc/resolv.conf "$ROOT_MOUNT/etc/resolv.conf"

# QEMU/binfmt needs the target dynamic loader at the ELF interpreter path.
if [[ ! -e "$ROOT_MOUNT/lib/ld-linux-aarch64.so.1" ]] &&
  [[ ! -L "$ROOT_MOUNT/lib/ld-linux-aarch64.so.1" ]]; then
  for loader in \
    /lib/aarch64-linux-gnu/ld-linux-aarch64.so.1 \
    /usr/lib/ld-linux-aarch64.so.1 \
    /usr/lib/aarch64-linux-gnu/ld-linux-aarch64.so.1
  do
    if [[ -e "$ROOT_MOUNT$loader" ]] || [[ -L "$ROOT_MOUNT$loader" ]]; then
      ln -s "$loader" "$ROOT_MOUNT/lib/ld-linux-aarch64.so.1"
      break
    fi
  done
fi

[[ -e "$ROOT_MOUNT/lib/ld-linux-aarch64.so.1" ]] ||
  [[ -L "$ROOT_MOUNT/lib/ld-linux-aarch64.so.1" ]] ||
  die "The source image is missing the ARM64 dynamic loader."

###############################################################################
# Install OpenMediaVault
###############################################################################

log "Installing OpenMediaVault 7"

for group in \
  staff \
  ssl-cert \
  statd \
  www-data \
  sambashare \
  postfix \
  postdrop \
  chrony
do
  ensure_target_group "$group"
done

ensure_target_user www-data

cat > "$ROOT_MOUNT/usr/sbin/policy-rc.d" <<'EOF'
#!/bin/sh
exit 101
EOF
chmod 0755 "$ROOT_MOUNT/usr/sbin/policy-rc.d"

run_in_target apt-get update
run_in_target apt-get install --yes systemd-resolved psmisc gnupg wget

run_in_target sh -c \
  "wget -qO- '$OMV_REPOSITORY/archive.key' |
    gpg --dearmor --yes \
      -o /usr/share/keyrings/openmediavault-archive-keyring.gpg"

cat > "$ROOT_MOUNT/etc/apt/sources.list.d/openmediavault.list" <<EOF
deb [signed-by=/usr/share/keyrings/openmediavault-archive-keyring.gpg] $OMV_REPOSITORY sandworm main
EOF

run_in_target env \
  LANG=C.UTF-8 \
  APT_LISTCHANGES_FRONTEND=none \
  apt-get update

run_in_target env \
  LANG=C.UTF-8 \
  APT_LISTCHANGES_FRONTEND=none \
  apt-get \
    --yes \
    --no-install-recommends \
    --option DPkg::Options::=--force-confdef \
    --option DPkg::Options::=--force-confold \
    install openmediavault

run_in_target omv-confdbadm populate
run_in_target omv-salt deploy run systemd-networkd

run_in_target id "$OMV_ADMIN_USER" >/dev/null ||
  die "OpenMediaVault administrator user does not exist: $OMV_ADMIN_USER"

run_in_target usermod -aG _ssh "$OMV_ADMIN_USER"

rm -f "$ROOT_MOUNT/usr/sbin/policy-rc.d"
systemctl --root="$ROOT_MOUNT" enable systemd-resolved.service

###############################################################################
# Clean, compress, and checksum
###############################################################################

log "Cleaning and compressing image"

rm -f \
  "$ROOT_MOUNT/var/cache/apt/archives/"*.deb \
  "$ROOT_MOUNT/var/cache/apt/pkgcache.bin" \
  "$ROOT_MOUNT/var/cache/apt/srcpkgcache.bin"

rm -rf \
  "$ROOT_MOUNT/var/lib/apt/lists/"* \
  "$ROOT_MOUNT/tmp/"* \
  "$ROOT_MOUNT/var/tmp/"*

rm -f "$ROOT_MOUNT/etc/resolv.conf"
ln -s ../run/systemd/resolve/stub-resolv.conf \
  "$ROOT_MOUNT/etc/resolv.conf"

sync
unmount_image
trap - EXIT INT TERM

zstd --force --threads=0 -19 "$IMAGE_PATH" -o "$IMAGE_PATH.zst"

(
  cd "$OUTPUT_DIR"
  sha256sum "$IMAGE_NAME" "$IMAGE_NAME.zst" > "$IMAGE_NAME.SHA256SUMS"
)

log "OpenMediaVault 7 image completed"

ls -lh \
  "$IMAGE_PATH" \
  "$IMAGE_PATH.zst" \
  "$IMAGE_PATH.SHA256SUMS"

printf '\nWeb UI: http://<device-ip>/\n'
printf 'OMV login: admin / openmediavault\n'
