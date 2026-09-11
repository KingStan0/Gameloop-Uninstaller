@echo off
setlocal EnableExtensions
title Gameloop Uninstaller - Launcher
color 0A

:: Gameloop-Uninstaller.bat
:: One-click launcher for Gameloop-Uninstaller.ps1 (2025-2026 GameLoop ready).
:: - Self-elevates to admin (required for services / HKLM / Program Files)
:: - Uses -ExecutionPolicy Bypass for this process only (no system change)
:: - Forwards all args to the .ps1, e.g.: Gameloop-Uninstaller.bat -Silent -KeepGames

cd /d "%~dp0"

set "SCRIPT=%~dp0Gameloop-Uninstaller.ps1"
set "PWSH=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if not exist "%PWSH%" set "PWSH=powershell"

if not exist "%SCRIPT%" (
    echo [ERROR] Could not find Gameloop-Uninstaller.ps1 next to this .bat:
    echo         "%SCRIPT%"
    echo Put both files in the same folder and try again.
    pause
    exit /b 1
)

:: Check admin; self-elevate if needed.
:: NOTE: elevation lives under :elevate (outside any parens) so folder
:: names containing ")" - e.g. C:\Users\Anna (Work)\... - cannot break it.
net session >nul 2>&1
if "%errorLevel%"=="0" goto :admin_ok
goto :elevate

:elevate
echo Requesting administrator rights...
echo A new window will open to continue. If Windows asks
echo for permission, please click Yes - the cleanup needs
echo it to remove system files properly.
:: Escape single quotes for PowerShell single-quoted strings (e.g. O'Brien -> O''Brien)
set "SELF=%~f0"
set "SELF=%SELF:'=''%"
if "%~1"=="" goto :elevate_noargs
set "ARGS=%*"
set "ARGS=%ARGS:'=''%"
"%PWSH%" -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath '%SELF%' -ArgumentList '%ARGS%' -Verb RunAs"
exit /b 0

:elevate_noargs
"%PWSH%" -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath '%SELF%' -Verb RunAs"
exit /b 0

:admin_ok

echo ======================================================
echo  GAMELOOP UNINSTALLER - one-click cleanup
echo ======================================================
echo Sit back - GameLoop is being removed step by step.
echo A full report is saved next to this file when done.
echo ------------------------------------------------------
echo Script: "%SCRIPT%"
echo Args  : %*
echo Log   : %~dp0Gameloop-Uninstaller-*.log
echo ------------------------------------------------------
echo.

"%PWSH%" -NoProfile -NoLogo -ExecutionPolicy Bypass -File "%SCRIPT%" %*

set "EXITCODE=%errorLevel%"
echo.
if "%EXITCODE%"=="0" (
    echo [OK] Finished successfully - exit code 0.
    echo See log in %~dp0Gameloop-Uninstaller-*.log
) else (
    echo [WARN] Finished with exit code %EXITCODE%. See log in %~dp0Gameloop-Uninstaller-*.log
)

:: Skip pause for automation (-Silent or /Silent), otherwise hold window open
echo "%*" | findstr /i "[-/]Silent" >nul 2>&1
if "%errorLevel%"=="0" (
    exit /b %EXITCODE%
)

pause
exit /b %EXITCODE%
