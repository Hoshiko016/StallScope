#Requires -Version 5.1
<#
.SYNOPSIS
    StallScope report generator - turns idle-stalls.txt into a readable summary.

.DESCRIPTION
    Reads the log written by stallscope.ps1 and produces a Markdown report that
    classifies every stall, groups them, and points at the most likely cause.

    Classification rules
      PAGING      cvg >= 90 and pagesIn >= 500 and availMB < 2000
                  -> memory pressure forced the system to page to disk
      C-STATE     cvg < 50
                  -> only part of the machine was producing CPU time, which
                     usually means cores were parked or the window was spent
                     waiting on I/O rather than executing
      BUSY         one process accounted for most of the stall duration
                  -> that process was doing real work and starving others
      KERNEL       cvg >= 90, every process nearly idle
                  -> something in the kernel blocked the whole machine
      SHORT        any stall under 1000 ms that fits none of the above

.PARAMETER LogPath
    Path to idle-stalls.txt. Defaults to ..\logs\idle-stalls.txt

.PARAMETER OutPath
    Where to write the Markdown report. Defaults to a timestamped file next to
    the log.

.EXAMPLE
    .\report.ps1

.EXAMPLE
    .\report.ps1 -LogPath <your-folder>\idle-stalls.txt -OutPath <your-folder>\report.md
#>
[CmdletBinding()]
param(
    [string] $LogPath,
    [string] $OutPath
)

$ErrorActionPreference = 'Stop'

$InstallRoot = Split-Path -Parent $PSScriptRoot
if (-not $LogPath) { $LogPath = Join-Path (Join-Path $InstallRoot 'logs') 'idle-stalls.txt' }

if (-not (Test-Path $LogPath)) {
    Write-Host "Log not found: $LogPath" -ForegroundColor Red
    Write-Host "Run stallscope.ps1 first, or pass -LogPath explicitly."
    exit 1
}
if (-not $OutPath) {
    $dir = Split-Path -Parent $LogPath
    $OutPath = Join-Path $dir ("stallscope-report-{0}.md" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
}

$lines = Get-Content $LogPath -Encoding UTF8
$stalls = New-Object System.Collections.ArrayList
$starts = New-Object System.Collections.ArrayList
$beats  = 0

foreach ($raw in $lines) {
    $m = [regex]::Match($raw, '^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{3})\s+(STALL|STALL\+\+|FREEZE)\s+gap=\s*(\d+)ms\s+cpu=\s*(\d+)%\s+cvg=\s*(\d+)%.*?availMB=\s*(-?\d+).*?pagesIn=\s*(-?\d+)/s.*?diskQ=\s*(-?\d+)\s*\|\s*(.*)$')
    if ($m.Success) {
        # A second -match here would overwrite $Matches, so use a fresh Match object.
        $cpuText = $m.Groups[9].Value
        $inner = [regex]::Match($cpuText, '(.+?)#(\d+)=(\d+)ms')
        $topName = ''
        $topCpu = 0
        if ($inner.Success) {
            $topName = $inner.Groups[1].Value.Trim()
            $topCpu = [int]$inner.Groups[3].Value
        }
        [void]$stalls.Add([pscustomobject]@{
            Time    = [datetime]::ParseExact($m.Groups[1].Value, 'yyyy-MM-dd HH:mm:ss.fff', $null)
            Kind    = $m.Groups[2].Value
            Gap     = [int]$m.Groups[3].Value
            Cpu     = [int]$m.Groups[4].Value
            Cvg     = [int]$m.Groups[5].Value
            AvailMB = [int]$m.Groups[6].Value
            PagesIn = [int]$m.Groups[7].Value
            DiskQ   = [int]$m.Groups[8].Value
            TopName = $topName
            TopCpu  = $topCpu
        })
        continue
    }
    if ($raw -match 'STALLSCOPE START') { [void]$starts.Add($raw) }
    if ($raw -match 'alive #') { $beats++ }
}

if ($stalls.Count -eq 0) {
    Write-Host "No stall records found in $LogPath" -ForegroundColor Yellow
    Write-Host "That is good news: nothing exceeded the threshold while the monitor ran."
    exit 0
}

# ------------------------------------------------- classify -----------------
foreach ($s in $stalls) {
    $s | Add-Member -NotePropertyName Class -NotePropertyValue 'SHORT' -Force
    if ($s.TopCpu -ge ($s.Gap * 0.7)) {
        $s.Class = 'BUSY'
    } elseif ($s.Cvg -lt 50) {
        $s.Class = 'C-STATE'
    } elseif ($s.PagesIn -ge 500 -and $s.AvailMB -lt 2000 -and $s.Cvg -ge 90) {
        $s.Class = 'PAGING'
    } elseif ($s.Cvg -ge 90 -and $s.Cpu -le 15) {
        $s.Class = 'KERNEL'
    }
}

$groups = $stalls | Group-Object Class | Sort-Object Count -Descending
$first  = $stalls[0].Time
$last   = $stalls[-1].Time
$span   = ($last - $first).TotalMinutes
$rate = $stalls.Count
if ($span -gt 0) { $rate = [math]::Round($stalls.Count / $span, 1) }

$sb = New-Object System.Text.StringBuilder
function A { param($t) [void]$sb.AppendLine($t) }

A '# StallScope Report'
A ''
A ('Generated: {0}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
A ('Source log: `{0}`' -f (Split-Path -Leaf $LogPath))
A ''

A '## Summary'
A ''
A '| Item | Value |'
A '|---|---|'
A ('| Stalls recorded | **{0}** |' -f $stalls.Count)
A ('| First / last | {0:yyyy-MM-dd HH:mm:ss} / {1:HH:mm:ss} |' -f $first, $last)
A ('| Time span covered | {0:N0} minutes |' -f $span)
$everyMin = 0
if ($rate -gt 0) { $everyMin = 60 / $rate }
A ('| Rate | 1 stall every {0:N1} minutes |' -f $everyMin)
A ('| Heartbeats | {0} |' -f $beats)
if ($stalls.Count -gt 0) {
    $avgGap = [math]::Round(($stalls | Measure-Object Gap -Average).Average)
    $avgCvg = [math]::Round(($stalls | Measure-Object Cvg -Average).Average)
    A ('| Longest stall | {0} ms |' -f ($stalls | Measure-Object Gap -Maximum).Maximum)
    A ('| Average stall | {0} ms |' -f $avgGap)
    A ('| Average coverage (cvg) | {0}% |' -f $avgCvg)
}
A ''

A '## Breakdown by class'
A ''
A '| Class | Count | Share | Meaning |'
A '|---|---|---|---|'
$meaning = @{
    'PAGING'  = 'Memory pressure: the system was paging to disk'
    'C-STATE' = 'Part of the machine was not producing CPU time (parked cores or I/O wait)'
    'BUSY'    = 'One process consumed most of the stall window'
    'KERNEL'  = 'Whole machine blocked, every process idle (kernel or driver)'
    'SHORT'   = 'Short stall, no single dominant cause'
}
foreach ($g in $groups) {
    $pct = [math]::Round(100.0 * $g.Count / $stalls.Count, 0)
    A ('| {0} | {1} | {2}% | {3} |' -f $g.Name, $g.Count, $pct, $meaning[$g.Name])
}
A ''

A '## What this points to'
A ''
$dominant = $groups[0]
A ('The dominant class is **{0}** ({1} of {2} stalls).' -f $dominant.Name, $dominant.Count, $stalls.Count)
A ''
switch ($dominant.Name) {
    'PAGING' {
        A 'The machine is running out of physical memory and paging to disk.'
        A ''
        A 'Actions worth trying, cheapest first:'
        A ''
        A '1. Close programs you are not using right now (each browser or IDE window costs 100-400 MB).'
        A '2. Check for handle leaks: a process with more than ~5000 handles is suspicious.'
        A '3. Limit IDE heap size (IntelliJ: Help > Edit Custom VM Options, -Xmx2g).'
        A '4. Add RAM. This is the only permanent fix for genuine memory pressure.'
    }
    'C-STATE' {
        A 'Part of the CPU was not accumulating time during these stalls. That'
        A 'usually means cores were parked or the window was spent waiting rather than executing.'
        A ''
        A 'Actions worth trying:'
        A ''
        A '1. Run `scripts\dptf-test.cmd` to rule out Intel Dynamic Tuning.'
        A '2. Try `scripts\disable-idle-ac.cmd` (disables processor idle on AC only).'
        A '3. Check for periodic scheduled tasks with `Get-ScheduledTask`.'
    }
    'BUSY' {
        A 'A single process dominated the stall window. Scroll to the per-stall'
        A 'table below and look at the process names in the last column.'
        A ''
        A 'Actions worth trying:'
        A ''
        A '1. Reduce how many windows of that application are open.'
        A '2. Check its own logs for retry loops or re-indexing.'
        A '3. If it is an IDE, let indexing finish before judging.'
    }
    'KERNEL' {
        A 'Every process was idle yet the machine stopped responding. That points at'
        A 'a kernel-level block: a driver waiting on hardware, a power transition, or'
        A 'a stalled storage queue.'
        A ''
        A 'Actions worth trying:'
        A ''
        A '1. Check `diskQ` in the table below. A persistently high value points at storage.'
        A '2. Update chipset and storage drivers from the OEM.'
        A '3. Kernel-level tracing (WPR/PerfView) needs administrator rights and may be'
        A '   blocked by VBS; that is the next step if this class dominates.'
    }
    default {
        A 'No single cause dominates. Look at the per-stall table below.'
    }
}
A ''

A '## Per-stall detail'
A ''
A '| Time | Class | gap (ms) | cpu % | cvg % | availMB | pagesIn/s | diskQ | Busiest process |'
A '|---|---|---|---|---|---|---|---|---|'
foreach ($s in $stalls) {
    A ('| {0:HH:mm:ss} | {1} | {2} | {3} | {4} | {5} | {6} | {7} | {8} ({9} ms) |' -f `
        $s.Time, $s.Class, $s.Gap, $s.Cpu, $s.Cvg, $s.AvailMB, $s.PagesIn, $s.DiskQ, $s.TopName, $s.TopCpu)
}
A ''

A '## How to read the columns'
A ''
A '| Column | Meaning | Healthy |'
A '|---|---|---|'
A '| **gap** | How late the sampling loop ran; the stall length | under 300 ms |'
A '| **cpu** | Busy CPU percentage across the window | depends on load |'
A '| **cvg** | Recorded CPU time / (cores x gap); 100% means the measurement is trustworthy | 95-105% |'
A '| **availMB** | Free physical memory | above 2000 MB |'
A '| **pagesIn/s** | Pages read from disk per second; the real paging signal | under 100 |'
A '| **diskQ** | Disk queue length | under 3 |'
A ''

A '## Caveats'
A ''
A '- A low `cvg` does not by itself prove a problem: it means part of the machine was'
A '  not producing CPU time, which can be normal on a lightly loaded system.'
A '- Records only appear when a stall exceeds the threshold. A clean log with'
A '  heartbeats but no stalls is a passing result.'
A '- The monitor costs roughly 5-7% of one core while running.'
A ''

$sb.ToString() | Set-Content -Path $OutPath -Encoding UTF8
Write-Host ("Report written to: {0}" -f $OutPath) -ForegroundColor Green
Write-Host ("Stalls analysed: {0}" -f $stalls.Count)
foreach ($g in $groups) { Write-Host ("  {0}: {1}" -f $g.Name, $g.Count) }






