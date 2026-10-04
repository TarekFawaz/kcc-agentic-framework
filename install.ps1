<#
KCC framework (c) 2026 Tarek Fawaz, https://tikasway.dev/kcc. Licensed under the terms in LICENSE.

.SYNOPSIS
    Installs the kcc command line on Windows.

.DESCRIPTION
    Downloads the self-contained kcc binary from the GitHub release, checks
    its SHA-256 against the release's checksums.txt, puts it in a user folder,
    and adds that folder to the user PATH. No administrator rights, no Node,
    and no PowerShell 7 are needed.

.PARAMETER Version
    Release to install, for example 0.5.0. Default: latest.

.PARAMETER InstallDir
    Target folder. Default: %LOCALAPPDATA%\kcc\bin.

.PARAMETER From
    Install a local binary (for example cli\dist\kcc.exe) instead of downloading.

.EXAMPLE
    irm https://raw.githubusercontent.com/TarekFawaz/kcc-agentic-framework/main/install.ps1 | iex

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File install.ps1 -Version 0.5.0
#>
[CmdletBinding()]
param(
    [string]$Version = 'latest',
    [string]$InstallDir = (Join-Path $env:LOCALAPPDATA 'kcc\bin'),
    [string]$From,
    [switch]$NoPath
)

$ErrorActionPreference = 'Stop'
$repo = 'TarekFawaz/kcc-agentic-framework'
$asset = 'kcc-windows-x64.exe'

if (-not [Environment]::Is64BitOperatingSystem) { throw 'kcc needs 64-bit Windows.' }

New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
$target = Join-Path $InstallDir 'kcc.exe'

if ($From) {
    if (-not (Test-Path -LiteralPath $From)) { throw "File not found: $From" }
    Copy-Item -LiteralPath $From -Destination $target -Force
} else {
    if ($Version -eq 'latest') { $base = "https://github.com/$repo/releases/latest/download" }
    else { $base = "https://github.com/$repo/releases/download/v$($Version.TrimStart('v'))" }
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ("kcc-" + [Guid]::NewGuid().ToString('N') + '.exe')
    Write-Host "Downloading $base/$asset"
    Invoke-WebRequest -Uri "$base/$asset" -OutFile $tmp -UseBasicParsing
    try {
        $sums = (Invoke-WebRequest -Uri "$base/checksums.txt" -UseBasicParsing).Content
        if ($sums -is [byte[]]) { $sums = [Text.Encoding]::UTF8.GetString($sums) }
        $expected = $null
        foreach ($line in ($sums -split "`n")) {
            $parts = $line.Trim() -split '\s+'
            if ($parts.Count -ge 2 -and $parts[1].TrimStart('*') -eq $asset) { $expected = $parts[0].ToLowerInvariant() }
        }
        if (-not $expected) { throw "checksums.txt has no entry for $asset" }
        $actual = (Get-FileHash -LiteralPath $tmp -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($actual -ne $expected) { throw "Checksum mismatch for $asset (expected $expected, got $actual). Nothing was installed." }
    } catch {
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        throw
    }
    Move-Item -LiteralPath $tmp -Destination $target -Force
}

$userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
if (-not $userPath) { $userPath = '' }
$onPath = $false
foreach ($p in ($userPath -split ';')) { if ($p.TrimEnd('\') -ieq $InstallDir.TrimEnd('\')) { $onPath = $true } }
if (-not $onPath -and -not $NoPath) {
    [Environment]::SetEnvironmentVariable('Path', ($userPath.TrimEnd(';') + ';' + $InstallDir).TrimStart(';'), 'User')
    $env:Path = $env:Path + ';' + $InstallDir
    Write-Host "Added $InstallDir to your user PATH. Open a new terminal to use it everywhere."
}

Write-Host "Installed: $target"
& $target version
Write-Host ''
Write-Host 'Next: cd into your project and run  kcc init'
