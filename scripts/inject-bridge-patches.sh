#!/bin/bash
# Inject bridge offload patches into naoki66's ImmortalWrt source
# Patches must be in airoha/patches-6.18/ (after 675-04) since they depend on 675-01~04
set -ex

BUILDER_PATCHES="$1"
AIROHA_PATCH="target/linux/airoha/patches-6.18"

echo "=== Injecting bridge offload patches into $AIROHA_PATCH ==="

# 9990 generic (flow-aware forward path) - depends on 675-01
# Needs to be applied AFTER 675-04, so name it 676-01
cp "$BUILDER_PATCHES/generic/9990-net-add-flow-aware-forward-path-discovery.patch" \
   "$AIROHA_PATCH/676-01-net-add-flow-aware-forward-path-discovery.patch"
echo "✅ 676-01 (9990 generic: flow-aware forward path)"

# 9991 (bonding LAG path) - depends on 9990
cp "$BUILDER_PATCHES/generic/9991-bonding-expose-selected-slave-through-forward-path.patch" \
   "$AIROHA_PATCH/676-02-bonding-expose-selected-slave-through-forward-path.patch"
echo "✅ 676-02 (9991: bonding LAG path)"

# 9992 (flowtable direct redirect) - depends on 9991
cp "$BUILDER_PATCHES/generic/9992-netfilter-flowtable-use-hardware-path-device-for-direct-redirect.patch" \
   "$AIROHA_PATCH/676-03-netfilter-flowtable-use-hardware-path-device-for-direct-redirect.patch"
echo "✅ 676-03 (9992: flowtable direct redirect)"

# 9990 airoha (WLAN PPE binding) - already named 9990, sorts after 676
cp "$BUILDER_PATCHES/airoha/9990-net-airoha-bind-WLAN-bound-flows-on-PPE-driver-L2-cache-miss.patch" \
   "$AIROHA_PATCH/"
echo "✅ 9990 (airoha: WLAN PPE binding)"

# 990-01 - already in naoki66's tree, skip
echo "⏭️  990-01 (already in naoki66)"

echo "=== Verifying patch order ==="
ls -1 "$AIROHA_PATCH"/67[56]*.patch "$AIROHA_PATCH"/9990*.patch "$AIROHA_PATCH"/990-01*.patch 2>/dev/null | sort
echo "=== Done ==="
