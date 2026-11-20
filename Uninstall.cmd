@echo off
chcp 65001 >nul
title StallScope - Uninstall
rem =====================================================================
rem  Removes StallScope's scheduled task and stops the monitor.
rem
rem  Logs are KEPT. Delete the logs folder yourself if you want them gone.
rem
rem  HOW TO RUN: right-click -> "Run as administrator"
rem =====================================================================

set "ROOT=%~dp0"
set "LOGDIR=%ROOT%logs"
set "TASK=StallScope"

whoami /groups 2>nul | findstr /C:"S-1-16-12288" >nul 2>&1
if errorlevel 1 goto NOADMIN

echo ================================================
echo   StallScope - Uninstall
echo ================================================
echo.

echo [1/3] Removing scheduled task ...
schtasks /Query /TN "%TASK%" >nul 2>&1
if errorlevel 1 (
  echo       task not present
) else (
  schtasks /End /TN "%TASK%" >nul 2>&1
  schtasks /Delete /TN "%TASK%" /F >nul 2>&1
  if errorlevel 1 ( echo       [WARN] delete failed ) else ( echo       task removed )
)
echo.

echo [2/3] Stopping monitor processes in this folder ...
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$root = '%ROOT%'; $n = @(Get-CimInstance Win32_Process -Filter \"Name='powershell.exe'\" | Where-Object { $_.CommandLine -like ('*' + $root + '*') -and $_.CommandLine -match 'stallscope\.ps1' }); if ($n.Count -eq 0) { Write-Host '      none running' } else { $n | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue; Write-Host ('      stopped PID=' + $_.ProcessId) } }"
echo.

echo [3/3] Clearing lock file ...
if exist "%LOGDIR%\.stallscope.lock" del /q "%LOGDIR%\.stallscope.lock" >nul 2>&1
echo       done
echo.

echo ================================================
echo   Done
echo ================================================
echo.
echo Logs kept at: %LOGDIR%
echo To reinstall: run "Install.cmd"
echo.
goto FINISH

:NOADMIN
echo [ERROR] Administrator rights required.
echo         Right-click this file and choose "Run as administrator".

:FINISH
echo.
echo ---- press any key to close ----
pause >nul
