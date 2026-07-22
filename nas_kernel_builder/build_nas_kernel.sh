#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# CM3588 NAS mainline Linux kernel builder
#
# Builds:
#   - arch/arm64/boot/Image
#   - rk3588-friendlyelec-cm3588-nas.dtb
#   - kernel modules
#   - userspace-visible kernel headers
#
# Default kernel:
#   Linux 6.18.39 LTS
###############################################################################

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

LINUX_DIR="${LINUX_DIR:-$ROOT_DIR/linux}"
BUILD_DIR="${BUILD_DIR:-$ROOT_DIR/kernel-build}"
STAGING_DIR="${STAGING_DIR:-$ROOT_DIR/kernel-staging}"
OUTPUT_DIR="${OUTPUT_DIR:-$ROOT_DIR/kernel-output}"

KERNEL_REPOSITORY="${KERNEL_REPOSITORY:-https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git}"
KERNEL_REF="${KERNEL_REF:-v6.18.39}"

KERNEL_DEFCONFIG="${KERNEL_DEFCONFIG:-defconfig}"
KERNEL_LOCALVERSION="${KERNEL_LOCALVERSION:--cm3588}"
JOBS="${JOBS:-$(nproc)}"

BOARD_DTB_NAME="rk3588-friendlyelec-cm3588-nas.dtb"
BOARD_DTB_RELATIVE="rockchip/$BOARD_DTB_NAME"

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

require_file() {
  [[ -f "$1" ]] ||
    die "Required file not found: $1"
}

show_setting() {
  printf '  %-22s %s\n' "$1" "$2"
}

###############################################################################
# Build environment
###############################################################################

: "${CROSS_COMPILE:?CROSS_COMPILE is unset. Enter the environment with: nix develop}"

export ARCH=arm64
export CROSS_COMPILE

CROSS_GCC="${CROSS_COMPILE}gcc"
CROSS_AR="${CROSS_COMPILE}ar"
CROSS_LD="${CROSS_COMPILE}ld"
CROSS_NM="${CROSS_COMPILE}nm"
CROSS_OBJCOPY="${CROSS_COMPILE}objcopy"
CROSS_OBJDUMP="${CROSS_COMPILE}objdump"
CROSS_READELF="${CROSS_COMPILE}readelf"
CROSS_STRIP="${CROSS_COMPILE}strip"

for tool in \
  git \
  make \
  bc \
  bison \
  flex \
  perl \
  python3 \
  dtc \
  pahole \
  rsync \
  cpio \
  "$CROSS_GCC" \
  "$CROSS_AR" \
  "$CROSS_LD" \
  "$CROSS_NM" \
  "$CROSS_OBJCOPY" \
  "$CROSS_OBJDUMP" \
  "$CROSS_READELF" \
  "$CROSS_STRIP"
do
  require_tool "$tool"
done

log "Build settings"

show_setting "Kernel repository:" "$KERNEL_REPOSITORY"
show_setting "Kernel ref:" "$KERNEL_REF"
show_setting "Source directory:" "$LINUX_DIR"
show_setting "Build directory:" "$BUILD_DIR"
show_setting "Staging directory:" "$STAGING_DIR"
show_setting "Output directory:" "$OUTPUT_DIR"
show_setting "Defconfig:" "$KERNEL_DEFCONFIG"
show_setting "Local version:" "$KERNEL_LOCALVERSION"
show_setting "Cross compiler:" "$CROSS_GCC"
show_setting "Parallel jobs:" "$JOBS"

"$CROSS_GCC" --version | head -n 1

###############################################################################
# Obtain and select the kernel source
###############################################################################

if [[ ! -d "$LINUX_DIR/.git" ]]; then
  if [[ -e "$LINUX_DIR" ]]; then
    die "$LINUX_DIR exists but is not a Git repository"
  fi

  log "Cloning Linux kernel source"

  git clone \
    --filter=blob:none \
    --no-checkout \
    "$KERNEL_REPOSITORY" \
    "$LINUX_DIR"
fi

log "Fetching kernel revision $KERNEL_REF"

git -C "$LINUX_DIR" fetch \
  --depth=1 \
  origin \
  "$KERNEL_REF"

git -C "$LINUX_DIR" checkout \
  --detach \
  FETCH_HEAD

KERNEL_COMMIT="$(git -C "$LINUX_DIR" rev-parse HEAD)"
KERNEL_DESCRIPTION="$(
  git -C "$LINUX_DIR" describe \
    --always \
    --tags \
    --dirty
)"

show_setting "Checked-out commit:" "$KERNEL_COMMIT"
show_setting "Source description:" "$KERNEL_DESCRIPTION"

###############################################################################
# Confirm CM3588 NAS board support
###############################################################################

BOARD_DTS="$LINUX_DIR/arch/arm64/boot/dts/rockchip/rk3588-friendlyelec-cm3588-nas.dts"

require_file "$BOARD_DTS"

log "Confirmed CM3588 NAS device-tree source"
printf '  %s\n' "$BOARD_DTS"

###############################################################################
# Clean and configure
###############################################################################

log "Preparing clean build directories"

rm -rf "$BUILD_DIR"
rm -rf "$STAGING_DIR"
rm -rf "$OUTPUT_DIR"

mkdir -p "$BUILD_DIR"
mkdir -p "$STAGING_DIR"
mkdir -p "$OUTPUT_DIR"

MAKE_ARGS=(
  -C "$LINUX_DIR"
  O="$BUILD_DIR"
  ARCH=arm64
  CROSS_COMPILE="$CROSS_COMPILE"
  KCFLAGS="-Wno-error"
)

log "Creating ARM64 default configuration"

make "${MAKE_ARGS[@]}" "$KERNEL_DEFCONFIG"

CONFIG_TOOL="$LINUX_DIR/scripts/config"
require_file "$CONFIG_TOOL"

###############################################################################
# NAS-oriented configuration
#
# scripts/config requests these options. olddefconfig resolves dependencies and
# silently drops options unavailable in the selected kernel version.
###############################################################################

log "Applying CM3588 NAS-oriented kernel options"

"$CONFIG_TOOL" --file "$BUILD_DIR/.config" \
  --set-str LOCALVERSION "$KERNEL_LOCALVERSION" \
  --enable LOCALVERSION_AUTO \
  --enable MODULES \
  --enable MODULE_UNLOAD \
  --enable BLK_DEV_NVME \
  --enable NVME_CORE \
  --enable PCIEPORTBUS \
  --enable PCIE_ROCKCHIP_DW_HOST \
  --enable R8169 \
  --enable MMC \
  --enable MMC_BLOCK \
  --enable MMC_DW \
  --enable MMC_DW_ROCKCHIP \
  --enable MMC_SDHCI \
  --enable MMC_SDHCI_PLTFM \
  --enable MMC_SDHCI_OF_DWCMSHC \
  --enable EXT4_FS \
  --enable BTRFS_FS \
  --enable XFS_FS \
  --enable MD \
  --enable BLK_DEV_MD \
  --enable MD_RAID0 \
  --enable MD_RAID1 \
  --enable MD_RAID10 \
  --enable MD_RAID456 \
  --enable DM_CRYPT \
  --enable CRYPTO_AES_ARM64 \
  --enable CRYPTO_SHA256_ARM64 \
  --enable DEVTMPFS \
  --enable DEVTMPFS_MOUNT \
  --enable TMPFS \
  --enable SERIAL_8250 \
  --enable SERIAL_8250_CONSOLE \
  --enable SERIAL_8250_DW \
  --enable IKCONFIG \
  --enable IKCONFIG_PROC \
  --enable FHANDLE \
  --enable CGROUPS \
  --enable NAMESPACES \
  --enable OVERLAY_FS \
  --enable BRIDGE \
  --enable VLAN_8021Q \
  --enable BONDING \
  --enable TUN \
  --enable VETH \
  --enable NF_TABLES \
  --enable NETFILTER \
  --enable SECURITY \
  --enable SECURITY_APPARMOR \
  --enable RANDOMIZE_BASE \
  --enable STACKPROTECTOR \
  --enable STACKPROTECTOR_STRONG

make "${MAKE_ARGS[@]}" olddefconfig

require_file "$BUILD_DIR/.config"

###############################################################################
# Show important resolved options
###############################################################################

log "Resolved kernel configuration"

for symbol in \
  CONFIG_ARCH_ROCKCHIP \
  CONFIG_BLK_DEV_NVME \
  CONFIG_NVME_CORE \
  CONFIG_PCIE_ROCKCHIP_DW_HOST \
  CONFIG_R8169 \
  CONFIG_MMC_DW_ROCKCHIP \
  CONFIG_MMC_SDHCI_OF_DWCMSHC \
  CONFIG_EXT4_FS \
  CONFIG_MODULES
do
  value="$(
    grep -E "^${symbol}=|^# ${symbol} is not set$" \
      "$BUILD_DIR/.config" ||
      true
  )"

  printf '  %s\n' "${value:-$symbol: unavailable}"
done

###############################################################################
# Build kernel, modules and device trees
###############################################################################

log "Building kernel image, modules and device trees"

make "${MAKE_ARGS[@]}" \
  -j"$JOBS" \
  Image \
  modules \
  dtbs

KERNEL_RELEASE="$(
  make "${MAKE_ARGS[@]}" -s kernelrelease
)"

KERNEL_IMAGE="$BUILD_DIR/arch/arm64/boot/Image"
BOARD_DTB="$BUILD_DIR/arch/arm64/boot/dts/$BOARD_DTB_RELATIVE"

require_file "$KERNEL_IMAGE"
require_file "$BOARD_DTB"

show_setting "Kernel release:" "$KERNEL_RELEASE"

###############################################################################
# Install modules and headers into staging
###############################################################################

log "Installing kernel modules into staging"

make "${MAKE_ARGS[@]}" \
  INSTALL_MOD_PATH="$STAGING_DIR" \
  INSTALL_MOD_STRIP=1 \
  modules_install

log "Installing kernel headers into staging"

make "${MAKE_ARGS[@]}" \
  INSTALL_HDR_PATH="$STAGING_DIR/usr" \
  headers_install

MODULE_DIRECTORY="$STAGING_DIR/lib/modules/$KERNEL_RELEASE"
[[ -d "$MODULE_DIRECTORY" ]] ||
  die "Module installation directory not found: $MODULE_DIRECTORY"

###############################################################################
# Collect deployable files
###############################################################################

log "Collecting output files"

BOOT_OUTPUT="$OUTPUT_DIR/boot"
MODULES_OUTPUT="$OUTPUT_DIR/rootfs"
HEADERS_OUTPUT="$OUTPUT_DIR/headers"

mkdir -p "$BOOT_OUTPUT/dtbs/rockchip"
mkdir -p "$MODULES_OUTPUT/lib"
mkdir -p "$HEADERS_OUTPUT"

cp -f "$KERNEL_IMAGE" "$BOOT_OUTPUT/Image"
cp -f "$BOARD_DTB" "$BOOT_OUTPUT/dtbs/rockchip/$BOARD_DTB_NAME"
cp -f "$BUILD_DIR/.config" "$BOOT_OUTPUT/config-$KERNEL_RELEASE"
cp -f "$BUILD_DIR/System.map" "$BOOT_OUTPUT/System.map-$KERNEL_RELEASE"

cp -a "$STAGING_DIR/lib/modules" "$MODULES_OUTPUT/lib/"
cp -a "$STAGING_DIR/usr/include" "$HEADERS_OUTPUT/"

###############################################################################
# Create extlinux example
###############################################################################

cat > "$BOOT_OUTPUT/extlinux.conf.example" <<EOF
default cm3588-mainline
timeout 30
menu title CM3588 NAS

label cm3588-mainline
    kernel /Image
    fdt /dtbs/rockchip/$BOARD_DTB_NAME
    append root=UUID=REPLACE_WITH_ROOTFS_UUID rootwait rw console=ttyS2,1500000
EOF

###############################################################################
# Build metadata
###############################################################################

cat > "$OUTPUT_DIR/BUILD-INFO.txt" <<EOF
Kernel release: $KERNEL_RELEASE
Kernel source: $KERNEL_REPOSITORY
Kernel ref: $KERNEL_REF
Kernel commit: $KERNEL_COMMIT
Kernel description: $KERNEL_DESCRIPTION
Architecture: arm64
Cross compiler: $("$CROSS_GCC" -dumpmachine)
Board DTB: $BOARD_DTB_RELATIVE
Build date UTC: $(date -u '+%Y-%m-%dT%H:%M:%SZ')
EOF

###############################################################################
# Optional compressed archives
###############################################################################

log "Creating deployment archives"

tar \
  --numeric-owner \
  -C "$MODULES_OUTPUT" \
  -caf "$OUTPUT_DIR/modules-$KERNEL_RELEASE.tar.zst" \
  .

tar \
  -C "$HEADERS_OUTPUT" \
  -caf "$OUTPUT_DIR/userspace-headers-$KERNEL_RELEASE.tar.zst" \
  .

###############################################################################
# Checksums
###############################################################################

log "Generating checksums"

(
  cd "$OUTPUT_DIR"

  find . \
    -type f \
    ! -name SHA256SUMS \
    -print0 |
    sort -z |
    xargs -0 sha256sum > SHA256SUMS
)

###############################################################################
# Summary
###############################################################################

log "Kernel build completed successfully"

printf '\nKernel release:\n'
printf '  %s\n' "$KERNEL_RELEASE"

printf '\nBoot files:\n'
find "$BOOT_OUTPUT" \
  -type f \
  -printf '  %P\n' |
  sort

printf '\nDeployment archives:\n'
find "$OUTPUT_DIR" \
  -maxdepth 1 \
  -type f \
  \( -name '*.tar.zst' -o -name 'BUILD-INFO.txt' \) \
  -printf '  %f\n' |
  sort

printf '\nPrimary files:\n'
printf '  Kernel: %s\n' "$BOOT_OUTPUT/Image"
printf '  DTB:    %s\n' "$BOOT_OUTPUT/dtbs/rockchip/$BOARD_DTB_NAME"
printf '  Modules archive: %s\n' \
  "$OUTPUT_DIR/modules-$KERNEL_RELEASE.tar.zst"

printf '\nNext steps:\n'
printf '%s\n' \
  '  1. Copy Image and the DTB to the test microSD boot filesystem.' \
  '  2. Extract the modules archive into the test root filesystem.' \
  '  3. Replace the root UUID in extlinux.conf.example.' \
  '  4. Test using serial console before changing the eMMC.'
