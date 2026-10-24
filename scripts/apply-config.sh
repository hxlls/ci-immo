#!/usr/bin/env bash
# ============================================================
# 用法一（生成）：
#   apply-config.sh <基础config> <黑名单> > final.config
#   清洗 target 行 + 禁用黑名单包，结果输出到 stdout
#
# 用法二（校验，defconfig 之后跑）：
#   apply-config.sh --check <生成好的.config> <黑名单>
#   检查黑名单里的包有没有被别的包 select 回来
#
# 黑名单每行的两种写法：
#   1) 包名        精确禁用，例如 luci-app-tlink
#                  也可以直接写符号名 CONFIG_PACKAGE_xxx
#   2) regex:模式  正则禁用所有匹配的符号，例如 regex:.*gecoos.*
#                  用于一个功能对应多个包（主包 + 依赖 + 内核模块）的情况
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

# 把黑名单展开成一串要禁用的符号
#   $1 = 用来展开正则的源文件（生成模式传当前 config，校验模式传最终 .config）
emit_symbols() {
  local src="$1" raw line pat hit
  [ -f "$BLACKLIST" ] || return 0
  while IFS= read -r raw || [ -n "${raw:-}" ]; do
    line="$(trim "${raw:-}")"
    [ -n "$line" ] || continue
    if is_comment "$line"; then continue; fi
    case "$line" in
      regex:*)
        pat="${line#regex:}"
        hit="$(grep -oE '^CONFIG_[A-Za-z0-9_.+-]+' "$src" 2>/dev/null | sort -u | grep -E "$pat" || true)"
        if [ -z "$hit" ]; then
          printf '::warning::黑名单正则 %s 没有匹配到任何符号\n' "$pat" >&2
        fi
        printf '%s\n' "$hit" | grep -v '^$' || true
        ;;
      *)
        sym_of "$line"
        ;;
    esac
  done < "$BLACKLIST"
}

# ---------------- 校验模式 ----------------
if [ "${1:-}" = "--check" ]; then
  CONF="${2:?用法: apply-config.sh --check <config> <黑名单>}"
  BLACKLIST="${3:-/dev/null}"
  bad=0
  SYMS="$(mktemp)"
  trap 'rm -f "$SYMS"' EXIT
  if [ -f "$CONF" ]; then
    emit_symbols "$CONF" | sort -u > "$SYMS"
    while IFS= read -r sym; do
      [ -n "$sym" ] || continue
      if grep -qxF "${sym}=y" "$CONF" 2>/dev/null; then
        printf '::warning::%s 在 defconfig 后仍被开启，可能有别的包 select 了它\n' "$sym"
        bad=$((bad + 1))
      fi
    done < "$SYMS"
  fi
  printf '仍被开启的黑名单包数量: %d\n' "$bad"
  exit 0
fi

# ---------------- 生成模式 ----------------
BASE="${1:?用法: apply-config.sh <基础config> <黑名单>}"
BLACKLIST="${2:-/dev/null}"
OUT="$(mktemp)"
TMP="$(mktemp)"
SYMS="$(mktemp)"
trap 'rm -f "$OUT" "$TMP" "$SYMS"' EXIT

if [ -f "$BASE" ]; then
  cp "$BASE" "$OUT"
else
  printf '::warning::基础配置不存在: %s，将使用空配置\n' "$BASE" >&2
  : > "$OUT"
fi

# 1. 清掉 base 里的「平台 / subtarget / profile / 设备」选择行
#    这些必须由 gen-target-config.sh 按 56 个机型的扫描结果重新生成。
#
#    ⚠️ 不能整段删 ^CONFIG_TARGET_：
#       CONFIG_TARGET_ROOTFS_PARTSIZE=160（分区大小）
#       CONFIG_TARGET_SQUASHFS_*、PREINIT_*、IMAGES_* 都是镜像参数，
#       删掉会退回默认值，导致固件分区和串口预配置跟 228 不一致。
TARGET_NAME="${TARGET_NAME:-mediatek}"
grep -vE '^(# )?CONFIG_TARGET_(BOARD|SUBTARGET|SUFFIX|PROFILE|MULTI_PROFILE|ALL_PROFILES|PER_DEVICE_ROOTFS|DEVICE_)' \
  "$OUT" > "$TMP" || true
mv "$TMP" "$OUT"
grep -vE "^(# )?CONFIG_TARGET_${TARGET_NAME}(=|_| )" "$OUT" > "$TMP" || true
mv "$TMP" "$OUT"
printf '已移除平台/设备/profile 行，镜像参数（分区大小等）保留\n' >&2

# 2. 先把黑名单展开成确定的符号清单（正则基于清洗后的 base 展开）
#    必须先落盘再循环：循环体在改写 OUT，边展开边改会漏掉最后几条
if [ -f "$BLACKLIST" ]; then
  emit_symbols "$OUT" | sort -u > "$SYMS"
  N="$(grep -c . "$SYMS" || true)"
  printf '黑名单展开为 %s 个符号\n' "${N:-0}" >&2

  while IFS= read -r sym; do
    [ -n "$sym" ] || continue
    # 用 index() 做精确前缀匹配，避免包名里的 . + - 被当成正则；
    # 同时删掉可能已存在的同名 "# ... is not set"，避免重复行
    awk -v s="$sym" 'index($0, s "=") != 1 && $0 != "# " s " is not set"' "$OUT" > "$TMP"
    mv "$TMP" "$OUT"
    printf '# %s is not set\n' "$sym" >> "$OUT"
    printf '  已禁用 %s\n' "$sym" >&2
  done < "$SYMS"
else
  printf '::warning::黑名单文件不存在: %s\n' "$BLACKLIST" >&2
fi

cat "$OUT"
