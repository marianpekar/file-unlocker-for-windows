cd /d %~dp0

@Reg Delete "HKEY_CLASSES_ROOT\*\shell\FileUnlocker" /F >Nul
@Reg Delete "HKEY_CLASSES_ROOT\Directory\shell\FileUnlocker" /F >Nul