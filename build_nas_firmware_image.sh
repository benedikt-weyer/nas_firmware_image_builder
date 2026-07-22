#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# CM3588 NAS bootable SD-card image builder
#
# Consumes:
#   ../nas_uboot_builder/output/u-boot-rockchip.bin
#   ../nas_kernel_builder/kernel-output/boot/Image
#   ../nas_kernel_builder/kernel-output/boot/dtbs/rockchip/
#       rk3588-friendlyelec-cm3588-nas.dtb
#   ../nas_kernel_builder/kernel-output/modules-*.tar.zst
#
# Produces:
#   output/cm3588-nas-debian-bookworm.img
#   output/cm3588-nas-debian-bookworm.img.zst
#   output/SHA256SUMS
#
# The resulting image contains:
#   - mainline U-Boot at offset 32 KiB
#   - GPT partition table
#   - ext4 boot partition
#   - Debian Bookworm ARM64 root filesystem
#   - mainline kernel, DTB and matching modules
###############################################################################

###############################################################################
# Paths and configurable values
###############################################################################

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"

UBOOT_OUTPUT_DIR="${UBOOT_OUTPUT_DIR:-$PROJECT_DIR/nas_uboot_builder/output}"
KERNEL_OUTPUT_DIR="${KERNEL_OUTPUT_DIR:-$PROJECT_DIR/nas_kernel_builder/kernel-output}"

OUTPUT_DIR="${OUTPUT_DIR:-$SCRIPT_DIR/output}"
WORK_DIR="${WORK_DIR:-$SCRIPT_DIR/work}"

IMAGE_NAME="${IMAGE_NAME:-cm3588-nas-debian-bookworm.img}"
IMAGE_PATH="$OUTPUT_DIR/$IMAGE_NAME"

UBOOT_IMAGE="${UBOOT_IMAGE:-$UBOOT_OUTPUT_DIR/u-boot-rockchip.bin}"
KERNEL_IMAGE="${KERNEL_IMAGE:-$KERNEL_OUTPUT_DIR/boot/Image}"

DTB_NAME="rk3588-friendlyelec-cm3588-nas.dtb"
DTB_IMAGE="${DTB_IMAGE:-$KERNEL_OUTPUT_DIR/boot/dtbs/rockchip/$DTB_NAME}"

DEBIAN_SUITE="${DEBIAN_SUITE:-bookworm}"
DEBIAN_MIRROR="${DEBIAN_MIRROR:-https://deb.debian.org/debian}"
DEBIAN_ARCH="${DEBIAN_ARCH:-arm64}"

IMAGE_SIZE="${IMAGE_SIZE:-4G}"
BOOT_SIZE="${BOOT_SIZE:-512M}"

HOSTNAME="${HOSTNAME:-nvme-nas}"
DEFAULT_USER="${DEFAULT_USER:-nas}"

# This password is intentionally temporary and must be changed at first login.
INITIAL_PASSWORD="${INITIAL_PASSWORD:-changeme}"

# Optional public key file. Example:
# AUTHORIZED_KEYS_FILE="$HOME/.ssh/id_ed25519.pub" ./build_nas_image.sh
AUTHORIZED_KEYS_FILE="${AUTHORIZED_KEYS_FILE:-}"

TIMEZONE="${TIMEZONE:-Europe/Berlin}"
LOCALE="${LOCALE:-en_US.UTF-8}"

SERIAL_CONSOLE="${SERIAL_CONSOLE:-ttyS2,1500000}"
KERNEL_EXTRA_ARGS="${KERNEL_EXTRA_ARGS:-}"

# Partition 1 begins at sector 32768 = 16 MiB.
# This leaves room for U-Boot, which starts at sector 64 = 32 KiB.
BOOT_START_SECTOR=32768
UBOOT_START_SECTOR=64
SECTOR_SIZE=512

###############################################################################
# Runtime state used by cleanup
###############################################################################

LOOP_DEVICE=""
BOOT_MOUNT=""
ROOT_MOUNT=""

MOUNTED_DEV=false
MOUNTED_DEV_PTS=false
MOUNTED_PROC=false
MOUNTED_SYS=false
MOUNTED_RUN=false
MOUNTED_BOOT=false
MOUNTED_ROOT=false

###############################################################################
# Helpers
###############################################################################

log() {
  printf '\n==> %s\n' "$*"
}

warn() {
  printf 'Warning: %s\n' "$*" >&2
}

die() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

require_tool() {
  command -v "$1" >/dev/null 2>&1 ||
    die "Missing required tool: $1"
}

require_file() {
  [[ -f "$1" ]] ||
    die "Required file not found: $1"
}

show_setting() {
  printf '  %-24s %s\n' "$1" "$2"
}

cleanup() {
  local exit_status=$?

  set +e

  if [[ "$MOUNTED_RUN" == true ]]; then
    umount -R "$ROOT_MOUNT/run" 2>/dev/null || true
  fi

  if [[ "$MOUNTED_SYS" == true ]]; then
    umount -R "$ROOT_MOUNT/sys" 2>/dev/null || true
  fi

  if [[ "$MOUNTED_PROC" == true ]]; then
    umount -R "$ROOT_MOUNT/proc" 2>/dev/null || true
  fi

  if [[ "$MOUNTED_DEV_PTS" == true ]]; then
    umount -R "$ROOT_MOUNT/dev/pts" 2>/dev/null || true
  fi

  if [[ "$MOUNTED_DEV" == true ]]; then
    umount -R "$ROOT_MOUNT/dev" 2>/dev/null || true
  fi

  if [[ "$MOUNTED_BOOT" == true ]]; then
    umount "$BOOT_MOUNT" 2>/dev/null || true
  fi

  if [[ "$MOUNTED_ROOT" == true ]]; then
    umount "$ROOT_MOUNT" 2>/dev/null || true
  fi

  if [[ -n "$LOOP_DEVICE" ]]; then
    losetup -d "$LOOP_DEVICE" 2>/dev/null || true
  fi

  exit "$exit_status"
}

trap cleanup EXIT INT TERM

###############################################################################
# Privilege handling
###############################################################################

if [[ "$EUID" -ne 0 ]]; then
  log "Requesting root privileges"

  exec sudo --preserve-env \
    env \
      PATH="$PATH" \
      UBOOT_OUTPUT_DIR="$UBOOT_OUTPUT_DIR" \
      KERNEL_OUTPUT_DIR="$KERNEL_OUTPUT_DIR" \
      OUTPUT_DIR="$OUTPUT_DIR" \
      WORK_DIR="$WORK_DIR" \
      IMAGE_NAME="$IMAGE_NAME" \
      UBOOT_IMAGE="$UBOOT_IMAGE" \
      KERNEL_IMAGE="$KERNEL_IMAGE" \
      DTB_IMAGE="$DTB_IMAGE" \
      DEBIAN_SUITE="$DEBIAN_SUITE" \
      DEBIAN_MIRROR="$DEBIAN_MIRROR" \
      DEBIAN_ARCH="$DEBIAN_ARCH" \
      IMAGE_SIZE="$IMAGE_SIZE" \
      BOOT_SIZE="$BOOT_SIZE" \
      HOSTNAME="$HOSTNAME" \
      DEFAULT_USER="$DEFAULT_USER" \
      INITIAL_PASSWORD="$INITIAL_PASSWORD" \
      AUTHORIZED_KEYS_FILE="$AUTHORIZED_KEYS_FILE" \
      TIMEZONE="$TIMEZONE" \
      LOCALE="$LOCALE" \
      SERIAL_CONSOLE="$SERIAL_CONSOLE" \
      KERNEL_EXTRA_ARGS="$KERNEL_EXTRA_ARGS" \
      "$0" "$@"
fi

###############################################################################
# Tool and input validation
###############################################################################

for tool in \
  debootstrap \
  sgdisk \
  losetup \
  partprobe \
  udevadm \
  mkfs.ext4 \
  mount \
  umount \
  mountpoint \
  blkid \
  rsync \
  tar \
  zstd \
  sha256sum \
  truncate \
  dd \
  chroot \
  find \
  sort \
  sed \
  grep \
  awk
do
  require_tool "$tool"
done

require_file "$UBOOT_IMAGE"
require_file "$KERNEL_IMAGE"
require_file "$DTB_IMAGE"

mapfile -t MODULE_ARCHIVES < <(
  find "$KERNEL_OUTPUT_DIR" \
    -maxdepth 1 \
    -type f \
    -name 'modules-*.tar.zst' \
    -print |
    sort -V
)

if (( ${#MODULE_ARCHIVES[@]} == 0 )); then
  die "No modules-*.tar.zst archive found in $KERNEL_OUTPUT_DIR"
fi

MODULES_ARCHIVE="${MODULES_ARCHIVE:-${MODULE_ARCHIVES[${#MODULE_ARCHIVES[@]} - 1]}}"
require_file "$MODULES_ARCHIVE"

if [[ -n "$AUTHORIZED_KEYS_FILE" ]]; then
  require_file "$AUTHORIZED_KEYS_FILE"
fi

###############################################################################
# Cross-architecture bootstrap validation
###############################################################################

HOST_ARCH="$(uname -m)"

case "$HOST_ARCH" in
  aarch64|arm64)
    CROSS_ARCH_BUILD=false
    ;;

  x86_64|amd64)
    CROSS_ARCH_BUILD=true
    ;;

  *)
    die "Unsupported build-host architecture: $HOST_ARCH"
    ;;
esac

if [[ "$CROSS_ARCH_BUILD" == true ]]; then
  if [[ ! -d /proc/sys/fs/binfmt_misc ]]; then
    die "binfmt_misc is not mounted"
  fi

  if [[ ! -e /proc/sys/fs/binfmt_misc/qemu-aarch64 ]]; then
    cat >&2 <<'EOF'
Error: AArch64 binfmt emulation is not enabled.

On NixOS, add this to the host configuration:

  boot.binfmt.emulatedSystems = [ "aarch64-linux" ];
  boot.binfmt.preferStaticEmulators = true;

Then rebuild the host configuration.

On Debian or Ubuntu, install and enable qemu-user-static and binfmt-support.
EOF
    exit 1
  fi
fi

###############################################################################
# Display settings
###############################################################################

log "Image build settings"

show_setting "U-Boot image:" "$UBOOT_IMAGE"
show_setting "Kernel image:" "$KERNEL_IMAGE"
show_setting "Board DTB:" "$DTB_IMAGE"
show_setting "Modules archive:" "$MODULES_ARCHIVE"
show_setting "Output image:" "$IMAGE_PATH"
show_setting "Image size:" "$IMAGE_SIZE"
show_setting "Boot partition:" "$BOOT_SIZE"
show_setting "Debian suite:" "$DEBIAN_SUITE"
show_setting "Debian mirror:" "$DEBIAN_MIRROR"
show_setting "Hostname:" "$HOSTNAME"
show_setting "Default user:" "$DEFAULT_USER"
show_setting "Build-host arch:" "$HOST_ARCH"

###############################################################################
# Ensure U-Boot fits before the first partition
###############################################################################

UBOOT_SIZE="$(stat -c '%s' "$UBOOT_IMAGE")"
UBOOT_OFFSET_BYTES=$((UBOOT_START_SECTOR * SECTOR_SIZE))
BOOT_START_BYTES=$((BOOT_START_SECTOR * SECTOR_SIZE))
UBOOT_END_BYTES=$((UBOOT_OFFSET_BYTES + UBOOT_SIZE))

if (( UBOOT_END_BYTES >= BOOT_START_BYTES )); then
  die "U-Boot image is too large for the reserved pre-partition area"
fi

show_setting "U-Boot size:" "$UBOOT_SIZE bytes"
show_setting "U-Boot offset:" "$UBOOT_OFFSET_BYTES bytes"
show_setting "First partition:" "$BOOT_START_BYTES bytes"

###############################################################################
# Prepare output and work directories
###############################################################################

log "Preparing directories"

rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"
mkdir -p "$OUTPUT_DIR"

BOOT_MOUNT="$WORK_DIR/boot"
ROOT_MOUNT="$WORK_DIR/root"

mkdir -p "$BOOT_MOUNT"
mkdir -p "$ROOT_MOUNT"

rm -f "$IMAGE_PATH"
rm -f "$IMAGE_PATH.zst"

###############################################################################
# Create sparse disk image and GPT layout
###############################################################################

log "Creating sparse disk image"

truncate -s "$IMAGE_SIZE" "$IMAGE_PATH"

sgdisk --zap-all "$IMAGE_PATH"

sgdisk \
  --new=1:${BOOT_START_SECTOR}:+${BOOT_SIZE} \
  --typecode=1:8300 \
  --change-name=1:boot \
  "$IMAGE_PATH"

sgdisk \
  --new=2:0:0 \
  --typecode=2:8300 \
  --change-name=2:rootfs \
  "$IMAGE_PATH"

sgdisk --print "$IMAGE_PATH"

###############################################################################
# Write the combined mainline Rockchip U-Boot image
###############################################################################

log "Writing mainline U-Boot at the Rockchip 32 KiB offset"

dd \
  if="$UBOOT_IMAGE" \
  of="$IMAGE_PATH" \
  bs="$SECTOR_SIZE" \
  seek="$UBOOT_START_SECTOR" \
  conv=notrunc,fsync \
  status=progress

###############################################################################
# Attach image as a loop device
###############################################################################

log "Attaching loop device"

LOOP_DEVICE="$(losetup --find --show --partscan "$IMAGE_PATH")"

partprobe "$LOOP_DEVICE"
udevadm settle

BOOT_PARTITION="${LOOP_DEVICE}p1"
ROOT_PARTITION="${LOOP_DEVICE}p2"

for partition in "$BOOT_PARTITION" "$ROOT_PARTITION"; do
  for _ in $(seq 1 50); do
    [[ -b "$partition" ]] && break
    sleep 0.1
  done

  [[ -b "$partition" ]] ||
    die "Partition device did not appear: $partition"
done

show_setting "Loop device:" "$LOOP_DEVICE"
show_setting "Boot partition:" "$BOOT_PARTITION"
show_setting "Root partition:" "$ROOT_PARTITION"

###############################################################################
# Format filesystems
###############################################################################

log "Formatting filesystems"

mkfs.ext4 \
  -F \
  -L boot \
  -U random \
  "$BOOT_PARTITION"

mkfs.ext4 \
  -F \
  -L rootfs \
  -U random \
  "$ROOT_PARTITION"

BOOT_UUID="$(blkid -s UUID -o value "$BOOT_PARTITION")"
ROOT_UUID="$(blkid -s UUID -o value "$ROOT_PARTITION")"

[[ -n "$BOOT_UUID" ]] || die "Could not determine boot UUID"
[[ -n "$ROOT_UUID" ]] || die "Could not determine root UUID"

show_setting "Boot UUID:" "$BOOT_UUID"
show_setting "Root UUID:" "$ROOT_UUID"

###############################################################################
# Mount root and boot filesystems
###############################################################################

log "Mounting filesystems"

mount "$ROOT_PARTITION" "$ROOT_MOUNT"
MOUNTED_ROOT=true

mkdir -p "$ROOT_MOUNT/boot"

mount "$BOOT_PARTITION" "$BOOT_MOUNT"
MOUNTED_BOOT=true

###############################################################################
# Create Debian ARM64 root filesystem
###############################################################################

log "Bootstrapping Debian $DEBIAN_SUITE ARM64"

debootstrap \
  --arch="$DEBIAN_ARCH" \
  --variant=minbase \
  --include=\
systemd-sysv,\
systemd-timesyncd,\
openssh-server,\
sudo,\
ca-certificates,\
locales,\
tzdata,\
ifupdown,\
isc-dhcp-client,\
iproute2,\
iputils-ping,\
ethtool,\
pciutils,\
usbutils,\
nvme-cli,\
smartmontools,\
mdadm,\
lvm2,\
cryptsetup,\
btrfs-progs,\
xfsprogs,\
dosfstools,\
e2fsprogs,\
less,\
vim-tiny,\
nano,\
curl,\
wget,\
rsync,\
bash-completion,\
procps,\
kmod,\
udev,\
dbus,\
logrotate,\
cron \
  "$DEBIAN_SUITE" \
  "$ROOT_MOUNT" \
  "$DEBIAN_MIRROR"

###############################################################################
# Mount pseudo-filesystems for target configuration
###############################################################################

log "Preparing target chroot"

mkdir -p \
  "$ROOT_MOUNT/dev" \
  "$ROOT_MOUNT/dev/pts" \
  "$ROOT_MOUNT/proc" \
  "$ROOT_MOUNT/sys" \
  "$ROOT_MOUNT/run"

mount --bind /dev "$ROOT_MOUNT/dev"
MOUNTED_DEV=true

mount --bind /dev/pts "$ROOT_MOUNT/dev/pts"
MOUNTED_DEV_PTS=true

mount -t proc proc "$ROOT_MOUNT/proc"
MOUNTED_PROC=true

mount -t sysfs sysfs "$ROOT_MOUNT/sys"
MOUNTED_SYS=true

mount --bind /run "$ROOT_MOUNT/run"
MOUNTED_RUN=true

rm -f "$ROOT_MOUNT/etc/resolv.conf"
cp -L /etc/resolv.conf "$ROOT_MOUNT/etc/resolv.conf"

###############################################################################
# Configure Debian repositories
###############################################################################

log "Configuring Debian package repositories"

cat > "$ROOT_MOUNT/etc/apt/sources.list" <<EOF
deb $DEBIAN_MIRROR $DEBIAN_SUITE main contrib non-free non-free-firmware
deb $DEBIAN_MIRROR ${DEBIAN_SUITE}-updates main contrib non-free non-free-firmware
deb http://security.debian.org/debian-security ${DEBIAN_SUITE}-security main contrib non-free non-free-firmware
EOF

###############################################################################
# Base system configuration
###############################################################################

log "Configuring target system"

printf '%s\n' "$HOSTNAME" > "$ROOT_MOUNT/etc/hostname"

cat > "$ROOT_MOUNT/etc/hosts" <<EOF
127.0.0.1 localhost
127.0.1.1 $HOSTNAME

::1       localhost ip6-localhost ip6-loopback
ff02::1   ip6-allnodes
ff02::2   ip6-allrouters
EOF

cat > "$ROOT_MOUNT/etc/fstab" <<EOF
UUID=$ROOT_UUID  /      ext4  defaults,noatime,errors=remount-ro  0  1
UUID=$BOOT_UUID  /boot  ext4  defaults,noatime                    0  2
EOF

cat > "$ROOT_MOUNT/etc/network/interfaces" <<'EOF'
source /etc/network/interfaces.d/*

auto lo
iface lo inet loopback

allow-hotplug eth0
iface eth0 inet dhcp

allow-hotplug end0
iface end0 inet dhcp

allow-hotplug enP2p1s0
iface enP2p1s0 inet dhcp
EOF

printf '%s\n' "$TIMEZONE" > "$ROOT_MOUNT/etc/timezone"

cat > "$ROOT_MOUNT/etc/locale.gen" <<EOF
$LOCALE UTF-8
EOF

###############################################################################
# Install firmware and complete package configuration
###############################################################################

log "Installing target firmware and utilities"

chroot "$ROOT_MOUNT" /usr/bin/env \
  DEBIAN_FRONTEND=noninteractive \
  apt-get update

chroot "$ROOT_MOUNT" /usr/bin/env \
  DEBIAN_FRONTEND=noninteractive \
  apt-get install -y \
    firmware-realtek \
    firmware-linux-free

chroot "$ROOT_MOUNT" /usr/bin/env \
  DEBIAN_FRONTEND=noninteractive \
  locale-gen

chroot "$ROOT_MOUNT" \
  update-locale LANG="$LOCALE"

ln -sfn \
  "/usr/share/zoneinfo/$TIMEZONE" \
  "$ROOT_MOUNT/etc/localtime"

###############################################################################
# Create initial user
###############################################################################

log "Creating initial user: $DEFAULT_USER"

chroot "$ROOT_MOUNT" \
  useradd \
    --create-home \
    --shell /bin/bash \
    --groups sudo,adm,systemd-journal \
    "$DEFAULT_USER"

printf '%s:%s\n' "$DEFAULT_USER" "$INITIAL_PASSWORD" |
  chroot "$ROOT_MOUNT" chpasswd

# Force password change on the first successful login.
chroot "$ROOT_MOUNT" \
  chage -d 0 "$DEFAULT_USER"

# Disable direct root-password login.
chroot "$ROOT_MOUNT" \
  passwd -l root

if [[ -n "$AUTHORIZED_KEYS_FILE" ]]; then
  USER_HOME="$ROOT_MOUNT/home/$DEFAULT_USER"

  install \
    -d \
    -m 0700 \
    -o 1000 \
    -g 1000 \
    "$USER_HOME/.ssh"

  install \
    -m 0600 \
    -o 1000 \
    -g 1000 \
    "$AUTHORIZED_KEYS_FILE" \
    "$USER_HOME/.ssh/authorized_keys"
fi

###############################################################################
# SSH hardening
###############################################################################

log "Configuring SSH"

cat > "$ROOT_MOUNT/etc/ssh/sshd_config.d/50-cm3588.conf" <<EOF
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
UsePAM yes
EOF

if [[ -z "$AUTHORIZED_KEYS_FILE" ]]; then
  warn "No SSH public key was supplied."
  warn "SSH password login remains disabled."
  warn "Use the serial console for the first login."
fi

###############################################################################
# Install kernel modules
###############################################################################

log "Installing kernel modules"

tar \
  --extract \
  --zstd \
  --file="$MODULES_ARCHIVE" \
  --directory="$ROOT_MOUNT"

MODULES_DIRECTORY="$ROOT_MOUNT/lib/modules"

[[ -d "$MODULES_DIRECTORY" ]] ||
  die "Kernel modules were not installed into $MODULES_DIRECTORY"

mapfile -t KERNEL_RELEASES < <(
  find "$MODULES_DIRECTORY" \
    -mindepth 1 \
    -maxdepth 1 \
    -type d \
    -printf '%f\n' |
    sort -V
)

if (( ${#KERNEL_RELEASES[@]} == 0 )); then
  die "Could not determine installed kernel release"
fi

KERNEL_RELEASE="${KERNEL_RELEASES[${#KERNEL_RELEASES[@]} - 1]}"

show_setting "Kernel release:" "$KERNEL_RELEASE"

chroot "$ROOT_MOUNT" \
  depmod "$KERNEL_RELEASE"

###############################################################################
# Install kernel and device tree on the boot partition
###############################################################################

log "Installing kernel and device tree"

mkdir -p \
  "$BOOT_MOUNT/dtbs/rockchip" \
  "$BOOT_MOUNT/extlinux"

cp -f \
  "$KERNEL_IMAGE" \
  "$BOOT_MOUNT/Image"

cp -f \
  "$DTB_IMAGE" \
  "$BOOT_MOUNT/dtbs/rockchip/$DTB_NAME"

if [[ -f "$KERNEL_OUTPUT_DIR/boot/config-$KERNEL_RELEASE" ]]; then
  cp -f \
    "$KERNEL_OUTPUT_DIR/boot/config-$KERNEL_RELEASE" \
    "$BOOT_MOUNT/config-$KERNEL_RELEASE"
fi

if [[ -f "$KERNEL_OUTPUT_DIR/boot/System.map-$KERNEL_RELEASE" ]]; then
  cp -f \
    "$KERNEL_OUTPUT_DIR/boot/System.map-$KERNEL_RELEASE" \
    "$BOOT_MOUNT/System.map-$KERNEL_RELEASE"
fi

###############################################################################
# Configure extlinux for mainline U-Boot
###############################################################################

log "Writing extlinux configuration"

cat > "$BOOT_MOUNT/extlinux/extlinux.conf" <<EOF
default cm3588-mainline
menu title CM3588 NAS
timeout 30

label cm3588-mainline
    menu label Linux $KERNEL_RELEASE
    kernel /Image
    fdt /dtbs/rockchip/$DTB_NAME
    append root=UUID=$ROOT_UUID rootwait rw rootfstype=ext4 console=$SERIAL_CONSOLE console=tty1 earlycon loglevel=7 $KERNEL_EXTRA_ARGS
EOF

###############################################################################
# Record image build metadata
###############################################################################

cat > "$ROOT_MOUNT/etc/cm3588-image-build" <<EOF
Image name: $IMAGE_NAME
Build date UTC: $(date -u '+%Y-%m-%dT%H:%M:%SZ')
Debian suite: $DEBIAN_SUITE
Architecture: $DEBIAN_ARCH
Kernel release: $KERNEL_RELEASE
Board DTB: $DTB_NAME
Boot UUID: $BOOT_UUID
Root UUID: $ROOT_UUID
EOF

###############################################################################
# Enable essential services
###############################################################################

log "Enabling target services"

chroot "$ROOT_MOUNT" \
  systemctl enable ssh.service

chroot "$ROOT_MOUNT" \
  systemctl enable systemd-timesyncd.service

chroot "$ROOT_MOUNT" \
  systemctl enable serial-getty@"${SERIAL_CONSOLE%%,*}".service

###############################################################################
# Clean the root filesystem
###############################################################################

log "Cleaning target filesystem"

chroot "$ROOT_MOUNT" \
  apt-get clean

rm -rf \
  "$ROOT_MOUNT/var/lib/apt/lists/"* \
  "$ROOT_MOUNT/tmp/"* \
  "$ROOT_MOUNT/var/tmp/"*

# Do not ship the build host's resolver configuration.
rm -f "$ROOT_MOUNT/etc/resolv.conf"
ln -s ../run/systemd/resolve/stub-resolv.conf "$ROOT_MOUNT/etc/resolv.conf"

sync

###############################################################################
# Unmount before image compression
###############################################################################

log "Unmounting filesystems"

umount -R "$ROOT_MOUNT/run"
MOUNTED_RUN=false

umount -R "$ROOT_MOUNT/sys"
MOUNTED_SYS=false

umount -R "$ROOT_MOUNT/proc"
MOUNTED_PROC=false

umount -R "$ROOT_MOUNT/dev/pts"
MOUNTED_DEV_PTS=false

umount -R "$ROOT_MOUNT/dev"
MOUNTED_DEV=false

umount "$BOOT_MOUNT"
MOUNTED_BOOT=false

umount "$ROOT_MOUNT"
MOUNTED_ROOT=false

losetup -d "$LOOP_DEVICE"
LOOP_DEVICE=""

sync

###############################################################################
# Validate partition table and U-Boot placement
###############################################################################

log "Validating generated image"

sgdisk --verify "$IMAGE_PATH"

IMAGE_UBOOT_HASH="$(
  dd \
    if="$IMAGE_PATH" \
    bs="$SECTOR_SIZE" \
    skip="$UBOOT_START_SECTOR" \
    count="$(( (UBOOT_SIZE + SECTOR_SIZE - 1) / SECTOR_SIZE ))" \
    status=none |
  head -c "$UBOOT_SIZE" |
  sha256sum |
  awk '{print $1}'
)"

SOURCE_UBOOT_HASH="$(
  sha256sum "$UBOOT_IMAGE" |
  awk '{print $1}'
)"

if [[ "$IMAGE_UBOOT_HASH" != "$SOURCE_UBOOT_HASH" ]]; then
  die "U-Boot verification failed after writing the image"
fi

###############################################################################
# Compress image and generate checksums
###############################################################################

log "Compressing image"

zstd \
  --force \
  --threads=0 \
  --long=27 \
  -19 \
  "$IMAGE_PATH" \
  -o "$IMAGE_PATH.zst"

log "Generating checksums"

(
  cd "$OUTPUT_DIR"

  sha256sum \
    "$IMAGE_NAME" \
    "$IMAGE_NAME.zst" \
    > SHA256SUMS
)

###############################################################################
# Summary
###############################################################################

log "SD-card image completed successfully"

printf '\nOutput files:\n'
ls -lh \
  "$IMAGE_PATH" \
  "$IMAGE_PATH.zst" \
  "$OUTPUT_DIR/SHA256SUMS"

printf '\nImage layout:\n'
sgdisk --print "$IMAGE_PATH"

printf '\nKernel release:\n'
printf '  %s\n' "$KERNEL_RELEASE"

printf '\nInitial login:\n'
printf '  Username: %s\n' "$DEFAULT_USER"
printf '  Password: %s\n' "$INITIAL_PASSWORD"
printf '  Password change is required on first login.\n'

if [[ -n "$AUTHORIZED_KEYS_FILE" ]]; then
  printf '  SSH public key installed from: %s\n' "$AUTHORIZED_KEYS_FILE"
else
  printf '  No SSH key installed; use the serial console initially.\n'
fi

printf '\nCompressed image:\n'
printf '  %s\n' "$IMAGE_PATH.zst"

printf '\nFlash example:\n'
printf '  zstdcat %q | sudo dd of=/dev/sdX bs=4M status=progress conv=fsync\n' \
  "$IMAGE_PATH.zst"

printf '\nImportant:\n'
printf '%s\n' \
  '  Replace /dev/sdX with the whole SD-card device.' \
  '  Do not use a partition such as /dev/sdX1.' \
  '  Verify the target with lsblk before running dd.' \
  '  Keep the eMMC unchanged until the complete SD boot is validated.'
