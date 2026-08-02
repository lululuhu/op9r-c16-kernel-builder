#!/bin/bash
# ===================================================================
# generate-patches.sh — 从主线 Linux git 仓库生成 PSI per-cgroup backport 补丁
#
# PSI (Pressure Stall Information) 由 Johannes Weiner 开发, 核心于主线 4.20 合入,
# per-cgroup 跟踪 / trigger / cgroup v1 支持在 5.x 逐步完善。本脚本以 v5.10 为源,
# 回移植到 4.19 基线 (vanilla 4.19 默认不含 PSI, 可能需一并回移植核心基础设施)。
# 主要涉及文件: kernel/sched/psi.c, include/linux/psi.h, kernel/sched/psi.h,
#               kernel/cgroup/cgroup.c, Documentation/accounting/psi.rst
#
# 本脚本流程:
#   1. 浅克隆 mainline linux 仓库 (torvalds) 分支 v5.10 并加深历史
#   2. 用 git log --author "Johannes Weiner" + grep "psi"/"cgroup"/"pressure stall" 定位提交
#   3. 用 git format-patch -1 --stdout 逐个提取补丁
#   4. 生成 series 文件
#
# 容错: 克隆失败 / 提取失败只输出 warn, 不退出; 最终仍生成 series。
#
# 用法:
#   ./generate-patches.sh [--kernel-tree /path/to/linux] [--output /path]
#
# 补丁默认保存在脚本所在目录下的 patches/ 子目录 (可用 --output 覆盖)。
# series 文件默认位于脚本所在目录 (与 rcu-lazy 等现有脚本布局一致)。
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
OUTPUT_DIR="$SCRIPT_DIR/patches"
SERIES_FILE="$SCRIPT_DIR/series"
KERNEL_TREE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --kernel-tree) KERNEL_TREE="$2"; shift 2 ;;
        --output)      OUTPUT_DIR="$2"; SERIES_FILE="$OUTPUT_DIR/series"; shift 2 ;;
        -h|--help)
            echo "Usage: $0 [--kernel-tree /path/to/linux] [--output /path]"
            exit 0
            ;;
        *) error "Unknown option: $1"; exit 1 ;;
    esac
done

# 工作目录为脚本所在目录
cd "$SCRIPT_DIR"

# ---- 配置 ----
LINUX_REPO="https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git"
BRANCH="v5.10"
BASELINE="4.19"
AUTHOR_GREP="Johannes Weiner"
# 搜索关键词: psi / cgroup / pressure stall (git 多个 --grep 默认为 OR, 配合 --author 取交集)
KEYWORDS=("psi" "cgroup" "pressure stall")
# 加深历史到 PSI 引入之时 (核心于 2018-08 合入 4.20), 保证覆盖 4.20 -> 5.10 的相关提交
SHALLOW_SINCE="2018-06-01"

info "=== PSI per-cgroup Backport Patch Generator ==="
info "  baseline : $BASELINE"
info "  repo     : $LINUX_REPO"
info "  branch   : $BRANCH"
info "  author   : '$AUTHOR_GREP'"
info "  keywords : ${KEYWORDS[*]}"
info "  output   : $OUTPUT_DIR"
info "  series   : $SERIES_FILE"

# ---- 创建输出目录, 清理上次的输出 ----
mkdir -p "$OUTPUT_DIR"
rm -f "$OUTPUT_DIR"/*.patch 2>/dev/null || true
rm -f "$SERIES_FILE" 2>/dev/null || true

# ---- 创建临时目录 (脚本末尾通过 trap 清理) ----
TEMP_DIR="$(mktemp -d)"
cleanup() {
    if [[ -n "${TEMP_DIR:-}" && -d "$TEMP_DIR" ]]; then
        info "Cleaning up temporary directory: $TEMP_DIR"
        rm -rf "$TEMP_DIR"
    fi
}
trap cleanup EXIT

# ---- Step 1: 获取 linux 源码树 (浅克隆 + 加深历史) ----
TREE=""
prepare_source() {
    if [[ -n "$KERNEL_TREE" ]]; then
        TREE="$KERNEL_TREE"
        if [[ -d "$TREE/.git" ]]; then
            info "Using existing kernel tree at $TREE"
            # 尝试加深历史以覆盖 4.20 -> 5.10 (非致命)
            git -C "$TREE" fetch --shallow-since="$SHALLOW_SINCE" origin "$BRANCH" 2>/dev/null \
                || git -C "$TREE" fetch --unshallow 2>/dev/null \
                || warn "Could not deepen history; using local state."
            return 0
        fi
        error "Provided --kernel-tree is not a git repo: $TREE"
        return 1
    fi

    TREE="$TEMP_DIR/linux"
    info "Shallow-cloning linux mainline at '$BRANCH' (this may take a while)..."
    if ! git clone --depth 1 --branch "$BRANCH" --single-branch "$LINUX_REPO" "$TREE" 2>/dev/null; then
        warn "Tagged shallow clone failed; retrying without a specific branch..."
        if ! git clone --depth 1 --no-single-branch "$LINUX_REPO" "$TREE" 2>/dev/null; then
            warn "git clone failed."
            return 1
        fi
    fi

    info "Deepening history (shallow-since $SHALLOW_SINCE) to locate PSI per-cgroup commits..."
    git -C "$TREE" fetch --shallow-since="$SHALLOW_SINCE" origin "$BRANCH" 2>/dev/null \
        || git -C "$TREE" fetch --unshallow 2>/dev/null \
        || warn "Could not deepen history; commit search may be incomplete."
    return 0
}

if ! prepare_source; then
    warn "Failed to obtain linux source tree; no patches will be generated."
    : > "$SERIES_FILE"
    info "Created empty series file."
    exit 0
fi

# ---- Step 2: 定位 PSI per-cgroup 相关 commit ----
info "Searching for PSI per-cgroup commits (author: '$AUTHOR_GREP', keywords: ${KEYWORDS[*]})..."

COMMITS_FILE="$TEMP_DIR/commits.txt"
: > "$COMMITS_FILE"

# 主搜索: author + 任一关键词 (git 多个 --grep 默认 OR, 与 --author 取交集)
info "  Searching author '$AUTHOR_GREP' with keywords psi/cgroup/pressure stall..."
{
    git -C "$TREE" log \
        --author="$AUTHOR_GREP" \
        --grep="psi" \
        --grep="cgroup" \
        --grep="pressure stall" \
        --format='%H' \
        --reverse \
        --no-merges \
        --all 2>/dev/null || true
} >> "$COMMITS_FILE"

# 补充搜索: 关键词 "pressure stall" (任意作者, 部分相关提交可能由其他维护者合入)
info "  Also searching keyword 'pressure stall' (any author)..."
{
    git -C "$TREE" log \
        --grep="pressure stall" \
        --format='%H' \
        --reverse \
        --no-merges \
        --all 2>/dev/null || true
} >> "$COMMITS_FILE"

# 去重后按提交时间排序 (最旧在前, 保证补丁按依赖顺序应用)
SORTED_FILE="$TEMP_DIR/sorted_commits.txt"
: > "$SORTED_FILE"
while IFS= read -r h; do
    [[ -z "$h" ]] && continue
    commit_info="$(git -C "$TREE" log -1 --format='%ct %H' "$h" 2>/dev/null || true)"
    [[ -n "$commit_info" ]] && echo "$commit_info" >> "$SORTED_FILE"
done < <(sort -u "$COMMITS_FILE")

if [[ ! -s "$SORTED_FILE" ]]; then
    warn "No commits matched author+keywords; retrying with keyword 'psi' only (any author)..."
    {
        git -C "$TREE" log \
            --grep="psi" \
            --format='%H' \
            --reverse \
            --no-merges \
            --all 2>/dev/null || true
    } >> "$COMMITS_FILE"

    : > "$SORTED_FILE"
    while IFS= read -r h; do
        [[ -z "$h" ]] && continue
        commit_info="$(git -C "$TREE" log -1 --format='%ct %H' "$h" 2>/dev/null || true)"
        [[ -n "$commit_info" ]] && echo "$commit_info" >> "$SORTED_FILE"
    done < <(sort -u "$COMMITS_FILE")
fi

# 构建 (按时间排序的) 提交数组
COMMITS=()
if [[ -s "$SORTED_FILE" ]]; then
    sort -n "$SORTED_FILE" -o "$SORTED_FILE"
    while IFS=' ' read -r _ h; do
        [[ -n "$h" ]] && COMMITS+=("$h")
    done < "$SORTED_FILE"
fi

if [[ ${#COMMITS[@]} -eq 0 ]]; then
    warn "No PSI per-cgroup commits found in the cloned repository."
    warn "The shallow clone may not have enough depth."
    warn "Try increasing history depth or fetch specific commits manually."
    : > "$SERIES_FILE"
    info "Created empty series file."
    exit 0
fi

info "Found ${#COMMITS[@]} unique candidate commit(s); extracting patches..."

# ---- Step 3: 用 git format-patch 逐个提取补丁 ----
SERIES_BODY="$TEMP_DIR/series.body"
: > "$SERIES_BODY"

idx=0
SUCCESS=0
FAILED=0
for c in "${COMMITS[@]}"; do
    idx=$((idx + 1))
    printf -v num '%04d' "$idx"
    short="${c:0:12}"
    out="$OUTPUT_DIR/${num}-psi-percgroup-${short}.patch"

    if git -C "$TREE" format-patch -1 --stdout "$c" 2>/dev/null > "$out" && [[ -s "$out" ]]; then
        info "  + $(basename "$out") ($(wc -l < "$out") lines)"
        echo "$(basename "$out")" >> "$SERIES_BODY"
        SUCCESS=$((SUCCESS + 1))
    else
        warn "  - failed to extract commit $c"
        rm -f "$out" 2>/dev/null || true
        FAILED=$((FAILED + 1))
    fi
done

# ---- Step 4: 生成 series 文件 (带头部) ----
info "Writing series file..."
{
    echo "# PSI per-cgroup backport series for $BASELINE"
    echo "# Source: $LINUX_REPO (branch: $BRANCH)"
    echo "# Author: $AUTHOR_GREP"
    echo "# Keywords: ${KEYWORDS[*]}"
    echo "# Status: experimental - requires manual conflict resolution for $BASELINE"
    echo "#"
    cat "$SERIES_BODY"
} > "$SERIES_FILE"

# ---- 汇总 ----
echo "" >&2
echo -e "${BLUE}========================================${NC}" >&2
echo -e "${BLUE}  PSI per-cgroup Patch Generation Summary${NC}" >&2
echo -e "${BLUE}========================================${NC}" >&2
info "Extracted: $SUCCESS patch(es)"
if [[ "$FAILED" -gt 0 ]]; then
    warn "Failed:   $FAILED patch(es)"
    warn "Missing patches need manual cherry-pick from mainline."
fi
info "Patches saved to: $OUTPUT_DIR"
info "Series file:      $SERIES_FILE"
info "Next: run apply-backports.sh --baseline $BASELINE --features psi-percgroup"
echo "" >&2
warn "WARNING: These patches are EXPERIMENTAL."
warn "         PSI per-cgroup support evolved across 4.20 -> 5.10. The $BASELINE baseline"
warn "         does not include PSI by default (core PSI landed in 4.20), so the core"
warn "         infrastructure may need to be backported alongside these per-cgroup patches."
warn "         These patches will likely NOT apply cleanly out-of-the-box; manual"
warn "         adaptation to $BASELINE is REQUIRED:"
warn "           - resolve API/context differences against your $BASELINE tree"
warn "           - reconcile cgroup v1/v2 PSI wiring"
warn "           - review and test thoroughly before applying to production kernels."
