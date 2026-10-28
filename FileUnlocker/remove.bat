@echo off
setlocal
cd /d "%~dp0"

rem Removes the Explorer context menu entries for FileUnlocker.
rem
rem   remove.bat            removes the entries for the current user
rem   remove.bat /allusers  removes the entries for every user (needs an elevated prompt)
rem
rem Safe to run more than once. Deleting a key that is not there is reported as
rem nothing to do, not as an error.

set "ROOT=HKCU\Software\Classes"
set "SCOPE=the current user"

if /i "%~1"=="/allusers" goto allusers
if /i "%~1"=="-allusers" goto allusers
if not "%~1"=="" (
    echo FileUnlocker: error: unknown parameter '%~1'.
    echo Usage: remove.bat [/allusers]
    exit /b 1
)
goto have_scope

:allusers
set "ROOT=HKEY_CLASSES_ROOT"
set "SCOPE=all users"
rem Removing the machine-wide entries needs administrator rights. Refuse early:
rem without this check the deletes below would fail silently and the script would
rem still claim success.
net session >nul 2>&1
if errorlevel 1 (
    echo FileUnlocker: error: removing the entries for all users needs an elevated prompt.
    echo FileUnlocker: run remove.bat /allusers from a Command Prompt started as administrator,
    echo FileUnlocker: or run remove.bat without a parameter to remove the current user's entries.
    exit /b 1
)

:have_scope
set "FAILED=0"

rem Always try both scopes would be surprising; mirror exactly what install.bat wrote.
rem reg.exe reports a missing key with exit code 1 and the text below on stderr, and
rem reports an access failure with exit code 0 and different stderr text, so the
rem error text is the only reliable signal. A missing key is "nothing to do"; any
rem other failure is reported.
call :del "%ROOT%\*\shell\FileUnlocker"
call :del "%ROOT%\Directory\shell\FileUnlocker"
call :del "%ROOT%\Directory\Background\shell\FileUnlocker"

if exist "%TEMP%\FileUnlockerRemoveErr.txt" del /q "%TEMP%\FileUnlockerRemoveErr.txt" >nul 2>&1

if not "%FAILED%"=="0" (
    echo FileUnlocker: error: %FAILED% of the registry deletes failed for %SCOPE%.
    echo FileUnlocker: the entries may still be registered. Try running this from an elevated Command Prompt.
    exit /b 1
)

echo FileUnlocker: removed the context menu for %SCOPE%. It is safe to run this again.
exit /b 0

rem ---------------------------------------------------------------------------
rem del <key>
rem Deletes a key.
rem
rem reg.exe puts "The operation completed successfully." on stdout only when it
rem really deleted something, and puts every failure on stderr. A key that was not
rem there is therefore indistinguishable from an access failure by exit code alone
rem (both leave stdout empty, and an access failure still returns 0), so the error
rem text decides: "unable to find" is benign, anything else is a real failure.
rem ---------------------------------------------------------------------------
:del
set "OUTTEXT="
set "ERRFILE=%TEMP%\FileUnlockerRemoveErr.txt"
for /f "delims=" %%E in ('reg delete "%~1" /f 2^>"%ERRFILE%"') do set "OUTTEXT=%%E"
rem Empty stdout means nothing was deleted. That is fine for a key that was not
rem there, so only complain when reg.exe actually reported a problem.
if defined OUTTEXT goto :eof
if not exist "%ERRFILE%" goto :eof
for %%E in ("%ERRFILE%") do if %%~zE==0 goto :eof

rem A missing key is the expected case on a second run.
findstr /i /c:"unable to find" "%ERRFILE%" >nul 2>&1
if not errorlevel 1 goto :eof

set /a FAILED+=1
set "ERRTEXT="
for /f "usebackq delims=" %%E in ("%ERRFILE%") do if not defined ERRTEXT set "ERRTEXT=%%E"
echo FileUnlocker: error: could not delete "%~1": %ERRTEXT%
goto :eof
