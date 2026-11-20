@echo off
chcp 65001 >nul
title Revert processor idle
rem =====================================================================
rem  Undoes disable-idle-ac.cmd: sets "Processor idle disable" back to 0 for
rem  both AC and DC, restoring normal CPU idle behaviour.
rem
rem  HOW TO RUN: right-click -> "Run as administrator"
rem =====================================================================

set "SID=5d76a2ca-e8c0-402f-a133-2158492d58ad"
set "OUT=%~dp0revert-idle.log"

whoami /groups 2>nul | findstr /C:"S-1-16-12288" >nul 2>&1
if errorlevel 1 goto NOADMIN

echo Revert processor idle  %DATE% %TIME% > "%OUT%"

echo ================================================
echo   Revert: processor idle disable = 0
echo ================================================
echo.

echo [1/3] BEFORE
powercfg /query SCHEME_CURRENT SUB_PROCESSOR %SID% >> "%OUT%" 2>&1
powercfg /query SCHEME_CURRENT SUB_PROCESSOR %SID% | findstr /C:"AC Power Setting Index" /C:"DC Power Setting Index"
echo.

echo [2/3] Setting AC and DC back to 0 ...
powercfg /setacvalueindex SCHEME_CURRENT SUB_PROCESSOR %SID% 0 >> "%OUT%" 2>&1
powercfg /setdcvalueindex SCHEME_CURRENT SUB_PROCESSOR %SID% 0 >> "%OUT%" 2>&1
powercfg /setactive SCHEME_CURRENT >> "%OUT%" 2>&1

echo [3/3] AFTER
echo. >> "%OUT%"
echo ========== AFTER ========== >> "%OUT%"
powercfg /query SCHEME_CURRENT SUB_PROCESSOR %SID% >> "%OUT%" 2>&1
powercfg /query SCHEME_CURRENT SUB_PROCESSOR %SID%

echo.
echo ================================================
echo   Done - expected AC = 0x00000000, DC = 0x00000000
echo ================================================
echo.
goto FINISH

:NOADMIN
echo [ERROR] Administrator rights required.
echo         Right-click this file and choose "Run as administrator".

:FINISH
echo.
echo ---- press any key to close ----
pause >nul
