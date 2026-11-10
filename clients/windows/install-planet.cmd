@echo off
rem install-planet.cmd - Windows wrapper for install-planet.ps1 (double-click friendly)
setlocal
set "PS1=%~dp0install-planet.ps1"
if not exist "%PS1%" (
    echo [FAIL] install-planet.ps1 not found next to this wrapper
    exit /b 1
)
if "%~1"=="" (
    echo Usage: install-planet.cmd -ServerUrl ^<URL^> [-Token ^<TOKEN^>] [-Sha256 ^<HEX^>] [-SkipRestart]
    echo Example: install-planet.cmd -ServerUrl https://zt.example.com -Token abc123
    exit /b 2
)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%PS1%" %*
set "RC=%ERRORLEVEL%"
endlocal & exit /b %RC%
