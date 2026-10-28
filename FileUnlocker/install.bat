@echo off
setlocal
cd /d "%~dp0"

rem Registers the Explorer context menu entries for FileUnlocker.
rem
rem   install.bat            installs for the current user (no administrator needed)
rem   install.bat /allusers  installs for every user (needs an elevated prompt)
rem
rem The per-user entries live in HKCU\Software\Classes, which Windows merges into
rem HKEY_CLASSES_ROOT, the view Explorer reads. A non-elevated user cannot write
rem HKEY_CLASSES_ROOT directly, so the default is per-user.

set "ROOT=HKCU\Software\Classes"
set "SCOPE=the current user"
set "FAILED=0"
set "FAILNAMES="

if /i "%~1"=="/allusers" goto allusers
if /i "%~1"=="-allusers" goto allusers
if not "%~1"=="" goto usage
goto have_scope

:allusers
set "ROOT=HKEY_CLASSES_ROOT"
set "SCOPE=all users"
rem Writing to HKEY_CLASSES_ROOT needs administrator rights. Refuse early with a
rem clear message instead of writing half of the entries and failing quietly.
net session >nul 2>&1
if errorlevel 1 (
    echo FileUnlocker: error: installing for all users needs an elevated prompt.
    echo FileUnlocker: run install.bat /allusers from a Command Prompt started as administrator,
    echo FileUnlocker: or run install.bat without a parameter to install for the current user.
    exit /b 1
)
goto have_scope

:usage
echo FileUnlocker: error: unknown parameter '%~1'.
echo Usage: install.bat [/allusers]
exit /b 1

:have_scope
set "APP=%CD%\FileUnlocker.exe"
set "ICO=%CD%\key.ico"

if not exist "%APP%" (
    echo FileUnlocker: error: "%APP%" was not found. Run install.bat from the folder that contains FileUnlocker.exe.
    exit /b 1
)

if not exist "%ICO%" (
    echo FileUnlocker: note: "%ICO%" was not found. The menu entries are registered without an icon.
)

rem The command values are written inline, not through a subroutine: a subroutine
rem would expand %%1 against its own parameters and store an empty string.

reg add "%ROOT%\*\shell\FileUnlocker" /ve /d "Unlock" /f >nul 2>&1
if errorlevel 1 call :record "%ROOT%\*\shell\FileUnlocker"
reg add "%ROOT%\*\shell\FileUnlocker\command" /ve /d "\"%APP%\" \"%%1\"" /f >nul 2>&1
if errorlevel 1 call :record "%ROOT%\*\shell\FileUnlocker\command"
reg add "%ROOT%\*\shell\FileUnlocker" /v "Icon" /d "%ICO%" /f >nul 2>&1
if errorlevel 1 call :record "%ROOT%\*\shell\FileUnlocker (Icon)"
reg add "%ROOT%\*\shell\FileUnlocker" /v "MultiSelectModel" /d "Single" /f >nul 2>&1
if errorlevel 1 call :record "%ROOT%\*\shell\FileUnlocker (MultiSelectModel)"

reg add "%ROOT%\Directory\shell\FileUnlocker" /ve /d "Unlock" /f >nul 2>&1
if errorlevel 1 call :record "%ROOT%\Directory\shell\FileUnlocker"
reg add "%ROOT%\Directory\shell\FileUnlocker\command" /ve /d "\"%APP%\" \"%%1\"" /f >nul 2>&1
if errorlevel 1 call :record "%ROOT%\Directory\shell\FileUnlocker\command"
reg add "%ROOT%\Directory\shell\FileUnlocker" /v "Icon" /d "%ICO%" /f >nul 2>&1
if errorlevel 1 call :record "%ROOT%\Directory\shell\FileUnlocker (Icon)"

reg add "%ROOT%\Directory\Background\shell\FileUnlocker" /ve /d "Unlock" /f >nul 2>&1
if errorlevel 1 call :record "%ROOT%\Directory\Background\shell\FileUnlocker"
reg add "%ROOT%\Directory\Background\shell\FileUnlocker\command" /ve /d "\"%APP%\" \"%%V\"" /f >nul 2>&1
if errorlevel 1 call :record "%ROOT%\Directory\Background\shell\FileUnlocker\command"
reg add "%ROOT%\Directory\Background\shell\FileUnlocker" /v "Icon" /d "%ICO%" /f >nul 2>&1
if errorlevel 1 call :record "%ROOT%\Directory\Background\shell\FileUnlocker (Icon)"

if not "%FAILED%"=="0" goto failure

echo FileUnlocker: registered the context menu for %SCOPE%.
echo FileUnlocker: right-click a file or a folder to use it. Run remove.bat to unregister.
exit /b 0

:failure
echo FileUnlocker: error: %FAILED% of the registry commands failed for %SCOPE%.
echo FileUnlocker: failed keys: %FAILNAMES%
echo FileUnlocker: try running install.bat from an elevated Command Prompt to install for every user.
exit /b 1

:record
set /a FAILED+=1
set "FAILNAMES=%FAILNAMES% %~1"
goto :eof
