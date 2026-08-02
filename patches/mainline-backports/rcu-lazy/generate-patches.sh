#!/bin/bash
set -euo pipefail

# ============================================================
# RCU_LAZY Backport Patch Generator
#
# Feature:  Lazy RCU Callbacks (CONFIG_RCU_LAZY)
# Source:   Linux 6.6
# Author:   Joel Fernandes
# Baseline: Linux 4.19
#
# RCU_LAZY uses a timer-based approach to batch RCU callbacks,
# reducing wakeups and saving 5-10% power on idle/light loads.
# The feature was developed by Joel Fernandes and merged into
# the mainline Linux kernel in the 6.6 release cycle.
#
# This script:
#   1. Clones the mainline Linux repository (shallow clone)
#   2. Searches for RCU_LAZY-related commits
#   3. Extracts patches via git format-patch
#   4. Attempts simple sed-based adaptation for 4.19
#   5. Generates a series file
#
# All failures are non-fatal (warn and continue / exit 0).
# ============================================================

# --- Working directory: script's own location ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

# --- Color output functions ---
info() {
    echo -e "\033[1;32m[INFO]\033[0m  $*"
}

warn() {
    echo -e "\033[1;33m[WARN]\033[0m  $*" >&2
}

error() {
    echo -e "\033[1;31m[ERROR]\033[0m $*" >&2
}

# --- Configuration ---
LINUX_REPO_URL="https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git"
LINUX_TAG="v6.6"
BASELINE_KERNEL="4.19"

# Directories
WORK_DIR="${SCRIPT_DIR}/.work"
LINUX_SRC_DIR="${WORK_DIR}/linux"
PATCHES_DIR="${SCRIPT_DIR}/patches"
SERIES_FILE="${SCRIPT_DIR}/series"

# Search patterns for RCU_LAZY related commits
SEARCH_PATTERNS=(
    "rcu: lazy"
    "RCU_LAZY"
    "rcu: Add lazy"
    "lazy callback"
    "rcu-lazy"
)

# Author to search for
SEARCH_AUTHOR="Joel Fernandes"

# How many additional commits to fetch (deepen) for history search
DEEPEN_AMOUNT=5000

# --- Pre-flight checks ---
info "============================================"
info " RCU_LAZY Backport Patch Generator"
info "============================================"
info " Source:   Linux ${LINUX_TAG}"
info " Baseline: Linux ${BASELINE_KERNEL}"
info " Author:   ${SEARCH_AUTHOR}"
info "============================================"
echo ""

for cmd in git sed sort awk; do
    if ! command -v "${cmd}" &>/dev/null; then
        error "Required command not found: ${cmd}"
        exit 1
    fi
done

# --- Step 1: Clone mainline Linux repository (shallow) ---
info "Step 1: Cloning mainline Linux repository (shallow clone, depth=1, tag=${LINUX_TAG})..."

rm -rf "${WORK_DIR}"
mkdir -p "${WORK_DIR}"

if ! git clone --depth=1 --branch "${LINUX_TAG}" "${LINUX_REPO_URL}" "${LINUX_SRC_DIR}"; then
    warn "git clone failed (repo: ${LINUX_REPO_URL}, tag: ${LINUX_TAG})."
    warn "This may be due to network issues, missing tag, or insufficient disk space."
    warn "Skipping RCU_LAZY patch generation."
    rm -rf "${WORK_DIR}"
    exit 0
fi

info "Clone successful."

# --- Step 2: Deepen clone history for commit searching ---
info "Step 2: Deepening clone history (${DEEPEN_AMOUNT} commits) to search for RCU_LAZY commits..."

cd "${LINUX_SRC_DIR}"

# With --depth=1 we only have a single commit. Deepen to search history.
if ! git fetch --deepen="${DEEPEN_AMOUNT}" 2>/dev/null; then
    warn "Failed to deepen clone history to ${DEEPEN_AMOUNT} commits."
    warn "Will attempt to search with available history only."
fi

# --- Step 3: Search for RCU_LAZY related commits ---
info "Step 3: Searching for RCU_LAZY related commits..."

COMMITS_FILE="${WORK_DIR}/commits.txt"
> "${COMMITS_FILE}"

# Search by commit message patterns in kernel/rcu/ and include/
for pattern in "${SEARCH_PATTERNS[@]}"; do
    info "  Searching pattern: '${pattern}'"
    git log --oneline --no-merges --grep="${pattern}" -- kernel/rcu/ include/ >> "${COMMITS_FILE}" 2>/dev/null || true
done

# Search by author + "lazy" keyword
info "  Searching by author: '${SEARCH_AUTHOR}' (keyword: lazy)"
git log --oneline --no-merges --author="${SEARCH_AUTHOR}" --grep="lazy" -- kernel/rcu/ include/ >> "${COMMITS_FILE}" 2>/dev/null || true

# Check if we found any commits
if [[ ! -s "${COMMITS_FILE}" ]]; then
    warn "No RCU_LAZY commits found in available history."
    warn "The shallow clone may not have enough depth."
    warn "Try increasing DEEPEN_AMOUNT or fetch specific commits manually."
    rm -rf "${WORK_DIR}"
    exit 0
fi

# Remove duplicates
sort -u "${COMMITS_FILE}" -o "${COMMITS_FILE}"
COMMIT_COUNT=$(wc -l < "${COMMITS_FILE}")

info "Found ${COMMIT_COUNT} unique RCU_LAZY-related commits."
echo ""
info "Commits found:"
sed 's/^/    /' "${COMMITS_FILE}"
echo ""

# --- Step 4: Extract patches using git format-patch ---
info "Step 4: Extracting patches using git format-patch..."

mkdir -p "${PATCHES_DIR}"
rm -f "${PATCHES_DIR}"/*.patch

# Sort commits chronologically (oldest first) so patches apply in order
info "  Sorting commits in chronological order..."

SORTED_FILE="${WORK_DIR}/sorted_commits.txt"
> "${SORTED_FILE}"

while IFS= read -r line; do
    [[ -z "${line}" ]] && continue
    hash="${line%% *}"
    # Get timestamp + full hash for chronological sorting
    commit_info=$(git log -1 --format="%ct %H" "${hash}" 2>/dev/null || echo "")
    if [[ -n "${commit_info}" ]]; then
        echo "${commit_info}" >> "${SORTED_FILE}"
    fi
done < "${COMMITS_FILE}"

sort -n "${SORTED_FILE}" -o "${SORTED_FILE}"

# Extract each commit as a patch
> "${SERIES_FILE}"
PATCH_NUM=1

while IFS=' ' read -r _ full_hash; do
    [[ -z "${full_hash}" ]] && continue
    short_hash="${full_hash:0:12}"

    info "  Extracting patch ${PATCH_NUM}: ${short_hash}..."

    patch_filename="$(printf '%04d' "${PATCH_NUM}")-rcu-lazy-${short_hash}.patch"
    patch_path="${PATCHES_DIR}/${patch_filename}"

    if git format-patch -1 "${full_hash}" --stdout > "${patch_path}" 2>/dev/null; then
        if [[ -s "${patch_path}" ]]; then
            echo "${patch_filename}" >> "${SERIES_FILE}"
            info "    -> ${patch_filename}"
            PATCH_NUM=$((PATCH_NUM + 1))
        else
            warn "    Empty patch generated, skipping."
            rm -f "${patch_path}"
        fi
    else
        warn "    Failed to extract patch for ${short_hash}, skipping."
        rm -f "${patch_path}"
    fi
done < "${SORTED_FILE}"

# --- Step 5: Adapt patches to 4.19 baseline (simple sed) ---
info "Step 5: Adapting patches to ${BASELINE_KERNEL} baseline (simple sed replacements)..."

adapt_patch() {
    local patch_file="$1"
    local basename
    basename="$(basename "${patch_file}")"

    cp "${patch_file}" "${patch_file}.bak"

    # Simple sed adaptations (best-effort):
    # 1. Replace version references in patch metadata/comments
    sed -i 's/v6\.6/v4.19/g' "${patch_file}" 2>/dev/null || true
    sed -i 's/Linux 6\.6/Linux 4.19/g' "${patch_file}" 2>/dev/null || true

    # 2. Normalize line endings (CRLF -> LF)
    sed -i 's/\r$//' "${patch_file}" 2>/dev/null || true

    # Report if changes were made
    if ! diff -q "${patch_file}" "${patch_file}.bak" > /dev/null 2>&1; then
        info "    Adapted: ${basename}"
    fi
    rm -f "${patch_file}.bak"
}

patch_count=0
for patch_file in "${PATCHES_DIR}"/*.patch; do
    [[ -f "${patch_file}" ]] || continue
    adapt_patch "${patch_file}" || warn "    Failed to adapt $(basename "${patch_file}")"
    patch_count=$((patch_count + 1))
done

info "  Processed ${patch_count} patches."

# --- Step 6: Finalize series file ---
info "Step 6: Finalizing series file..."

if [[ -s "${SERIES_FILE}" ]]; then
    # Prepend header
    {
        echo "# RCU_LAZY backport patches"
        echo "# Source: Linux ${LINUX_TAG}"
        echo "# Baseline: Linux ${BASELINE_KERNEL}"
        echo "# Feature: CONFIG_RCU_LAZY=y"
        echo "# Status: experimental"
        echo "#"
        cat "${SERIES_FILE}"
    } > "${SERIES_FILE}.tmp"
    mv "${SERIES_FILE}.tmp" "${SERIES_FILE}"

    info ""
    info "Series file contents:"
    sed 's/^/    /' "${SERIES_FILE}"
    echo ""
else
    warn "No patches were successfully generated."
fi

# --- Cleanup ---
info "Cleaning up temporary files..."
rm -rf "${WORK_DIR}"

# --- Summary ---
echo ""
info "============================================"
info " RCU_LAZY Backport Generation Complete"
info "============================================"
info " Patches:  ${PATCHES_DIR}"
info " Series:   ${SERIES_FILE}"
info "============================================"
echo ""
warn "Note: These patches are EXPERIMENTAL."
warn "      Simple sed adaptations may not handle all API differences between 6.6 and 4.19."
warn "      Manual review and additional adaptation will likely be required."
warn "      Test thoroughly before applying to production kernels."
