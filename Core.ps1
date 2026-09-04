# MemTrim.Core: memory telemetry + trim engine
# Dot-source this from Dashboard.ps1 / Watchdog.ps1 (or their compiled exe
# equivalents, see build.ps1). No side effects on load other than defining
# the native P/Invoke type and helper functions.

$ErrorActionPreference = 'Stop'

# Same $PSScriptRoot fallback as the scripts that dot-source this file,
# kept here too since this is loaded by path either way and shouldn't
# assume which caller resolved it correctly.
$Script:MemTrimRoot = if ($PSScriptRoot) {
    $PSScriptRoot
} elseif ($MyInvocation.MyCommand.Path) {
    Split-Path -Parent $MyInvocation.MyCommand.Path
} else {
    [System.AppDomain]::CurrentDomain.BaseDirectory.TrimEnd('\')
}
$Script:MemTrimLog     = Join-Path $MemTrimRoot 'Logs\memtrim.log'
$Script:MemTrimConfig  = Join-Path $MemTrimRoot 'config.json'

if (-not ("MemTrim.Native" -as [type])) {
Add-Type -Namespace MemTrim -Name Native -MemberDefinition @'
[StructLayout(LayoutKind.Sequential)]
public struct MEMORYSTATUSEX {
    public uint dwLength;
    public uint dwMemoryLoad;
    public ulong ullTotalPhys;
    public ulong ullAvailPhys;
    public ulong ullTotalPageFile;
    public ulong ullAvailPageFile;
    public ulong ullTotalVirtual;
    public ulong ullAvailVirtual;
    public ulong ullAvailExtendedVirtual;
}

[StructLayout(LayoutKind.Sequential)]
public struct PERFORMANCE_INFORMATION {
    public uint cb;
    public UIntPtr CommitTotal;
    public UIntPtr CommitLimit;
    public UIntPtr CommitPeak;
    public UIntPtr PhysicalTotal;
    public UIntPtr PhysicalAvailable;
    public UIntPtr SystemCache;
    public UIntPtr KernelTotal;
    public UIntPtr KernelPaged;
    public UIntPtr KernelNonpaged;
    public UIntPtr PageSize;
    public uint HandleCount;
    public uint ProcessCount;
    public uint ThreadCount;
}

[StructLayout(LayoutKind.Sequential)]
public struct LUID { public uint LowPart; public int HighPart; }

[StructLayout(LayoutKind.Sequential)]
public struct LUID_AND_ATTRIBUTES { public LUID Luid; public uint Attributes; }

[StructLayout(LayoutKind.Sequential)]
public struct TOKEN_PRIVILEGES { public uint PrivilegeCount; public LUID_AND_ATTRIBUTES Privileges; }

[StructLayout(LayoutKind.Sequential)]
public struct RECT { public int Left, Top, Right, Bottom; }

[DllImport("kernel32.dll", SetLastError = true)]
[return: MarshalAs(UnmanagedType.Bool)]
public static extern bool GlobalMemoryStatusEx(ref MEMORYSTATUSEX lpBuffer);

[DllImport("psapi.dll", SetLastError = true)]
[return: MarshalAs(UnmanagedType.Bool)]
public static extern bool GetPerformanceInfo(ref PERFORMANCE_INFORMATION pPerformanceInformation, uint cb);

[DllImport("psapi.dll", SetLastError = true)]
[return: MarshalAs(UnmanagedType.Bool)]
public static extern bool EmptyWorkingSet(IntPtr hProcess);

[DllImport("ntdll.dll")]
public static extern int NtSetSystemInformation(int SystemInformationClass, IntPtr SystemInformation, int SystemInformationLength);

[DllImport("advapi32.dll", SetLastError = true)]
[return: MarshalAs(UnmanagedType.Bool)]
public static extern bool OpenProcessToken(IntPtr ProcessHandle, uint DesiredAccess, out IntPtr TokenHandle);

[DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Auto)]
[return: MarshalAs(UnmanagedType.Bool)]
public static extern bool LookupPrivilegeValue(string lpSystemName, string lpName, out LUID lpLuid);

[DllImport("advapi32.dll", SetLastError = true)]
[return: MarshalAs(UnmanagedType.Bool)]
public static extern bool AdjustTokenPrivileges(IntPtr TokenHandle, [MarshalAs(UnmanagedType.Bool)] bool DisableAllPrivileges, ref TOKEN_PRIVILEGES NewState, uint BufferLength, IntPtr PreviousState, IntPtr ReturnLength);

[DllImport("kernel32.dll")]
public static extern IntPtr GetCurrentProcess();

[DllImport("kernel32.dll", SetLastError = true)]
[return: MarshalAs(UnmanagedType.Bool)]
public static extern bool CloseHandle(IntPtr hObject);

[DllImport("user32.dll")]
public static extern IntPtr GetForegroundWindow();

[DllImport("user32.dll")]
[return: MarshalAs(UnmanagedType.Bool)]
public static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);

[DllImport("user32.dll")]
public static extern int GetSystemMetrics(int nIndex);
'@ -ErrorAction Stop
}

Set-Variable -Name TOKEN_QUERY -Value 0x0008 -Option Constant -Scope Script -ErrorAction SilentlyContinue
Set-Variable -Name TOKEN_ADJUST_PRIVILEGES -Value 0x0020 -Option Constant -Scope Script -ErrorAction SilentlyContinue
Set-Variable -Name SE_PRIVILEGE_ENABLED -Value 0x00000002 -Option Constant -Scope Script -ErrorAction SilentlyContinue

function Test-MemTrimIsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p  = New-Object Security.Principal.WindowsPrincipal($id)
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Write-MemTrimLog {
    param([Parameter(Mandatory)][string]$Message)
    $line = "[{0:yyyy-MM-dd HH:mm:ss}] {1}" -f (Get-Date), $Message
    try {
        Add-Content -Path $Script:MemTrimLog -Value $line -Encoding utf8
    } catch { }
    return $line
}

function Get-MemTrimConfig {
    $defaults = [ordered]@{
        watchdogEnabled   = $true
        thresholdPercent  = 12      # trigger a trim when free RAM % drops below this
        checkIntervalSec  = 20
        skipWhenFullscreen = $true
        excludeProcesses  = @('iRacingSim64DX11','acs','AC2-Win64-Shipping','RTSS','MSIAfterburner')
    }
    if (Test-Path $Script:MemTrimConfig) {
        try {
            $loaded = Get-Content $Script:MemTrimConfig -Raw | ConvertFrom-Json
            foreach ($k in $defaults.Keys) {
                if ($null -ne $loaded.$k) { $defaults[$k] = $loaded.$k }
            }
        } catch { }
    }
    return $defaults
}

function Save-MemTrimConfig {
    param([Parameter(Mandatory)]$Config)
    $Config | ConvertTo-Json -Depth 5 | Set-Content -Path $Script:MemTrimConfig -Encoding utf8
}

function Get-MemTrimStatus {
    # Returns a PSCustomObject with the numbers the dashboard/watchdog need.
    $ms = New-Object MemTrim.Native+MEMORYSTATUSEX
    $ms.dwLength = [uint32][System.Runtime.InteropServices.Marshal]::SizeOf($ms)
    [void][MemTrim.Native]::GlobalMemoryStatusEx([ref]$ms)

    $pi = New-Object MemTrim.Native+PERFORMANCE_INFORMATION
    $pi.cb = [uint32][System.Runtime.InteropServices.Marshal]::SizeOf($pi)
    [void][MemTrim.Native]::GetPerformanceInfo([ref]$pi, $pi.cb)
    $pageSize = [uint64]$pi.PageSize

    $totalGB     = [math]::Round($ms.ullTotalPhys / 1GB, 2)
    $availGB     = [math]::Round($ms.ullAvailPhys / 1GB, 2)
    $usedGB      = [math]::Round($totalGB - $availGB, 2)
    $freePercent = [math]::Round((100 - $ms.dwMemoryLoad), 1)
    # PERFORMANCE_INFORMATION.SystemCache is Windows' broader "system cache"
    # figure (standby list + modified page list), not an isolated count of
    # only the standby list that Invoke-MemTrimStandbyPurge targets. Exposed
    # as StandbyGB here for API stability; the dashboard displays it as
    # "Cache GB" rather than "Standby GB" to match what the number actually is.
    $standbyGB   = [math]::Round(([uint64]$pi.SystemCache * $pageSize) / 1GB, 2)
    $commitGB    = [math]::Round(([uint64]$pi.CommitTotal * $pageSize) / 1GB, 2)

    [PSCustomObject]@{
        TotalGB     = $totalGB
        UsedGB      = $usedGB
        FreeGB      = $availGB
        FreePercent = $freePercent
        StandbyGB   = $standbyGB
        CommitGB    = $commitGB
        Timestamp   = Get-Date
    }
}

function Test-MemTrimForegroundFullscreen {
    # Best-effort heuristic, not a guarantee: true if the foreground window's
    # bounds cover the primary display. Doesn't distinguish exclusive
    # fullscreen from a borderless window sized to match, doesn't check
    # non-primary monitors, and can't see anything if there's no foreground
    # window at all. Good enough to usually avoid trimming mid-race.
    try {
        $hwnd = [MemTrim.Native]::GetForegroundWindow()
        if ($hwnd -eq [IntPtr]::Zero) { return $false }
        $rect = New-Object MemTrim.Native+RECT
        if (-not [MemTrim.Native]::GetWindowRect($hwnd, [ref]$rect)) { return $false }
        $w = $rect.Right - $rect.Left
        $h = $rect.Bottom - $rect.Top
        $screenW = [MemTrim.Native]::GetSystemMetrics(0)  # SM_CXSCREEN
        $screenH = [MemTrim.Native]::GetSystemMetrics(1)  # SM_CYSCREEN
        return ($w -ge $screenW -and $h -ge $screenH)
    } catch {
        return $false
    }
}

function Enable-MemTrimPrivilege {
    # Enables SeProfileSingleProcessPrivilege on the current process token.
    # Required for the standby-list purge. No-op (returns $false) if not admin.
    if (-not (Test-MemTrimIsAdmin)) { return $false }
    $hToken = [IntPtr]::Zero
    $proc = [MemTrim.Native]::GetCurrentProcess()  # pseudo-handle, does not need closing
    if (-not [MemTrim.Native]::OpenProcessToken($proc, ($Script:TOKEN_ADJUST_PRIVILEGES -bor $Script:TOKEN_QUERY), [ref]$hToken)) {
        return $false
    }
    try {
        $luid = New-Object MemTrim.Native+LUID
        if (-not [MemTrim.Native]::LookupPrivilegeValue($null, "SeProfileSingleProcessPrivilege", [ref]$luid)) {
            return $false
        }
        $tp = New-Object MemTrim.Native+TOKEN_PRIVILEGES
        $tp.PrivilegeCount = 1
        $tp.Privileges = New-Object MemTrim.Native+LUID_AND_ATTRIBUTES
        $tp.Privileges.Luid = $luid
        $tp.Privileges.Attributes = $Script:SE_PRIVILEGE_ENABLED
        $adjusted = [MemTrim.Native]::AdjustTokenPrivileges($hToken, $false, [ref]$tp, 0, [IntPtr]::Zero, [IntPtr]::Zero)
        # AdjustTokenPrivileges can return true while quietly granting nothing.
        # ERROR_NOT_ALL_ASSIGNED (1300) only shows up via GetLastError, not the
        # return value, so a caller that only checks the bool gets a false positive.
        $lastError = [System.Runtime.InteropServices.Marshal]::GetLastWin32Error()
        return ($adjusted -and $lastError -ne 1300)
    } finally {
        [void][MemTrim.Native]::CloseHandle($hToken)
    }
}

function Invoke-MemTrimStandbyPurge {
    # Purges the standby list (the "cached but reclaimable" memory Windows
    # keeps around). Only meaningful right before loading something
    # RAM-hungry. See notes in README. Requires admin.
    if (-not (Test-MemTrimIsAdmin)) {
        return [PSCustomObject]@{ Success = $false; Reason = 'not-admin' }
    }
    if (-not (Enable-MemTrimPrivilege)) {
        return [PSCustomObject]@{ Success = $false; Reason = 'privilege-failed' }
    }
    $MemoryPurgeStandbyList = 4
    $buf = [System.Runtime.InteropServices.Marshal]::AllocHGlobal(4)
    try {
        [System.Runtime.InteropServices.Marshal]::WriteInt32($buf, $MemoryPurgeStandbyList)
        $status = [MemTrim.Native]::NtSetSystemInformation(80, $buf, 4)  # SystemMemoryListInformation
        if ($status -eq 0) {
            return [PSCustomObject]@{ Success = $true; Reason = 'ok' }
        } else {
            return [PSCustomObject]@{ Success = $false; Reason = ("ntstatus-0x{0:X}" -f $status) }
        }
    } finally {
        [System.Runtime.InteropServices.Marshal]::FreeHGlobal($buf)
    }
}

function Invoke-MemTrimWorkingSets {
    param(
        [string[]]$ExcludeProcesses = @(),
        [switch]$SkipForeground
    )
    # Trims idle background processes' working sets. Non-destructive: no
    # data is lost, trimmed pages just get paged back in from disk the next
    # time that process touches them, which costs a page fault (a small,
    # one-time stall) rather than being free. We skip the foreground app
    # (and anything in the exclude list) so we never touch whatever you're
    # actively using/racing.
    $fgPid = 0
    if ($SkipForeground) {
        try {
            $hwnd = [MemTrim.Native]::GetForegroundWindow()
            Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public class MemTrimFg {
    [DllImport("user32.dll")]
    public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint lpdwProcessId);
}
'@ -ErrorAction SilentlyContinue
            $u = 0
            [void][MemTrimFg]::GetWindowThreadProcessId($hwnd, [ref]$u)
            $fgPid = $u
        } catch { }
    }

    $trimmed = 0
    $before = Get-MemTrimStatus

    # Filtering and trimming both happen inside the same try/catch per
    # process. A process that exits mid-scan (or is a protected/system
    # process we can't open a handle to) throws on property access just as
    # often as on EmptyWorkingSet itself. Putting the filter in a separate
    # Where-Object left those exceptions unprotected and able to abort the
    # whole pipeline over one process.
    Get-Process | ForEach-Object {
        try {
            if ($_.Id -eq $fgPid -or $_.Id -eq $PID) { return }
            if ($ExcludeProcesses -contains $_.ProcessName) { return }
            if ($_.WorkingSet64 -le 30MB) { return }
            if ($_.Handle -and [MemTrim.Native]::EmptyWorkingSet($_.Handle)) {
                $trimmed++
            }
        } catch { }
    }

    $after = Get-MemTrimStatus
    [PSCustomObject]@{
        ProcessesTrimmed = $trimmed
        FreeBeforeGB     = $before.FreeGB
        FreeAfterGB      = $after.FreeGB
        DeltaGB          = [math]::Round($after.FreeGB - $before.FreeGB, 2)
    }
}
