{
  description = "CM3588 NAS bootable SD-card image builder";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = { nixpkgs, ... }:
    let
      supportedSystems = [
        "x86_64-linux"
        "aarch64-linux"
      ];

      forEachSystem = nixpkgs.lib.genAttrs supportedSystems;
    in
    {
      devShells = forEachSystem (
        system:
        let
          pkgs = import nixpkgs {
            inherit system;
          };
          crossPkgs = pkgs.pkgsCross.aarch64-multiplatform;
        in
        {
          default = pkgs.mkShell {
            name = "cm3588-image-builder";

            CROSS_COMPILE = crossPkgs.stdenv.cc.targetPrefix;

            packages = with pkgs; [
              # Core shell utilities
              bash
              coreutils
              findutils
              gnugrep
              gnused
              gawk
              diffutils
              file
              which

              # Disk image and partition tools
              util-linux
              gptfdisk
              e2fsprogs
              dosfstools
              parted

              # Root filesystem creation
              debootstrap
              qemu
              rsync

              # Compression and archives
              gnutar
              gzip
              xz
              zstd

              # Privilege and device handling
              sudo
              systemd
              kmod

              # Network and certificates
              curl
              cacert

              # AArch64 firmware builds
              crossPkgs.stdenv.cc
              pkgs.bison
              pkgs.flex
              pkgs.bc
              pkgs.dtc
              pkgs.pkg-config
              pkgs.python3Packages.setuptools
              pkgs.python3Packages.pyelftools
              pkgs.swig
              pkgs.gnutls.dev
            ];

            shellHook = ''
              echo
              echo "CM3588 NAS image-builder environment"
              echo

              required_tools=(
                debootstrap
                sgdisk
                losetup
                mkfs.ext4
                mount
                umount
                rsync
                zstd
                sha256sum
              )

              missing=0

              for tool in "''${required_tools[@]}"; do
                if ! command -v "$tool" >/dev/null 2>&1; then
                  echo "Missing required tool: $tool" >&2
                  missing=1
                fi
              done

              if [ "$missing" -ne 0 ]; then
                echo "Image-builder environment validation failed." >&2
                return 1
              fi

              echo "Tools are available."
              echo "The image build itself requires root privileges."
              echo
            '';
          };
        }
      );
    };
}
