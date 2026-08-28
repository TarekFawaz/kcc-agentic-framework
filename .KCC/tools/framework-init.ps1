<#
KCC framework (c) 2026 Tarek Fawaz, https://tikasway.dev/kcc. Licensed under the terms in LICENSE.

.SYNOPSIS
    First-run initializer for KCC v0.4.

.DESCRIPTION
    Creates the root orchestrator entrypoint(s), framework scaffolding
    (coordination maps, memory MOC/index, Traces MOC + session template), and
    requested harness adapter outputs from .KCC/kernel/ and .KCC/capabilities/.

    Runtime/state folders are NOT pre-created here. They are created lazily by
    the workflow that owns them, so a greenfield init never leaves empty,
    unused folders behind (the test6 fix). Lazy folder ownership:

      Folder                          Created by                  When
      ------------------------------  --------------------------  --------------------------
      ideation/                       idea-interrogator           first idea
      specs/                          spec-writer                 first spec
      src/IDEA-*                     implementer                 first implementation
      architecture/                   architect                   first architect pass
      Traces/Session-*                butler                      first run (session)
      coordination/backchannel.jsonl  backchannel-append.ps1      first event
      memory/{type}/                  memory-append.ps1           first entry
      solution/                       solution-onboard            onboarding existing code
      migrations/                     adapt-workflow              importing a workflow

    Framework scaffolding that IS created at init: root entrypoints, harness
    adapter outputs, coordination/ (MOC + orchestrator maps), memory/ (MOC +
    index + schema), and Traces/ (traces.md MOC + _session-template/).

    This is the recommended command for a clean folder that contains only:

      .KCC/kernel/
      .KCC/capabilities/
      .KCC/tools/
      QUICKSTART.md

    It delegates to .KCC/tools/sync-adapters.ps1 so first-run initialization and
    ongoing adapter regeneration stay on the same code path.

.PARAMETER Harness
    Which harness to initialize. One of: claude, codex, opencode, generic,
    ollama, dsh, all. Defaults to all.

.PARAMETER RepoRoot
    Optional repository root. Defaults to the parent of .KCC.

.PARAMETER InstallCodexSkills
    Explicitly request project-local Codex skill initialization. This does not
    write to ~/.codex.

.PARAMETER InstallCodexPrompts
    Deprecated/no-op compatibility flag. Global Codex installation belongs in
    a separate bootstrap pipeline.

.PARAMETER InstallDshProfile
    Print AND execute the explicit DSH hardened-profile installer
    (.KCC\adapters\dsh\install.ps1). Without this switch the dsh block only
    PRINTS the install command: framework-init never silently mutates
    DSH_HOME (Plan 08, Task 5).

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .KCC\tools\framework-init.ps1 -Harness codex

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .KCC\tools\framework-init.ps1 claude
#>

[CmdletBinding()]
param(
    [Parameter(Position=0)]
    [ValidateSet('claude', 'codex', 'opencode', 'generic', 'ollama', 'dsh', 'all')]
    [string]$Harness = 'all',

    [string]$RepoRoot,

    [switch]$InstallCodexSkills,

    [switch]$InstallCodexPrompts,

    [switch]$InstallDshProfile
)

$ErrorActionPreference = 'Stop'

function Resolve-RepoRootFromTool {
    if ($PSScriptRoot) {
        $toolDir = $PSScriptRoot
    } elseif ($MyInvocation.MyCommand.Path) {
        $toolDir = Split-Path -Parent $MyInvocation.MyCommand.Path
    } else {
        return (Get-Location).Path
    }

    $parent = Split-Path -Parent $toolDir
    if ((Split-Path -Leaf $parent) -eq '.KCC') {
        return (Split-Path -Parent $parent)
    }
    return $parent
}

if (-not $RepoRoot) {
    $RepoRoot = Resolve-RepoRootFromTool
}

$syncPath = Join-Path $RepoRoot '.KCC/tools/sync-adapters.ps1'
if (-not (Test-Path -LiteralPath $syncPath)) {
    $syncPath = Join-Path $RepoRoot 'tools/sync-adapters.ps1'
}
if (-not (Test-Path -LiteralPath $syncPath)) {
    throw "Could not find sync-adapters.ps1 at $syncPath"
}

$argsForSync = @{
    Harness = $Harness
    RepoRoot = $RepoRoot
}
if ($InstallCodexSkills) { $argsForSync['InstallCodexSkills'] = $true }
if ($InstallCodexPrompts) { $argsForSync['InstallCodexPrompts'] = $true }

Write-Host ''
Write-Host "Initializing spec-driven framework for harness: $Harness"
Write-Host ''

& $syncPath @argsForSync

if ($Harness -in @('dsh', 'all')) {
    Write-Host ''
    Write-Host 'dsh hardened profile (Plan 08, Task 5): the kcc-autobuild profile is'
    Write-Host 'NOT installed by default (no silent DSH_HOME mutation).'
    Write-Host ''
    $installScript = Join-Path $RepoRoot '.KCC\adapters\dsh\install.ps1'
    Write-Host "  install:    powershell -ExecutionPolicy Bypass -File `"$installScript`""
    Write-Host '  live proof: kcc-autobuild harness doctor dsh --live --template kcc-autobuild'
    Write-Host ''
    if ($InstallDshProfile) {
        Write-Host '[dsh      ] executing the explicit DSH profile installer:'
        & powershell -ExecutionPolicy Bypass -File $installScript
    } else {
        Write-Host '[dsh      ] profile installer NOT executed (re-run with -InstallDshProfile to install).'
    }
}

Write-Host ''
Write-Host 'Note: runtime folders (ideation/, specs/, src/, architecture/, solution/,'
Write-Host '      migrations/, Traces/Session-*, coordination/backchannel.jsonl,'
Write-Host '      memory/{type}/) are created lazily by the workflow that needs them,'
Write-Host '      not at init. See the lazy-folder table in this script header.'
