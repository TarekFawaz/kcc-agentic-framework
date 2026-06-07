<#
KCC framework (c) 2026 Tarek Fawaz, https://tikasway.dev/kcc. Licensed under the terms in LICENSE.

.SYNOPSIS
    Deterministically write one memory entry and update the memory index + MOC.

.DESCRIPTION
    Butler is the sole writer of memory/. This helper turns "store a memory
    entry" into a single deterministic command so memory curation can never be
    silently skipped. It allocates the next per-type id (DEC-/PAT-/INC-/PRE-/GLO-),
    writes memory/{type-plural}/{ID}.md with schema-1.1 frontmatter + body,
    appends a record to memory/index.json, and adds a row to the correct table
    in memory/memory.md. The new entry ID is printed.

    Body is supplied via -Body (raw markdown following the per-type section
    convention in memory/schema.md). The entry ID is printed.

    PowerShell 5.1 compatible. UTF-8 (no BOM) output. No && operator.

.PARAMETER Type
    One of: decision, pattern, incident, preference, glossary.

.PARAMETER Title
    Human-readable title (the "<ID> - " prefix is added automatically).

.PARAMETER Summary
    One-line summary (copied into the entry and the index).

.PARAMETER Tags
    Comma-separated topic tags. The memory/<type> tag is added automatically.

.PARAMETER RelatedSpecs
    Comma-separated SPEC-/IDEA-IDs, or empty.

.PARAMETER Body
    Markdown body following the per-type section convention in schema.md.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .KCC\tools\memory-append.ps1 -Type decision -Title "Use SQLite for tip store" -Summary "Tip calculator persists to SQLite, not flat files." -Tags "tech-stack,storage" -RelatedSpecs "SPEC-001" -Body "## Decision`nUse SQLite.`n`n## Context`n..."
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('decision','pattern','incident','preference','glossary')][string]$Type,
    [Parameter(Mandatory)][string]$Title,
    [Parameter(Mandatory)][string]$Summary,
    [string]$Tags,
    [string]$RelatedSpecs,
    [Parameter(Mandatory)][string]$Body,
    [string]$RepoRoot
)

$ErrorActionPreference = 'Stop'

function Resolve-RepoRootFromTool {
    if ($PSScriptRoot) { $toolDir = $PSScriptRoot }
    elseif ($MyInvocation.MyCommand.Path) { $toolDir = Split-Path -Parent $MyInvocation.MyCommand.Path }
    else { return (Get-Location).Path }
    $parent = Split-Path -Parent $toolDir
    if ((Split-Path -Leaf $parent) -eq '.KCC') { return (Split-Path -Parent $parent) }
    return $parent
}

if (-not $RepoRoot) { $RepoRoot = Resolve-RepoRootFromTool }

$map = @{
    decision   = @{ prefix = 'DEC'; folder = 'decisions' }
    pattern    = @{ prefix = 'PAT'; folder = 'patterns' }
    incident   = @{ prefix = 'INC'; folder = 'incidents' }
    preference = @{ prefix = 'PRE'; folder = 'preferences' }
    glossary   = @{ prefix = 'GLO'; folder = 'glossary' }
}
$prefix = $map[$Type].prefix
$folderName = $map[$Type].folder

$memDir = Join-Path $RepoRoot 'memory'
$typeDir = Join-Path $memDir $folderName
if (-not (Test-Path -LiteralPath $typeDir)) { New-Item -ItemType Directory -Path $typeDir | Out-Null }

# Allocate next per-type id by scanning existing entry files.
$maxNum = 0
Get-ChildItem -LiteralPath $typeDir -Filter "$prefix-*.md" -ErrorAction SilentlyContinue | ForEach-Object {
    if ($_.BaseName -match "^$prefix-(\d+)$") {
        $n = [int]$Matches[1]
        if ($n -gt $maxNum) { $maxNum = $n }
    }
}
$id = '{0}-{1:D3}' -f $prefix, ($maxNum + 1)

$nowIso = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
$today = (Get-Date).ToString('yyyy-MM-dd')

$tagList = @("memory/$Type")
if (-not [string]::IsNullOrWhiteSpace($Tags)) {
    foreach ($t in ($Tags -split ',')) { $tt = $t.Trim(); if ($tt) { $tagList += $tt } }
}
$specList = @()
if (-not [string]::IsNullOrWhiteSpace($RelatedSpecs)) {
    foreach ($s in ($RelatedSpecs -split ',')) { $ss = $s.Trim(); if ($ss) { $specList += $ss } }
}

# Build entry frontmatter + body per schema 1.1.
$sb = New-Object System.Text.StringBuilder
[void]$sb.AppendLine('---')
[void]$sb.AppendLine('# Functional fields (consumed by Butler and memory/index.json)')
[void]$sb.AppendLine("id: $id")
[void]$sb.AppendLine("type: $Type")
[void]$sb.AppendLine("created: $nowIso")
if ($specList.Count -gt 0) {
    [void]$sb.AppendLine('related-specs:')
    foreach ($s in $specList) { [void]$sb.AppendLine("  - $s") }
} else {
    [void]$sb.AppendLine('related-specs: []')
}
[void]$sb.AppendLine("summary: $Summary")
[void]$sb.AppendLine('')
[void]$sb.AppendLine('# Obsidian metadata (required for new entries under schema 1.1)')
[void]$sb.AppendLine("title: $id - $Title")
[void]$sb.AppendLine('tags:')
foreach ($t in $tagList) { [void]$sb.AppendLine("  - $t") }
[void]$sb.AppendLine("updated: $today")
[void]$sb.AppendLine('version: 1.0.0')
[void]$sb.AppendLine('status: active')
[void]$sb.AppendLine('---')
[void]$sb.AppendLine('')
[void]$sb.AppendLine("# $id - $Title")
[void]$sb.AppendLine('')
[void]$sb.AppendLine($Body)

$entryPath = Join-Path $typeDir "$id.md"
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($entryPath, $sb.ToString(), $utf8NoBom)

# Update memory/index.json.
$indexPath = Join-Path $memDir 'index.json'
if (Test-Path -LiteralPath $indexPath) {
    $index = Get-Content -LiteralPath $indexPath -Raw | ConvertFrom-Json
} else {
    $index = [pscustomobject]@{ entries = @(); last_updated = $null; schema_version = '1.1' }
}
$entriesList = New-Object System.Collections.ArrayList
if ($index.entries) { foreach ($e in $index.entries) { [void]$entriesList.Add($e) } }
[void]$entriesList.Add([ordered]@{
    id             = $id
    type           = $Type
    file           = "memory/$folderName/$id.md"
    created        = $nowIso
    'related-specs' = $specList
    tags           = $tagList
    summary        = $Summary
})
$index | Add-Member -NotePropertyName entries -NotePropertyValue @($entriesList) -Force
$index | Add-Member -NotePropertyName last_updated -NotePropertyValue $nowIso -Force
$index | Add-Member -NotePropertyName schema_version -NotePropertyValue '1.1' -Force
$indexJson = $index | ConvertTo-Json -Depth 12
[System.IO.File]::WriteAllText($indexPath, $indexJson, $utf8NoBom)

# Update memory/memory.md MOC: add a row under the correct type table.
$mocPath = Join-Path $memDir 'memory.md'
if (Test-Path -LiteralPath $mocPath) {
    $sectionHeader = @{
        decision   = '## Decisions'
        pattern    = '## Patterns'
        incident   = '## Incidents'
        preference = '## Preferences'
        glossary   = '## Glossary'
    }[$Type]
    $row = "| [[$id]] | $($id) - $Title | $([string]::Join(', ', $tagList)) | $([string]::Join(', ', $specList)) | $today |"
    $mocLines = @(Get-Content -LiteralPath $mocPath)
    $out = New-Object System.Collections.Generic.List[string]
    $inSection = $false
    $rowInserted = $false
    foreach ($l in $mocLines) {
        if ($l -match '^## ') { $inSection = ($l.Trim() -eq $sectionHeader) }
        if ($inSection -and -not $rowInserted -and $l -match '_No entries yet') {
            $out.Add($row)
            $rowInserted = $true
            continue
        }
        if ($inSection -and -not $rowInserted -and $l -match '^\|--') {
            $out.Add([string]$l)
            $out.Add($row)
            $rowInserted = $true
            continue
        }
        $out.Add([string]$l)
    }
    [System.IO.File]::WriteAllText($mocPath, ([string]::Join("`n", $out.ToArray()) + "`n"), $utf8NoBom)
}

Write-Output $id
