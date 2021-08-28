cd /d %~dp0

@Reg Add "HKEY_CLASSES_ROOT\*\shell\FileUnlocker" /VE /D "Unlock" /F >Nul
@Reg Add "HKEY_CLASSES_ROOT\*\shell\FileUnlocker" /V "Icon" /D "\"%CD%\key.ico\"
@Reg Add "HKEY_CLASSES_ROOT\*\shell\FileUnlocker\command" /VE /D "\"%CD%\FileUnlocker.exe\" \"%%1\"" /F >Nul

@Reg Add "HKEY_CLASSES_ROOT\Directory\shell\FileUnlocker" /VE /D "Unlock" /F >Nul
@Reg Add "HKEY_CLASSES_ROOT\Directory\shell\FileUnlocker" /V "Icon" /D "\"%CD%\key.ico\"
@Reg Add "HKEY_CLASSES_ROOT\Directory\shell\FileUnlocker\command" /VE /D "\"%CD%\FileUnlocker.exe\" \"%%1\"" /F >Nul