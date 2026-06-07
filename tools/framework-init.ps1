<#
KCC framework (c) 2026 Tarek Fawaz, https://tikasway.dev/kcc. Licensed under the terms in LICENSE.

.SYNOPSIS
    Compatibility wrapper for .KCC/tools/framework-init.ps1.
#>

[CmdletBinding()]
param(
    [Parameter(Position=0)]
    [ValidateSet('claude', 'codex', 'opencode', 'generic', 'ollama', 'all')]
    [string]$Harness = 'all',

    [string]$RepoRoot,

    [switch]$InstallCodexSkills,

    [switch]$InstallCodexPrompts
)

$ErrorActionPreference = 'Stop'

if (-not $RepoRoot) {
    $RepoRoot = Split-Path -Parent $PSScriptRoot
}

$target = Join-Path $RepoRoot '.KCC/tools/framework-init.ps1'
if (-not (Test-Path -LiteralPath $target)) {
    throw "Canonical tool not found: $target"
}

$argsForTool = @{
    Harness = $Harness
    RepoRoot = $RepoRoot
}
if ($InstallCodexSkills) { $argsForTool['InstallCodexSkills'] = $true }
if ($InstallCodexPrompts) { $argsForTool['InstallCodexPrompts'] = $true }

& $target @argsForTool
