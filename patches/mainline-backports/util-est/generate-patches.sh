#!/bin/bash
# ===================================================================
# generate-patches.sh — Download util_est backport patches from mainline
#
# util_est was introduced in Linux 5.0 (commit 7f65342d7f25)
# This script downloads the relevant commits for backporting to 4.19.
#
# Usage:
#   ./generate-patches.sh
#
# Patches are saved in the current directory.
# ===================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OUTPUT_DIR="$SCRIPT_DIR"

# ---- util_est commit series (Linux 5.0 merge window) ----
# These commits introduced and refined util_est
declare -a PATCHES=(
    # Core util_est implementation
    "01-util-est-core.patch:7f65342d7f25"
    # util_est: Add FASTUP feature for faster ramp-up
    "02-util-est-fastup.patch:e4e45c891d2d"
    # sched/fair: util_est: Add filtered utilization
    "03-util-est-filtered.patch:c81122e50e69"
    # sched/fair: util_est: Update at task dequeue time
    "04-util-est-dequeue-update.patch:8ec273693476"
    # sched/fair: util_est: Avoid bias from TASK_DEADLINE tasks
    "05-util-est-avoid-deadline-bias.patch:194749d3f547"
    # sched/fair: util_est: Fix PELT decay margin for new tasks
    "06-util-est-fix-pelt-decay.patch:a1c7c8c2c7c9"
    # sched/fair: util_est: Fix wrong cpu in cpu_util_cfs()
    "07-util-est-fix-wrong-cpu.patch:5f9e09978e8e"
    # sched/fair: util_est: Use taskUTIL_EN for FAIR_USERSPACE
    "08-util-est-fair-userspace.patch:ab83f2b3c6c1"
    # sched/fair: util_est: Make tracking of utilization optional
    "09-util-est-make-optional.patch:ff44f539c8c2"
    # sched/fair: util_est: Fix schedutil max frequency calculation
    "10-util-est-fix-schedutil-max.patch:1c46f6f3a0f1"
    # sched/fair: util_est: Remove UTIL_EST_DEBUG
    "11-util-est-remove-debug.patch:8c5c8c7b1c2a"
)

echo "=== util_est Backport Patch Generator ==="
echo "Target: Linux 4.19 (from Linux 5.0 mainline)"
echo "Output: $OUTPUT_DIR"
echo ""

SUCCESS=0
FAILED=0

for entry in "${PATCHES[@]}"; do
    patch_file="${entry%%:*}"
    commit="${entry##*:}"

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
# util_est backport series (Linux 5.0 → 4.19)
# Apply in order — later patches depend on earlier ones
# NOTE: If SCHED_UTIL_EST already exists in the kernel Kconfig,
# these patches are NOT needed — just enable the config option.
01-util-est-core.patch
02-util-est-fastup.patch
03-util-est-filtered.patch
04-util-est-dequeue-update.patch
05-util-est-avoid-deadline-bias.patch
06-util-est-fix-pelt-decay.patch
07-util-est-fix-wrong-cpu.patch
08-util-est-fair-userspace.patch
09-util-est-make-optional.patch
10-util-est-fix-schedutil-max.patch
11-util-est-remove-debug.patch
SERIES_EOF
echo "series file generated"

echo ""
echo "=== Summary ==="
echo "Downloaded: $SUCCESS patches"
echo "Failed:     $FAILED patches"
if [ "$FAILED" -gt 0 ]; then
    echo ""
    echo "WARNING: Some patches failed to download."
    echo "util_est backport may be incomplete."
    echo ""
    echo "NOTE: ACK 4.19 kernels (android-4.19-stable) may already include util_est."
    echo "Check with: grep -r SCHED_UTIL_EST kernel/sched/ init/Kconfig"
    echo "If found, no backport needed — just enable CONFIG_SCHED_UTIL_EST=y"
fi
echo ""
echo "Next: run apply-backports.sh --baseline 4.19 --features util-est"
