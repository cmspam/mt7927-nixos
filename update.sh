#!/usr/bin/env bash
# Usage: ./update.sh 6.20.1

NEW_VER=$1
if [ -z "$NEW_VER" ]; then
    echo "Usage: ./update.sh <kernel_version>"
    exit 1
fi

echo "Fetching hash for kernel v$NEW_VER..."

# We use 'nix shell' to ensure nix-prefetch-git and jq are available
# This avoids "command not found" errors in GitHub Actions
NEW_HASH=$(nix shell nixpkgs#nix-prefetch-git nixpkgs#jq --command bash -c "
    nix-prefetch-git https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git \
    --rev 'refs/tags/v$NEW_VER' \
    --sparse-checkout '[\"drivers/net/wireless/mediatek/mt76\",\"drivers/bluetooth\"]' \
    --quiet | jq -r '.hash'
")

if [ -n "$NEW_HASH" ] && [ "$NEW_HASH" != "null" ]; then
    # Update the JSON file using jq from the shell environment
    nix shell nixpkgs#jq --command bash -c "
        jq \".mt76KVer = \\\"$NEW_VER\\\" | .mt76Hash = \\\"$NEW_HASH\\\"\" versions.json > versions.json.tmp && mv versions.json.tmp versions.json
    "
    echo "Updated versions.json to $NEW_VER with hash $NEW_HASH"
else
    echo "Failed to fetch hash. (Result was: $NEW_HASH)"
    exit 1
fi
