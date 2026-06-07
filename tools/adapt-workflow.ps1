<#
KCC framework (c) 2026 Tarek Fawaz, https://tikasway.dev/kcc. Licensed under the terms in LICENSE.

.SYNOPSIS
    Compatibility wrapper for .KCC/tools/adapt-workflow.ps1.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$SourcePath,

    [ValidateSet('cursor', 'claude', 'codex', 'opencode', 'aider', 'generic', 'auto')]
    [string]$Format = 'auto',

    [ValidateSet('claude', 'codex', 'opencode', 'generic', 'ollama', 'all')]
    [string]$Harness = 'generic',

    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent $PSScriptRoot
$target = Join-Path $RepoRoot '.KCC/tools/adapt-workflow.ps1'
if (-not (Test-Path -LiteralPath $target)) {
    throw "Canonical tool not found: $target"
}

$argsForTool = @{
    SourcePath = $SourcePath
    Format = $Format
    Harness = $Harness
}
if ($DryRun) { $argsForTool['DryRun'] = $true }

& $target @argsForTool
