{
  description = "CM3588 NAS mainline U-Boot and TF-A development environment";

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
              setuptools
            ]
          );
        in
        {
          default = pkgs.mkShell {
            name = "cm3588-mainline-uboot";

            packages = with pkgs; [
              # Source management
              git
              git-lfs
              cacert

              # Host compilation tools
              bash
              coreutils
              findutils
              gnugrep
              gnused
              gawk
              gnumake
              which
              file

              # AArch64 cross-compilation
              cross.stdenv.cc
              cross.buildPackages.binutils

              # U-Boot and TF-A generators
              bison
              flex
              bc
              dtc
              swig
              python

              # U-Boot host libraries
              pkg-config
              openssl
              gnutls
              ncurses
              libuuid
              zlib

              # Image inspection and manipulation
              util-linux
              dosfstools
              e2fsprogs
              ubootTools
            ];

            # Nixpkgs uses the canonical GNU target name:
            # aarch64-unknown-linux-gnu-
            CROSS_COMPILE = cross.stdenv.cc.targetPrefix;

            shellHook = ''
              set -o pipefail

              export ARCH=arm64
              export CROSS_COMPILE="${cross.stdenv.cc.targetPrefix}"

              echo
              echo "CM3588 mainline U-Boot environment"
              echo "  ARCH=$ARCH"
              echo "  CROSS_COMPILE=$CROSS_COMPILE"
              echo "  GCC: $(command -v "''${CROSS_COMPILE}gcc")"
              echo

              missing=0

              for tool in \
                "''${CROSS_COMPILE}gcc" \
                "''${CROSS_COMPILE}gcc-ar" \
                "''${CROSS_COMPILE}ld" \
                bison \
                flex \
                dtc \
                swig \
                python3
              do
                if ! command -v "$tool" >/dev/null 2>&1; then
                  echo "Missing tool: $tool" >&2
                  missing=1
                fi
              done

              if [ "$missing" -ne 0 ]; then
                echo "Development shell validation failed." >&2
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
