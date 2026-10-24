#!/usr/bin/env bash
# ============================================================
# 在 openwrt 源码根目录执行。
#
# 作用：给 subtarget 的内核配置文件补上"没有默认值的新符号"的取值。
#
# 为什么需要这一步：
#   某些机型的 DEVICE_PACKAGES 会引入从未出现过的新内核符号（kconfig
#   标记为 NEW 且无默认值）。本地 make menuconfig 时它会弹出来问一句，
#   人机回答即可；但 CI 没有终端，kconfig 停在
#       (NEW) make[7]: *** [scripts/kconfig/Makefile:85: syncconfig] Error 1
#   外层只报 "ERROR: target/linux failed to build."，看不出真正原因。
#
#   典型例子：ruijie_rg-x60-new-mtkuboot 依赖 kmod-phy-airoha-en8811h，
#   带出 CONFIG_AIR_EN8811H_PHY=m 及它的子选项
#   CONFIG_AIR_EN8811H_PHY_DEBUGFS（6.12 新增、无默认值）。
#
#   提前把取值写进内核配置文件，符号就变成"已知答案"，kconfig 不再询问。
#
# 排查下一次类似问题时这样做：
#   1. 下载 workflow 产物 build-log-<run_id> 里的 kernel-retry.log
#   2. 搜 "(NEW)" 或 "Restart config..." 上方最近的那个符号名
#   3. 把它的取值加到下面的 SYMBOLS 表里重跑
# ============================================================
set -euo pipefail

log() { printf '%s\n' "$*" >&2; }

TARGET="${TARGET_NAME:-mediatek}"

# 表驱动：每个元素是一行完整的 kconfig 取值
SYMBOLS=(
  # ruijie_rg-x60-new-mtkuboot -> kmod-phy-airoha-en8811h（内核 6.12 新增）
  "# CONFIG_AIR_EN8811H_PHY_DEBUGFS is not set"
)

if [ "${#SYMBOLS[@]}" -eq 0 ]; then
  log "无需修补"
  exit 0
fi

# 可能的内核配置文件：subtarget 优先，其次 target
CANDIDATES=()
for kver in 6.12 6.6 6.1; do
  CANDIDATES+=("target/linux/${TARGET}/filogic/config-${kver}")
  CANDIDATES+=("target/linux/${TARGET}/config-${kver}")
done

added=0
skipped=0
found=0
for f in "${CANDIDATES[@]}"; do
  [ -f "$f" ] || continue
  found=$((found + 1))
  for sym in "${SYMBOLS[@]}"; do
    # 取符号名（去掉 "# " 前缀和 " is not set" 后缀）
    name="${sym#\# }"
    name="${name% is not set}"
    name="${name#CONFIG_}"
    if grep -q "${name}" "$f"; then
      skipped=$((skipped + 1))
      continue
    fi
    printf '%s\n' "$sym" >> "$f"
    added=$((added + 1))
    log "  $(basename "$f")：已写入 ${sym}"
  done
done

if [ "$found" -eq 0 ]; then
  log "::warning::没有找到可修补的内核配置文件，请确认路径"
  find target/linux -maxdepth 3 -name 'config-*' -type f 2>/dev/null | head -10 >&2 || true
else
  log "检查 ${found} 个内核配置文件：新增 ${added} 处取值，${skipped} 处已存在"
fi
