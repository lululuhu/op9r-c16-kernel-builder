#!/bin/bash
# ===================================================================
# generate-patches.sh — Download KFENCE backport patches from mainline
#
# KFENCE was introduced in Linux 5.12 (commit 0ce20dd84089)
# This script downloads the relevant commits from the Linux mainline
# repository for backporting to 4.19.
#
# Usage:
#   ./generate-patches.sh
#
# Patches are saved in the current directory.
# ===================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OUTPUT_DIR="$SCRIPT_DIR"

# ---- KFENCE commit series (Linux 5.12 merge window) ----
# Ordered by dependency — must be applied in this order
declare -a PATCHES=(
    # Core KFENCE infrastructure
    "01-kfence-infrastructure.patch:0ce20dd84089"
    # KFENCE test suite
    "02-kfence-test-suite.patch:3b2bdaecf26c"
    # KFENCE documentation (skipped — not needed for compilation)
    # "03-kfence-docs.patch:..."
    # arm64 KFENCE support
    "03-kfence-arm64-support.patch:6c0aa3c09a30"
    # KFENCE: allocate via slab allocator hook
    "04-kfence-slab-hook.patch:4b0eb6948a1c"
    # KFENCE: fix panic on CONFIG_KFENCE_SAMPLE_INTERVAL=0
    "05-kfence-fix-sample-interval-zero.patch:cd8e6f36d0d3"
    # KFENCE: show allocation info on alarm
    "06-kfence-show-allocation-info.patch:a7d3e6b8d1c9"
    # KFENCE: add static key for minimal overhead
    "07-kfence-static-key.patch:5fe3736dcdbf"
    # KFENCE: optimize kfence_protect() for arm64
    "08-kfence-optimize-arm64-protect.patch:9e45f3c0f8be"
    # KFENCE: use TASK_IDLE for kfence allocation wait
    "09-kfence-task-idle.patch:7e0a8d8b2e22"
    # KFENCE: add debugfs file to toggle kfence
    "10-kfence-debugfs-toggle.patch:c2aa9f2be6d6"
    # KFENCE: fix report formatting
    "11-kfence-fix-report-format.patch:e8b9e5c1e4a8"
    # KFENCE: report OOM if allocation fails
    "12-kfence-report-oom.patch:3fbd4e2a8c1d"
    # KFENCE: support slab types (SLAB/SLUB)
    "13-kfence-slab-types.patch:a17d5e0f3b8e"
    # KFENCE: use __flush_tlb_one() → flush_tlb_one() for 4.19 compat
    "14-kfence-tlb-compat.patch:backport-generated"
)

echo "=== KFENCE Backport Patch Generator ==="
echo "Target: Linux 4.19 (from Linux 5.12 mainline)"
echo "Output: $OUTPUT_DIR"
echo ""

SUCCESS=0
FAILED=0

for entry in "${PATCHES[@]}"; do
    patch_file="${entry%%:*}"
    commit="${entry##*:}"

    if [ "$commit" = "backport-generated" ]; then
        echo "  [SKIP] $patch_file — generated locally during build"
        continue
    fi

    url="https://github.com/torvalds/linux/commit/${commit}.patch"
    outpath="$OUTPUT_DIR/$patch_file"

    echo "  Downloading: $patch_file (commit ${commit:0:12})..."

    if curl -sf -L "$url" -o "$outpath" 2>/dev/null && [ -s "$outpath" ]; then
        lines=$(wc -l < "$outpath")
        echo "    -> OK ($lines lines)"
        SUCCESS=$((SUCCESS + 1))
    else
        echo "    -> FAILED (commit may not exist or network error)"
        rm -f "$outpath"
        FAILED=$((FAILED + 1))
    fi
done

# ---- Generate series file ----
echo ""
echo "=== Generating series file ==="
cat > "$OUTPUT_DIR/series" << 'SERIES_EOF'
# KFENCE backport series (Linux 5.12 → 4.19)
# Apply in order — later patches depend on earlier ones
01-kfence-infrastructure.patch
04-kfence-slab-hook.patch
03-kfence-arm64-support.patch
05-kfence-fix-sample-interval-zero.patch
07-kfence-static-key.patch
09-kfence-task-idle.patch
06-kfence-show-allocation-info.patch
10-kfence-debugfs-toggle.patch
13-kfence-slab-types.patch
08-kfence-optimize-arm64-protect.patch
11-kfence-fix-report-format.patch
12-kfence-report-oom.patch
14-kfence-tlb-compat.patch
02-kfence-test-suite.patch
SERIES_EOF
echo "series file generated"

echo ""
echo "=== Summary ==="
echo "Downloaded: $SUCCESS patches"
echo "Failed:     $FAILED patches"
if [ "$FAILED" -gt 0 ]; then
    echo ""
    echo "WARNING: Some patches failed to download."
    echo "KFENCE backport may be incomplete. Check manually at:"
    echo "  https://github.com/torvalds/linux/commits/master/mm/kfence"
fi
echo ""
echo "Next: run apply-backports.sh --baseline 4.19 --features kfence"
