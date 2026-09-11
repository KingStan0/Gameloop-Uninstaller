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

# Temp base with fallback (SYSTEM account may lack $env:TEMP)
$script:TempBase = if (-not [string]::IsNullOrWhiteSpace($env:TEMP)) { $env:TEMP } else { [System.IO.Path]::GetTempPath() }

# ---------- Helpers ----------
function Write-Step {
    param([string]$Message)
    Write-Host ""
    Write-Host "==> $Message" -ForegroundColor Cyan
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
                        Write-Host "  Skipped shared process $($pr.ProcessName) ($($pr.Id)) outside GameLoop path"
                        continue
                    }
                }
                if ($PSCmdlet.ShouldProcess("$($pr.ProcessName) (PID $($pr.Id))", "Stop-Process")) {
                    try { Stop-Process -Id $pr.Id -Force -ErrorAction Stop; Write-Host "  Killed $($pr.ProcessName) ($($pr.Id))" }
                    catch { Write-Warning "  Could not kill $($pr.ProcessName): $_" }
                }
            }
        } catch { Write-Warning "  process lookup failed for $name : $_" }
    }
}

function Remove-PathSafe {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return }
    # Expand env vars, keep as literal
    $expanded = [Environment]::ExpandEnvironmentVariables($Path).Trim().TrimEnd('\')
    # Defense-in-depth: block only exact dangerous roots (not every subfolder).
    $lower = $expanded.ToLowerInvariant()
    $dangerous = @(
        $env:SystemRoot.ToLowerInvariant(),
        ($env:ProgramFiles).ToLowerInvariant(),
        (${env:ProgramFiles(x86)}).ToLowerInvariant(),
        ($env:ProgramData).ToLowerInvariant(),
        ($env:USERPROFILE).ToLowerInvariant(),
        ($env:APPDATA).ToLowerInvariant(),
        ($env:LOCALAPPDATA).ToLowerInvariant()
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
    if ($expanded -match '^[A-Z]:\\Windows([\\/]|$)') {
        if ($expanded -match '\\Temp\\(Tencent|GameLoop|TxGameAssistant)([\\/]|$)') {
            # Allowed: C:\Windows\Temp\Tencent, ...\GameLoop - GameLoop-only temp.
        } else {
            Write-Warning "  Refused to delete protected path: $expanded"
            return
        }
    }
    if ($expanded.Length -lt 12) {
        Write-Warning "  Refused to delete suspiciously short path: $expanded"
        return
    }
    if (Test-Path -LiteralPath $expanded) {
        if ($PSCmdlet.ShouldProcess($expanded, "Remove-Item -Recurse -Force")) {
            try {
                Remove-Item -LiteralPath $expanded -Recurse -Force -ErrorAction Stop
                Write-Host "  Removed: $expanded"
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
    if (Test-Path -LiteralPath $Path) {
        if ($PSCmdlet.ShouldProcess($Path, "Remove registry key")) {
            try { Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop; Write-Host "  Removed reg: $Path" }
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

Write-Host "==============================================" -ForegroundColor Green
Write-Host " Gameloop Uninstaller (2025-2026 ready)" -ForegroundColor Green
Write-Host "=============================================="
Write-Host "Log: $logFile"
Write-Host "Options: Silent=$Silent KeepGames=$KeepGames SkipOfficial=$SkipOfficialUninstaller"

if (-not (Test-IsAdmin) -and -not $WhatIfPreference) {
    Write-Error "Please run as Administrator (right-click Gameloop-Uninstaller.bat -> Run as administrator). Aborting."
    try { Stop-Transcript | Out-Null } catch {}
    exit 1
}

if (-not $Silent -and -not $WhatIfPreference) {
    Write-Warning "This will completely remove GameLoop / Tencent emulator files, services and registry keys."
    Write-Warning "Close games and the emulator first. A reboot is recommended afterwards."
    $ans = Read-Host "Type YES to continue"
    if ($ans.Trim() -ne "YES") { Write-Host "Aborted by user."; try { Stop-Transcript | Out-Null } catch {}; exit 0 }
}

# Registry backup
Write-Step "Backing up Tencent/GameLoop registry keys"
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
                Write-Host "  Skipped backup (key not present): $key"
                continue
            }
            $null = & reg.exe export $key $out /y 2>$null
            if (Test-Path $out) { Write-Host "  Backed up $key -> $out" }
        }
    } catch {}
}

# ---------- 1. Official uninstallers first ----------
if (-not $SkipOfficialUninstaller) {
    Write-Step "Step 1/7 - Running official uninstallers (if present)"

    # a) New path: C:\Program Files\Tencent\GameLoop\Application\Uninstall.exe
    $official = @(
        "$env:ProgramFiles\Tencent\GameLoop\Application\Uninstall.exe",
        "${env:ProgramFiles(x86)}\Tencent\GameLoop\Application\Uninstall.exe"
    )
    $script:CustomInstallPaths = @()
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
                            if ($uninstall) { Write-Host "  Found: $display -> $uninstall" }
                            if (-not [string]::IsNullOrWhiteSpace($installLoc) -and (Test-Path -LiteralPath $installLoc)) {
                                $script:CustomInstallPaths += $installLoc
                                Write-Host "  Found custom install location: $installLoc"
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
            Write-Host "  Running official uninstaller: $exeExp"
            if ($PSCmdlet.ShouldProcess($exeExp, "Run official uninstaller")) {
                # Per-exe silent flags (GameLoop uses mixed installers: custom /uninstall, Inno /VERYSILENT, NSIS /S)
                $flags = @("/uninstall", "/quiet")
                if ($exeExp -match 'TUninstall\.exe$') { $flags = @("/S") }
                elseif ($exeExp -match 'Uninstall\.exe$') { $flags = @("/uninstall", "/quiet") }
                try {
                    $proc = Start-Process -FilePath $exeExp -ArgumentList $flags -PassThru -ErrorAction Stop
                    $exited = $proc.WaitForExit(180000)
                    if (-not $exited) {
                        Write-Warning "  Uninstaller timed out after 180s, killing PID $($proc.Id)"
                        try { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue } catch {}
                    } else {
                        Write-Host "  Exit code: $($proc.ExitCode)"
                    }
                } catch {
                    Write-Warning "  Silent uninstall failed: $_"
                    if (-not $Silent) {
                        Write-Host "  Trying interactive uninstaller (user input may be required)..."
                        try {
                            $proc2 = Start-Process -FilePath $exeExp -PassThru -ErrorAction Stop
                            $proc2.WaitForExit(300000) | Out-Null
                        } catch { Write-Warning "  Failed: $_" }
                    }
                }
            }
        }
    }
    if (-not $WhatIfPreference) { Start-Sleep -Seconds 3 }
} else {
    Write-Step "Step 1/7 - Skipped official uninstaller (-SkipOfficialUninstaller)"
}

# ---------- 2. Kill GameLoop processes only ----------
Write-Step "Step 2/7 - Stopping GameLoop processes"
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
    Write-Host "  Retry pass $i for $($remaining.Count) straggler(s)..."
    Stop-GameLoopProcess -Names $stragglers
    if ($i -lt 3 -and -not $WhatIfPreference) { Start-Sleep -Seconds 2 }
}

# ---------- 3. Stop + delete services ----------
Write-Step "Step 3/7 - Stopping and removing GameLoop services"
foreach ($svc in @("GameLoopService","GLABoxSup","QMEmulatorService","aow_drv","Tensafe")) {
    try {
        $s = Get-Service -Name $svc -ErrorAction SilentlyContinue
        if ($s) {
            Write-Host "  Found service: $svc ($($s.Status))"
            if ($PSCmdlet.ShouldProcess($svc, "Stop-Service + sc delete")) {
                try { Stop-Service -Name $svc -Force -ErrorAction SilentlyContinue } catch {}
                Start-Sleep -Seconds 1
                & sc.exe delete $svc 2>$null | Out-Null
                Write-Host "  Deleted service: $svc"
            }
        }
    } catch { Write-Warning "  Service $svc : $_" }
}

# ---------- 4. Firewall rules + scheduled tasks + startup ----------
# NOTE: intentionally NOT matching bare 'Tencent' - would nuke QQ/WeChat rules.
Write-Step "Step 4/7 - Removing firewall rules, scheduled tasks and startup entries"
try {
    $patterns = @('*GameLoop*', '*TxGameAssistant*', '*TenStore*', '*QMEmulator*', '*aow_exe*', '*AndroidEmulator*', '*GLABox*')
    $rules = @()
    foreach ($pat in $patterns) {
        try { $rules += Get-NetFirewallRule -DisplayName $pat -ErrorAction SilentlyContinue } catch {}
    }
    $rules = $rules | Sort-Object Name -Unique | Where-Object {
        $_.DisplayName -match 'GameLoop|TxGameAssistant|TenStore|QMEmulator|aow_exe|AndroidEmulator|GameLoopService|GLABox' -or
        $_.Name -match 'GameLoop|TxGameAssistant|TenStore|QMEmulator'
    }
    foreach ($r in $rules) {
        if ($PSCmdlet.ShouldProcess($r.DisplayName, "Remove-NetFirewallRule")) {
            try { Remove-NetFirewallRule -Name $r.Name -ErrorAction Stop; Write-Host "  Removed firewall rule: $($r.DisplayName)" }
            catch { Write-Warning "  Firewall rule failed: $_" }
        }
    }
    if (@($rules).Count -eq 0) { Write-Host "  No GameLoop firewall rules found." }
} catch { Write-Warning "  Firewall cleanup: $_" }

try {
    $tasks = @()
    foreach ($pat in @('*GameLoop*', '*TxGameAssistant*', '*TenStore*', '*QMEmulator*')) {
        try { $tasks += Get-ScheduledTask -TaskName $pat -ErrorAction SilentlyContinue } catch {}
    }
    if ($tasks.Count -eq 0) {
        try { $tasks = Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object { $_.TaskName -match 'GameLoop|TxGameAssistant|TenStore|QMEmulator' } } catch {}
    }
    $tasks = @($tasks | Sort-Object TaskPath, TaskName -Unique)
    foreach ($t in $tasks) {
        if ($PSCmdlet.ShouldProcess("$($t.TaskPath)$($t.TaskName)", "Unregister-ScheduledTask")) {
            try { Unregister-ScheduledTask -TaskName $t.TaskName -TaskPath $t.TaskPath -Confirm:$false -ErrorAction Stop; Write-Host "  Removed task: $($t.TaskPath)$($t.TaskName)" }
            catch { Write-Warning "  Task failed: $_" }
        }
    }
    if (@($tasks).Count -eq 0) { Write-Host "  No GameLoop scheduled tasks found." }
} catch { Write-Warning "  Task cleanup: $_" }

# Startup entries (Run keys + Startup folders) - GameLoop only, never whole keys
foreach ($runKey in @("HKCU:\Software\Microsoft\Windows\CurrentVersion\Run", "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run", "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run")) {
    try {
        if (Test-Path -LiteralPath $runKey) {
            $props = (Get-ItemProperty -LiteralPath $runKey -ErrorAction SilentlyContinue).PSObject.Properties | Where-Object { $_.Name -notmatch '^(PSPath|PSParentPath|PSChildName|PSDrive|PSProvider)$' }
            foreach ($prop in $props) {
                if ("$($prop.Value)" -match 'GameLoop|TxGameAssistant|TenStore|QMEmulator|AndroidEmulator|aow_exe') {
                    if ($PSCmdlet.ShouldProcess("$runKey\$($prop.Name)", "Remove Run value")) {
                        try { Remove-ItemProperty -LiteralPath $runKey -Name $prop.Name -Force -ErrorAction Stop; Write-Host "  Removed Run value: $($prop.Name)" }
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
                Remove-PathSafe $_.FullName
            }
        }
    } catch {}
}

# ---------- 5. Registry ----------
Write-Step "Step 5/7 - Removing GameLoop registry keys (targeted only)"
# Ensure HKCR: drive exists for HKCR\GameLoop
try { if (-not (Get-PSDrive -Name HKCR -ErrorAction SilentlyContinue)) { New-PSDrive -Name HKCR -PSProvider Registry -Root HKEY_CLASSES_ROOT -ErrorAction SilentlyContinue | Out-Null } } catch {}

Remove-RegKeySafe "HKCU:\Software\Tencent\GameLoop"
Remove-RegKeySafe "HKCU:\Software\Tencent\MobileGamePC"
Remove-RegKeySafe "HKLM:\SOFTWARE\Tencent\GameLoop"
Remove-RegKeySafe "HKLM:\SOFTWARE\Tencent\MobileGamePC"
Remove-RegKeySafe "HKLM:\SOFTWARE\WOW6432Node\Tencent\GameLoop"
Remove-RegKeySafe "HKLM:\SOFTWARE\WOW6432Node\Tencent\MobileGamePC"
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
            $vals = @((Get-ItemProperty -LiteralPath $parent -ErrorAction SilentlyContinue).PSObject.Properties | Where-Object { $_.Name -notmatch '^(PSPath|PSParentPath|PSChildName|PSDrive|PSProvider)$' })
            if ($kids.Count -eq 0 -and $vals.Count -eq 0) { Remove-Item -LiteralPath $parent -Force -ErrorAction SilentlyContinue; Write-Host "  Removed empty parent: $parent" }
            else { Write-Host "  Kept parent $parent (still has $($kids.Count) subkey(s), $($vals.Count) value(s) - may belong to other Tencent apps)" }
        }
    } catch {}
}

# Per-user hives (dynamic SID, no hardcoded SID): remove GameLoop keys for real users only
try {
    if (-not (Get-PSDrive -Name HKU -ErrorAction SilentlyContinue)) { New-PSDrive -Name HKU -PSProvider Registry -Root HKEY_USERS -ErrorAction SilentlyContinue | Out-Null }
    Get-ChildItem "HKU:\" -ErrorAction SilentlyContinue | Where-Object { $_.PSChildName -match '^S-1-5-21-' } | ForEach-Object {
        foreach ($sub in @("Software\Tencent\GameLoop", "Software\Tencent\MobileGamePC")) {
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
                        try { Remove-ItemProperty -LiteralPath $muiKey -Name $prop.Name -Force -ErrorAction Stop; Write-Host "  Removed MuiCache: $($prop.Name)" }
                        catch { Write-Warning "  MuiCache failed: $_" }
                    }
                }
            }
        }
    } catch {}
}

# NOTE: intentionally NOT deleting Compatibility Assistant\Store wholesale (too broad).

# ---------- 6. Folders, shortcuts, temp ----------
Write-Step "Step 6/7 - Removing GameLoop folders and shortcuts"

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
# Custom install locations discovered from Uninstall registry (e.g. D:\Games\GameLoop)
foreach ($custom in @($script:CustomInstallPaths)) {
    if (-not [string]::IsNullOrWhiteSpace($custom)) { $folders += $custom }
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
        Write-Host "  Skipped (KeepGames): $f"
        continue
    }
    # Never delete a drive root or bare Temp
    if ($f -match '^[A-Z]:\\?$' -or $f -match '^[A-Z]:\\Temp\\?$' -or $f -match '^[A-Z]:\\Windows') {
        Write-Warning "  Refused to delete protected path: $f"
        continue
    }
    Remove-PathSafe $f
}

# Remove parent Tencent folders only if GameLoop was the sole content
foreach ($tencentParent in @("$env:ProgramFiles\Tencent", "${env:ProgramFiles(x86)}\Tencent", "$env:ProgramData\Tencent", "$env:LOCALAPPDATA\Tencent", "$env:APPDATA\Tencent")) {
    try {
        if ((Test-Path -LiteralPath $tencentParent) -and $PSCmdlet.ShouldProcess($tencentParent, "Remove empty parent Tencent folder")) {
            if (@(Get-ChildItem -LiteralPath $tencentParent -Force -ErrorAction SilentlyContinue).Count -eq 0) {
                Remove-Item -LiteralPath $tencentParent -Force -ErrorAction SilentlyContinue
                Write-Host "  Removed empty parent: $tencentParent"
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
    if (Test-Path -LiteralPath $startDir) { Remove-PathSafe $startDir }
}
foreach ($s in $shortcuts) { Remove-PathSafe $s }

# GameLoop-only temp (never whole %TEMP%)
Write-Step "Cleaning GameLoop-only temp files"
$sysTemp = Join-Path $env:SystemRoot "Temp"
foreach ($t in @( "$script:TempBase\Tencent", "$script:TempBase\GameLoop", "$script:TempBase\TBSdk", "$script:TempBase\TxGameAssistant", "$env:LOCALAPPDATA\Temp\Tencent", (Join-Path $sysTemp "Tencent"), (Join-Path $sysTemp "GameLoop") )) {
    Remove-PathSafe $t
}

# Rotate old logs in the log folder (keep last 10)
try {
    Get-ChildItem -LiteralPath $script:LogDir -Filter "Gameloop-Uninstaller-*.log" -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -Skip 10 | ForEach-Object {
            try { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue } catch {}
        }
} catch {}

# ---------- 7. Verify ----------
Write-Step "Step 7/7 - Verify"
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
        Write-Host "Cleanup looks complete. No GameLoop folders, services or processes remain." -ForegroundColor Green
    } else {
        if ($leftover.Count -gt 0) { Write-Warning ("Remaining folders (may need reboot to unlock driver aow_drv): " + ($leftover -join ", ")) }
        if ($leftoverSvcs.Count -gt 0) { Write-Warning ("Remaining services: " + (($leftoverSvcs | Select-Object -ExpandProperty Name) -join ", ")) }
        if ($leftoverProcs.Count -gt 0) { Write-Warning ("Remaining processes: " + (($leftoverProcs | Select-Object -ExpandProperty ProcessName -Unique) -join ", ")) }
    }
}

Write-Host ""
Write-Host "Done. Log saved to: $logFile" -ForegroundColor Green
Write-Host "Registry backup in: $backupDir"
try { Stop-Transcript | Out-Null } catch {}

if (-not $NoRebootPrompt -and -not $Silent -and -not $WhatIfPreference) {
    $rb = Read-Host "Reboot now to release locked drivers (aow_drv)? (Y/N)"
    if ($rb -match '^[Yy]') { Restart-Computer -Force }
}

