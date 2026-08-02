#!/bin/bash
# ===================================================================
# generate-patches.sh — 从主线 Linux git 仓库生成 DAMON backport 补丁
#
# DAMON (Data Access MONitor) 由 SeongJae Park 开发:
#   - 5.15: DAMON 核心 (mm/damon/, include/linux/damon.h)
#   - 5.16: DAMON_RECLAIM (主动回收)
#   - 6.0+: DAMON_LRU_SORT (LRU 链表优化, 与 MGLRU 协同良好)
#   - 文档: Documentation/admin-guide/mm/damon/
#
# 本脚本流程:
#   1. 浅克隆 mainline linux 仓库 (torvalds) 并加深历史
#   2. 用 git log --grep "DAMON" --author "SeongJae Park" 定位提交
#      (失败则退化为仅 grep "DAMON" / 路径 mm/damon)
#   3. 用 git format-patch -1 --stdout 逐个提取补丁
#   4. 尝试用 sed 适配到 4.19 基线 (best-effort, 实验性)
#   5. 生成 series 文件
#
# 容错: 克隆失败 / 提取失败只输出 warn, 不退出; 最终仍生成 series。
#
# 用法:
#   ./generate-patches.sh [--kernel-tree /path/to/linux] [--output /path]
#
# 补丁默认保存在脚本所在目录 (可用 --output 覆盖)。
# 脚本可独立运行, 不依赖任何外部环境变量。
# ===================================================================
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# 所有日志走 stderr, 保证 stdout 干净
info()  { echo -e "${GREEN}[INFO]${NC} $*" >&2; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*" >&2; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OUTPUT_DIR="$SCRIPT_DIR"
KERNEL_TREE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --kernel-tree) KERNEL_TREE="$2"; shift 2 ;;
        --output)      OUTPUT_DIR="$2"; shift 2 ;;
        -h|--help)
            echo "Usage: $0 [--kernel-tree /path/to/linux] [--output /path]"
            exit 0
            ;;
        *) error "Unknown option: $1"; exit 1 ;;
    esac
done

# 工作目录为脚本所在目录 (输出默认也落在这里)
cd "$SCRIPT_DIR"

LINUX_REPO="https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git"
CLONE_TAG="v6.1"                       # 覆盖 5.15 核心 / 5.16 reclaim / 6.0 lru_sort
DEFAULT_TREE="$SCRIPT_DIR/.linux-mainline"
COMMIT_GREP="DAMON"
AUTHOR_GREP="SeongJae Park"
PATHSPEC="mm/damon include/linux/damon.h"
BASELINE="4.19"
SCAN_RANGE="v5.15..v6.1"               # 仅作参考/日志

info "=== DAMON Backport Patch Generator ==="
info "  baseline : $BASELINE"
info "  repo     : $LINUX_REPO"
info "  grep     : '$COMMIT_GREP' (author: '$AUTHOR_GREP')"
info "  output   : $OUTPUT_DIR"

# ---- 清理上次的输出 ----
rm -f "$OUTPUT_DIR"/*.patch 2>/dev/null || true
rm -f "$OUTPUT_DIR/series" 2>/dev/null || true
rm -rf "$OUTPUT_DIR/adapted" 2>/dev/null || true
mkdir -p "$OUTPUT_DIR/adapted"

# ---- Step 1: 获取 linux 源码树 (浅克隆 + 加深历史) ----
TREE=""
prepare_source() {
    TREE="${KERNEL_TREE:-$DEFAULT_TREE}"

    if [[ -d "$TREE/.git" ]]; then
        info "Using existing kernel tree at $TREE"
        # 尝试加深历史以覆盖 5.15~6.1 (非致命)
        git -C "$TREE" fetch --shallow-since="2020-01-01" origin "$CLONE_TAG" 2>/dev/null \
            || git -C "$TREE" fetch --unshallow 2>/dev/null \
            || warn "Could not deepen history; using local state."
        return 0
    fi

    info "Shallow-cloning linux mainline at '$CLONE_TAG' (this may take a while)..."
    if ! git clone --depth 1 --branch "$CLONE_TAG" --single-branch "$LINUX_REPO" "$TREE" 2>/dev/null; then
        warn "Tagged shallow clone failed; retrying without a specific branch..."
        if ! git clone --depth 1 --no-single-branch "$LINUX_REPO" "$TREE" 2>/dev/null; then
            warn "git clone failed."
            return 1
        fi
    fi

    info "Deepening history (shallow-since 2020-01-01) to locate DAMON commits..."
    git -C "$TREE" fetch --shallow-since="2020-01-01" origin "$CLONE_TAG" 2>/dev/null \
        || git -C "$TREE" fetch --unshallow 2>/dev/null \
        || warn "Could not deepen history; commit search may be incomplete."
    return 0
}

if ! prepare_source; then
    warn "Failed to obtain linux source tree; no patches will be generated."
    : > "$OUTPUT_DIR/series"
    info "Created empty series file."
    exit 0
fi

# ---- Step 2: 定位 DAMON 相关 commit ----
# 策略: author+grep -> grep only -> 路径 mm/damon
info "Searching for DAMON commits (grep: '$COMMIT_GREP', author: '$AUTHOR_GREP')..."

COMMITS=()
while IFS= read -r line; do
    if [[ -n "$line" ]]; then
        COMMITS+=("$line")
    fi
done < <(git -C "$TREE" log \
            --grep="$COMMIT_GREP" \
            --author="$AUTHOR_GREP" \
            --format='%H' \
            --reverse \
            --all 2>/dev/null || true)

if [[ ${#COMMITS[@]} -eq 0 ]]; then
    warn "No commits matched author+grep; retrying with grep only ('$COMMIT_GREP')..."
    while IFS= read -r line; do
        if [[ -n "$line" ]]; then
            COMMITS+=("$line")
        fi
    done < <(git -C "$TREE" log \
                --grep="$COMMIT_GREP" \
                --format='%H' \
                --reverse \
                --all 2>/dev/null || true)
fi

if [[ ${#COMMITS[@]} -eq 0 ]]; then
    warn "No commits matched grep; falling back to pathspec ($PATHSPEC)..."
    while IFS= read -r line; do
        if [[ -n "$line" ]]; then
            COMMITS+=("$line")
        fi
    done < <(git -C "$TREE" log \
                --format='%H' \
                --reverse \
                --all \
                -- mm/damon include/linux/damon.h 2>/dev/null || true)
fi

if [[ ${#COMMITS[@]} -eq 0 ]]; then
    warn "No DAMON commits found in the cloned repository."
    : > "$OUTPUT_DIR/series"
    info "Created empty series file."
    exit 0
fi

info "Found ${#COMMITS[@]} candidate commit(s); extracting patches..."

# ---- Step 3: 用 git format-patch 逐个提取补丁 ----
idx=0
SUCCESS=0
FAILED=0
for c in "${COMMITS[@]}"; do
    idx=$((idx + 1))
    printf -v num '%04d' "$idx"
    short="${c:0:12}"
    out="$OUTPUT_DIR/${num}-damon-${short}.patch"

    if git -C "$TREE" format-patch -1 --stdout "$c" 2>/dev/null > "$out" && [[ -s "$out" ]]; then
        info "  + $(basename "$out") ($(wc -l < "$out") lines)"
        SUCCESS=$((SUCCESS + 1))
    else
        warn "  - failed to extract commit $c"
        rm -f "$out" 2>/dev/null || true
        FAILED=$((FAILED + 1))
    fi
done

# ---- 收集生成的补丁 (排序) ----
PATCHES=()
while IFS= read -r f; do
    PATCHES+=("$f")
done < <(find "$OUTPUT_DIR" -maxdepth 1 -type f -name '*.patch' 2>/dev/null | sort)

if [[ ${#PATCHES[@]} -eq 0 ]]; then
    warn "No patch files were produced."
    : > "$OUTPUT_DIR/series"
    info "Created empty series file."
    exit 0
fi

# ---- Step 4: best-effort 适配到 4.19 基线 ----
info "Adapting patches to $BASELINE baseline (best-effort sed rewriting)..."
warn "Adaptation is naive; manual conflict resolution is REQUIRED before applying."
warn "Note: DAMON_LRU_SORT benefits from MGLRU; apply the mglru series first."

adapt_patch() {
    local src="$1" name dst
    name="$(basename "$src")"
    dst="$OUTPUT_DIR/adapted/$name"

    if cp "$src" "$dst" 2>/dev/null; then
        # 4.19 没有 folio API, 也缺少部分 5.x 基础设施。这里只做少量已知等价
        # 替换以减少噪声, 远不足以让补丁干净 apply, 必须人工处理冲突。
        sed -i -E \
            -e 's/\bfolio_test_lru\b/PageLRU/g' \
            -e 's/\bfolio_set_lru\b/SetPageLRU/g' \
            -e 's/\bfolio_clear_lru\b/ClearPageLRU/g' \
            -e 's/\bfolio_test_clear_lru\b/TestClearPageLRU/g' \
            -e 's/\bfolio_test_set_lru\b/TestSetPageLRU/g' \
            "$dst" 2>/dev/null \
            || warn "  ! sed adaptation error for $name (kept unmodified copy)"
        info "  ~ adapted: $name"
    else
        warn "  ! copy failed for $name; keeping raw patch"
    fi
    return 0
}

for p in "${PATCHES[@]}"; do
    adapt_patch "$p"
done

# ---- Step 5: 生成 series 文件 ----
info "Writing series file..."
{
    echo "# DAMON (Data Access MONitor) backport series for $BASELINE"
    echo "# Source: $LINUX_REPO (grep: '$COMMIT_GREP', author: '$AUTHOR_GREP')"
    echo "# Range reference: $SCAN_RANGE (core 5.15 / reclaim 5.16 / lru_sort 6.0)"
    echo "# Status: experimental - requires manual conflict resolution"
    echo "# Recommended: apply the mglru series first for DAMON_LRU_SORT synergy"
    echo "# Adapted (4.19-targeted) copies are in adapted/"
    echo "#"
    for p in "${PATCHES[@]}"; do
        echo "$(basename "$p")"
    done
} > "$OUTPUT_DIR/series"

# ---- 汇总 ----
echo "" >&2
echo -e "${BLUE}========================================${NC}" >&2
echo -e "${BLUE}  DAMON Patch Generation Summary${NC}" >&2
echo -e "${BLUE}========================================${NC}" >&2
info "Extracted: $SUCCESS patch(es)"
if [[ "$FAILED" -gt 0 ]]; then
    warn "Failed:   $FAILED patch(es)"
    warn "Missing patches need manual cherry-pick from mainline."
fi
info "Adapted copies: $OUTPUT_DIR/adapted/"
info "Patches saved to: $OUTPUT_DIR"
info "Next: run apply-backports.sh --baseline $BASELINE --features damon"
