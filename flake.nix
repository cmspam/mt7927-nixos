{
  description = "NixOS hardware support for MediaTek MT7927 / MT6639 (Filogic 380) WiFi 7 and Bluetooth";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    # Upstream source for patches and firmware extraction scripts
    mediatek-mt7927-dkms = {
      url = "github:jetm/mediatek-mt7927-dkms";
      flake = false;
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      mediatek-mt7927-dkms,
    }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
      repoSrc = mediatek-mt7927-dkms;

      # 1. Load automated version/hash data from the JSON bridge
      versions =
        if builtins.pathExists ./versions.json then
          builtins.fromJSON (builtins.readFile ./versions.json)
        else
          {
            # Fallback defaults if the file is missing locally
            mt76KVer = "6.19.3";
            mt76Hash = "sha256-lEZOxC8mWC3xjQRPbd92lej36CEdHLEvHZGq5KNxG5Q=";
          };

      # 2. Parse metadata from the DKMS repo's PKGBUILD for ASUS firmware
      pkgbuild = builtins.readFile "${repoSrc}/PKGBUILD";

      driverFilename =
        let
          m = builtins.match ".*_driver_filename='([^']+)'.*" pkgbuild;
        in
        if m != null then builtins.head m else "DRV_WiFi_MTK_MT7925_MT7927_TP_W11_64_V5603998_20250709R.zip";

      driverSha256Hex =
        let
          m = builtins.match ".*_driver_sha256='([a-f0-9]+)'.*" pkgbuild;
        in
        if m != null then builtins.head m else "b377fffa28208bb1671a0eb219c84c62fba4cd6f92161b74e4b0909476307cc8";

      # 3. Fetch Kernel source using the Tarball method to ensure hash consistency
      # This matches the behavior of the update.sh script.
      linuxDrivers = pkgs.fetchzip {
        url = "https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git/snapshot/linux-${versions.mt76KVer}.tar.gz";
        hash = versions.mt76Hash;
      };

      # 4. Firmware source from ASUS
      asusZip = pkgs.fetchurl {
        url = "https://dlcdnets.asus.com/pub/ASUS/mb/08WIRELESS/${driverFilename}";
        hash = "sha256:${driverSha256Hex}";
        name = "asus-mt7927-driver.zip";
      };

      # Generator function for kernel-version-specific packages
      mkMt7927 =
        kernel:
        let
          isClang = kernel.stdenv.cc.isClang or false;
          kernelBuild = "${kernel.dev}/lib/modules/${kernel.modDirVersion}/build";
          makeFlags = if isClang then "LLVM=1 CC=clang" else "";
        in
        rec {
          firmware = kernel.stdenv.mkDerivation {
            pname = "mediatek-mt7927-firmware";
            version = "2.1";
            dontUnpack = true;
            nativeBuildInputs = [
              pkgs.libarchive
              pkgs.python3
            ];

            buildPhase = ''
              runHook preBuild
              bsdtar -xf ${asusZip} mtkwlan.dat
              python3 ${repoSrc}/extract_firmware.py mtkwlan.dat firmware/
              runHook postBuild
            '';

            installPhase = ''
              runHook preInstall
              install -Dm644 firmware/BT_RAM_CODE_MT6639_2_1_hdr.bin \
                "$out/lib/firmware/mediatek/mt6639/BT_RAM_CODE_MT6639_2_1_hdr.bin"
              install -Dm644 firmware/WIFI_MT6639_PATCH_MCU_2_1_hdr.bin \
                "$out/lib/firmware/mediatek/mt7927/WIFI_MT6639_PATCH_MCU_2_1_hdr.bin"
              install -Dm644 firmware/WIFI_RAM_CODE_MT6639_2_1.bin \
                "$out/lib/firmware/mediatek/mt7927/WIFI_RAM_CODE_MT6639_2_1.bin"
              runHook postInstall
            '';

            meta.license = pkgs.lib.licenses.unfreeRedistributableFirmware;
          };

          wifi = kernel.stdenv.mkDerivation {
            pname = "mediatek-mt7927-wifi";
            version = "2.1";
            src = "${linuxDrivers}/drivers/net/wireless/mediatek/mt76";
            nativeBuildInputs = kernel.moduleBuildDependencies ++ [
              pkgs.python3
              pkgs.perl
              pkgs.kmod
            ];
            patches = [
              "${repoSrc}/mt7902-wifi-6.19.patch"
              "${repoSrc}/mt6639-wifi-init.patch"
              "${repoSrc}/mt6639-wifi-dma.patch"
            ];
            buildPhase = ''
              runHook preBuild
              cat > Kbuild << 'KBUILD'
              obj-m += mt76.o
              obj-m += mt76-connac-lib.o
              obj-m += mt792x-lib.o
              obj-m += mt7921/
              obj-m += mt7925/
              mt76-y := mmio.o util.o trace.o dma.o mac80211.o debugfs.o eeprom.o tx.o agg-rx.o mcu.o wed.o scan.o channel.o pci.o
              mt76-connac-lib-y := mt76_connac_mcu.o mt76_connac_mac.o mt76_connac3_mac.o
              mt792x-lib-y := mt792x_core.o mt792x_mac.o mt792x_trace.o mt792x_debugfs.o mt792x_dma.o mt792x_acpi_sar.o
              CFLAGS_trace.o := -I$(src)
              CFLAGS_mt792x_trace.o := -I$(src)
              KBUILD

              cat > mt7921/Kbuild << 'KBUILD'
              obj-m += mt7921-common.o
              obj-m += mt7921e.o
              mt7921-common-y := mac.o mcu.o main.o init.o debugfs.o
              mt7921e-y := pci.o pci_mac.o pci_mcu.o
              KBUILD

              cat > mt7925/Kbuild << 'KBUILD'
              obj-m += mt7925-common.o
              obj-m += mt7925e.o
              mt7925-common-y := mac.o mcu.o regd.o main.o init.o debugfs.o
              mt7925e-y := pci.o pci_mac.o pci_mcu.o
              KBUILD
              make -C ${kernelBuild} M=$(pwd) ${makeFlags} modules
              runHook postBuild
            '';
            installPhase = ''
              runHook preInstall
              modDir="$out/lib/modules/${kernel.modDirVersion}/extra/mt76"
              install -dm755 "$modDir/mt7921" "$modDir/mt7925"
              install -m644 mt76.ko mt76-connac-lib.ko mt792x-lib.ko "$modDir/"
              install -m644 mt7921/*.ko "$modDir/mt7921/"
              install -m644 mt7925/*.ko "$modDir/mt7925/"
              runHook postInstall
            '';
          };

          bluetooth = kernel.stdenv.mkDerivation {
            pname = "mediatek-mt7927-bluetooth";
            version = "2.1";
            src = "${linuxDrivers}/drivers/bluetooth";
            nativeBuildInputs = kernel.moduleBuildDependencies ++ [ pkgs.kmod ];
            buildPhase = ''
              runHook preBuild
              if ! grep -q '0x6639' btmtk.c; then
                patch -p3 < ${repoSrc}/mt6639-bt-6.19.patch
              fi
              echo "obj-m += btusb.o btmtk.o" > Makefile
              make -C ${kernelBuild} M=$(pwd) ${makeFlags} modules
              runHook postBuild
            '';
            installPhase = ''
              runHook preInstall
              modDir="$out/lib/modules/${kernel.modDirVersion}/extra/bluetooth"
              install -dm755 "$modDir"
              install -m644 btusb.ko btmtk.ko "$modDir/"
              runHook postInstall
            '';
          };
        };

      defaultModules = mkMt7927 pkgs.linux;
    in
    {
      packages.${system} = {
        firmware = defaultModules.firmware;
        wifi = defaultModules.wifi;
        bluetooth = defaultModules.bluetooth;
        default = defaultModules.firmware;
        repo-src = repoSrc;
      };

      nixosModules.default =
        {
          config,
          pkgs,
          lib,
          ...
        }:
        let
          cfg = config.hardware.mediatek-mt7927;
          builtModules = mkMt7927 config.boot.kernelPackages.kernel;
        in
        {
          options.hardware.mediatek-mt7927 = {
            enable = lib.mkEnableOption "MediaTek MT7927 / MT6639 WiFi and Bluetooth";
            enableWifi = lib.mkOption {
              type = lib.types.bool;
              default = true;
            };
            enableBluetooth = lib.mkOption {
              type = lib.types.bool;
              default = true;
            };
            disableAspm = lib.mkOption {
              type = lib.types.bool;
              default = true;
            };
          };

          config = lib.mkIf cfg.enable {
            hardware.firmware = [ builtModules.firmware ];
            boot.extraModulePackages =
              lib.optional cfg.enableWifi builtModules.wifi
              ++ lib.optional cfg.enableBluetooth builtModules.bluetooth;

            boot.kernelModules =
              lib.optionals cfg.enableWifi [
                "mt7925e"
                "mt7921e"
              ]
              ++ lib.optionals cfg.enableBluetooth [
                "btmtk"
                "btusb"
              ];

            services.udev.extraRules = lib.mkIf cfg.disableAspm ''
              ACTION=="add", SUBSYSTEM=="pci", \
                ATTR{vendor}=="0x14c3", ATTR{device}=="0x7927", \
                ATTR{link/l1_aspm}="0"
            '';
          };
        };
    };
}
