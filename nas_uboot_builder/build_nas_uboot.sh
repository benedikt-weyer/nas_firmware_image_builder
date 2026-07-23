#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

RKBIN_DIR="${RKBIN_DIR:-$ROOT_DIR/rkbin}"
UBOOT_DIR="${UBOOT_DIR:-$ROOT_DIR/u-boot}"
TFA_DIR="${TFA_DIR:-$ROOT_DIR/trusted-firmware-a}"
OUTPUT_DIR="${OUTPUT_DIR:-$ROOT_DIR/output}"

UBOOT_DEFCONFIG="${UBOOT_DEFCONFIG:-cm3588-nas-rk3588_defconfig}"
JOBS="${JOBS:-$(nproc)}"
BUILD_TFA="${BUILD_TFA:-0}"

###############################################################################
# Helpers
###############################################################################

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

require_directory() {
  [[ -d "$1" ]] ||
    die "Source directory does not exist: $1"
}

require_file() {
  [[ -f "$1" ]] ||
    die "Required file does not exist: $1"
}

###############################################################################
# Environment validation
###############################################################################

: "${CROSS_COMPILE:?CROSS_COMPILE is unset. Enter the environment with: nix develop}"

export ARCH=arm64

HOST_CC="${HOST_CC:-cc}"
HOST_CXX="${HOST_CXX:-c++}"

CROSS_GCC="${CROSS_COMPILE}gcc"
CROSS_CPP="${CROSS_COMPILE}cpp"
CROSS_AR="${CROSS_COMPILE}ar"
CROSS_GCC_AR="${CROSS_COMPILE}gcc-ar"
CROSS_LD="${CROSS_COMPILE}ld"
CROSS_NM="${CROSS_COMPILE}nm"
CROSS_OBJCOPY="${CROSS_COMPILE}objcopy"
CROSS_OBJDUMP="${CROSS_COMPILE}objdump"
CROSS_READELF="${CROSS_COMPILE}readelf"
CROSS_STRIP="${CROSS_COMPILE}strip"

for tool in \
  git \
  make \
  bison \
  flex \
  bc \
  dtc \
  python3 \
  "$HOST_CC" \
  "$CROSS_GCC" \
  "$CROSS_CPP" \
  "$CROSS_AR" \
  "$CROSS_GCC_AR" \
  "$CROSS_LD" \
  "$CROSS_NM" \
  "$CROSS_OBJCOPY" \
  "$CROSS_OBJDUMP" \
  "$CROSS_READELF" \
  "$CROSS_STRIP"
do
  require_tool "$tool"
done

require_directory "$RKBIN_DIR"
require_directory "$UBOOT_DIR"

if [[ "$BUILD_TFA" == "1" ]]; then
  require_directory "$TFA_DIR"
fi

mkdir -p "$OUTPUT_DIR"

printf '%s\n' \
  "Using:" \
  "  CROSS_COMPILE=$CROSS_COMPILE" \
  "  RKBIN_DIR=$RKBIN_DIR" \
  "  UBOOT_DIR=$UBOOT_DIR" \
  "  TFA_DIR=$TFA_DIR" \
  "  OUTPUT_DIR=$OUTPUT_DIR" \
  "  UBOOT_DEFCONFIG=$UBOOT_DEFCONFIG" \
  "  JOBS=$JOBS"

"$CROSS_GCC" --version | head -n 1

###############################################################################
# Select Rockchip DDR initialization firmware
###############################################################################

log "Selecting RK3588 DDR firmware"

if [[ -z "${ROCKCHIP_TPL:-}" ]]; then
  mapfile -t DDR_CANDIDATES < <(
    find "$RKBIN_DIR/bin/rk35" \
      -maxdepth 1 \
      -type f \
      -name 'rk3588_ddr_*.bin' \
      ! -name '*eyescan*' \
      -print |
      sort -V
  )

  if (( ${#DDR_CANDIDATES[@]} == 0 )); then
    die "No non-eyescan RK3588 DDR firmware found in $RKBIN_DIR/bin/rk35"
  fi

  ROCKCHIP_TPL="${DDR_CANDIDATES[${#DDR_CANDIDATES[@]} - 1]}"
fi

ROCKCHIP_TPL="$(realpath "$ROCKCHIP_TPL")"
require_file "$ROCKCHIP_TPL"

printf 'DDR firmware:\n  %s\n' "$ROCKCHIP_TPL"

###############################################################################
# Select Trusted Firmware-A BL31
###############################################################################

if [[ -n "${BL31:-}" ]]; then
  log "Using supplied BL31"
elif [[ "$BUILD_TFA" == "1" ]]; then
  log "Building Trusted Firmware-A BL31"

  rm -rf "$TFA_DIR/build/rk3588"

  make -C "$TFA_DIR" \
    CROSS_COMPILE="$CROSS_COMPILE" \
    CC="$CROSS_GCC" \
    CPP="$CROSS_CPP" \
    AS="$CROSS_GCC" \
    AR="$CROSS_AR" \
    LD="$CROSS_LD" \
    NM="$CROSS_NM" \
    OC="$CROSS_OBJCOPY" \
    OD="$CROSS_OBJDUMP" \
    READELF="$CROSS_READELF" \
    PLAT=rk3588 \
    DEBUG=0 \
    bl31 \
    -j"$JOBS"

  BL31="$TFA_DIR/build/rk3588/release/bl31/bl31.elf"
else
  log "Using Rockchip RK3588 BL31"
  BL31="$RKBIN_DIR/bin/rk35/rk3588_bl31_v1.54.elf"
fi

BL31="$(realpath "$BL31")"

require_file "$BL31"

printf 'BL31:\n  %s\n' "$BL31"

"$CROSS_READELF" -h "$BL31" |
  grep -E 'Class:|Machine:|Entry point address:' ||
  true

###############################################################################
# Configure and build mainline U-Boot
###############################################################################

log "Cleaning U-Boot tree"

make -C "$UBOOT_DIR" \
  ARCH=arm \
  CROSS_COMPILE="$CROSS_COMPILE" \
  HOSTCC="$HOST_CC" \
  HOSTCXX="$HOST_CXX" \
  distclean

log "Configuring U-Boot with $UBOOT_DEFCONFIG"

make -C "$UBOOT_DIR" \
  ARCH=arm \
  CROSS_COMPILE="$CROSS_COMPILE" \
  CC="$CROSS_GCC" \
  HOSTCC="$HOST_CC" \
  HOSTCXX="$HOST_CXX" \
  "$UBOOT_DEFCONFIG"

require_file "$UBOOT_DIR/.config"

log "Building mainline U-Boot"

make -C "$UBOOT_DIR" \
  ARCH=arm \
  CROSS_COMPILE="$CROSS_COMPILE" \
  CC="$CROSS_GCC" \
  CPP="$CROSS_CPP" \
  AR="$CROSS_AR" \
  LD="$CROSS_LD" \
  NM="$CROSS_NM" \
  OBJCOPY="$CROSS_OBJCOPY" \
  OBJDUMP="$CROSS_OBJDUMP" \
  READELF="$CROSS_READELF" \
  STRIP="$CROSS_STRIP" \
  HOSTCC="$HOST_CC" \
  HOSTCXX="$HOST_CXX" \
  BL31="$BL31" \
  ROCKCHIP_TPL="$ROCKCHIP_TPL" \
  -j"$JOBS"

###############################################################################
# Validate generated images
###############################################################################

UBOOT_ROCKCHIP_BIN="$UBOOT_DIR/u-boot-rockchip.bin"

if [[ ! -f "$UBOOT_ROCKCHIP_BIN" ]]; then
  printf '\nGenerated image candidates:\n' >&2

  find "$UBOOT_DIR" \
    -maxdepth 1 \
    -type f \
    \( \
      -name '*.bin' \
      -o -name '*.img' \
      -o -name '*.itb' \
    \) \
    -printf '  %f\n' \
    >&2 || true

  die "U-Boot did not produce $UBOOT_ROCKCHIP_BIN"
fi

###############################################################################
# Collect outputs
###############################################################################

log "Collecting build outputs"

rm -rf "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR"

copy_if_present() {
  local source_file="$1"

  if [[ -f "$source_file" ]]; then
    cp -f "$source_file" "$OUTPUT_DIR/"
  fi
}

copy_if_present "$UBOOT_DIR/u-boot-rockchip.bin"
copy_if_present "$UBOOT_DIR/u-boot.itb"
copy_if_present "$UBOOT_DIR/u-boot.bin"
copy_if_present "$UBOOT_DIR/u-boot-nodtb.bin"
copy_if_present "$UBOOT_DIR/idbloader.img"
copy_if_present "$UBOOT_DIR/spl/u-boot-spl.bin"
copy_if_present "$UBOOT_DIR/tpl/u-boot-tpl.bin"

cp -f "$BL31" "$OUTPUT_DIR/bl31.elf"
cp -f "$ROCKCHIP_TPL" "$OUTPUT_DIR/$(basename "$ROCKCHIP_TPL")"
cp -f "$UBOOT_DIR/.config" "$OUTPUT_DIR/u-boot.config"

(
  cd "$OUTPUT_DIR"
  sha256sum ./* > SHA256SUMS
)

###############################################################################
# Summary
###############################################################################

log "Build completed successfully"

printf 'Output files:\n'
ls -lh "$OUTPUT_DIR"

printf '\nChecksums:\n'
cat "$OUTPUT_DIR/SHA256SUMS"

printf '\nPrimary image:\n'
printf '  %s\n' "$OUTPUT_DIR/u-boot-rockchip.bin"

printf '\nSafety note:\n'
printf '%s\n' \
  '  Test the image from removable media before modifying the eMMC.' \
  '  Do not write it directly over the existing bootloader without a recovery plan.'
