#!/usr/bin/env bash
# ============================================================
# 用法一（生成）：
#   apply-config.sh <基础config> <黑名单> > final.config
#   清洗 target 行 + 禁用黑名单包，结果输出到 stdout
#
# 用法二（校验，defconfig 之后跑）：
#   apply-config.sh --check <生成好的.config> <黑名单>
#   检查黑名单里的包有没有被别的包 select 回来
# ============================================================
set -euo pipefail

trim() {
  printf '%s' "$1" | tr -d '\r' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'
}

sym_of() {
  case "$1" in
    CONFIG_*) printf '%s' "$1" ;;
    *) printf 'CONFIG_PACKAGE_%s' "$1" ;;
  esac
}

is_comment() {
  case "$1" in \#*) return 0 ;; *) return 1 ;; esac
}

# ---------------- 校验模式 ----------------
if [ "${1:-}" = "--check" ]; then
  CONF="${2:?用法: apply-config.sh --check <config> <黑名单>}"
  BL="${3:-/dev/null}"
  bad=0
  if [ -f "$BL" ]; then
    while IFS= read -r raw || [ -n "${raw:-}" ]; do
      line="$(trim "${raw:-}")"
      [ -n "$line" ] || continue
      if is_comment "$line"; then continue; fi
      sym="$(sym_of "$line")"
      if grep -qE "^${sym}=y" "$CONF" 2>/dev/null; then
        printf '::warning::%s 在 defconfig 后仍被开启，可能有别的包 select 了它\n' "$sym"
        bad=$((bad + 1))
      fi
    done < "$BL"
  fi
  printf '仍被开启的黑名单包数量: %d\n' "$bad"
  exit 0
fi

# ---------------- 生成模式 ----------------
BASE="${1:?用法: apply-config.sh <基础config> <黑名单>}"
BLACKLIST="${2:-/dev/null}"
OUT="$(mktemp)"
TMP="$(mktemp)"
trap 'rm -f "$OUT" "$TMP"' EXIT

if [ -f "$BASE" ]; then
  cp "$BASE" "$OUT"
else
  printf '::warning::基础配置不存在: %s，将使用空配置\n' "$BASE" >&2
  : > "$OUT"
fi

# 1. 清掉 base 里的 target / device 相关行
#    - CONFIG_TARGET_DEVICE_*（含 DEVICE_PACKAGES_*）会覆盖设备专属包，
#      一旦是空字符串就会让固件丢无线驱动，必须由 gen-target-config.sh 统一生成
#    - 平台行、profile 行同理，避免和扫描结果打架
grep -vE '^CONFIG_TARGET_(DEVICE|mediatek|MULTI_PROFILE|PROFILE|ALL_PROFILES|PER_DEVICE_ROOTFS)' "$OUT" > "$TMP" || true
mv "$TMP" "$OUT"
printf '已移除 base 中的 target/device 行\n' >&2

# 2. 套用黑名单
if [ -f "$BLACKLIST" ]; then
  while IFS= read -r raw || [ -n "${raw:-}" ]; do
    line="$(trim "${raw:-}")"
    [ -n "$line" ] || continue
    if is_comment "$line"; then continue; fi
    sym="$(sym_of "$line")"
    grep -vE "^${sym}=" "$OUT" > "$TMP" || true
    mv "$TMP" "$OUT"
    printf '# %s is not set\n' "$sym" >> "$OUT"
    printf '  已禁用 %s\n' "$sym" >&2
  done < "$BLACKLIST"
else
  printf '::warning::黑名单文件不存在: %s\n' "$BLACKLIST" >&2
fi

cat "$OUT"
