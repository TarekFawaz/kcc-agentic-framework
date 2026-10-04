<#
KCC framework (c) 2026 Tarek Fawaz, https://tikasway.dev/kcc. Licensed under the terms in LICENSE.

.SYNOPSIS
    Deterministic conformance linter over a KCC run's OUTPUT (not the framework).

.DESCRIPTION
    Checks that a generated cell's run artifacts conform to the agreed structure,
    so the `auto` orchestrator can gate on real facts instead of agent good faith.
    This is the mechanical half of the self-healing gates: agents drift under
    `--silent --assume --parallel`; this tool catches the drift.

    Checks (by scope):
      architecture - architecture/architecture.md exists, is non-trivial, and has
                     >=1 fenced ```mermaid``` block; zero *.mmd files under
                     architecture/; no architecture/README.md hub; every spec
                     arch.md has >=1 fenced ```mermaid``` block.
      linking      - idea file wikilinks its specs index; specs index wikilinks
                     the idea and each SPEC; SPEC note wikilinks its Backlog items
                     and architecture.md; specs contain no architecture/README
                     reference and no bare-relative architecture path.
      trace        - the most recent Traces/Session-*/ has the 7 canonical files.
      memory       - when substantive decisions were made (ADRs/specs/gate),
                     memory/decisions or memory/preferences is non-empty.
      token        - the latest trace session records an actual token row.
      idea         - IDEA-001..005: idea file sections, 7 artifacts, ROI confidence.
      specs        - SPEC-001..007, SPEC-LEGACY, SZ-2, SZ-3, SZ-5 (spec-layout v6).
      plan         - PLAN-001..005, SZ-4 (waves, atomic tests, AC coverage).
      review       - REV-001..005 (verdict, evidence, traceability, open bugs).
      bugs         - BUG-001..004 (bug table fields, enums, regression tests).

    Read-only. PowerShell 5.1 compatible. No && operator. See
    kernel/contracts/tool-contract.md for the CLI / exit-code / JSON contract.

.PARAMETER RepoRoot
    Workspace root to check. Defaults to the parent of .KCC.

.PARAMETER Scope
    all | architecture | linking | trace | memory | token | idea | specs | plan | review | bugs.

.PARAMETER Spec
    Limit specs/plan/review/bugs checks to one spec (SPEC-001 or SPEC-001-slug).

.PARAMETER Json
    Emit one JSON object (tool contract shape) on stdout.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .KCC\tools\check-run-conformance.ps1 -Scope specs -Spec SPEC-001 -Json
#>

[CmdletBinding()]
param(
    [string]$RepoRoot,
    [string]$Scope = 'all',
    [string]$Spec,
    [switch]$Json
)

$ErrorActionPreference = 'Stop'
$ToolVersion = '2.0.0'
$validScopes = @('all', 'architecture', 'linking', 'trace', 'memory', 'token', 'idea', 'specs', 'plan', 'review', 'bugs')
if ($validScopes -notcontains $Scope) {
    [Console]::Error.WriteLine(("unknown scope: {0} (valid: {1})" -f $Scope, ($validScopes -join ', ')))
    exit 2
}

if ($PSScriptRoot) { $ToolDir = $PSScriptRoot } else { $ToolDir = Split-Path -Parent $MyInvocation.MyCommand.Path }

function Resolve-RepoRootFromTool {
    $parent = Split-Path -Parent $ToolDir
    if ((Split-Path -Leaf $parent) -eq '.KCC') { return (Split-Path -Parent $parent) }
    return $parent
}
if (-not $RepoRoot) { $RepoRoot = Resolve-RepoRootFromTool }
if (-not (Test-Path -LiteralPath $RepoRoot)) {
    [Console]::Error.WriteLine("workspace not found: $RepoRoot")
    exit 2
}
$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path.TrimEnd('\', '/')

$violations = New-Object System.Collections.ArrayList

function Add-Violation {
    param(
        [string]$Code,
        [ValidateSet('error', 'warning')] [string]$Severity,
        [string]$Owner,
        [string]$Message,
        [string]$File = ''
    )
    [void]$violations.Add([pscustomobject]@{
            id        = $Code
            code      = $Code
            severity  = $Severity
            fix_owner = $Owner
            owner     = $Owner
            file      = $File
            message   = $Message
        })
}

function Read-Text([string]$path) {
    try { return [System.IO.File]::ReadAllText($path) } catch { return '' }
}

function Read-Lines([string]$path) {
    try { return , ([string[]][System.IO.File]::ReadAllLines($path)) } catch { return , ([string[]]@()) }
}

function Test-HasMermaid([string]$text) {
    return ($text -match '(?m)^\s*```mermaid')
}

function Get-RelPath([string]$full) {
    if ($full.Length -le $RepoRoot.Length) { return $full }
    return ($full.Substring($RepoRoot.Length)).TrimStart('\', '/').Replace('\', '/')
}

$archDir = Join-Path $RepoRoot 'architecture'
$specsDir = Join-Path $RepoRoot 'specs'
$ideationDir = Join-Path $RepoRoot 'ideation'
$tracesDir = Join-Path $RepoRoot 'Traces'
$memoryDir = Join-Path $RepoRoot 'memory'

# ---------------------------------------------------------------------------
# Settings (spec_sizing)
# ---------------------------------------------------------------------------
$MaxItems = 6; $MaxFiles = 5; $MaxTests = 8; $MaxSpecLines = 150
$settingsPath = Join-Path (Join-Path $RepoRoot '.KCC') 'settings.json'
if (Test-Path -LiteralPath $settingsPath) {
    $st = Read-Text $settingsPath
    $m = [regex]::Match($st, '"max_items"\s*:\s*(\d+)'); if ($m.Success) { $MaxItems = [int]$m.Groups[1].Value }
    $m = [regex]::Match($st, '"max_files_per_item"\s*:\s*(\d+)'); if ($m.Success) { $MaxFiles = [int]$m.Groups[1].Value }
    $m = [regex]::Match($st, '"max_tests_per_item"\s*:\s*(\d+)'); if ($m.Success) { $MaxTests = [int]$m.Groups[1].Value }
    $m = [regex]::Match($st, '"max_spec_lines"\s*:\s*(\d+)'); if ($m.Success) { $MaxSpecLines = [int]$m.Groups[1].Value }
}

# ---------------------------------------------------------------------------
# Markdown helpers (mirrored 1:1 in check-run-conformance.sh)
# ---------------------------------------------------------------------------
function Test-Heading([string[]]$Lines, [string]$Heading) {
    foreach ($l in $Lines) {
        if ($l -match ('^##\s+' + $Heading)) { return $true }
    }
    return $false
}

# Lines between '## <Heading...>' and the next '## ' heading (### stays inside).
function Get-Section([string[]]$Lines, [string]$Heading) {
    $out = New-Object System.Collections.ArrayList
    $inside = $false
    foreach ($l in $Lines) {
        if ($l -match '^##\s') {
            if ($inside) { break }
            $t = ($l -replace '^##\s+', '').Trim()
            if ($t -match ('^' + $Heading)) { $inside = $true }
            continue
        }
        if ($inside) { [void]$out.Add($l) }
    }
    return , ([string[]]$out.ToArray())
}

function Get-CellTrim([string]$s) {
    return ($s -replace '^[\s\*`]+', '' -replace '[\s\*`]+$', '')
}

function Test-SeparatorRow([string]$l) { return ($l -match '^\s*\|[\s:|-]*$') }

# Value of column $Col in the first data row of the first table in $Lines.
function Get-KeyTableField([string[]]$Lines, [string]$Col) {
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        if ($Lines[$i] -match '^\s*\|') {
            $hdr = $Lines[$i].Replace('\|', '/').Split('|')
            $idx = -1
            for ($c = 0; $c -lt $hdr.Count; $c++) {
                if ((Get-CellTrim $hdr[$c]).ToLower() -eq $Col.ToLower()) { $idx = $c; break }
            }
            if ($idx -lt 0) { return $null }
            $j = $i + 1
            while ($j -lt $Lines.Count -and (Test-SeparatorRow $Lines[$j])) { $j++ }
            if ($j -ge $Lines.Count -or $Lines[$j] -notmatch '^\s*\|') { return '' }
            $row = $Lines[$j].Replace('\|', '/').Split('|')
            if ($idx -ge $row.Count) { return '' }
            return (Get-CellTrim $row[$idx])
        }
    }
    return $null
}

function Get-StatusRank([string]$s) {
    if (-not $s) { return -1 }
    $t = $s.ToLower().Trim()
    if ($t -match '^draft') { return 0 }
    if ($t -match '^ready') { return 1 }
    if ($t -match '^(planned|planning)') { return 2 }
    if ($t -match '^(in[ -]?progress|implement)') { return 3 }
    if ($t -match '^(testing|test|review|in[ -]?review|verif)') { return 4 }
    if ($t -match '^(done|complete|closed|delivered)') { return 5 }
    return -1
}

function Get-SpecStatus($sp) {
    $lines = Read-Lines $sp.File
    $v = Get-KeyTableField $lines 'Status'
    if ($v) { return $v }
    $m = [regex]::Match((Read-Text $sp.File), '(?m)^status:\s*"?([^"\r\n]+)')
    if ($m.Success) { return $m.Groups[1].Value.Trim() }
    return ''
}

function Get-BacklogDir([string]$specDir) {
    # Return the on-disk folder (Backlog preferred, legacy backlog accepted) with its real casing.
    $cands = @(Get-ChildItem -LiteralPath $specDir -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -ieq 'backlog' })
    if ($cands.Count -eq 0) { return $null }
    foreach ($c in $cands) { if ($c.Name -ceq 'Backlog') { return $c.FullName } }
    return $cands[0].FullName
}

# Backlog item files keyed by Story-NNN / Enabler-NNN / Bug-NNN.
function Get-Items($sp) {
    $out = New-Object System.Collections.ArrayList
    $bd = Get-BacklogDir $sp.Dir
    if (-not $bd) { return , @() }
    foreach ($f in @(Get-ChildItem -LiteralPath $bd -File -Filter '*.md' -ErrorAction SilentlyContinue | Sort-Object Name)) {
        $m = [regex]::Match($f.Name, '^(Story|Enabler|Bug)-\d+')
        if ($m.Success) {
            [void]$out.Add([pscustomobject]@{ Key = $m.Value; Type = $m.Groups[1].Value; File = $f.FullName })
        }
    }
    return , ($out.ToArray())
}

function Get-ItemACs([string]$file) {
    $acs = New-Object System.Collections.ArrayList
    foreach ($l in (Get-Section (Read-Lines $file) 'acceptance criteria')) {
        $m = [regex]::Match($l, '^\s*[-*]\s*(\[[ xX]\]\s*)?\**\s*(AC-\d+)')
        if ($m.Success -and -not $acs.Contains($m.Groups[2].Value)) { [void]$acs.Add($m.Groups[2].Value) }
    }
    return , ([string[]]$acs.ToArray())
}

function Get-ImpactedFiles([string]$file) {
    $out = New-Object System.Collections.ArrayList
    foreach ($l in (Get-Section (Read-Lines $file) 'impacted files')) {
        if ($l -match '^\s*[-*]\s+\S') {
            $m = [regex]::Match($l, '`([^`]+)`')
            if ($m.Success) { $p = $m.Groups[1].Value }
            else { $p = (($l -replace '^\s*[-*]\s+', '').Trim() -split '\s+')[0] }
            $p = $p.Trim().Replace('\', '/')
            if ($p.StartsWith('./')) { $p = $p.Substring(2) }
            [void]$out.Add($p)
        }
    }
    return , ([string[]]$out.ToArray())
}

# Atomic test rows from plan.md: Id, Item, AC.
function Get-PlanTests([string]$planFile) {
    $out = New-Object System.Collections.ArrayList
    if (-not (Test-Path -LiteralPath $planFile)) { return , @() }
    $ti = -1; $ii = -1; $ai = -1; $hdr = $false
    foreach ($l in (Get-Section (Read-Lines $planFile) 'atomic test cases')) {
        if ($l -notmatch '^\s*\|') { continue }
        $cells = $l.Split('|')
        if (-not $hdr) {
            for ($c = 0; $c -lt $cells.Count; $c++) {
                $t = (Get-CellTrim $cells[$c]).ToLower()
                if ($t -eq 'test id') { $ti = $c } elseif ($t -eq 'item') { $ii = $c } elseif ($t -eq 'ac') { $ai = $c }
            }
            $hdr = $true
            continue
        }
        if (Test-SeparatorRow $l) { continue }
        if ($ti -lt 0 -or $ti -ge $cells.Count) { continue }
        $id = Get-CellTrim $cells[$ti]
        if (-not $id) { continue }
        $item = ''
        if ($ii -ge 0 -and $ii -lt $cells.Count) {
            $m = [regex]::Match($cells[$ii], '(Story|Enabler|Bug)-\d+'); if ($m.Success) { $item = $m.Value }
        }
        $ac = ''
        if ($ai -ge 0 -and $ai -lt $cells.Count) { $ac = Get-CellTrim $cells[$ai] }
        [void]$out.Add([pscustomobject]@{ Id = $id; Item = $item; AC = $ac })
    }
    return , ($out.ToArray())
}

# Wave assignments: list of {Wave, Item}. Source: plan.md ## Waves, else legacy parallelization.md.
function Get-Waves($sp) {
    $lines = @()
    $plan = Join-Path $sp.Dir 'plan.md'
    if (Test-Path -LiteralPath $plan) { $lines = Get-Section (Read-Lines $plan) 'waves' }
    if ($lines.Count -eq 0) {
        $par = Join-Path $sp.Dir 'parallelization.md'
        if (Test-Path -LiteralPath $par) {
            $pl = Read-Lines $par
            $lines = Get-Section $pl 'waves'
            if ($lines.Count -eq 0) { $lines = $pl }
        }
    }
    return , (ConvertTo-WaveList $lines)
}

function ConvertTo-WaveList([string[]]$Lines) {
    $out = New-Object System.Collections.ArrayList
    $cur = ''
    $waveCol = -1
    $excl = @{}
    $keyRx = '(Story|Enabler|Bug)-\d+'
    foreach ($l in $Lines) {
        $low = $l.ToLower()
        $mh = [regex]::Match($low, '^###+\s*wave\s*(\d+)')
        if ($mh.Success) { $cur = [string][int]$mh.Groups[1].Value; continue }
        $w = ''
        $src = New-Object System.Collections.ArrayList
        if ($l -match '^\s*\|') {
            if (Test-SeparatorRow $l) { continue }
            $cells = $l.Split('|')
            if (-not [regex]::IsMatch($l, $keyRx)) {
                # header row: remember wave column and dependency columns
                $waveCol = -1; $excl = @{}
                for ($c = 0; $c -lt $cells.Count; $c++) {
                    $t = (Get-CellTrim $cells[$c]).ToLower()
                    if ($t -eq 'wave' -and $waveCol -lt 0) { $waveCol = $c }
                    if ($t -match 'depend|block|after') { $excl[$c] = $true }
                }
                continue
            }
            if ($waveCol -ge 0 -and $waveCol -lt $cells.Count) {
                $t = (Get-CellTrim $cells[$waveCol]).ToLower()
                $mw = [regex]::Match($t, '^(wave\s*)?(\d+)$'); if ($mw.Success) { $w = [string][int]$mw.Groups[2].Value }
            }
            if (-not $w) {
                for ($c = 0; $c -lt $cells.Count; $c++) {
                    $t = (Get-CellTrim $cells[$c]).ToLower()
                    $mw = [regex]::Match($t, '^(wave\s*)?(\d+)$')
                    if ($mw.Success) { $w = [string][int]$mw.Groups[2].Value; break }
                }
            }
            for ($c = 0; $c -lt $cells.Count; $c++) { if (-not $excl.ContainsKey($c)) { [void]$src.Add($cells[$c]) } }
        }
        else {
            $mw = [regex]::Match($low, 'wave\s*(\d+)')
            if ($mw.Success) { $w = [string][int]$mw.Groups[1].Value }
            [void]$src.Add($l)
        }
        if (-not $w) { $w = $cur }
        if (-not $w) { continue }
        foreach ($s in $src) {
            foreach ($mk in [regex]::Matches($s, $keyRx)) {
                [void]$out.Add([pscustomobject]@{ Wave = $w; Item = $mk.Value })
            }
        }
    }
    return , ($out.ToArray())
}

function Get-Bug([string]$file) {
    $lines = Read-Lines $file
    $b = @{}
    foreach ($f in @('Source', 'Severity', 'Status', 'Story / AC', 'Regression test')) {
        $b[$f] = Get-KeyTableField $lines $f
    }
    return $b
}

function Get-ReviewVerdict([string]$reviewFile) {
    if (-not (Test-Path -LiteralPath $reviewFile)) { return '' }
    foreach ($l in (Read-Lines $reviewFile)) {
        if ($l -match '(?i)verdict') {
            $m = [regex]::Match($l, '(?i)\b(CHANGES_NEEDED|APPROVED|toolchain-deferred|quality-deferred)\b')
            if ($m.Success) { return $m.Groups[1].Value.ToUpper().Replace('-', '_') }
        }
    }
    return ''
}

# All spec folders: specs/**/SPEC-*/<same-name>.md
function Get-AllSpecs {
    $out = New-Object System.Collections.ArrayList
    if (-not (Test-Path -LiteralPath $specsDir)) { return , @() }
    foreach ($d in @(Get-ChildItem -LiteralPath $specsDir -Recurse -Directory -Filter 'SPEC-*' -ErrorAction SilentlyContinue | Sort-Object FullName)) {
        $note = Join-Path $d.FullName ($d.Name + '.md')
        if (-not (Test-Path -LiteralPath $note)) { continue }
        $m = [regex]::Match($d.Name, '^SPEC-\d+')
        if (-not $m.Success) { continue }
        $group = Split-Path -Parent $d.FullName
        $mi = [regex]::Match((Split-Path -Leaf $group), '^IDEA-\d+')
        $ideaId = ''
        if ($mi.Success) { $ideaId = $mi.Value }
        [void]$out.Add([pscustomobject]@{
                Id     = $m.Value
                Name   = $d.Name
                Dir    = $d.FullName
                File   = $note
                Group  = $group
                IdeaId = $ideaId
                Legacy = (Test-Path -LiteralPath (Join-Path $d.FullName 'backlog.md'))
            })
    }
    return , ($out.ToArray())
}

function Test-SpecMatch($sp) {
    if (-not $Spec) { return $true }
    $s = $Spec.ToLower()
    $n = $sp.Name.ToLower()
    return (($n -eq $s) -or $n.StartsWith($s + '-') -or ($sp.Id.ToLower() -eq $s))
}

$script:AllSpecs = $null
function Get-TargetSpecs {
    if ($null -eq $script:AllSpecs) { $script:AllSpecs = Get-AllSpecs }
    return , @($script:AllSpecs | Where-Object { Test-SpecMatch $_ })
}

# ---------------------------------------------------------------------------
# ARCHITECTURE
# ---------------------------------------------------------------------------
function Invoke-ArchitectureChecks {
    if (-not (Test-Path -LiteralPath $archDir)) { return }

    # Only judge a "populated" architecture folder (real run output).
    $adrs = @(Get-ChildItem -LiteralPath $archDir -Recurse -File -Filter '*.md' -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -ne '.gitkeep' })
    $mmd = @(Get-ChildItem -LiteralPath $archDir -Recurse -File -Filter '*.mmd' -ErrorAction SilentlyContinue)
    $populated = ($adrs.Count -gt 0) -or ($mmd.Count -gt 0)
    if (-not $populated) { return }

    $archDoc = Join-Path $archDir 'architecture.md'
    if (-not (Test-Path -LiteralPath $archDoc)) {
        Add-Violation 'ARCH-001' 'error' 'architect' 'architecture/architecture.md is missing. The Architecture Document must exist (not a README hub).' 'architecture/architecture.md'
    }
    else {
        $text = Read-Text $archDoc
        if ($text.Length -lt 800) {
            Add-Violation 'ARCH-002a' 'error' 'architect' ("architecture/architecture.md is a stub ({0} bytes). It must be a narrative document with embedded diagrams." -f $text.Length) 'architecture/architecture.md'
        }
        if (-not (Test-HasMermaid $text)) {
            Add-Violation 'ARCH-002b' 'error' 'architect' 'architecture/architecture.md contains no embedded ```mermaid``` block. Diagrams must be embedded inline.' 'architecture/architecture.md'
        }
    }

    foreach ($f in $mmd) {
        Add-Violation 'ARCH-003' 'error' 'architect' ("Deprecated loose diagram file: {0}. Embed fenced ```mermaid``` in a .md instead." -f (Get-RelPath $f.FullName)) (Get-RelPath $f.FullName)
    }

    foreach ($name in @('README.md', 'readme.md')) {
        $readme = Join-Path $archDir $name
        if (Test-Path -LiteralPath $readme) {
            Add-Violation 'ARCH-004' 'error' 'architect' ("architecture/{0} must not exist - the Architecture Document is architecture.md, not a README hub." -f $name) ('architecture/' + $name)
            break
        }
    }

    if (Test-Path -LiteralPath $specsDir) {
        $specArchFiles = @(Get-ChildItem -LiteralPath $specsDir -Recurse -File -Filter 'arch.md' -ErrorAction SilentlyContinue)
        foreach ($sa in $specArchFiles) {
            $t = Read-Text $sa.FullName
            if (-not (Test-HasMermaid $t)) {
                Add-Violation 'ARCH-005' 'error' 'architect' ("{0} has no embedded ```mermaid``` block (content bar). Spec arch.md must embed its design slice." -f (Get-RelPath $sa.FullName)) (Get-RelPath $sa.FullName)
            }
        }
    }
}

# ---------------------------------------------------------------------------
# LINKING (Obsidian graph)
# ---------------------------------------------------------------------------
function Invoke-LinkingChecks {
    if (-not (Test-Path -LiteralPath $ideationDir)) { return }

    $ideaFiles = @(Get-ChildItem -LiteralPath $ideationDir -Recurse -File -Filter 'idea-*.md' -ErrorAction SilentlyContinue)
    foreach ($idea in $ideaFiles) {
        $t = Read-Text $idea.FullName
        if ($t -notmatch '\[\[[^\]]*-Specs') {
            Add-Violation 'LINK-001' 'error' 'idea-interrogator' ("{0} does not wikilink its specs index ([[...-Specs...]]). Idea must connect to its specs in the graph." -f (Get-RelPath $idea.FullName)) (Get-RelPath $idea.FullName)
        }
    }

    if (-not (Test-Path -LiteralPath $specsDir)) { return }

    $indexFiles = @(Get-ChildItem -LiteralPath $specsDir -Recurse -File -Filter 'IDEA-*-Specs.md' -ErrorAction SilentlyContinue)
    foreach ($idx in $indexFiles) {
        $t = Read-Text $idx.FullName
        if ($t -notmatch '\[\[[^\]]*ideation') {
            Add-Violation 'LINK-002' 'error' 'spec-writer' ("{0} does not wikilink back to its idea ([[...ideation...]])." -f (Get-RelPath $idx.FullName)) (Get-RelPath $idx.FullName)
        }
        if ($t -notmatch '\[\[[^\]]*SPEC-') {
            Add-Violation 'LINK-003' 'error' 'spec-writer' ("{0} does not wikilink any SPEC folder note." -f (Get-RelPath $idx.FullName)) (Get-RelPath $idx.FullName)
        }
    }

    $specNotes = @(Get-ChildItem -LiteralPath $specsDir -Recurse -File -Filter 'SPEC-*.md' -ErrorAction SilentlyContinue |
            Where-Object { (Split-Path -Leaf (Split-Path -Parent $_.FullName)) -eq ($_.BaseName) })
    foreach ($note in $specNotes) {
        $t = Read-Text $note.FullName
        $rel = Get-RelPath $note.FullName
        $stripped = [regex]::Replace($t, '\[\[[^\]]*\]\]', '')
        if ($t -match 'architecture[\\/](README|readme)') {
            Add-Violation 'LINK-004' 'error' 'spec-writer' ("{0} references architecture/README - link [[...architecture/architecture]] instead." -f $rel) $rel
        }
        if ($stripped -match '(?m)\.\.[\\/].*architecture[\\/]') {
            Add-Violation 'LINK-005' 'error' 'spec-writer' ("{0} uses bare (non-wikilink) relative architecture paths - use [[wikilinks]] so the graph connects." -f $rel) $rel
        }
        if ($t -notmatch '\[\[[^\]]*architecture') {
            Add-Violation 'LINK-006' 'error' 'spec-writer' ("{0} does not wikilink the Architecture Document ([[...architecture/architecture]])." -f $rel) $rel
        }
        if ($t -notmatch '\[\[[^\]]*(Story|Enabler)-') {
            Add-Violation 'LINK-007' 'error' 'spec-writer' ("{0} does not wikilink its stories/enablers." -f $rel) $rel
        }
    }
}

# ---------------------------------------------------------------------------
# TRACE
# ---------------------------------------------------------------------------
function Invoke-TraceChecks {
    if (-not (Test-Path -LiteralPath $tracesDir)) { return }
    $sessions = @(Get-ChildItem -LiteralPath $tracesDir -Directory -Filter 'Session-*' -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending)
    if ($sessions.Count -eq 0) {
        Add-Violation 'TRACE-000' 'error' 'butler' 'No Traces/Session-* folder exists. Butler must create a trace session at run start.' 'Traces'
        return
    }
    $latest = $sessions[0]
    $required = @('Decisions.md', 'Handovers.md', 'Actions.md', 'ToolsUsed.md', 'HumanActions.md', 'HumanDecisions.md', 'TokenUsage.md')
    foreach ($r in $required) {
        if (-not (Test-Path -LiteralPath (Join-Path $latest.FullName $r))) {
            Add-Violation 'TRACE-001' 'error' 'butler' ("Trace session {0} is missing canonical file {1}. Copy _session-template and use the 7 canonical files." -f $latest.Name, $r) ('Traces/' + $latest.Name)
        }
    }
}

function Test-SubstantiveRun {
    $hasArch = (Test-Path -LiteralPath $archDir) -and (@(Get-ChildItem -LiteralPath $archDir -Recurse -File -Filter '*.md' -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne '.gitkeep' }).Count -gt 0)
    $hasSpecs = (Test-Path -LiteralPath $specsDir) -and (@(Get-ChildItem -LiteralPath $specsDir -Recurse -File -Filter 'SPEC-*.md' -ErrorAction SilentlyContinue).Count -gt 0)
    return ($hasArch -or $hasSpecs)
}

# ---------------------------------------------------------------------------
# MEMORY
# ---------------------------------------------------------------------------
function Invoke-MemoryChecks {
    if (-not (Test-Path -LiteralPath $memoryDir)) { return }
    if (-not (Test-SubstantiveRun)) { return }

    $decDir = Join-Path $memoryDir 'decisions'
    $preDir = Join-Path $memoryDir 'preferences'
    $decCount = 0; $preCount = 0
    if (Test-Path -LiteralPath $decDir) { $decCount = @(Get-ChildItem -LiteralPath $decDir -File -Filter '*.md' -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne '.gitkeep' }).Count }
    if (Test-Path -LiteralPath $preDir) { $preCount = @(Get-ChildItem -LiteralPath $preDir -File -Filter '*.md' -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne '.gitkeep' }).Count }
    if (($decCount + $preCount) -eq 0) {
        Add-Violation 'MEM-001' 'error' 'butler' 'A substantive run (ADRs/specs created) recorded no memory entries. Butler must write decisions/preferences via memory-append, or justify "none".' 'memory'
    }
}

# ---------------------------------------------------------------------------
# TOKEN ACTUALS
# ---------------------------------------------------------------------------
function Invoke-TokenChecks {
    if (-not (Test-Path -LiteralPath $tracesDir)) { return }
    if (-not (Test-SubstantiveRun)) { return }

    $sessions = @(Get-ChildItem -LiteralPath $tracesDir -Directory -Filter 'Session-*' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)
    if ($sessions.Count -eq 0) { return }
    $tokenFile = Join-Path $sessions[0].FullName 'TokenUsage.md'
    if (-not (Test-Path -LiteralPath $tokenFile)) {
        Add-Violation 'TOKEN-001' 'error' 'butler' ("Trace session {0} has no TokenUsage.md. Record actuals via record-token-actuals (SessionEnd hook / -ManualTotal / -Unavailable)." -f $sessions[0].Name) ('Traces/' + $sessions[0].Name)
        return
    }
    $t = Read-Text $tokenFile
    if ($t -notmatch '(?m)^\s*source:\s*(harness-reported|api-usage|manual-meter|unavailable)') {
        Add-Violation 'TOKEN-001' 'error' 'butler' ("TokenUsage.md in {0} has estimates only - no actual row (source: harness-reported|api-usage|manual-meter|unavailable). Run record-token-actuals at session end." -f $sessions[0].Name) (Get-RelPath $tokenFile)
    }
}

# ---------------------------------------------------------------------------
# IDEA
# ---------------------------------------------------------------------------
function Invoke-IdeaChecks {
    if (-not (Test-Path -LiteralPath $ideationDir)) { return }
    $ideaFiles = @(Get-ChildItem -LiteralPath $ideationDir -Recurse -File -Filter 'idea-*.md' -ErrorAction SilentlyContinue |
            Where-Object { (Split-Path -Leaf (Split-Path -Parent $_.FullName)) -match '^IDEA-' } | Sort-Object FullName)
    foreach ($idea in $ideaFiles) {
        $rel = Get-RelPath $idea.FullName
        $lines = Read-Lines $idea.FullName
        $text = Read-Text $idea.FullName
        foreach ($h in @('Reasoning', 'Phases', 'Upfront Budget', 'Effort Estimate')) {
            if (-not (Test-Heading $lines $h)) {
                Add-Violation 'IDEA-001' 'error' 'idea-interrogator' ("{0} is missing required section '## {1}'." -f $rel, $h) $rel
            }
        }
        if ($text -match '(?i)input[ _-]?class\W*existing-solution') {
            foreach ($h in @('Impact Analysis', 'Gap Analysis', 'Alternatives')) {
                if (-not (Test-Heading $lines $h)) {
                    Add-Violation 'IDEA-002' 'error' 'idea-interrogator' ("{0} declares input class existing-solution+idea but has no '## {1}' section." -f $rel, $h) $rel
                }
            }
        }
        if ($text -match '(?im)^\s*(assume|silent)\s*:\s*true|--assume|--silent|^\s*mode\s*:.*(assume|silent)') {
            if (-not (Test-Heading $lines 'Assumptions')) {
                Add-Violation 'IDEA-003' 'error' 'idea-interrogator' ("{0} records assume/silent mode but has no '## Assumptions' section." -f $rel) $rel
            }
        }
        $dir = Split-Path -Parent $idea.FullName
        foreach ($a in @('Questionnaire.md', 'HumanAnswers.md', 'Research.md', 'ROI.md', 'Conclusion.md', 'QuickRoadmap.md', 'SpecWriterStarter.md')) {
            if (-not (Test-Path -LiteralPath (Join-Path $dir $a))) {
                Add-Violation 'IDEA-004' 'error' 'idea-interrogator' ("{0} is missing required artifact {1}." -f (Get-RelPath $dir), $a) ((Get-RelPath $dir) + '/' + $a)
            }
        }
        $roi = Join-Path $dir 'ROI.md'
        if (Test-Path -LiteralPath $roi) {
            if ((Read-Text $roi) -notmatch '(?im)confidence.*?\d{1,3}(\.\d+)?\s*%') {
                Add-Violation 'IDEA-005' 'error' 'idea-interrogator' ("{0} has no ROI confidence percentage (e.g. 'ROI confidence: 80%')." -f (Get-RelPath $roi)) (Get-RelPath $roi)
            }
        }
    }
}

# ---------------------------------------------------------------------------
# SPECS (spec-layout v6)
# ---------------------------------------------------------------------------
function Get-BacklogRows($sp) {
    if ($sp.Legacy) { $lines = Read-Lines (Join-Path $sp.Dir 'backlog.md') }
    else { $lines = Get-Section (Read-Lines $sp.File) 'backlog' }
    $out = New-Object System.Collections.ArrayList
    foreach ($l in $lines) {
        if ($l -notmatch '^\s*\|') { continue }
        $cells = $l.Split('|')
        if ($cells.Count -lt 2) { continue }
        $m = [regex]::Match((Get-CellTrim $cells[1]), '^\[{0,2}(Story|Enabler|Bug)-\d+')
        if (-not $m.Success) { continue }
        $key = [regex]::Match($m.Value, '(Story|Enabler|Bug)-\d+').Value
        $lm = [regex]::Match($l, '\[\[([^\]|#]+)')
        $link = ''
        if ($lm.Success) { $link = $lm.Groups[1].Value.Trim().TrimEnd([char]92).Trim() }
        [void]$out.Add([pscustomobject]@{ Key = $key; Type = $m.Groups[1].Value; Link = $link })
    }
    return , ($out.ToArray())
}

function Resolve-BacklogLink($sp, [string]$link) {
    if (-not $link) { return $null }
    $t = $link.Replace('\', '/')
    if (-not $t.ToLower().EndsWith('.md')) { $t = $t + '.md' }
    $c1 = Join-Path $sp.Dir $t
    if ((Test-Path -LiteralPath $c1 -PathType Leaf) -and ((Split-Path -Leaf (Split-Path -Parent $c1)) -match '^(?i)backlog$')) { return $c1 }
    $bd = Get-BacklogDir $sp.Dir
    if ($bd) {
        $c2 = Join-Path $bd (Split-Path -Leaf $t)
        if (Test-Path -LiteralPath $c2 -PathType Leaf) { return $c2 }
    }
    return $null
}

function Invoke-SpecsChecks {
    $specs = Get-TargetSpecs
    if ($Spec -and $specs.Count -eq 0) {
        Add-Violation 'SPEC-000' 'error' 'spec-writer' ("No spec folder matches {0}." -f $Spec) 'specs'
        return
    }
    $groups = @{}
    foreach ($sp in $specs) {
        $rel = Get-RelPath $sp.File
        $sev = 'error'
        if ($sp.Legacy) {
            $sev = 'warning'
            Add-Violation 'SPEC-LEGACY' 'warning' 'spec-writer' ("{0} uses the legacy v5 layout (backlog.md). Findings are warnings; migrate per spec-layout 'Legacy v5 specs'." -f $sp.Name) $rel
        }
        else {
            $lines = Read-Lines $sp.File
            foreach ($h in @('Delivery Brief', 'Acceptance Criteria', 'Backlog', 'Architecture')) {
                if (-not (Test-Heading $lines $h)) {
                    Add-Violation 'SPEC-001' 'error' 'spec-writer' ("{0} is missing required section '## {1}'." -f $rel, $h) $rel
                }
            }
            if ($lines.Count -gt $MaxSpecLines) {
                Add-Violation 'SZ-5' 'error' 'spec-writer' ("{0} has {1} lines (max {2}). Move detail into backlog items or arch.md." -f $rel, $lines.Count, $MaxSpecLines) $rel
            }
        }
        if (-not (Test-Path -LiteralPath (Join-Path $sp.Dir 'arch.md'))) {
            Add-Violation 'SPEC-003' $sev 'spec-writer' ("{0} has no arch.md." -f $sp.Name) ((Get-RelPath $sp.Dir) + '/arch.md')
        }
        $rows = Get-BacklogRows $sp
        $counted = 0
        foreach ($r in $rows) {
            if ($r.Type -ne 'Bug') { $counted++ }
            if (-not (Resolve-BacklogLink $sp $r.Link)) {
                if ($r.Link) { $why = "wikilink [[{0}]] does not resolve to a file under Backlog/" -f $r.Link } else { $why = 'has no [[wikilink]] to its Backlog/ file' }
                Add-Violation 'SPEC-002' $sev 'spec-writer' ("{0}: backlog row {1} {2}." -f $rel, $r.Key, $why) $rel
            }
        }
        if ($counted -gt $MaxItems) {
            Add-Violation 'SZ-2' $sev 'spec-writer' ("{0} has {1} stories/enablers (max {2}). Split the spec." -f $rel, $counted, $MaxItems) $rel
        }
        foreach ($it in (Get-Items $sp)) {
            if ($it.Type -eq 'Bug') { continue }
            $irel = Get-RelPath $it.File
            $ilines = Read-Lines $it.File
            $hasInvest = $false
            foreach ($l in $ilines) { if ($l -match '^\s*(#{1,6}\s*|[-*]\s*|\*\*)?INVEST\b') { $hasInvest = $true; break } }
            if (-not $hasInvest) {
                Add-Violation 'SPEC-004' $sev 'spec-writer' ("{0} has no INVEST line/section." -f $irel) $irel
            }
            $nf = (Get-ImpactedFiles $it.File).Count
            if ($nf -gt $MaxFiles) {
                Add-Violation 'SZ-3' $sev 'spec-writer' ("{0} lists {1} impacted files (max {2}). Split the item." -f $irel, $nf, $MaxFiles) $irel
            }
        }
        if (-not $groups.ContainsKey($sp.Group)) { $groups[$sp.Group] = New-Object System.Collections.ArrayList }
        [void]$groups[$sp.Group].Add($sp)
    }
    foreach ($g in $groups.Keys) {
        $gspecs = $groups[$g]
        $allLegacy = $true
        foreach ($sp in $gspecs) { if (-not $sp.Legacy) { $allLegacy = $false } }
        $gsev = 'error'; if ($allLegacy) { $gsev = 'warning' }
        $rm = Join-Path $g 'ROADMAP.md'
        if (-not (Test-Path -LiteralPath $rm)) {
            Add-Violation 'SPEC-005' $gsev 'spec-writer' ("{0} has no ROADMAP.md." -f (Get-RelPath $g)) ((Get-RelPath $g) + '/ROADMAP.md')
            continue
        }
        $rt = Read-Text $rm
        $done6 = @{}
        foreach ($sp in $gspecs) {
            if ($done6.ContainsKey($sp.Id)) { continue }
            $done6[$sp.Id] = $true
            if ($rt -notmatch ([regex]::Escape($sp.Id) + '(?!\d)')) {
                $ssev = 'error'; if ($sp.Legacy) { $ssev = 'warning' }
                Add-Violation 'SPEC-006' $ssev 'spec-writer' ("{0} does not list {1}." -f (Get-RelPath $rm), $sp.Id) (Get-RelPath $rm)
            }
        }
    }
    # Duplicate SPEC IDs across the whole specs tree.
    if ($null -eq $script:AllSpecs) { $script:AllSpecs = Get-AllSpecs }
    $seen = @{}
    foreach ($sp in $script:AllSpecs) {
        if (-not $seen.ContainsKey($sp.Id)) { $seen[$sp.Id] = New-Object System.Collections.ArrayList }
        [void]$seen[$sp.Id].Add((Get-RelPath $sp.Dir))
    }
    foreach ($id in ($seen.Keys | Sort-Object)) {
        if ($seen[$id].Count -gt 1) {
            if ($Spec -and ($specs | Where-Object { $_.Id -eq $id }).Count -eq 0) { continue }
            Add-Violation 'SPEC-007' 'error' 'spec-writer' ("Duplicate spec ID {0}: {1}." -f $id, ($seen[$id] -join ', ')) 'specs'
        }
    }
}

# ---------------------------------------------------------------------------
# PLAN
# ---------------------------------------------------------------------------
function Invoke-PlanChecks {
    $specs = Get-TargetSpecs
    if ($Spec -and $specs.Count -eq 0) {
        Add-Violation 'SPEC-000' 'error' 'planner' ("No spec folder matches {0}." -f $Spec) 'specs'
        return
    }
    foreach ($sp in $specs) {
        $plan = Join-Path $sp.Dir 'plan.md'
        $prel = (Get-RelPath $sp.Dir) + '/plan.md'
        if (-not (Test-Path -LiteralPath $plan)) {
            $rank = Get-StatusRank (Get-SpecStatus $sp)
            if (($Spec -and $Scope -eq 'plan') -or $rank -ge 2) {
                Add-Violation 'PLAN-001' 'error' 'planner' ("{0} has no plan.md (spec status requires a plan)." -f $sp.Name) $prel
            }
            continue
        }
        $plines = Read-Lines $plan
        if (-not (Test-Heading $plines 'Waves') -and -not (Test-Path -LiteralPath (Join-Path $sp.Dir 'parallelization.md'))) {
            Add-Violation 'PLAN-002' 'error' 'planner' ("{0} has no '## Waves' section (and no legacy parallelization.md)." -f $prel) $prel
        }
        if (-not (Test-Heading $plines 'Atomic test cases')) {
            Add-Violation 'PLAN-003' 'error' 'planner' ("{0} has no '## Atomic test cases' section." -f $prel) $prel
        }
        $tests = Get-PlanTests $plan
        $items = Get-Items $sp
        $files = @{}
        foreach ($it in $items) {
            if ($it.Type -eq 'Bug') { continue }
            $files[$it.Key] = Get-ImpactedFiles $it.File
            foreach ($ac in (Get-ItemACs $it.File)) {
                $hit = $false
                foreach ($t in $tests) {
                    if ($t.Item -eq $it.Key -and $t.AC -match ([regex]::Escape($ac) + '(?!\d)')) { $hit = $true; break }
                }
                if (-not $hit) {
                    Add-Violation 'PLAN-004' 'error' 'planner' ("{0} {1} has no Test ID row in plan.md atomic test cases." -f $it.Key, $ac) $prel
                }
            }
            $n = @($tests | Where-Object { $_.Item -eq $it.Key }).Count
            if ($n -gt $MaxTests) {
                Add-Violation 'SZ-4' 'error' 'planner' ("{0} needs {1} atomic tests (max {2}). Split the item." -f $it.Key, $n, $MaxTests) $prel
            }
        }
        $waves = Get-Waves $sp
        $byWave = @{}
        foreach ($w in $waves) {
            if (-not $byWave.ContainsKey($w.Wave)) { $byWave[$w.Wave] = New-Object System.Collections.ArrayList }
            if (-not $byWave[$w.Wave].Contains($w.Item)) { [void]$byWave[$w.Wave].Add($w.Item) }
        }
        foreach ($wk in ($byWave.Keys | Sort-Object)) {
            $list = $byWave[$wk]
            for ($a = 0; $a -lt $list.Count; $a++) {
                for ($b = $a + 1; $b -lt $list.Count; $b++) {
                    if (-not $files.ContainsKey($list[$a]) -or -not $files.ContainsKey($list[$b])) { continue }
                    foreach ($fa in $files[$list[$a]]) {
                        foreach ($fb in $files[$list[$b]]) {
                            if ($fa.ToLower() -eq $fb.ToLower()) {
                                Add-Violation 'PLAN-005' 'error' 'planner' ("Wave {0}: {1} and {2} both touch {3}; items in one wave must have disjoint impacted files." -f $wk, $list[$a], $list[$b], $fa) $prel
                            }
                        }
                    }
                }
            }
        }
    }
}

# ---------------------------------------------------------------------------
# REVIEW
# ---------------------------------------------------------------------------
function Test-OpenSevereBug([hashtable]$b) {
    $sev = ([string]$b['Severity']).ToLower()
    $st = ([string]$b['Status']).ToLower()
    return (($sev -eq 'blocker' -or $sev -eq 'major') -and ($st -eq 'open' -or $st -eq 'fixing'))
}

function Invoke-ReviewChecks {
    $specs = Get-TargetSpecs
    if ($Spec -and $specs.Count -eq 0) {
        Add-Violation 'SPEC-000' 'error' 'verifier' ("No spec folder matches {0}." -f $Spec) 'specs'
        return
    }
    foreach ($sp in $specs) {
        $rev = Join-Path $sp.Dir 'review.md'
        $rrel = (Get-RelPath $sp.Dir) + '/review.md'
        if (-not (Test-Path -LiteralPath $rev)) {
            $rank = Get-StatusRank (Get-SpecStatus $sp)
            if (($Spec -and $Scope -eq 'review') -or $rank -ge 5) {
                Add-Violation 'REV-001' 'error' 'verifier' ("{0} has no review.md." -f $sp.Name) $rrel
            }
            continue
        }
        $verdict = Get-ReviewVerdict $rev
        if (-not $verdict) {
            Add-Violation 'REV-002' 'error' 'verifier' ("{0} has no verdict line (APPROVED | CHANGES_NEEDED | toolchain-deferred | quality-deferred)." -f $rrel) $rrel
        }
        $ev = Get-Section (Read-Lines $rev) 'evidence'
        if (-not (Test-Heading (Read-Lines $rev) 'Evidence')) {
            Add-Violation 'REV-003' 'error' 'verifier' ("{0} has no '## Evidence' section." -f $rrel) $rrel
        }
        else {
            $hasCmd = $false; $hasExit = $false; $inFence = $false; $exitHdr = $false
            foreach ($l in $ev) {
                if ($l -match '^\s*```') { $inFence = -not $inFence; continue }
                if ($inFence -and $l.Trim()) { $hasCmd = $true }
                if ($l -match '`[^`]+`' -or $l -match '^\s*(\$|>|PS>)\s*\S') { $hasCmd = $true }
                if ($l -match '(?i)exit[ _-]*(code)?[^0-9]*-?\d') { $hasExit = $true }
                if ($l -match '^\s*\|' -and $l -match '(?i)exit') { $exitHdr = $true }
                elseif ($exitHdr -and $l -match '\|\s*-?\d+\s*(\||$)') { $hasExit = $true }
            }
            if (-not ($hasCmd -and $hasExit)) {
                Add-Violation 'REV-003' 'error' 'verifier' ("{0} '## Evidence' needs at least one command line and its exit code." -f $rrel) $rrel
            }
        }
        if ($verdict -eq 'APPROVED') {
            $trc = Join-Path $ToolDir 'check-traceability.ps1'
            $exe = (Get-Process -Id $PID).Path
            $trcExit = 2
            $oldEap = $ErrorActionPreference
            $ErrorActionPreference = 'Continue'
            try {
                $null = & $exe -NoProfile -ExecutionPolicy Bypass -File $trc -RepoRoot $RepoRoot -Spec $sp.Id -Json 2>&1
                $trcExit = $LASTEXITCODE
            }
            catch { $trcExit = 2 }
            $ErrorActionPreference = $oldEap
            if ($trcExit -ne 0) {
                Add-Violation 'REV-004' 'error' 'verifier' ("{0} is APPROVED but check-traceability fails for {1} (exit {2})." -f $rrel, $sp.Id, $trcExit) $rrel
            }
            foreach ($it in (Get-Items $sp)) {
                if ($it.Type -ne 'Bug') { continue }
                if (Test-OpenSevereBug (Get-Bug $it.File)) {
                    Add-Violation 'REV-005' 'error' 'verifier' ("{0} is APPROVED but {1} is an open blocker/major bug." -f $rrel, $it.Key) $rrel
                }
            }
        }
    }
}

# ---------------------------------------------------------------------------
# BUGS
# ---------------------------------------------------------------------------
function Invoke-BugsChecks {
    $specs = Get-TargetSpecs
    foreach ($sp in $specs) {
        $allItems = Get-Items $sp
        $bugs = @($allItems | Where-Object { $_.Type -eq 'Bug' })
        if ($bugs.Count -eq 0) { continue }
        $specDone = ((Get-StatusRank (Get-SpecStatus $sp)) -ge 5) -or ((Get-ReviewVerdict (Join-Path $sp.Dir 'review.md')) -eq 'APPROVED')
        $planTests = Get-PlanTests (Join-Path $sp.Dir 'plan.md')
        $testIds = @($planTests | ForEach-Object { $_.Id })
        foreach ($bf in $bugs) {
            $brel = Get-RelPath $bf.File
            $b = Get-Bug $bf.File
            $missing = $false
            foreach ($f in @('Source', 'Severity', 'Status', 'Story / AC', 'Regression test')) {
                if ($null -eq $b[$f]) {
                    Add-Violation 'BUG-001' 'error' 'human' ("{0} bug table has no '{1}' column." -f $brel, $f) $brel
                    $missing = $true
                }
            }
            $src = ([string]$b['Source']).ToLower()
            $sev = ([string]$b['Severity']).ToLower()
            $st = ([string]$b['Status']).ToLower()
            if ($null -ne $b['Source'] -and @('human', 'verifier') -notcontains $src) {
                Add-Violation 'BUG-002' 'error' 'human' ("{0} Source '{1}' is not human|verifier." -f $brel, $b['Source']) $brel
            }
            if ($null -ne $b['Severity'] -and @('blocker', 'major', 'minor') -notcontains $sev) {
                Add-Violation 'BUG-002' 'error' 'human' ("{0} Severity '{1}' is not blocker|major|minor." -f $brel, $b['Severity']) $brel
            }
            if ($null -ne $b['Status'] -and @('open', 'fixing', 'fixed', 'verified', 'wontfix') -notcontains $st) {
                Add-Violation 'BUG-002' 'error' 'human' ("{0} Status '{1}' is not open|fixing|fixed|verified|wontfix." -f $brel, $b['Status']) $brel
            }
            if ($specDone -and (Test-OpenSevereBug $b)) {
                Add-Violation 'BUG-003' 'error' 'human' ("{0} is an {1} {2} bug but {3} is Done/APPROVED." -f $brel, $st, $sev, $sp.Id) $brel
            }
            if (@('fixing', 'fixed', 'verified') -contains $st) {
                $rt = [regex]::Match([string]$b['Regression test'], '[A-Za-z]+-\d+')
                if (-not $rt.Success) {
                    Add-Violation 'BUG-004' 'error' 'planner' ("{0} is {1} but names no regression Test ID." -f $brel, $st) $brel
                }
                elseif ($testIds -notcontains $rt.Value) {
                    Add-Violation 'BUG-004' 'error' 'planner' ("{0} regression test {1} is not in plan.md atomic test cases." -f $brel, $rt.Value) $brel
                }
            }
        }
    }
}

if ($Scope -eq 'all' -or $Scope -eq 'architecture') { Invoke-ArchitectureChecks }
if ($Scope -eq 'all' -or $Scope -eq 'linking') { Invoke-LinkingChecks }
if ($Scope -eq 'all' -or $Scope -eq 'trace') { Invoke-TraceChecks }
if ($Scope -eq 'all' -or $Scope -eq 'memory') { Invoke-MemoryChecks }
if ($Scope -eq 'all' -or $Scope -eq 'token') { Invoke-TokenChecks }
if ($Scope -eq 'all' -or $Scope -eq 'idea') { Invoke-IdeaChecks }
if ($Scope -eq 'all' -or $Scope -eq 'specs') { Invoke-SpecsChecks }
if ($Scope -eq 'all' -or $Scope -eq 'plan') { Invoke-PlanChecks }
if ($Scope -eq 'all' -or $Scope -eq 'review') { Invoke-ReviewChecks }
if ($Scope -eq 'all' -or $Scope -eq 'bugs') { Invoke-BugsChecks }

$errors = @($violations | Where-Object { $_.severity -eq 'error' })
$warnings = @($violations | Where-Object { $_.severity -eq 'warning' })
$status = 'pass'
if ($errors.Count -gt 0) { $status = 'fail' }

if ($Json) {
    [pscustomobject]@{
        tool        = 'check-run-conformance'
        version     = $ToolVersion
        scope       = $Scope
        spec        = $Spec
        errors      = $errors.Count
        warnings    = $warnings.Count
        status      = $status
        repo_root   = $RepoRoot
        error_count = $errors.Count
        warn_count  = $warnings.Count
        violations  = $violations
    } | ConvertTo-Json -Depth 5
}
else {
    Write-Output ("KCC run conformance: {0}  (scope: {1})" -f $RepoRoot, $Scope)
    foreach ($v in $violations) {
        Write-Output ("[{0}] {1} ({2}) {3}: {4}" -f $v.severity.ToUpper(), $v.id, $v.fix_owner, $v.file, $v.message)
    }
    Write-Output ("Errors: {0}  Warnings: {1}" -f $errors.Count, $warnings.Count)
}

if ($errors.Count -gt 0) { exit 1 } else { exit 0 }
