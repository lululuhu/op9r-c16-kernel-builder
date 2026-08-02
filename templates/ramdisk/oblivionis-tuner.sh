#!/system/bin/sh
# ===================================================================
# oblivionis-tuner.sh — Oblivionis-kernel 智能模式切换 v2
#
# 四种模式:
#   1. 均衡模式 (默认) — 日常使用，性能与功耗平衡，各项都好
#   2. 游戏模式 — GPU+CPU 双重检测到游戏时切换，全核高频 + 解除温控
#   3. 低电量模式 — 电量 ≤15% 且未充电时触发，降低频率省电
#   4. 息屏 Doze 模式 — 屏幕关闭时触发，极低功耗，息屏省电
#
# 检测方式:
#   游戏检测: GPU busy >40% 且 CPU loadavg >4.0，连续 3 次 (约 9 秒)
#   低电量检测: battery capacity ≤15% 且 status != Charging
#   息屏检测: LCD backlight brightness == 0
#
# 优先级: 息屏Doze > 低电量 > 游戏 > 均衡
# 轮询间隔: 3 秒 (极低开销)
# ===================================================================

# ---- 路径定义: GPU ----
GPU_BUSY="/sys/class/kgsl/kgsl-3d0/devfreq/gpu_busy_percentage"
GPU_MAX_FREQ="/sys/class/kgsl/kgsl-3d0/devfreq/max_freq"
GPU_MIN_FREQ="/sys/class/kgsl/kgsl-3d0/devfreq/min_freq"
GPU_GOV="/sys/class/kgsl/kgsl-3d0/devfreq/governor"
GPU_IDLE_TIMER="/sys/class/kgsl/kgsl-3d0/idle_timer"
GPU_POLLING="/sys/class/kgsl/kgsl-3d0/devfreq/polling_time"

# ---- 路径定义: 电池 ----
BATT_CAP="/sys/class/power_supply/battery/capacity"
BATT_STATUS="/sys/class/power_supply/battery/status"
BATT_TEMP="/sys/class/power_supply/battery/temp"

# ---- 路径定义: 屏幕 ----
SCREEN_BRIGHTNESS="/sys/class/leds/lcd-backlight/brightness"

# ---- 路径定义: CPU 频率 ----
P0_MAX="/sys/devices/system/cpu/cpufreq/policy0/scaling_max_freq"
P4_MAX="/sys/devices/system/cpu/cpufreq/policy4/scaling_max_freq"
P7_MAX="/sys/devices/system/cpu/cpufreq/policy7/scaling_max_freq"
P0_MIN="/sys/devices/system/cpu/cpufreq/policy0/scaling_min_freq"
P4_MIN="/sys/devices/system/cpu/cpufreq/policy4/scaling_min_freq"
P7_MIN="/sys/devices/system/cpu/cpufreq/policy7/scaling_min_freq"

# ---- 路径定义: 热管理 ----
THERMAL_SCONFIG="/sys/class/thermal/thermal_message/sconfig"

# ---- 路径定义: 内存 ----
KSM_PAGES="/sys/kernel/mm/ksm/pages_to_scan"
UKSM_PAGES="/sys/kernel/mm/uksm/pages_to_scan"
SWAPPINESS="/proc/sys/vm/swappiness"
WATERMARK="/proc/sys/vm/watermark_scale_factor"
DIRTY_RATIO="/proc/sys/vm/dirty_ratio"
EXTRA_FREE="/proc/sys/vm/extra_free_kbytes"

# ---- 路径定义: 触控 Boost ----
BOOST_FREQ_CPU0="/sys/devices/system/cpu/cpu_boost/parameters/sched_boost_freq_khz_cpu0"
BOOST_FREQ_CPU4="/sys/devices/system/cpu/cpu_boost/parameters/sched_boost_freq_khz_cpu4"
BOOST_FREQ_CPU7="/sys/devices/system/cpu/cpu_boost/parameters/sched_boost_freq_khz_cpu7"
BOOST_DURATION="/sys/devices/system/cpu/cpu_boost/parameters/sched_boost_duration"
WAKEUP_BOOST="/sys/devices/system/cpu/cpu_boost/parameters/sched_wakeup_boost"
INPUT_BOOST="/sys/devices/system/cpu/cpu_boost/parameters/boost_input_events"

# ---- 路径定义: schedutil ----
P0_UP_RATE="/sys/devices/system/cpu/cpufreq/policy0/schedutil/up_rate_limit_us"
P0_DOWN_RATE="/sys/devices/system/cpu/cpufreq/policy0/schedutil/down_rate_limit_us"
P4_UP_RATE="/sys/devices/system/cpu/cpufreq/policy4/schedutil/up_rate_limit_us"
P4_DOWN_RATE="/sys/devices/system/cpu/cpufreq/policy4/schedutil/down_rate_limit_us"
P7_UP_RATE="/sys/devices/system/cpu/cpufreq/policy7/schedutil/up_rate_limit_us"
P7_DOWN_RATE="/sys/devices/system/cpu/cpufreq/policy7/schedutil/down_rate_limit_us"

# ---- 路径定义: EPP ----
P0_EPP="/sys/devices/system/cpu/cpufreq/policy0/energy_performance_preference"
P4_EPP="/sys/devices/system/cpu/cpufreq/policy4/energy_performance_preference"
P7_EPP="/sys/devices/system/cpu/cpufreq/policy7/energy_performance_preference"

# ---- 路径定义: CPU Idle ----
CPUIDLE_DEEPEST="/sys/devices/system/cpu/cpuidle/use_deepest_state"

# ---- 路径定义: DDR 带宽 (SM8250 devfreq) ----
DDR_LLCC_BW="/sys/class/devfreq/soc:qcom,cpu-cpu-llcc-bw/max_freq"
DDR_BW="/sys/class/devfreq/soc:qcom,cpu-llcc-ddr-bw/max_freq"
DDR_LLCC_BW_GOV="/sys/class/devfreq/soc:qcom,cpu-cpu-llcc-bw/governor"
DDR_BW_GOV="/sys/class/devfreq/soc:qcom,cpu-llcc-ddr-bw/governor"

# ---- 路径定义: 网络省电 ----
WIFI_PWR="/proc/sys/net/ieee80211/wifi_powersave"

# ---- 路径定义: GPU AdrenoBoost ----
GPU_ADRENOBOOST="/sys/class/kgsl/kgsl-3d0/devfreq/adrenoboost"

# ---- 路径定义: 存储 I/O ----
IO_READ_AHEAD="/sys/block/sda/queue/read_ahead_kb"
IO_NR_REQUESTS="/sys/block/sda/queue/nr_requests"
IO_WBT_LAT="/sys/block/sda/queue/wbt_lat_usec"
IO_F2FS_GC="/sys/fs/f2fs/sda/gc_urgent"

# ---- 路径定义: 网络 TCP ----
TCP_RMEM="/proc/sys/net/ipv4/tcp_rmem"
TCP_WMEM="/proc/sys/net/ipv4/tcp_wmem"
TCP_FASTOPEN="/proc/sys/net/ipv4/tcp_fastopen"

# ---- 路径定义: 充电 ----
USB_FASTCHARGE="/sys/class/power_supply/usb/fastcharge"

# ---- 路径定义: 热管理扩展 ----
THERMAL_LIMIT="/sys/class/thermal/thermal_message/thermal_limit"

# ===================================================================
# 频率定义 (OnePlus 9R / SM8250)
# ===================================================================
# CPU 频率表:
#   Silver (A55):  300MHz - 1804MHz
#   Gold   (A77):  300MHz - 2419MHz
#   Prime  (A77):  300MHz - 2841MHz
# GPU (Adreno 650): 257MHz - 825MHz

# ---- 均衡模式: 满血但智能 ----
SILVER_MAX_BAL=1804800
GOLD_MAX_BAL=2419200
PRIME_MAX_BAL=2841600
SILVER_MIN_BAL=300000
GOLD_MIN_BAL=300000
PRIME_MIN_BAL=300000
GPU_MAX_BAL=675000000    # 675MHz: 日常流畅且省电
GPU_MIN_BAL=257000000

# ---- 游戏模式: 全核满血 ----
SILVER_MAX_GAME=1804800
GOLD_MAX_GAME=2419200
PRIME_MAX_GAME=2841600
SILVER_MIN_GAME=652800
GOLD_MIN_GAME=806400
PRIME_MIN_GAME=806400
GPU_MAX_GAME=825000000   # 825MHz: 满血
GPU_MIN_GAME=465000000

# ---- 低电量模式: 限制频率省电 ----
SILVER_MAX_LOW=1555200
GOLD_MAX_LOW=1804800
PRIME_MAX_LOW=2419200
SILVER_MIN_LOW=300000
GOLD_MIN_LOW=300000
PRIME_MIN_LOW=300000
GPU_MAX_LOW=465000000    # 465MHz: 大幅省电
GPU_MIN_LOW=257000000

# ---- 息屏 Doze: 极低功耗 ----
SILVER_MAX_DOZE=1152000
GOLD_MAX_DOZE=1555200
PRIME_MAX_DOZE=1804800
SILVER_MIN_DOZE=300000
GOLD_MIN_DOZE=300000
PRIME_MIN_DOZE=300000
GPU_MAX_DOZE=257000000  # 最低 GPU 频率
GPU_MIN_DOZE=257000000

# ---- DDR 带宽 (Hz, 0 = 不限制) ----
# SM8250 LPDDR5 典型带宽级别: 2097152, 3221225472, 5153960752, 6335076762...
# Doze/低电量时限制 DDR 带宽可省显著功耗
DDR_LLCC_MAX_BAL=0       # 不限制
DDR_MAX_BAL=0
DDR_LLCC_MAX_LOW=2097152000   # 限制到较低带宽
DDR_MAX_LOW=2097152000
DDR_LLCC_MAX_DOZE=1556925696  # 极低带宽
DDR_MAX_DOZE=1556925696

# ===================================================================
# 状态变量
# ===================================================================
CURRENT_MODE="init"
GAME_COUNTER=0
GAME_EXIT_COUNTER=0
LOW_BATT_COUNTER=0
SCREEN_OFF_COUNTER=0
MODE_LOCK=0             # 模式锁定计时器 (防止抖动)
LAST_MODE_CHANGE=0

# ===================================================================
# 辅助函数
# ===================================================================
log() {
    echo "[$(date '+%H:%M:%S')] $*" >> /data/oblivionis-tuner.log 2>/dev/null
}

read_val() {
    cat "$1" 2>/dev/null
}

write_val() {
    echo "$2" > "$1" 2>/dev/null
}

# 获取 1 分钟平均负载 (整数部分)
get_loadavg() {
    load=$(cut -d' ' -f1 /proc/loadavg 2>/dev/null)
    # loadavg 格式: 1.23 0.45 0.67 X/Y ZZZZ
    # 取整数部分
    echo "${load%%.*}" | tr -dc '0-9'
}

# ===================================================================
# 模式切换函数
# ===================================================================

apply_balanced_mode() {
    [ "$CURRENT_MODE" = "balanced" ] && return 0
    log "切换到均衡模式 (性能好 + 省电)"
    CURRENT_MODE="balanced"

    # CPU 最大频率: 满血 (各项都要好)
    write_val "$P0_MAX" "$SILVER_MAX_BAL"
    write_val "$P4_MAX" "$GOLD_MAX_BAL"
    write_val "$P7_MAX" "$PRIME_MAX_BAL"

    # CPU 最低频率: 300MHz (空闲时深度省电)
    write_val "$P0_MIN" "$SILVER_MIN_BAL"
    write_val "$P4_MIN" "$GOLD_MIN_BAL"
    write_val "$P7_MIN" "$PRIME_MIN_BAL"

    # 触控 Boost: 强力响应 (均衡但触控好)
    write_val "$INPUT_BOOST" 1
    write_val "$BOOST_FREQ_CPU0" 1800000
    write_val "$BOOST_FREQ_CPU4" 2400000
    write_val "$BOOST_FREQ_CPU7" 2800000
    write_val "$BOOST_DURATION" 40
    write_val "$WAKEUP_BOOST" 1

    # schedutil: 快升慢降 (流畅但不过激)
    # 300us 升频: 比游戏稍慢但日常足够快
    # 1500us 降频: 延迟降频保持界面流畅
    write_val "$P0_UP_RATE" 300
    write_val "$P0_DOWN_RATE" 1500
    write_val "$P4_UP_RATE" 300
    write_val "$P4_DOWN_RATE" 1500
    write_val "$P7_UP_RATE" 300
    write_val "$P7_DOWN_RATE" 1500

    # EPP: 100 (偏性能的平衡，各项好)
    # 0=最大性能, 128=平衡, 255=最大省电
    # 100: 略偏性能，日常使用流畅
    write_val "$P0_EPP" 100
    write_val "$P4_EPP" 100
    write_val "$P7_EPP" 100

    # 温控: 正常 (sconfig=13)
    write_val "$THERMAL_SCONFIG" 13

    # GPU: 日常频率上限 675MHz (流畅 UI 足够，省电)
    write_val "$GPU_GOV" msm-adreno-tz 2>/dev/null
    write_val "$GPU_MAX_FREQ" "$GPU_MAX_BAL" 2>/dev/null
    write_val "$GPU_MIN_FREQ" "$GPU_MIN_BAL" 2>/dev/null
    write_val "$GPU_IDLE_TIMER" 32 2>/dev/null
    write_val "$GPU_POLLING" 16 2>/dev/null

    # CPU Idle: 允许深度 C-state (空闲省电)
    write_val "$CPUIDLE_DEEPEST" 1 2>/dev/null

    # DDR 带宽: 不限制
    write_val "$DDR_LLCC_BW" "$DDR_LLCC_MAX_BAL" 2>/dev/null
    write_val "$DDR_BW" "$DDR_MAX_BAL" 2>/dev/null

    # 内存: 均衡 (好缓存 + 适度回收)
    write_val "$SWAPPINESS" 80
    write_val "$WATERMARK" 60
    write_val "$DIRTY_RATIO" 15
    write_val "$EXTRA_FREE" 16384

    # KSM/UKSM: 正常扫描
    write_val "$KSM_PAGES" 200 2>/dev/null
    write_val "$UKSM_PAGES" 200 2>/dev/null

    # WiFi 省电: 开启 (均衡模式也省电)
    write_val "$WIFI_PWR" 1 2>/dev/null

    # GPU AdrenoBoost: 关闭 (均衡模式省电)
    write_val "$GPU_ADRENOBOOST" 0 2>/dev/null

    # 存储 I/O: 均衡 (流畅日常 + 适度预读)
    write_val "$IO_READ_AHEAD" 128 2>/dev/null
    write_val "$IO_NR_REQUESTS" 256 2>/dev/null
    write_val "$IO_WBT_LAT" 75000 2>/dev/null
    write_val "$IO_F2FS_GC" 1 2>/dev/null

    # 网络: 均衡 (好速度 + 省电)
    write_val "$TCP_RMEM" "4096 87380 67108864" 2>/dev/null
    write_val "$TCP_WMEM" "4096 65536 67108864" 2>/dev/null
    write_val "$TCP_FASTOPEN" 3 2>/dev/null

    # 热管理: 正常 (45°C)
    write_val "$THERMAL_LIMIT" 45000 2>/dev/null
}

apply_game_mode() {
    [ "$CURRENT_MODE" = "game" ] && return 0
    log "切换到游戏模式 (全核高频 + 解除温控)"
    CURRENT_MODE="game"

    # CPU 最大频率: 全部拉满
    write_val "$P0_MAX" "$SILVER_MAX_GAME"
    write_val "$P4_MAX" "$GOLD_MAX_GAME"
    write_val "$P7_MAX" "$PRIME_MAX_GAME"

    # CPU 最低频率: 提高底线 (减少升降频延迟，游戏更稳)
    write_val "$P0_MIN" "$SILVER_MIN_GAME"
    write_val "$P4_MIN" "$GOLD_MIN_GAME"
    write_val "$P7_MIN" "$PRIME_MIN_GAME"

    # 触控 Boost: 最大强度 (游戏触控响应)
    write_val "$INPUT_BOOST" 1
    write_val "$BOOST_FREQ_CPU0" 1800000
    write_val "$BOOST_FREQ_CPU4" 2400000
    write_val "$BOOST_FREQ_CPU7" 2800000
    write_val "$BOOST_DURATION" 60
    write_val "$WAKEUP_BOOST" 1

    # schedutil: 极速升频 + 延迟降频 (保持高频)
    write_val "$P0_UP_RATE" 200
    write_val "$P0_DOWN_RATE" 3000
    write_val "$P4_UP_RATE" 200
    write_val "$P4_DOWN_RATE" 3000
    write_val "$P7_UP_RATE" 200
    write_val "$P7_DOWN_RATE" 3000

    # EPP: 0 (最大性能)
    write_val "$P0_EPP" 0
    write_val "$P4_EPP" 0
    write_val "$P7_EPP" 0

    # 温控: 放宽 (sconfig=0 解除限制)
    write_val "$THERMAL_SCONFIG" 0

    # GPU: 性能模式 + 满血频率
    write_val "$GPU_GOV" performance 2>/dev/null
    write_val "$GPU_MAX_FREQ" "$GPU_MAX_GAME" 2>/dev/null
    write_val "$GPU_MIN_FREQ" "$GPU_MIN_GAME" 2>/dev/null
    write_val "$GPU_IDLE_TIMER" 80 2>/dev/null
    write_val "$GPU_POLLING" 8 2>/dev/null

    # CPU Idle: 禁用最深 C-state (更快唤醒，游戏不卡)
    write_val "$CPUIDLE_DEEPEST" 0 2>/dev/null

    # DDR 带宽: 不限制 (游戏需要高带宽)
    write_val "$DDR_LLCC_BW" 0 2>/dev/null
    write_val "$DDR_BW" 0 2>/dev/null

    # 内存: 游戏优先 (更多内存给前台)
    write_val "$SWAPPINESS" 100
    write_val "$WATERMARK" 40
    write_val "$DIRTY_RATIO" 10
    write_val "$EXTRA_FREE" 8192

    # KSM/UKSM: 降低扫描 (减少 CPU 开销，让 CPU 给游戏)
    write_val "$KSM_PAGES" 100 2>/dev/null
    write_val "$UKSM_PAGES" 100 2>/dev/null

    # WiFi 省电: 关闭 (游戏时降低延迟)
    write_val "$WIFI_PWR" 0 2>/dev/null

    # GPU AdrenoBoost: 开启 (游戏 GPU 性能增强)
    write_val "$GPU_ADRENOBOOST" 1 2>/dev/null

    # 存储 I/O: 游戏优先 (大预读 + 低延迟)
    write_val "$IO_READ_AHEAD" 256 2>/dev/null
    write_val "$IO_NR_REQUESTS" 512 2>/dev/null
    write_val "$IO_WBT_LAT" 50000 2>/dev/null
    write_val "$IO_F2FS_GC" 0 2>/dev/null

    # 网络: 游戏 (大缓冲 + 低延迟)
    write_val "$TCP_RMEM" "4096 87380 134217728" 2>/dev/null
    write_val "$TCP_WMEM" "4096 65536 134217728" 2>/dev/null
    write_val "$TCP_FASTOPEN" 3 2>/dev/null

    # 热管理: 放宽 (50°C, 游戏允许更高温度)
    write_val "$THERMAL_LIMIT" 50000 2>/dev/null

    # USB 快充: 游戏时不限制
    write_val "$USB_FASTCHARGE" 1 2>/dev/null
}

apply_low_battery_mode() {
    [ "$CURRENT_MODE" = "low_battery" ] && return 0
    log "切换到低电量模式 (限制频率省电)"
    CURRENT_MODE="low_battery"

    # CPU 最大频率: 限制 (省电)
    write_val "$P0_MAX" "$SILVER_MAX_LOW"
    write_val "$P4_MAX" "$GOLD_MAX_LOW"
    write_val "$P7_MAX" "$PRIME_MAX_LOW"

    # CPU 最低频率: 300MHz (深度省电)
    write_val "$P0_MIN" "$SILVER_MIN_LOW"
    write_val "$P4_MIN" "$GOLD_MIN_LOW"
    write_val "$P7_MIN" "$PRIME_MIN_LOW"

    # 触控 Boost: 降低 (省电但仍可用)
    write_val "$INPUT_BOOST" 1
    write_val "$BOOST_FREQ_CPU0" 1555000
    write_val "$BOOST_FREQ_CPU4" 1804000
    write_val "$BOOST_FREQ_CPU7" 2419000
    write_val "$BOOST_DURATION" 30
    write_val "$WAKEUP_BOOST" 0

    # schedutil: 慢升快降 (优先省电)
    write_val "$P0_UP_RATE" 1000
    write_val "$P0_DOWN_RATE" 1000
    write_val "$P4_UP_RATE" 1000
    write_val "$P4_DOWN_RATE" 1000
    write_val "$P7_UP_RATE" 1000
    write_val "$P7_DOWN_RATE" 1000

    # EPP: 255 (最大省电)
    write_val "$P0_EPP" 255
    write_val "$P4_EPP" 255
    write_val "$P7_EPP" 255

    # 温控: 严格 (sconfig=13)
    write_val "$THERMAL_SCONFIG" 13

    # GPU: 省电模式 + 低频
    write_val "$GPU_GOV" powersave 2>/dev/null
    write_val "$GPU_MAX_FREQ" "$GPU_MAX_LOW" 2>/dev/null
    write_val "$GPU_MIN_FREQ" "$GPU_MIN_LOW" 2>/dev/null
    write_val "$GPU_IDLE_TIMER" 16 2>/dev/null
    write_val "$GPU_POLLING" 32 2>/dev/null

    # CPU Idle: 最深 C-state (最大化省电)
    write_val "$CPUIDLE_DEEPEST" 1 2>/dev/null

    # DDR 带宽: 限制 (省电)
    write_val "$DDR_LLCC_BW" "$DDR_LLCC_MAX_LOW" 2>/dev/null
    write_val "$DDR_BW" "$DDR_MAX_LOW" 2>/dev/null

    # 内存: 省电优先
    write_val "$SWAPPINESS" 60
    write_val "$WATERMARK" 80
    write_val "$DIRTY_RATIO" 20
    write_val "$EXTRA_FREE" 32768

    # KSM/UKSM: 加强扫描 (省内存)
    write_val "$KSM_PAGES" 400 2>/dev/null
    write_val "$UKSM_PAGES" 400 2>/dev/null

    # WiFi 省电: 开启
    write_val "$WIFI_PWR" 1 2>/dev/null

    # GPU AdrenoBoost: 关闭 (低电量省电)
    write_val "$GPU_ADRENOBOOST" 0 2>/dev/null

    # 存储 I/O: 省电 (小预读 + 减少请求)
    write_val "$IO_READ_AHEAD" 64 2>/dev/null
    write_val "$IO_NR_REQUESTS" 128 2>/dev/null
    write_val "$IO_WBT_LAT" 100000 2>/dev/null
    write_val "$IO_F2FS_GC" 2 2>/dev/null

    # 网络: 省电 (小缓冲减少唤醒)
    write_val "$TCP_RMEM" "4096 16384 33554432" 2>/dev/null
    write_val "$TCP_WMEM" "4096 16384 33554432" 2>/dev/null
    write_val "$TCP_FASTOPEN" 1 2>/dev/null

    # 热管理: 严格 (40°C, 低电量保护)
    write_val "$THERMAL_LIMIT" 40000 2>/dev/null
}

apply_doze_mode() {
    [ "$CURRENT_MODE" = "doze" ] && return 0
    log "切换到息屏 Doze 模式 (极低功耗)"
    CURRENT_MODE="doze"

    # CPU 最大频率: 大幅限制 (息屏不需要性能)
    write_val "$P0_MAX" "$SILVER_MAX_DOZE"
    write_val "$P4_MAX" "$GOLD_MAX_DOZE"
    write_val "$P7_MAX" "$PRIME_MAX_DOZE"

    # CPU 最低频率: 300MHz
    write_val "$P0_MIN" "$SILVER_MIN_DOZE"
    write_val "$P4_MIN" "$GOLD_MIN_DOZE"
    write_val "$P7_MIN" "$PRIME_MIN_DOZE"

    # 触控 Boost: 关闭 (息屏无触摸)
    write_val "$INPUT_BOOST" 0
    write_val "$BOOST_DURATION" 0
    write_val "$WAKEUP_BOOST" 0

    # schedutil: 慢升快降 (最大化省电)
    write_val "$P0_UP_RATE" 2000
    write_val "$P0_DOWN_RATE" 500
    write_val "$P4_UP_RATE" 2000
    write_val "$P4_DOWN_RATE" 500
    write_val "$P7_UP_RATE" 2000
    write_val "$P7_DOWN_RATE" 500

    # EPP: 255 (最大省电)
    write_val "$P0_EPP" 255
    write_val "$P4_EPP" 255
    write_val "$P7_EPP" 255

    # 温控: 严格
    write_val "$THERMAL_SCONFIG" 13

    # GPU: 最低频率 (息屏不需要 GPU)
    write_val "$GPU_GOV" powersave 2>/dev/null
    write_val "$GPU_MAX_FREQ" "$GPU_MAX_DOZE" 2>/dev/null
    write_val "$GPU_MIN_FREQ" "$GPU_MIN_DOZE" 2>/dev/null
    write_val "$GPU_IDLE_TIMER" 1 2>/dev/null
    write_val "$GPU_POLLING" 100 2>/dev/null

    # CPU Idle: 最深 C-state (最大化省电)
    write_val "$CPUIDLE_DEEPEST" 1 2>/dev/null

    # DDR 带宽: 极低 (息屏省电)
    write_val "$DDR_LLCC_BW" "$DDR_LLCC_MAX_DOZE" 2>/dev/null
    write_val "$DDR_BW" "$DDR_MAX_DOZE" 2>/dev/null

    # 内存: 省电优先 + 激进回收
    write_val "$SWAPPINESS" 40
    write_val "$WATERMARK" 100
    write_val "$DIRTY_RATIO" 25
    write_val "$EXTRA_FREE" 32768

    # KSM/UKSM: 加强扫描 (息屏时合并页面省内存)
    write_val "$KSM_PAGES" 500 2>/dev/null
    write_val "$UKSM_PAGES" 500 2>/dev/null

    # WiFi 省电: 开启
    write_val "$WIFI_PWR" 1 2>/dev/null

    # GPU AdrenoBoost: 关闭 (息屏省电)
    write_val "$GPU_ADRENOBOOST" 0 2>/dev/null

    # 存储 I/O: 极省电 (最小预读 + 高延迟容忍)
    write_val "$IO_READ_AHEAD" 32 2>/dev/null
    write_val "$IO_NR_REQUESTS" 64 2>/dev/null
    write_val "$IO_WBT_LAT" 200000 2>/dev/null
    write_val "$IO_F2FS_GC" 2 2>/dev/null

    # 网络: 极省电 (最小缓冲减少唤醒)
    write_val "$TCP_RMEM" "4096 8192 16777216" 2>/dev/null
    write_val "$TCP_WMEM" "4096 8192 16777216" 2>/dev/null
    write_val "$TCP_FASTOPEN" 0 2>/dev/null

    # 热管理: 严格 (40°C)
    write_val "$THERMAL_LIMIT" 40000 2>/dev/null
}

# ===================================================================
# 检测函数
# ===================================================================

# 检测是否在充电
is_charging() {
    status=$(read_val "$BATT_STATUS")
    case "$status" in
        Charging|Full|Not charging) return 0 ;;
        *) return 1 ;;
    esac
}

# 检测屏幕是否开启
is_screen_on() {
    bright=$(read_val "$SCREEN_BRIGHTNESS")
    [ "${bright:-0}" -gt 0 ] 2>/dev/null
}

# 检测电池温度是否过高 (>42°C)
# 注意: temp 值是 10 倍 (如 420 = 42.0°C)
is_battery_hot() {
    temp=$(read_val "$BATT_TEMP")
    temp=${temp:-0}
    [ "$temp" -gt 420 ] 2>/dev/null
}

# 检测游戏: GPU busy >40% 且 CPU loadavg >4，连续 3 次
# 双重检测避免视频播放等误触发
check_game() {
    gpu_busy=$(read_val "$GPU_BUSY")
    gpu_busy=${gpu_busy:-0}

    cpu_load=$(get_loadavg)
    cpu_load=${cpu_load:-0}

    # GPU busy >40% 且 CPU loadavg >4 (半数核心繁忙) → 可能游戏
    if [ "$gpu_busy" -gt 40 ] 2>/dev/null && [ "$cpu_load" -ge 4 ] 2>/dev/null; then
        GAME_COUNTER=$((GAME_COUNTER + 1))
        GAME_EXIT_COUNTER=0
        # 连续 3 次确认 (约 9 秒)
        if [ "$GAME_COUNTER" -ge 3 ]; then
            return 0
        fi
    else
        GAME_EXIT_COUNTER=$((GAME_EXIT_COUNTER + 1))
        # 连续 5 次低负载 (约 15 秒) → 退出游戏
        if [ "$GAME_EXIT_COUNTER" -ge 5 ]; then
            GAME_COUNTER=0
        fi
    fi
    return 1
}

# 检测低电量 (≤15% 且未充电)
check_low_battery() {
    cap=$(read_val "$BATT_CAP")
    cap=${cap:-100}

    if [ "$cap" -le 15 ] 2>/dev/null && ! is_charging; then
        LOW_BATT_COUNTER=$((LOW_BATT_COUNTER + 1))
        if [ "$LOW_BATT_COUNTER" -ge 2 ]; then
            return 0
        fi
    else
        LOW_BATT_COUNTER=0
    fi
    return 1
}

# 检测息屏 (连续 2 次确认)
check_screen_off() {
    if ! is_screen_on; then
        SCREEN_OFF_COUNTER=$((SCREEN_OFF_COUNTER + 1))
        if [ "$SCREEN_OFF_COUNTER" -ge 2 ]; then
            return 0
        fi
    else
        SCREEN_OFF_COUNTER=0
    fi
    return 1
}

# ===================================================================
# 主循环
# ===================================================================
log "=== Oblivionis 智能调参服务 v2 启动 ==="
log "模式: 均衡 / 游戏(GPU+CPU双重检测) / 低电量(≤15%) / 息屏Doze"

# 初始应用均衡模式
apply_balanced_mode

# 轮询间隔 (秒)
POLL_INTERVAL=3

while true; do
    # 优先级: 息屏Doze > 低电量 > 电池过热 > 游戏 > 均衡

    # 1. 检查息屏 (最高优先级 — 息屏时不需要任何性能)
    if check_screen_off; then
        # 息屏时即使低电量也用 Doze (Doze 本身就极省电)
        # 但低电量模式下保持 Doze 直到充电且电量恢复
        if [ "$CURRENT_MODE" != "doze" ]; then
            apply_doze_mode
        fi
        sleep $POLL_INTERVAL
        continue
    fi

    # 2. 屏幕亮了，检查低电量
    if check_low_battery; then
        # 低电量模式: 即使充电也等电量 >20% 才退出
        if is_charging; then
            cap=$(read_val "$BATT_CAP")
            cap=${cap:-100}
            if [ "$cap" -gt 20 ]; then
                # 电量恢复，切回均衡
                if [ "$CURRENT_MODE" != "balanced" ]; then
                    apply_balanced_mode
                fi
            else
                # 充电但电量仍低，保持低电量模式
                if [ "$CURRENT_MODE" != "low_battery" ]; then
                    apply_low_battery_mode
                fi
            fi
        else
            # 未充电且低电量
            if [ "$CURRENT_MODE" != "low_battery" ]; then
                apply_low_battery_mode
            fi
        fi
        sleep $POLL_INTERVAL
        continue
    fi

    # 3. 电池过热保护 (温度 >42°C 时降频)
    if is_battery_hot && [ "$CURRENT_MODE" = "game" ]; then
        log "电池温度过高 ($(read_val "$BATT_TEMP")°C)，退出游戏模式降温"
        GAME_COUNTER=0
        GAME_EXIT_COUNTER=0
        apply_balanced_mode
        sleep $POLL_INTERVAL
        continue
    fi

    # 4. 电量正常且屏幕亮，检查游戏
    if check_game; then
        if [ "$CURRENT_MODE" != "game" ]; then
            apply_game_mode
        fi
    else
        # 5. 默认均衡模式
        if [ "$CURRENT_MODE" != "balanced" ]; then
            apply_balanced_mode
        fi
    fi

    sleep $POLL_INTERVAL
done
