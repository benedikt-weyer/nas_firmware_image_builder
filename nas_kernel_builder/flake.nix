{
  description = "CM3588 NAS mainline Linux kernel build environment";

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

          cross = pkgs.pkgsCross.aarch64-multiplatform;

          python = pkgs.python3.withPackages (
            pythonPackages: with pythonPackages; [
              pyelftools
            ]
          );
        in
        {
          default = pkgs.mkShell {
            name = "cm3588-mainline-kernel";

            packages = with pkgs; [
              # Source and general build tools
              git
              cacert
              gnumake
              gcc
              binutils
              coreutils
              findutils
              gnugrep
              gnused
              gawk
              diffutils
              patch
              file
              which
              rsync

              # AArch64 GNU cross-toolchain
              cross.stdenv.cc
              cross.buildPackages.binutils

              # Kernel configuration and generation
              bc
              bison
              flex
              perl
              python
              pkg-config

              # Device trees and image tooling
              dtc
              cpio
              kmod
              pahole

              # Compression formats used by kernel builds/modules
              gzip
              bzip2
              xz
              zstd
              lz4

              # Host-side development libraries
              openssl
              openssl.dev
              elfutils
              elfutils.dev
              zlib
              zlib.dev
              ncurses
              ncurses.dev

              # Useful inspection tools
              ubootTools
              util-linux
            ];

            ARCH = "arm64";
            CROSS_COMPILE = cross.stdenv.cc.targetPrefix;

            shellHook = ''
              export ARCH=arm64
              export CROSS_COMPILE="${cross.stdenv.cc.targetPrefix}"

              echo
              echo "CM3588 mainline Linux kernel environment"
              echo "  ARCH=$ARCH"
              echo "  CROSS_COMPILE=$CROSS_COMPILE"
              echo "  Compiler: $(command -v "''${CROSS_COMPILE}gcc")"
              echo

              missing=0

              for tool in \
                make \
                git \
                bc \
                bison \
                flex \
                dtc \
                pahole \
                rsync \
                python3 \
                "''${CROSS_COMPILE}gcc" \
                "''${CROSS_COMPILE}ld" \
                "''${CROSS_COMPILE}objcopy"
              do
                if ! command -v "$tool" >/dev/null 2>&1; then
                  echo "Missing required tool: $tool" >&2
                  missing=1
                fi
              done

              if [ "$missing" -ne 0 ]; then
                echo "Development environment validation failed." >&2
                return 1
              fi

              "''${CROSS_COMPILE}gcc" --version | head -n 1
              echo
            '';
          };
        }
      );
    };
}


