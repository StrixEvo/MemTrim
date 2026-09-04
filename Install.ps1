# MemTrim Install: registers the hidden logon watchdog (highest privileges,
# so it can purge the standby list without a UAC prompt every boot) and
# drops a "Clean RAM Now" desktop shortcut for the on-demand dashboard.
#
# Safe to re-run any time: it re-registers the task and re-writes the
# shortcut, so it's idempotent. The dashboard itself never needs admin to
# run; only the watchdog's standby-list purge does, which is why this
# installer is the thing that needs elevation, not the app.

$ErrorActionPreference = 'Stop'
$here = if ($PSScriptRoot) {
    $PSScriptRoot
} elseif ($MyInvocation.MyCommand.Path) {
    Split-Path -Parent $MyInvocation.MyCommand.Path
} else {
    [System.AppDomain]::CurrentDomain.BaseDirectory.TrimEnd('\')
}
$iconPath = Join-Path $here 'assets\icon.ico'

# Prefer the compiled exes (see build.ps1) if they're sitting right here.
# That's the whole point of building them, no PowerShell invocation needed
# at all. Falls back to the source scripts otherwise, so this same
# installer works whether or not anyone's run build.ps1.
$watchdogExe = Join-Path $here 'MemTrimWatchdog.exe'
$dashboardExe = Join-Path $here 'MemTrim.exe'
$usingExe = (Test-Path $watchdogExe) -and (Test-Path $dashboardExe)

if ($usingExe) {
    $watchdogTarget  = $watchdogExe
    $watchdogArgs    = ''
    $dashboardTarget = $dashboardExe
    $dashboardArgs   = ''
} else {
    $pwsh = (Get-Command pwsh -ErrorAction SilentlyContinue).Source
    if (-not $pwsh) { $pwsh = (Get-Command powershell).Source }
    $watchdogScript  = Join-Path $here 'Watchdog.ps1'
    $dashboardScript = Join-Path $here 'Dashboard.ps1'
    $watchdogTarget  = $pwsh
    $watchdogArgs    = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$watchdogScript`""
    $dashboardTarget = $pwsh
    $dashboardArgs   = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$dashboardScript`""
}

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

$isAdmin = Test-Admin
$taskName = 'MemTrim Watchdog'
$taskInstalled = $false

if (-not $isAdmin) {
    Write-Warning "Not running as Administrator. The watchdog needs 'highest privileges' to purge the standby list, and Windows won't register a task at that level from a non-elevated session."
    Write-Warning "Re-run this script from an elevated PowerShell to install the watchdog. Continuing to set up the desktop shortcut, which doesn't need admin."
} else {
    $action    = New-ScheduledTaskAction -Execute $watchdogTarget -Argument $watchdogArgs
    $trigger   = New-ScheduledTaskTrigger -AtLogOn
    $principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Highest
    $settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero)

    if (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
    }
    try {
        Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings `
            -Description "MemTrim background memory watchdog (idle working-set trim + standby purge, throttled)" -ErrorAction Stop | Out-Null
    } catch {
        Write-Warning "Register-ScheduledTask failed: $($_.Exception.Message)"
    }

    # Register-ScheduledTask's underlying CIM errors don't always respect
    # -ErrorAction the way a normal cmdlet would. Verify it actually landed
    # rather than trust a clean exit code.
    $taskInstalled = [bool](Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue)
    if ($taskInstalled) {
        try { Start-ScheduledTask -TaskName $taskName } catch { }
    }
}

# desktop shortcut for the on-demand dashboard
$desktop = [Environment]::GetFolderPath('Desktop')
$shortcutPath = Join-Path $desktop 'Clean RAM Now.lnk'
$wsh = New-Object -ComObject WScript.Shell
$shortcut = $wsh.CreateShortcut($shortcutPath)
$shortcut.TargetPath = $dashboardTarget
$shortcut.Arguments = $dashboardArgs
$shortcut.WorkingDirectory = $here
$shortcut.Description = "MemTrim - clean RAM now"
if (Test-Path $iconPath) { $shortcut.IconLocation = $iconPath }
$shortcut.Save()

Write-Output ""
Write-Output "MemTrim install summary:"
Write-Output " - Running from            : $(if ($usingExe) { 'compiled .exe' } else { 'PowerShell source (.ps1)' })"
Write-Output " - Watchdog scheduled task : $(if ($taskInstalled) { 'installed and started' } else { 'NOT installed (see warning above)' })"
Write-Output " - Desktop shortcut        : $shortcutPath"
Write-Output " - Config                 : $(Join-Path $here 'config.json') (created on first Save in the Tuning drawer)"
Write-Output " - Log                    : $(Join-Path $here 'Logs\memtrim.log')"
