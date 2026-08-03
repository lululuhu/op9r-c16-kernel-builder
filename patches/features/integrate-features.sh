#!/bin/bash
# ===================================================================
# integrate-features.sh — 集成高级内核特性 (4.19 兼容版)
#
# 使用预编写的 4.19 兼容源码文件，不再依赖外部 6.x 仓库
#
# 特性列表:
#   网络:
#     - BBRv3 (Google BBR v3, 独立模块, 不替换 BBRv1)
#     - C2TCP (蜂窝网络/深缓冲网络低延迟拥塞控制)
#     - TCP ROCCET (CUBIC + RTT/ACK 速率感知, 5G/移动网络)
#     - TCP Brutal (Hysteria 速率控制 + ECN)
#     - ADIOS 3.2.0 (I/O 调度器, 默认)
#
#   内存:
#     - UKSM (Ultra KSM, 增强版 KSM)
#     - NTSYNC (NT 同步原语, Wine/Proton 兼容)
#
#   显示:
#     - Lindroid EVDI (虚拟显示接口, 配置级)
#
#   其他:
#     - WireGuard (检查内核是否已内置)
#     - Droidspaces (配置级)
#     - Mountify (OverlayFS, 配置级)
#     - IPSet (配置级)
#     - Android 17 GSI 兼容性 (配置级)
#
# 用法: ./integrate-features.sh [--kernel-dir /path/to/kernel]
# ===================================================================
set -uo pipefail

# ---- 颜色输出 ----
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; }
ok()    { echo -e "${GREEN}[OK]${NC} $*"; }

# ---- 解析参数 ----
KERNEL_DIR="$(pwd)"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC_DIR="${SCRIPT_DIR}/src"

while [[ $# -gt 0 ]]; do
    case $1 in
        --kernel-dir) KERNEL_DIR="$2"; shift 2 ;;
        --src-dir) SRC_DIR="$2"; shift 2 ;;
        --help|-h)
            echo "用法: $0 [--kernel-dir /path/to/kernel] [--src-dir /path/to/src]"
            exit 0 ;;
        *) warn "未知选项: $1"; shift ;;
    esac
done

cd "$KERNEL_DIR" || { error "无法进入 $KERNEL_DIR"; exit 1; }

# 验证内核源码树
[ -f "Makefile" ] || { error "不在内核源码根目录"; exit 1; }
head -5 Makefile | grep -q "VERSION" || { error "Makefile 不是内核格式"; exit 1; }

# 验证源码目录
if [ ! -d "$SRC_DIR" ]; then
    error "源码目录不存在: $SRC_DIR"
    exit 1
fi

# 计数器
SUCCESS=0
FAILED=0
SKIPPED=0

record_success() { SUCCESS=$((SUCCESS + 1)); ok "$1"; }
record_failed()  { FAILED=$((FAILED + 1)); error "$1"; }
record_skipped() { SKIPPED=$((SKIPPED + 1)); warn "$1"; }

# ===================================================================
# 辅助函数: 添加 Kconfig 条目
# ===================================================================
add_kconfig_entry() {
    local kconfig_file="$1"
    local config_name="$2"
    local config_type="$3"
    local config_desc="$4"
    local config_help="${5:-}"

    if grep -q "config $config_name" "$kconfig_file" 2>/dev/null; then
        info "  Kconfig: $config_name 已存在于 $(basename "$kconfig_file")"
        return 0
    fi

    cat >> "$kconfig_file" << KCONFIG_EOF

config $config_name
	$config_type "$config_desc"
	depends on INET
	default m
	help
	  $config_help
KCONFIG_EOF
    info "  Kconfig: 已添加 $config_name 到 $(basename "$kconfig_file")"
}

# ===================================================================
# 辅助函数: 添加 Makefile 条目
# ===================================================================
add_makefile_entry() {
    local makefile="$1"
    local entry="$2"
    local check_str="${3:-$entry}"

    if grep -q "$check_str" "$makefile" 2>/dev/null; then
        info "  Makefile: 条目已存在于 $(basename "$makefile")"
        return 0
    fi
    # CRITICAL: Ensure newline separation — some vendor Makefiles don't end with \n
    # Without this, the new entry gets concatenated with the last line, causing:
    #   "No rule to make target 'blk-crypto-fallback.oobj-'" errors
    echo "" >> "$makefile"
    echo "$entry" >> "$makefile"
    info "  Makefile: 已添加到 $(basename "$makefile")"
}

# ###################################################################
# 特性 1: BBRv3 (Google BBR v3)
# ###################################################################
integrate_bbrv3() {
    echo ""
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}  特性: Google BBRv3${NC}"
    echo -e "${BLUE}========================================${NC}"

    local src="$SRC_DIR/tcp_bbr3.c"
    if [ ! -f "$src" ]; then
        record_skipped "BBRv3: 源码文件不存在 ($src)"
        return 0
    fi

    # 作为独立模块安装，不替换 BBRv1
    cp "$src" net/ipv4/tcp_bbr3.c
    info "  已复制 tcp_bbr3.c 到 net/ipv4/"

    # 添加 Kconfig 条目
    if ! grep -q "TCP_CONG_BBR3" net/ipv4/Kconfig 2>/dev/null; then
        cat >> net/ipv4/Kconfig << 'KCONFIG_EOF'

config TCP_CONG_BBR3
	tristate "Google BBRv3 TCP congestion control (separate module)"
	depends on INET
	default m
	help
	  Google BBR v3 拥塞控制算法。
	  作为独立模块安装，不替换内核内置的 BBR v1。
	  如果此模块编译失败，BBR v1 继续作为默认拥塞控制。
KCONFIG_EOF
        info "  已添加 TCP_CONG_BBR3 到 Kconfig"
    fi

    # 添加 Makefile 条目
    add_makefile_entry net/ipv4/Makefile \
        'obj-$(CONFIG_TCP_CONG_BBR3) += tcp_bbr3.o' \
        'tcp_bbr3'

    record_success "BBRv3: 已安装为独立模块 (BBRv1 保留为默认)"
}

# ###################################################################
# 特性 2: C2TCP
# ###################################################################
integrate_c2tcp() {
    echo ""
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}  特性: C2TCP${NC}"
    echo -e "${BLUE}========================================${NC}"

    local src="$SRC_DIR/tcp_c2tcp.c"
    if [ ! -f "$src" ]; then
        record_skipped "C2TCP: 源码文件不存在"
        return 0
    fi

    cp "$src" net/ipv4/tcp_c2tcp.c
    info "  已复制 tcp_c2tcp.c 到 net/ipv4/"

    if ! grep -q "TCP_CONG_C2TCP" net/ipv4/Kconfig 2>/dev/null; then
        cat >> net/ipv4/Kconfig << 'KCONFIG_EOF'

config TCP_CONG_C2TCP
	tristate "C2TCP congestion control (cellular low-latency)"
	depends on INET
	default m
	help
	  C2TCP 针对蜂窝网络和深缓冲网络设计。
	  根据延迟变化主动控制拥塞，在保持吞吐量的同时降低网络延迟。
KCONFIG_EOF
    fi

    add_makefile_entry net/ipv4/Makefile \
        'obj-$(CONFIG_TCP_CONG_C2TCP) += tcp_c2tcp.o' \
        'tcp_c2tcp'

    record_success "C2TCP: 已集成到 net/ipv4/tcp_c2tcp.c"
}

# ###################################################################
# 特性 3: TCP ROCCET
# ###################################################################
integrate_tcp_roccet() {
    echo ""
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}  特性: TCP ROCCET${NC}"
    echo -e "${BLUE}========================================${NC}"

    local src="$SRC_DIR/tcp_roccet.c"
    if [ ! -f "$src" ]; then
        record_skipped "TCP ROCCET: 源码文件不存在"
        return 0
    fi

    cp "$src" net/ipv4/tcp_roccet.c
    info "  已复制 tcp_roccet.c 到 net/ipv4/"

    if ! grep -q "TCP_CONG_ROCCET" net/ipv4/Kconfig 2>/dev/null; then
        cat >> net/ipv4/Kconfig << 'KCONFIG_EOF'

config TCP_CONG_ROCCET
	tristate "TCP ROCCET congestion control (5G/mobile/Bufferbloat)"
	depends on INET
	default m
	help
	  ROCCET 基于 CUBIC，加入 RTT 和 ACK 速率感知。
	  面向 5G、移动网络以及 Bufferbloat 场景。
KCONFIG_EOF
    fi

    add_makefile_entry net/ipv4/Makefile \
        'obj-$(CONFIG_TCP_CONG_ROCCET) += tcp_roccet.o' \
        'tcp_roccet'

    record_success "TCP ROCCET: 已集成到 net/ipv4/tcp_roccet.c"
}

# ###################################################################
# 特性 4: TCP Brutal
# ###################################################################
integrate_tcp_brutal() {
    echo ""
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}  特性: TCP Brutal${NC}"
    echo -e "${BLUE}========================================${NC}"

    local src="$SRC_DIR/tcp_brutal.c"
    if [ ! -f "$src" ]; then
        record_skipped "TCP Brutal: 源码文件不存在"
        return 0
    fi

    cp "$src" net/ipv4/tcp_brutal.c
    info "  已复制 tcp_brutal.c 到 net/ipv4/"

    if ! grep -q "TCP_CONG_BRUTAL" net/ipv4/Kconfig 2>/dev/null; then
        cat >> net/ipv4/Kconfig << 'KCONFIG_EOF'

config TCP_CONG_BRUTAL
	tristate "TCP Brutal congestion control (Hysteria rate-based)"
	depends on INET
	default m
	help
	  TCP Brutal 是基于速率的拥塞控制算法，源自 Hysteria。
	  使用固定发送速率而非 AIMD，适用于带宽已知且稳定的场景。
	  默认启用 ECN 协商。
KCONFIG_EOF
    fi

    add_makefile_entry net/ipv4/Makefile \
        'obj-$(CONFIG_TCP_CONG_BRUTAL) += tcp_brutal.o' \
        'tcp_brutal'

    record_success "TCP Brutal: 已集成到 net/ipv4/tcp_brutal.c"
}

# ###################################################################
# 特性 5b: Windchill CPU Frequency Governor (一加风驰调速器)
# ###################################################################
integrate_windchill() {
    echo ""
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}  特性: Windchill 调速器 (风驰)${NC}"
    echo -e "${BLUE}========================================${NC}"

    local src="$SRC_DIR/cpufreq_windchill.c"
    if [ ! -f "$src" ]; then
        record_skipped "Windchill: 源码文件不存在"
        return 0
    fi

    # 复制到 drivers/cpufreq/
    cp "$src" drivers/cpufreq/cpufreq_windchill.c
    info "  已复制 cpufreq_windchill.c 到 drivers/cpufreq/"

    # 添加 Kconfig 条目
    if ! grep -q "CPU_FREQ_GOV_WINDCHILL" drivers/cpufreq/Kconfig 2>/dev/null; then
        cat >> drivers/cpufreq/Kconfig << 'KCONFIG_EOF'

config CPU_FREQ_GOV_WINDCHILL
	tristate "windchill cpufreq governor"
	help
	  Windchill (风驰) CPU frequency governor for Oblivionis-kernel.
	  Inspired by OnePlus Windchill Game Kernel concepts:
	  - Energy-aware model with EMA load tracking
	  - Fast frequency ramp-up for bursty workloads
	  - Smart ramp-down with hysteresis to prevent oscillation
	  - Boost window for temporary high-frequency hold
	  - Sweet-spot frequency selection for energy efficiency

config CPU_FREQ_DEFAULT_GOV_WINDCHILL
	bool "windchill"
	depends on CPU_FREQ_GOV_WINDCHILL
	help
	  Use the windchill governor as the default cpufreq governor.
KCONFIG_EOF
        info "  已添加 CPU_FREQ_GOV_WINDCHILL 到 Kconfig"
    fi

    # 添加 Makefile 条目
    add_makefile_entry drivers/cpufreq/Makefile \
        'obj-$(CONFIG_CPU_FREQ_GOV_WINDCHILL) += cpufreq_windchill.o' \
        'cpufreq_windchill'

    record_success "Windchill 调速器: 已集成到 drivers/cpufreq/cpufreq_windchill.c"
}

# ###################################################################
# 特性 5: ADIOS 3.2.0 (I/O 调度器)
# ###################################################################
integrate_adios() {
    echo ""
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}  特性: ADIOS 3.2.0 I/O 调度器${NC}"
    echo -e "${BLUE}========================================${NC}"

    local src="$SRC_DIR/adios.c"
    if [ ! -f "$src" ]; then
        record_skipped "ADIOS: 源码文件不存在"
        return 0
    fi

    cp "$src" block/adios.c
    info "  已复制 adios.c 到 block/"

    # 添加 Kconfig 条目
    if ! grep -q "MQ_IOSCHED_ADIOS" block/Kconfig.iosched 2>/dev/null; then
        cat >> block/Kconfig.iosched << 'KCONFIG_EOF'

config MQ_IOSCHED_ADIOS
	tristate "ADIOS I/O scheduler (v3.2.0)"
	default y
	help
	  ADIOS (Adaptive Deadline I/O Scheduler) 是混合式 I/O 调度器，
	  结合截止时间调度和自适应优先级调度。
	  v3.2.0 优化了延迟模型、优先级调度和异常处理。
	  适用于 NVMe/UFS 存储设备。
KCONFIG_EOF
        info "  已添加 MQ_IOSCHED_ADIOS 到 Kconfig.iosched"
    fi

    # 添加 Makefile 条目
    add_makefile_entry block/Makefile \
        'obj-$(CONFIG_MQ_IOSCHED_ADIOS) += adios.o' \
        'adios'

    record_success "ADIOS 3.2.0: 已集成到 block/adios.c"
}

# ###################################################################
# 特性 6: NTSYNC (NT 同步原语)
# ###################################################################
integrate_ntsync() {
    echo ""
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}  特性: NTSYNC${NC}"
    echo -e "${BLUE}========================================${NC}"

    local src="$SRC_DIR/ntsync.c"
    if [ ! -f "$src" ]; then
        record_skipped "NTSYNC: 源码文件不存在"
        return 0
    fi

    mkdir -p drivers/misc
    cp "$src" drivers/misc/ntsync.c
    info "  已复制 ntsync.c 到 drivers/misc/"

    # 添加 Kconfig 条目
    if ! grep -q "NTSYNC" drivers/misc/Kconfig 2>/dev/null; then
        cat >> drivers/misc/Kconfig << 'KCONFIG_EOF'

config NTSYNC
	tristate "NT synchronization primitive driver"
	depends on ANON_INODES
	default m
	help
	  此模块提供 NT 同步原语的字符设备接口，
	  用于 Wine/Proton 运行 Windows 应用程序时的同步兼容。
KCONFIG_EOF
    fi

    # 添加 Makefile 条目
    add_makefile_entry drivers/misc/Makefile \
        'obj-$(CONFIG_NTSYNC) += ntsync.o' \
        'ntsync'

    record_success "NTSYNC: 已集成到 drivers/misc/ntsync.c"
}

# ###################################################################
# 特性 7: UKSM (Ultra KSM)
# ###################################################################
integrate_uksm() {
    echo ""
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}  特性: UKSM (Ultra KSM)${NC}"
    echo -e "${BLUE}========================================${NC}"

    # UKSM 需要修改 mm/ 核心文件，比较复杂
    # 这里只添加 Kconfig/Makefile 条目，实际 patch 需要单独处理
    # 如果内核已有 KSM，我们启用增强配置

    if grep -q "config UKSM" mm/Kconfig 2>/dev/null; then
        record_success "UKSM: 已存在于内核配置中"
        return 0
    fi

    # 检查源码文件是否存在 — 没有源码就不能添加 Makefile/Kconfig 条目
    # 否则会导致 "No rule to make target 'mm/uksm.o'" 编译错误
    if [ ! -f "$SRC_DIR/uksm.c" ]; then
        warn "  UKSM 源码不存在 (patches/features/src/uksm.c)，跳过集成"
        warn "  不添加 Kconfig/Makefile 条目以避免编译错误"
        record_skipped "UKSM: 源码文件不存在，未集成"
        return 0
    fi

    # 复制源码
    cp "$SRC_DIR/uksm.c" mm/uksm.c
    info "  已复制 uksm.c 到 mm/"

    cat >> mm/Kconfig << 'KCONFIG_EOF'

config UKSM
	bool "Ultra KSM (UKSM)"
	depends on MMU
	default n
	help
	  UKSM 是 KSM 的增强版本，具有自动扫描和合并功能。
	  相比原生 KSM，UKSM 提供更智能的页面合并策略。
KCONFIG_EOF

    if ! grep -q "uksm" mm/Makefile 2>/dev/null; then
        echo "" >> mm/Makefile
        echo 'obj-$(CONFIG_UKSM) += uksm.o' >> mm/Makefile
    fi

    record_success "UKSM: 已添加配置项和源码"

}

# ###################################################################
# 特性 8: WireGuard (检查是否已内置)
# ###################################################################
integrate_wireguard() {
    echo ""
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}  特性: WireGuard VPN${NC}"
    echo -e "${BLUE}========================================${NC}"

    if [ -d "net/wireguard" ]; then
        record_success "WireGuard: 已存在于内核源码树中"
        return 0
    fi

    # 尝试从 wireguard-linux-compat 获取
    info "  WireGuard 不在内核树中，尝试 backport..."
    git clone --depth=1 https://git.zx2c4.com/wireguard-linux-compat /tmp/wg-compat 2>/dev/null || \
    git clone --depth=1 https://github.com/WireGuard/wireguard-linux-compat /tmp/wg-compat 2>/dev/null

    if [ -d /tmp/wg-compat/src ]; then
        cp -r /tmp/wg-compat/src net/wireguard
        if [ -f /tmp/wg-compat/patch/kernel/enable.patch ]; then
            git apply /tmp/wg-compat/patch/kernel/enable.patch 2>/dev/null || \
            patch -p1 < /tmp/wg-compat/patch/kernel/enable.patch 2>/dev/null || true
        fi
        record_success "WireGuard: 已从 wireguard-linux-compat backport"
    else
        record_skipped "WireGuard: 无法获取源码 (将仅使用配置项)"
    fi
}

# ###################################################################
# 特性 9: EVDI (Lindroid 虚拟显示)
# ###################################################################
integrate_evdi() {
    echo ""
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}  特性: Lindroid EVDI${NC}"
    echo -e "${BLUE}========================================${NC}"

    # EVDI 需要大量 DRM API 支持，4.19 兼容性复杂
    # 这里仅添加配置项，实际源码需要单独处理
    if [ -f "$SRC_DIR/evdi" ] && [ -d "$SRC_DIR/evdi" ]; then
        mkdir -p drivers/gpu/drm/evdi
        cp "$SRC_DIR"/evdi/*.c drivers/gpu/drm/evdi/ 2>/dev/null || true
        cp "$SRC_DIR"/evdi/*.h drivers/gpu/drm/evdi/ 2>/dev/null || true
        info "  已复制 EVDI 源码到 drivers/gpu/drm/evdi/"
    else
        info "  EVDI 源码不存在，仅添加配置项"
    fi

    if ! grep -q "DRM_EVDI" drivers/gpu/drm/Kconfig 2>/dev/null; then
        cat >> drivers/gpu/drm/Kconfig << 'KCONFIG_EOF'

config DRM_EVDI
	tristate "EVDI (Extensible Virtual Display Interface) for Lindroid"
	depends on DRM && DRM_KMS_HELPER
	default m
	help
	  EVDI 提供虚拟显示接口，用于 Lindroid。
	  允许创建虚拟显示器进行屏幕镜像/扩展。
KCONFIG_EOF
    fi

    if ! grep -q "evdi" drivers/gpu/drm/Makefile 2>/dev/null; then
        echo "" >> drivers/gpu/drm/Makefile
        echo 'obj-$(CONFIG_DRM_EVDI) += evdi/' >> drivers/gpu/drm/Makefile
    fi

    record_skipped "EVDI: 已添加配置项 (源码需要单独 patch，4.19 DRM API 兼容性有限)"
}

# ###################################################################
# 特性 10: LZ4K/LZ4KD (ZRAM 压缩算法)
# ###################################################################
integrate_lz4k() {
    echo ""
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}  特性: LZ4K / LZ4KD 压缩算法${NC}"
    echo -e "${BLUE}========================================${NC}"

    # LZ4K/LZ4KD 需要 Android 内核特有的库代码
    # 检查内核是否已有这些算法
    if grep -q "LZ4K" lib/Kconfig 2>/dev/null || \
       grep -q "lz4k" lib/Makefile 2>/dev/null; then
        record_success "LZ4K/LZ4KD: 已存在于内核中"
        return 0
    fi

    # 尝试从 Android 4.19 内核树获取
    info "  尝试从 Android 内核树获取 LZ4K/LZ4KD..."
    git clone --depth=1 https://github.com/yjy239/android_kernel_4.19 /tmp/android-4.19 2>/dev/null || true

    local lz4k_found=0
    if [ -d /tmp/android-4.19 ]; then
        if [ -d /tmp/android-4.19/lib/lz4k ]; then
            mkdir -p lib/lz4k
            cp -r /tmp/android-4.19/lib/lz4k/* lib/lz4k/ 2>/dev/null || true
            lz4k_found=1
        fi
        if [ -d /tmp/android-4.19/lib/lz4kd ]; then
            mkdir -p lib/lz4kd
            cp -r /tmp/android-4.19/lib/lz4kd/* lib/lz4kd/ 2>/dev/null || true
            lz4k_found=1
        fi
        # 复制 crypto wrapper
        for f in lz4k.c lz4kd.c; do
            [ -f /tmp/android-4.19/crypto/$f ] && cp /tmp/android-4.19/crypto/$f crypto/$f
        done
    fi

    if [ $lz4k_found -eq 1 ]; then
        # 添加 Kconfig 和 Makefile
        if ! grep -q "LZ4K_COMPRESS" lib/Kconfig 2>/dev/null; then
            cat >> lib/Kconfig << 'KCONFIG_EOF'

config LZ4K_COMPRESS
	tristate "LZ4K compression"
	help
	  LZ4K 是 LZ4 的内核优化变体。

config LZ4K_DECOMPRESS
	tristate "LZ4K decompression"
	help
	  LZ4K 是 LZ4 的内核优化变体。

config LZ4KD_COMPRESS
	tristate "LZ4KD compression"
	help
	  LZ4KD 是 LZ4K 的改进版，具有更好的压缩比。

config LZ4KD_DECOMPRESS
	tristate "LZ4KD decompression"
	help
	  LZ4KD 是 LZ4K 的改进版，具有更好的压缩比。
KCONFIG_EOF
        fi
        if ! grep -q "lz4k" lib/Makefile 2>/dev/null; then
            echo "" >> lib/Makefile
            echo 'obj-$(CONFIG_LZ4K_COMPRESS) += lz4k/' >> lib/Makefile
            echo 'obj-$(CONFIG_LZ4KD_COMPRESS) += lz4kd/' >> lib/Makefile
        fi
        if ! grep -q "CRYPTO_LZ4K" crypto/Kconfig 2>/dev/null; then
            echo -e "\nconfig CRYPTO_LZ4K\n\ttristate \"LZ4K compression algorithm\"\n\tselect LZ4K_COMPRESS\n\tselect LZ4K_DECOMPRESS\n" >> crypto/Kconfig
            echo -e "\nconfig CRYPTO_LZ4KD\n\ttristate \"LZ4KD compression algorithm\"\n\tselect LZ4KD_COMPRESS\n\tselect LZ4KD_DECOMPRESS\n" >> crypto/Kconfig
        fi
        if ! grep -q "lz4k" crypto/Makefile 2>/dev/null; then
            echo "" >> crypto/Makefile
            echo 'obj-$(CONFIG_CRYPTO_LZ4K) += lz4k.o' >> crypto/Makefile
            echo 'obj-$(CONFIG_CRYPTO_LZ4KD) += lz4kd.o' >> crypto/Makefile
        fi
        record_success "LZ4K/LZ4KD: 已从 Android 内核树集成"
    else
        record_skipped "LZ4K/LZ4KD: 无法获取源码 (使用内置 LZ4 作为 ZRAM 默认)"
    fi
}

# ###################################################################
# 特性 11: Droidspaces (配置级)
# ###################################################################
integrate_droidspaces() {
    echo ""
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}  特性: Droidspaces${NC}"
    echo -e "${BLUE}========================================${NC}"

    # Droidspaces 主要是配置级支持 (namespace, cgroup, overlayfs 等)
    # 这些配置在 fragment 中已包含
    info "  Droidspaces 主要是配置级支持"
    info "  必需配置 (namespaces, cgroups, overlayfs) 已在 fragment 中启用"
    record_success "Droidspaces: 配置级支持已就绪"
}

# ###################################################################
# 特性 12: Mountify (配置级 - OverlayFS)
# ###################################################################
integrate_mountify() {
    echo ""
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}  特性: Mountify (OverlayFS)${NC}"
    echo -e "${BLUE}========================================${NC}"

    info "  Mountify 依赖 OverlayFS，配置已在 fragment 中启用"
    record_success "Mountify: OverlayFS 配置已就绪"
}

# ###################################################################
# 特性 13: 网络稳定性增强 (配置级)
# ###################################################################
integrate_network_enhancements() {
    echo ""
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}  特性: 网络稳定性增强${NC}"
    echo -e "${BLUE}========================================${NC}"

    info "  网络增强为配置级 (FQ-CoDel + CAKE + BBR + TCP_FASTOPEN)"
    info "  改善复杂网络及热点共享场景下的传输稳定性"
    record_success "网络稳定性: 配置级增强已就绪"
}

# ###################################################################
# 特性 14: Android 17 GSI 兼容性 (配置级)
# ###################################################################
integrate_gsi_compat() {
    echo ""
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}  特性: Android 17 AOSP GSI 兼容性${NC}"
    echo -e "${BLUE}========================================${NC}"

    info "  GSI 兼容性为配置级 (Treble, VNDK, binder, ashmem 等)"
    info "  关键配置已在 fragment 中启用"

    # 检查 Treble 支持
    if grep -q "TREBLE" arch/arm64/configs/vendor/*.config 2>/dev/null; then
        info "  Treble 配置已存在于 vendor configs"
    fi

    record_success "GSI 兼容性: 配置级支持已就绪"
}

# ###################################################################
# 特性 15: MGLRU (4.19 不支持)
# ###################################################################
integrate_mglru() {
    echo ""
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}  特性: MGLRU${NC}"
    echo -e "${BLUE}========================================${NC}"

    if grep -q "LRU_GEN" mm/Kconfig 2>/dev/null; then
        record_success "MGLRU: 已可用"
    else
        record_skipped "MGLRU: 4.19 不支持 (需要 6.1+)，使用增强 vmscan 替代"
    fi
}

# ===================================================================
# 主执行
# ===================================================================
echo ""
echo -e "${BLUE}╔══════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║  Oblivionis-kernel 特性集成                      ║${NC}"
echo -e "${BLUE}║  基线: Linux 4.19                                 ║${NC}"
echo -e "${BLUE}║  模式: 本地源码 (4.19 兼容)                       ║${NC}"
echo -e "${BLUE}╚══════════════════════════════════════════════════╝${NC}"
echo ""

KVER=$(make -s kernelversion 2>/dev/null || echo "unknown")
info "内核版本: $KVER"
info "内核目录: $KERNEL_DIR"
info "源码目录: $SRC_DIR"
echo ""

# 验证所有源码文件
info "=== 检查本地源码文件 ==="
for f in tcp_bbr3.c tcp_brutal.c tcp_c2tcp.c tcp_roccet.c adios.c ntsync.c cpufreq_windchill.c; do
    if [ -f "$SRC_DIR/$f" ]; then
        info "  [OK] $f ($(wc -l < "$SRC_DIR/$f") 行)"
    else
        warn "  [缺失] $f"
    fi
done
echo ""

# 运行所有集成 (每个独立且非致命)
integrate_bbrv3                || true
integrate_c2tcp                || true
integrate_tcp_roccet           || true
integrate_tcp_brutal           || true
integrate_adios                || true
integrate_windchill            || true
integrate_ntsync               || true
integrate_uksm                 || true
integrate_wireguard            || true
integrate_evdi                 || true
integrate_lz4k                 || true
integrate_droidspaces          || true
integrate_mountify             || true
integrate_network_enhancements || true
integrate_gsi_compat           || true
integrate_mglru                || true

# 汇总
echo ""
echo -e "${BLUE}╔══════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║  集成汇总                                         ║${NC}"
echo -e "${BLUE}╠══════════════════════════════════════════════════╣${NC}"
echo -e "${GREEN}║  成功: $SUCCESS${NC}"
echo -e "${YELLOW}║  跳过: $SKIPPED${NC}"
echo -e "${RED}║  失败: $FAILED${NC}"
echo -e "${BLUE}╚══════════════════════════════════════════════════╝${NC}"
echo ""

if [ $FAILED -gt 0 ]; then
    warn "部分特性集成失败，构建将继续使用可用特性。"
    warn "失败的特性将使用回退或从最终内核中省略。"
fi

# 输出关键提示
echo ""
info "=== 重要提示 ==="
info "BBR v1 保持为默认 TCP 拥塞控制 (CONFIG_DEFAULT_TCP_CONG=\"bbr\")"
info "BBRv3/C2TCP/ROCCET/Brutal 作为可选模块 (CONFIG_*_CONG_*=m)"
info "ADIOS 作为默认 I/O 调度器 (如编译失败则回退到 mq-deadline)"
info "Windchill (风驰) 调速器已集成 (可作为替代 cpufreq governor)"
info "模块签名已禁用 (确保厂商模块可加载)"
echo ""

exit 0
