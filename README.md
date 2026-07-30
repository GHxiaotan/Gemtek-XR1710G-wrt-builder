# Gemtek XR1710G OpenWrt 固件构建器

基于 YYH2913/openwrt 源码（xr1710g-6.18 分支），注入桥接 offload 补丁，通过 GitHub Actions 自动编译 XR1710G 专用固件。

## 目标

在 XR1710G 路由器上实现 WiFi↔LAN 桥接流量的 PPE 硬件加速，突破 800Mbps WiFi 吞吐限制。

## 背景

XR1710G 使用 Airoha AN7581 SoC + MT7996E WiFi 芯片。当前 ImmortalWrt 开源驱动下，WiFi iperf3 只能跑 ~800Mbps（协商速率 2882Mbps），根因是 PPE 硬件引擎不加速同网段桥接流量（L2B 类型），所有 802.11↔802.3 帧转换走 CPU 单核处理。

## 补丁说明

| 补丁 | 文件 | 作用 |
|------|------|------|
| 675-04 | `patches/675-04-netfilter-nf_flow_table-add-bridge-flowtable-type.patch` | 核心补丁：创建 bridge flowtable 类型，使 nftables 能在 bridge forward hook 捕获桥接流量 |
| 675-05 | `patches/675-05-netfilter-bridge-Add-conntrack-double-vlan-pppoe.patch` | 桥接 conntrack 双层 VLAN/PPPoE 支持 |

补丁来源：OpenWrt PR #24038（chbgdn），已在 AN7581（W1700K）上实测验证 PPE BND 绑定成功。

## GitHub Actions 编译记录

### Run #8（当前）— 2026-07-30
- 状态：编译中
- 修复：完全移除 `make oldconfig`，避免其删除 `.config` 中的 `CONFIG_NF_FLOW_TABLE_BRIDGE=m`

### Run #7 — 2026-07-30 01:44
- 状态：已取消
- 原因：与 #6 相同问题，手动取消

### Run #6 — 2026-07-30 01:03
- 失败步骤：Build firmware
- 错误：`NF_FLOW_TABLE_BRIDGE not found in .config`
- 根因：`make oldconfig` 对新符号回答空行（=N），删除了 `CONFIG_NF_FLOW_TABLE_BRIDGE=m`
- 修复：移除 `make oldconfig`，直接在 `.config` 写入配置

### Run #5 — 2026-07-30 01:01
- 失败步骤：Build firmware
- 错误：同 Run #4

### Run #4 — 2026-07-29 18:34
- 失败步骤：Build firmware
- 错误：`Netfilter flow table bridge module (NF_FLOW_TABLE_BRIDGE) [N/m/?] (NEW)` + `syncconfig Error 1`
- 根因：`make defconfig` 未设置目标设备，默认编译了 `mediatek_filogic` 而非 `airoha_an7581`；内核新选项等待用户输入
- 修复：在 `.config` 中预设 `CONFIG_TARGET_airoha_an7581_DEVICE_gemtek_xr1710g-ubi=y`

### Run #3 — 2026-07-29 18:34
- 失败：自动重试 Run #2 的问题

### Run #2 — 2026-07-29 17:35
- 失败步骤：Build firmware
- 错误：内核 NEW 选项等待交互输入
- 修复：`yes "" | make oldconfig`

### Run #1 — 2026-07-29 17:28
- 失败步骤：Clone YYH2913 source
- 错误：`fatal: could not create work tree dir '/workdir': Permission denied`
- 修复：改用 `$GITHUB_WORKSPACE/openwrt`

## 关键问题总结

| 问题 | 根因 | 解决方案 |
|------|------|---------|
| `/workdir` 权限拒绝 | GitHub Actions 无 root 权限 | 使用 `$GITHUB_WORKSPACE/openwrt` |
| 编译目标错误 | `.config` 未预设目标设备 | defconfig 前写入 `CONFIG_TARGET_airoha_an7581` |
| 内核 NEW 选项等待输入 | `NF_FLOW_TABLE_BRIDGE` 是补丁新增的符号 | 跳过 `make oldconfig`，直接写入 `.config` |
| NF_FLOW_TABLE_BRIDGE 被删除 | `make oldconfig` 对新符号回答 N | **完全移除 `make oldconfig`** |
| 补丁未被 quilt 应用 | 补丁在编译内核时才被 quilt 应用，但 defconfig 阶段就失败 | `.config` 直接写入，让内核编译时自行处理 |

## 固件对比

| 固件 | 基础 | WiFi | 桥接 offload | 状态 |
|------|------|------|------------|------|
| naoki66/ImmortalWrt | ImmortalWrt | ✅ | ❌ | 当前在用 |
| YYH2913/openwrt | OpenWrt | ✅ | ❌ | 有 release |
| genshanxinli/XR1710g-Builder | OpenWrt (W1700K) | ❌ WiFi 不识别 | ✅ 有补丁 | DTS 不匹配 |
| **本项目** | YYH2913 + 补丁 | ✅ | ✅ | 编译中 |

## 技术参考

- OpenWrt PR #24038: https://github.com/openwrt/openwrt/pulls/24038
- OpenW1700k offload 分支: https://github.com/OpenWRT-fanboy/OpenW1700k/tree/offload
- YYH2913 源码: https://github.com/YYH2913/openwrt (xr1710g-6.18)
- naoki66 源码: https://github.com/naoki66/ImmortalWrt-for-Gemtek-XR1710G

## 编译使用

1. Fork 本仓库
2. 在 GitHub Actions 页面手动触发 `Build XR1710G (Minimal Bridge Offload)`
3. 等待编译完成（2-4 小时）
4. 从 Artifacts 下载固件
5. 通过 LuCI 系统升级刷入
