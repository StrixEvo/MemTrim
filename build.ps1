# MemTrim Build: compiles the .ps1 scripts into standalone .exe files under
# dist/, using ps2exe (installs it for the current user if missing).
#
# dist/ ends up a complete, self-contained copy you can zip and hand to
# someone: the compiled exes, plus Core.ps1 sitting right next to them.
# The exes load Core.ps1 from disk at runtime rather than embedding it, so
# the actual memory/privilege logic stays a plain, readable, editable file
# even in the compiled build, not baked into a binary you have to trust
# blind. Nothing here touches the source scripts, they still run directly
# under pwsh exactly as before, this only adds the exe as another option.

$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot
$distDir = Join-Path $here 'dist'
$iconPath = Join-Path $here 'assets\icon.ico'

if (-not (Get-Module -ListAvailable ps2exe)) {
    Write-Output "ps2exe not found, installing for the current user..."
    Install-Module ps2exe -Scope CurrentUser -Force
}
Import-Module ps2exe

New-Item -ItemType Directory -Path $distDir -Force | Out-Null

function Build-Exe {
    param(
        [Parameter(Mandatory)][string]$InputScript,
        [Parameter(Mandatory)][string]$OutputExe,
        [Parameter(Mandatory)][string]$Description,
        [switch]$NoConsole,
        [switch]$STA
    )
    $params = @{
        inputFile   = Join-Path $here $InputScript
        outputFile  = Join-Path $distDir $OutputExe
        title       = 'MemTrim'
        product     = 'MemTrim'
        description = $Description
        version     = '1.0.0.0'
        copyright   = 'MIT License'
    }
    if (Test-Path $iconPath) { $params.iconFile = $iconPath }
    if ($NoConsole) { $params.noConsole = $true }
    if ($STA) { $params.STA = $true }
    Write-Output "Building $OutputExe..."
    Invoke-ps2exe @params
}

# Dashboard and Watchdog are pure GUI/background, no console window.
# WPF requires STA, so Dashboard needs it explicitly.
Build-Exe -InputScript 'Dashboard.ps1' -OutputExe 'MemTrim.exe' `
    -Description 'MemTrim dashboard' -NoConsole -STA
Build-Exe -InputScript 'Watchdog.ps1' -OutputExe 'MemTrimWatchdog.exe' `
    -Description 'MemTrim background watchdog'

# Install/Uninstall keep their console window: they print a summary and
# warnings the user actually needs to see.
Build-Exe -InputScript 'Install.ps1' -OutputExe 'Install.exe' `
    -Description 'MemTrim installer'
Build-Exe -InputScript 'Uninstall.ps1' -OutputExe 'Uninstall.exe' `
    -Description 'MemTrim uninstaller'

# Core.ps1 is not embedded in any of the above. It's loaded from disk at
# runtime, so it has to physically be here for the exes to work at all.
Copy-Item (Join-Path $here 'Core.ps1') $distDir -Force
Copy-Item (Join-Path $here 'config.example.json') $distDir -Force
Copy-Item (Join-Path $here 'assets') $distDir -Recurse -Force
# Write-MemTrimLog silently no-ops if this doesn't exist (Add-Content is
# wrapped in try/catch). Missed this the first time and it cost a debug
# session, logging just quietly did nothing.
New-Item -ItemType Directory -Path (Join-Path $distDir 'Logs') -Force | Out-Null

Write-Output ""
Write-Output "Built dist/. Copy the whole folder to share it. Install.exe there"
Write-Output "is a normal Windows installer at that point: no PowerShell required."
