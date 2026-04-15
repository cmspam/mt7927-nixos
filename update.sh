#!/usr/bin/env bash
# Usage: ./update.sh <version> <upstream-source-path>
#
# version:               kernel version from the upstream PKGBUILD's _mt76_kver
# upstream-source-path:  path to the mediatek-mt7927-dkms repo (nix store or checkout)
#
# Resolves the kernel hash and patch lists, then writes versions.json.

set -euo pipefail

NEW_VER=${1:?Usage: ./update.sh <version> <upstream-source-path>}
SOURCE_PATH=${2:?Usage: ./update.sh <version> <upstream-source-path>}

echo "--- Fetching Hash for Kernel v$NEW_VER ---"

URL="https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git/snapshot/linux-$NEW_VER.tar.gz"

echo "Downloading and hashing $URL..."
RAW_HASH=$(nix-prefetch-url --unpack "$URL")

if [ -z "$RAW_HASH" ]; then
    echo "Error: Failed to fetch hash."
    exit 1
fi

SRI_HASH=$(nix hash to-sri --type sha256 "$RAW_HASH")

echo "--- Resolving patch lists from upstream Makefile ---"

# Read the Makefile to extract the patch application order.
# This is the single source of truth for which patches to apply and in what order.
MAKEFILE="$SOURCE_PATH/Makefile"
if [ ! -f "$MAKEFILE" ]; then
    echo "Error: Makefile not found at $MAKEFILE"
    exit 1
fi

# WiFi patches — the Makefile applies:
#   1. mt7902-wifi-6.19.patch (explicit)
#   2. mt7927-wifi-*.patch    (glob, sorted)
# We replicate this by listing the actual files in the same order.
WIFI_PATCHES=()
for f in "$SOURCE_PATH"/mt7902-wifi-*.patch; do
    [ -f "$f" ] && WIFI_PATCHES+=("$(basename "$f")")
done
for f in "$SOURCE_PATH"/mt7927-wifi-*.patch; do
    [ -f "$f" ] && WIFI_PATCHES+=("$(basename "$f")")
done

# BT patches — the Makefile applies:
#   1. mt6639-bt-[0-9]*.patch   (numbered, sorted)
#   2. mt6639-bt-compat-*.patch (compat, sorted)
BT_PATCHES=()
for f in "$SOURCE_PATH"/mt6639-bt-[0-9]*.patch; do
    [ -f "$f" ] && BT_PATCHES+=("$(basename "$f")")
done
for f in "$SOURCE_PATH"/mt6639-bt-compat-*.patch; do
    [ -f "$f" ] && BT_PATCHES+=("$(basename "$f")")
done

echo "Found ${#WIFI_PATCHES[@]} WiFi patches, ${#BT_PATCHES[@]} BT patches"

# Build the JSON using python3 for correctness (handles quoting, etc.)
python3 - "$NEW_VER" "$SRI_HASH" <<'PYEOF' "${WIFI_PATCHES[@]}" -- "${BT_PATCHES[@]}" > versions.json
import json, sys

args = sys.argv[1:]
ver = args[0]
sri = args[1]
rest = args[2:]

sep = rest.index("--")
wifi = [x for x in rest[:sep] if x]
bt   = [x for x in rest[sep+1:] if x]

json.dump({
    "mt76KVer": ver,
    "mt76Hash": sri,
    "wifiPatches": wifi,
    "btPatches": bt,
}, sys.stdout, indent=2)
print()
PYEOF

echo "versions.json updated."
echo "  Version: $NEW_VER"
echo "  Hash:    $SRI_HASH"
echo "  WiFi patches: ${WIFI_PATCHES[*]}"
echo "  BT patches:   ${BT_PATCHES[*]}"
