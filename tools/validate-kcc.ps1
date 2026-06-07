<#
KCC framework (c) 2026 Tarek Fawaz, https://tikasway.dev/kcc. Licensed under the terms in LICENSE.

.SYNOPSIS
    Compatibility wrapper for .KCC/tools/validate-kcc.ps1.
#>

[CmdletBinding()]
param(
    [string]$RepoRoot
)

$ErrorActionPreference = 'Stop'

if (-not $RepoRoot) {
    $RepoRoot = Split-Path -Parent $PSScriptRoot
}

$target = Join-Path $RepoRoot '.KCC/tools/validate-kcc.ps1'
if (-not (Test-Path -LiteralPath $target)) {
    throw "Canonical tool not found: $target"
}

& $target -RepoRoot $RepoRoot
