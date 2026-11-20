# StallScope

**Windows 卡顿检测工具**

一个用于记录 Windows 系统卡顿瞬间运行状态的监控脚本。针对整机停止响应一至三秒、音频爆音，而任务管理器中 CPU、磁盘与内存占用均显示正常的场景。

无需安装，无需编译。监控本身不需要管理员权限。纯粹依赖系统自带的 PowerShell 与性能计数器。

> **免责声明**：本项目为独立开发的诊断工具，与 Microsoft 无任何关联，非官方产品。仅在用户本机上运行，不收集、不上传任何数据。

---

## 一、设计缘由

多数监控工具只是监控机器的负载。当系统在空闲状态下发生卡顿时，这一指标无法提供有效信息：CPU 占用 5%，磁盘占用 0%，无法据此判断故障来源。

StallScope 采用不同的测量方式。每 500 毫秒，它向内核查询一次「实际流逝了多少 CPU 时间」，并与墙钟时间进行对比。若墙钟推进的幅度超出 CPU 时间的允许范围，说明该时段内机器未在执行任何任务，此现象将被记录。

核心字段为 `cvg`（覆盖率）：

```
cvg = 记录到的 CPU 时间 / （核数 × 卡顿时长）
```

- **接近 100%**：整机时间均被计入。卡顿真实存在，内核中存在阻塞源。
- **明显低于 100%**：仅部分核心在产生 CPU 时间，其余核心处于停泊状态或在 CPU 之外等待。

单一指标即可区分「各进程均在执行」与「各进程均在等待」两种情况，这通常是首要的有效线索。

### 上游相关链接

| 说明 | 链接 |
|---|---|
| Windows 性能计数器文档 | https://learn.microsoft.com/en-us/windows/win32/perfctrs/performance-counters-portal |
| GetSystemTimes API | https://learn.microsoft.com/en-us/windows/win32/api/processthreadsapi/nf-processthreadsapi-getsystemtimes |
| MMCSS 多媒体类调度服务 | https://learn.microsoft.com/en-us/windows/win32/procthread/multimedia-class-scheduler-service |
| Intel DPTF 说明 | https://www.intel.com/content/www/us/en/developer/articles/technical/dynamic-platform-and-thermal-framework.html |

---

## 二、功能特性

- ⚡ **全自动监控**：注册计划任务后于每次登录自动启动，进程异常终止后 1 分钟内自动恢复。
- 🎯 **免安装运行**：直接调用 PowerShell 脚本，无需编译、无需第三方依赖。
- 📊 **覆盖率指标**：独有 `cvg` 字段，可区分「CPU 繁忙」与「CPU 停摆」两种本质不同的卡顿。
- 🔍 **深度快照**：针对 1450–1700 毫秒区间的典型周期性卡顿，额外记录进程数、线程数与句柄数的变化。
- 📈 **自动分类报告**：生成 Markdown 报告，将卡顿归入 PAGING、C-STATE、BUSY、KERNEL、SHORT 五类。
- 🔒 **完全本地**：日志写入本地文件，不联网，不上传。
- 🧩 **参数可调**：采样间隔、运行时长、记录阈值均可通过命令行参数配置。
- 🛠 **可选实验脚本**：附带 DPTF 排除测试与处理器空闲开关，均自带回滚命令。

### 分类逻辑

| 类别 | 判定条件 | 可能原因 |
|---|---|---|
| `PAGING` | `cvg` ≥ 90，`pagesIn` ≥ 500，`availMB` < 2000 | 物理内存不足，发生换页 |
| `C-STATE` | `cvg` < 50 | 核心停泊，或在 CPU 之外等待 |
| `BUSY` | 单一进程占用窗口时长 70% 以上 | 该进程正在执行实际工作 |
| `KERNEL` | `cvg` ≥ 90，且所有进程均空闲 | 驱动或内核组件阻塞 |
| `SHORT` | 其余情况 | 无主导原因 |

---

## 三、快速使用（桌面脚本，推荐普通用户）

### 1. 直接使用

下载或克隆本仓库后，右键单击安装脚本。

```
StallScope\
└── Install.cmd        ← 右键 → 以管理员身份运行
```

首次运行会自动完成以下操作：

- 检测当前安装路径
- 注册计划任务 `StallScope`
- 启动监控进程
- 在 `logs\` 目录创建日志文件

安装完成后即可正常使用计算机。发生卡顿时记录下大致时间。

### 2. 生成报告

```
StallScope\
└── Make Report.cmd    ← 双击运行，无需管理员权限
```

报告将生成于 `logs\stallscope-report-<时间戳>.md`，可用任意 Markdown 编辑器打开。

### 3. 卸载

```
StallScope\
└── Uninstall.cmd      ← 右键 → 以管理员身份运行
```

卸载仅移除计划任务与监控进程，`logs\` 目录中的历史日志予以保留。如需彻底删除，请手动移除该目录。

### 4. 免安装运行（高级用户）

无需注册计划任务，直接以前台方式运行监控：

```powershell
cd StallScope
.\bin\stallscope.ps1 -Hours 2
```

按 <kbd>Ctrl</kbd>+<kbd>C</kbd> 终止。

---

## 四、命令行说明

### stallscope.ps1

```
.\bin\stallscope.ps1 [-LogDirectory <路径>] [-Hours <小时>] [-Threshold <毫秒>] [-Quiet]
```

| 参数 | 默认值 | 说明 |
|---|---|---|
| `-LogDirectory` | `<安装目录>\logs` | 日志存放位置 |
| `-Hours` | `8` | 运行时长，单位小时 |
| `-Threshold` | `300` | 超出采样间隔多少毫秒后记录 |
| `-Quiet` | 关闭 | 不输出控制台信息，供计划任务使用 |

同一日志目录仅允许一个实例运行，由锁文件控制。若检测到超过 10 分钟的残留锁，将自动清理后继续启动。

### report.ps1

```
.\bin\report.ps1 [-LogPath <日志路径>] [-OutPath <报告路径>]
```

| 参数 | 默认值 | 说明 |
|---|---|---|
| `-LogPath` | `<安装目录>\logs\idle-stalls.txt` | 待分析的日志文件 |
| `-OutPath` | 与日志同目录，文件名含时间戳 | 报告输出路径 |

---

## 五、日志字段

每次卡顿生成一条记录：

```
2026-01-15 14:22:31.847  STALL++  gap= 2581ms cpu=  6% cvg= 100%
  kMs=61406 iMs= 58344 availMB=  488 compMB= 391 faults=  5992/s
  pagesIn=     8/s diskQ=  0 | idea64#6372=281ms java#34488=94ms ...
```

| 字段 | 含义 | 健康值 |
|---|---|---|
| `gap` | 卡顿时长，单位毫秒 | 低于 300 |
| `cpu` | 窗口内 CPU 使用率 | 视负载而定 |
| `cvg` | 覆盖率，定义见第一章 | 95–105% |
| `kMs` / `iMs` | 内核时间 / 空闲时间 | — |
| `availMB` | 可用物理内存 | 高于 2000 |
| `compMB` | 内存压缩占用 | 低于 500 |
| `faults` | 页面错误频率，单位每秒 | 视情况而定 |
| `pagesIn` | 从磁盘读取的页数，单位每秒 | 低于 100 |
| `diskQ` | 磁盘队列长度 | 低于 3 |
| `top:` | CPU 占用最高的八个进程 | — |

### 心跳记录

每五分钟生成一条，用于区分「未发生卡顿」与「监控进程已停止」：

```
2026-01-15 14:25:00.121  alive #3 stalls=7 procs=331 threads=7402 handles=231114 availMB=2288 compMB=352
```

若日志中持续出现 `alive` 记录而无 `STALL` 记录，说明该时段未检测到超过阈值的事件。

### 深度快照

时长在 1450 至 1700 毫秒之间的卡顿，通常为周期性后台任务的特征。针对此类卡顿，额外记录前后进程数、线程数与句柄总数，以及任何显著增长项：

```
      DEEP[at-stall] procs 380->380  threads 8997->8999 (+2)  handles 271913->271909 (-4)
      DEEP[at-stall] changed: none (>=5 threads or handles)
```

该机制可捕获仅观察 CPU 无法发现的句柄泄漏与线程突发。

---

## 六、报告结构

生成的 Markdown 报告包含以下章节：

| 章节 | 内容 |
|---|---|
| Summary | 卡顿总数、时间跨度、频率、最长与平均时长、平均覆盖率 |
| Breakdown by class | 各分类的数量与占比 |
| What this points to | 主导类别的判定与对应处置建议 |
| Per-stall detail | 每次卡顿的时间、类别、各项指标与占用最高的进程 |
| How to read the columns | 字段含义速查表 |
| Caveats | 使用限制与误判可能 |

---

## 七、目录结构

```
StallScope/
├── README.md                    英文文档
├── README.zh-CN.md              中文文档（本文件）
├── RELEASE.md                   发布页文档
├── LICENSE                      MIT 许可证
├── .gitignore                   排除日志与临时文件
├── Install.cmd                  安装计划任务（需管理员）
├── Uninstall.cmd                卸载计划任务（需管理员）
├── Make Report.cmd              生成 Markdown 报告
├── bin/
│   ├── stallscope.ps1           监控主体（331 行）
│   └── report.ps1               报告生成器（259 行）
├── scripts/
│   ├── dptf-test.cmd            暂停 Intel 动态调优 10 分钟后恢复（95 行）
│   ├── disable-idle-ac.cmd      仅插电时禁用处理器空闲（70 行）
│   └── revert-idle.cmd          撤销上一条设置（54 行）
└── logs/
    └── .gitkeep                 运行时生成日志的目录占位
```

---

## 八、已知限制

- 进程枚举频率为每秒两次，当进程数超过五百时开销会明显上升（约占单核 5%–7%）。
- 时长极短但频率较高的卡顿（低于 300 毫秒）会被采样间隔过滤掉。可通过降低 `-Threshold` 改善，但代价是日志量增加。
- 报告分类基于经验阈值，不保证在所有机器上均准确。
- 不包含内核级跟踪功能。若要定位 `KERNEL` 类卡顿的具体驱动，需使用 WPR 或 PerfView，两者均要求管理员权限。在启用基于虚拟化的安全（VBS）时，WPR 可能直接拒绝运行，并报告 `WPR_E_POLICYFAILURE`。此为 Windows 的既定限制，本工具不予规避。
- `cvg` 偏低不必然代表故障。在轻载系统中，部分 CPU 本就不产生时间。有效的信号是：在确实感知到卡顿的时刻，`cvg` 呈现偏低。

---

## 九、系统要求

| 项目 | 要求 |
|---|---|
| 操作系统 | Windows 10 2004 或更高版本，推荐 Windows 11 |
| PowerShell | 5.1（系统自带），无需安装 PowerShell 7 |
| 管理员权限 | 监控本身不需要；安装、卸载及可选脚本需要 |
| 磁盘空间 | 约 60 KB（不含日志） |

---

---

## 许可证

MIT License，详见 [LICENSE](LICENSE)。

Copyright © 2026 Hoshiko016
