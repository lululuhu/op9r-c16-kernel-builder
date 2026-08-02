#!/bin/bash
# ===================================================================
# build.sh — Local build script for Oblivionis-kernel
# OnePlus 9R (lemonades / SM8250) — 4.19 baseline with mainline backports
# Can also be used to reproduce the GitHub Actions build locally.
# ===================================================================
set -e

# ---- Configuration ----
DEVICE="${DEVICE:-lemonades}"
KERNEL_BRANCH="${KERNEL_BRANCH:-lineage-23.2}"
KERNEL_REPO="${KERNEL_REPO:-LineageOS/android_kernel_oneplus_sm8250}"
ANYKERNEL_REPO="${ANYKERNEL_REPO:-osm0sis/AnyKernel3}"
ENABLE_LTO="${ENABLE_LTO:-true}"
ENABLE_KPTI="${ENABLE_KPTI:-false}"  # false = kpti=off (performance)
CONFIG_VARIANT="${CONFIG_VARIANT:-extreme}"  # perf | advanced | extreme
WORKDIR="${WORKDIR:-$(pwd)/build_workspace}"

export ARCH=arm64
export SUBARCH=arm64

# ---- Colors ----
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
log()  { echo -e "${CYAN}[$(date +%H:%M:%S)]${NC} $*"; }
ok()   { echo -e "${GREEN}[OK]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()  { echo -e "${RED}[ERR]${NC} $*"; }

# ---- Step 1: Check dependencies ----
log "Checking dependencies..."
for cmd in clang ld.lld git make python3 pahole; do
    if ! command -v "$cmd" &>/dev/null; then
        err "Missing: $cmd. Install it first."
        exit 1
    fi
done
PAHOLE_VER=$(pahole --version 2>/dev/null | grep -oP '\d+\.\d+' | head -1)
log "pahole version: $PAHOLE_VER (need >= 1.16 for BTF)"
ok "Dependencies OK"

# ---- Step 2: Setup workspace ----
mkdir -p "$WORKDIR"
cd "$WORKDIR"

# ---- Step 3: Clone toolchain (Proton Clang) ----
if [ ! -d "clang" ]; then
    log "Cloning Proton Clang toolchain..."
    git clone --depth=1 https://github.com/kdrag0n/proton-clang clang
fi
export PATH="$WORKDIR/clang/bin:$PATH"
CLANG_VER=$(clang --version | head -1)
ok "Toolchain: $CLANG_VER"

# ---- Step 4: Clone kernel source ----
if [ ! -d "kernel" ]; then
    log "Cloning kernel source: $KERNEL_REPO ($KERNEL_BRANCH)..."
    git clone --depth=1 -b "$KERNEL_BRANCH" "https://github.com/$KERNEL_REPO" kernel
fi
cd kernel
log "Kernel source ready: $(head -1 Makefile)"
git log --oneline -1

# ---- Step 5b: Clean version string for Oblivionis branding ----
log "Cleaning version string prefixes (-cip132 -st16 etc.)..."
# LineageOS/CIP kernel 在 Makefile EXTRAVERSION 和 localversion* 文件注入后缀
# 清理后 /proc/version 显示干净的: 4.19.325-Oblivionis-kernel
sed -i 's/^EXTRAVERSION = .*/EXTRAVERSION =/' Makefile
rm -f localversion* 2>/dev/null || true
ok "Version string cleaned"

# ---- Step 5: Apply patches ----
PATCH_DIR="$(dirname "$0")/patches"
if [ -d "$PATCH_DIR" ] && ls "$PATCH_DIR"/*.patch 1>/dev/null 2>&1; then
    for p in "$PATCH_DIR"/*.patch; do
        log "Applying patch: $(basename "$p")"
        git apply --verbose "$p" || warn "Patch failed: $(basename "$p")"
    done
else
    log "No patches to apply."
fi

# ---- Step 6: Fix GCC 11 vendor code issues ----
log "Fixing GCC 11 vendor code issues..."
# Fix 1: oplus_adfr.h — inline without function body
if [ -f "techpack/display/oplus/oplus_adfr.h" ]; then
    sed -i 's/inline bool oplus_adfr_is_support(void);/bool oplus_adfr_is_support(void);/' techpack/display/oplus/oplus_adfr.h
fi
# Fix 2: oplus_display_panel.h — C++11 enum base type syntax
if [ -f "techpack/display/oplus/oplus_display_panel.h" ]; then
    sed -i 's/enum APOLLO_BL_ID : int {/enum APOLLO_BL_ID {/' techpack/display/oplus/oplus_display_panel.h
fi
# Fix 3: thread_info.h — __bad_copy_to compile-time assertion
if [ -f "include/linux/thread_info.h" ]; then
    sed -i \
      -e '/extern void __compiletime_error("copy source size is too small")/{N;s/.*/static inline void __bad_copy_from(void) { }/}' \
      -e '/extern void __compiletime_error("copy destination size is too small")/{N;s/.*/static inline void __bad_copy_to(void) { }/}' \
      include/linux/thread_info.h
fi
ok "Vendor code fixes applied"

# ---- Step 7: Find and merge defconfig ----
DEFCFG=""
for f in \
    arch/arm64/configs/vendor/kona-perf_defconfig \
    arch/arm64/configs/vendor/kona_defconfig; do
    if [ -f "$f" ]; then DEFCFG="$f"; break; fi
done
if [ -z "$DEFCFG" ]; then
    err "defconfig not found!"
    find arch/arm64/configs -name "*kona*" -o -name "*lemonade*" 2>/dev/null
    exit 1
fi
ok "Base defconfig: $DEFCFG"
MAKE_TARGET="${DEFCFG#arch/arm64/configs/}"

log "Generating base config..."
make O=out ARCH=arm64 "$MAKE_TARGET"

# Append oplus.config if present
if [ -f "arch/arm64/configs/vendor/oplus.config" ]; then
    log "Appending oplus.config..."
    cat arch/arm64/configs/vendor/oplus.config >> out/.config
fi

FRAGMENT="$(dirname "$0")/configs/lemonades_c16_${CONFIG_VARIANT}.fragment"
if [ -f "$FRAGMENT" ]; then
    log "Appending config fragment ($CONFIG_VARIANT)..."
    grep -v '^#' "$FRAGMENT" | grep -v '^$' >> out/.config
else
    warn "Fragment not found: $FRAGMENT — using defconfig only"
fi

log "Running olddefconfig..."
make O=out ARCH=arm64 olddefconfig

# ---- Step 8: Apply runtime toggles ----
log "Applying runtime toggles..."

# Set kernel name to Oblivionis-kernel (shows in /proc/version → About phone)
./scripts/config --file out/.config --set-str LOCALVERSION "-Oblivionis-kernel"
./scripts/config --file out/.config --disable LOCALVERSION_AUTO

if [ "$ENABLE_KPTI" = "false" ]; then
    log "KPTI: OFF (performance mode)"
    ./scripts/config --file out/.config --enable CMDLINE --set-str CMDLINE "kpti=off"
else
    log "KPTI: ON (security mode)"
    ./scripts/config --file out/.config --disable CMDLINE
fi

if [ "$ENABLE_LTO" = "true" ]; then
    log "Enabling ThinLTO..."
    ./scripts/config --file out/.config --enable LTO_CLANG_THIN --disable LTO_NONE
fi

# CRITICAL: Disable module signing — vendor modules use OEM keys
./scripts/config --file out/.config --disable MODULE_SIG
./scripts/config --file out/.config --disable MODULE_SIG_FORCE
./scripts/config --file out/.config --disable MODULE_SIG_ALL

# Disable BTF to avoid resolve_btfids build tool issue
./scripts/config --file out/.config --disable DEBUG_INFO_BTF

# Ensure oplus vendor hooks enabled
./scripts/config --file out/.config --enable ANDROID_VENDOR_HOOKS

# ---- Hibernation: 手机无用，关闭以减少攻击面 ----
./scripts/config --file out/.config --disable HIBERNATION
./scripts/config --file out/.config --disable HIBERNATE_CALLBACKS
./scripts/config --file out/.config --disable PM_AUTOSLEEP

# ---- NO_HZ: 移动端使用 NO_HZ_IDLE (非 NO_HZ_FULL) ----
./scripts/config --file out/.config --disable NO_HZ_FULL
./scripts/config --file out/.config --disable NO_HZ_FULL_ALL
./scripts/config --file out/.config --disable RCU_NOCB_CPU
./scripts/config --file out/.config --enable NO_HZ_IDLE

# ---- 安全加固: 关闭 usercopy 回退 ----
./scripts/config --file out/.config --disable HARDENED_USERCOPY_FALLBACK

# ---- I/O 调度器: 默认 mq-deadline ----
./scripts/config --file out/.config --set-str DEFAULT_IOSCHED "mq-deadline"

# ---- 调度器增强: util_est (5.0 主线，ACK 4.19 可能已包含) ----
./scripts/config --file out/.config --enable SCHED_UTIL_EST 2>/dev/null || true
./scripts/config --file out/.config --enable SCHED_UTIL_EST_FASTUP 2>/dev/null || true

# ---- KFENCE: 近零开销内存安全检测 (5.12 backport) ----
# 如果 backport 补丁成功应用则启用，否则 olddefconfig 忽略
./scripts/config --file out/.config --enable KFENCE 2>/dev/null || true
./scripts/config --file out/.config --set-val KFENCE_SAMPLE_INTERVAL 100 2>/dev/null || true
./scripts/config --file out/.config --set-val KFENCE_NUM_OBJECTS 255 2>/dev/null || true

# ---- slab/slub 安全加固 ----
./scripts/config --file out/.config --enable SLAB_FREELIST_RANDOM
./scripts/config --file out/.config --enable SLAB_FREELIST_HARDENED
./scripts/config --file out/.config --enable INIT_ON_ALLOC_DEFAULT_ON
# INIT_ON_FREE 有 ~5-10% 性能损耗，生产环境关闭
./scripts/config --file out/.config --disable INIT_ON_FREE_DEFAULT_ON

# ---- 关闭调度器调试开销 ----
./scripts/config --file out/.config --disable SCHED_DEBUG
./scripts/config --file out/.config --disable SCHEDSTATS
./scripts/config --file out/.config --disable ZSMALLOC_STAT
./scripts/config --file out/.config --disable ZRAM_MEMORY_TRACKING

# Disable XDP_SOCKETS_DIAG — 4.19 xdp_umem struct missing fields
./scripts/config --file out/.config --disable XDP_SOCKETS_DIAG

log "Running olddefconfig (final)..."
make O=out ARCH=arm64 olddefconfig

# ---- Step 9: Build ----
export CC=clang
export CXX=clang++
export LD=ld.lld
export AR=llvm-ar
export NM=llvm-nm
export OBJCOPY=llvm-objcopy
export OBJDUMP=llvm-objdump
export STRIP=llvm-strip
export CROSS_COMPILE=aarch64-linux-gnu-
export CROSS_COMPILE_ARM32=arm-linux-gnueabi-

# Vendor code warnings → non-fatal
# NOTE: -ftrivial-auto-var-init=zero 是 Clang 选项，不能放在 KCFLAGS 里
#   因为 KCFLAGS 也会传给 GCC 编译的 host 工具 (scripts/mod/)，GCC 不认识会报错。
#   改用 CFLAGS_CLANG 分离: 仅内核代码用 Clang 编译时生效。
export KCFLAGS="-Wno-error -Wno-unused-function -Wno-unused-variable -U_FORTIFY_SOURCE"
export CFLAGS_GCC="-Wno-error -Wno-unused-function -Wno-unused-variable"
export CFLAGS_CLANG="-ftrivial-auto-var-init=zero"

# 隐藏 CI 构建信息，使 /proc/version 显示 (Oblivionis@lemonades) 而非 (runner@runnervmliwqe)
export KBUILD_BUILD_USER=Oblivionis
export KBUILD_BUILD_HOST=lemonades

# Suppress git-based version suffix (+) — patches make git tree "dirty"
printf '' > .scmversion
export SCMVERSION=""

log "=== .config highlights ==="
grep -E "LOCALVERSION|BPF_SYSCALL|F2FS_FS|EROFS_FS|BLK_INLINE|PREEMPT|ZRAM|HZ=|SCHED_WALT|SCHED_UTIL_EST|KFENCE|SLAB_FREELIST|INIT_ON_ALLOC|INIT_ON_FREE|ZSWAP|UCLAMP|PSI|OVERLAY_FS|UKSM|ADIOS|MQ_IOSCHED|TRANSPARENT_HUGEPAGE|TCP_CONG|NET_SCH_FQ|NET_SCH_CAKE" out/.config

log "Building Oblivionis-kernel (variant=$CONFIG_VARIANT, this takes 10-30 min)..."
make O=out ARCH=arm64 LOCALVERSION_AUTO= -j"$(nproc)" 2>&1 | tail -100

# ---- Step 10: Verify ----
KERNEL_IMG=""
for f in out/arch/arm64/boot/Image.gz-dtb out/arch/arm64/boot/Image.gz out/arch/arm64/boot/Image; do
    if [ -f "$f" ]; then KERNEL_IMG="$f"; break; fi
done
if [ -z "$KERNEL_IMG" ]; then
    err "Build FAILED — no kernel image found"
    ls -la out/arch/arm64/boot/ 2>/dev/null || true
    exit 1
fi
ok "Build successful!"
ls -la "$KERNEL_IMG"

# Print version string to verify Oblivionis name
VERSION_STR=$(strings "$KERNEL_IMG" | grep -m1 "Linux version" || true)
echo "Version: $VERSION_STR"
if echo "$VERSION_STR" | grep -q "Oblivionis"; then
    ok "Oblivionis-kernel name found in version string"
else
    warn "Oblivionis-kernel name NOT found — check CONFIG_LOCALVERSION"
fi

# ---- Step 11: Package with AnyKernel3 ----
cd "$WORKDIR"
if [ ! -d "AnyKernel3" ]; then
    git clone --depth=1 "https://github.com/$ANYKERNEL_REPO" AnyKernel3
fi
cd AnyKernel3
cp "$WORKDIR/kernel/$KERNEL_IMG" kernel
if [ -f "$WORKDIR/kernel/out/arch/arm64/boot/dtb" ]; then
    cp "$WORKDIR/kernel/out/arch/arm64/boot/dtb" dtb
fi
if [ -f "$WORKDIR/kernel/out/arch/arm64/boot/dtbo.img" ]; then
    cp "$WORKDIR/kernel/out/arch/arm64/boot/dtbo.img" dtbo.img
fi

# Copy anykernel.sh from template
cp "$(dirname "$0")/templates/anykernel.sh" anykernel.sh
ok "AnyKernel3 config copied from template"

# ---- Oblivionis: copy ramdisk tuning script ----
if [ -d "$(dirname "$0")/templates/ramdisk" ]; then
    mkdir -p ramdisk
    cp -r "$(dirname "$0")/templates/ramdisk/"* ramdisk/
    ok "Ramdisk tuning script injected"
    ls -la ramdisk/
else
    warn "No ramdisk directory found, skipping tuning injection"
fi

ZIP_NAME="Oblivionis-kernel-4.19-${CONFIG_VARIANT}"
zip -r9 "${ZIP_NAME}.zip" * -x '*.git*' -x '*.git/*'
ok "Package: $WORKDIR/AnyKernel3/${ZIP_NAME}.zip"
ls -la "${ZIP_NAME}.zip"

echo ""
ok "=== BUILD COMPLETE ==="
echo "  Kernel Image: $WORKDIR/kernel/$KERNEL_IMG"
echo "  Flash zip:    $WORKDIR/AnyKernel3/${ZIP_NAME}.zip"
echo ""
echo "  Flash via fastboot:  fastboot flash boot Image"
echo "  Flash via recovery:  install ${ZIP_NAME}.zip"
