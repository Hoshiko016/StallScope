#Requires -Version 5.1
<#
.SYNOPSIS
    StallScope - Windows stall (hitch/freeze) detector

.DESCRIPTION
    Samples the system every 500 ms and records what the machine was doing
    at the moment it stopped responding. Designed to catch the kind of stall
    that does not show up as high CPU or disk usage: the whole machine
    freezes for 1-3 seconds while every process looks idle.

    Each record captures:
      gap       - how late the sampling loop actually ran (the stall length)
      cvg       - coverage: recorded CPU time / (cores x gap); ~100% means the
                  measurement is trustworthy, low values mean parts of the
                  machine were not producing CPU time at all
      cpu       - overall CPU busy percentage for the window
      kMs/uMs/iMs - kernel / user / idle time in milliseconds
      availMB   - free physical memory
      compMB    - memory compression working set
      faults    - page faults per second
      pagesIn   - pages read from disk per second (the real paging signal)
      diskQ     - disk queue length
      top       - the 8 busiest processes in that window

    A DEEP block is added for stalls between 1450 and 1700 ms, which is a
    common length for periodic stalls: it records process/thread/handle
    totals before and after, plus every process whose thread or handle
    count moved by 5 or more.

.PARAMETER LogDirectory
    Where idle-stalls.txt is written. Defaults to <install>\logs

.PARAMETER Hours
    How long to run before exiting. Default 8.

.PARAMETER Threshold
    Milliseconds of lateness beyond the sampling interval before a stall
    is recorded. Default 300 (i.e. stalls longer than ~800 ms).

.PARAMETER Quiet
    Suppress console output. Useful when started by a scheduled task.

.EXAMPLE
    .\stallscope.ps1 -Hours 2

.EXAMPLE
    .\stallscope.ps1 -LogDirectory <your-folder>\ss -Threshold 200 -Quiet

.NOTES
    No administrator rights are required. Runs entirely in user space.
    Single instance per log directory (uses a lock file).
#>
[CmdletBinding()]
param(
    [string] $LogDirectory,
    [int]    $Hours = 8,
    [int]    $Threshold = 300,
    [switch] $Quiet
)

$ErrorActionPreference = 'SilentlyContinue'

# ---------------------------------------------------------------- paths ----
$InstallRoot = Split-Path -Parent $PSScriptRoot
if (-not $LogDirectory) { $LogDirectory = Join-Path $InstallRoot 'logs' }
if (-not (Test-Path $LogDirectory)) {
    New-Item -ItemType Directory -Path $LogDirectory -Force | Out-Null
}
$Out  = Join-Path $LogDirectory 'idle-stalls.txt'
$Lock = Join-Path $LogDirectory '.stallscope.lock'
$Cfg  = Join-Path $LogDirectory 'config.json'

$Interval = 500   # ms between samples
$Label    = 'stallscope'

# ------------------------------------------------------------- helpers ----
function Say {
    param([string] $Message)
    if (-not $Quiet) { Write-Host $Message }
}

function Write-Log {
    param([string] $Line)
    try { Add-Content -Path $Out -Value $Line -Encoding UTF8 } catch { }
}

Add-Type -MemberDefinition @'
[StructLayout(LayoutKind.Sequential)] public struct FT { public uint lo; public uint hi; }
[DllImport("kernel32.dll")]
public static extern bool GetSystemTimes(out FT idle, out FT kernel, out FT user);
'@ -Name Native -Namespace StallScope

function To-U64 { param($ft) return ([double]$ft.hi * 4294967296.0) + [double]$ft.lo }

function Get-SystemTimes {
    $i = New-Object StallScope.Native+FT
    $k = New-Object StallScope.Native+FT
    $u = New-Object StallScope.Native+FT
    if (-not [StallScope.Native]::GetSystemTimes([ref]$i, [ref]$k, [ref]$u)) { return $null }
    return @{ idle = (To-U64 $i); kernel = (To-U64 $k); user = (To-U64 $u) }
}

function Get-MemoryInfo {
    $r = @{ availMB = -1; faultSec = -1; pagesInSec = -1; compMB = -1 }
    try {
        $c = Get-Counter -Counter '\Memory\Available MBytes','\Memory\Page Faults/sec','\Memory\Pages Input/sec' -MaxSamples 1 -ErrorAction Stop
        foreach ($s in $c.CounterSamples) {
            switch -Wildcard ($s.Path) {
                '*available mbytes*' { $r.availMB    = [math]::Round($s.CookedValue) }
                '*page faults/sec*'  { $r.faultSec   = [math]::Round($s.CookedValue) }
                '*pages input/sec*'  { $r.pagesInSec = [math]::Round($s.CookedValue) }
            }
        }
    } catch { }
    $mc = Get-Process 'Memory Compression' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($mc) { $r.compMB = [math]::Round($mc.WorkingSet64 / 1MB) }
    return $r
}

function Get-Snapshot {
    $h = @{}
    foreach ($p in [Diagnostics.Process]::GetProcesses()) {
        try {
            $h[$p.Id] = @{
                n  = $p.ProcessName
                t  = $p.TotalProcessorTime.TotalSeconds
                th = $p.Threads.Count
                hc = $p.HandleCount
            }
        } catch { }
    }
    return $h
}

function Get-Totals {
    param($Snapshot)
    $th = 0; $hc = 0
    foreach ($k in $Snapshot.Keys) { $th += $Snapshot[$k].th; $hc += $Snapshot[$k].hc }
    return @{ procs = $Snapshot.Count; threads = $th; handles = $hc }
}

function Write-DeepReport {
    param([string] $Tag, $Before, $After)
    $tb = Get-Totals $Before
    $ta = Get-Totals $After
    $dt = $ta.threads - $tb.threads
    $dh = $ta.handles - $tb.handles
    Write-Log ("      DEEP[{0}] procs {1}->{2}  threads {3}->{4} ({5:+0;-0})  handles {6}->{7} ({8:+0;-0})" -f `
        $Tag, $tb.procs, $ta.procs, $tb.threads, $ta.threads, $dt, $tb.handles, $ta.handles, $dh)

    $changes = New-Object System.Collections.ArrayList
    foreach ($k in $After.Keys) {
        if (-not $Before.ContainsKey($k)) { continue }
        $dth = $After[$k].th - $Before[$k].th
        $dhc = $After[$k].hc - $Before[$k].hc
        if ([math]::Abs($dth) -ge 5 -or [math]::Abs($dhc) -ge 5) {
            [void]$changes.Add([pscustomobject]@{ n = $After[$k].n; id = $k; dth = $dth; dhc = $dhc })
        }
    }
    if ($changes.Count -gt 0) {
        $txt = (($changes | Sort-Object { -([math]::Abs($_.dth) + [math]::Abs($_.dhc)) } | Select-Object -First 10 |
                 ForEach-Object { $_.n + '#' + $_.id + ' th' + $_.dth.ToString('+0;-0') + ' hd' + $_.dhc.ToString('+0;-0') }) -join '  ')
        Write-Log ("      DEEP[" + $Tag + "] changed: " + $txt)
    } else {
        Write-Log ("      DEEP[" + $Tag + "] changed: none (>=5 threads or handles)")
    }
}

# ------------------------------------------------------------ run state ----
# A lock file left behind by a killed process would block every future run,
# so verify the lock is actually held before trusting it.
$lockAge = $null
if (Test-Path $Lock) { $lockAge = (Get-Date) - (Get-Item $Lock).LastWriteTime }

try {
    $lockStream = [System.IO.File]::Open($Lock, 'OpenOrCreate', 'ReadWrite', 'None')
} catch {
    if ($lockAge -and $lockAge.TotalMinutes -gt 10) {
        Write-Log ("{0:yyyy-MM-dd HH:mm:ss.fff}  stale lock detected (age {1:N0} min), removing" -f (Get-Date), $lockAge.TotalMinutes)
        try { Remove-Item $Lock -Force -ErrorAction Stop } catch { }
        try { $lockStream = [System.IO.File]::Open($Lock, 'OpenOrCreate', 'ReadWrite', 'None') }
        catch {
            Say 'Another StallScope instance is already running for this directory.'
            exit 0
        }
    } else {
        Say 'Another StallScope instance is already running for this directory.'
        exit 0
    }
}

$cores = [Environment]::ProcessorCount
$exitReason = 'terminated'
$stallCount = 0
$startTime  = Get-Date

# persist the parameters so the report tool can read them later
@{ hours = $Hours; threshold = $Threshold; interval = $Interval; cores = $cores; started = $startTime.ToString('o') } |
    ConvertTo-Json | Set-Content $Cfg -Encoding UTF8

try {
    $prev      = Get-Snapshot
    $prevSys   = Get-SystemTimes
    $lastWall  = Get-Date
    $end       = $startTime.AddHours($Hours)
    $nextBeat  = (Get-Date).AddMinutes(5)
    $beat      = 0

    Write-Log ''
    Write-Log ("{0:yyyy-MM-dd HH:mm:ss.fff}  === STALLSCOPE START pid={1} cores={2} interval={3}ms threshold={4}ms hours={5} ===" -f `
        (Get-Date), $PID, $cores, $Interval, $Threshold, $Hours)
    Write-Log ("{0:yyyy-MM-dd HH:mm:ss.fff}  deep snapshot active for stalls in the 1450-1700 ms band" -f (Get-Date))
    $initTot = Get-Totals $prev
    $initMem = Get-MemoryInfo
    Write-Log ("{0:yyyy-MM-dd HH:mm:ss.fff}  alive #0 baseline procs={1} threads={2} handles={3} availMB={4} compMB={5}" -f `
        (Get-Date), $initTot.procs, $initTot.threads, $initTot.handles, $initMem.availMB, $initMem.compMB)
    Say ("StallScope started. Log: {0}" -f $Out)
    Say 'Press Ctrl+C to stop.'

    while ((Get-Date) -lt $end) {
        Start-Sleep -Milliseconds $Interval
        $now     = Get-Date
        $gap     = [double]($now - $lastWall).TotalMilliseconds
        $lastWall = $now

        # periodic heartbeat so a healthy run is distinguishable from a dead one
        if ($now -ge $nextBeat) {
            $beat++
            $mem = Get-MemoryInfo
            $tot = Get-Totals $prev
            Write-Log ("{0:yyyy-MM-dd HH:mm:ss.fff}  alive #{1} stalls={2} procs={3} threads={4} handles={5} availMB={6} compMB={7}" -f `
                $now, $beat, $stallCount, $tot.procs, $tot.threads, $tot.handles, $mem.availMB, $mem.compMB)
            $nextBeat = $now.AddMinutes(5)
        }

        if ($gap -lt ($Interval + $Threshold)) {
            $prev    = Get-Snapshot
            $prevSys = Get-SystemTimes
            continue
        }

        # ----------------------------------------------------- stall! ----
        $stallCount++
        $cur    = Get-Snapshot
        $curSys = Get-SystemTimes

        if ($null -eq $curSys -or $null -eq $prevSys) {
            Write-Log ("{0:yyyy-MM-dd HH:mm:ss.fff}  STALL gap={1:0}ms (no CPU counters available)" -f $now, $gap)
            $prev = $cur; $prevSys = $curSys; $lastWall = Get-Date
            continue
        }

        $kMs = [double](($curSys.kernel - $prevSys.kernel) / 10000.0)
        $uMs = [double](($curSys.user   - $prevSys.user)   / 10000.0)
        $iMs = [double](($curSys.idle   - $prevSys.idle)   / 10000.0)

        $cpuPct = 0
        if (($kMs + $uMs) -gt 0) {
            $cpuPct = [math]::Round(100.0 * ($kMs + $uMs - $iMs) / ($kMs + $uMs), 0)
        }
        $cvg = 0
        if (($cores * $gap) -gt 0) {
            $cvg = [math]::Round(100.0 * ($kMs + $uMs) / ($cores * $gap), 0)
        }

        $diskQ = -1
        $dl = Get-CimInstance Win32_PerfFormattedData_PerfDisk_PhysicalDisk -ErrorAction SilentlyContinue |
              Where-Object { $_.Name -eq '_Total' } | Select-Object -First 1
        if ($dl) { $diskQ = $dl.CurrentDiskQueueLength }

        $mem = Get-MemoryInfo

        $busy = New-Object System.Collections.ArrayList
        foreach ($k in $cur.Keys) {
            if ($prev.ContainsKey($k)) {
                $d = $cur[$k].t - $prev[$k].t
                if ($d -gt 0.03) { [void]$busy.Add([pscustomobject]@{ n = $cur[$k].n; id = $k; d = $d }) }
            }
        }
        $top = 'none>30ms'
        if ($busy.Count -gt 0) {
            $top = (($busy | Sort-Object d -Descending | Select-Object -First 8 |
                     ForEach-Object { $_.n + '#' + $_.id + '=' + [math]::Round($_.d * 1000) + 'ms' }) -join ' ')
        }

        $tag = 'STALL'
        if ($gap -ge 1250) { $tag = 'STALL++' }
        if ($gap -ge 4750) { $tag = 'FREEZE' }

        $line  = $now.ToString('yyyy-MM-dd HH:mm:ss.fff') + '  ' + $tag.PadRight(7)
        $line += ' gap='   + ([int]$gap).ToString().PadLeft(5) + 'ms'
        $line += ' cpu='   + ([int]$cpuPct).ToString().PadLeft(3) + '%'
        $line += ' cvg='   + ([int]$cvg).ToString().PadLeft(4) + '%'
        $line += ' kMs='   + ([int]$kMs).ToString().PadLeft(5)
        $line += ' iMs='   + ([int]$iMs).ToString().PadLeft(6)
        $line += ' availMB=' + ([int]$mem.availMB).ToString().PadLeft(5)
        $line += ' compMB='  + ([int]$mem.compMB).ToString().PadLeft(4)
        $line += ' faults='  + ([int]$mem.faultSec).ToString().PadLeft(6) + '/s'
        $line += ' pagesIn=' + ([int]$mem.pagesInSec).ToString().PadLeft(6) + '/s'
        $line += ' diskQ='   + ([int]$diskQ).ToString().PadLeft(3)
        $line += ' | ' + $top
        Write-Log $line
        Say ("{0}  {1} {2}ms  cpu {3}%  cvg {4}%" -f $now.ToString('HH:mm:ss'), $tag, [int]$gap, [int]$cpuPct, [int]$cvg)

        # deep snapshot for the characteristic periodic-stall band
        if ($gap -ge 1450 -and $gap -le 1700) {
            Write-DeepReport 'at-stall' $prev $cur
            Start-Sleep -Milliseconds 400
            $again = Get-Snapshot
            Write-DeepReport 'after+400ms' $cur $again
            $prev = $again
        } else {
            $prev = $cur
        }

        $prevSys  = $curSys
        $lastWall = Get-Date
    }
    $exitReason = 'duration elapsed'
} catch {
    $exitReason = 'error: ' + $_.Exception.Message
} finally {
    Write-Log ("{0:yyyy-MM-dd HH:mm:ss.fff}  === STALLSCOPE EXIT pid={1} reason={2} stalls={3} ===" -f `
        (Get-Date), $PID, $exitReason, $stallCount)
    try { $lockStream.Close(); $lockStream.Dispose() } catch { }
    try { Remove-Item $Lock -Force -ErrorAction SilentlyContinue } catch { }
    Say ("StallScope stopped. {0} stall(s) recorded. Log: {1}" -f $stallCount, $Out)
}


