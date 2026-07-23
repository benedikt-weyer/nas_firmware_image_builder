{
  nixpkgs,
  kernelImage,
  kernelModules,
  kernelConfig,
  boardDtb,
  ubootImage,
  kernelRelease,
  imageBaseName ? "cm3588-nas-nixos",
  hostName ? "cm3588-nas",
  defaultUser ? "nas",
  initialPassword ? "changeme",
  authorizedKeysFile ? "",
  timeZone ? "Europe/Berlin",
  serialConsole ? "ttyS2,1500000n8",
  kernelExtraArgs ? "",
}:

let
  lib = nixpkgs.lib;
  system = "aarch64-linux";
  pkgs = import nixpkgs { inherit system; };

  importArtifact = name: path: builtins.path {
    inherit name path;
  };

  kernelImagePath = importArtifact "cm3588-kernel-Image" kernelImage;
  kernelModulesPath = importArtifact "cm3588-kernel-modules.tar.zst" kernelModules;
  kernelConfigPath = importArtifact "cm3588-kernel-config" kernelConfig;
  boardDtbPath = importArtifact "cm3588-board.dtb" boardDtb;
  ubootImagePath = importArtifact "cm3588-u-boot-rockchip.bin" ubootImage;

  kernelVersion = lib.head (lib.splitString "-" kernelRelease);

  rawKernelConfig = lib.listToAttrs (
    lib.concatMap (
      line:
      let
        match = builtins.match "(CONFIG_[^=]+)=([ym])" line;
      in
      lib.optional (match != null) {
        name = builtins.elemAt match 0;
        value = builtins.elemAt match 1;
      }
    ) (lib.splitString "\n" (builtins.readFile kernelConfigPath))
  );

  kernelConfigInterface = rec {
    isSet = option: builtins.hasAttr ("CONFIG_" + option) rawKernelConfig;
    getValue = option: rawKernelConfig.${"CONFIG_" + option} or null;
    isYes = option: getValue option == "y";
    isNo = option: !isSet option;
    isModule = option: getValue option == "m";
    isEnabled = option: isYes option || isModule option;
    isDisabled = option: !isEnabled option;
  } // rawKernelConfig;

  prebuiltKernel = lib.makeOverridable (
    {
      features ? { },
      kernelPatches ? [ ],
      randstructSeed ? "",
      ...
    }:
    pkgs.stdenvNoCC.mkDerivation {
      pname = "linux-cm3588-prebuilt";
      version = kernelVersion;

      outputs = [
        "out"
        "modules"
      ];

      dontUnpack = true;
      nativeBuildInputs = [
        pkgs.gnutar
        pkgs.zstd
      ];

      installPhase = ''
        runHook preInstall

        mkdir -p "$out/dtbs/rockchip" "$modules"
        install -m 0644 ${kernelImagePath} "$out/Image"
        install -m 0644 ${boardDtbPath} \
          "$out/dtbs/rockchip/rk3588-friendlyelec-cm3588-nas.dtb"

        tar \
          --use-compress-program="zstd -d" \
          --extract \
          --file=${kernelModulesPath} \
          --directory="$modules"

        rm -f \
          "$modules/lib/modules/${kernelRelease}/build" \
          "$modules/lib/modules/${kernelRelease}/source"

        test -f "$modules/lib/modules/${kernelRelease}/modules.dep"

        runHook postInstall
      '';

      passthru = {
        inherit features kernelPatches randstructSeed;
        version = kernelVersion;
        modDirVersion = kernelRelease;
        configfile = kernelConfigPath;
        config = kernelConfigInterface;
        target = "Image";
        buildDTBs = true;
        isLTS = true;
        isZen = false;
        stdenv = pkgs.stdenv;
        commonMakeFlags = [ ];
        baseVersion = kernelVersion;
        kernelOlder = lib.versionOlder kernelVersion;
        kernelAtLeast = lib.versionAtLeast kernelVersion;
      };

      meta.platforms = [ system ];
    }
  ) { };

  kernelPackages = pkgs.linuxPackagesFor prebuiltKernel;

  authorizedKeys =
    if authorizedKeysFile == "" then
      [ ]
    else
      lib.filter (key: key != "") (
        lib.splitString "\n" (builtins.readFile authorizedKeysFile)
      );

  extraKernelParams = lib.filter (arg: arg != "") (lib.splitString " " kernelExtraArgs);

  nixos = lib.nixosSystem {
    inherit system;

    modules = [
      "${nixpkgs}/nixos/modules/installer/sd-card/sd-image-aarch64.nix"

      (
        { config, lib, pkgs, ... }:
        {
          image.baseName = imageBaseName;

          boot.kernelPackages = kernelPackages;
          boot.loader.grub.enable = false;
          boot.loader.generic-extlinux-compatible.enable = true;
          boot.loader.timeout = 3;

          boot.consoleLogLevel = 7;
          boot.kernelParams = [
            "console=${serialConsole}"
            "earlycon"
            "rootwait"
          ] ++ extraKernelParams;

          # The storage and ext4 drivers needed for the SD root are built in.
          # Avoid pulling unrelated generic hardware modules into the initrd.
          hardware.enableAllHardware = lib.mkForce false;
          hardware.enableRedistributableFirmware = true;
          boot.initrd.includeDefaultModules = false;
          boot.initrd.availableKernelModules = lib.mkForce [ ];
          boot.initrd.kernelModules = lib.mkForce [ ];
          boot.kernelModules = lib.mkForce [ ];
          boot.supportedFilesystems.zfs = lib.mkForce false;
          boot.initrd.supportedFilesystems.zfs = lib.mkForce false;

          hardware.deviceTree = {
            enable = true;
            name = "rockchip/rk3588-friendlyelec-cm3588-nas.dtb";
            filter = "*rk3588-friendlyelec-cm3588-nas.dtb";
          };

          networking = {
            inherit hostName;
            useDHCP = true;
          };

          services.openssh = {
            enable = true;
            settings = {
              PasswordAuthentication = true;
              PermitRootLogin = "no";
            };
          };

          users.users.${defaultUser} = {
            isNormalUser = true;
            description = "CM3588 NAS administrator";
            extraGroups = [ "wheel" ];
            inherit initialPassword;
            openssh.authorizedKeys.keys = authorizedKeys;
          };

          security.sudo.wheelNeedsPassword = true;

          environment.systemPackages = with pkgs; [
            btrfs-progs
            curl
            ethtool
            gitMinimal
            gptfdisk
            mdadm
            nvme-cli
            smartmontools
            vim
          ];

          services.xserver.enable = false;
          documentation.enable = false;
          time.timeZone = timeZone;

          sdImage = {
            compressImage = true;
            expandOnBoot = true;
            firmwarePartitionOffset = 16;
            populateFirmwareCommands = lib.mkForce "";

            populateRootCommands = ''
              mkdir -p ./files/boot
              ${config.boot.loader.generic-extlinux-compatible.populateCmd} \
                -c ${config.system.build.toplevel} \
                -d ./files/boot \
                -n rockchip/rk3588-friendlyelec-cm3588-nas.dtb
            '';

            postBuildCommands = ''
              dd \
                if=${ubootImagePath} \
                of="$img" \
                bs=512 \
                seek=64 \
                conv=notrunc,fsync \
                status=none
            '';
          };

          system.stateVersion = "26.05";
        }
      )
    ];
  };
in
nixos.config.system.build.sdImage
