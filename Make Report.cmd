@echo off
chcp 65001 >nul
title StallScope - Make Report
rem =====================================================================
rem  Turns logs\idle-stalls.txt into a readable Markdown report.
rem
rem  No administrator rights needed.
rem
rem  HOW TO RUN: double-click, or run from a terminal.
rem =====================================================================

set "ROOT=%~dp0"
set "REPORT=%ROOT%bin\report.ps1"

echo ================================================
echo   StallScope - Make Report
echo ================================================
echo.

if not exist "%REPORT%" (
  echo [ERROR] bin\report.ps1 not found next to this file.
  goto FINISH
)

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%REPORT%"
if errorlevel 1 (
  echo.
  echo [WARN] report generation failed - see the message above.
) else (
  echo.
  echo The report is in the logs folder, named stallscope-report-*.md
  echo Open it with any text editor or a Markdown viewer.
)
echo.
goto FINISH

:FINISH
echo.
echo ---- press any key to close ----
pause >nul
