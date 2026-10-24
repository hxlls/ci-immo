#!/usr/bin/env bash
# ============================================================
# 用法: replace-packages.sh <custom-packages.txt> [包名输出文件]
# 在 openwrt 源码根目录执行；必须在 feeds install 之后、make defconfig 之前。
#
# 清单格式：标识名|仓库地址|分支|子目录(可省略)
#   第一列只是给人看的名字，真正生效的包名以 Makefile 里的 define Package/ 为准。
#
# 这个脚本处理三件事：
#   1) 不假设「仓库根 = 包目录」：clone 后扫描所有含 define Package/ 的 Makefile，
#      把它们所在目录复制进 package/。
#   2) 按【Makefile 里的真实包名】清理 feeds 里的同名包。
#      这是「用自己的改版顶替上游包」必须做的：
#      feeds install 只在 package/feeds/<feed>/<包名> 建符号链接，
#      不删掉它就会出现两个同名包定义，编译直接报 duplicate package。
#   3) 修正 fork 自 feeds 的 luci 包的 include 路径。
#      feed 里的包写的是 include ../../luci.mk（相对 feeds/luci/applications/xxx），
#      复制到 package/ 之后 ../../ 指向源码根，luci.mk 找不到，编译必然失败。
# ============================================================
set -euo pipefail

LIST="${1:?用法: replace-packages.sh <custom-packages.txt> [输出文件]}"
OUTFILE="${2:-$(pwd)/../replaced-pkgs.txt}"

clean() { printf '%s' "${1:-}" | tr -d '\r' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'; }

# 取某个目录 Makefile 里定义的全部真实包名
# define Package/xxx 与 define Package/xxx/install 这类子段都会归到 xxx
pkgs_in_dir() {
  local mk="$1/Makefile"
  [ -f "$mk" ] || return 0
  grep -hoE 'define[[:space:]]+Package/[A-Za-z0-9._+-]+' "$mk" 2>/dev/null \
    | sed -E 's/.*Package\///' | sort -u || true
}

# 修正 luci 包的 luci.mk 引用
fix_luci_include() {
  local dir="$1" mk="$1/Makefile"
  [ -f "$mk" ] || return 0

  grep -qE '^[[:space:]]*include[[:space:]]+.*luci\.mk' "$mk" || return 0

  if [ ! -f feeds/luci/luci.mk ]; then
    echo "::error::源码里找不到 feeds/luci/luci.mk，无法修正 ${mk} 的 include 路径"
    return 1
  fi

  # 已经是 $(TOPDIR)/feeds/luci/luci.mk 这种绝对写法就不用改
  if ! grep -qE '^[[:space:]]*include[[:space:]]+[^[:space:]]*luci\.mk' "$mk"; then
    return 0
  fi

  local before
  before="$(grep -hE '^[[:space:]]*include[[:space:]]+.*luci\.mk' "$mk" | tr '\n' ' ')"
  sed -i -E \
    's#^([[:space:]]*include[[:space:]]+)[^[:space:]]*luci\.mk.*$#\1$(TOPDIR)/feeds/luci/luci.mk#' \
    "$mk"
  local after
  after="$(grep -hE '^[[:space:]]*include[[:space:]]+.*luci\.mk' "$mk" | tr '\n' ' ')"
  echo "     luci.mk 引用: ${before}  ->  ${after}"
}

# 断言：整个 package/ 下不能有第二个文件定义同一个包名
assert_unique() {
  local pkg="$1"
  local hits
  hits="$(find package -name Makefile -type f 2>/dev/null \
          | while IFS= read -r f; do
              if grep -qE "^[[:space:]]*define[[:space:]]+Package/${pkg}([[:space:]]|/|$)" "$f" 2>/dev/null; then
                echo "$f"
              fi
            done)"
  local n
  n="$(printf '%s' "$hits" | grep -c . || true)"
  if [ "${n:-0}" -gt 1 ]; then
    echo "::error::包 ${pkg} 被 ${n} 个 Makefile 重复定义，编译会失败"
    printf '%s\n' "$hits" | sed 's/^/       /'
    return 1
  fi
  return 0
}

if [ ! -f "$LIST" ]; then
  echo "清单不存在，跳过替换: $LIST"
  : > "$OUTFILE"
  exit 0
fi

: > "$OUTFILE"

replace_one() {
  local ident="$1" repo="$2" ref="$3" sub="$4"
  local tmp srcroot dirs d target primary pkgs

  echo "处理 ${ident}  <=  ${repo}  (${ref:-默认分支})"

  tmp="$(mktemp -d)"
  if ! git clone --depth 1 ${ref:+-b "$ref"} "$repo" "$tmp/src" 2>&1 | tail -n 3; then
    echo "::error::克隆失败: ${repo}"
    rm -rf "$tmp"
    return 1
  fi
  srcroot="$(cd "$tmp/src" && pwd)"

  if [ -n "$sub" ]; then
    if [ ! -f "$tmp/src/${sub}/Makefile" ]; then
      echo "::error::${repo} 里没有 ${sub}/Makefile"
      echo "----- 仓库顶层结构 -----"
      ls -1A "$tmp/src" | head -20 || true
      rm -rf "$tmp"
      return 1
    fi
    dirs="$tmp/src/${sub}"
  else
    dirs="$(find "$tmp/src" -name .git -prune -o -name Makefile -print 2>/dev/null \
            | while IFS= read -r f; do
                if grep -qE '^[[:space:]]*define[[:space:]]+Package/' "$f" 2>/dev/null; then
                  dirname "$f"
                fi
              done | sort -u)"
    if [ -z "$dirs" ]; then
      echo "::error::${repo} 里找不到任何含 define Package/ 的 Makefile"
      echo "----- 仓库顶层结构 -----"
      ls -1A "$tmp/src" | head -20 || true
      echo "----- 所有 Makefile -----"
      find "$tmp/src" -name .git -prune -o -name Makefile -print | head -20 || true
      rm -rf "$tmp"
      return 1
    fi
  fi

  while IFS= read -r d; do
    [ -n "$d" ] || continue
    d="$(cd "$d" && pwd)"

    pkgs="$(pkgs_in_dir "$d")"
    if [ -z "$pkgs" ]; then
      echo "  跳过 ${d}：Makefile 里没有 define Package/"
      continue
    fi
    primary="$(printf '%s\n' "$pkgs" | head -n 1)"

    # 单包目录用真实包名做目录名，让 package/<包名> 与 feeds 路径完全对应
    if [ "$(printf '%s\n' "$pkgs" | grep -c .)" -eq 1 ]; then
      target="$primary"
    else
      target="$(basename "$d")"
      echo "  该目录定义多个包: $(printf '%s' "$pkgs" | tr '\n' ' ')"
    fi

    echo "  真实包名: $(printf '%s' "$pkgs" | tr '\n' ' ') -> package/${target}"

    # 按真实包名逐个清理 feeds 里的同名条目（符号链接）和旧目录
    while IFS= read -r p; do
      [ -n "$p" ] || continue
      if ls -d package/feeds/*/"$p" >/dev/null 2>&1; then
        echo "     移除 feeds 同名包: $(ls -d package/feeds/*/"$p" | tr '\n' ' ')"
      fi
      rm -rf package/feeds/*/"$p" 2>/dev/null || true
      rm -rf "package/${p}"
    done <<< "$pkgs"
    rm -rf "package/${target}"

    mkdir -p "package/${target}"
    cp -a "$d/." "package/${target}/"
    rm -rf "package/${target}/.git"

    fix_luci_include "package/${target}"

    # 把真实包名登记下来，供后续校验和 .config 检查使用
    while IFS= read -r p; do
      [ -n "$p" ] || continue
      grep -qxF "$p" "$OUTFILE" || echo "$p" >> "$OUTFILE"
    done <<< "$pkgs"

    assert_unique "$target"
  done <<< "$dirs"

  rm -rf "$tmp"
  return 0
}

count=0
while IFS='|' read -r r_ident r_repo r_ref r_sub || [ -n "${r_ident:-}" ]; do
  ident="$(clean "${r_ident:-}")"
  repo="$(clean "${r_repo:-}")"
  ref="$(clean "${r_ref:-}")"
  sub="$(clean "${r_sub:-}")"

  case "$ident" in
    ''|\#*) continue ;;
  esac

  if [ -z "$repo" ]; then
    echo "  跳过 ${ident}：仓库地址还没填"
    continue
  fi

  replace_one "$ident" "$repo" "$ref" "$sub"
  count=$((count + 1))
done < "$LIST"

echo "共处理 ${count} 个自定义包"
echo "----- 实际替换/加入的包名 -----"
cat "$OUTFILE" 2>/dev/null || true
