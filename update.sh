#!/usr/bin/env bash
# Usage: ./update.sh 6.19.3

NEW_VER=$1
if [ -z "$NEW_VER" ]; then
    echo "Usage: ./update.sh <version>"
    exit 1
fi

echo "--- Fetching Hash for Kernel v$NEW_VER ---"

# The tarball URL for this specific version
URL="https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git/snapshot/linux-$NEW_VER.tar.gz"

# We use nix store prefetch-file because it is a core Nix command
# --unpack is used because fetchzip unpacks the tarball before hashing
PREFETCH_JSON=$(nix store prefetch-file "$URL" --json --unpack)

# Extract the SRI hash (sha256-...)
SRI_HASH=$(echo "$PREFETCH_JSON" | jq -r '.hash')

if [ -z "$SRI_HASH" ] || [ "$SRI_HASH" == "null" ]; then
    echo "❌ Error: Failed to fetch hash."
    exit 1
fi

# Save to versions.json
echo "{\"mt76KVer\": \"$NEW_VER\", \"mt76Hash\": \"$SRI_HASH\"}" > versions.json

echo "✅ Success! versions.json updated."
echo "Version: $NEW_VER"
echo "Hash:    $SRI_HASH"
