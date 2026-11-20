@echo off
chcp 65001 >nul
title Disable processor idle - AC only
rem =====================================================================
rem  Sets "Processor idle disable" = 1 for the ACTIVE power scheme, on the
rem  AC (plugged-in) profile only. Battery behaviour is untouched.
rem
rem  WHY
rem    If stalls show a low cvg (well under 100%), part of the CPU was not
rem    producing CPU time. Keeping cores awake is the direct test of that
rem    theory. Running the experiment on AC only means battery life is not
rem    affected while you decide.
rem
rem  COST while on AC: slightly higher idle power and temperature; the fan
rem  may spin up more often. Nothing permanent, and revert-idle.cmd undoes it.
rem
rem  HOW TO RUN: right-click -> "Run as administrator"
rem =====================================================================

set "SID=5d76a2ca-e8c0-402f-a133-2158492d58ad"
set "OUT=%~dp0disable-idle.log"

whoami /groups 2>nul | findstr /C:"S-1-16-12288" >nul 2>&1
if errorlevel 1 goto NOADMIN

echo Disable processor idle (AC only)  %DATE% %TIME% > "%OUT%"

echo ================================================
echo   Processor idle disable = 1  (AC only)
echo ================================================
echo.

echo [1/4] BEFORE
powercfg /query SCHEME_CURRENT SUB_PROCESSOR %SID% >> "%OUT%" 2>&1
powercfg /query SCHEME_CURRENT SUB_PROCESSOR %SID% | findstr /C:"AC Power Setting Index" /C:"DC Power Setting Index"
echo.

echo [2/4] Making the setting visible ...
powercfg -attributes SUB_PROCESSOR %SID% -ATTRIB_HIDE >> "%OUT%" 2>&1

echo [3/4] AC = 1, DC stays 0 ...
powercfg /setacvalueindex SCHEME_CURRENT SUB_PROCESSOR %SID% 1 >> "%OUT%" 2>&1
powercfg /setdcvalueindex SCHEME_CURRENT SUB_PROCESSOR %SID% 0 >> "%OUT%" 2>&1
powercfg /setactive SCHEME_CURRENT >> "%OUT%" 2>&1

echo [4/4] AFTER
echo. >> "%OUT%"
echo ========== AFTER ========== >> "%OUT%"
powercfg /query SCHEME_CURRENT SUB_PROCESSOR %SID% >> "%OUT%" 2>&1
powercfg /query SCHEME_CURRENT SUB_PROCESSOR %SID%

echo.
echo ================================================
echo   Done - expected AC = 0x00000001, DC = 0x00000000
echo ================================================
echo.
echo Takes effect immediately, no reboot needed.
echo Run "Make Report.cmd" after a while and compare the C-STATE class counts.
echo Undo with: revert-idle.cmd
echo.
goto FINISH

:NOADMIN
echo [ERROR] Administrator rights required.
echo         Right-click this file and choose "Run as administrator".

:FINISH
echo.
echo ---- press any key to close ----
pause >nul
