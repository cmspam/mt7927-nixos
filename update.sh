#!/usr/bin/env bash
# Usage: ./update.sh 6.19.3

NEW_VER=$1
if [ -z "$NEW_VER" ]; then
    echo "Usage: ./update.sh <version>"
    exit 1
fi

echo "--- Fetching Hash for Kernel v$NEW_VER ---"

# The tarball URL
URL="https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git/snapshot/linux-$NEW_VER.tar.gz"

# nix-prefetch-url --unpack is the most compatible way to get the hash of a tarball
# It returns a single string (the hash)
echo "Downloading and hashing $URL..."
RAW_HASH=$(nix-prefetch-url --unpack "$URL")

if [ -z "$RAW_HASH" ]; then
    echo "❌ Error: Failed to fetch hash."
    exit 1
fi

# Convert the base32 hash to the SRI format (sha256-...) flakes expect
SRI_HASH=$(nix hash to-sri --type sha256 "$RAW_HASH")

# Save to versions.json
echo "{\"mt76KVer\": \"$NEW_VER\", \"mt76Hash\": \"$SRI_HASH\"}" > versions.json

echo "✅ Success! versions.json updated."
echo "Version: $NEW_VER"
echo "Hash:    $SRI_HASH"
