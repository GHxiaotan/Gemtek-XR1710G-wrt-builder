#!/bin/bash
# Inject bridge offload patches into naoki66's ImmortalWrt source
# Strategy: copy clean patches directly, fix 9990 via Python code modification
set -ex

BUILDER_PATCHES="$1"
GENERIC_PATCH="target/linux/generic/pending-6.18"
AIROHA_PATCH="target/linux/airoha/patches-6.18"

echo "=== Step 1: Copy patches that apply cleanly ==="

# 9991 (bonding LAG path) - only adds DEV_PATH_LAG enum, no conflict
cp "$BUILDER_PATCHES/generic/9991-bonding-expose-selected-slave-through-forward-path.patch" "$GENERIC_PATCH/"
echo "✅ 9991 (bonding LAG path)"

# 9992 (flowtable direct redirect) - modifies nft_flow_offload.c
cp "$BUILDER_PATCHES/generic/9992-netfilter-flowtable-use-hardware-path-device-for-direct-redirect.patch" "$GENERIC_PATCH/"
echo "✅ 9992 (flowtable direct redirect)"

# 990-01 (bridge FDB roaming) - modifies nf_flow_table
cp "$BUILDER_PATCHES/airoha/990-01-smartrg-netfilter-nf_flow_table-invalidate-flows-on-bridge-FDB-roaming.patch" "$AIROHA_PATCH/"
echo "✅ 990-01 (bridge FDB roaming)"

# 9990 airoha (WLAN PPE binding) - modifies airoha_ppe.c
cp "$BUILDER_PATCHES/airoha/9990-net-airoha-bind-WLAN-bound-flows-on-PPE-driver-L2-cache-miss.patch" "$AIROHA_PATCH/"
echo "✅ 9990 airoha (WLAN PPE binding)"

echo "=== Step 2: Apply 9990 generic changes via Python (avoids context conflicts) ==="

python3 << 'PYEOF'
import re

# --- Fix include/linux/netdevice.h ---
nh = "include/linux/netdevice.h"
with open(nh, 'r') as f:
    content = f.read()

# 1. Add struct flow_keys forward declaration (after struct neighbour;)
if 'struct flow_keys;' not in content:
    content = content.replace(
        'struct neighbour;\nstruct neigh_parms;\nstruct sk_buff;',
        'struct neighbour;\nstruct neigh_parms;\nstruct flow_keys;\nstruct sk_buff;'
    )
    print(f"✅ {nh}: added struct flow_keys forward declaration")
else:
    print(f"ℹ️  {nh}: struct flow_keys already present")

# 2. Add flow field to net_device_path_ctx
if '.flow' not in content or 'flow_keys' not in content.split('net_device_path_ctx')[1][:200] if 'net_device_path_ctx' in content else '':
    # Add const struct flow_keys *flow; after const struct net_device *dev;
    old = 'struct net_device_path_ctx {\n\tconst struct net_device *dev;\n\tu8'
    new = 'struct net_device_path_ctx {\n\tconst struct net_device *dev;\n\tconst struct flow_keys\t*flow;\n\tu8'
    if old in content:
        content = content.replace(old, new)
        print(f"✅ {nh}: added flow field to net_device_path_ctx")
    else:
        print(f"⚠️  {nh}: could not find net_device_path_ctx to patch")
else:
    print(f"ℹ️  {nh}: flow field already present")

# 3. Add dev_fill_forward_path_flow declaration
if 'dev_fill_forward_path_flow' not in content:
    # Find the __dev_fill_forward_path declaration and add after it
    old = 'int __dev_fill_forward_path(struct net_device_path_ctx *ctx, const u8 *daddr,\n\t\t\t    struct net_device_path_stack *stack);\nint dev_fill_forward_path'
    new = 'int __dev_fill_forward_path(struct net_device_path_ctx *ctx, const u8 *daddr,\n\t\t\t    struct net_device_path_stack *stack);\nint dev_fill_forward_path_flow(const struct net_device *dev, const u8 *daddr,\n\t\t\t       const struct flow_keys *flow,\n\t\t\t       struct net_device_path_stack *stack);\nint dev_fill_forward_path'
    if old in content:
        content = content.replace(old, new)
        print(f"✅ {nh}: added dev_fill_forward_path_flow declaration")
    else:
        # Try alternative: after __dev_fill_forward_path declaration
        marker = '__dev_fill_forward_path(struct net_device_path_ctx *ctx, const u8 *daddr,'
        if marker in content:
            # Find the end of that declaration
            idx = content.find(marker)
            end = content.find(';', idx) + 1
            decl = '\nint dev_fill_forward_path_flow(const struct net_device *dev, const u8 *daddr,\n\t\t\t       const struct flow_keys *flow,\n\t\t\t       struct net_device_path_stack *stack);'
            content = content[:end] + decl + content[end:]
            print(f"✅ {nh}: added dev_fill_forward_path_flow declaration (alt method)")
        else:
            print(f"⚠️  {nh}: could not find __dev_fill_forward_path to add declaration")
else:
    print(f"ℹ️  {nh}: dev_fill_forward_path_flow already present")

with open(nh, 'w') as f:
    f.write(content)

# --- Fix net/core/dev.c ---
dc = "net/core/dev.c"
with open(dc, 'r') as f:
    content = f.read()

if 'dev_fill_forward_path_flow' not in content:
    # Find the dev_fill_forward_path function and refactor it
    # Pattern: the function that creates ctx and calls __dev_fill_forward_path
    old_func = '''int dev_fill_forward_path(const struct net_device *dev, const u8 *daddr,
\t\t\t  struct net_device_path_stack *stack)
{
\tstruct net_device_path_ctx ctx = {
\t\t.dev\t= dev,
\t};

\treturn __dev_fill_forward_path(&ctx, daddr, stack);
}
EXPORT_SYMBOL_GPL(dev_fill_forward_path);'''

    new_func = '''int dev_fill_forward_path_flow(const struct net_device *dev, const u8 *daddr,
\t\t\t       const struct flow_keys *flow,
\t\t\t       struct net_device_path_stack *stack)
{
\tstruct net_device_path_ctx ctx = {
\t\t.dev\t= dev,
\t\t.flow\t= flow,
\t};

\treturn __dev_fill_forward_path(&ctx, daddr, stack);
}
EXPORT_SYMBOL_GPL(dev_fill_forward_path_flow);

int dev_fill_forward_path(const struct net_device *dev, const u8 *daddr,
\t\t\t  struct net_device_path_stack *stack)
{
\treturn dev_fill_forward_path_flow(dev, daddr, NULL, stack);
}
EXPORT_SYMBOL_GPL(dev_fill_forward_path);'''

    if old_func in content:
        content = content.replace(old_func, new_func)
        print(f"✅ {dc}: refactored dev_fill_forward_path → dev_fill_forward_path_flow")
    else:
        # Try with different whitespace (spaces vs tabs)
        print(f"⚠️  {dc}: exact match failed, trying flexible match...")
        # Find the function by looking for the pattern
        pattern = r'int dev_fill_forward_path\(const struct net_device \*dev, const u8 \*daddr,\s+struct net_device_path_stack \*stack\)\s*\{\s*struct net_device_path_ctx ctx = \{\s*\.dev\s*=\s*dev,\s*\};\s*return __dev_fill_forward_path\(&ctx, daddr, stack\);\s*\}\s*EXPORT_SYMBOL_GPL\(dev_fill_forward_path\);'
        if re.search(pattern, content):
            new_code = '''int dev_fill_forward_path_flow(const struct net_device *dev, const u8 *daddr,
\t\t\t       const struct flow_keys *flow,
\t\t\t       struct net_device_path_stack *stack)
{
\tstruct net_device_path_ctx ctx = {
\t\t.dev\t= dev,
\t\t.flow\t= flow,
\t};

\treturn __dev_fill_forward_path(&ctx, daddr, stack);
}
EXPORT_SYMBOL_GPL(dev_fill_forward_path_flow);

int dev_fill_forward_path(const struct net_device *dev, const u8 *daddr,
\t\t\t  struct net_device_path_stack *stack)
{
\treturn dev_fill_forward_path_flow(dev, daddr, NULL, stack);
}
EXPORT_SYMBOL_GPL(dev_fill_forward_path);'''
            content = re.sub(pattern, new_code, content)
            print(f"✅ {dc}: refactored via regex match")
        else:
            print(f"❌ {dc}: could not find dev_fill_forward_path function to refactor")
            print(f"   Searching for nearby context...")
            idx = content.find('dev_fill_forward_path')
            if idx >= 0:
                print(f"   Found at position {idx}: ...{content[idx:idx+200]}...")
else:
    print(f"ℹ️  {dc}: dev_fill_forward_path_flow already present")

with open(dc, 'w') as f:
    f.write(content)

print("\n=== 9990 generic patch applied via code modification ===")
PYEOF

echo "=== Step 3: Verify ==="
echo "--- netdevice.h ---"
grep -n 'flow_keys\|dev_fill_forward_path_flow\|flow.*flow' include/linux/netdevice.h | grep -v '/\*' | head -5
echo "--- dev.c ---"
grep -n 'dev_fill_forward_path_flow\|EXPORT.*forward_path' net/core/dev.c | head -5
echo "=== Done ==="
