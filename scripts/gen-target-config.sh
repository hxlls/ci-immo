#!/usr/bin/env bash
# ============================================================
# 在 openwrt 源码根目录执行。
#
# 作用：扫描 target/linux/<target>/image/*.mk 里所有 define Device/，
#      按芯片型号（默认 mt7986）筛选，输出 CONFIG_TARGET_* 行到 stdout，
#      诊断信息走 stderr。
#
# 为什么不能只看一个 .mk：
#   这个源码里 mediatek 平台没有 mt7986.mk，设备分散在
#     image/filogic.mk      （205 个块，其中 49 个是 MT7986）
#     image/filogic-ext.mk  （19 个块，其中 7 个是 MT7986）
#   只读排序在前的 filogic-ext.mk 会漏掉 49 个设备。
#
# 为什么按 DEVICE_DTS 判断芯片：
#   设备名里没有 highpower 之类的字样，"支持 7986" 的准确依据是
#   DEVICE_DTS 的前缀（mt7986a-* / mt7986b-*）。
# ============================================================
set -euo pipefail

log() { printf '%s\n' "$*" >&2; }

TARGET="${TARGET_NAME:-mediatek}"
CHIP_FILTER="${CHIP_FILTER:-mt7986}"
DEVICE_FILTER="${DEVICE_FILTER:-}"
DEVICE_SLICE="${DEVICE_SLICE:-all}"

TDIR="target/linux/${TARGET}"
if [ ! -d "$TDIR" ]; then
  log "::error::找不到 ${TDIR}"
  ls -1 target/linux 2>/dev/null || true
  exit 1
fi

# ---------- 1. 已知 subtarget 目录 ----------
mapfile -t SUBDIRS < <(find "$TDIR" -maxdepth 1 -mindepth 1 -type d ! -name image \
                       ! -name base-files ! -name 'dts*' ! -name 'files*' \
                       ! -name 'patches*' -printf '%f\n' 2>/dev/null | sort)
log "subtarget 目录: ${SUBDIRS[*]:-（无）}"

# mk 文件名 -> subtarget
subtarget_of() {
  local base="$1" s
  for s in "${SUBDIRS[@]:-}"; do
    [ "$base" = "$s" ] && { printf '%s' "$s"; return 0; }
  done
  # filogic-ext -> filogic 这种前缀归属
  for s in "${SUBDIRS[@]:-}"; do
    case "$base" in "$s"-*) printf '%s' "$s"; return 0 ;; esac
  done
  return 1
}

# ---------- 2. 解析所有 .mk ----------
# 输出：dev<TAB>dts<TAB>subtarget
parse_all() {
  local mk base sub
  for mk in "$TDIR"/image/*.mk; do
    [ -f "$mk" ] || continue
    base="$(basename "$mk" .mk)"
    if ! sub="$(subtarget_of "$base")"; then
      log "  跳过 ${mk}：找不到对应的 subtarget"
      continue
    fi
    log "  解析 $(basename "$mk")  ->  subtarget ${sub}"
    awk -v SUB="$sub" '
      /^define[ \t]+Device\// {
        name=$0
        sub(/^define[ \t]+Device\//, "", name)
        sub(/[^A-Za-z0-9_.+-].*$/, "", name)
        inblk=1; dts=""; next
      }
      inblk && /^[ \t]*DEVICE_DTS[ \t]*:?=/ {
        line=$0
        sub(/^[ \t]*DEVICE_DTS[ \t]*:?=[ \t]*/, "", line)
        sub(/[ \t].*$/, "", line)
        dts=line
      }
      inblk && /^endef/ {
        if (name != "" && dts != "") print name "\t" dts "\t" SUB
        inblk=0; next
      }
    ' "$mk"
  done
}

ALL_ROWS="$(parse_all)"
if [ -z "$ALL_ROWS" ]; then
  log "::error::没有解析到任何带 DEVICE_DTS 的设备定义"
  ls -1 "$TDIR"/image/*.mk 2>/dev/null || true
  exit 1
fi

TOTAL="$(printf '%s\n' "$ALL_ROWS" | grep -c . || true)"
log "共解析到 ${TOTAL} 个设备定义（含所有芯片）"

# ---------- 3. 按芯片筛选 ----------
CHIP_ROWS="$(printf '%s\n' "$ALL_ROWS" | awk -F'\t' -v c="$CHIP_FILTER" 'tolower($2) ~ tolower(c)')"
CHIP_N="$(printf '%s' "$CHIP_ROWS" | grep -c . || true)"
if [ "${CHIP_N:-0}" -eq 0 ]; then
  log "::error::没有任何设备的 DEVICE_DTS 含 '${CHIP_FILTER}'"
  log "----- 该平台实际出现的芯片前缀 -----"
  printf '%s\n' "$ALL_ROWS" | awk -F'\t' '{print $2}' | sed -E 's/^([a-z0-9]+)-.*/\1/' | sort | uniq -c | sort -rn | sed 's/^/  /' >&2
  exit 1
fi
log "DEVICE_DTS 含 '${CHIP_FILTER}' 的设备: ${CHIP_N} 个"

# ---------- 4. 附加名字过滤（可选）----------
if [ -n "$DEVICE_FILTER" ] && [ "$DEVICE_FILTER" != ".*" ]; then
  CHIP_ROWS="$(printf '%s\n' "$CHIP_ROWS" | awk -F'\t' -v f="$DEVICE_FILTER" '$1 ~ f')"
  N="$(printf '%s' "$CHIP_ROWS" | grep -c . || true)"
  if [ "${N:-0}" -eq 0 ]; then
    log "::error::机型名过滤 '${DEVICE_FILTER}' 在 ${CHIP_N} 个设备里没有匹配"
    log "----- 可选机型 -----"
    printf '%s\n' "$CHIP_ROWS" | awk -F'\t' '{print "  " $1}' >&2 || true
    exit 1
  fi
  log "机型名过滤 '${DEVICE_FILTER}' 后剩 ${N} 个"
fi

# ---------- 5. 分批（可选，格式 1/3 表示第 1 批共 3 批）----------
MATCHED="$(printf '%s\n' "$CHIP_ROWS" | awk -F'\t' '{print $1 "\t" $3}' | sort -u)"
if [ "$DEVICE_SLICE" != "all" ]; then
  if [[ "$DEVICE_SLICE" =~ ^([0-9]+)/([0-9]+)$ ]]; then
    n="${BASH_REMATCH[1]}"; m="${BASH_REMATCH[2]}"
    if [ "$n" -lt 1 ] || [ "$n" -gt "$m" ]; then
      log "::error::DEVICE_SLICE=${DEVICE_SLICE} 无效，应是 1/${m} 到 ${m}/${m}"
      exit 1
    fi
    MATCHED="$(printf '%s\n' "$MATCHED" | awk -v n="$n" -v m="$m" '((NR-1)%m)+1==n')"
    log "分批：第 ${n}/${m} 批"
  else
    log "::warning::DEVICE_SLICE='${DEVICE_SLICE}' 无法识别（要写 1/3 这种），按全量处理"
  fi
fi

HIT="$(printf '%s' "$MATCHED" | grep -c . || true)"
log "本次将编译 ${HIT} 个设备："
printf '%s\n' "$MATCHED" | awk -F'\t' '{printf "  * %-45s [%s]\n", $1, $2}' >&2

# ---------- 6. 输出 config ----------
SUBS="$(printf '%s\n' "$MATCHED" | awk -F'\t' '{print $2}' | sort -u)"
echo "CONFIG_TARGET_${TARGET}=y"
while IFS= read -r s; do
  [ -n "$s" ] || continue
  echo "CONFIG_TARGET_${TARGET}_${s}=y"
done <<< "$SUBS"
echo "CONFIG_TARGET_MULTI_PROFILE=y"
echo "CONFIG_TARGET_PER_DEVICE_ROOTFS=y"
while IFS=$'\t' read -r dev sub; do
  [ -n "${dev:-}" ] || continue
  echo "CONFIG_TARGET_${TARGET}_${sub}_DEVICE_${dev}=y"
done <<< "$MATCHED"
