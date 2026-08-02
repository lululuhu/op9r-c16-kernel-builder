# Oblivionis-kernel

OnePlus 9R (lemonades / SM8250 / Snapdragon 870) custom kernel based on
LineageOS 4.19.325 with mainline feature backports and aggressive tuning.

## Features

### Base
- Linux 4.19.325 (LineageOS lineage-23.2 branch, CIP stable tree)
- Proton Clang toolchain (Clang 17+)
- ThinLTO + CFI support (configurable via workflow inputs)
- Configurable KPTI/LTO/CFI via workflow inputs
- Kernel name: **Oblivionis-kernel** (shown in /proc/version → About phone)

### Mainline Backports
- **WireGuard** VPN (android-4.19-stable built-in)
- **zram 6.6** multi-compression/recompression (patches downloaded from mainline,
  may require manual adaptation for 4.19 — see patches/mainline-backports/README.md)
- **zsmalloc 6.12** per-class lock (NOT applicable to 4.19 — already has per-class locking)

### Native 4.19 Features Enabled
- PSI (Pressure Stall Information)
- userfaultfd
- XDP sockets (AF_XDP)
- diag char (QCOM diagnostic interface — fixes band-locking tools)
- SCHED_WALT + SCHED_TUNE + SCHED_CORE_CTL (vendor scheduler)
- BPF + BPF_JIT + BPF_LSM
- F2FS with compression (LZ4 + ZSTD)
- EROFS with compression
- Inline encryption (QCOM ICE)
- WireGuard VPN
- TCP BBR congestion control
- fs-verity with signatures
- UCLAMP task utilization clamping

### Scheduler Tuning (Frame-Aware)
- HZ=300 (matches 90Hz/120Hz display, reduces frame jitter)
- NO_HZ_IDLE (reduces timer interrupts on idle CPUs — correct for mobile)
- High-resolution timers
- RCU boost (protects foreground tasks from RCU reclaim)
- PREEMPT (full preemption for lower latency)

### Memory Management
- KSM (page merging)
- zram with writeback + memory tracking
- zsmalloc with stats
- MEMCG (memory cgroup accounting)

### Security
- Stack protector (strong)
- FORTIFY_SOURCE
- Strict kernel/module RWX
- Hardened usercopy
- Refcount full checking
- dm-verity with FEC

### Block I/O
- blk-throttling with low limit
- Writeback throttling (wbt)
- Kyber I/O scheduler (low-latency for NVMe/UFS)
- Deadline I/O scheduler

### Network
- TCP BBR + Fast Open
- FQ + FQ-CoDel + CAKE queueing disciplines
- BPF for networking
- Net namespaces

## Build

### GitHub Actions (Recommended)
1. Go to Actions → "Build Oblivionis-kernel" → "Run workflow"
2. Select config variant: `extreme` (full features), `advanced`, or `perf`
3. Toggle LTO/KPTI/CFI as needed
4. Download artifact from the completed run

### Local Build
```bash
./build.sh
# Or with options:
CONFIG_VARIANT=extreme ENABLE_LTO=true ./build.sh
```
Requires: clang, ld.lld, aarch64-linux-gnu-gcc, pahole, python3

## Flash

### Via TWRP Recovery
1. Download `Oblivionis-kernel-4.19-extreme-XX.zip`
2. Transfer to device
3. Boot into TWRP
4. Install the zip
5. Reboot

### Via Fastboot
```bash
fastboot flash boot Image
```

## Important Notes

### Kernel Version String
The kernel version appears in Settings → About phone → Kernel version:
```
Linux version 4.19.325-Oblivionis-kernel (Oblivionis@lemonades) ...
```
- Version prefixes (`-cip132-st16`) are cleaned from Makefile EXTRAVERSION and localversion files
- `-Oblivionis-kernel` is our CONFIG_LOCALVERSION
- Build user/host set to `Oblivionis@lemonades` (hides CI runner info)
- No `+` suffix (git dirty state suppressed via LOCALVERSION_AUTO= and .scmversion)

### Root (Magisk/KernelSU/SukiSU)
AnyKernel3 flashes the kernel to the boot partition. If you use SukiSU/KernelSU
in "builtin" mode, it will **replace** this kernel with its own patched version.
To keep Oblivionis-kernel AND have root:
- Use **Magisk** (patches boot image, preserves our kernel)
- OR integrate KernelSU/SukiSU into the kernel source before building

### Module Signing
Module signing is **disabled**. Vendor modules use OEM keys that we don't have.
Enabling `MODULE_SIG_FORCE` would block all vendor modules and cause boot failure.

### What Does NOT Work on 4.19
- MGLRU (needs 6.1+ mm/ rework)
- DAMON (needs 5.15+)
- EEVDF scheduler (needs 6.6+)
- sched_ext (needs 6.12+)
- folio (needs 6.1+)
- zram multi-compression (6.6 patches don't apply to 4.19 codebase — manual port needed)
- zsmalloc per-class lock revert (4.19 already has per-class locking)

## Config Variants

| Variant | Description |
|---------|-------------|
| `perf` | Performance-first, stable, minimal features |
| `advanced` | PSI + CFI + fs-verity + BBR + advanced IO |
| `extreme` | Full backports + scheduler tuning + all optimizations |

## Repository Structure
```
.github/workflows/build.yml  — CI/CD build pipeline
configs/                     — Kernel config fragments
  lemonades_c16_extreme.fragment   — Full feature set + tuning
  lemonades_c16_advanced.fragment  — Advanced features
  lemonades_c16_perf.fragment      — Performance-first
patches/mainline-backports/  — Backport patch scripts and documentation
  apply-backports.sh              — Automated patch application
  zram66/                         — zram 6.6 multi-compression (generate-patches.sh)
  zsmalloc612/                    — zsmalloc 6.12 per-class lock (generate-patches.sh)
  cherry-pick-mainline.sh         — Alternative: git cherry-pick from mainline
templates/anykernel.sh       — AnyKernel3 flashing template
build.sh                     — Local build script
```
