@echo off
chcp 65001 >nul
title DPTF Test - stop Intel Dynamic Tuning for 10 minutes
rem =====================================================================
rem  Rules out Intel DPTF (Dynamic Platform and Thermal Framework) as the
rem  cause of periodic stalls.
rem
rem  WHY THIS TEST
rem    DPTF re-evaluates the CPU power budget on a timer. If stalls land on
rem    a fixed cycle (for example exactly every 5 minutes), stopping DPTF for
rem    a short window and comparing the stall log is the cheapest way to
rem    confirm or eliminate it.
rem
rem  WHAT IT DOES
rem    1. stops the dptftcs service for 10 minutes
rem    2. leaves the ipf_* kernel drivers loaded (they cannot be unloaded
rem       safely; the service is the supported control point)
rem    3. restarts the service automatically when the timer ends
rem    4. writes a timeline so the stall log can be matched against it
rem
rem  RISK: while stopped, thermal and fan tuning is less adaptive. Ten minutes
rem  on AC power is safe. If you close the window early the service stays
rem  stopped - restart it from services.msc or run this file again.
rem
rem  HOW TO RUN: right-click -> "Run as administrator"
rem =====================================================================

set "ME=%~dp0"
set "LOG=%ME%dptf-test.log"

whoami /groups 2>nul | findstr /C:"S-1-16-12288" >nul 2>&1
if errorlevel 1 goto NOADMIN

sc query dptftcs 2>&1 | findstr /C:"SERVICE_NAME" >nul
if errorlevel 1 (
  echo This system has no dptftcs service - Intel DPTF is not installed,
  echo so there is nothing to test here.
  goto FINISH
)

echo ================================================
echo   DPTF test - stop Intel Dynamic Tuning
echo ================================================
echo.

echo === before === > "%LOG%"
echo %DATE% %TIME% >> "%LOG%"
sc query dptftcs >> "%LOG%" 2>&1
echo %DATE% %TIME%  STOP dptftcs >> "%LOG%"

echo [1/4] Stopping dptftcs ...
sc stop dptftcs
echo.

echo [2/4] Measuring for 10 minutes - use the computer normally.
echo       Start: %TIME%
echo.
timeout /t 300 /nobreak >nul
echo       ... 5 minutes elapsed.
echo %DATE% %TIME%  checkpoint 5min >> "%LOG%"
timeout /t 300 /nobreak >nul
echo       ... 10 minutes elapsed.
echo %DATE% %TIME%  checkpoint 10min >> "%LOG%"
echo.

echo [3/4] Restarting dptftcs ...
sc start dptftcs
echo %DATE% %TIME%  START dptftcs >> "%LOG%"
echo.

echo [4/4] Verifying ...
sc query dptftcs
echo. >> "%LOG%"
echo === after === >> "%LOG%"
echo %DATE% %TIME% >> "%LOG%"
sc query dptftcs >> "%LOG%" 2>&1

echo.
echo ================================================
echo   Done - service restored
echo ================================================
echo.
echo Timeline: %LOG%
echo Compare it against the stall log, then run "Make Report.cmd".
echo.
goto FINISH

:NOADMIN
echo [ERROR] Administrator rights required.
echo         Right-click this file and choose "Run as administrator".

:FINISH
echo.
echo ---- press any key to close ----
pause >nul
