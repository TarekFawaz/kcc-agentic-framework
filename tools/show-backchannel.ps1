<#
KCC framework (c) 2026 Tarek Fawaz, https://tikasway.dev/kcc. Licensed under the terms in LICENSE.

.SYNOPSIS
    Compatibility wrapper for .KCC/tools/show-backchannel.ps1.
#>

[CmdletBinding()]
param(
    [int]$Last = 20,

    [string]$From,

    [string]$Kind,

    [string]$Spec,

    [string]$RepoRoot,

    [switch]$Json
)

$ErrorActionPreference = 'Stop'

if (-not $RepoRoot) {
    $RepoRoot = Split-Path -Parent $PSScriptRoot
}

$target = Join-Path $RepoRoot '.KCC/tools/show-backchannel.ps1'
if (-not (Test-Path -LiteralPath $target)) {
    throw "Canonical tool not found: $target"
}

$argsForTool = @{
    Last = $Last
    RepoRoot = $RepoRoot
}
if ($From) { $argsForTool['From'] = $From }
if ($Kind) { $argsForTool['Kind'] = $Kind }
if ($Spec) { $argsForTool['Spec'] = $Spec }
if ($Json) { $argsForTool['Json'] = $true }

& $target @argsForTool
