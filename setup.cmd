@echo off
rem Launcher for setup.ps1: checks for PowerShell 7, then runs the setup with any arguments you pass.
where pwsh >nul 2>nul
if errorlevel 1 (
  echo PowerShell 7 is required but wasn't found.
  echo Install it with:  winget install --id Microsoft.PowerShell
  echo Then open a new terminal and run setup.cmd again.
  exit /b 1
)
pwsh -NoProfile -ExecutionPolicy Bypass -File "%~dp0setup.ps1" %*
exit /b %errorlevel%
