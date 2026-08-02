# Oblivionis-kernel 更新日志

OnePlus 9R (lemonades / SM8250 / Snapdragon 870) 自定义内核
基线: Linux 4.19.325 (LineageOS lineage-23.2)

---

## v1.0.0 — 首次构建成功 (2026-07-30)

**构建编号**: Run #53 | **状态**: ✅ 成功 | **产物**: Oblivionis-kernel-4.19-extreme-53

---

### 一、项目初始化 (2026-07-29)

#### 核心架构
- 基于 LineageOS 4.19.325 (lineage-23.2 分支) 内核源码
- 目标设备: OnePlus 9R (lemonades / SM8250 / Kona / Snapdragon 870)
- 目标系统: ColorOS 16 (C16) 兼容
- 内核命名: **Oblivionis-kernel** (通过 `CONFIG_LOCALVERSION` 设置)
- 使用 Proton Clang 工具链 + GCC 11 交叉编译

#### 主线 Backport 框架
- 创建 `patches/mainline-backports/` 目录结构
- 实现 `apply-backports.sh` 自动化补丁应用脚本
- 实现 `cherry-pick-mainline.sh` 主线 cherry-pick 替代方案
- **zram 6.6**: 多压缩算法/重压缩 backport (6个补丁，从主线 commit 下载)
  - `01-zram-preparation-multi-zcomp.patch` (43cbd4cb7389)
  - `02-zram-recomp-algorithm-sysfs.patch` (1ecb3403eb22)
  - `03-zram-factor-out-wb-read.patch` (9e02b88ac3f5)
  - `04-zram-recompress-sysfs.patch` (9d4e2da8d831)
  - `05-zram-kconfig-recomp-choice.patch` (9528113347a0)
  - `06-zram-recompress-block-state.patch` (9b061a5e9e30)
- **zsmalloc 6.12**: per-size_class 锁 backport (2个补丁)
  - 注: 4.19 已有 per-class 锁定，此 backport 仅作参考

#### 配置文件体系
- `lemonades_c16_extreme.fragment` — 全特性 + 调度/内存优化
- `lemonades_c16_advanced.fragment` — PSI/CFI/fs-verity/BBR
- `lemonades_c16_perf.fragment` — 性能优先，稳定
- `lemonades_c16_security.fragment` — 安全加固 + BBG 防格机
- `lemonades_c16_droidspaces.fragment` — Droidspaces 容器 + 网络增强

#### 调度器优化 (帧感知)
- `HZ=300` 适配 90Hz/120Hz 屏幕，减少帧抖动
- `NO_HZ_FULL` 减少空闲 CPU 定时器中断
- 高精度定时器 (`HIGH_RES_TIMERS`)
- `RCU_BOOST` 保护前台任务免受 RCU 回收影响
- `PREEMPT` 完全抢占，降低延迟
- `SCHED_MC` + `SCHED_SMT` 多核调度
- `SCHED_TUNE` + `SCHED_AUTOGROUP` 调度调优

#### 内存延迟优化 (memlat)
- `KSM` 页面合并
- `ZRAM` 内置 + writeback + memory tracking
- `ZSMALLOC` + 统计
- `MEMCG` 内存 cgroup 计费
- `ZSWAP` 压缩交换缓存 (LZ4 + zsmalloc)

---

### 二、CI/CD 构建流水线修复 (2026-07-29)

#### Defconfig 与配置合并
- 修复 defconfig 路径: 使用 `vendor/kona-perf_defconfig`
- 修复 `scripts/config` 路径: 从内核根目录运行，使用 `out/.config`
- 修复配置合并: 使用 `cat + olddefconfig` 替代 `merge_config.sh`
- 合并 `oplus.config` 厂商配置

#### 内核镜像检测
- 支持 `Image`、`Image.gz`、`Image.gz-dtb` 三种格式检测
- 修复 SM8250 内核镜像打包路径
- 添加 boot 目录列表辅助调试

#### 依赖安装
- 添加 `gcc-aarch64-linux-gnu` (Kconfig 编译器检查需要)
- 添加 `gcc-arm-linux-gnueabi` (arm32 交叉编译)
- 添加 `dwarves` / `pahole` (BTF 支持)
- 添加 `libncurses-dev` / `libelf-dev` / `libssl-dev`

#### 构建错误检测
- 添加 `set -o pipefail` 正确捕获 make 退出码
- 使用 `PIPESTATUS` 替代管道退出码
- 修复 `grep|head` 管道在 `set -e` 下 SIGPIPE (141) 导致的提前退出
- 所有 `grep|head` 管道添加 `|| true` 防护

---

### 三、编译器兼容性修复 (2026-07-29)

#### Clang → GCC 切换
- 从 Proton Clang 切换到 GCC 11 编译 LineageOS 4.19.325
- 原因: 厂商代码大量 Clang 不兼容警告
- 添加 `KCFLAGS` 全局 `-Wno-error` 绕过厂商代码警告

#### GCC 11 厂商代码修复
- `oplus_adfr.h`: `inline` 函数无函数体 → 移除 `inline` 关键字
- `thread_info.h` / `compiler.h`: `__compiletime_error` 属性修复
- `__bad_copy_to/from`: 提供内联定义
- 添加 `-Wno-error=parentheses` / `-Wno-error=unused-result`
- 添加 `-Wno-error=format` (WALT 调度器格式化警告)
- 添加 `-Wno-error=unused-variable` (厂商代码未使用变量)

#### BTF 禁用
- 禁用 `CONFIG_DEBUG_INFO_BTF` 避免 `resolve_btfids` 工具缺失错误
- 原因: CI 环境中 `pahole` 版本可能不兼容

---

### 四、AnyKernel3 刷机包修复 (2026-07-29 ~ 07-30)

#### 仓库修复
- 修复 AnyKernel3 仓库地址: `osm0sis/AnyKernel3` (原 `osm0cha` 已删除)

#### anykernel.sh 模板
- 将 `anykernel.sh` 从 YAML heredoc 移至 `templates/anykernel.sh` 模板文件
- 原因: heredoc 零缩进内容破坏 YAML `run` 块缩进结构
- 修复 `source` 路径: 引用 `tools/ak3-core.sh` 而非自引用
- 添加 `dump_boot; write_boot;` 命令 (原先完全缺失)

#### 设备识别
- 添加 OnePlus 9R 所有已知代号: `lemonades`, `lemonadep`, `OP595DL1`, `OnePlus9R` 等
- 修复 `do.devicecheck=1` 替代无效的 `do.device=1`
- 使用 `device.name1/name2/...` 替代逗号分隔的 `device.name=`

#### A/B 槽位检测
- `IS_SLOT_DEVICE=auto`: TWRP 无法检测 A/B 槽位时不中止
- 原因: OnePlus 9R TWRP 不通过 `getprop` 或 `/proc/cmdline` 报告槽位信息

#### MODULE_SIG 禁用 (关键启动修复)
- 禁用 `CONFIG_MODULE_SIG` / `MODULE_SIG_FORCE` / `MODULE_SIG_ALL`
- 原因: `MODULE_SIG_FORCE` 会拒绝所有厂商模块 (WiFi/相机等)，导致无法开机
- 厂商模块使用高通/一加密钥签名，我们无法获取
- 在运行时 toggle 步骤中强制禁用 (双重保险)

#### KERNEL_LZ4 清理
- 移除 `CONFIG_KERNEL_LZ4` — arm64 使用原始 `Image`，非自解压
- 该配置仅适用于 x86/arm32

---

### 五、版本字符串修复 (2026-07-30)

#### LOCALVERSION 显示
- 设置 `CONFIG_LOCALVERSION="-Oblivionis-kernel"`
- 禁用 `CONFIG_LOCALVERSION_AUTO`
- 创建空 `.scmversion` 文件防止 `scripts/setlocalversion` 追加 `+` 后缀
- 添加 `LOCALVERSION_AUTO=` 作为 make 变量
- 构建后添加版本字符串验证步骤
- 最终版本: `4.19.325-cip132-st16-Oblivionis-kernel`

---

### 六、高级特性集成 (2026-07-30)

#### 特性集成脚本
- 创建 `integrate-features.sh` 自动化特性集成脚本
- 使用预编写的 4.19 兼容源码文件，不依赖外部 6.x 仓库

#### 网络拥塞控制
- **BBRv3** (Google BBR v3): 独立模块 `tcp_bbr3.c`，不替换 BBRv1
  - 适配 4.19 API: `jiffies`、`TCP_INIT_CWND`、`cong_control` 回调
  - 编译失败时 BBRv1 继续作为默认拥塞控制
- **C2TCP**: 蜂窝网络/深缓冲网络低延迟拥塞控制 (`tcp_c2tcp.c`)
- **TCP ROCCET**: CUBIC + RTT/ACK 速率感知，面向 5G/移动网络 (`tcp_roccet.c`)
- **TCP Brutal**: Hysteria 速率控制 + 默认 ECN 协商 (`tcp_brutal.c`)
- 保留 BBRv1 (4.19 原生) 作为默认 + CUBIC/Westwood/Vegas 备选
- `TCP_FASTOPEN` + `TCP_ECN` + `TCP_MD5SIG`

#### 队列调度
- FQ / FQ-CoDel / CAKE / HTB / TBF / PRIO / CODEL
- `NET_RX_BUSY_POLL` + `BQL`
- `NET_NS` 网络命名空间

#### I/O 调度器
- **ADIOS 3.2.0**: 自适应截止时间 I/O 调度器 (`adios.c`)
  - 混合式: 截止时间调度 + 自适应优先级
  - 优化延迟模型、优先级调度和异常处理
  - 适配 4.19 `blk-mq` API
  - 编译失败时回退到 `mq-deadline`
- 保留 `mq-deadline` / `Kyber` / `BFQ` 备选
- `blk-throttling` (含 low limit) + `wbt` 写回节流

#### 内存管理
- **UKSM** (Ultra KSM): 增强版 KSM，自动扫描和合并
- **NTSYNC**: NT 同步原语驱动 (`ntsync.c`)，Wine/Proton 兼容
- **ZRAM**: 内置 + LZ4K/LZ4KD/LZ4HC/842 多压缩算法 (默认 LZ4KD)
- **Zswap**: 压缩交换缓存 (LZ4 + zsmalloc)
- **THP**: 透明大页 (含自动修复+回退机制)
- `MEMCG` + `MEMCG_SWAP` + `MEMCG_KMEM`

#### 压缩算法
- LZ4 / LZ4HC / LZ4K / LZ4KD / 842 / ZSTD / LZO
- LZ4K/LZ4KD 压缩/解压库

#### 安全加固
- Stack Protector (Strong) + `FORTIFY_SOURCE`
- `STRICT_KERNEL_RWX` + `STRICT_MODULE_RWX`
- `HARDENED_USERCOPY` + `REFCOUNT_FULL`
- `STRICT_DEVMEM` + `LOCKDOWN_LSM` (4.19 不支持，已禁用)
- dm-verity + FEC + 签名验证
- `SECURITY_YAMA` + `SECURITY_LOADPIN` + `SECURITY_SAFESETID`
- `VMAP_STACK` + `THREAD_INFO_IN_TASK` + `TCP_SYN_COOKIES`
- SLAB freelist 随机化/加固 + KASLR + KPTI (可选) + Retpoline

#### 文件系统
- **F2FS**: 压缩 (LZ4 + ZSTD) + XATTR + ACL + Security + Encryption
- **EROFS**: XATTR + ZIP + LZ4HC
- **EXT4**: POSIX ACL + Security
- `fs-verity` (含签名)
- 内联加密: `BLK_INLINE_ENCRYPTION` + `BLK_INLINE_ENCRYPTION_FALLBACK` + `QCOM_ICE`

#### Android 兼容性
- `ANDROID_VENDOR_HOOKS` (必需)
- `USERFAULTFD` (4.19 原生)
- `XDP_SOCKETS` (AF_XDP，4.18+ 原生)
  - 注: `XDP_SOCKETS_DIAG` 禁用 — 4.19 `xdp_umem` 结构体缺少字段
- `WIREGUARD` VPN (android-4.19-stable 内置)
- `DIAG_CHAR` (高通诊断字符设备，修复锁频段工具)
- `CPU_FREQ_TIMES` (CPU 频率统计)
- Android 17 AOSP GSI 兼容性配置
- `DMABUF_HEAPS` (System + CMA) + `ION`

#### cgroup v2
- `CGROUP_V2` + `CGROUP_FREEZER` + `CGROUP_PIDS` + `CGROUP_DEVICE`
- `CGROUP_CPUACCT` + `CGROUP_PERF` + `CGROUP_BPF` + `CGROUP_RDMA`
- `CGROUP_HUGETLB` + `CPUSETS` + `CGROUP_SCHEDTUNE`

#### 调度器增强
- `UCLAMP_TASK` (5.3 backport) — 利用率钳位
- `UCLAMP_BUCKETS_COUNT=20` + `UCLAMP_TASK_GROUP`
- `IO_URING` (5.1+ backport)
- `SECRETMEM` (5.14 backport)
- `SCHED_DEBUG` + `SCHED_INFO` + `SCHEDSTATS` + `SCHED_HRTICK`
- `CPU_FREQ_DEFAULT_GOV_SCHEDUTIL` + `ENERGY_MODEL`

#### 热管理
- `THERMAL_WRITABLE_TRIPS` + `THERMAL_GOV_STEP_WISE` + `THERMAL_GOV_POWER_ALLOCATOR`
- `CPU_THERMAL` + `DEVFREQ_THERMAL` + `CLOCK_THERMAL`

#### 看门狗
- `QCOM_WATCHDOG` + `WATCHDOG_NOWAYOUT`
- `SOFTLOCKUP_DETECTOR` + `DETECT_HUNG_TASK` (120s 超时)

---

### 七、4.19 兼容源码重构 (2026-07-30)

#### 新增源码文件
- `patches/features/src/tcp_bbr3.c` — BBRv3 独立模块
- `patches/features/src/tcp_brutal.c` — TCP Brutal 速率控制
- `patches/features/src/tcp_c2tcp.c` — C2TCP 蜂窝低延迟
- `patches/features/src/tcp_roccet.c` — ROCCET CUBIC+RTT/ACK 感知
- `patches/features/src/adios.c` — ADIOS 3.2.0 I/O 调度器
- `patches/features/src/ntsync.c` — NTSYNC NT 同步原语

所有源码均适配 4.19 API:
- `jiffies` 时间处理
- `TCP_INIT_CWND` 初始拥塞窗口
- `cong_control` 回调接口
- `blk-mq` 块层 API

---

### 八、THP 透明大页修复 (2026-07-30)

#### 问题
厂商内核 cherry-pick 了较新的主线 API 到头文件 (`rmap.h`, `mmu_notifier.h`)，
但未更新所有调用方 (`huge_memory.c`, `khugepaged.c`)，导致编译错误:
- `try_to_unmap()`: 参数数量不匹配 (2参数 vs 3参数)
- `mmu_notifier_invalidate_range_start/end()`: API 从3参数改为 `struct mmu_notifier_range*`
- `maybe_mkwrite()`: 需要 `vma_flags` 而非 `vma` 参数

#### 修复
- 创建 `fix-thp-compat.py` Python 修复脚本
  - `try_to_unmap`: 从 `rmap.h` 读取多行声明，自动适配第3参数
  - `mmu_notifier_invalidate_range_start/end`: struct API 适配
  - `maybe_mkwrite`: `vma->vm_flags` 适配
- 集成到 CI 流水线，自动运行
- **自动回退机制**: 修复失败时自动禁用 THP，确保构建成功

---

### 九、Makefile 完整性修复 (2026-07-30)

#### 问题
特性集成脚本向 Makefile 追加条目时，如果原文件不以换行符结尾，
新条目会与最后一行连接，导致:
- `No rule to make target 'block/blk-crypto-fallback.oobj-'` 错误

#### 修复
- `add_makefile_entry()` 函数添加前导换行符
- 所有直接 `echo >> Makefile` 命令添加前导换行符
- CI 添加 Makefile 完整性检查步骤 (确保所有 Makefile 以换行符结尾)
- 修复 `set -e` 下 `&&` 链条件不满足导致的退出 (改用 `if` 语句)

---

### 十、构建产物 (Run #53)

| 产物 | 大小 | 说明 |
|------|------|------|
| `Oblivionis-kernel-4.19-extreme-53` | 24.7 MB | AnyKernel3 刷机包 |
| `Image-extreme-53` | 22.6 MB | 内核镜像 (fastboot 刷入) |
| `build-log-extreme-53` | 0.1 MB | 构建日志 |

---

### 十一、已知限制 (4.19 基线)

以下特性无法在 4.19 内核上实现:

| 特性 | 原因 | 替代方案 |
|------|------|----------|
| MGLRU | 需要 6.1+ mm/ 重构 | 原生 LRU + KSM + zram |
| DAMON | 需要 5.15+ | — |
| EEVDF 调度器 | 需要 6.6+ | WALT + SchedTune + uclamp |
| sched_ext | 需要 6.12+ | — |
| Folio | 需要 6.1+ | — |
| BBRv3 (内置) | 需要 5.4+ TCP 栈 | BBRv3 独立模块 + BBRv1 默认 |
| zram 多压缩 (6.6) | 补丁不适用于 4.19 代码库 | LZ4/LZ4HC/ZSTD (4.19 原生) |
| zsmalloc per-class lock (6.12) | 4.19 已有 per-class 锁定 | — |
| LZ4K/LZ4KD (内置) | 需要 zram 多压缩流框架 | 配置已启用，实际取决于编译支持 |

---

### 十二、Backport 文档

创建了以下 backport 可行性分析文档:

| 目录 | 特性 | 状态 |
|------|------|------|
| `eevdf/` | EEVDF 调度器 | ❌ 不可行 (替换整个 CFS) |
| `binder-uclamp/` | Binder IPC UClamp | ⚠️ 需适配 (android13-5.15-lts) |
| `cpufreq-stats/` | cpufreq 统计驱动 | ⚠️ 需适配 |
| `sched-topology-dsu/` | DynamIQ Shared Unit 拓扑 | ⚠️ 需适配 |
| `cass-llc/` | CASS LLC 缓存亲和 | ⚠️ 需适配 |
| `wireguard/` | WireGuard VPN | ✅ 已内置 |
| `tcp-bbr2/` | TCP BBR v2 | ⚠️ 需大量适配 |
| `input-boost/` | 触摸触发 CPU 提频 | ⚠️ 需适配 |

---

### 十三、配置变体

| 变体 | 描述 |
|------|------|
| `perf` | 性能优先，稳定，最少特性 |
| `advanced` | PSI + CFI + fs-verity + BBR + 高级 I/O |
| `extreme` | 全特性 + 调度优化 + 内存优化 + 所有 backport |

CI 工作流参数:
- `config_variant`: perf / advanced / extreme
- `apply_backports`: 是否应用主线 backport 补丁
- `lto`: ThinLTO (性能提升，构建较慢)
- `kpti`: KPTI (安全开启，~1-3% 性能损耗)
- `cfi`: Clang CFI (控制流完整性)

---

### 十四、CI/CD 构建历史

| Run # | 结果 | 关键变更 |
|-------|------|----------|
| #53 | ✅ 成功 | Makefile 完整性检查修复 |
| #52 | ❌ 失败 | Makefile 条目拼接 |
| #51 | ❌ 失败 | THP API 兼容性 |
| #50 | ❌ 失败 | YAML 语法 (Python heredoc) |
| #49 | ❌ 失败 | THP vendor 代码 API 不匹配 |
| #48 | ❌ 失败 | grep\|head SIGPIPE |
| #47 | ✅ 成功 | 4.19 兼容源码重构 |
| #46 | ❌ 失败 | BBRv3 编译 + 回退机制 |
| #45 | ❌ 失败 | 高级特性集成 |
| #44 | ❌ 失败 | 补丁生成 bash 算术 |
| #43 | ❌ 失败 | LOCALVERSION 显示 |
| #42 | ❌ 失败 | KCONFIG_CONFIG 路径 |
| #41 | ❌ 失败 | scmversion + 后缀 |
| #40 | ❌ 失败 | AnyKernel3 IS_SLOT_DEVICE |
| #39 | ❌ 失败 | YAML heredoc 解析 |
| #38 | ❌ 失败 | AnyKernel3 配置重写 |
| #37 | ❌ 失败 | AnyKernel3 error 1 (device.name) |
| #36 | ❌ 失败 | CONFIG_KERNEL_LZ4 |
| #35 | ❌ 失败 | MODULE_SIG_FORCE (启动阻断) |
| #34 | ❌ 失败 | XDP_SOCKETS_DIAG |
| #33 | ❌ 失败 | userfaultfd/XDP/WireGuard/diag |
| #32 | ❌ 失败 | BTF resolve_btfids |
| #31 | ❌ 失败 | AnyKernel3 仓库地址 |
| #30 | ❌ 失败 | GCC 11 厂商代码 |
| #29 | ❌ 失败 | __compiletime_error |
| #28 | ❌ 失败 | __bad_copy_to/from |
| #27 | ❌ 失败 | Clang → GCC 切换 |
| #26 | ❌ 失败 | KCFLAGS 警告抑制 |
| #25 | ❌ 失败 | 厂商代码警告 |
| #24 | ❌ 失败 | THP int-conversion (Clang) |
| #23 | ❌ 失败 | 管道错误检测 |
| #22 | ❌ 失败 | 内核镜像检测 |
| #21 | ❌ 失败 | arm32 gcc / zip 排除 |
| #20 | ❌ 失败 | scripts/config 路径 |
| #19 | ❌ 失败 | gcc-aarch64-linux-gnu |
| #18 | ❌ 失败 | defconfig 路径 |
| #17 | ❌ 失败 | 配置合并 |
| #16 | ❌ 失败 | YAML heredoc 缩进 |
| #1-15 | ❌ 失败 | 初始构建流水线搭建 |

---

## 技术栈

- **内核源码**: LineageOS/android_kernel_oneplus_sm8250 (lineage-23.2)
- **内核版本**: Linux 4.19.325 (CIP stable tree)
- **工具链**: Proton Clang (Clang 17+) + GCC 11 (aarch64-linux-gnu)
- **CI/CD**: GitHub Actions (ubuntu-22.04)
- **打包**: AnyKernel3 (osm0sis/AnyKernel3)
- **目标设备**: OnePlus 9R (lemonades / SM8250 / Snapdragon 870)
- **目标系统**: ColorOS 16 (C16)

---

## 仓库结构

```
op9r-c16-kernel-builder/
├── .github/workflows/build.yml          — CI/CD 构建流水线
├── configs/                             — 内核配置片段
│   ├── lemonades_c16_extreme.fragment   — 全特性 + 调优
│   ├── lemonades_c16_advanced.fragment  — 高级特性
│   ├── lemonades_c16_perf.fragment      — 性能优先
│   ├── lemonades_c16_security.fragment  — 安全加固 + BBG
│   ├── lemonades_c16_droidspaces.fragment — 容器 + 网络
│   ├── lemonades_c16_510.fragment       — 5.10 基线 (未使用)
│   └── lemonades_c16_510_extreme.fragment — 5.10 极限 (未使用)
├── patches/
│   ├── features/                        — 高级特性集成
│   │   ├── src/                         — 4.19 兼容源码
│   │   │   ├── tcp_bbr3.c               — BBRv3 模块
│   │   │   ├── tcp_brutal.c             — TCP Brutal
│   │   │   ├── tcp_c2tcp.c              — C2TCP
│   │   │   ├── tcp_roccet.c             — TCP ROCCET
│   │   │   ├── adios.c                  — ADIOS 3.2.0
│   │   │   └── ntsync.c                 — NTSYNC
│   │   ├── integrate-features.sh        — 特性集成脚本
│   │   └── fix-thp-compat.py            — THP API 兼容修复
│   └── mainline-backports/              — 主线 backport
│       ├── apply-backports.sh           — 补丁应用脚本
│       ├── cherry-pick-mainline.sh      — cherry-pick 脚本
│       ├── zram66/                      — zram 6.6 backport
│       ├── zsmalloc612/                 — zsmalloc 6.12 backport
│       ├── eevdf/                       — EEVDF (不可行)
│       ├── binder-uclamp/               — Binder UClamp
│       ├── cpufreq-stats/               — cpufreq 统计
│       ├── sched-topology-dsu/          — DSU 拓扑
│       ├── cass-llc/                    — CASS LLC
│       ├── wireguard/                   — WireGuard
│       ├── tcp-bbr2/                    — BBR v2
│       └── input-boost/                 — 输入提频
├── templates/anykernel.sh               — AnyKernel3 刷机模板
├── build.sh                             — 本地构建脚本
├── README.md                            — 项目说明
├── FEATURES_ANALYSIS.md                 — 特性兼容性分析
└── CHANGELOG.md                         — 本文件
```
