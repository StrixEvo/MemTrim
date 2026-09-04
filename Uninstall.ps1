# MemTrim Uninstall: removes the watchdog scheduled task and desktop shortcut.
# Leaves the MemTrim folder (logs/config) in place; delete it manually if you
# want it fully gone.

$ErrorActionPreference = 'SilentlyContinue'
$taskName = 'MemTrim Watchdog'

if (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) {
    Stop-ScheduledTask -TaskName $taskName
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
    Write-Output "Removed scheduled task '$taskName'."
} else {
    Write-Output "Scheduled task '$taskName' was not installed."
}

$desktop = [Environment]::GetFolderPath('Desktop')
$shortcutPath = Join-Path $desktop 'Clean RAM Now.lnk'
if (Test-Path $shortcutPath) {
    Remove-Item $shortcutPath -Force
    Write-Output "Removed desktop shortcut."
} else {
    Write-Output "Desktop shortcut was not present."
}
