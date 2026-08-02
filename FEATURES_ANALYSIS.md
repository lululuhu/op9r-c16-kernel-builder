# Oblivionis-kernel 特性兼容性分析

本文档详细分析了用户请求的各特性在 Linux 4.19.325 内核上的可行性。

## 已实现特性

### BBG 防格机 (Anti-crash/Anti-panic)
- **状态**: ✅ 已实现
- **配置**: `configs/lemonades_c16_security.fragment`
- **功能**: oops 转 panic、5 秒自动重启、硬/软锁死检测、挂起任务检测、pstore 崩溃日志

### Droidspaces 容器支持
- **状态**: ✅ 已实现 (配置层)
- **配置**: `configs/lemonades_c16_droidspaces.fragment`
- **补丁**: CI 自动下载 non-GKI 补丁
- **功能**: 命名空间、cgroup、OverlayFS、VETH/Bridge 网络隔离、IPSET、UFW/Fail2ban 支持
- **参考**: [Droidspaces Kernel Configuration Guide](https://github.com/ravindu644/Droidspaces-OSS/blob/main/Documentation/Kernel-Configuration.md)

### WireGuard VPN
- **状态**: ✅ 已实现
- **功能**: android-4.19-stable 内置，配置已启用

### IPSET 工具集
- **状态**: ✅ 已实现
- **配置**: `configs/lemonades_c16_droidspaces.fragment`
- **功能**: hash:ip, hash:net, hash:ipport, list:set 等完整 IPSET 支持

### 网络拥塞控制增强
- **状态**: ✅ 部分实现
- **已启用**: BBRv1 (4.19 原生), CUBIC, Westwood, Vegas
- **队列调度**: FQ, FQ-CoDel, CAKE, HTB, TBF, CODEL
- **TCP Brutal**: CI 自动下载源码集成 (作为外挂模块)
- **参考**: [TCP Brutal](https://github.com/apernet/tcp-brutal)

### 热点共享/网络稳定性增强
- **状态**: ✅ 已实现
- **配置**: `configs/lemonades_c16_droidspaces.fragment`
- **功能**: 完整 Netfilter 框架、CONNMARK 追踪、桥接防火墙、IPv6 NAT、QoS 调度

### ZRAM 内置
- **状态**: ✅ 已实现
- **功能**: ZRAM + ZSMALLOC 内置 (非模块)、writeback、memory tracking
- **压缩算法**: LZ4 (默认), LZ4HC, ZSTD — 均为 4.19 原生支持

### 安全漏洞修复
- **状态**: ✅ 已实现
- **配置**: `configs/lemonades_c16_security.fragment`
- **功能**: SLAB freelist 随机化/加固、KASLR、KPTI、Retpoline、栈清零、页分配器随机化

### Android 17 AOSP GSI 兼容
- **状态**: ✅ 兼容 (无需内核修改)
- **说明**: OnePlus 9R 出厂 Android 11 (API 30)，完全符合 Treble 标准。GSI 兼容性取决于 vendor 分区和 HAL，内核本身无需修改。直接刷入 Android 17 GSI system.img 即可。

---

## 无法在 4.19 实现的特性

### ADIOS 3.2.0 I/O 调度器
- **状态**: ❌ 不可行
- **原因**: ADIOS 3.2.0 基于 Linux 6.15+ 的 blk-mq API，4.19 的块层接口差异巨大，需要完全重写调度器代码
- **替代方案**: 使用 4.19 原生的 Kyber (低延迟) 和 Deadline 调度器
- **参考**: [ADIOS GitHub](https://github.com/firelzrd/adios)

### Google BBRv3
- **状态**: ❌ 不可行
- **原因**: BBRv3 补丁基于 5.4+ 的 TCP 栈，4.19 的 TCP 内部结构 (tcp_sock、拥塞控制框架) 差异过大，backport 需要重写大量 TCP 核心代码
- **替代方案**: 使用 4.19 原生的 BBRv1
- **参考**: [Google BBR v3](https://github.com/google/bbr/blob/v3/README.md)

### C2TCP
- **状态**: ⚠️ 理论可行但工作量大
- **原因**: C2TCP 原始实现基于 4.13.1 内核的 CUBIC，需要适配 4.19 的 TCP 框架。可作为独立模块编译，但需要大量测试
- **参考**: [C2TCP GitHub](https://github.com/c2tcp/c2tcp)

### TCP ROCCET
- **状态**: ❌ 不可行
- **原因**: ROCCET 是 RFC 补丁，需要 Linux 5.15+ 的 TCP CUBIC 实现。4.19 的 CUBIC 代码结构不同
- **参考**: [TCP ROCCET RFC](https://patchew.org/linux/aaw7WZdZA9MDo8cm@volt-roccet-vm/)

### UKSM (Ultra Kernel Samepage Merging)
- **状态**: ⚠️ 需要手动适配
- **原因**: UKSM 补丁最新版本针对 5.x 内核。4.19 版本需要从 [dolohow/uksm](https://github.com/dolohow/uksm) 获取对应版本并手动适配
- **替代方案**: 当前使用标准 KSM

### NTSYNC
- **状态**: ❌ 不可行
- **原因**: NTSYNC 驱动在 Linux 6.14 才被合入主线，依赖 6.x 的同步原语框架。4.19 的等待队列和锁机制完全不同
- **参考**: [NTSYNC LWN](https://lwn.net/Articles/960275/)

### MGLRU
- **状态**: ❌ 不可行
- **原因**: MGLRU 需要 6.1+ 的 mm/ 子系统大规模重构，4.19 的 LRU 框架完全不同
- **替代方案**: 4.19 原生 LRU + KSM + zram

### Lindroid EVDI
- **状态**: ❌ 不适用
- **原因**: EVDI 是显示驱动模块，不是内核核心特性。需要单独编译为外挂模块
- **参考**: EVDI 需要独立的 DKMS 模块

### LZ4K / LZ4KD 压缩算法
- **状态**: ❌ 不可行
- **原因**: LZ4K/LZ4KD 是 Google 为 Android 定制的压缩算法，需要较新的 crypto API 和 zram 框架。4.19 的 zram 不支持多压缩流
- **替代方案**: 使用 4.19 原生的 LZ4 (最快) 和 ZSTD (最佳压缩率)

### Zswap
- **状态**: ✅ 可配置启用
- **说明**: 4.19 原生支持 Zswap，已在配置中启用

### THP (Transparent Huge Pages)
- **状态**: ⚠️ 已知编译问题
- **原因**: 4.19.325 + Clang 编译 THP 存在 int-conversion 错误 (厂商代码问题)
- **当前状态**: 暂时禁用，待修复

### Mountify 模块支持
- **状态**: ⚠️ 需要进一步研究
- **说明**: Mountify 是用户态工具，内核端支持通过 OverlayFS 和命名空间配置已覆盖

---

## 配置文件说明

| 文件 | 说明 |
|------|------|
| `configs/lemonades_c16_extreme.fragment` | 主配置: 调度器、内存、文件系统优化 |
| `configs/lemonades_c16_security.fragment` | 安全加固 + BBG防格机 |
| `configs/lemonades_c16_droidspaces.fragment` | Droidspaces容器 + 网络增强 |

CI 构建时会自动合并所有三个 fragment。
