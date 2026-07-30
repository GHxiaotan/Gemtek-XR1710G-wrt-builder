#!/bin/bash
# Fix XR1710G DTS: add missing PCIe configuration from naoki66's gemtek DTS
# NOTE: Only use reset constants available in YYH's kernel tree (EN7581_PCIE0/1_RST)
#       EN7581_PCIC_PERSTOUT0/1_RST are NOT available in YYH's tree - omit them
set -ex

DTS="target/linux/airoha/dts/an7581-xr1710g-ubi.dts"

echo "=== Before patch ==="
grep -n 'pcie0\|pcie1\|num-lanes\|airoha,scu\|reg-names' $DTS | head -10

python3 << 'PYEOF'
dts_file = "target/linux/airoha/dts/an7581-xr1710g-ubi.dts"
with open(dts_file, 'r') as f:
    content = f.read()

# Find &pcie0 block and add missing properties after "status = okay"
old = '&pcie0 {\n\tstatus = "okay";\n\n\tairoha,x2-mode;'

new = '''&pcie0 {
\tstatus = "okay";

\treg = <0x0 0x1fc00000 0x0 0x1670>,
\t      <0x0 0x1fc20000 0x0 0x1670>;

\treg-names = "pcie-mac", "sec-pcie-mac";

\tresets = <&scuclk EN7581_PCIE0_RST>,
\t\t <&scuclk EN7581_PCIE1_RST>;

\treset-names = "phy-lane0",
\t\t      "phy-lane1";

\tnum-lanes = <2>;

\tairoha,scu = <&scuclk>;
\tairoha,x2-mode;'''

content = content.replace(old, new)

# Add &pcie1 disabled node before &pcie2 if missing
if '&pcie1' not in content:
    content = content.replace(
        '&pcie2 {',
        '&pcie1 {\n\tstatus = "disabled";\n};\n\n&pcie2 {'
    )

with open(dts_file, 'w') as f:
    f.write(content)

print("DTS patched successfully")
PYEOF

echo "=== After patch ==="
grep -n 'pcie0\|pcie1\|num-lanes\|airoha,scu\|reg-names' $DTS | head -15
