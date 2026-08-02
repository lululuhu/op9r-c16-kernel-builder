#!/bin/bash
# ===================================================================
# generate-patches.sh — 从主线 Linux git 仓库生成 Landlock backport 补丁
#
# Landlock LSM 由 Mickaël Salaün 开发, 于主线 5.13 合入核心。
# Landlock 是一个细粒度文件系统访问控制的安全模块 (LSM), 允许非特权
# 进程安全地沙箱化自身, 限制对文件层次结构的访问。
# 主要涉及文件:
#   security/landlock/, include/uapi/linux/landlock.h,
#   security/security.c, include/linux/lsm_hooks.h,
#   Documentation/userspace-api/landlock.rst
#
# 本脚本流程:
#   1. 浅克隆 mainline linux 仓库 (torvalds) 分支 v5.13 并加深历史
#   2. 用 git log --grep "Landlock" --author "Mickaël Salaün" 定位提交
#      (失败则退化为仅 grep "Landlock" / 路径 security/landlock)
#   3. 用 git format-patch -1 --stdout 逐个提取补丁
#   4. 输出补丁到 patches/ 子目录
#   5. 生成 series 文件 (位于特性目录根部, 供 apply-backports.sh 使用)
#
# 容错: 克隆失败 / 提取失败只输出 warn, 不退出; 最终仍生成 series。
#
# 警告: 这些补丁是实验性的! Landlock 依赖 5.12~5.13 引入的 LSM 基础设施
#       (LSM stacking、unprivileged 挂载/ptrace 限制、新的 file/path API),
#       backport 到 4.19 内核需要大量手动适配, 不能直接 apply。
#
# 用法:
#   ./generate-patches.sh [--kernel-tree /path/to/linux] [--output /path]
#
# 补丁默认保存在脚本所在目录下的 patches/ 子目录; series 文件位于
# 脚本所在目录根部 (apply-backports.sh 期望的位置)。
# 如指定 --output, 则补丁与 series 一并输出到该目录 (自包含)。
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
TEMP_DIR="$(mktemp -d 2>/dev/null || echo "$SCRIPT_DIR/.landlock-tmp")"
KERNEL_TREE=""
CUSTOM_OUTPUT=0

# ---- 临时目录清理 (脚本退出时, 含 --help / 异常退出) ----
# 注意: trap 必须在解析参数之前注册, 保证任何退出路径都清理 TEMP_DIR。
cleanup() {
    if [[ -n "${TEMP_DIR:-}" && -d "${TEMP_DIR:-}" ]]; then
        info "Cleaning up temporary directory: $TEMP_DIR"
        rm -rf "$TEMP_DIR" 2>/dev/null || warn "Could not remove $TEMP_DIR"
    fi
}
trap cleanup EXIT

while [[ $# -gt 0 ]]; do
    case "$1" in
        --kernel-tree) KERNEL_TREE="$2"; shift 2 ;;
        --output)
            OUTPUT_DIR="$2"; SERIES_FILE="$OUTPUT_DIR/series"; CUSTOM_OUTPUT=1; shift 2 ;;
        -h|--help)
            echo "Usage: $0 [--kernel-tree /path/to/linux] [--output /path]"
            echo ""
            echo "  --kernel-tree  复用本地已有的 linux 源码树 (不会被清理)"
            echo "  --output       补丁与 series 的输出目录 (默认: ./patches, series 在脚本根部)"
            exit 0
            ;;
        *) error "Unknown option: $1"; exit 1 ;;
    esac
done

# 工作目录为脚本所在目录
cd "$SCRIPT_DIR"

LINUX_REPO="https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git"
BRANCH="v5.13"
COMMIT_GREP="Landlock"
AUTHOR_GREP="Mickaël Salaün"
PATHSPEC="security/landlock include/uapi/linux/landlock.h"
BASELINE="4.19"
SCAN_RANGE="v5.12..v5.13"               # 仅作参考/日志 (核心于 5.13 合入)

# series 中补丁路径前缀: 默认指向 patches/ 子目录; 自定义输出时为裸文件名
if [[ "$CUSTOM_OUTPUT" = "1" ]]; then
    PATCH_PREFIX=""
else
    PATCH_PREFIX="patches/"
fi

info "=== Landlock LSM Backport Patch Generator ==="
info "  baseline : $BASELINE"
info "  repo     : $LINUX_REPO"
info "  branch   : $BRANCH"
info "  grep     : '$COMMIT_GREP' (author: '$AUTHOR_GREP')"
info "  output   : $OUTPUT_DIR"
info "  series   : $SERIES_FILE"
info "  temp     : $TEMP_DIR"

# ---- 清理上次的输出 ----
rm -f "$OUTPUT_DIR"/*.patch 2>/dev/null || true
rm -f "$SERIES_FILE" 2>/dev/null || true
rm -rf "$OUTPUT_DIR/adapted" 2>/dev/null || true
mkdir -p "$OUTPUT_DIR/adapted"

# ---- Step 1: 获取 linux 源码树 (浅克隆 + 加深历史) ----
TREE=""
prepare_source() {
    if [[ -n "${KERNEL_TREE:-}" ]]; then
        # 用户提供了本地源码树, 复用且不清理
        TREE="$KERNEL_TREE"
        if [[ -d "$TREE/.git" ]]; then
            info "Using existing kernel tree at $TREE"
            git -C "$TREE" fetch --shallow-since="2019-01-01" origin "$BRANCH" 2>/dev/null \
                || git -C "$TREE" fetch --unshallow 2>/dev/null \
                || warn "Could not deepen history; using local state."
        else
            warn "$TREE is not a git repository; commit search will likely fail."
        fi
        return 0
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

    info "Deepening history (shallow-since 2019-01-01) to locate Landlock commits..."
    git -C "$TREE" fetch --shallow-since="2019-01-01" origin "$BRANCH" 2>/dev/null \
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

# ---- Step 2: 定位 Landlock 相关 commit ----
# 策略: author+grep -> grep only -> 路径 security/landlock
info "Searching for Landlock commits (grep: '$COMMIT_GREP', author: '$AUTHOR_GREP')..."

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
                -- security/landlock include/uapi/linux/landlock.h 2>/dev/null || true)
fi

if [[ ${#COMMITS[@]} -eq 0 ]]; then
    warn "No Landlock commits found in the cloned repository."
    : > "$SERIES_FILE"
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
    out="$OUTPUT_DIR/${num}-landlock-${short}.patch"

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
    : > "$SERIES_FILE"
    info "Created empty series file."
    exit 0
fi

# ---- Step 4: best-effort 适配到 4.19 基线 ----
info "Adapting patches to $BASELINE baseline (best-effort)..."
warn "Landlock backport is EXPERIMENTAL and requires manual adaptation to $BASELINE."
warn "Known 4.19 gaps are STRUCTURAL (LSM stacking, lsm_hooks list, file/path API"
warn "signatures) and cannot be fixed by sed; adapted/ copies are flagged for manual review only."

adapt_patch() {
    local src="$1" name dst
    name="$(basename "$src")"
    dst="$OUTPUT_DIR/adapted/$name"

    if cp "$src" "$dst" 2>/dev/null; then
        # 4.19 缺少 Landlock 所依赖的 5.12~5.13 LSM 基础设施。Landlock 的 4.19
        # 缺口是结构性的 (LSM hook 注册、file/path API 签名变更), 无法用 sed
        # 可靠修复。这里仅做无害的行尾归一化, 并标记为待人工审阅。
        sed -i 's/\r$//' "$dst" 2>/dev/null \
            || warn "  ! sed adaptation error for $name (kept unmodified copy)"
        info "  ~ flagged for manual review: $name"
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
    echo "# Landlock LSM backport series for $BASELINE"
    echo "# Source: $LINUX_REPO (branch: $BRANCH, grep: '$COMMIT_GREP', author: '$AUTHOR_GREP')"
    echo "# Range reference: $SCAN_RANGE (core merged in 5.13)"
    echo "# Status: experimental - requires MANUAL adaptation to $BASELINE"
    echo "# Warning: depends on 5.12~5.13 LSM infrastructure not present in $BASELINE"
    echo "# Flagged (manual-review) copies are in ${PATCH_PREFIX}adapted/"
    echo "#"
    for p in "${PATCHES[@]}"; do
        echo "${PATCH_PREFIX}$(basename "$p")"
    done
} > "$SERIES_FILE"

# ---- 汇总 ----
echo "" >&2
echo -e "${BLUE}========================================${NC}" >&2
echo -e "${BLUE}  Landlock Patch Generation Summary${NC}" >&2
echo -e "${BLUE}========================================${NC}" >&2
info "Extracted: $SUCCESS patch(es)"
if [[ "$FAILED" -gt 0 ]]; then
    warn "Failed:   $FAILED patch(es)"
    warn "Missing patches need manual cherry-pick from mainline."
fi
info "Flagged copies: $OUTPUT_DIR/adapted/"
info "Patches saved to: $OUTPUT_DIR"
info "Series file:     $SERIES_FILE"
warn "These patches are EXPERIMENTAL and may require manual adaptation to $BASELINE."
info "Next: run apply-backports.sh --baseline $BASELINE --features landlock"
