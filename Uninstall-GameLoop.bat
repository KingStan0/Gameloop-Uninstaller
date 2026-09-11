@echo off
setlocal EnableExtensions
title GameLoop Complete Uninstall - Launcher
color 0A

:: Uninstall-GameLoop.bat
:: One-click launcher for Uninstall-GameLoop.ps1 (2025-2026 GameLoop ready).
:: - Self-elevates to admin (required for services / HKLM / Program Files)
:: - Uses -ExecutionPolicy Bypass for this process only (no system change)
:: - Forwards all args to the .ps1, e.g.: Uninstall-GameLoop.bat -Silent -KeepGames

cd /d "%~dp0"

set "SCRIPT=%~dp0Uninstall-GameLoop.ps1"
set "PWSH=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if not exist "%PWSH%" set "PWSH=powershell"

if not exist "%SCRIPT%" (
    echo [ERROR] Could not find Uninstall-GameLoop.ps1 next to this .bat:
    echo         "%SCRIPT%"
    echo Put both files in the same folder and try again.
    pause
    exit /b 1
)

:: Check admin; self-elevate if needed
net session >nul 2>&1
if not "%errorLevel%"=="0" (
    echo Requesting administrator rights...
    echo A new elevated window will open to continue the uninstall.
    :: Escape single quotes for PowerShell single-quoted strings (e.g. O'Brien -> O''Brien)
    set "SELF=%~f0"
    set "SELF=%SELF:'=''%"
    if "%~1"=="" (
        "%PWSH%" -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath '%SELF%' -Verb RunAs"
    ) else (
        set "ARGS=%*"
        set "ARGS=%ARGS:'=''%"
        "%PWSH%" -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath '%SELF%' -ArgumentList '%ARGS%' -Verb RunAs"
    )
    exit /b 0
)

echo Launching GameLoop uninstaller...
echo Script: "%SCRIPT%"
echo Args  : %*
echo Log   : %~dp0GameLoop-Uninstall-*.log
echo.

"%PWSH%" -NoProfile -NoLogo -ExecutionPolicy Bypass -File "%SCRIPT%" %*

set "EXITCODE=%errorLevel%"
echo.
if "%EXITCODE%"=="0" (
    echo [OK] Finished successfully - exit code 0.
    echo See log in %~dp0GameLoop-Uninstall-*.log
) else (
    echo [WARN] Finished with exit code %EXITCODE%. See log in %~dp0GameLoop-Uninstall-*.log
)

:: Skip pause for automation (-Silent or /Silent), otherwise hold window open
echo "%*" | findstr /i "[-/]Silent" >nul 2>&1
if "%errorLevel%"=="0" (
    exit /b %EXITCODE%
)

pause
exit /b %EXITCODE%
