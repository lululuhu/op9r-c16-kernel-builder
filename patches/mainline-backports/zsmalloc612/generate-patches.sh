#!/bin/bash
# ===================================================================
# generate-patches.sh — 从主线 Linux git 仓库生成 zsmalloc 6.12 backport 补丁
#
# 用法:
#   ./generate-patches.sh [--kernel-tree /path/to/linux-stable] [--all]
#
# --all: 生成全部补丁 (包括 zpdesc 实验性系列)
#        不加 --all 则仅生成 per-size_class lock 补丁 (推荐)
#
# 生成的补丁保存在当前目录下
# ===================================================================
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
KERNEL_TREE=""
GENERATE_ALL=false
OUTPUT_DIR="$SCRIPT_DIR"

while [[ $# -gt 0 ]]; do
    case $1 in
        --kernel-tree) KERNEL_TREE="$2"; shift 2 ;;
        --output) OUTPUT_DIR="$2"; shift 2 ;;
        --all) GENERATE_ALL=true; shift ;;
        *) error "Unknown option: $1"; exit 1 ;;
    esac
done

# ---- 部分 A: per-size_class lock 补丁 ----
declare -a LOCK_PATCH_SUBJECTS=(
    "mm/zsmalloc: change back to per-size_class lock"
    "mm/zsmalloc: remove pool spinlock"
    "mm/zsmalloc: restore per-class lock for size_class"
)

declare -a LOCK_PATCH_FILES=(
    "01-zsmalloc-revert-pool-spinlock.patch"
    "02-zsmalloc-per-size-class-lock.patch"
    "03-zsmalloc-migrate-lock-cleanup.patch"
)

# ---- 部分 B: zpdesc 补丁系列 (21 个) ----
declare -a ZPDESC_PATCH_SUBJECTS=(
    "mm/zsmalloc: add zpdesc memory descriptor"
    "mm/zsmalloc: convert obj_to_page to obj_to_zpdesc"
    "mm/zsmalloc: convert zs_free to use zpdesc"
    "mm/zsmalloc: convert init_zspage to use zpdesc"
    "mm/zsmalloc: convert migrate_zspage to use zpdesc"
    "mm/zsmalloc: convert obj_malloc to use zpdesc"
    "mm/zsmalloc: convert get_first_obj to use zpdesc"
    "mm/zsmalloc: convert zs_map_object to use zpdesc"
    "mm/zsmalloc: convert zs_unmap_object to use zpdesc"
    "mm/zsmalloc: convert zs_compact to use zpdesc"
    "mm/zsmalloc: convert zs_pool_stats to use zpdesc"
    "mm/zsmalloc: convert zs_register_shrinker to use zpdesc"
    "mm/zsmalloc: convert zs_create_pool to use zpdesc"
    "mm/zsmalloc: convert zs_destroy_pool to use zpdesc"
    "mm/zsmalloc: convert zs_shrinker_scan to use zpdesc"
    "mm/zsmalloc: convert zs_page_migrate to use zpdesc"
    "mm/zsmalloc: convert zs_page_isolate to use zpdesc"
    "mm/zsmalloc: convert zs_page_putback to use zpdesc"
    "mm/zsmalloc: use get_first_zpdesc/get_next_zpdesc"
    "mm/zsmalloc: finalize zpdesc conversion"
    "mm/zsmalloc: cleanup after zpdesc conversion"
)

# ---- 部分 C: proper page type ----
declare -a PAGETYPE_PATCH_SUBJECTS=(
    "mm: page_type: zsmalloc: use proper page type"
    "mm: remove page_mapcount_reset for zsmalloc"
)

declare -a PAGETYPE_PATCH_FILES=(
    "25-zsmalloc-proper-page-type.patch"
    "26-zsmalloc-remove-page-mapcount-reset.patch"
)

# ---- 获取或使用已有的 kernel tree ----
if [ -z "$KERNEL_TREE" ]; then
    KERNEL_TREE="$HOME/linux-stable"
    if [ ! -d "$KERNEL_TREE/.git" ]; then
        info "Cloning linux-stable (shallow, tag v6.12)..."
        git clone --depth=1 --branch v6.12 \
            https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git \
            "$KERNEL_TREE"
    else
        info "Using existing kernel tree at $KERNEL_TREE"
    fi
fi

[ -d "$KERNEL_TREE/.git" ] || { error "Not a git repo: $KERNEL_TREE"; exit 1; }

generate_patches() {
    local -n subjects=$1
    local -n files=$2
    local tag=$3
    local count=0
    local failed=0

    for i in "${!subjects[@]}"; do
        local subject="${subjects[$i]}"
        local outfile="${files[$i]}"
        local outpath="$OUTPUT_DIR/$outfile"

        info "Looking for: $subject"

        local commit_hash
        commit_hash=$(git log --grep="$subject" --format="%H" -1 "$tag" 2>/dev/null || true)

        if [ -z "$commit_hash" ]; then
            commit_hash=$(git log --grep="$subject" --format="%H" -1 HEAD 2>/dev/null || true)
        fi

        if [ -z "$commit_hash" ]; then
            warn "  -> Commit not found, creating placeholder"
            echo "# PATCH NOT FOUND: $subject" > "$outpath"
            echo "# Generate manually from kernel.org git" >> "$outpath"
            ((failed++))
            continue
        fi

        info "  -> Found: ${commit_hash:0:12}"
        git format-patch -1 "$commit_hash" --stdout > "$outpath"

        if [ -s "$outpath" ]; then
            info "  -> Generated: $outfile ($(wc -l < "$outpath") lines)"
            ((count++))
        else
            warn "  -> Empty patch"
            rm -f "$outpath"
            ((failed++))
        fi
    done

    echo "$count $failed"
}

# ---- 生成补丁 ----
cd "$KERNEL_TREE"

SUCCESS=0
FAILED=0

echo -e "${BLUE}=== 部分 A: per-size_class lock (推荐) ===${NC}"
result=$(generate_patches LOCK_PATCH_SUBJECTS LOCK_PATCH_FILES v6.12)
SUCCESS=$((SUCCESS + ${result%% *}))
FAILED=$((FAILED + ${result##* }))

if [ "$GENERATE_ALL" = true ]; then
    echo ""
    echo -e "${BLUE}=== 部分 B: zpdesc 内存描述符 (实验性) ===${NC}"

    declare -a ZPDESC_FILES=()
    for i in "${!ZPDESC_PATCH_SUBJECTS[@]}"; do
        num=$((i + 4))
        ZPDESC_FILES+=("$(printf '%02d' $num)-zsmalloc-zpdesc-$((${i} + 1)).patch")
    done

    result=$(generate_patches ZPDESC_PATCH_SUBJECTS ZPDESC_FILES v6.12)
    SUCCESS=$((SUCCESS + ${result%% *}))
    FAILED=$((FAILED + ${result##* }))

    echo ""
    echo -e "${BLUE}=== 部分 C: proper page type (可选) ===${NC}"
    result=$(generate_patches PAGETYPE_PATCH_SUBJECTS PAGETYPE_PATCH_FILES v6.12)
    SUCCESS=$((SUCCESS + ${result%% *}))
    FAILED=$((FAILED + ${result##* }))
else
    info "Skipping zpdesc and page_type patches (use --all to generate)"
    info "zpdesc series is experimental and only for 5.10 baseline"
fi

# ---- 汇总 ----
echo ""
echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}  zsmalloc 6.12 Patch Generation Summary${NC}"
echo -e "${BLUE}========================================${NC}"
info "Generated: $SUCCESS patches"
if [ "$FAILED" -gt 0 ]; then
    warn "Failed:   $FAILED patches"
    warn "Missing patches need manual generation"
fi
echo ""
info "Patches saved to: $OUTPUT_DIR"
info "Next: run apply-backports.sh --baseline 5.10 --features zsmalloc612"
echo ""
if [ "$GENERATE_ALL" = false ]; then
    info "Tip: run with --all to generate experimental zpdesc patches (21 patches)"
    info "     zpdesc is HIGH RISK and only for 5.10 baseline"
fi
