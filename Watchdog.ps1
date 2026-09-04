# MemTrim Watchdog: background safety net.
# Launched hidden at logon (see Install.ps1). Polls memory at a low priority,
# does nothing until free RAM actually drops below the configured threshold,
# skips fullscreen apps (best-effort, see Test-MemTrimForegroundFullscreen)
# so it shouldn't interrupt a race, and never trims more often than once
# per cooldown window.

$ErrorActionPreference = 'Continue'

# Same fallback as Dashboard.ps1. Empty once compiled to an exe, since
# there's no script file on disk anymore for $PSScriptRoot to point at.
$here = if ($PSScriptRoot) {
    $PSScriptRoot
} elseif ($MyInvocation.MyCommand.Path) {
    Split-Path -Parent $MyInvocation.MyCommand.Path
} else {
    [System.AppDomain]::CurrentDomain.BaseDirectory.TrimEnd('\')
}

Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force -ErrorAction SilentlyContinue
. (Join-Path $here 'Core.ps1')

try { (Get-Process -Id $PID).PriorityClass = 'BelowNormal' } catch { }

Write-MemTrimLog "Watchdog started (pid $PID)."

$CooldownSec = 120
$lastCleanUtc = [datetime]::MinValue

while ($true) {
    # $intervalSec is resolved once, clamped, and used for the single sleep
    # at the bottom of the loop. Previously three of the four Start-Sleep
    # call sites re-cast $config.checkIntervalSec directly, and the one
    # reached on a normal "nothing to do" pass sat outside the try/catch.
    # A hand-edited config.json with a non-numeric checkIntervalSec would
    # throw there uncaught and kill the watchdog process for good.
    $intervalSec = 20
    try {
        $config = Get-MemTrimConfig
        $intervalSec = [math]::Max(10, [int]$config.checkIntervalSec)

        if ($config.watchdogEnabled) {
            $status = Get-MemTrimStatus

            if ($status.FreePercent -lt [double]$config.thresholdPercent) {
                $sinceLastClean = (Get-Date).ToUniversalTime() - $lastCleanUtc

                if ($sinceLastClean.TotalSeconds -ge $CooldownSec) {
                    if ($config.skipWhenFullscreen -and (Test-MemTrimForegroundFullscreen)) {
                        # Best-effort detection (see Test-MemTrimForegroundFullscreen), this
                        # can occasionally skip a clean that would have been fine, or vice versa.
                        Write-MemTrimLog ("Free RAM {0}% below threshold {1}% but a fullscreen app has focus, skipping." -f $status.FreePercent, $config.thresholdPercent)
                    } else {
                        $trim = Invoke-MemTrimWorkingSets -SkipForeground -ExcludeProcesses $config.excludeProcesses
                        $purgeMsg = ""
                        if (Test-MemTrimIsAdmin) {
                            $purge = Invoke-MemTrimStandbyPurge
                            $purgeMsg = if ($purge.Success) { " + standby purge" } else { " (standby purge failed: $($purge.Reason))" }
                        }

                        # DeltaGB is available-memory before/after, not causally
                        # attributed to this trim alone, reported as a change.
                        Write-MemTrimLog ("Auto-clean: free was {0}% (< {1}% threshold), trimmed {2} processes, available {3:+0.00;-0.00;0.00} GB{4}." -f `
                            $status.FreePercent, $config.thresholdPercent, $trim.ProcessesTrimmed, $trim.DeltaGB, $purgeMsg)

                        $lastCleanUtc = (Get-Date).ToUniversalTime()
                    }
                }
            }
        }
    } catch {
        Write-MemTrimLog "Watchdog loop error: $($_.Exception.Message)"
    }

    Start-Sleep -Seconds $intervalSec
}
