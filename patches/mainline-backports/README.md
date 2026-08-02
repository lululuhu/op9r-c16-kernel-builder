# Mainline Linux Feature Backport Strategy

This directory contains scripts and documentation for backporting modern Linux
mainline features to the OnePlus 9R (SM8250 / Snapdragon 870) kernel.

## Two Baselines, Two Strategies

### Baseline 4.19 (Enhanced)

The 4.19 kernel (LineageOS lineage-23.2 branch) is the stable, proven baseline.
The following mainline features can be backported with moderate effort:

| Feature | Mainline Version | Backport Difficulty | Value |
|---------|-----------------|---------------------|-------|
| PSI | 4.20 | Easy | High (lmkd integration) |
| TCP BBR | 4.9+ | Easy (already in 4.19) | Medium |
| uclamp | 5.3 | Medium (needs EAS) | High (scheduling) |
| io_uring | 5.1 | Medium (large patchset) | Medium |
| fs-verity | 5.4 | Medium | High (APK integrity) |
| KFENCE | 5.12 | Medium | Medium (debug) |
| Landlock | 5.13 | Medium (already partial) | Medium |
| memfd_secret | 5.14 | Medium | Low |
| BPF ringbuf | 5.8 | Medium (needs 5.x BPF) | Medium |
| DAMON | 5.15 | Hard (mm/ changes) | Medium |
| zram multi-comp | 6.6 | Medium (zcomp rework) | High (15-30% memory savings) |

### Baseline 5.10 (GKI Path)

The 5.10 kernel (LineageOS sm8250/lineage-20 branch) is closer to Android GKI.
Many features are native; additional backports:

| Feature | Mainline Version | Backport Difficulty | Value |
|---------|-----------------|---------------------|-------|
| KFENCE | 5.12 | Easy (small patchset) | Medium |
| BBR v2 | 5.18+ | Medium | Medium |
| DAMON | 5.15 | Easy (clean port) | Medium |
| MGLRU | 6.1 | Hard (mm/ rework) | High (memory perf) |
| zram multi-comp | 6.6 | Easy-Medium (5.10 zram close to 6.6) | High (15-30% memory savings) |
| zsmalloc lock opt | 6.12 | Easy-Medium (per-class lock revert) | High (20% sys time reduction) |
| folio | 6.1 | Very Hard (fundamental) | High but risky |
| sched_ext | 6.12 | Very Hard (needs BPF infra) | Experimental |
| EEVDF | 6.6 | Very Hard (scheduler rewrite) | High but risky |

## How to Use

### Automated Backport (Recommended)

```bash
# From kernel source root:
bash $BUILDER_DIR/patches/mainline-backports/apply-backports.sh --baseline 4.19
# or
bash $BUILDER_DIR/patches/mainline-backports/apply-backports.sh --baseline 5.10
```

This script cherry-picks specific mainline commits that are known to apply
cleanly. Review the output carefully — some patches may need manual resolution.

### Manual Backport

Each feature directory contains:
- `feature.info` — mainline commit hashes and description
- `series` — ordered list of patches to apply
- `*.patch` — backported patches (if pre-generated)

### Feature Toggles in Config

Use `configs/lemonades_c16_extreme.fragment` to enable all backported features.
Individual features can be toggled via kernel config.

## zram 6.6: Multi-Compression Streams

Backported from Linux 6.6 (author: Sergey Senozhatsky). Supports 1 primary + up
to 3 secondary compression algorithms with idle/huge page recompression.

**Key features:**
- Huge page recompression: pages that the primary algorithm cannot compress are
  recompressed with a secondary algorithm (e.g. zstd)
- Idle page recompression: cold pages recompressed with a more efficient algorithm
- New sysfs: `recomp_algorithm`, `recompress`

**New CONFIG options:**
- `CONFIG_ZRAM_MULTI_COMP` — enable multi-compression streams
- `CONFIG_ZRAM_DEF_RECOMP_ZSTD` — default secondary algorithm: zstd
- Requires: `CONFIG_ZRAM_TRACK_ENTRY_ACTIME` (idle page tracking)

**Patch generation:**
```bash
cd zram66
./generate-patches.sh --linux-dir /path/to/linux-6.6
```

**Affected files:** `drivers/block/zram/Kconfig`, `zcomp.c`, `zcomp.h`,
`zram_drv.c`, `zram_drv.h`

## zsmalloc 6.12: Per-Class Lock Optimization

Backported from Linux 6.12. Three independent parts — only Part A is recommended.

### Part A: per-size_class lock (Recommended, Low Risk)

Reverts the pool spinlock merge (commit c0547d0b6a4b) that was introduced for
the cancelled zsmalloc reclaim feature. Restores per-size_class locking for
better scalability.

**Performance:** sys time 1844s → 1469s (tmpfs + zswap + 10GB swapfile)

**Affected files:** `mm/zsmalloc.c` only

**Patch generation (default, Part A only):**
```bash
cd zsmalloc612
./generate-patches.sh --linux-dir /path/to/linux-6.12
```

### Part B: zpdesc memory descriptor (Experimental, High Risk)

Replaces direct `struct page` usage with an 8-byte `zpdesc` descriptor.
Requires new `mm/zpdesc.h` and extensive function signature changes.
Only attempt on 5.10 baseline with thorough testing.

### Part C: proper page type (Optional, Medium Risk)

Uses proper page type for zsmalloc pages. Modifies `page-flags.h` — may
conflict with QCOM patches. Drops support for PAGE_SIZE > 64KB.

**Generate all parts (including B and C):**
```bash
./generate-patches.sh --linux-dir /path/to/linux-6.12 --all
```

## What CANNOT Be Backported to 4.19

These features require fundamental infrastructure changes that make backporting
to 4.19 impractical or impossible:

- **sched_ext** (6.12) — requires BPF struct_ops (5.6) + SCX dispatch framework
- **PREEMPT_LAZY** (6.13) — requires core preemption model rewrite
- **MGLRU** (6.1) — requires mm/ subsystem rework (MGLRU has a 4.19 backport
  branch but it's unmaintained and conflicts with QCOM patches)
- **EEVDF** (6.6) — requires complete scheduler core rewrite
- **folio** (6.1) — requires page→folio migration across entire mm/ subsystem
- **DAMON** (5.15) — can be backported but conflicts with QCOM mm/ patches

## Recommended Approach

1. Start with **4.19 enhanced** (proven stable, easy backports)
2. Test **5.10 GKI** for native modern features
3. Backport **zram 6.6** on both baselines — high value, moderate effort
4. Backport **zsmalloc 6.12 Part A** on 5.10 — low risk, clear perf win
5. Only attempt **extreme backports** (MGLRU, DAMON) if you have time to
   resolve conflicts and test thoroughly
6. **Never** attempt EEVDF/folio/sched_ext on 4.19 — upgrade to 6.x instead

## Upgrade Path to 6.x (Future)

For truly modern features (sched_ext, EEVDF, MGLRU, folio), the only viable
path is upgrading to Linux 6.1+ or 6.6+. This requires:

- GKI 6.1 kernel source (android13-6.1 or android14-6.1)
- SM8250 device tree port to 6.1
- QCOM driver updates for 6.1 API changes
- Extensive testing

This is a major undertaking (months of work) and should be a separate project.
