#Requires -Version 5.1
<#
.SYNOPSIS
    Completely uninstalls GameLoop / Tencent Gaming Buddy (old TxGameAssistant + new Tencent\GameLoop / TenStore).

.DESCRIPTION
    Updated for 2025-2026 GameLoop (7.0.19.x, Hong Kong Gathering Media Limited / TenStore Android Connect).
    1. Runs official uninstallers first (Settings-equivalent, no leftover-risky force-delete only)
    2. Stops GameLoop-only processes and services (GameLoopService, GLABoxSup, QMEmulatorService, aow_drv)
    3. Removes firewall rules + scheduled tasks for GameLoop
    4. Removes targeted Tencent/GameLoop registry keys (backed up first)
    5. Removes GameLoop folders, shortcuts, and GameLoop-only temp files

    SAFETY: never kills Windows processes (RuntimeBroker, Synaptics, conime),
    never wipes whole C:\Temp / %TEMP% / MuiCache, never uses hardcoded SIDs.

.PARAMETER Silent
    Skip confirmation prompt and reboot prompt (fully unattended).

.PARAMETER KeepGames
    Keep ~/Documents/Tencent Files (game downloads / screenshots).

.PARAMETER SkipOfficialUninstaller
    Skip official Uninstall.exe / TUninstall.exe step (force-cleanup only).

.PARAMETER NoRebootPrompt
    Do not prompt for reboot at the end.

.EXAMPLE
    .\Gameloop-Uninstaller.ps1
    .\Gameloop-Uninstaller.ps1 -Silent
    .\Gameloop-Uninstaller.ps1 -Silent -KeepGames
    .\Gameloop-Uninstaller.ps1 -WhatIf
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [switch]$Silent,
    [switch]$KeepGames,
    [switch]$SkipOfficialUninstaller,
    [switch]$NoRebootPrompt
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'

# Custom install locations discovered in Step 1 (e.g. D:\Games\GameLoop)
$script:CustomInstallPaths = @()

# Temp base with fallback (SYSTEM account may lack $env:TEMP)
$script:TempBase = if (-not [string]::IsNullOrWhiteSpace($env:TEMP)) { $env:TEMP } else { [System.IO.Path]::GetTempPath() }

# Accent color for headers (change in one place to re-theme)
$script:Accent = 'Cyan'

# Live counters for the end-of-run summary panel
$script:Stats = [ordered]@{
    Processes = 0; Services = 0; Firewall = 0; Tasks = 0; Startup = 0
    RegKeys = 0; RegValues = 0; Folders = 0; Shortcuts = 0; Temp = 0
}
function Add-Stat {
    param([string]$Name)
    if ($script:Stats.Contains($Name)) { $script:Stats[$Name]++ }
}

# ---------- Helpers ----------
function Write-Step {
    param([string]$Message)
    Write-Host ""
    if ($Message -match '^Step (\d+/\d+)\s*-\s*(.*)$') {
        Write-Host ("  [{0}] " -f $Matches[1]) -ForegroundColor $script:Accent -NoNewline
        Write-Host $Matches[2] -ForegroundColor White
    } else {
        Write-Host ("  -- {0} --" -f $Message) -ForegroundColor $script:Accent
    }
}

function Write-Ok {
    param([string]$Message)
    Write-Host "  [+] " -ForegroundColor Green -NoNewline
    Write-Host $Message
}

function Write-Skip {
    param([string]$Message)
    Write-Host "  [-] $Message" -ForegroundColor DarkGray
}

function Write-Found {
    param([string]$Message)
    Write-Host "  [>] $Message" -ForegroundColor Gray
}

function Write-Detail {
    param([string]$Message)
    Write-Host "      $Message" -ForegroundColor DarkGray
}

function Test-IsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p = New-Object Security.Principal.WindowsPrincipal($id)
    return $p.IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)
}

function Stop-GameLoopProcess {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param([string[]]$Names)
    # Processes that exist outside GameLoop too - only kill when the exe lives
    # under a GameLoop / TxGameAssistant folder. Everything else is GameLoop-only.
    $pathScoped = @('adb', 'VBoxNetDHCP', 'VBoxNetNAT', 'vbox-img', 'qqlogin')
    foreach ($name in $Names) {
        try {
            $base = $name -replace '\.exe$', ''
            $procs = Get-Process -Name $base -ErrorAction SilentlyContinue
            foreach ($pr in $procs) {
                if ($pathScoped -contains $pr.ProcessName) {
                    $exePath = ''
                    try { $exePath = $pr.Path } catch {}
                    if ([string]::IsNullOrWhiteSpace($exePath)) {
                        try { $exePath = (Get-CimInstance Win32_Process -Filter ("ProcessId={0}" -f $pr.Id) -ErrorAction SilentlyContinue | Select-Object -ExpandProperty ExecutablePath) } catch {}
                    }
                    if ($exePath -notmatch 'GameLoop|TxGameAssistant|Tencent') {
                        Write-Skip "$($pr.ProcessName) belongs to another program - left running"
                        continue
                    }
                }
                if ($PSCmdlet.ShouldProcess("$($pr.ProcessName) (PID $($pr.Id))", "Stop-Process")) {
                    try { Stop-Process -Id $pr.Id -Force -ErrorAction Stop; Write-Ok "closed $($pr.ProcessName) ($($pr.Id))"; Add-Stat 'Processes' }
                    catch { Write-Warning "  Could not kill $($pr.ProcessName): $_" }
                }
            }
        } catch { Write-Warning "  process lookup failed for $name : $_" }
    }
}

function Remove-PathSafe {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param([string]$Path, [string]$Stat = 'Paths', [switch]$Trusted)
    if ([string]::IsNullOrWhiteSpace($Path)) { return }
    # Expand env vars, keep as literal
    $expanded = [Environment]::ExpandEnvironmentVariables($Path).Trim().TrimEnd('\')
    # Defense-in-depth: block only exact dangerous roots (not every subfolder).
    # Quoted "$env:..." so missing variables (e.g. ProgramFiles(x86) on 32-bit) become "" instead of crashing.
    $lower = "$expanded".ToLowerInvariant()
    $dangerous = @(
        "$env:SystemRoot".ToLowerInvariant(),
        "$env:ProgramFiles".ToLowerInvariant(),
        "${env:ProgramFiles(x86)}".ToLowerInvariant(),
        "$env:ProgramData".ToLowerInvariant(),
        "$env:USERPROFILE".ToLowerInvariant(),
        "$env:APPDATA".ToLowerInvariant(),
        "$env:LOCALAPPDATA".ToLowerInvariant()
    )
    foreach ($d in $dangerous) {
        if (-not [string]::IsNullOrWhiteSpace($d) -and $lower -eq $d) {
            Write-Warning "  Refused to delete protected root: $expanded"
            return
        }
    }
    if ($expanded -match '^[A-Z]:\\?$') {
        Write-Warning "  Refused to delete protected path: $expanded"
        return
    }
    # Block Windows except GameLoop-only temp under Windows\Temp.
    # Trusted paths (explicitly registered by GameLoop's own installer) may use
    # any Windows\Temp subfolder - Temp is scratch space by design. Anything
    # else under Windows (System32, WinSxS, ...) is always refused.
    if ($expanded -match '^[A-Z]:\\Windows([\\/]|$)') {
        $gameTemp = $expanded -match '\\Temp\\(Tencent|GameLoop|TxGameAssistant)([\\/]|$)'
        $anySysTemp = $expanded -match '\\Temp\\[^\\/]+([\\/]|$)'
        if ($gameTemp -or ($Trusted -and $anySysTemp)) {
            # Allowed: GameLoop temp, or installer-registered Temp subfolder.
        } else {
            Write-Warning "  Refused to delete protected path: $expanded"
            return
        }
    }
    # Very short paths can only be drive roots (custom installs like E:\GameLoop are longer).
    if ($expanded.Length -lt 6) {
        Write-Warning "  Refused to delete suspiciously short path: $expanded"
        return
    }
    if (Test-Path -LiteralPath $expanded -ErrorAction SilentlyContinue) {
        if ($PSCmdlet.ShouldProcess($expanded, "Remove-Item -Recurse -Force")) {
            try {
                Remove-Item -LiteralPath $expanded -Recurse -Force -ErrorAction Stop
                Write-Ok "removed: $expanded"
                if ($script:Stats.Contains($Stat)) { Add-Stat $Stat }
            } catch { Write-Warning "  Could not remove $expanded : $_" }
        }
    }
}

function Remove-RegKeySafe {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return }
    # Defense-in-depth: refuse hive roots only (HKCU:\, HKLM:\SOFTWARE, ...).
    # HKCR:\GameLoop has 2 segments and is valid - allow depth >= 2.
    $segments = @($Path -split '[\\/]').Where({ -not [string]::IsNullOrWhiteSpace($_) -and $_ -ne ':' })
    if ($segments.Count -lt 2) {
        Write-Warning "  Refused to delete shallow registry path: $Path"
        return
    }
    if (Test-Path -LiteralPath $Path -ErrorAction SilentlyContinue) {
        if ($PSCmdlet.ShouldProcess($Path, "Remove registry key")) {
            try { Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop; Write-Ok "removed leftover setting: $Path"; Add-Stat 'RegKeys' }
            catch { Write-Warning "  Could not remove reg $Path : $_" }
        }
    }
}

# ---------- 0. Preflight ----------
# Logs go next to the script; fall back to TEMP if the script folder is read-only.
$script:LogDir = $script:TempBase
if (-not [string]::IsNullOrWhiteSpace($PSScriptRoot)) {
    if ($WhatIfPreference) {
        $script:LogDir = $PSScriptRoot
    } else {
        try {
            $probe = Join-Path $PSScriptRoot (".writetest-{0}.tmp" -f ([Guid]::NewGuid().ToString("N")))
            [System.IO.File]::WriteAllText($probe, "test")
            Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue -WhatIf:$false
            $script:LogDir = $PSScriptRoot
        } catch { $script:LogDir = $script:TempBase }
    }
}
$logFile = Join-Path $script:LogDir ("Gameloop-Uninstaller-{0:yyyyMMdd-HHmmss}.log" -f (Get-Date))
if (-not $WhatIfPreference) {
    try { Start-Transcript -Path $logFile -Append -ErrorAction SilentlyContinue | Out-Null } catch {}
}

Write-Host "  +------------------------------------------------------+" -ForegroundColor Green
Write-Host "  |  GAMELOOP UNINSTALLER BY KingStan                    |" -ForegroundColor Green
Write-Host "  |  Removes GameLoop completely, step by step             |" -ForegroundColor Gray
Write-Host "  +------------------------------------------------------+" -ForegroundColor Green
Write-Host "      This tool closes GameLoop, removes its background" -ForegroundColor DarkGray
Write-Host "      helpers, settings and leftover files - and nothing" -ForegroundColor DarkGray
Write-Host "      else. Your documents, photos and other apps are" -ForegroundColor DarkGray
Write-Host "      never touched. Everything it does is written to" -ForegroundColor DarkGray
Write-Host "      the log file below, so you can always see what" -ForegroundColor DarkGray
Write-Host "      happened afterwards." -ForegroundColor DarkGray
$gamesNote = if ($KeepGames) { 'ON (downloaded games are kept)' } else { 'OFF (everything GameLoop goes)' }
Write-Host ("  Log      : {0}" -f $logFile) -ForegroundColor DarkGray
Write-Host ("  Started  : {0:yyyy-MM-dd HH:mm:ss}" -f (Get-Date)) -ForegroundColor DarkGray
Write-Host ("  Mode     : {0}" -f $(if ($Silent) { 'Automatic (no questions asked)' } else { 'Guided (asks before doing anything)' })) -ForegroundColor DarkGray
Write-Host ("  KeepGames: {0}" -f $gamesNote) -ForegroundColor DarkGray
$script:Stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

if (-not (Test-IsAdmin) -and -not $WhatIfPreference) {
    Write-Error "Please run as Administrator (right-click Gameloop-Uninstaller.bat -> Run as administrator). Aborting."
    try { Stop-Transcript | Out-Null } catch {}
    exit 1
}

if (-not $Silent -and -not $WhatIfPreference) {
    Write-Host ""
    Write-Host "  Before we start:" -ForegroundColor White
    Write-Host "    - Close any game running inside GameLoop." -ForegroundColor Gray
    Write-Host "    - This only removes GameLoop and Tencent emulator leftovers." -ForegroundColor Gray
    Write-Host "    - When it is done, restarting your PC finishes the job." -ForegroundColor Gray
    Write-Host ""
    $ans = Read-Host "  Type YES in capital letters to start the cleanup"
    if ([string]::IsNullOrWhiteSpace($ans) -or $ans.Trim() -ne "YES") { Write-Host "  No problem - nothing was changed. Bye!"; try { Stop-Transcript | Out-Null } catch {}; exit 0 }
}

# Registry backup
Write-Step "Safety backup first"
Write-Detail "We save a copy of the GameLoop settings before touching"
Write-Detail "anything, so nothing is lost forever."
$backupDir = Join-Path $script:TempBase "GameLoop-RegBackup"
if ($PSCmdlet.ShouldProcess($backupDir, "Create backup dir")) {
    try { New-Item -ItemType Directory -Path $backupDir -Force -ErrorAction Stop | Out-Null }
    catch { Write-Warning "  Could not create backup dir $backupDir : $_" }
}
foreach ($key in @("HKCU\Software\Tencent", "HKLM\SOFTWARE\Tencent", "HKLM\SOFTWARE\WOW6432Node\Tencent")) {
    $out = Join-Path $backupDir (($key -replace '[^A-Za-z0-9]+','_') + ".reg")
    try {
        if ($PSCmdlet.ShouldProcess($key, "reg export to $out")) {
            # Skip missing keys silently (no reg.exe ERROR noise in the log)
            $psKey = $key -replace '^HKCU\\', 'HKCU:\' -replace '^HKLM\\', 'HKLM:\'
            if (-not (Test-Path -LiteralPath $psKey)) {
                Write-Skip "backup skipped (key not present): $key"
                continue
            }
            $null = & reg.exe export $key $out /y 2>$null
            if (Test-Path $out) { Write-Ok "backed up $key -> $out" }
        }
    } catch {}
}

# ---------- 1. Official uninstallers first ----------
if (-not $SkipOfficialUninstaller) {
    Write-Step "Step 1/7 - Letting GameLoop uninstall itself"
    Write-Detail "GameLoop's own uninstaller knows its files best, so we"
    Write-Detail "let it go first. This is the gentlest, safest way."

    # a) New path: C:\Program Files\Tencent\GameLoop\Application\Uninstall.exe
    $official = @(
        "$env:ProgramFiles\Tencent\GameLoop\Application\Uninstall.exe",
        "${env:ProgramFiles(x86)}\Tencent\GameLoop\Application\Uninstall.exe"
    )
    # b) Old path: TxGameAssistant GF*\TUninstall.exe on fixed drives only (depth-limited for speed)
    try {
        $drives = [System.IO.DriveInfo]::GetDrives() | Where-Object { $_.DriveType -eq 'Fixed' -and $_.IsReady } | Select-Object -ExpandProperty RootDirectory | Select-Object -ExpandProperty FullName
        if (-not $drives) { $drives = @("C:\") }
    } catch { $drives = @("C:\") }
    foreach ($root in $drives) {
        foreach ($cand in @(
            (Join-Path $root "Program Files\TxGameAssistant\AppMarket"),
            (Join-Path $root "Program Files (x86)\TxGameAssistant\AppMarket")
        )) {
            if (Test-Path -LiteralPath $cand) {
                try {
                    Get-ChildItem -LiteralPath $cand -Filter "TUninstall.exe" -Depth 3 -ErrorAction SilentlyContinue |
                        Select-Object -ExpandProperty FullName | ForEach-Object { $official += $_ }
                } catch {}
            }
        }
    }
    # c) From Uninstall registry (DisplayName + Publisher for rebranded TenStore builds)
    foreach ($base in @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall"
    )) {
        if (Test-Path $base) {
            try {
                Get-ChildItem $base -ErrorAction SilentlyContinue | ForEach-Object {
                    try {
                        $p = Get-ItemProperty $_.PsPath -ErrorAction SilentlyContinue
                        if ($null -eq $p) { return }
                        $display = $null
                        $uninstall = $null
                        $quiet = $null
                        $publisher = $null
                        $installLoc = $null
                        if ($p.PSObject.Properties['DisplayName']) { $display = $p.DisplayName }
                        if ($p.PSObject.Properties['UninstallString']) { $uninstall = $p.UninstallString }
                        if ($p.PSObject.Properties['QuietUninstallString']) { $quiet = $p.QuietUninstallString }
                        if ($p.PSObject.Properties['Publisher']) { $publisher = $p.Publisher }
                        if ($p.PSObject.Properties['InstallLocation']) { $installLoc = $p.InstallLocation }
                        $isGameLoop = ($display -match 'GameLoop|MobileGamePC|Tencent Gaming|TxGameAssistant|TenStore') -or
                                      ($publisher -match 'Tencent|Hong Kong Gathering Media|GameLoop|TenStore' -and $display -match 'Game|Emulator|Assistant|Loop|Store')
                        if ($isGameLoop) {
                            if ($uninstall) { Write-Found "installed program: $display"; Write-Detail $uninstall }
                            else { Write-Found "installed program (no uninstaller registered): $display" }
                            if (-not [string]::IsNullOrWhiteSpace($installLoc) -and (Test-Path -LiteralPath $installLoc)) {
                                $script:CustomInstallPaths += $installLoc
                                Write-Found "its files live in: $installLoc"
                            }
                            # Prefer QuietUninstallString, strip quotes for exe lookup
                            $us = $quiet
                            if ([string]::IsNullOrWhiteSpace($us)) { $us = $uninstall }
                            if ($us -match '"([^"]+\.exe)"') { $official += $Matches[1] }
                            elseif ($us -match "'([^']+\.exe)'") { $official += $Matches[1] }
                            elseif ($us -match '([A-Z]:\\[^\s]+\.exe)') { $official += $Matches[1] }
                        }
                    } catch {}
                }
            } catch {}
        }
    }

    $official = $official | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique
    foreach ($exe in $official) {
        $exeExp = [Environment]::ExpandEnvironmentVariables($exe)
        if (Test-Path -LiteralPath $exeExp) {
            Write-Found "running GameLoop's own uninstaller - if it opens a window, please follow it:"
            Write-Detail $exeExp
            if ($PSCmdlet.ShouldProcess($exeExp, "Run official uninstaller")) {
                # Silent flags per installer family (TUninstall = NSIS-style /S).
                $flags = @("/uninstall", "/quiet")
                if ($exeExp -match 'TUninstall\.exe$') { $flags = @("/S") }
                try {
                    $proc = Start-Process -FilePath $exeExp -ArgumentList $flags -PassThru -ErrorAction Stop
                    try { $exited = $proc.WaitForExit(180000) }
                    catch { $exited = $true }  # Already gone: nothing left to wait for.
                    if (-not $exited) {
                        # Revalidate the PID before killing - it may belong to
                        # another app by now. Never kill on a stale PID.
                        $stillThere = $false
                        try {
                            $recheck = Get-Process -Id $proc.Id -ErrorAction Stop
                            $stillThere = ($recheck.ProcessName -eq [System.IO.Path]::GetFileNameWithoutExtension($exeExp))
                        } catch { $stillThere = $false }
                        if ($stillThere) {
                            Write-Warning "  Uninstaller timed out after 180s, stopping it (PID $($proc.Id))"
                            try { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue } catch {}
                        } else {
                            Write-Found "uninstaller already gone - moving on"
                        }
                    } else {
                        Write-Found "its uninstaller finished (result code $($proc.ExitCode))"
                    }
                } catch {
                    Write-Warning "  Quiet mode did not work for this uninstaller: $_"
                    if (-not $Silent) {
                        Write-Found "opening it normally instead - just click through its window..."
                        try {
                            $proc2 = Start-Process -FilePath $exeExp -PassThru -ErrorAction Stop
                            try { $proc2.WaitForExit(300000) | Out-Null } catch {}
                        } catch { Write-Warning "  Failed: $_" }
                    }
                }
            }
        }
    }
    if (-not $WhatIfPreference) { Start-Sleep -Seconds 3 }
} else {
    Write-Step "Step 1/7 - Skipped (you chose -SkipOfficialUninstaller)"
}

# ---------- 2. Kill GameLoop processes only ----------
Write-Step "Step 2/7 - Closing GameLoop apps still running"
Write-Detail "Some GameLoop parts keep running quietly in the background."
Write-Detail "We close only those - your other programs stay open."
$killList = @(
    # New GameLoop 7.x
    "GameLoop.exe","GameLoopEmulator.exe","GameLoopService.exe","GameLoopAssistant.exe",
    "GameLoopAssistantToast.exe","GameLoopLauncher.exe","GameLoopUpdate.exe","GameLoopInstaller.exe",
    "GameLoopVfs.exe","GameLoopVm.exe","GameLoopDldSvr.exe","GameService_x86.exe",
    "GLABoxSVC.exe","GLABoxHeadless.exe","GLABoxManage.exe",
    "CefRendererProcess.exe","crashpad_handler.exe","crashpad_handler_extension.exe",
    "DiagnosisTool.exe","dokanctl.exe","ginkgo.exe","hpatchz.exe","Updater32.exe",
    "SilentProcess.exe","shutdown_abox.exe","opengl_checker.exe",
    "VBoxNetDHCP.exe","VBoxNetNAT.exe","vbox-img.exe",
    # Old TxGameAssistant
    "AppMarket.exe","AndroidEmulator.exe","AndroidEmulatorEn.exe","AndroidEmulatorEx.exe",
    "AndroidRenderer.exe","aow_exe.exe","QMEmulatorService.exe","adb.exe",
    "GameLoader.exe","TSettingCenter.exe","syzs_dl_svr.exe","TBSWebRenderer.exe",
    "TitanService.exe","ProjectTitan.exe","Auxillary.exe","TP3Helper.exe",
    "cef_frame_demo.exe","cef_frame_render.exe","qqlogin.exe","txplatform.exe",
    "tencentdl.exe","tensafe_1.exe","tensafe_2.exe","TUpdate.exe","TUninstall.exe"
    # NOTE: deliberately NOT killing RuntimeBroker.exe, Synaptics.exe, conime.exe, dnf.exe - system / unrelated
)
Stop-GameLoopProcess -Names $killList
if (-not $WhatIfPreference) { Start-Sleep -Seconds 2 }
# Retry stragglers up to 3x (drivers often respawn once)
$stragglers = @("GameLoopEmulator.exe","aow_exe.exe","QMEmulatorService.exe","AndroidEmulatorEn.exe","GameLoopService.exe")
for ($i = 1; $i -le 3; $i++) {
    $remaining = @(Get-Process -Name ($stragglers -replace '\.exe$','') -ErrorAction SilentlyContinue)
    if ($remaining.Count -eq 0) { break }
    Write-Found "looking once more for stragglers (pass $i of 3)..."
    Stop-GameLoopProcess -Names $stragglers
    if ($i -lt 3 -and -not $WhatIfPreference) { Start-Sleep -Seconds 2 }
}
# Catch-all: any remaining process actually running from a GameLoop folder
# (catches renamed or future helper exes the fixed list does not know yet).
# Never touches anything outside GameLoop folders, and never this script.
try {
    # .Path throws on protected system processes - swallow per-process, keep sweeping.
    $strays = @(Get-Process -ErrorAction SilentlyContinue | Where-Object {
        if ($_.Id -eq $PID) { return $false }
        $exePath = ''
        try { $exePath = $_.Path } catch { return $false }
        (-not [string]::IsNullOrWhiteSpace($exePath)) -and ($exePath -match 'GameLoop|TxGameAssistant')
    })
    foreach ($stray in $strays) {
        if ($PSCmdlet.ShouldProcess("$($stray.ProcessName) (PID $($stray.Id))", "Stop-Process")) {
            try { Stop-Process -Id $stray.Id -Force -ErrorAction Stop; Write-Ok "closed leftover app: $($stray.ProcessName) ($($stray.Id))"; Add-Stat 'Processes' }
            catch { Write-Warning "  Could not close $($stray.ProcessName): $_" }
        }
    }
    if ($strays.Count -gt 0 -and -not $WhatIfPreference) { Start-Sleep -Seconds 2 }
} catch { Write-Warning "  leftover-app sweep: $_" }

# ---------- 3. Stop + delete services ----------
Write-Step "Step 3/7 - Removing GameLoop background helpers"
Write-Detail "GameLoop installs hidden helpers that start with Windows."
Write-Detail "We remove the GameLoop ones only."
$svcNames = @("GameLoopService","GLABoxSup","QMEmulatorService","aow_drv","Tensafe")
# Auto-discovery: services whose program lives in a GameLoop folder
# (catches future/renamed helpers the fixed list does not know yet).
try {
    $found = @(Get-CimInstance Win32_Service -ErrorAction SilentlyContinue |
        Where-Object { "$($_.PathName)" -match 'GameLoop|TxGameAssistant|TenStore' } |
        Select-Object -ExpandProperty Name)
    foreach ($extra in $found) {
        if (-not [string]::IsNullOrWhiteSpace($extra) -and ($svcNames -notcontains $extra)) {
            Write-Found "discovered GameLoop helper: $extra"
            $svcNames += $extra
        }
    }
} catch { Write-Warning "  helper discovery: $_" }
foreach ($svc in $svcNames) {
    try {
        $s = Get-Service -Name $svc -ErrorAction SilentlyContinue
        if ($s) {
            Write-Found "found background helper: $svc ($($s.Status))"
            if ($PSCmdlet.ShouldProcess($svc, "Stop-Service + sc delete")) {
                try { Stop-Service -Name $svc -Force -ErrorAction SilentlyContinue } catch {}
                Start-Sleep -Seconds 1
                $scOut = (& sc.exe delete $svc 2>&1 | Out-String).Trim()
                if ($LASTEXITCODE -eq 0) {
                    Write-Ok "removed background helper: $svc"; Add-Stat 'Services'
                } else {
                    Write-Warning "  $svc needs a restart to finish going away ($scOut)"
                }
            }
        }
    } catch { Write-Warning "  Service $svc : $_" }
}

# ---------- 4. Firewall rules + scheduled tasks + startup ----------
# NOTE: intentionally NOT matching bare 'Tencent' - would nuke QQ/WeChat rules.
Write-Step "Step 4/7 - Tidying permissions and auto-start"
Write-Detail "Leftover entries that let GameLoop through the firewall,"
Write-Detail "wake it on a schedule, or start it with Windows."
try {
    $patterns = @('*GameLoop*', '*TxGameAssistant*', '*TenStore*', '*QMEmulator*', '*aow_exe*', '*AndroidEmulator*', '*GLABox*')
    $rules = @()
    foreach ($pat in $patterns) {
        try { $rules += Get-NetFirewallRule -DisplayName $pat -ErrorAction SilentlyContinue } catch {}
    }
    $rules = @($rules | Where-Object { $_ } | Sort-Object Name -Unique | Where-Object {
        $_.DisplayName -match 'GameLoop|TxGameAssistant|TenStore|QMEmulator|aow_exe|AndroidEmulator|GameLoopService|GLABox' -or
        $_.Name -match 'GameLoop|TxGameAssistant|TenStore|QMEmulator'
    })
    foreach ($r in $rules) {
        $ruleLabel = if ([string]::IsNullOrWhiteSpace($r.DisplayName)) { $r.Name } else { $r.DisplayName }
        if ($PSCmdlet.ShouldProcess($ruleLabel, "Remove-NetFirewallRule")) {
            try { Remove-NetFirewallRule -Name $r.Name -ErrorAction Stop; Write-Ok "removed firewall permission: $ruleLabel"; Add-Stat 'Firewall' }
            catch { Write-Warning "  Firewall rule failed: $_" }
        }
    }
    if (@($rules).Count -eq 0) { Write-Skip "nothing to do - no GameLoop firewall permissions" }
} catch { Write-Warning "  Firewall cleanup: $_" }

try {
    $tasks = @()
    foreach ($pat in @('*GameLoop*', '*TxGameAssistant*', '*TenStore*', '*QMEmulator*')) {
        try { $tasks += Get-ScheduledTask -TaskName $pat -ErrorAction SilentlyContinue } catch {}
    }
    if ($tasks.Count -eq 0) {
        try { $tasks = Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object { $_.TaskName -match 'GameLoop|TxGameAssistant|TenStore|QMEmulator' } } catch {}
    }
    $tasks = @($tasks | Where-Object { $_ } | Sort-Object TaskPath, TaskName -Unique)
    foreach ($t in $tasks) {
        if ($PSCmdlet.ShouldProcess("$($t.TaskPath)$($t.TaskName)", "Unregister-ScheduledTask")) {
            try { Unregister-ScheduledTask -TaskName $t.TaskName -TaskPath $t.TaskPath -Confirm:$false -ErrorAction Stop; Write-Ok "removed automatic task: $($t.TaskPath)$($t.TaskName)"; Add-Stat 'Tasks' }
            catch { Write-Warning "  Task failed: $_" }
        }
    }
    if (@($tasks).Count -eq 0) { Write-Skip "nothing to do - no GameLoop automatic tasks" }
} catch { Write-Warning "  Task cleanup: $_" }

# Startup entries (Run keys + Startup folders) - GameLoop only, never whole keys
foreach ($runKey in @("HKCU:\Software\Microsoft\Windows\CurrentVersion\Run", "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run", "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run")) {
    try {
        if (Test-Path -LiteralPath $runKey) {
            $props = (Get-ItemProperty -LiteralPath $runKey -ErrorAction SilentlyContinue).PSObject.Properties | Where-Object { $_.Name -notmatch '^(PSPath|PSParentPath|PSChildName|PSDrive|PSProvider)$' }
            foreach ($prop in $props) {
                if ("$($prop.Value)" -match 'GameLoop|TxGameAssistant|TenStore|QMEmulator|AndroidEmulator|aow_exe') {
                    if ($PSCmdlet.ShouldProcess("$runKey\$($prop.Name)", "Remove Run value")) {
                        try { Remove-ItemProperty -LiteralPath $runKey -Name $prop.Name -Force -ErrorAction Stop; Write-Ok "removed auto-start entry: $($prop.Name)"; Add-Stat 'Startup' }
                        catch { Write-Warning "  Run value failed: $_" }
                    }
                }
            }
        }
    } catch {}
}
foreach ($startupDir in @("$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Startup", "$env:ProgramData\Microsoft\Windows\Start Menu\Programs\StartUp")) {
    try {
        if (Test-Path -LiteralPath $startupDir) {
            Get-ChildItem -LiteralPath $startupDir -Filter "*.lnk" -ErrorAction SilentlyContinue | Where-Object { $_.Name -match 'GameLoop|TxGameAssistant|Tencent Gaming|TenStore|AndroidEmulator' } | ForEach-Object {
                Remove-PathSafe $_.FullName -Stat 'Shortcuts'
            }
        }
    } catch {}
}

# ---------- 5. Registry ----------
Write-Step "Step 5/7 - Removing leftover GameLoop settings"
Write-Detail "Small notes Windows keeps about GameLoop. Only GameLoop"
Write-Detail "entries are removed - everything else stays as it is."
# Ensure HKCR: drive exists for HKCR\GameLoop
try { if (-not (Get-PSDrive -Name HKCR -ErrorAction SilentlyContinue)) { New-PSDrive -Name HKCR -PSProvider Registry -Root HKEY_CLASSES_ROOT -ErrorAction SilentlyContinue | Out-Null } } catch {}

Remove-RegKeySafe "HKCU:\Software\Tencent\GameLoop"
Remove-RegKeySafe "HKCU:\Software\Tencent\MobileGamePC"
Remove-RegKeySafe "HKCU:\Software\Tencent\TGB"
Remove-RegKeySafe "HKLM:\SOFTWARE\Tencent\GameLoop"
Remove-RegKeySafe "HKLM:\SOFTWARE\Tencent\MobileGamePC"
Remove-RegKeySafe "HKLM:\SOFTWARE\Tencent\TGB"
Remove-RegKeySafe "HKLM:\SOFTWARE\WOW6432Node\Tencent\GameLoop"
Remove-RegKeySafe "HKLM:\SOFTWARE\WOW6432Node\Tencent\MobileGamePC"
Remove-RegKeySafe "HKLM:\SOFTWARE\WOW6432Node\Tencent\TGB"
Remove-RegKeySafe "HKCR:\GameLoop"
Remove-RegKeySafe "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\GameLoop"
Remove-RegKeySafe "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\GameLoop"
Remove-RegKeySafe "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\MobileGamePC"
Remove-RegKeySafe "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\MobileGamePC"
Remove-RegKeySafe "HKLM:\SOFTWARE\Classes\TencentMobileGameAssistant"
# Fallback: service keys if sc.exe delete left them behind (reboot still required for drivers)
Remove-RegKeySafe "HKLM:\SYSTEM\CurrentControlSet\Services\GameLoopService"
Remove-RegKeySafe "HKLM:\SYSTEM\CurrentControlSet\Services\GLABoxSup"
Remove-RegKeySafe "HKLM:\SYSTEM\CurrentControlSet\Services\QMEmulatorService"
Remove-RegKeySafe "HKLM:\SYSTEM\CurrentControlSet\Services\aow_drv"

# Only remove parent Tencent keys if they are now empty / GameLoop-only to avoid nuking other Tencent apps
foreach ($parent in @("HKCU:\Software\Tencent", "HKLM:\SOFTWARE\Tencent", "HKLM:\SOFTWARE\WOW6432Node\Tencent")) {
    try {
        if ((Test-Path -LiteralPath $parent) -and $PSCmdlet.ShouldProcess($parent, "Remove parent Tencent key if empty")) {
            $kids = @(Get-ChildItem -LiteralPath $parent -ErrorAction SilentlyContinue)
            # An empty "(default)" value does not count as content - ignore it.
            $vals = @((Get-ItemProperty -LiteralPath $parent -ErrorAction SilentlyContinue).PSObject.Properties | Where-Object { $_.Name -notmatch '^(PSPath|PSParentPath|PSChildName|PSDrive|PSProvider|\(default\))$' -and -not [string]::IsNullOrWhiteSpace("$($_.Value)") })
            if ($kids.Count -eq 0 -and $vals.Count -eq 0) { Remove-Item -LiteralPath $parent -Force -ErrorAction SilentlyContinue; Write-Ok "removed empty settings group: $parent"; Add-Stat 'RegKeys' }
            else { Write-Skip "kept $parent - still used by your other Tencent apps" }
        }
    } catch {}
}

# Per-user hives (dynamic SID, no hardcoded SID): remove GameLoop keys for real users only
try {
    if (-not (Get-PSDrive -Name HKU -ErrorAction SilentlyContinue)) { New-PSDrive -Name HKU -PSProvider Registry -Root HKEY_USERS -ErrorAction SilentlyContinue | Out-Null }
    Get-ChildItem "HKU:\" -ErrorAction SilentlyContinue | Where-Object { $_.PSChildName -match '^S-1-5-21-' } | ForEach-Object {
        foreach ($sub in @("Software\Tencent\GameLoop", "Software\Tencent\MobileGamePC", "Software\Tencent\TGB")) {
            $full = "HKU:\$($_.PSChildName)\$sub"
            if (Test-Path -LiteralPath $full) {
                Remove-RegKeySafe $full
            }
        }
    }
} catch { Write-Warning "  HKU cleanup: $_" }

# Per-value MuiCache cleanup (never the whole key): drop only GameLoop-related values
foreach ($muiKey in @("HKCU:\Software\Classes\Local Settings\Software\Microsoft\Windows\Shell\MuiCache")) {
    try {
        if (Test-Path -LiteralPath $muiKey) {
            $muiProps = (Get-ItemProperty -LiteralPath $muiKey -ErrorAction SilentlyContinue).PSObject.Properties | Where-Object { $_.Name -notmatch '^(PSPath|PSParentPath|PSChildName|PSDrive|PSProvider)$' }
            foreach ($prop in $muiProps) {
                if ($prop.Name -match 'GameLoop|TxGameAssistant|TenStore|MobileGamePC|AndroidEmulator|AppMarket') {
                    if ($PSCmdlet.ShouldProcess("$muiKey\$($prop.Name)", "Remove MuiCache value")) {
                        try { Remove-ItemProperty -LiteralPath $muiKey -Name $prop.Name -Force -ErrorAction Stop; Write-Ok "removed remembered app entry: $($prop.Name)"; Add-Stat 'RegValues' }
                        catch { Write-Warning "  MuiCache failed: $_" }
                    }
                }
            }
        }
    } catch {}
}

# NOTE: intentionally NOT deleting Compatibility Assistant\Store wholesale (too broad).

# ---------- 6. Folders, shortcuts, temp ----------
Write-Step "Step 6/7 - Removing leftover files and icons"
Write-Detail "Leftover program folders, desktop icons and Start menu"
Write-Detail "entries. Your personal files are never touched."

# Narrowed to GameLoop subfolders only - never whole ...\Tencent (would wipe QQ/WeChat).
$folders = @(
    "$env:ProgramFiles\TxGameAssistant",
    "${env:ProgramFiles(x86)}\TxGameAssistant",
    "$env:ProgramFiles\Tencent\GameLoop",
    "${env:ProgramFiles(x86)}\Tencent\GameLoop",
    "$env:ProgramData\Tencent\GameLoop",
    "$env:ProgramData\TxGameAssistant",
    "$env:LOCALAPPDATA\Tencent\GameLoop",
    "$env:LOCALAPPDATA\Tencent\MobileGamePC",
    "$env:LOCALAPPDATA\TxGameAssistant",
    "$env:APPDATA\Tencent\GameLoop",
    "$env:APPDATA\Tencent\MobileGamePC",
    "$env:USERPROFILE\Documents\Tencent Files",
    "$env:LOCALAPPDATA\Temp\Tencent"
)
# Documents may live under OneDrive - cover the real location too
$knownDocs = [Environment]::GetFolderPath('MyDocuments')
if (-not [string]::IsNullOrWhiteSpace($knownDocs) -and ($knownDocs -ne "$env:USERPROFILE\Documents")) {
    $folders += (Join-Path $knownDocs "Tencent Files")
}
# Custom install locations discovered from Uninstall registry (e.g. D:\Games\GameLoop).
# Trusted: GameLoop's own installer registered them, so they bypass the
# Windows\Temp name restriction (drive roots and system folders still refused).
foreach ($custom in @($script:CustomInstallPaths)) {
    if ([string]::IsNullOrWhiteSpace($custom)) { continue }
    if ($KeepGames -and $custom -like "*Documents\Tencent Files*") {
        Write-Skip "kept your games folder (you chose -KeepGames): $custom"
        continue
    }
    Remove-PathSafe $custom -Stat 'Folders' -Trusted
}
# Also scan fixed drives for installs on D:, E:, etc. (old bat did C-G manually)
try {
    $driveRoots = [System.IO.DriveInfo]::GetDrives() | Where-Object { $_.DriveType -eq 'Fixed' -and $_.IsReady } | Select-Object -ExpandProperty RootDirectory | Select-Object -ExpandProperty FullName
    if (-not $driveRoots) { $driveRoots = @("C:\") }
} catch { $driveRoots = @("C:\") }
foreach ($root in $driveRoots) {
    $folders += (Join-Path $root "Program Files\TxGameAssistant")
    $folders += (Join-Path $root "Program Files (x86)\TxGameAssistant")
    $folders += (Join-Path $root "Program Files\Tencent\GameLoop")
    $folders += (Join-Path $root "Program Files (x86)\Tencent\GameLoop")
    $folders += (Join-Path $root "txgameassistant")
    $folders += (Join-Path $root "Temp\TxGameAssistant")
}
$folders = $folders | Select-Object -Unique

foreach ($f in $folders) {
    # Respect -KeepGames for Documents\Tencent Files
    if ($KeepGames -and $f -like "*Documents\Tencent Files*") {
        Write-Skip "kept your games folder (you chose -KeepGames): $f"
        continue
    }
    # Safety refusals (drive roots, Windows, bare system folders) are handled
    # inside Remove-PathSafe so custom install paths are judged correctly.
    Remove-PathSafe $f -Stat 'Folders'
}

# Remove parent Tencent folders only if GameLoop was the sole content
foreach ($tencentParent in @("$env:ProgramFiles\Tencent", "${env:ProgramFiles(x86)}\Tencent", "$env:ProgramData\Tencent", "$env:LOCALAPPDATA\Tencent", "$env:APPDATA\Tencent")) {
    try {
        if ((Test-Path -LiteralPath $tencentParent) -and $PSCmdlet.ShouldProcess($tencentParent, "Remove empty parent Tencent folder")) {
            if (@(Get-ChildItem -LiteralPath $tencentParent -Force -ErrorAction SilentlyContinue).Count -eq 0) {
                Remove-Item -LiteralPath $tencentParent -Force -ErrorAction SilentlyContinue
                Write-Ok "removed empty leftover folder: $tencentParent"; Add-Stat 'Folders'
            }
        }
    } catch {}
}

# Shortcuts (fixed quoting bug from old bat) - includes OneDrive-redirected Desktop
$knownDesktop = [Environment]::GetFolderPath('Desktop')
$shortcuts = @(
    "$env:USERPROFILE\Desktop\GameLoop.lnk",
    "$env:USERPROFILE\Desktop\AndroidEmulator.lnk",
    "$env:USERPROFILE\Desktop\Tencent Gaming Buddy.lnk",
    "$env:PUBLIC\Desktop\GameLoop.lnk",
    "$env:PUBLIC\Desktop\TxGameAssistant.lnk",
    "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\GameLoop.lnk",
    "$env:APPDATA\Microsoft\Internet Explorer\Quick Launch\GameLoop.lnk",
    "$env:ProgramData\Microsoft\Windows\Start Menu\Programs\GameLoop.lnk"
)
if (-not [string]::IsNullOrWhiteSpace($knownDesktop) -and ($knownDesktop -ne "$env:USERPROFILE\Desktop")) {
    $shortcuts += (Join-Path $knownDesktop "GameLoop.lnk")
    $shortcuts += (Join-Path $knownDesktop "AndroidEmulator.lnk")
    $shortcuts += (Join-Path $knownDesktop "Tencent Gaming Buddy.lnk")
}
# Start Menu TxGameAssistant folder (directory, not just .lnk)
foreach ($startDir in @("$env:APPDATA\Microsoft\Windows\Start Menu\Programs\TxGameAssistant", "$env:ProgramData\Microsoft\Windows\Start Menu\Programs\TxGameAssistant")) {
    if (Test-Path -LiteralPath $startDir) { Remove-PathSafe $startDir -Stat 'Shortcuts' }
}
foreach ($s in $shortcuts) { Remove-PathSafe $s -Stat 'Shortcuts' }

# GameLoop-only temp (never whole %TEMP%)
Write-Step "Cleaning temporary files"
Write-Detail "Temporary download and setup files GameLoop left behind."
$sysTemp = Join-Path $env:SystemRoot "Temp"
foreach ($t in @( "$script:TempBase\Tencent", "$script:TempBase\GameLoop", "$script:TempBase\TBSdk", "$script:TempBase\TxGameAssistant", "$env:LOCALAPPDATA\Temp\Tencent", (Join-Path $sysTemp "Tencent"), (Join-Path $sysTemp "GameLoop") )) {
    Remove-PathSafe $t -Stat 'Temp'
}

# Rotate old logs in the log folder (keep last 10)
try {
    Get-ChildItem -LiteralPath $script:LogDir -Filter "Gameloop-Uninstaller-*.log" -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -Skip 10 | ForEach-Object {
            try { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue } catch {}
        }
} catch {}

# ---------- 7. Verify ----------
Write-Step "Step 7/7 - Double-checking everything is gone"
Write-Detail "We look again at the main GameLoop spots to confirm."
if ($WhatIfPreference) {
    Write-Host "WhatIf mode: verification skipped (no files were actually deleted)."
} else {
    $leftover = @()
    $verifyTargets = @(
        "$env:ProgramFiles\Tencent\GameLoop", "$env:ProgramFiles\TxGameAssistant", "${env:ProgramFiles(x86)}\TxGameAssistant",
        "${env:ProgramFiles(x86)}\Tencent\GameLoop", "$env:ProgramData\Tencent\GameLoop",
        "$env:LOCALAPPDATA\Tencent\GameLoop", "$env:APPDATA\Tencent\GameLoop"
    )
    foreach ($custom in @($script:CustomInstallPaths)) {
        if (-not [string]::IsNullOrWhiteSpace($custom)) { $verifyTargets += $custom }
    }
    foreach ($p in ($verifyTargets | Select-Object -Unique)) {
        if (Test-Path -LiteralPath ([Environment]::ExpandEnvironmentVariables($p))) { $leftover += $p }
    }
    $leftoverSvcs = @(Get-Service -Name @("GameLoopService","GLABoxSup","QMEmulatorService","aow_drv") -ErrorAction SilentlyContinue)
    $leftoverProcs = @(Get-Process -Name @("GameLoop","GameLoopEmulator","aow_exe","QMEmulatorService","AndroidEmulatorEn") -ErrorAction SilentlyContinue)
    if ($leftover.Count -eq 0 -and $leftoverSvcs.Count -eq 0 -and $leftoverProcs.Count -eq 0) {
        Write-Ok "all clean - no GameLoop leftovers found anywhere"
    } else {
        Write-Host "  Almost there - a few things need attention:" -ForegroundColor Yellow
        if ($leftover.Count -gt 0) { Write-Warning ("  Folders still there (a restart usually unlocks them): " + ($leftover -join ", ")) }
        if ($leftoverSvcs.Count -gt 0) { Write-Warning ("  Helpers still installed: " + (($leftoverSvcs | Select-Object -ExpandProperty Name) -join ", ")) }
        if ($leftoverProcs.Count -gt 0) { Write-Warning ("  Apps still running (close them, then run this again): " + (($leftoverProcs | Select-Object -ExpandProperty ProcessName -Unique) -join ", ")) }
    }
}

$script:Stopwatch.Stop()
$labels = [ordered]@{
    Processes = 'Apps closed'; Services = 'Background helpers'
    Firewall = 'Firewall permissions'; Tasks = 'Automatic tasks'; Startup = 'Auto-start entries'
    RegKeys = 'Settings groups'; RegValues = 'Settings entries'
    Folders = 'Folders'; Shortcuts = 'Icons & shortcuts'; Temp = 'Temp files'
}
$total = 0
foreach ($v in $script:Stats.Values) { $total += $v }
Write-Host ""
Write-Host "  +------------------------------------------------------+" -ForegroundColor Green
Write-Host "  |  ALL DONE - HERE IS WHAT WAS CLEANED                 |" -ForegroundColor Green
Write-Host "  +------------------------------------------------------+" -ForegroundColor Green
foreach ($k in $script:Stats.Keys) {
    Write-Host ("    {0,-20} {1,5}" -f $labels[$k], $script:Stats[$k]) -ForegroundColor Gray
}
Write-Host ("    {0,-20} {1,5}" -f 'TOTAL', $total) -ForegroundColor White
Write-Host ("    {0,-20} {1,5}" -f 'Time taken', $script:Stopwatch.Elapsed.ToString('mm\:ss')) -ForegroundColor Gray
Write-Host "  +------------------------------------------------------+" -ForegroundColor Green
Write-Host ""
if (($total -eq 0) -and (-not $WhatIfPreference)) {
    Write-Host "  Your PC was already clean - there was nothing to remove." -ForegroundColor Green
    Write-Host ""
}
Write-Host "  What is next:" -ForegroundColor White
Write-Host "    1. Restart your PC to finish (unlocks any files still in use)." -ForegroundColor Gray
Write-Host "    2. Want GameLoop back? Get it fresh from the official site." -ForegroundColor Gray
Write-Host "    3. This full report is saved in the log file below." -ForegroundColor Gray
Write-Host ""
Write-Ok "done - full report saved to: $logFile"
Write-Found "settings backup kept in: $backupDir"
try { Stop-Transcript | Out-Null } catch {}

if (-not $NoRebootPrompt -and -not $Silent -and -not $WhatIfPreference) {
    Write-Host ""
    $rb = Read-Host "  Restart your PC now to finish the cleanup? (Y/N)"
    if ($rb -match '^[Yy]') { Restart-Computer -Force }
}

