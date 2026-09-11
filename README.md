# Gameloop Uninstaller by KingStan

Removes GameLoop (Tencent's Android emulator for PC) completely: the program
itself plus every leftover - background helpers, settings, folders, icons
and temporary files. Old installs (TxGameAssistant / Tencent Gaming Buddy)
and new ones (Tencent\GameLoop / TenStore, 7.x) are both covered.

This is an unofficial community tool. It is not affiliated with Tencent.

## Files

- `Gameloop-Uninstaller.bat` - double-click this. Asks for administrator
  rights, then runs the script below.
- `Gameloop-Uninstaller.ps1` - does the actual work (PowerShell 5.1+).

## Usage

1. Close any game running inside GameLoop.
2. Right-click `Gameloop-Uninstaller.bat` and choose **Run as administrator**
   (it asks for permission by itself if you forget).
3. Type `YES` when asked, then sit back - it works through 7 steps.
4. Restart your PC when it suggests to - that unlocks files still in use.

Unattended options (pass them after the file name):

- `-Silent` - no questions, no pause at the end (for scripts).
- `-KeepGames` - keep `Documents\Tencent Files` (downloaded games).
- `-SkipOfficialUninstaller` - skip GameLoop's own uninstaller, force-clean only.
- `-NoRebootPrompt` - do not ask about restarting.
- `-WhatIf` - preview only: shows what WOULD happen, changes nothing.

Example:

    Gameloop-Uninstaller.bat -Silent -KeepGames

## What it does, step by step

0. **Safety backup** - exports the Tencent settings to `.reg` files first.
1. **Official uninstaller** - runs GameLoop's own `Uninstall.exe` /
   `TUninstall.exe` first (auto-detected, even on other drives).
2. **Running apps** - closes GameLoop processes only, plus anything running
   from a GameLoop folder. Your other programs stay open.
3. **Background helpers** - stops and removes GameLoop services and drivers
   (`GameLoopService`, `GLABoxSup`, `QMEmulatorService`, `aow_drv`, ...),
   including ones discovered automatically by install path.
4. **Permissions & auto-start** - removes GameLoop firewall permissions,
   scheduled tasks, Run entries and Startup shortcuts.
5. **Leftover settings** - removes GameLoop registry keys
   (`GameLoop`, `MobileGamePC`, `TGB`, uninstall entries, per-app icon cache
   values). Shared Tencent keys (QQ, WeChat, ...) are left alone.
6. **Leftover files** - removes GameLoop folders, desktop/Start-menu icons
   and temp files. Your documents and other apps are never touched.
7. **Double-check** - verifies the main GameLoop spots are empty.

A summary panel at the end shows everything that was cleaned, and a full
report is saved next to the scripts as `Gameloop-Uninstaller-<date>.log`.

## Safety notes

- Run as administrator is required (services and system folders).
- Nothing from QQ, WeChat or other Tencent apps is removed - parents are
  only deleted when completely empty, and the registry is backed up first
  (`%TEMP%\GameLoop-RegBackup`, restore with `reg import file.reg`).
- Shared system processes are never touched. Shared tools (`adb`,
  VirtualBox network helpers, QQ login) are only closed when running from
  a GameLoop folder.
- Never deletes whole Temp folders, whole `Tencent` folders, or system paths.
  Every deletion goes through a protected-path guard.

## Requirements

- Windows 10/11, PowerShell 5.1+ (built in), administrator rights.
