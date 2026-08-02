#!/bin/bash
# ===================================================================
# apply-backports.sh — Apply mainline Linux feature backports
#
# Usage:
#   ./apply-backports.sh --baseline 4.19 [--features "psi,uclamp,fsverity"]
#   ./apply-backports.sh --baseline 5.10 [--features "kfence,damon,mglru"]
#
# Run from the kernel source root directory.
# ===================================================================
set -euo pipefail

# ---- Color output ----
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; }
fatal() { echo -e "${RED}[FATAL]${NC} $*"; exit 1; }

# ---- Defaults ----
BASELINE=""
FEATURES=""
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# ---- Parse args ----
while [[ $# -gt 0 ]]; do
    case $1 in
        --baseline) BASELINE="$2"; shift 2 ;;
        --features) FEATURES="$2"; shift 2 ;;
        --help|-h)
            echo "Usage: $0 --baseline {4.19|5.10} [--features \"feat1,feat2\"]"
            echo ""
            echo "Available features for 4.19:"
            echo "  psi             — Pressure Stall Information (4.20)"
            echo "  uclamp          — Utilization clamping (5.3)"
            echo "  fsverity        — fs-verity file integrity (5.4)"
            echo "  kfence          — KFENCE memory detector (5.12)"
            echo "  util-est        — Utilization estimation EWMA (5.0)"
            echo "  iouring         — io_uring async IO (5.1)"
            echo "  landlock        — Landlock LSM (5.13)"
            echo "  zram66          — zram multi-compression/recompression (6.6)"
            echo "  zsmalloc612     — zsmalloc per-class lock (6.12)"
            echo "  wireguard       — WireGuard VPN (android-4.19-stable built-in)"
            echo "  binder-uclamp   — Binder IPC UClamp optimization (android13-5.15)"
            echo "  cpufreq-stats   — cpufreq stats driver mainline update"
            echo "  sched-topology-dsu — DynamIQ Shared Unit topology fix"
            echo "  cass-llc        — CASS LLC cache affinity optimization"
            echo "  tcp-bbr2        — TCP BBR v2 congestion control"
            echo "  input-boost     — Touch-triggered CPU frequency boost"
            echo "  eevdf           — EEVDF scheduler (DOCUMENT ONLY - cannot backport)"
            echo "  mglru           — Multi-Gen LRU (5.18/6.1) [experimental]"
            echo "  damon           — DAMON data access monitor (5.15) [experimental]"
            echo "  rcu-lazy        — Lazy RCU callbacks (6.6) [experimental]"
            echo "  futex-waitv     — futex_waitv multi-futex wait (5.16) [experimental]"
            echo "  psi-percgroup   — Per-cgroup PSI tracking (5.10) [experimental]"
            echo "  landlock        — Landlock LSM filesystem access control (5.13) [experimental]"
            echo ""
            echo "Config-only (no patches needed, enabled in .fragment):"
            echo "  userfaultfd     — CONFIG_USERFAULTFD (4.19 native)"
            echo "  xdp_sockets     — CONFIG_XDP_SOCKETS (4.18+ native)"
            echo "  diag_char       — CONFIG_DIAG_CHAR (vendor)"
            echo "  cpufreq_times   — CONFIG_CPU_FREQ_TIMES"
            echo ""
            echo "Available features for 5.10:"
            echo "  kfence     — KFENCE memory detector (5.12)"
            echo "  damon      — DAMON data access monitor (5.15)"
            echo "  mglru      — Multi-Gen LRU (6.1) [experimental]"
            echo "  bbr2       — TCP BBR v2 (5.18+) [experimental]"
            echo "  zram66     — zram multi-compression/recompression (6.6)"
            echo "  zsmalloc612 — zsmalloc per-class lock + zpdesc (6.12)"
            exit 0 ;;
        *) fatal "Unknown option: $1" ;;
    esac
done

[ -z "$BASELINE" ] && fatal "Must specify --baseline {4.19|5.10}"
[[ "$BASELINE" != "4.19" && "$BASELINE" != "5.10" ]] && \
    fatal "Baseline must be 4.19 or 5.10"

# ---- Verify we're in a kernel tree ----
[ -f "Makefile" ] || fatal "Not in kernel source root (no Makefile found)"
if ! head -5 Makefile | grep -q "VERSION"; then
    fatal "Makefile doesn't look like kernel"
fi

KVER=$(make -s kernelversion 2>/dev/null || echo "unknown")
info "Kernel version: $KVER"
info "Target baseline: $BASELINE"

# ---- Feature sets ----
FEATURES_419="psi uclamp fsverity kfence util-est iouring landlock zram66 zsmalloc612 wireguard binder-uclamp cpufreq-stats sched-topology-dsu cass-llc tcp-bbr2 input-boost mglru damon rcu-lazy futex-waitv psi-percgroup"
FEATURES_510="kfence damon mglru bbr2 zram66 zsmalloc612 wireguard binder-uclamp cpufreq-stats"

if [ -z "$FEATURES" ]; then
    if [ "$BASELINE" = "4.19" ]; then
        FEATURES="$FEATURES_419"
    else
        FEATURES="$FEATURES_510"
    fi
    info "Using default feature set for $BASELINE: $FEATURES"
else
    info "Using requested features: $FEATURES"
fi

# Convert comma-separated to space-separated
FEATURES=$(echo "$FEATURES" | tr ',' ' ')

# ---- Apply features ----
APPLIED=0
FAILED=0

apply_feature() {
    local feat="$1"
    local feat_dir="$SCRIPT_DIR/$feat"
    local series_file="$feat_dir/series"

    echo ""
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}  Feature: $feat${NC}"
    echo -e "${BLUE}========================================${NC}"

    # ---- 4.19 compatibility warnings ----
    if [ "$BASELINE" = "4.19" ]; then
        case "$feat" in
            zram66)
                warn "zram 6.6 patches are designed for v6.6 codebase."
                warn "4.19 zram code differs significantly — patches will likely NOT apply."
                warn "Manual porting required for full multi-compression support."
                warn "Config options (CONFIG_ZRAM_MULTI_COMP etc.) will be ignored by olddefconfig."
                ;;
            zsmalloc612)
                warn "zsmalloc 6.12 patches revert a v6.11 pool spinlock merge."
                warn "4.19 already has per-size_class locking — nothing to revert."
                warn "These patches are NOT applicable to 4.19. Skipping."
                return 0
                ;;
            util-est)
                warn "util_est was introduced in 5.0."
                warn "ACK 4.19 (android-4.19-stable) may already include it."
                warn "Checking if SCHED_UTIL_EST is already available..."
                if grep -rq "SCHED_UTIL_EST" kernel/sched/ init/Kconfig 2>/dev/null; then
                    info "SCHED_UTIL_EST already found in kernel source — no backport needed."
                    info "Just enable CONFIG_SCHED_UTIL_EST=y in your config fragment."
                    return 0
                else
                    warn "SCHED_UTIL_EST not found — will attempt backport patches."
                    warn "Patches may need manual resolution due to scheduler API differences."
                fi
                ;;
            kfence)
                warn "KFENCE was introduced in 5.12."
                warn "4.19's slab allocator API differs significantly from 5.12."
                warn "Patches will likely need manual resolution."
                warn "If backport fails, KFENCE config will be ignored by olddefconfig."
                ;;
        esac
    fi

    if [ ! -d "$feat_dir" ]; then
        warn "Feature '$feat' has no patch directory, skipping (config-only)"
        return 0
    fi

    # ---- Helper: try multiple methods to apply a patch ----
    try_apply_patch() {
        local patch="$1"
        local name="$(basename "$patch")"

        # Method 1: git apply --check (strict)
        if git apply --check "$patch" 2>/dev/null; then
            git apply "$patch"
            info "  -> Applied (git apply)"
            APPLIED=$((APPLIED + 1))
            return 0
        fi

        # Method 2: git apply --3way (uses index for merge)
        if git apply --3way "$patch" 2>/dev/null; then
            info "  -> Applied (3-way merge)"
            APPLIED=$((APPLIED + 1))
            return 0
        fi

        # Method 3: patch -p1 (more lenient, may succeed where git fails)
        if patch -p1 --dry-run < "$patch" 2>/dev/null; then
            patch -p1 < "$patch" 2>/dev/null
            info "  -> Applied (patch -p1)"
            APPLIED=$((APPLIED + 1))
            return 0
        fi

        # Method 4: patch -p1 --fuzz=3 (allow fuzzy matching)
        if patch -p1 --fuzz=3 --dry-run < "$patch" 2>/dev/null; then
            patch -p1 --fuzz=3 < "$patch" 2>/dev/null
            warn "  -> Applied with fuzz=3 (review for correctness)"
            APPLIED=$((APPLIED + 1))
            return 0
        fi

        error "  -> FAILED to apply (all methods exhausted)"
        FAILED=$((FAILED + 1))
        return 1
    }

    if [ ! -f "$series_file" ]; then
        warn "No series file for '$feat', checking for direct patches..."
        if ls "$feat_dir"/*.patch 1>/dev/null 2>&1; then
            for p in "$feat_dir"/*.patch; do
                info "Applying: $(basename "$p")"
                try_apply_patch "$p" || true
            done
        else
            warn "No patches found for '$feat' (may need to generate them first)"
        fi
        return 0
    fi

    # Apply patches in series order
    while IFS= read -r line; do
        # Skip comments and empty lines
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [ -z "$line" ] && continue

        local patch="$feat_dir/$line"
        if [ ! -f "$patch" ]; then
            error "Patch file not found: $patch"
            FAILED=$((FAILED + 1))
            continue
        fi

        info "Applying: $line"
        try_apply_patch "$patch" || true
    done < "$series_file"
}

# ---- Main loop ----
info "Starting backport process for baseline $BASELINE"

for feat in $FEATURES; do
    # Check if feature is valid for this baseline
    if [ "$BASELINE" = "4.19" ]; then
        if [[ ! " $FEATURES_419 " =~ " $feat " ]]; then
            warn "Feature '$feat' is not supported on 4.19 baseline, skipping"
            continue
        fi
    else
        if [[ ! " $FEATURES_510 " =~ " $feat " ]]; then
            warn "Feature '$feat' is not supported on 5.10 baseline, skipping"
            continue
        fi
    fi

    apply_feature "$feat"
done

# ---- Summary ----
echo ""
echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}  Backport Summary${NC}"
echo -e "${BLUE}========================================${NC}"
info "Applied: $APPLIED patches"
if [ "$FAILED" -gt 0 ]; then
    warn "Failed:  $FAILED patches (need manual resolution)"
    warn "Resolve conflicts with: git mergetool"
    warn "After resolving: git add . && git commit"
    exit 1
else
    info "All patches applied successfully!"
    info "Next: merge config fragment and build"
fi

echo ""
info "Recommended config fragment:"
if [ "$BASELINE" = "4.19" ]; then
    echo "  configs/lemonades_c16_extreme.fragment"
else
    echo "  configs/lemonades_c16_510_extreme.fragment"
fi
echo ""
info "Build command:"
echo "  make O=out ARCH=arm64 olddefconfig && make O=out ARCH=arm64 -j\$(nproc)"
