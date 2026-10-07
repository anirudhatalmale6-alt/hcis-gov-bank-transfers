@echo off
REM ============================================================
REM  HCIS - install the bank transfer work on this box
REM
REM  DOUBLE-CLICK THIS ONE, then STEP-2-reload-api.bat.
REM
REM  It adds:
REM    - where each care giver is paid (bank, account, account holder)
REM    - what the transfer file calls each bank
REM    - a record of what was actually sent to the banks
REM    - a history of every change to an account
REM    - the Bank Transfers screen in the Payroll menu
REM
REM  It backs up first and refuses to go on without one. Safe to
REM  run twice. It does NOT touch config.js - that file is this
REM  server's own settings and stays exactly where it is.
REM
REM  It does NOT install the job that emails Finance. That runs on
REM  the office server as a scheduled Linux task and has to be
REM  rebuilt for Windows - separate piece of work.
REM ============================================================
setlocal
set HERE=%~dp0

if not exist "%HERE%install-bank-transfers.ps1" (
  echo.
  echo   ERROR: install-bank-transfers.ps1 is missing from this folder.
  echo.
  echo   This usually means the package is still inside the zip.
  echo   Right-click the zip, choose Extract All, and run it from
  echo   the folder that comes out.
  echo.
  pause
  exit /b 1
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%HERE%install-bank-transfers.ps1" %*

echo.
pause
