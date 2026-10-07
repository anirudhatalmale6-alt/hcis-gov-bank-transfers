@echo off
REM ============================================================
REM  HCIS - what does this machine already have?
REM
REM  READS ONLY. CHANGES NOTHING. Run it any time.
REM
REM  Run this on the GOV BOX while you are there. It answers the
REM  questions I need before building the job that emails Finance
REM  the payroll after the 29th - chiefly whether this machine can
REM  run Python.
REM
REM  That one answer decides whether the payroll calculation
REM  exists once or twice. Two copies of a payroll calculation
REM  drift apart eventually, and when they do the banks pay one
REM  figure while Finance is told another.
REM
REM  Takes about ten seconds. Send me a photo of the window.
REM ============================================================
setlocal
set HERE=%~dp0

if not exist "%HERE%check-this-box.ps1" (
  echo.
  echo   ERROR: check-this-box.ps1 is missing from this folder.
  echo.
  echo   This usually means the package is still inside the zip.
  echo   Right-click the zip, choose Extract All, and run it from
  echo   the folder that comes out.
  echo.
  pause
  exit /b 1
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%HERE%check-this-box.ps1" %*

echo.
pause
