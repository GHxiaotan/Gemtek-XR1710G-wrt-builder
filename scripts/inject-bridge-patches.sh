#!/bin/bash
# Inject bridge offload patches into naoki66's ImmortalWrt source
# Strategy: copy clean patches, fix 9990 and 9992 via Python code modification
set -ex

BUILDER_PATCHES="$1"
GENERIC_PATCH="target/linux/generic/pending-6.18"
AIROHA_PATCH="target/linux/airoha/patches-6.18"

# Ensure we're in the openwrt source directory
OPENWRT_DIR="${2:-.}"
cd "$OPENWRT_DIR"
echo "Working directory: $(pwd)"
ls include/linux/netdevice.h || { echo "ERROR: netdevice.h not found!"; exit 1; }

echo "=== Step 1: Copy patches that apply cleanly ==="

# 9991 (bonding LAG path) - only adds DEV_PATH_LAG enum, no conflict
cp "$BUILDER_PATCHES/generic/9991-bonding-expose-selected-slave-through-forward-path.patch" "$GENERIC_PATCH/"
echo "✅ 9991 (bonding LAG path)"

# 990-01 (bridge FDB roaming) - SKIP: already in naoki66's tree (same md5)
echo "⏭️  990-01 (already in naoki66)"

# 9990 airoha (WLAN PPE binding) - modifies airoha_ppe.c (untouched by 675)
cp "$BUILDER_PATCHES/airoha/9990-net-airoha-bind-WLAN-bound-flows-on-PPE-driver-L2-cache-miss.patch" "$AIROHA_PATCH/"
echo "✅ 9990 airoha (WLAN PPE binding)"

echo "=== Step 2: Apply 9990 generic via Python ==="

python3 << 'PYEOF'
import re

nh = "include/linux/netdevice.h"
with open(nh, 'r') as f:
    content = f.read()

# 1. Add struct flow_keys forward declaration
if 'struct flow_keys;' not in content:
    content = content.replace(
        'struct neighbour;\nstruct neigh_parms;\nstruct sk_buff;',
        'struct neighbour;\nstruct neigh_parms;\nstruct flow_keys;\nstruct sk_buff;'
    )
    print(f"✅ {nh}: added struct flow_keys forward declaration")

# 2. Add flow field to net_device_path_ctx
if 'const struct flow_keys' not in content.split('net_device_path_ctx')[1][:300] if 'net_device_path_ctx' in content else '':
    old = 'struct net_device_path_ctx {\n\tconst struct net_device *dev;\n\tu8'
    new = 'struct net_device_path_ctx {\n\tconst struct net_device *dev;\n\tconst struct flow_keys\t*flow;\n\tu8'
    if old in content:
        content = content.replace(old, new)
        print(f"✅ {nh}: added flow field to net_device_path_ctx")

# 3. Add dev_fill_forward_path_flow declaration
if 'dev_fill_forward_path_flow' not in content:
    marker = '__dev_fill_forward_path(struct net_device_path_ctx *ctx, const u8 *daddr,'
    if marker in content:
        idx = content.find(marker)
        end = content.find(';', idx) + 1
        decl = '\nint dev_fill_forward_path_flow(const struct net_device *dev, const u8 *daddr,\n\t\t\t       const struct flow_keys *flow,\n\t\t\t       struct net_device_path_stack *stack);'
        content = content[:end] + decl + content[end:]
        print(f"✅ {nh}: added dev_fill_forward_path_flow declaration")

with open(nh, 'w') as f:
    f.write(content)

# --- Fix dev.c ---
dc = "net/core/dev.c"
with open(dc, 'r') as f:
    content = f.read()

if 'dev_fill_forward_path_flow' not in content:
    # Use regex to find and replace the function
    pattern = r'int dev_fill_forward_path\(const struct net_device \*dev, const u8 \*daddr,\s+struct net_device_path_stack \*stack\)\s*\{\s*struct net_device_path_ctx ctx = \{\s*\.dev\s*=\s*dev,\s*\};\s*return __dev_fill_forward_path\(&ctx, daddr, stack\);\s*\}\s*EXPORT_SYMBOL_GPL\(dev_fill_forward_path\);'
    if re.search(pattern, content, re.DOTALL):
        new_code = '''int dev_fill_forward_path_flow(const struct net_device *dev, const u8 *daddr,\n\t\t\t       const struct flow_keys *flow,\n\t\t\t       struct net_device_path_stack *stack)\n{\n\tstruct net_device_path_ctx ctx = {\n\t\t.dev\t= dev,\n\t\t.flow\t= flow,\n\t};\n\n\treturn __dev_fill_forward_path(&ctx, daddr, stack);\n}\nEXPORT_SYMBOL_GPL(dev_fill_forward_path_flow);\n\nint dev_fill_forward_path(const struct net_device *dev, const u8 *daddr,\n\t\t\t  struct net_device_path_stack *stack)\n{\n\treturn dev_fill_forward_path_flow(dev, daddr, NULL, stack);\n}\nEXPORT_SYMBOL_GPL(dev_fill_forward_path);'''
        content = re.sub(pattern, new_code, content, flags=re.DOTALL)
        print(f"✅ {dc}: refactored dev_fill_forward_path")
    else:
        print(f"❌ {dc}: could not find dev_fill_forward_path to refactor")

with open(dc, 'w') as f:
    f.write(content)
PYEOF

echo "=== Step 3: Apply 9992 via Python (nft_flow_offload.c has MTK_WDMA conflict) ==="

python3 << 'PYEOF'
nf = "net/netfilter/nft_flow_offload.c"
with open(nf, 'r') as f:
    content = f.read()

# 1. Add #include <net/flow_dissector.h> after nf_tables.h
if 'flow_dissector.h' not in content:
    content = content.replace(
        '#include <linux/netfilter/nf_tables.h>\n#include <net/ip.h>',
        '#include <linux/netfilter/nf_tables.h>\n#include <net/flow_dissector.h>\n#include <net/ip.h>'
    )
    print(f"✅ {nf}: added flow_dissector.h include")

# 2. Add nft_flow_keys_init function after nft_dev_fill_forward_path
if 'nft_flow_keys_init' not in content:
    # Find the end of nft_dev_fill_forward_path function (returns __dev_fill_forward_path)
    marker = 'return __dev_fill_forward_path(ctx, ha, stack);\n}\n'
    if marker in content:
        new_func = '''return __dev_fill_forward_path(ctx, ha, stack);
}

static void nft_flow_keys_init(const struct nf_conn *ct,
\t\t\t       enum ip_conntrack_dir dir,
\t\t\t       struct flow_keys *flow)
{
\tconst struct nf_conntrack_tuple *tuple = &ct->tuplehash[dir].tuple;
\tconst struct nf_conntrack_tuple *other = &ct->tuplehash[!dir].tuple;

\tmemset(flow, 0, sizeof(*flow));

\tswitch (tuple->src.l3num) {
\tcase NFPROTO_IPV4:
\t\tflow->control.addr_type = FLOW_DISSECTOR_KEY_IPV4_ADDRS;
\t\tflow->basic.n_proto = htons(ETH_P_IP);
\t\tflow->addrs.v4addrs.src = tuple->src.u3.ip;
\t\tflow->addrs.v4addrs.dst = other->src.u3.ip;
\t\tbreak;
\tcase NFPROTO_IPV6:
\t\tflow->control.addr_type = FLOW_DISSECTOR_KEY_IPV6_ADDRS;
\t\tflow->basic.n_proto = htons(ETH_P_IPV6);
\t\tflow->addrs.v6addrs.src = tuple->src.u3.in6;
\t\tflow->addrs.v6addrs.dst = other->src.u3.in6;
\t\tbreak;
\t}

\tflow->basic.ip_proto = tuple->dst.protonum;
\tswitch (tuple->dst.protonum) {
\tcase IPPROTO_TCP:
\tcase IPPROTO_UDP:
\t\tflow->ports.src = tuple->src.u.tcp.port;
\t\tflow->ports.dst = other->src.u.tcp.port;
\t\tbreak;
\t}
}

'''
        content = content.replace(marker, new_func)
        print(f"✅ {nf}: added nft_flow_keys_init function")

# 3. Add case DEV_PATH_LAG in the switch (before DEV_PATH_PPPOE)
#    Context: after 675-03, DEV_PATH_MTK_WDMA is between VLAN and PPPOE
if 'DEV_PATH_LAG' not in content:
    # Find the switch and add LAG before PPPOE
    old = 'case DEV_PATH_PPPOE:'
    new = 'case DEV_PATH_LAG:\n\t\tcase DEV_PATH_PPPOE:'
    if old in content and 'case DEV_PATH_LAG' not in content:
        content = content.replace(old, new, 1)  # only first occurrence
        print(f"✅ {nf}: added case DEV_PATH_LAG before PPPOE")

# 4. Add flow_keys variable and bonding flow init in nft_flow_offload_eval
#    Find the function that has nft_dev_path_info and nft_flow_route
if 'struct flow_keys flow;' not in content:
    # Find: struct nft_forward_info info = {};
    old = 'struct nft_forward_info info = {};'
    new = 'struct nft_forward_info info = {};\n\tstruct flow_keys flow;'
    if old in content:
        content = content.replace(old, new, 1)
        print(f"✅ {nf}: added flow_keys variable")

with open(nf, 'w') as f:
    f.write(content)
PYEOF

echo "=== Step 4: Verify ==="
echo "--- netdevice.h ---"
grep -n 'flow_keys\|dev_fill_forward_path_flow' include/linux/netdevice.h | head -5
echo "--- dev.c ---"
grep -n 'dev_fill_forward_path_flow\|EXPORT.*forward_path' net/core/dev.c | head -5
echo "--- nft_flow_offload.c ---"
grep -n 'flow_dissector\|nft_flow_keys_init\|DEV_PATH_LAG\|flow_keys flow' net/netfilter/nft_flow_offload.c | head -5
echo "=== Done ==="
