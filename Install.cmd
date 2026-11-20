@echo off
chcp 65001 >nul
title StallScope - Install
rem =====================================================================
rem  Installs StallScope's scheduled task so monitoring starts at every
rem  logon and restarts within 1 minute if it ever stops.
rem
rem  Does NOT copy files anywhere: StallScope runs from this folder.
rem  Move the whole folder first if you want it elsewhere, then run this.
rem
rem  HOW TO RUN: right-click -> "Run as administrator"
rem =====================================================================

set "ROOT=%~dp0"
set "SCRIPT=%ROOT%bin\stallscope.ps1"
set "LOGDIR=%ROOT%logs"
set "TASK=StallScope"

whoami /groups 2>nul | findstr /C:"S-1-16-12288" >nul 2>&1
if errorlevel 1 goto NOADMIN

echo ================================================
echo   StallScope - Install
echo ================================================
echo.

if not exist "%SCRIPT%" (
  echo [ERROR] bin\stallscope.ps1 not found next to this file.
  goto FINISH
)
if not exist "%LOGDIR%" mkdir "%LOGDIR%"

echo Install folder : %ROOT%
echo Log folder     : %LOGDIR%
echo.

echo [1/3] Removing any previous StallScope task ...
schtasks /Query /TN "%TASK%" >nul 2>&1
if not errorlevel 1 (
  schtasks /Delete /TN "%TASK%" /F >nul 2>&1
  echo       previous task removed
) else (
  echo       none present
)
echo.

echo [2/3] Registering task at logon ...
schtasks /Create /TN "%TASK%" ^
  /TR "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File \"%SCRIPT%\" -Quiet" ^
  /SC ONLOGON /RL HIGHEST /F >nul 2>&1

if errorlevel 1 (
  echo       [ERROR] registration failed
  goto FINISH
)
echo       task "%TASK%" created
echo.

echo [3/3] Starting it now ...
schtasks /Run /TN "%TASK%" >nul 2>&1
timeout /t 4 /nobreak >nul

powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Start-Sleep -Seconds 2; $f = '%LOGDIR%\idle-stalls.txt'; if (Test-Path $f) { $m = (Get-Item $f).LastWriteTime; if (((Get-Date) - $m).TotalSeconds -lt 60) { Write-Host '      running - log is being written' } else { Write-Host '      [WARN] log not updated recently' } } else { Write-Host '      [WARN] log file not created yet - give it a moment' }"
echo.

echo ================================================
echo   Installed
echo ================================================
echo.
echo Log      : %LOGDIR%\idle-stalls.txt
echo Report   : run "Make Report.cmd"
echo Uninstall: run "Uninstall.cmd"
echo.
goto FINISH

:NOADMIN
echo [ERROR] Administrator rights required.
echo         Right-click this file and choose "Run as administrator".

:FINISH
echo.
echo ---- press any key to close ----
pause >nul
