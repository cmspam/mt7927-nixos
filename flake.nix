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
      lib = pkgs.lib;
      repoSrc = mediatek-mt7927-dkms;

      # 1. Load automated version/hash data from the JSON bridge
      versions =
        if builtins.pathExists ./versions.json then
          builtins.fromJSON (builtins.readFile ./versions.json)
        else
          {
            mt76KVer = "7.0";
            mt76Hash = "sha256-7TjYHhJdD67P3lquusrjjVtUIUzhLPtA5Oy7tc82gYA=";
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

      # 3. Dynamically discover patch files from the upstream repo.
      #    This mirrors the Makefile's glob-based approach so that when
      #    upstream adds/removes/renames patches, a `nix flake update` is
      #    all that's needed — no manual flake.nix edits required.
      repoFiles = builtins.attrNames (builtins.readDir repoSrc);

      # WiFi patches: mt7902-wifi-6.19.patch + mt7927-wifi-*.patch (numbered + compat)
      wifiPatches =
        let
          mt7902 = builtins.filter (n: lib.hasPrefix "mt7902-wifi-" n && lib.hasSuffix ".patch" n) repoFiles;
          mt7927 = builtins.filter (n: lib.hasPrefix "mt7927-wifi-" n && lib.hasSuffix ".patch" n) repoFiles;
        in
        map (n: "${repoSrc}/${n}") (builtins.sort builtins.lessThan (mt7902 ++ mt7927));

      # Bluetooth patches: mt6639-bt-*.patch (numbered + compat)
      btPatches =
        let
          names = builtins.filter (n: lib.hasPrefix "mt6639-bt-" n && lib.hasSuffix ".patch" n) repoFiles;
        in
        map (n: "${repoSrc}/${n}") (builtins.sort builtins.lessThan names);

      # 4. Fetch kernel source
      linuxDrivers = pkgs.fetchzip {
        url = "https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git/snapshot/linux-${versions.mt76KVer}.tar.gz";
        hash = versions.mt76Hash;
      };

      # 5. Firmware source from ASUS
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
            patches = wifiPatches;
            postPatch = ''
              # Install upstream Kbuild files
              cp ${repoSrc}/mt76.Kbuild Kbuild
              cp ${repoSrc}/mt7921.Kbuild mt7921/Kbuild
              cp ${repoSrc}/mt7925.Kbuild mt7925/Kbuild
              # Install compat header for kernels lacking airoha_offload.h
              mkdir -p compat/include/linux/soc/airoha
              cp ${repoSrc}/compat-airoha-offload.h \
                compat/include/linux/soc/airoha/airoha_offload.h
            '';
            buildPhase = ''
              runHook preBuild
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
            patches = btPatches;
            buildPhase = ''
              runHook preBuild
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
