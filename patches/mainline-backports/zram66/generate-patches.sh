#!/bin/bash
# ===================================================================
# generate-patches.sh — 从主线 Linux git 仓库生成 zram 6.6 backport 补丁
#
# 用法:
#   ./generate-patches.sh [--kernel-tree /path/to/linux-stable]
#
# 如果没有指定 --kernel-tree，会 clone 一份 linux-stable (浅克隆)
#
# 生成的补丁保存在当前目录下 (zram66/ 子目录)
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
OUTPUT_DIR="$SCRIPT_DIR"

while [[ $# -gt 0 ]]; do
    case $1 in
        --kernel-tree) KERNEL_TREE="$2"; shift 2 ;;
        --output) OUTPUT_DIR="$2"; shift 2 ;;
        *) error "Unknown option: $1"; exit 1 ;;
    esac
done

# ---- zram 6.6 多压缩流补丁系列 ----
# 这些是主线 v6.6-rc1 到 v6.6 期间合入的 zram recompression 补丁
# 补丁标题 (用于 git log --grep 匹配)
declare -a PATCH_SUBJECTS=(
    "zram: Preparation for multi-zcomp support"
    "zram: Add recompression algorithm sysfs knob"
    "zram: Factor out WB and non-WB zram read functions"
    "zram: Introduce recompress sysfs knob"
    "zram: Add recompression algorithm choice to Kconfig"
    "zram: Add recompress flag to read_block_state"
)

# 输出文件名
declare -a PATCH_FILES=(
    "01-zram-preparation-multi-zcomp.patch"
    "02-zram-recomp-algorithm-sysfs.patch"
    "03-zram-factor-out-wb-read.patch"
    "04-zram-recompress-sysfs.patch"
    "05-zram-kconfig-recomp-choice.patch"
    "06-zram-recompress-block-state.patch"
)

# ---- 获取或使用已有的 kernel tree ----
if [ -z "$KERNEL_TREE" ]; then
    KERNEL_TREE="$HOME/linux-stable"
    if [ ! -d "$KERNEL_TREE/.git" ]; then
        info "Cloning linux-stable (shallow, tag v6.6)..."
        git clone --depth=1 --branch v6.6 \
            https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git \
            "$KERNEL_TREE"
    else
        info "Using existing kernel tree at $KERNEL_TREE"
    fi
fi

[ -d "$KERNEL_TREE/.git" ] || { error "Not a git repo: $KERNEL_TREE"; exit 1; }

# ---- 生成补丁 ----
info "Generating zram 6.6 backport patches from $KERNEL_TREE (tag v6.6)"

cd "$KERNEL_TREE"

SUCCESS=0
FAILED=0

for i in "${!PATCH_SUBJECTS[@]}"; do
    subject="${PATCH_SUBJECTS[$i]}"
    outfile="${PATCH_FILES[$i]}"
    outpath="$OUTPUT_DIR/$outfile"

    info "Looking for: $subject"

    # 通过 git log --grep 查找提交
    commit_hash=$(git log --grep="$subject" --format="%H" -1 v6.6 2>/dev/null || true)

    if [ -z "$commit_hash" ]; then
        # 尝试不带 v6.6 tag 限制
        commit_hash=$(git log --grep="$subject" --format="%H" -1 HEAD 2>/dev/null || true)
    fi

    if [ -z "$commit_hash" ]; then
        warn "  -> Commit not found, skipping"
        echo "# PATCH NOT FOUND: $subject" > "$outpath"
        ((FAILED++))
        continue
    fi

    info "  -> Found: ${commit_hash:0:12}"

    # 生成补丁文件
    git format-patch -1 "$commit_hash" --stdout > "$outpath"

    if [ -s "$outpath" ]; then
        info "  -> Generated: $outfile ($(wc -l < "$outpath") lines)"
        ((SUCCESS++))
    else
        warn "  -> Empty patch, skipping"
        rm -f "$outpath"
        ((FAILED++))
    fi
done

# ---- 额外: 文档补丁 ----
info "Looking for documentation patch..."
DOC_COMMIT=$(git log --grep="documentation.*recompression" --format="%H" -1 v6.6 2>/dev/null || true)
if [ -n "$DOC_COMMIT" ]; then
    git format-patch -1 "$DOC_COMMIT" --stdout > "$OUTPUT_DIR/07-zram-recompress-docs.patch"
    info "  -> Generated: 07-zram-recompress-docs.patch"
    ((SUCCESS++))
else
    warn "  -> Documentation commit not found"
    echo "# Documentation patch not auto-generated" > "$OUTPUT_DIR/07-zram-recompress-docs.patch"
    ((FAILED++))
fi

# ---- 拼写修正补丁 (可选) ----
info "Looking for typo fix patch..."
TYPO_COMMIT=$(git log --grep="zram.*correct typos" --format="%H" -1 v6.6 2>/dev/null || true)
if [ -n "$TYPO_COMMIT" ]; then
    git format-patch -1 "$TYPO_COMMIT" --stdout > "$OUTPUT_DIR/08-zram-typos.patch"
    info "  -> Generated: 08-zram-typos.patch"
    ((SUCCESS++))
else
    warn "  -> Typo fix commit not found (non-critical)"
    echo "# Optional: typo fixes not found" > "$OUTPUT_DIR/08-zram-typos.patch"
fi

# ---- 汇总 ----
echo ""
echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}  zram 6.6 Patch Generation Summary${NC}"
echo -e "${BLUE}========================================${NC}"
info "Generated: $SUCCESS patches"
if [ "$FAILED" -gt 0 ]; then
    warn "Failed:   $FAILED patches"
    warn "Missing patches need manual generation or cherry-pick"
fi
echo ""
info "Patches saved to: $OUTPUT_DIR"
info "Next: run apply-backports.sh --baseline 5.10 --features zram66"
