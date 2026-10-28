@echo off
rem Double-clickable wrapper for build-and-install.ps1.
rem Runs the script with execution-policy bypass so it works without changing any
rem machine-wide PowerShell settings, then pauses so the output can be read.
rem Any arguments given here are passed straight through, for example:
rem   build-and-install.cmd -Uninstall
rem   build-and-install.cmd -FrameworkDependent

setlocal

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0build-and-install.ps1" %*

set "RC=%ERRORLEVEL%"

echo.
if not "%RC%"=="0" echo FileUnlocker: the script exited with code %RC%.
echo Press any key to close this window . . .
pause >nul

rem "pause" resets ERRORLEVEL, and "endlocal" would drop RC, so both the closing of
rem the local scope and the exit code are done in one line: %RC% is expanded first.
endlocal & exit /b %RC%
