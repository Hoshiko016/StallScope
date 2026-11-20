# StallScope

**A Windows stall detector**

A monitoring script that records what a Windows machine was doing at the exact moment it stopped responding. Built for the case where the whole system freezes for one to three seconds, audio crackles, and Task Manager shows nothing wrong: low CPU, no disk activity, plenty of memory.

No installation, no compilation. Monitoring itself needs no administrator rights. It relies only on the PowerShell and performance counters that ship with Windows.

> **Disclaimer**: This is an independent diagnostic tool. It is not affiliated with, endorsed by, or in any way connected to Microsoft. It runs entirely on the local machine and collects or transmits no data.

---

## 1. Why This Exists

Most monitoring tools simply monitor how loaded the machine is. When the system freezes while idle, that answer is useless. CPU reads 5%, disk reads 0%, and nothing in those numbers points at a cause.

StallScope measures something else. Every 500 ms it asks the kernel how much CPU time has actually elapsed, and compares that to how much wall-clock time passed. If wall time moved much further than CPU time could account for, the machine was not executing anything during that window. That window gets recorded.

The central field is `cvg`, short for coverage:

```
cvg = recorded CPU time / (cores × stall duration)
```

- **Near 100%** — the whole machine is accounted for. The freeze is real, and something inside the kernel was blocking.
- **Well under 100%** — only part of the machine was producing CPU time. The rest was parked, or was waiting outside the CPU entirely.

That single number separates "everything is busy" from "everything is stuck", which is usually the first useful clue.

### Upstream references

| Topic | Link |
|---|---|
| Windows performance counters | https://learn.microsoft.com/en-us/windows/win32/perfctrs/performance-counters-portal |
| GetSystemTimes API | https://learn.microsoft.com/en-us/windows/win32/api/processthreadsapi/nf-processthreadsapi-getsystemtimes |
| MMCSS (Multimedia Class Scheduler Service) | https://learn.microsoft.com/en-us/windows/win32/procthread/multimedia-class-scheduler-service |
| Intel DPTF documentation | https://www.intel.com/content/www/us/en/developer/articles/technical/dynamic-platform-and-thermal-framework.html |

---

## 2. Features

- ⚡ **Starts automatically** — registers a scheduled task that runs at every logon and restarts within one minute if it dies.
- 🎯 **No install, no build** — plain PowerShell scripts. No compiler, no third-party dependencies.
- 📊 **Coverage metric** — the `cvg` field distinguishes "CPU busy" from "CPU stuck", two fundamentally different failures.
- 🔍 **Deep snapshots** — for stalls in the 1450–1700 ms band, process, thread and handle totals are captured before and after.
- 📈 **Automatic classification** — generates a Markdown report sorting every stall into PAGING, C-STATE, BUSY, KERNEL or SHORT.
- 🔒 **Fully local** — logs are written to disk. No network access, no telemetry.
- 🧩 **Configurable** — sampling interval, run duration and record threshold are all command-line parameters.
- 🛠 **Optional experiments** — DPTF exclusion test and a processor-idle toggle, each printing its own rollback command.

### Classification rules

| Class | Condition | Likely cause |
|---|---|---|
| `PAGING` | `cvg` ≥ 90, `pagesIn` ≥ 500, `availMB` < 2000 | Not enough physical memory; paging to disk |
| `C-STATE` | `cvg` < 50 | Cores parked, or waiting outside the CPU |
| `BUSY` | one process used ≥ 70% of the window | That process was doing real work |
| `KERNEL` | `cvg` ≥ 90, every process idle | A driver or kernel component blocked |
| `SHORT` | anything else | No dominant cause |

---

## 3. Quick Start (scripts, recommended for most users)

### 1. Install

After downloading or cloning the repository, right-click the install script.

```
StallScope\
└── Install.cmd        ← right-click → Run as administrator
```

On first run it will:

- detect the current install path
- register the scheduled task `StallScope`
- start the monitor
- create the log file under `logs\`

After that, use the computer normally. When a stall happens, note the approximate time.

### 2. Generate a report

```
StallScope\
└── Make Report.cmd    ← double-click, no admin needed
```

The report is written to `logs\stallscope-report-<timestamp>.md` and opens in any Markdown editor.

### 3. Uninstall

```
StallScope\
└── Uninstall.cmd      ← right-click → Run as administrator
```

Uninstalling removes only the scheduled task and the monitor process. Historical logs in `logs\` are kept. Delete that folder yourself if you want them gone.

### 4. Run without installing (advanced)

Run the monitor in the foreground instead of registering a task:

```powershell
cd StallScope
.\bin\stallscope.ps1 -Hours 2
```

Stop with <kbd>Ctrl</kbd>+<kbd>C</kbd>.

---

## 4. Command Reference

### stallscope.ps1

```
.\bin\stallscope.ps1 [-LogDirectory <path>] [-Hours <n>] [-Threshold <ms>] [-Quiet]
```

| Parameter | Default | Purpose |
|---|---|---|
| `-LogDirectory` | `<install>\logs` | Where the log is written |
| `-Hours` | `8` | How long to run, in hours |
| `-Threshold` | `300` | Extra lateness (ms) before a stall is recorded |
| `-Quiet` | off | Suppress console output; used by the scheduled task |

One instance per log directory is enforced with a lock file. A lock older than 10 minutes is treated as stale and cleared automatically.

### report.ps1

```
.\bin\report.ps1 [-LogPath <log>] [-OutPath <report>]
```

| Parameter | Default | Purpose |
|---|---|---|
| `-LogPath` | `<install>\logs\idle-stalls.txt` | Log to analyse |
| `-OutPath` | same folder, timestamped name | Where to write the report |

---

## 5. Log Fields

Every stall produces one record:

```
2026-01-15 14:22:31.847  STALL++  gap= 2581ms cpu=  6% cvg= 100%
  kMs=61406 iMs= 58344 availMB=  488 compMB= 391 faults=  5992/s
  pagesIn=     8/s diskQ=  0 | idea64#6372=281ms java#34488=94ms ...
```

| Field | Meaning | Healthy |
|---|---|---|
| `gap` | Stall length in milliseconds | under 300 |
| `cpu` | Busy CPU percentage across the window | depends on load |
| `cvg` | Coverage, defined in section 1 | 95–105% |
| `kMs` / `iMs` | Kernel time / idle time in the window | — |
| `availMB` | Free physical memory, MB | above 2000 |
| `compMB` | Memory compression working set, MB | under 500 |
| `faults` | Page faults per second | context dependent |
| `pagesIn` | Pages read from disk per second | under 100 |
| `diskQ` | Disk queue length | under 3 |
| `top:` | The eight busiest processes | — |

### Heartbeat

Written every five minutes, so a healthy run can be told apart from a dead one:

```
2026-01-15 14:25:00.121  alive #3 stalls=7 procs=331 threads=7402 handles=231114 availMB=2288 compMB=352
```

A log full of `alive` lines and no `STALL` lines means nothing crossed the threshold during that period.

### Deep snapshots

Stalls between 1450 and 1700 ms are a common signature of periodic background work. For those, process, thread and handle totals are recorded before and after, along with anything that grew noticeably:

```
      DEEP[at-stall] procs 380->380  threads 8997->8999 (+2)  handles 271913->271909 (-4)
      DEEP[at-stall] changed: none (>=5 threads or handles)
```

This catches handle leaks and thread bursts that a CPU-only view misses.

---

## 6. Report Structure

The generated Markdown report contains these sections:

| Section | Contents |
|---|---|
| Summary | Stall count, time span, rate, longest and average duration, average coverage |
| Breakdown by class | Count and share per class |
| What this points to | Dominant class and the cheapest fixes for it |
| Per-stall detail | Time, class, every metric and the busiest process per stall |
| How to read the columns | Field reference table |
| Caveats | Limits and possible misreads |

---

## 7. Layout

```
StallScope/
├── README.md                    English documentation (this file)
├── README.zh-CN.md              Chinese documentation
├── RELEASE.md                   Release page document
├── LICENSE                      MIT license
├── .gitignore                   Excludes logs and temp files
├── Install.cmd                  Install scheduled task (admin)
├── Uninstall.cmd                Remove scheduled task (admin)
├── Make Report.cmd              Generate the Markdown report
├── bin/
│   ├── stallscope.ps1           The monitor (331 lines)
│   └── report.ps1               Report generator (259 lines)
├── scripts/
│   ├── dptf-test.cmd            Pause Intel Dynamic Tuning for 10 min, then restore (95 lines)
│   ├── disable-idle-ac.cmd      Disable processor idle on AC only (70 lines)
│   └── revert-idle.cmd          Undo the above (54 lines)
└── logs/
    └── .gitkeep                 Placeholder for runtime logs
```

---

## 8. Known Limitations

- Processes are enumerated twice per second; with more than about five hundred processes the cost becomes noticeable (roughly 5–7% of one core).
- Very short, high-frequency stalls (under 300 ms) are filtered out by the sampling interval. Lowering `-Threshold` helps, at the cost of a larger log.
- Classification uses empirical thresholds and will not be right on every machine.
- No kernel-level tracing is included. Naming the exact driver behind a `KERNEL` stall requires WPR or PerfView, both of which need administrator rights. When Virtualization-Based Security is enabled, WPR may refuse outright and report `WPR_E_POLICYFAILURE`. That is a deliberate Windows restriction, not something this tool works around.
- A low `cvg` is not automatically a fault. On a lightly loaded machine, part of the CPU legitimately produces no time. The signal is a low `cvg` *during a stall you actually felt*.

---

## 9. Requirements

| Item | Requirement |
|---|---|
| OS | Windows 10 2004 or later; Windows 11 recommended |
| PowerShell | 5.1 (built into Windows); PowerShell 7 not required |
| Administrator rights | Not needed to monitor; required to install, uninstall or run the optional scripts |
| Disk space | about 60 KB, excluding logs |

---

---

## License

MIT License. See [LICENSE](LICENSE).

Copyright © 2026 Hoshiko016
