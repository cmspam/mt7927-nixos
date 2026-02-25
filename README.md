# MediaTek MT7927 / MT6639 (Filogic 380) NixOS Support

This NixOS flake provides out-of-tree kernel modules and firmware for the **MediaTek MT7927 / MT6639 (Filogic 380)** Wi-Fi 7 and Bluetooth combo card.

## Features
- **Patched Bluetooth**: Includes the `btusb` and `btmtk` patches required to initialize the MT6639 Bluetooth stack on Linux.
- **ASPM Fix**: Automatically applies a udev rule to disable PCIe Active State Power Management (ASPM) for this device, which fixes common "stuck upload" and packet loss issues.
- **Auto-Firmware Extraction**: Automatically downloads the latest official ASUS Windows drivers and extracts the necessary `.bin` firmware files using Python scripts.
- **Automated Updates**: A GitHub Action keeps the driver patches and kernel source hashes in sync with the latest stable kernel releases.

## Usage

### 1. Add to your `flake.nix`
Add this repository to your inputs:

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    mt7927.url = "github:cmspam/mt7927-nixos";
  };

  outputs = { self, nixpkgs, mt7927, ... }: {
    nixosConfigurations.your-hostname = nixpkgs.lib.nixosSystem {
      specialArgs = { inherit mt7927; };
      modules = [
        # ... your other modules
        mt7927.nixosModules.default
      ];
    };
  };
}
```

### 2. Enable the hardware in `configuration.nix`
Activate the module and its features:

```nix
{
  hardware.mediatek-mt7927 = {
    enable = true;
    enableWifi = true;
    enableBluetooth = true;
    # Highly recommended to fix upload speed issues
    disableAspm = true;
  };
}
```

## How it works
This flake pulls specific sub-directories from the [Linux stable kernel tree](https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git) using a sparse checkout. It then applies the patches maintained by the [mediatek-mt7927-dkms](https://github.com/jetm/mediatek-mt7927-dkms) project. 

Because NixOS handles kernel modules differently than standard DKMS, this flake compiles the modules against your specific `boot.kernelPackages.kernel` version automatically, ensuring the driver is always compatible with your running kernel.

## Troubleshooting

### Verify Module Loading
After applying the configuration and rebooting, you can verify the drivers are loaded:

**Bluetooth Check**:
```bash
modinfo btusb | grep filename
# Result should point to a path in /nix/store/
```

**WiFi Check**:
```bash
lsmod | grep mt7925
```

## Credits
- Patches and firmware extraction logic based on [jetm/mediatek-mt7927-dkms](https://github.com/jetm/mediatek-mt7927-dkms).
