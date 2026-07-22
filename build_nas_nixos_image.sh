#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# CM3588 NAS headless NixOS SD-card image builder
#
# Uses the prebuilt mainline U-Boot, kernel, modules and board DTB produced by
# the sibling builders. NixOS creates the matching initrd and root filesystem.
###############################################################################

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$SCRIPT_DIR"

UBOOT_OUTPUT_DIR="${UBOOT_OUTPUT_DIR:-$PROJECT_DIR/nas_uboot_builder/output}"
KERNEL_OUTPUT_DIR="${KERNEL_OUTPUT_DIR:-$PROJECT_DIR/nas_kernel_builder/kernel-output}"
OUTPUT_DIR="${OUTPUT_DIR:-$PROJECT_DIR/output}"
WORK_DIR="${WORK_DIR:-$PROJECT_DIR/work-nixos}"

IMAGE_NAME="${IMAGE_NAME:-cm3588-nas-nixos.img.zst}"
IMAGE_BASENAME="${IMAGE_NAME%.img.zst}"

UBOOT_IMAGE="${UBOOT_IMAGE:-$UBOOT_OUTPUT_DIR/u-boot-rockchip.bin}"
KERNEL_IMAGE="${KERNEL_IMAGE:-$KERNEL_OUTPUT_DIR/boot/Image}"

DTB_NAME="rk3588-friendlyelec-cm3588-nas.dtb"
DTB_IMAGE="${DTB_IMAGE:-$KERNEL_OUTPUT_DIR/boot/dtbs/rockchip/$DTB_NAME}"

NIXOS_HOSTNAME="${NIXOS_HOSTNAME:-cm3588-nas}"
DEFAULT_USER="${DEFAULT_USER:-nas}"
INITIAL_PASSWORD="${INITIAL_PASSWORD:-changeme}"
AUTHORIZED_KEYS_FILE="${AUTHORIZED_KEYS_FILE:-}"
TIMEZONE="${TIMEZONE:-Europe/Berlin}"
SERIAL_CONSOLE="${SERIAL_CONSOLE:-ttyS2,1500000n8}"
KERNEL_EXTRA_ARGS="${KERNEL_EXTRA_ARGS:-}"

UBOOT_START_SECTOR=64
SECTOR_SIZE=512
PARTITION_OFFSET_BYTES=$((16 * 1024 * 1024))

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

require_file() {
  [[ -f "$1" ]] || die "Required file not found: $1"
}

show_setting() {
  printf '  %-22s %s\n' "$1" "$2"
}

for tool in nix find sort sed tar sha256sum stat cp mkdir; do
  require_tool "$tool"
done

require_file "$PROJECT_DIR/flake.nix"
require_file "$PROJECT_DIR/nixos-image.nix"
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

mapfile -t KERNEL_RELEASES < <(
  tar --zstd -tf "$MODULES_ARCHIVE" |
    sed -n 's#^\./lib/modules/\([^/]*\)/$#\1#p' |
    sort -Vu
)

if (( ${#KERNEL_RELEASES[@]} != 1 )); then
  die "Could not determine one kernel release from $MODULES_ARCHIVE"
fi

KERNEL_RELEASE="${KERNEL_RELEASES[0]}"
KERNEL_CONFIG="$KERNEL_OUTPUT_DIR/boot/config-$KERNEL_RELEASE"
require_file "$KERNEL_CONFIG"

if [[ -n "$AUTHORIZED_KEYS_FILE" ]]; then
  require_file "$AUTHORIZED_KEYS_FILE"
fi

UBOOT_SIZE="$(stat -c '%s' "$UBOOT_IMAGE")"
UBOOT_END_BYTES=$((UBOOT_START_SECTOR * SECTOR_SIZE + UBOOT_SIZE))

if (( UBOOT_END_BYTES >= PARTITION_OFFSET_BYTES )); then
  die "U-Boot image is too large for the reserved pre-partition area"
fi

case "$IMAGE_NAME" in
  *.img.zst) ;;
  *) die "IMAGE_NAME must end in .img.zst" ;;
esac

log "Headless NixOS image settings"

show_setting "U-Boot image:" "$UBOOT_IMAGE"
show_setting "Kernel image:" "$KERNEL_IMAGE"
show_setting "Kernel release:" "$KERNEL_RELEASE"
show_setting "Board DTB:" "$DTB_IMAGE"
show_setting "Modules archive:" "$MODULES_ARCHIVE"
show_setting "Output image:" "$OUTPUT_DIR/$IMAGE_NAME"
show_setting "Hostname:" "$NIXOS_HOSTNAME"
show_setting "Default user:" "$DEFAULT_USER"
show_setting "Serial console:" "$SERIAL_CONSOLE"

mkdir -p "$OUTPUT_DIR" "$WORK_DIR"

export CM3588_PROJECT_DIR="$PROJECT_DIR"
export CM3588_NIXOS_EXPRESSION="$PROJECT_DIR/nixos-image.nix"
export CM3588_KERNEL_IMAGE="$KERNEL_IMAGE"
export CM3588_KERNEL_MODULES="$MODULES_ARCHIVE"
export CM3588_KERNEL_CONFIG="$KERNEL_CONFIG"
export CM3588_BOARD_DTB="$DTB_IMAGE"
export CM3588_UBOOT_IMAGE="$UBOOT_IMAGE"
export CM3588_KERNEL_RELEASE="$KERNEL_RELEASE"
export CM3588_IMAGE_BASENAME="$IMAGE_BASENAME"
export CM3588_HOSTNAME="$NIXOS_HOSTNAME"
export CM3588_DEFAULT_USER="$DEFAULT_USER"
export CM3588_INITIAL_PASSWORD="$INITIAL_PASSWORD"
export CM3588_AUTHORIZED_KEYS_FILE="$AUTHORIZED_KEYS_FILE"
export CM3588_TIMEZONE="$TIMEZONE"
export CM3588_SERIAL_CONSOLE="$SERIAL_CONSOLE"
export CM3588_KERNEL_EXTRA_ARGS="$KERNEL_EXTRA_ARGS"

RESULT_LINK="$WORK_DIR/nixos-image-result"

log "Building the NixOS ARM64 system and SD-card image"

nix build \
  --impure \
  --print-build-logs \
  --out-link "$RESULT_LINK" \
  --expr '
    let
      project = builtins.getFlake ("path:" + builtins.getEnv "CM3588_PROJECT_DIR");
    in
    import (builtins.getEnv "CM3588_NIXOS_EXPRESSION") {
      nixpkgs = project.inputs.nixpkgs;
      kernelImage = builtins.getEnv "CM3588_KERNEL_IMAGE";
      kernelModules = builtins.getEnv "CM3588_KERNEL_MODULES";
      kernelConfig = builtins.getEnv "CM3588_KERNEL_CONFIG";
      boardDtb = builtins.getEnv "CM3588_BOARD_DTB";
      ubootImage = builtins.getEnv "CM3588_UBOOT_IMAGE";
      kernelRelease = builtins.getEnv "CM3588_KERNEL_RELEASE";
      imageBaseName = builtins.getEnv "CM3588_IMAGE_BASENAME";
      hostName = builtins.getEnv "CM3588_HOSTNAME";
      defaultUser = builtins.getEnv "CM3588_DEFAULT_USER";
      initialPassword = builtins.getEnv "CM3588_INITIAL_PASSWORD";
      authorizedKeysFile = builtins.getEnv "CM3588_AUTHORIZED_KEYS_FILE";
      timeZone = builtins.getEnv "CM3588_TIMEZONE";
      serialConsole = builtins.getEnv "CM3588_SERIAL_CONSOLE";
      kernelExtraArgs = builtins.getEnv "CM3588_KERNEL_EXTRA_ARGS";
    }
  '

BUILT_IMAGE="$RESULT_LINK/sd-image/$IMAGE_BASENAME.img.zst"
require_file "$BUILT_IMAGE"

cp -fL "$BUILT_IMAGE" "$OUTPUT_DIR/$IMAGE_NAME"

(
  cd "$OUTPUT_DIR"
  sha256sum "$IMAGE_NAME" > "$IMAGE_NAME.sha256"
)

log "Headless NixOS SD-card image completed successfully"

ls -lh \
  "$OUTPUT_DIR/$IMAGE_NAME" \
  "$OUTPUT_DIR/$IMAGE_NAME.sha256"

printf '\nInitial login:\n'
printf '  Username: %s\n' "$DEFAULT_USER"
printf '  Password: %s\n' "$INITIAL_PASSWORD"

if [[ -n "$AUTHORIZED_KEYS_FILE" ]]; then
  printf '  SSH public key installed from: %s\n' "$AUTHORIZED_KEYS_FILE"
fi

printf '\nFlash example:\n'
printf '  zstdcat %q | sudo dd of=/dev/sdX bs=4M status=progress conv=fsync\n' \
  "$OUTPUT_DIR/$IMAGE_NAME"
