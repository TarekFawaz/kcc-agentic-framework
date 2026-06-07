<#
KCC framework (c) 2026 Tarek Fawaz, https://tikasway.dev/kcc. Licensed under the terms in LICENSE.

.SYNOPSIS
    Detect whether a build/test toolchain is present, and suggest per-OS
    install commands for whatever is missing.

.DESCRIPTION
    Detection + suggestion only. For each tool in -Tools, this script checks
    presence via Get-Command and prints PRESENT (with version) or MISSING.
    For each missing tool it prints a suggested install command for the
    current OS (winget on Windows, brew on macOS, apt/dnf on Linux).

    This script NEVER installs anything. Toolchain install is a human-gated,
    system-mutating action (see .KCC/kernel/protocols/toolchain-preflight.md).
    The agent runs installs at runtime only after explicit human approval.

    Exit code: 0 if all tools are present, 1 if any tool is missing.

    PowerShell 5.1 compatible. No && operator.

.PARAMETER Tools
    Comma-separated list of tool executables to check, e.g. "node,pnpm,git".

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .KCC\tools\toolchain-preflight.ps1 -Tools node,pnpm,git
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Tools
)

$ErrorActionPreference = 'Stop'

# Detect the current OS family (PS 5.1 has no $IsWindows automatic variable).
function Get-OSFamily {
    if ($env:OS -eq 'Windows_NT') { return 'windows' }
    if (Test-Path '/System/Library/CoreServices') { return 'macos' }
    return 'linux'
}

# Pick a Linux package-manager hint (apt vs dnf).
function Get-LinuxInstaller {
    if (Get-Command apt-get -ErrorAction SilentlyContinue) { return 'apt-get install -y' }
    if (Get-Command dnf -ErrorAction SilentlyContinue) { return 'dnf install -y' }
    return 'apt-get install -y'   # default hint
}

# Suggest an install command for a missing tool on the current OS.
function Get-InstallSuggestion {
    param([string]$Tool, [string]$OS)

    # Tool-specific globals first.
    switch ($Tool) {
        'pnpm' { return 'corepack enable; corepack prepare pnpm@latest --activate   (or: npm i -g pnpm)' }
        'cargo' { return 'install rustup from https://rustup.rs (rustup-init), then: rustup default stable' }
        'flutter' { return 'install Flutter SDK from https://docs.flutter.dev/get-started/install' }
    }

    switch ($OS) {
        'windows' {
            $map = @{
                node = 'winget install OpenJS.NodeJS.LTS'
                npm  = 'winget install OpenJS.NodeJS.LTS'
                git  = 'winget install Git.Git'
                python = 'winget install Python.Python.3.12'
                go   = 'winget install GoLang.Go'
                dotnet = 'winget install Microsoft.DotNet.SDK.8'
                terraform = 'winget install HashiCorp.Terraform'
                kubectl = 'winget install Kubernetes.kubectl'
                helm = 'winget install Helm.Helm'
                dart = 'winget install Google.DartSDK'
            }
            if ($map.ContainsKey($Tool)) { return $map[$Tool] + '   (fallback: choco install / scoop install)' }
            return "winget install <package-for-$Tool>   (fallback: choco/scoop)"
        }
        'macos' {
            $map = @{ node = 'brew install node'; npm = 'brew install node'; git = 'brew install git';
                      python = 'brew install python'; go = 'brew install go'; dotnet = 'brew install --cask dotnet-sdk';
                      terraform = 'brew install terraform'; kubectl = 'brew install kubectl'; helm = 'brew install helm';
                      dart = 'brew install dart' }
            if ($map.ContainsKey($Tool)) { return $map[$Tool] }
            return "brew install $Tool"
        }
        default {
            $inst = Get-LinuxInstaller
            $map = @{ node = 'nodejs'; npm = 'npm'; git = 'git'; python = 'python3'; go = 'golang-go';
                      dotnet = 'dotnet-sdk-8.0'; terraform = 'terraform'; kubectl = 'kubectl'; helm = 'helm';
                      dart = 'dart' }
            $pkg = if ($map.ContainsKey($Tool)) { $map[$Tool] } else { $Tool }
            return "sudo $inst $pkg   (may require elevation)"
        }
    }
}

$os = Get-OSFamily
$toolList = $Tools.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' }
$missing = @()

Write-Output "Toolchain preflight (OS: $os)"
Write-Output "-----------------------------------"

foreach ($tool in $toolList) {
    $cmd = Get-Command $tool -ErrorAction SilentlyContinue
    if ($cmd) {
        $version = ''
        try { $version = (& $tool --version 2>$null | Select-Object -First 1) } catch { $version = '' }
        if ([string]::IsNullOrWhiteSpace($version)) { $version = 'present' }
        Write-Output ("PRESENT  {0}  ({1})" -f $tool, $version.Trim())
    } else {
        $missing += $tool
        Write-Output ("MISSING  {0}" -f $tool)
        Write-Output ("         install: {0}" -f (Get-InstallSuggestion -Tool $tool -OS $os))
    }
}

Write-Output "-----------------------------------"
if ($missing.Count -gt 0) {
    Write-Output ("MISSING TOOLS: {0}" -f ($missing -join ', '))
    Write-Output "Toolchain install is a HUMAN-GATED action. Do NOT install silently."
    Write-Output "See .KCC/kernel/protocols/toolchain-preflight.md (install / human-install / defer)."
    exit 1
}

Write-Output "All required tools are present."
exit 0
