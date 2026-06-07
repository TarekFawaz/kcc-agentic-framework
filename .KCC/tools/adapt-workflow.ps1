<#
KCC framework (c) 2026 Tarek Fawaz, https://tikasway.dev/kcc. Licensed under the terms in LICENSE.

.SYNOPSIS
    Scaffold a new migration folder for importing an external agentic workflow.

.DESCRIPTION
    Deterministic scanner + scaffolder for the /adapt-workflow lifecycle.
    Scans a source path for canonical agentic-workflow markers (Cursor,
    Claude Code, Codex/OpenCode AGENTS.md, Aider, or generic prompts/agents
    folders), prints a detected-inventory table, allocates the next free
    migrations/IMPORT-{NNN}/ folder, and writes an empty plan.md plus the
    drafts/ subdirectory skeleton.

    This script does NOT do the semantic translation — that is the
    migrator agent's job via /adapt-workflow. The split keeps the script
    deterministic (file enumeration, folder allocation) and the agent
    bounded (mapping decisions, prose drafting).

    PowerShell 5.1 compatible. No '&&' operator. UTF-8 with BOM output.

.PARAMETER SourcePath
    Path to the external workflow root (file or directory). Required.

.PARAMETER Format
    Optional source-format hint. One of:
    cursor | claude | codex | opencode | aider | generic | auto
    Default: auto (the script attempts to detect from canonical files).

.PARAMETER DryRun
    Skip all writes. Print the detected inventory only.

.PARAMETER Harness
    Local harness infrastructure to initialize before writing migration
    scaffolding. One of: claude | codex | opencode | generic | ollama | all.
    Defaults to generic.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .KCC/tools/adapt-workflow.ps1 -SourcePath ../OtherProject

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .KCC/tools/adapt-workflow.ps1 -SourcePath ../OtherProject -Format cursor

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .KCC/tools/adapt-workflow.ps1 -SourcePath ../OtherProject -DryRun

.NOTES
    Run from the repo root:
        powershell -ExecutionPolicy Bypass -File .KCC/tools/adapt-workflow.ps1 -SourcePath <path>
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

# ---------- resolve repo root (PSScriptRoot fallback) ----------

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

$RepoRoot = Resolve-RepoRootFromTool

if (-not $DryRun) {
    $initPath = Join-Path $RepoRoot '.KCC/tools/framework-init.ps1'
    if (-not (Test-Path -LiteralPath $initPath)) {
        $initPath = Join-Path $RepoRoot 'tools/framework-init.ps1'
    }
    if (Test-Path -LiteralPath $initPath) {
        & $initPath -Harness $Harness -RepoRoot $RepoRoot
    } else {
        Write-Warning "framework-init.ps1 not found at $initPath; continuing without initialization."
    }
}

# ---------- validate source path ----------

if (-not (Test-Path -LiteralPath $SourcePath)) {
    Write-Error "Source path does not exist: $SourcePath"
    exit 1
}

$resolvedSource = (Resolve-Path -LiteralPath $SourcePath).ProviderPath
$sourceIsDir = (Get-Item -LiteralPath $resolvedSource).PSIsContainer

if ($sourceIsDir) {
    $anyFile = Get-ChildItem -LiteralPath $resolvedSource -Recurse -File -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $anyFile) {
        Write-Error "Source directory is empty: $resolvedSource"
        exit 1
    }
}

# ---------- detection ----------

function Test-PathSafe {
    param([string]$Root, [string]$Relative)
    $full = Join-Path $Root $Relative
    return (Test-Path -LiteralPath $full)
}

function Get-FilesSafe {
    param([string]$Root, [string]$Pattern, [switch]$Recurse)
    if (-not (Test-Path -LiteralPath $Root)) { return @() }
    try {
        if ($Recurse) {
            return @(Get-ChildItem -LiteralPath $Root -Filter $Pattern -Recurse -File -ErrorAction SilentlyContinue)
        } else {
            return @(Get-ChildItem -LiteralPath $Root -Filter $Pattern -File -ErrorAction SilentlyContinue)
        }
    } catch {
        return @()
    }
}

function Detect-Format {
    param([string]$Root)

    if (-not (Get-Item -LiteralPath $Root).PSIsContainer) {
        # single file — treat by extension / parent dir
        $parent = Split-Path -Parent $Root
        $name   = Split-Path -Leaf   $Root
        if ($name -like '*.mdc') { return 'cursor' }
        if ($name -ieq 'AGENTS.md') {
            if ((Test-PathSafe $parent '.opencode') -or (Test-PathSafe $parent 'opencode.toml')) {
                return 'opencode'
            }
            return 'codex'
        }
        if ($name -ieq 'AIDER.md') { return 'aider' }
        return 'generic'
    }

    if (Test-PathSafe $Root '.cursor/rules')         { return 'cursor' }
    if ((Test-PathSafe $Root '.claude/agents') -or (Test-PathSafe $Root '.claude/skills')) { return 'claude' }
    if (Test-PathSafe $Root 'AGENTS.md') {
        if ((Test-PathSafe $Root '.opencode') -or (Test-PathSafe $Root 'opencode.toml')) {
            return 'opencode'
        }
        return 'codex'
    }
    if ((Test-PathSafe $Root 'AIDER.md') -or (Test-PathSafe $Root '.aider.conf.yml')) { return 'aider' }
    if ((Test-PathSafe $Root 'prompts') -or (Test-PathSafe $Root 'agents'))           { return 'generic' }

    return 'unknown'
}

function Get-Inventory {
    param([string]$Root, [string]$Fmt)

    $items = New-Object System.Collections.ArrayList

    switch ($Fmt) {
        'cursor' {
            $dir = Join-Path $Root '.cursor/rules'
            foreach ($f in (Get-FilesSafe -Root $dir -Pattern '*.mdc' -Recurse)) {
                [void]$items.Add([pscustomobject]@{
                    Kind       = 'rule'
                    SourcePath = $f.FullName
                    Name       = [IO.Path]::GetFileNameWithoutExtension($f.Name)
                })
            }
        }
        'claude' {
            $aDir = Join-Path $Root '.claude/agents'
            foreach ($f in (Get-FilesSafe -Root $aDir -Pattern '*.md' -Recurse)) {
                [void]$items.Add([pscustomobject]@{
                    Kind       = 'agent'
                    SourcePath = $f.FullName
                    Name       = [IO.Path]::GetFileNameWithoutExtension($f.Name)
                })
            }
            $sDir = Join-Path $Root '.claude/skills'
            foreach ($f in (Get-FilesSafe -Root $sDir -Pattern 'SKILL.md' -Recurse)) {
                $skillName = Split-Path -Leaf (Split-Path -Parent $f.FullName)
                [void]$items.Add([pscustomobject]@{
                    Kind       = 'skill'
                    SourcePath = $f.FullName
                    Name       = $skillName
                })
            }
        }
        'codex' {
            $agentsMd = Join-Path $Root 'AGENTS.md'
            if (Test-Path -LiteralPath $agentsMd) {
                [void]$items.Add([pscustomobject]@{
                    Kind       = 'catalog'
                    SourcePath = $agentsMd
                    Name       = 'AGENTS.md'
                })
            }
        }
        'opencode' {
            $agentsMd = Join-Path $Root 'AGENTS.md'
            if (Test-Path -LiteralPath $agentsMd) {
                [void]$items.Add([pscustomobject]@{
                    Kind       = 'catalog'
                    SourcePath = $agentsMd
                    Name       = 'AGENTS.md'
                })
            }
        }
        'aider' {
            foreach ($candidate in @('AIDER.md', '.aider.conf.yml')) {
                $p = Join-Path $Root $candidate
                if (Test-Path -LiteralPath $p) {
                    [void]$items.Add([pscustomobject]@{
                        Kind       = 'conventions'
                        SourcePath = $p
                        Name       = $candidate
                    })
                }
            }
        }
        'generic' {
            foreach ($subdir in @('prompts', 'agents')) {
                $d = Join-Path $Root $subdir
                foreach ($f in (Get-FilesSafe -Root $d -Pattern '*.md' -Recurse)) {
                    [void]$items.Add([pscustomobject]@{
                        Kind       = $subdir.TrimEnd('s')
                        SourcePath = $f.FullName
                        Name       = [IO.Path]::GetFileNameWithoutExtension($f.Name)
                    })
                }
            }
        }
        default { }
    }

    return @($items)
}

# ---------- determine format ----------

$effectiveFormat = $Format
if ($effectiveFormat -eq 'auto') {
    $effectiveFormat = Detect-Format -Root $resolvedSource
}

Write-Host ''
Write-Host '=== adapt-workflow scaffolder ==='
Write-Host ("Source:        {0}" -f $resolvedSource)
Write-Host ("Hint:          {0}" -f $Format)
Write-Host ("Effective fmt: {0}" -f $effectiveFormat)

if ($effectiveFormat -eq 'unknown') {
    Write-Warning 'Could not detect a known agentic-workflow format.'
    Write-Warning 'Re-run with -Format <cursor|claude|codex|opencode|aider|generic>'
    Write-Warning 'or invoke /adapt-workflow and let the migrator agent ask the human.'
    exit 2
}

# ---------- inventory ----------

$inventory = @(Get-Inventory -Root $resolvedSource -Fmt $effectiveFormat)

Write-Host ''
Write-Host ("Detected {0} item(s):" -f $inventory.Count)
if ($inventory.Count -gt 0) {
    $inventory | Format-Table -AutoSize Kind, Name, SourcePath | Out-String | Write-Host
} else {
    Write-Host '  (none — the migrator agent will need to be told what to look at)'
}

if ($DryRun) {
    Write-Host ''
    Write-Host 'DryRun: skipping folder allocation and file writes.'
    exit 0
}

# ---------- allocate IMPORT-{NNN} ----------

$migrationsRoot = Join-Path $RepoRoot 'migrations'
if (-not (Test-Path -LiteralPath $migrationsRoot)) {
    New-Item -ItemType Directory -Force -Path $migrationsRoot | Out-Null
}

$existing = @(Get-ChildItem -LiteralPath $migrationsRoot -Directory -Filter 'IMPORT-*' -ErrorAction SilentlyContinue)
$maxN = 0
foreach ($d in $existing) {
    if ($d.Name -match '^IMPORT-(\d{3,})$') {
        $n = [int]$Matches[1]
        if ($n -gt $maxN) { $maxN = $n }
    }
}
$nextN = $maxN + 1
$importId = 'IMPORT-{0:D3}' -f $nextN
$importDir = Join-Path $migrationsRoot $importId

New-Item -ItemType Directory -Force -Path $importDir | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $importDir 'drafts/agents') | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $importDir 'drafts/skills') | Out-Null

# ---------- write skeleton plan.md ----------

$nowIso = (Get-Date).ToString('yyyy-MM-ddTHH:mm:sszzz')
$planLines = New-Object System.Collections.ArrayList

[void]$planLines.Add('---')
[void]$planLines.Add('title: Migration Plan ' + $importId)
[void]$planLines.Add('tags:')
[void]$planLines.Add('  - migration')
[void]$planLines.Add('  - lifecycle/meta')
[void]$planLines.Add('status: scaffolded')
[void]$planLines.Add('created: ' + $nowIso)
[void]$planLines.Add('---')
[void]$planLines.Add('')
[void]$planLines.Add('# Migration Plan: ' + $importId)
[void]$planLines.Add('')
[void]$planLines.Add('_Scaffolded by `.KCC/tools/adapt-workflow.ps1`. The migrator agent populates the rest._')
[void]$planLines.Add('')
[void]$planLines.Add('## Source')
[void]$planLines.Add('')
[void]$planLines.Add('- Path: `' + $resolvedSource + '`')
[void]$planLines.Add('- Format (hint): `' + $Format + '`')
[void]$planLines.Add('- Format (detected): `' + $effectiveFormat + '`')
[void]$planLines.Add('')
[void]$planLines.Add('## Inventory (pre-mapping)')
[void]$planLines.Add('')
[void]$planLines.Add('| Kind | Name | Source path |')
[void]$planLines.Add('|------|------|-------------|')
foreach ($it in $inventory) {
    [void]$planLines.Add(('| {0} | {1} | `{2}` |' -f $it.Kind, $it.Name, $it.SourcePath))
}
if ($inventory.Count -eq 0) {
    [void]$planLines.Add('| _none_ | | _migrator agent to investigate_ |')
}
[void]$planLines.Add('')
[void]$planLines.Add('## Mapping decisions')
[void]$planLines.Add('')
[void]$planLines.Add('_(to be filled by migrator)_')
[void]$planLines.Add('')
[void]$planLines.Add('## Items needing human input')
[void]$planLines.Add('')
[void]$planLines.Add('_(to be filled by migrator)_')
[void]$planLines.Add('')
[void]$planLines.Add('## Recommended order of import')
[void]$planLines.Add('')
[void]$planLines.Add('_(to be filled by migrator)_')
[void]$planLines.Add('')

$planContent = ($planLines -join "`r`n") + "`r`n"
$planPath = Join-Path $importDir 'plan.md'

# UTF-8 with BOM, CRLF — Set-Content -Encoding utf8 writes BOM on PS 5.1
Set-Content -LiteralPath $planPath -Value $planContent -Encoding utf8 -NoNewline

# Drop a README in drafts/ so the empty subdirs survive in git
$draftsReadme = @'
This folder will hold migration-draft agent and skill files written by the migrator agent.

Drafts are never auto-promoted. Review them in place, then move accepted files into
.KCC/capabilities/agents/ or .KCC/capabilities/skills/ and rerun .KCC/tools/sync-adapters.ps1.
'@
$draftsReadmePath = Join-Path $importDir 'drafts/README.md'
Set-Content -LiteralPath $draftsReadmePath -Value $draftsReadme -Encoding utf8 -NoNewline

# ---------- summary ----------

Write-Host ''
Write-Host ('Created scaffold: {0}' -f $importDir)
Write-Host ('  plan.md           : {0}' -f $planPath)
Write-Host ('  drafts/agents/    : empty (migrator fills)')
Write-Host ('  drafts/skills/    : empty (migrator fills)')
Write-Host ''
Write-Host 'Next step:'
Write-Host ('  Run /adapt-workflow "{0}" --format={1}' -f $resolvedSource, $effectiveFormat)
Write-Host '  The migrator agent will perform the semantic mapping and populate'
Write-Host '  plan.md, mapping.md, and drafts/. Promote drafts manually afterward.'
Write-Host ''
