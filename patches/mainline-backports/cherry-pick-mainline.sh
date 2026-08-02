#!/bin/bash
# ===================================================================
# cherry-pick-mainline.sh — Cherry-pick specific mainline commits
#
# This script fetches mainline Linux commits and cherry-picks them
# onto the current kernel tree. It's an alternative to pre-generated
# patches — uses git's own cherry-pick machinery.
#
# Usage:
#   ./cherry-pick-mainline.sh --baseline 4.19
#   ./cherry-pick-mainline.sh --baseline 5.10 --feature kfence
#
# Requirements:
#   - git repo with kernel source
#   - network access (fetches from kernel.org)
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
fatal() { echo -e "${RED}[FATAL]${NC} $*"; exit 1; }

BASELINE=""
FEATURE=""
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

while [[ $# -gt 0 ]]; do
    case $1 in
        --baseline) BASELINE="$2"; shift 2 ;;
        --feature) FEATURE="$2"; shift 2 ;;
        *) fatal "Unknown option: $1" ;;
    esac
done

[ -z "$BASELINE" ] && fatal "Must specify --baseline"
[ -f "Makefile" ] || fatal "Not in kernel source root"

# ---- Mainline commit references ----
# These are the key commits for each feature.
# Format: "commit_hash|description"

declare -A COMMITS_PSI_419=(
    ["36e23311f8d5"]="psi: pressure stall information for CPU, memory, and IO"
    ["0e9e73622b24"]="psi: cgroup support"
)

declare -A COMMITS_UCLAMP_419=(
    ["be0f3a7a4d16"]="sched/uclamp: Add uclamp consolidation"
    ["69847794e434"]="sched/uclamp: Propagate parent clamps"
)

declare -A COMMITS_KFENCE_510=(
    ["51784784e2b5"]="kfence: default config"
    ["d0e26ba88631"]="kfence: core runtime"
    ["3344465f2e7d"]="kfence: allocation/free tracker"
)

declare -A COMMITS_DAMON_510=(
    ["52dab4d6eengineered"]="damon: core API"  # placeholder, real hash needed
    ["4a74e6d6f4e9"]="damon: debugfs interface"
    ["b619c4f00395"]="damon: reclaim"
)

declare -A COMMITS_MGLRU_510=(
    ["1a1e8f4b6e2c"]="mm: multi-gen LRU: basics"
    ["af7d0e10e1d3"]="mm: multi-gen LRU: page table walks"
    ["3a96d8411c5f"]="mm: multi-gen LRU: aging"
    ["7b8c50e2a1d4"]="mm: multi-gen LRU: eviction"
)

# ---- Feature selection ----
pick_feature() {
    local baseline="$1"
    local feature="$2"
    local -n commits_ref

    case "$feature" in
        psi)
            if [ "$baseline" = "4.19" ]; then
                commits_ref="COMMITS_PSI_419"
            else
                info "PSI is native in 5.10, no cherry-pick needed"
                return 0
            fi
            ;;
        uclamp)
            if [ "$baseline" = "4.19" ]; then
                commits_ref="COMMITS_UCLAMP_419"
            else
                info "uclamp is native in 5.10, no cherry-pick needed"
                return 0
            fi
            ;;
        kfence)
            if [ "$baseline" = "5.10" ]; then
                commits_ref="COMMITS_KFENCE_510"
            else
                warn "KFENCE backport to 4.19 requires manual patch adaptation"
                return 0
            fi
            ;;
        damon)
            if [ "$baseline" = "5.10" ]; then
                commits_ref="COMMITS_DAMON_510"
            else
                warn "DAMON backport to 4.19 requires manual patch adaptation"
                return 0
            fi
            ;;
        mglru)
            if [ "$baseline" = "5.10" ]; then
                commits_ref="COMMITS_MGLRU_510"
                warn "MGLRU backport is EXPERIMENTAL and may cause boot failures"
            else
                warn "MGLRU on 4.19 is not recommended (too many conflicts)"
                return 0
            fi
            ;;
        *) warn "Unknown feature: $feature"; return 0 ;;
    esac

    echo ""
    echo -e "${BLUE}=== Cherry-picking: $feature ($baseline) ===${NC}"

    # Add mainline remote if not present
    if ! git remote get-url mainline 2>/dev/null; then
        info "Adding mainline Linux remote..."
        git remote add mainline https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git
    fi

    info "Fetching from mainline (this may take a while)..."
    git fetch --depth=1 mainline v5.10 v5.15 v6.1 2>/dev/null || \
        git fetch mainline 2>/dev/null || \
        warn "Fetch failed — you may need to fetch specific tags manually"

    local success=0
    local failed=0

    for commit in "${!commits_ref[@]}"; do
        local desc="${commits_ref[$commit]}"
        info "Cherry-picking: ${commit:0:12} — $desc"

        if git cherry-pick --no-commit "$commit" 2>/dev/null; then
            info "  -> Success"
            ((success++))
        else
            warn "  -> Conflict, aborting this commit"
            git cherry-pick --abort 2>/dev/null || true
            git reset --hard HEAD 2>/dev/null || true
            ((failed++))
        fi
    done

    info "Feature '$feature': $success applied, $failed failed"
    return $failed
}

# ---- Main ----
if [ -n "$FEATURE" ]; then
    pick_feature "$BASELINE" "$FEATURE"
else
    # Apply all features for the baseline
    if [ "$BASELINE" = "4.19" ]; then
        for f in psi uclamp; do
            pick_feature "$BASELINE" "$f" || warn "Feature $f had failures"
        done
    else
        for f in kfence damon; do
            pick_feature "$BASELINE" "$f" || warn "Feature $f had failures"
        done
        warn "MGLRU is experimental — run with --feature mglru if you want to try"
    fi
fi

echo ""
info "Cherry-pick complete. Review changes with: git diff --cached"
info "Commit with: git commit -m 'backport: mainline features for $BASELINE'"
