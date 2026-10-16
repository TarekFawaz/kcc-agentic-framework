<#
KCC framework (c) 2026 Tarek Fawaz, https://tikasway.dev/kcc. Licensed under the terms in LICENSE.

.SYNOPSIS
    Generate the self-contained, offline KCC delivery dashboard (dashboard/index.html).

.DESCRIPTION
    Collects the framework's progress and telemetry surfaces, then fills the shared page
    template (.KCC/kernel/templates/dashboard.html) with one JSON data block:

      - roadmaps    specs/IDEA-*-Specs/ROADMAP.md
      - specs       spec notes, Backlog/ stories, enablers and bugs, plan.md, review.md,
                    TestResults, and the ADRs they reference
      - events      coordination/backchannel.jsonl
      - checkpoints coordination/checkpoints/CP-*.md
      - run         coordination/run/run.json plus the state table (kernel/auto-states.json)
      - traces      Traces/Session-*/ (the seven files, plus parsed Decisions / HumanDecisions)

    The page uses the Tikasway.dev theme (light and dark), shows overall statistics, lets the
    reader follow one spec and the decisions behind it, and can reload itself ("Live").
    No external CDNs or network calls: it opens offline and can be re-opened without this script.

    PowerShell 5.1 compatible. UTF-8 (no BOM) output. No && operator.

.PARAMETER RepoRoot
    Path to the repo root. Defaults to the parent of .KCC when this script lives in {repo}/.KCC/tools/.

.PARAMETER Template
    Page template to use instead of the workspace's .KCC/kernel/templates/dashboard.html (for example to view an
    older workspace with the newest page).

.PARAMETER Open
    Launch the generated dashboard in the default browser.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .KCC\tools\build-dashboard.ps1 -Open
#>

[CmdletBinding()]
param(
    [string]$RepoRoot,
    [string]$Template,
    [switch]$Open
)

$ErrorActionPreference = 'Stop'

function Resolve-ToolDir {
    if ($PSScriptRoot) { return $PSScriptRoot }
    if ($MyInvocation.MyCommand.Path) { return (Split-Path -Parent $MyInvocation.MyCommand.Path) }
    return (Get-Location).Path
}
$ToolDir = Resolve-ToolDir
if (-not $RepoRoot) {
    $parent = Split-Path -Parent $ToolDir
    if ((Split-Path -Leaf $parent) -eq '.KCC') { $RepoRoot = Split-Path -Parent $parent } else { $RepoRoot = $parent }
}
$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path.TrimEnd('\', '/')

$MaxTraceChars = 24000
$MaxEvents = 4000

# ---- helpers ---------------------------------------------------------------

# Opens with FileShare.ReadWrite: a log or transcript the harness is still writing must stay readable.
function Open-SharedReader([string]$Path) {
    $fs = New-Object System.IO.FileStream($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
    return (New-Object System.IO.StreamReader($fs, [System.Text.Encoding]::UTF8))
}
function Read-TextOrNull([string]$Path) {
    if ($Path -and (Test-Path -LiteralPath $Path -PathType Leaf)) {
        try { $r = Open-SharedReader $Path; try { return $r.ReadToEnd() } finally { $r.Dispose() } } catch { return $null }
    }
    return $null
}
function Read-FirstLine([string]$Path) {
    try { $r = Open-SharedReader $Path; try { return [string]$r.ReadLine() } finally { $r.Dispose() } } catch { return '' }
}

function Get-Frontmatter([string]$Text, [string]$Key) {
    if (-not $Text) { return $null }
    $m = [regex]::Match($Text, '(?s)\A\s*---\s*\r?\n(.*?)\r?\n---')
    if (-not $m.Success) { return $null }
    $km = [regex]::Match($m.Groups[1].Value, '(?m)^' + [regex]::Escape($Key) + '\s*:\s*(.+?)\s*$')
    if (-not $km.Success) { return $null }
    return $km.Groups[1].Value.Trim().Trim('"').Trim("'")
}

function Get-Lines([string]$Text) {
    if (-not $Text) { return @() }
    return @($Text -split "\r?\n")
}

# Lines under the first heading matching $Pattern (any level), up to the next heading of the same or higher level.
function Get-Section([string[]]$Lines, [string]$Pattern) {
    $out = New-Object System.Collections.ArrayList
    $inside = $false; $level = 0
    foreach ($l in $Lines) {
        $hm = [regex]::Match($l, '^(#{1,6})\s+(.*)$')
        if ($hm.Success) {
            if ($inside -and $hm.Groups[1].Value.Length -le $level) { break }
            if (-not $inside -and $hm.Groups[2].Value -match $Pattern) { $inside = $true; $level = $hm.Groups[1].Value.Length; continue }
        }
        if ($inside) { [void]$out.Add($l) }
    }
    return @($out)
}

function Split-Row([string]$Line) {
    $t = $Line.Trim()
    if ($t.StartsWith('|')) { $t = $t.Substring(1) }
    if ($t.EndsWith('|')) { $t = $t.Substring(0, $t.Length - 1) }
    return @($t -split '(?<!\\)\|' | ForEach-Object { $_.Trim() })
}

# First markdown table in $Lines -> array of hashtables keyed by lower-cased header cell.
function Get-Table([string[]]$Lines) {
    $rows = New-Object System.Collections.ArrayList
    $head = $null
    foreach ($l in $Lines) {
        if ($l -notmatch '^\s*\|') { if ($head) { break } else { continue } }
        $cells = Split-Row $l
        if (-not $head) { $head = @($cells | ForEach-Object { $_.ToLowerInvariant() }); continue }
        if ($l -match '^\s*\|[\s:|\-]+\|?\s*$') { continue }
        $h = [ordered]@{}
        for ($i = 0; $i -lt $head.Count; $i++) { if ($i -lt $cells.Count) { $h[$head[$i]] = $cells[$i] } else { $h[$head[$i]] = '' } }
        [void]$rows.Add($h)
    }
    return @($rows)
}

function Clean-Link([string]$s) {
    if ($null -eq $s) { return '' }
    $x = [regex]::Replace($s, '\[\[([^\]|]+)\|?([^\]]*)\]\]', { param($m) if ($m.Groups[2].Value) { $m.Groups[2].Value } else { $m.Groups[1].Value } })
    return ($x -replace '\*\*', '').Trim()
}

function Get-Cell($row, [string[]]$names) {
    foreach ($n in $names) { if ($row.Contains($n) -and $row[$n]) { return (Clean-Link $row[$n]) } }
    return ''
}

function Get-H1([string]$Text) {
    $m = [regex]::Match([string]$Text, '(?m)^#\s+(.+?)\s*$')
    if ($m.Success) { return $m.Groups[1].Value.Trim() }
    return ''
}

function To-Utc([string]$s) { return $s }

# ---- data model -------------------------------------------------------------

$data = [ordered]@{
    schema         = 2
    generatedAt    = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    repoRoot       = $RepoRoot
    project        = (Split-Path -Leaf $RepoRoot)
    run            = $null
    states         = @()
    ideas          = @()
    specs          = @()
    roadmaps       = @()
    events         = @()
    checkpoints    = @()
    sessions       = @()
    decisions      = @()
    humanDecisions = @()
    adrs           = @()
    memory         = [ordered]@{ total = 0; byType = [ordered]@{} }
    notes          = @()
}

# Run state + the lifecycle state table.
$runObj = $null
$runFile = Join-Path $RepoRoot 'coordination/run/run.json'
$runText = Read-TextOrNull $runFile
if ($runText) {
    try { $runObj = $runText | ConvertFrom-Json } catch { $runObj = $null }
}
# Values come from the raw text: ConvertFrom-Json would turn ISO timestamps into locale dates.
function Run-Val($name) {
    if ($null -eq $runObj) { return '' }
    $m = [regex]::Match($runText, '"' + [regex]::Escape($name) + '"\s*:\s*"((?:[^"\\]|\\.)*)"')
    if ($m.Success) { return [regex]::Unescape($m.Groups[1].Value) }
    if ($runObj.PSObject.Properties.Name -contains $name) { return [string]$runObj.$name }
    return ''
}
$fast = ((Run-Val 'fasttrack') -eq '1') -or ($runText -match '--fasttrack'); $par = ((Run-Val 'parallel') -eq '1') -or ($runText -match '--parallel')
# A chat run may have no run.json at all: its policy is in the first auto-policy-parsed event.
$bcEarly = Join-Path $RepoRoot 'coordination/backchannel.jsonl'
if (Test-Path -LiteralPath $bcEarly) {
    $pol = @(Get-Content -LiteralPath $bcEarly -ErrorAction SilentlyContinue | Where-Object { $_ -match '"kind"\s*:\s*"auto-policy-parsed"' } | Select-Object -First 1)
    if ($pol.Count -gt 0) {
        if ($pol[0] -match '--fasttrack|"fasttrack"\s*:\s*(true|"1")') { $fast = $true }
        if ($pol[0] -match '--parallel|"parallel"\s*:\s*(true|"1")') { $par = $true }
    }
}
$statesFile = Join-Path $RepoRoot '.KCC/kernel/auto-states.json'
if ($fast -and (Test-Path -LiteralPath (Join-Path $RepoRoot '.KCC/kernel/auto-states-fasttrack.json'))) { $statesFile = Join-Path $RepoRoot '.KCC/kernel/auto-states-fasttrack.json' }
$stText = Read-TextOrNull $statesFile
if ($stText) {
    try {
        $sm = $stText | ConvertFrom-Json
        $list = @()
        foreach ($s in @($sm.states)) {
            $skipped = $false
            if ($s.PSObject.Properties.Name -contains 'skip_if_flag') {
                foreach ($f in @($s.skip_if_flag)) {
                    if (($f -eq 'fasttrack' -and $fast) -or ($f -eq 'parallel' -and $par)) { $skipped = $true }
                }
            }
            if (($s.PSObject.Properties.Name -contains 'only_in') -and ((Run-Val 'scenario') -ne '') -and (@($s.only_in) -notcontains (Run-Val 'scenario'))) { $skipped = $true }
            $list += [ordered]@{ id = [int]$s.id; name = [string]$s.name; scope = [string]$s.scope; skipped = $skipped }
        }
        $data.states = $list
    } catch { $data.notes += 'kernel/auto-states.json could not be parsed.' }
}

# ---- ideas ------------------------------------------------------------------
$ideationDir = Join-Path $RepoRoot 'ideation'
if (Test-Path -LiteralPath $ideationDir) {
    foreach ($folder in @(Get-ChildItem -LiteralPath $ideationDir -Directory -Filter 'IDEA-*' -ErrorAction SilentlyContinue | Sort-Object Name)) {
        $ideaFile = Get-ChildItem -LiteralPath $folder.FullName -Filter 'idea-*.md' -File -ErrorAction SilentlyContinue | Select-Object -First 1
        $text = $null; if ($ideaFile) { $text = Read-TextOrNull $ideaFile.FullName }
        $idm = [regex]::Match($folder.Name, '^IDEA-\d+')
        $title = Get-Frontmatter $text 'title'
        if (-not $title) { $title = Get-H1 $text }
        $files = @(Get-ChildItem -LiteralPath $folder.FullName -File -Filter '*.md' -ErrorAction SilentlyContinue | ForEach-Object { $_.Name })
        $st = Get-Frontmatter $text 'status'
        $data.ideas += [ordered]@{ id = $idm.Value; folder = $folder.Name; title = $title; slug = (Get-Frontmatter $text 'slug'); status = $st; files = $files }
    }
} else { $data.notes += 'No ideation/ folder yet.' }

# ---- ADRs -------------------------------------------------------------------
$adrDir = Join-Path $RepoRoot 'architecture/adrs'
if (Test-Path -LiteralPath $adrDir) {
    foreach ($f in @(Get-ChildItem -LiteralPath $adrDir -Filter 'ADR-*.md' -File -ErrorAction SilentlyContinue | Sort-Object Name)) {
        $t = Read-TextOrNull $f.FullName
        $idm = [regex]::Match($f.Name, '^ADR-\d+')
        $title = (Get-H1 $t) -replace '^ADR-\d+\s*[:\-]?\s*', ''
        $status = Get-Frontmatter $t 'status'
        if (-not $status) { $sec = Get-Section (Get-Lines $t) '^Status'; $first = @($sec | Where-Object { $_.Trim() })[0]; if ($first) { $status = ($first -replace '\s*\(.*$', '').Trim() } }
        $data.adrs += [ordered]@{ id = $idm.Value; title = $title; status = $status; file = ('architecture/adrs/' + $f.Name) }
    }
}

# ---- specs + roadmaps ---------------------------------------------------------
function Parse-Acs([string[]]$Lines) {
    $out = @()
    foreach ($l in $Lines) {
        $m = [regex]::Match($l, '^\s*[-*]\s*\[([ xX])\]\s*(AC-\d+)\s*[-:]?\s*(.*)$')
        if ($m.Success) { $out += [ordered]@{ id = $m.Groups[2].Value; text = (Clean-Link $m.Groups[3].Value); done = ($m.Groups[1].Value -ne ' ') } }
    }
    return $out
}

$specsDir = Join-Path $RepoRoot 'specs'
if (Test-Path -LiteralPath $specsDir) {
    foreach ($group in @(Get-ChildItem -LiteralPath $specsDir -Directory -Filter 'IDEA-*-Specs' -ErrorAction SilentlyContinue | Sort-Object Name)) {
        $ideaId = [regex]::Match($group.Name, '^IDEA-\d+').Value
        # roadmap
        $rm = Read-TextOrNull (Join-Path $group.FullName 'ROADMAP.md')
        if ($rm) {
            $rlines = Get-Lines $rm
            $tbl = Get-Table (Get-Section $rlines '^Execution Plan')
            if (@($tbl).Count -eq 0) { $tbl = Get-Table $rlines }
            $keyMap = [ordered]@{ 'order' = 'order'; 'spec' = 'spec'; 'delivery' = 'delivery'; 'depends on' = 'dependsOn'; 'lane' = 'lane'; 'est. tokens' = 'tokens'; 'restore point' = 'restore' }
            $rows = @()
            foreach ($r in $tbl) {
                $o = [ordered]@{}
                foreach ($k in $keyMap.Keys) { if ($r.Contains($k)) { $o[$keyMap[$k]] = (Clean-Link $r[$k]) } }
                $rows += $o
            }
            $data.roadmaps += [ordered]@{ ideaId = $ideaId; title = ((Get-H1 $rm) -replace '^Roadmap\s*[-:]\s*', ''); columns = @($keyMap.Values | Where-Object { $rows.Count -gt 0 -and $rows[0].Contains($_) }); rows = $rows }
        }
        foreach ($sf in @(Get-ChildItem -LiteralPath $group.FullName -Directory -Filter 'SPEC-*' -ErrorAction SilentlyContinue | Sort-Object Name)) {
            $specId = [regex]::Match($sf.Name, '^SPEC-[0-9A-Za-z]+').Value
            $note = Get-ChildItem -LiteralPath $sf.FullName -Filter 'SPEC-*.md' -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -notmatch 'backlog' } | Select-Object -First 1
            $sText = $null; if ($note) { $sText = Read-TextOrNull $note.FullName }
            $sLines = Get-Lines $sText
            $head = @(Get-Table (@($sLines | Select-Object -First 12)))
            $h0 = $null; if ($head.Count -gt 0) { $h0 = $head[0] }
            $status = ''; $prio = ''; $cat = ''; $wave = ''
            if ($h0) { $status = Get-Cell $h0 @('status'); $prio = Get-Cell $h0 @('priority'); $cat = Get-Cell $h0 @('category'); $wave = Get-Cell $h0 @('wave') }
            if (-not $status) { $status = Get-Frontmatter $sText 'status' }
            $title = (Get-H1 $sText) -replace '^SPEC-[0-9A-Za-z]+\s*[:\-]?\s*', ''
            if (-not $title) { $title = Get-Frontmatter $sText 'title' }
            # delivery brief bullets
            $brief = [ordered]@{ who = ''; gets = ''; value = ''; measured = '' }
            foreach ($l in (Get-Section $sLines '^Delivery Brief')) {
                $bm = [regex]::Match($l, '^\s*[-*]\s*\*\*([^*:]+):?\*\*:?\s*(.+)$')
                if ($bm.Success) {
                    $k = $bm.Groups[1].Value.Trim().ToLowerInvariant()
                    if ($k -eq 'who') { $brief.who = (Clean-Link $bm.Groups[2].Value) }
                    elseif ($k -eq 'gets') { $brief.gets = (Clean-Link $bm.Groups[2].Value) }
                    elseif ($k -eq 'value') { $brief.value = (Clean-Link $bm.Groups[2].Value) }
                    elseif ($k -like 'measured*') { $brief.measured = (Clean-Link $bm.Groups[2].Value) }
                }
            }
            $acs = @(Parse-Acs (Get-Section $sLines '^Acceptance Criteria'))
            # backlog items: spec table first, then item files (status in the item file wins)
            $blTable = @(Get-Table (Get-Section $sLines '^Backlog'))
            $items = @(); $bugs = @()
            $bdir = Join-Path $sf.FullName 'Backlog'
            $seen = @{}
            if (Test-Path -LiteralPath $bdir) {
                foreach ($bf in @(Get-ChildItem -LiteralPath $bdir -Filter '*.md' -File -ErrorAction SilentlyContinue | Sort-Object Name)) {
                    $bt = Read-TextOrNull $bf.FullName
                    $bl = Get-Lines $bt
                    $key = [regex]::Match($bf.BaseName, '^(Story|Enabler|Bug)-\d+').Value
                    if (-not $key) { continue }
                    $type = ($key -split '-')[0]
                    $tr = @(Get-Table (@($bl | Select-Object -First 14)))
                    $r0 = $null; if ($tr.Count -gt 0) { $r0 = $tr[0] }
                    $itTitle = ((Get-H1 $bt) -replace '^(Story|Enabler|Bug)-\d+\s*[:\-]?\s*', '')
                    $seen[$key] = $true
                    if ($type -eq 'Bug') {
                        $bugs += [ordered]@{
                            key = $key; title = $itTitle
                            severity = ($(if ($r0) { Get-Cell $r0 @('severity') } else { '' }))
                            status = ($(if ($r0) { Get-Cell $r0 @('status') } else { '' }))
                            source = ($(if ($r0) { Get-Cell $r0 @('source', 'reporter') } else { '' }))
                            ref = ($(if ($r0) { Get-Cell $r0 @('story / ac', 'against') } else { '' }))
                            test = ($(if ($r0) { Get-Cell $r0 @('regression test') } else { '' }))
                        }
                        continue
                    }
                    $row = $null
                    foreach ($t in $blTable) { if ((Get-Cell $t @('key')) -eq $key) { $row = $t; break } }
                    $st = ''; if ($r0) { $st = Get-Cell $r0 @('status') }
                    if (-not $st -and $row) { $st = Get-Cell $row @('status') }
                    $items += [ordered]@{
                        key = $key; type = $type
                        title = ($(if ($itTitle) { $itTitle } elseif ($row) { Get-Cell $row @('title') } else { '' }))
                        status = $st
                        wave = ($(if ($row) { Get-Cell $row @('wave') } else { '' }))
                        dependsOn = ($(if ($r0) { Get-Cell $r0 @('depends on') } elseif ($row) { Get-Cell $row @('depends on') } else { '' }))
                        dialect = ($(if ($r0) { Get-Cell $r0 @('dialect') } else { '' }))
                        acs = @(Parse-Acs (Get-Section $bl '^Acceptance Criteria'))
                    }
                }
            }
            foreach ($t in $blTable) {   # table rows whose item file is missing
                $k = Get-Cell $t @('key')
                if ($k -and -not $seen.ContainsKey($k) -and $k -notmatch '^Bug-') {
                    $items += [ordered]@{ key = $k; type = (Get-Cell $t @('type')); title = (Get-Cell $t @('title')); status = (Get-Cell $t @('status')); wave = (Get-Cell $t @('wave')); dependsOn = (Get-Cell $t @('depends on')); dialect = ''; acs = @() }
                }
            }
            # plan
            $plan = [ordered]@{ exists = $false; status = ''; waves = 0; tests = 0 }
            $pt = Read-TextOrNull (Join-Path $sf.FullName 'plan.md')
            if ($pt) {
                $pl = Get-Lines $pt
                $plan.exists = $true; $plan.status = (Get-Frontmatter $pt 'status')
                $wvs = @(Get-Table (Get-Section $pl '^Waves'))
                $plan.waves = @($wvs | ForEach-Object { Get-Cell $_ @('wave') } | Where-Object { $_ } | Select-Object -Unique).Count
                $plan.tests = @(Get-Table (Get-Section $pl '^Atomic test cases')).Count
            }
            # review
            $review = [ordered]@{ exists = $false; verdict = '' }
            $rvt = Read-TextOrNull (Join-Path $sf.FullName 'review.md')
            if ($rvt) {
                $review.exists = $true
                $vm = [regex]::Match($rvt, '(?i)\b(APPROVED|CHANGES_NEEDED|TOOLCHAIN_DEFERRED|BLOCKED)\b')
                if ($vm.Success) { $review.verdict = $vm.Groups[1].Value.ToUpperInvariant() }
            }
            # test verdicts
            $verdict = $null
            $trf = Join-Path (Join-Path (Join-Path $RepoRoot 'TestResults') $ideaId) (Join-Path $specId 'test-run-summary.md')
            $trt = Read-TextOrNull $trf
            if ($trt) {
                $verdict = [ordered]@{ pass = ([regex]::Matches($trt, '(?i)\bPASS(ED)?\b')).Count; fail = ([regex]::Matches($trt, '(?i)\bFAIL(ED)?\b')).Count }
            }
            # ADR references
            $refText = [string]$sText + [string](Read-TextOrNull (Join-Path $sf.FullName 'arch.md')) + [string]$pt
            $adrRefs = @([regex]::Matches($refText, 'ADR-\d+') | ForEach-Object { $_.Value } | Select-Object -Unique)
            $data.specs += [ordered]@{
                id = $specId; ideaId = $ideaId; folder = $sf.Name; title = $title; status = $status; priority = $prio; category = $cat; wave = $wave
                deliveryBrief = $brief; acs = $acs; items = $items; bugs = $bugs; plan = $plan; review = $review; verdict = $verdict; adrRefs = $adrRefs
            }
        }
    }
} else { $data.notes += 'No specs/ folder yet.' }

# ---- run object (needs the spec list for currentSpec) --------------------------
if ($runObj) {
    $curSpec = ''
    $entries = @((Run-Val 'specs') -split ' ' | Where-Object { $_ })
    $si = 0; [void][int]::TryParse((Run-Val 'spec_index'), [ref]$si)
    if ($entries.Count -gt $si) { $m = [regex]::Match($entries[$si], 'SPEC-[0-9A-Za-z]+'); if ($m.Success) { $curSpec = $m.Value } }
    $stNum = 0; [void][int]::TryParse((Run-Val 'state'), [ref]$stNum)
    $data.run = [ordered]@{
        status = (Run-Val 'status'); state = $stNum; wave = (Run-Val 'wave'); scenario = (Run-Val 'scenario'); harness = (Run-Val 'harness')
        fasttrack = $fast; parallel = $par; depthlevel = (Run-Val 'depthlevel'); reason = (Run-Val 'reason'); updated = (Run-Val 'updated')
        created = (Run-Val 'created'); input = (Run-Val 'input'); idea = (Run-Val 'idea'); currentSpec = $curSpec; gate_name = (Run-Val 'gate_name')
    }
}

# ---- backchannel events ---------------------------------------------------------
$bcPath = Join-Path $RepoRoot 'coordination/backchannel.jsonl'
if (Test-Path -LiteralPath $bcPath) {
    $all = @(Get-Content -LiteralPath $bcPath -ErrorAction SilentlyContinue | Where-Object { $_ -and $_.Trim() })
    if ($all.Count -gt $MaxEvents) { $data.notes += ('Showing the last ' + $MaxEvents + ' of ' + $all.Count + ' backchannel events.'); $all = @($all | Select-Object -Last $MaxEvents) }
    $evs = @()
    # Fields are read from the raw line: ConvertFrom-Json would turn ISO timestamps into locale dates.
    function Raw-Field([string]$Line, [string[]]$Keys) {
        foreach ($k in $Keys) {
            $m = [regex]::Match($Line, '"' + $k + '"\s*:\s*"((?:[^"\\]|\\.)*)"')
            if ($m.Success) { return [regex]::Unescape($m.Groups[1].Value) }
        }
        return ''
    }
    foreach ($line in $all) {
        $valid = $true
        try { [void]($line | ConvertFrom-Json) } catch { $valid = $false }
        if (-not $valid) { $evs += [ordered]@{ id = ''; ts = ''; kind = 'invalid-json'; from = ''; to = ''; spec = ''; payload = $line }; continue }
        $pi = $line.IndexOf('"payload"')
        $raw = ''
        if ($pi -ge 0) {
            $colon = $line.IndexOf(':', $pi)
            $end = $line.LastIndexOf('}')
            if ($colon -ge 0 -and $end -gt $colon) { $raw = $line.Substring($colon + 1, $end - $colon - 1).Trim() }
        }
        $head = $line; if ($pi -ge 0) { $head = $line.Substring(0, $pi) }
        $evs += [ordered]@{
            id = (Raw-Field $head @('id')); ts = (Raw-Field $head @('ts', 'timestamp')); kind = (Raw-Field $head @('kind', 'event'))
            from = (Raw-Field $head @('from', 'agent')); to = (Raw-Field $head @('to')); spec = (Raw-Field $head @('spec'))
            payload = $raw
        }
    }
    $data.events = $evs
} else { $data.notes += 'No coordination/backchannel.jsonl yet.' }

# ---- stage of a chat-driven run ----------------------------------------------------
# The `auto` skill in a chat session records progress as backchannel events but does not keep the
# driver's run.json `state`; without this the pipeline would sit on REPO for the whole run.
if ((-not $runObj -or -not (Run-Val 'state')) -and @($data.events).Count -gt 0) {
    $doneMap = @{ 'idea-interrogation-completed' = 1; 'architecture-pass-complete' = 6; 'spec-created' = 9; 'roadmap-created' = 9;
        'plan-created' = 11; 'toolchain-preflight-result' = 14; 'implement-completed' = 15; 'test-completed' = 16; 'review-produced' = 17; 'session-closed' = 18 }
    $startMap = @{ 'implement-started' = 15; 'test-started' = 16; 'toolchain-preflight-started' = 14 }
    # Run-wide stages (up to SPECS) advance on any event; PLAN..REVIEW advance per spec, so the pipeline shows
    # the earliest stage a spec is still in (a spec-less event, e.g. an early preflight, moves nothing).
    $done = 0; $closed = $false; $specDone = @{}; $specStart = @{}
    foreach ($e in @($data.events)) {
        $k = [string]$e.kind; $id = -1; $sp = ''
        if ([string]$e.spec -match '^SPEC-') { $sp = [string]$e.spec }
        if ($k -eq 'specialist-brief-created') { if ([string]$e.from -match 'technical') { $id = 3 } else { $id = 4 } }
        elseif ($doneMap.ContainsKey($k)) { $id = $doneMap[$k] }
        if ($k -eq 'session-closed') { $closed = $true }
        if ($k -eq 'spec-created' -and $sp -and -not $specDone.ContainsKey($sp)) { $specDone[$sp] = 9 }
        if ($id -ge 0 -and $id -lt 10) { if ($id -gt $done) { $done = $id } }
        elseif ($id -ge 10 -and $sp) { if (-not $specDone.ContainsKey($sp) -or $id -gt $specDone[$sp]) { $specDone[$sp] = $id } }
        elseif ($id -eq 18) { $done = 18 }
        elseif ($id -eq 14 -and -not $sp) {
            # One preflight for the whole run covers every spec that is already planned.
            foreach ($x in @($specDone.Keys)) { if ($specDone[$x] -ge 11 -and $specDone[$x] -lt 14) { $specDone[$x] = 14 } }
        }
        if ($sp -and $startMap.ContainsKey($k)) { if (-not $specStart.ContainsKey($sp) -or $startMap[$k] -gt $specStart[$sp]) { $specStart[$sp] = $startMap[$k] } }
    }
    $nextAfter = { param($d) foreach ($s in @($data.states)) { if ([int]$s.id -gt $d -and -not $s.skipped) { return [int]$s.id } }; return $d }
    if ($done -ge 9 -and $done -lt 18 -and $specDone.Count -gt 0) {
        $cur = 99
        foreach ($sp in @($specDone.Keys)) {
            $n = & $nextAfter $specDone[$sp]
            if ($specStart.ContainsKey($sp) -and $specStart[$sp] -gt $specDone[$sp]) { $n = $specStart[$sp] }
            if ($n -lt $cur) { $cur = $n }
        }
    } else { $cur = & $nextAfter $done; if ($done -ge 18) { $cur = 18 } }
    $status = 'running'; if ($closed) { $status = 'done' }
    if ($data.run) { $data.run.state = $cur; if (-not $data.run.status) { $data.run.status = $status } }
    else { $data.run = [ordered]@{ status = $status; state = $cur; wave = ''; scenario = (Run-Val 'scenario'); harness = 'chat'; fasttrack = $fast; parallel = $par; depthlevel = (Run-Val 'depthlevel'); reason = ''; updated = ''; created = ''; input = ''; idea = (Run-Val 'idea'); currentSpec = ''; gate_name = '' } }
    $data.notes += 'Stage derived from backchannel events (chat-driven run).'
    $script:derivedRun = $true
}

# ---- checkpoints ------------------------------------------------------------------
$cpDir = Join-Path $RepoRoot 'coordination/checkpoints'
if (Test-Path -LiteralPath $cpDir) {
    $latestId = Get-Frontmatter (Read-TextOrNull (Join-Path $cpDir 'latest.md')) 'points_to'
    foreach ($f in @(Get-ChildItem -LiteralPath $cpDir -Filter 'CP-*.md' -File -ErrorAction SilentlyContinue | Sort-Object Name)) {
        $t = Read-TextOrNull $f.FullName
        $id = Get-Frontmatter $t 'id'; if (-not $id) { $id = $f.BaseName }
        $data.checkpoints += [ordered]@{
            id = $id; created = (Get-Frontmatter $t 'created'); reason = (Get-Frontmatter $t 'reason'); spec = (Get-Frontmatter $t 'spec'); stage = (Get-Frontmatter $t 'stage')
            next_action = (Get-Frontmatter $t 'next_action'); git_tag = (Get-Frontmatter $t 'git_tag'); previous = (Get-Frontmatter $t 'previous'); latest = ($id -eq $latestId)
        }
    }
}

# ---- traces + parsed decisions -------------------------------------------------------
function Parse-Decisions([string]$Text, [string]$Session, [bool]$Human) {
    $out = @()
    if (-not $Text) { return $out }
    $parts = [regex]::Split($Text, '(?m)^##\s+\d+\.\s+')
    for ($i = 1; $i -lt $parts.Count; $i++) {
        $block = $parts[$i]
        $nl = $block.IndexOf("`n")
        if ($nl -lt 0) { $title = $block.Trim(); $body = '' } else { $title = $block.Substring(0, $nl).Trim(); $body = $block.Substring($nl + 1) }
        if ($title -match '^<.*>$') { continue }   # untouched template placeholder
        $e = [ordered]@{ session = $Session; title = $title; when = ''; by = ''; context = ''; options = ''; decision = ''; rationale = ''; impact = ''; text = ($title + "`n" + $body) }
        foreach ($l in ($body -split "\r?\n")) {
            $m = [regex]::Match($l, '^\s*[-*]\s*\*\*([^*:]+?):?\*\*:?\s*(.*)$')
            if (-not $m.Success) { continue }
            $k = $m.Groups[1].Value.Trim().ToLowerInvariant(); $v = (Clean-Link $m.Groups[2].Value)
            if ($k -eq 'when') { $e.when = $v }
            elseif ($k -eq 'by') { $e.by = $v }
            elseif ($k -eq 'context' -or $k -like 'question*') { $e.context = $v }
            elseif ($k -like 'options*') { $e.options = $v }
            elseif ($k -eq 'decision' -or $k -eq 'human decision') { $e.decision = $v }
            elseif ($k -like 'rationale*') { $e.rationale = $v }
            elseif ($k -eq 'impact') { $e.impact = $v }
        }
        $out += $e
    }
    return $out
}

$tracesDir = Join-Path $RepoRoot 'Traces'
$names7 = @('Decisions', 'HumanDecisions', 'Actions', 'Handovers', 'ToolsUsed', 'HumanActions', 'TokenUsage')
if (Test-Path -LiteralPath $tracesDir) {
    foreach ($sess in @(Get-ChildItem -LiteralPath $tracesDir -Directory -Filter 'Session-*' -ErrorAction SilentlyContinue | Sort-Object Name)) {
        $files = @()
        foreach ($n in $names7) {
            $p = Join-Path $sess.FullName ($n + '.md')
            $txt = Read-TextOrNull $p
            $present = ($null -ne $txt)
            $lines = 0; $trunc = $false; $body = ''
            if ($present) {
                $lines = @(Get-Lines $txt.TrimEnd("`r", "`n")).Count
                $body = $txt
                if ($body.Length -gt $MaxTraceChars) { $body = $body.Substring(0, $MaxTraceChars); $trunc = $true }
            }
            $files += [ordered]@{ name = $n; present = $present; lines = $lines; truncated = $trunc; text = $body }
            if ($present -and $n -eq 'Decisions') { $data.decisions += @(Parse-Decisions $txt $sess.Name $false) }
            if ($present -and $n -eq 'HumanDecisions') { $data.humanDecisions += @(Parse-Decisions $txt $sess.Name $true) }
        }
        $data.sessions += [ordered]@{ name = $sess.Name; files = $files }
    }
} else { $data.notes += 'No Traces/ folder yet (fast-track runs do not write traces).' }

# ---- memory ---------------------------------------------------------------------------------
$memText = Read-TextOrNull (Join-Path $RepoRoot 'memory/index.json')
if ($memText) {
    try {
        $mem = $memText | ConvertFrom-Json
        $entries = if ($mem.PSObject.Properties.Name -contains 'entries') { $mem.entries } else { $mem }
        $data.memory.total = @($entries).Count
    } catch { $data.notes += 'memory/index.json present but not parseable.' }
}

# ---- agent history (Claude Code transcripts) --------------------------------------------------
# Every headless session `kcc-run` starts (and every subagent it spawns) is a transcript under
# ~/.claude/projects/<workspace path with non-alphanumerics replaced by '-'>/. They record the
# resolved model, token usage and, per session, the cost summary. CLAUDE_CONFIG_DIR is honoured.
$MaxSessions = 80
function Get-ClaudeProjectDir([string]$Root = $RepoRoot) {
    $base = $env:CLAUDE_CONFIG_DIR
    if (-not $base) {
        $h = $env:USERPROFILE; if (-not $h) { $h = $env:HOME }
        if ($h) { $base = Join-Path $h '.claude' }
    }
    if (-not $base) { return '' }
    return (Join-Path (Join-Path $base 'projects') ([regex]::Replace($Root, '[^A-Za-z0-9]', '-')))
}
# A spec built in a lane (.kcc-lanes/SPEC-x, .worktrees/SPEC-x) runs its sessions with the lane as the working
# folder, so its transcripts live under the lane's own project folder, not the workspace's.
function Get-LaneRoots {
    $out = @()
    foreach ($ld in @('.kcc-lanes', '.worktrees')) {
        $lp = Join-Path $RepoRoot $ld
        if (Test-Path -LiteralPath $lp) { foreach ($d in @(Get-ChildItem -LiteralPath $lp -Directory -ErrorAction SilentlyContinue)) { $out += $d.FullName } }
    }
    return $out
}
function Get-RawTs([string]$line) {
    $m = [regex]::Match($line, '"timestamp"\s*:\s*"([^"]+)"')
    if ($m.Success) { return $m.Groups[1].Value }
    return ''
}
function Get-Utc([string]$s) {
    if (-not $s) { return $null }
    try { return [datetime]::Parse($s, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime() } catch { return $null }
}
# Totals for one transcript: dedupes by message id (a message is logged once per content block).
function Read-Transcript([string]$Path) {
    $res = [ordered]@{ first = ''; last = ''; effort = ''; label = ''; direct = ''; models = [ordered]@{}; cost = $null; ok = $false }
    $lines = $null
    try { $rd = Open-SharedReader $Path; try { $lines = @(); while ($null -ne ($ln = $rd.ReadLine())) { $lines += $ln } } finally { $rd.Dispose() } } catch { return $res }
    $byMsg = [ordered]@{}
    $effCount = @{}
    $seenUser = 0
    foreach ($line in $lines) {
        if (-not $line) { continue }
        $ts = Get-RawTs $line
        if ($ts) { if (-not $res.first) { $res.first = $ts }; $res.last = $ts }
        if ($line.Contains('"effort":"')) { $em = [regex]::Match($line, '"effort"\s*:\s*"([a-z]+)"'); if ($em.Success) { $effCount[$em.Groups[1].Value] = 1 + [int]$effCount[$em.Groups[1].Value] } }
        if (-not $res.label -and $seenUser -lt 60) {
            $seenUser++
            $lm = [regex]::Match($line, 'KCC run state (\d+) ([A-Z0-9-]+)(?: for (SPEC-[0-9A-Za-z]+))?(?: wave (\d+))?')
            if ($lm.Success) {
                $res.label = $lm.Value
                # `--fasttrack` worker states run AS the agent (claude --agent), with no orchestrator session above it.
                $dm0 = [regex]::Match($line, 'You are the ([a-z][a-z0-9-]*) agent running this state directly')
                if ($dm0.Success) { $res.direct = $dm0.Groups[1].Value }
            }
        }
        if ($line.Contains('"type":"assistant"') -and $line.Contains('"usage"')) {
            try { $o = $line | ConvertFrom-Json } catch { continue }
            $msg = $o.message
            if ($null -eq $msg -or $null -eq $msg.usage) { continue }
            $id = [string]$msg.id; if (-not $id) { $id = [string]$o.uuid }
            $byMsg[$id] = @{ model = [string]$msg.model; u = $msg.usage }
        } elseif ($line.Contains('"type":"cost-state"')) {
            $cm = [regex]::Match($line, '"totalCostUSD"\s*:\s*([0-9.eE+-]+)')
            if ($cm.Success) { $res.cost = [double]::Parse($cm.Groups[1].Value, [Globalization.CultureInfo]::InvariantCulture) }
        }
    }
    foreach ($k in $byMsg.Keys) {
        $e = $byMsg[$k]; $m = $e.model; if (-not $m) { $m = 'unknown' }
        if (-not $res.models.Contains($m)) { $res.models[$m] = [ordered]@{ input = 0; output = 0; cacheRead = 0; cacheWrite = 0; messages = 0 } }
        $t = $res.models[$m]; $u = $e.u
        $t.input += [int64]($u.input_tokens); $t.output += [int64]($u.output_tokens)
        $t.cacheRead += [int64]($u.cache_read_input_tokens); $t.cacheWrite += [int64]($u.cache_creation_input_tokens); $t.messages += 1
    }
    if ($effCount.Count -gt 0) { $res.effort = ($effCount.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 1).Key }
    $res.ok = ($res.first -ne '')
    return $res
}
function New-AgentRun($kind, $id, $parent, $agent, $desc, $tr, $label) {
    $in = 0; $out = 0; $cr = 0; $cw = 0; $top = ''; $topOut = -1
    foreach ($m in $tr.models.Keys) {
        $t = $tr.models[$m]; $in += $t.input; $out += $t.output; $cr += $t.cacheRead; $cw += $t.cacheWrite
        if ($t.output -gt $topOut) { $topOut = $t.output; $top = $m }
    }
    $a = Get-Utc $tr.first; $b = Get-Utc $tr.last; $dur = 0
    if ($a -and $b) { $dur = [int64]($b - $a).TotalMilliseconds }
    $state = ''; $stateName = ''; $spec = ''; $wave = ''
    if ($label) {
        $m = [regex]::Match($label, 'state (\d+) ([A-Z0-9-]+)(?: for (SPEC-[0-9A-Za-z]+))?(?: wave (\d+))?')
        if ($m.Success) { $state = $m.Groups[1].Value; $stateName = $m.Groups[2].Value; $spec = $m.Groups[3].Value; $wave = $m.Groups[4].Value }
    }
    if (-not $spec) { $sm = [regex]::Match([string]$desc, 'SPEC-[0-9A-Za-z]+'); if ($sm.Success) { $spec = $sm.Value } }
    return [ordered]@{
        id = $id; kind = $kind; parent = $parent; agent = $agent; description = $desc
        state = $state; stateName = $stateName; spec = $spec; wave = $wave
        started = $tr.first; ended = $tr.last; durationMs = $dur
        model = $top; effort = $tr.effort; effortSource = ($(if ($tr.effort) { 'transcript' } else { '' }))
        tokens = [ordered]@{ input = $in; output = $out; cacheRead = $cr; cacheWrite = $cw }
        models = $tr.models; costUSD = $tr.cost
    }
}

$projDir = Get-ClaudeProjectDir
$profiles = @{}
$agentsDir = Join-Path $RepoRoot '.claude/agents'
if (Test-Path -LiteralPath $agentsDir) {
    foreach ($f in @(Get-ChildItem -LiteralPath $agentsDir -Filter '*.md' -File -ErrorAction SilentlyContinue)) {
        $t = Read-TextOrNull $f.FullName
        $nm = Get-Frontmatter $t 'name'; if (-not $nm) { $nm = $f.BaseName }
        $profiles[$nm] = [ordered]@{ name = $nm; model = (Get-Frontmatter $t 'model'); effort = (Get-Frontmatter $t 'effort') }
    }
}
$data['profiles'] = @($profiles.Values | Sort-Object { $_.name })
$agentRuns = @()
$projDirs = @(); if ($projDir) { $projDirs += $projDir }
foreach ($lr0 in @(Get-LaneRoots)) { $lpd = Get-ClaudeProjectDir $lr0; if ($lpd) { $projDirs += $lpd } }
$projDirs = @($projDirs | Where-Object { Test-Path -LiteralPath $_ })
if ($projDirs.Count -gt 0) {
    $sessions = @($projDirs | ForEach-Object { Get-ChildItem -LiteralPath $_ -Filter '*.jsonl' -File -ErrorAction SilentlyContinue } | Sort-Object LastWriteTime -Descending)
    if ($sessions.Count -gt $MaxSessions) { $data.notes += ('Agent history shows the newest ' + $MaxSessions + ' of ' + $sessions.Count + ' Claude sessions.'); $sessions = @($sessions | Select-Object -First $MaxSessions) }
    foreach ($sf in $sessions) {
        $sid = $sf.BaseName
        $tr = Read-Transcript $sf.FullName
        if (-not $tr.ok) { continue }
        $label = $tr.label
        $agentName = 'main session'; if ($tr.direct) { $agentName = $tr.direct }
        $srun = New-AgentRun 'session' $sid '' $agentName $label $tr $label
        $srun['mode'] = $(if ($tr.direct) { 'direct' } else { 'orchestrator' })
        if ($tr.direct -and $profiles.Contains($tr.direct)) { $srun['profileModel'] = $profiles[$tr.direct].model }
        $agentRuns += $srun
        $subDir = Join-Path (Join-Path $sf.DirectoryName $sid) 'subagents'
        if (Test-Path -LiteralPath $subDir) {
            foreach ($jf in @(Get-ChildItem -LiteralPath $subDir -Filter 'agent-*.jsonl' -File -ErrorAction SilentlyContinue | Sort-Object Name)) {
                $metaText = Read-TextOrNull ([System.IO.Path]::ChangeExtension($jf.FullName, '.meta.json'))
                $atype = ''; $adesc = ''
                if ($metaText) {
                    $am = [regex]::Match($metaText, '"agentType"\s*:\s*"([^"]*)"'); if ($am.Success) { $atype = $am.Groups[1].Value }
                    $dm = [regex]::Match($metaText, '"description"\s*:\s*"((?:[^"\\]|\\.)*)"'); if ($dm.Success) { $adesc = [regex]::Unescape($dm.Groups[1].Value) }
                }
                if (-not $atype) { $atype = 'subagent' }
                $str = Read-Transcript $jf.FullName
                if (-not $str.ok) { continue }
                $run = New-AgentRun 'subagent' ($sid + '/' + $jf.BaseName) $sid $atype $adesc $str $label
                $run['mode'] = 'subagent'
                if ($profiles.Contains($atype)) { $run['effort'] = $profiles[$atype].effort; $run['effortSource'] = 'profile'; $run['profileModel'] = $profiles[$atype].model }
                $agentRuns += $run
            }
        }
    }
}
$data['agents'] = $agentRuns

# A chat run has no driver to say it stopped. When nothing happened for 30 minutes (no event, no agent
# transcript written), the run is idle: the page must not keep a timer running on it.
if ($script:derivedRun -and $data.run -and $data.run.status -eq 'running') {
    $lastAct = [DateTime]::MinValue
    foreach ($e in @($data.events)) { $t = Get-Utc $e.ts; if ($t -and $t -gt $lastAct) { $lastAct = $t } }
    foreach ($a in @($agentRuns)) { $t = Get-Utc $a.ended; if ($t -and $t -gt $lastAct) { $lastAct = $t } }
    if ($lastAct -ne [DateTime]::MinValue -and ([DateTime]::UtcNow - $lastAct).TotalMinutes -gt 30) {
        $data.run.status = 'idle'
        $data.run.reason = ('no event or agent activity since ' + $lastAct.ToString('yyyy-MM-ddTHH:mm:ssZ') + '; resume with: auto resume')
        $data.notes += 'Run marked idle: nothing happened for more than 30 minutes.'
    }
}

# ---- stage timing: one row per harness dispatch (coordination/run/logs/state-*.log) -------------------
# The log header carries the start time; the last write is the end (the harness writes at exit).
$runLogs = @()
$logDirs = @($RepoRoot)
foreach ($lr1 in @(Get-LaneRoots)) { $logDirs += $lr1 }
foreach ($root1 in $logDirs) {
    $logDir = Join-Path $root1 'coordination/run/logs'
    if (-not (Test-Path -LiteralPath $logDir)) { continue }
    $relBase = ''; if ($root1 -ne $RepoRoot) { $relBase = ($root1.Substring($RepoRoot.Length).TrimStart('\', '/') -replace '\\', '/') + '/' }
    foreach ($lf in @(Get-ChildItem -LiteralPath $logDir -Filter 'state-*.log' -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTimeUtc)) {
        $lm = [regex]::Match($lf.Name, '^state-(\d+)-(run|SPEC-[0-9A-Za-z]+)(?:-w(\d+))?-(\d+|install)\.log$')
        if (-not $lm.Success) { continue }
        $first = ''
        $first = Read-FirstLine $lf.FullName
        $hm = [regex]::Match($first, '^# kcc-run (\S+)')
        $sp = $lm.Groups[2].Value; if ($sp -eq 'run') { $sp = '' }
        $runLogs += [ordered]@{
            state = [int]$lm.Groups[1].Value; spec = $sp; wave = $lm.Groups[3].Value; attempt = $lm.Groups[4].Value
            started = $(if ($hm.Success) { $hm.Groups[1].Value } else { '' })
            ended = $lf.LastWriteTimeUtc.ToString('yyyy-MM-ddTHH:mm:ssZ'); file = ($relBase + 'coordination/run/logs/' + $lf.Name)
        }
    }
}
$data['runLogs'] = $runLogs

# ---- lanes: git worktrees (.worktrees/) and kcc run lanes (.kcc-lanes/) where specs are being built ----
$lanes = @()
foreach ($ld in @('.worktrees', '.kcc-lanes')) {
    $lp = Join-Path $RepoRoot $ld
    if (-not (Test-Path -LiteralPath $lp)) { continue }
    foreach ($d in @(Get-ChildItem -LiteralPath $lp -Directory -ErrorAction SilentlyContinue)) {
        $src = Join-Path $d.FullName 'src'
        $files = @(); if (Test-Path -LiteralPath $src) { $files = @(Get-ChildItem -LiteralPath $src -Recurse -File -ErrorAction SilentlyContinue | Where-Object { $_.FullName -notmatch '[\\/]node_modules[\\/]' }) }
        $last = $d.LastWriteTimeUtc; foreach ($f in $files) { if ($f.LastWriteTimeUtc -gt $last) { $last = $f.LastWriteTimeUtc } }
        $sm = [regex]::Match($d.Name, 'SPEC-[0-9A-Za-z]+')
        # A kcc lane runs its own kcc-run: its state, wave and status say which stage the spec is in.
        $lr = $null; $lrp = Join-Path $d.FullName 'coordination/run/run.json'
        if (Test-Path -LiteralPath $lrp) { try { $lr = [System.IO.File]::ReadAllText($lrp) | ConvertFrom-Json } catch { $lr = $null } }
        $lanes += [ordered]@{ name = $d.Name; kind = $ld.TrimStart('.'); spec = $sm.Value; files = $files.Count; updated = $last.ToString('yyyy-MM-ddTHH:mm:ssZ')
            runState = $(if ($lr) { [string]$lr.state } else { '' }); runWave = $(if ($lr) { [string]$lr.wave } else { '' }); runStatus = $(if ($lr) { [string]$lr.status } else { '' }) }
    }
}
$data['lanes'] = $lanes

# ---- fill the template ------------------------------------------------------------------------
$tplPath = Join-Path $RepoRoot '.KCC/kernel/templates/dashboard.html'
if ($Template) { $tplPath = $Template }
if (-not (Test-Path -LiteralPath $tplPath)) { $tplPath = Join-Path (Split-Path -Parent $ToolDir) 'kernel/templates/dashboard.html' }
$tpl = Read-TextOrNull $tplPath
if (-not $tpl) { [Console]::Error.WriteLine("dashboard template not found: $tplPath"); exit 2 }

$json = ConvertTo-Json -InputObject $data -Depth 14 -Compress
$json = $json.Replace('</', '<\/').Replace([string][char]0x2028, ' ').Replace([string][char]0x2029, ' ')
$html = $tpl.Replace('__KCC_DATA__', $json)

$outDir = Join-Path $RepoRoot 'dashboard'
if (-not (Test-Path -LiteralPath $outDir)) { New-Item -ItemType Directory -Path $outDir | Out-Null }
$outFile = Join-Path $outDir 'index.html'
[System.IO.File]::WriteAllText($outFile, $html, (New-Object System.Text.UTF8Encoding($false)))

Write-Host "Dashboard written to $outFile"
Write-Host ("  ideas={0} specs={1} events={2} checkpoints={3} sessions={4} decisions={5}" -f @($data.ideas).Count, @($data.specs).Count, @($data.events).Count, @($data.checkpoints).Count, @($data.sessions).Count, (@($data.decisions).Count + @($data.humanDecisions).Count))
# A lane (<root>/.kcc-lanes/SPEC-x) builds its own page, but the page people look at is the workspace's. Rebuild that one
# too, so lane activity reaches it even when the scheduler that normally refreshes it is not running.
$parentRoot = $null
if (($env:KCC_DASH_PARENT -ne '1') -and ($RepoRoot -match '[\\/]\.kcc-lanes[\\/][^\\/]+$')) { $parentRoot = Split-Path -Parent (Split-Path -Parent $RepoRoot) }
if ($parentRoot -and (Test-Path -LiteralPath (Join-Path $parentRoot 'coordination/lanes.json')) -and (Test-Path -LiteralPath (Join-Path $parentRoot '.KCC/tools/build-dashboard.ps1'))) {
    $env:KCC_DASH_PARENT = '1'
    try { & (Join-Path $parentRoot '.KCC/tools/build-dashboard.ps1') -RepoRoot $parentRoot *> $null } catch { } finally { $env:KCC_DASH_PARENT = $null }
}
if ($Open) {
    # KCC_OPEN_LOG: automation hook. Record the path instead of launching a browser.
    # KCC_DASHBOARD_URL: `kcc run` serves a live page; open that instead of the file so the page stays current.
    $openTarget = $outFile; if ($env:KCC_DASHBOARD_URL) { $openTarget = $env:KCC_DASHBOARD_URL }
    if ($env:KCC_OPEN_LOG) { Add-Content -LiteralPath $env:KCC_OPEN_LOG -Value $openTarget } else { Start-Process $openTarget }
}
