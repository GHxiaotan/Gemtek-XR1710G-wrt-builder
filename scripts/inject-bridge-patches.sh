#!/bin/bash
# Inject YYH bridge offload patches into naoki66's ImmortalWrt source
set -ex

BUILDER_PATCHES="$1"
GENERIC_PATCH="target/linux/generic/pending-6.18"
AIROHA_PATCH="target/linux/airoha/patches-6.18"

echo "=== Injecting bridge offload patches ==="

# Generic patches (flow-aware forward path, bonding, flowtable redirect)
for f in "$BUILDER_PATCHES/generic/"*.patch; do
  [ -f "$f" ] || continue
  name=$(basename "$f")
  cp "$f" "$GENERIC_PATCH/"
  echo "✅ generic: $name"
done

# Airoha patches (bridge FDB roaming, WLAN PPE binding)
for f in "$BUILDER_PATCHES/airoha/"*.patch; do
  [ -f "$f" ] || continue
  name=$(basename "$f")
  cp "$f" "$AIROHA_PATCH/"
  echo "✅ airoha: $name"
done

echo "=== Verifying patch injection ==="
ls -la "$GENERIC_PATCH"/999*.patch 2>/dev/null || echo "No 999x generic patches"
ls -la "$AIROHA_PATCH"/990-01*.patch "$AIROHA_PATCH"/9990*.patch 2>/dev/null || echo "No 990/9990 airoha patches"
echo "=== Done ==="
