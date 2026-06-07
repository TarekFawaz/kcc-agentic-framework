<#
KCC framework (c) 2026 Tarek Fawaz, https://tikasway.dev/kcc. Licensed under the terms in LICENSE.

.SYNOPSIS
    Compatibility wrapper for .KCC/tools/start-agent-session.ps1.
#>

[CmdletBinding()]
param(
    [ValidateSet('claude', 'codex', 'opencode', 'cmd', 'powershell')]
    [string]$Harness = 'cmd',

    [Parameter(Mandatory)]
    [string]$Agent,

    [string]$RepoRoot,

    [string]$Title,

    [string]$Prompt,

    [string]$PromptFile,

    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

if (-not $RepoRoot) {
    $RepoRoot = Split-Path -Parent $PSScriptRoot
}

$target = Join-Path $RepoRoot '.KCC/tools/start-agent-session.ps1'
if (-not (Test-Path -LiteralPath $target)) {
    throw "Canonical tool not found: $target"
}

$argsForTool = @{
    Harness = $Harness
    Agent = $Agent
    RepoRoot = $RepoRoot
}
if ($Title) { $argsForTool['Title'] = $Title }
if ($Prompt) { $argsForTool['Prompt'] = $Prompt }
if ($PromptFile) { $argsForTool['PromptFile'] = $PromptFile }
if ($DryRun) { $argsForTool['DryRun'] = $true }

& $target @argsForTool
