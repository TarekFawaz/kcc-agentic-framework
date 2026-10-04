<#
KCC framework (c) 2026 Tarek Fawaz, https://tikasway.dev/kcc. Licensed under the terms in LICENSE.

.SYNOPSIS
    AC -> Test ID -> test file -> PASS result traceability gate.

.DESCRIPTION
    For each spec (or -Spec):
      1. every AC-n in every Backlog Story/Enabler item has >=1 Test ID row in
         plan.md '## Atomic test cases'                          (TRC-000/001, planner)
      2. every such Test ID appears in a test file under src/IDEA-{ID}-*/
         (T-001, T_001 and T001 spellings are accepted)          (TRC-005/002, implementer)
      3. every such Test ID has a PASS result: a line in
         TestResults/IDEA-{ID}/SPEC-{ID}/test-run-summary.md containing the ID
         and PASS, or a JUnit <testcase> under TestResults/ whose name contains
         the ID and has no failure/error/skipped child         (TRC-003 verifier, TRC-004 implementer)

    Read-only. PowerShell 5.1 compatible. Contract: kernel/contracts/tool-contract.md.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .KCC\tools\check-traceability.ps1 -Spec SPEC-001 -Json
#>

[CmdletBinding()]
param(
    [string]$RepoRoot,
    [string]$Spec,
    [string]$Scope = 'all',
    [switch]$Json
)

$ErrorActionPreference = 'Stop'
$ToolVersion = '1.0.0'
if ($PSScriptRoot) { $ToolDir = $PSScriptRoot } else { $ToolDir = Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $RepoRoot) {
    $parent = Split-Path -Parent $ToolDir
    if ((Split-Path -Leaf $parent) -eq '.KCC') { $RepoRoot = Split-Path -Parent $parent } else { $RepoRoot = $parent }
}
if (-not (Test-Path -LiteralPath $RepoRoot)) { [Console]::Error.WriteLine("workspace not found: $RepoRoot"); exit 2 }
$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path.TrimEnd('\', '/')

$violations = New-Object System.Collections.ArrayList
function Add-Violation([string]$Code, [string]$Severity, [string]$Owner, [string]$Message, [string]$File = '') {
    [void]$violations.Add([pscustomobject]@{ id = $Code; severity = $Severity; fix_owner = $Owner; file = $File; message = $Message })
}
function Read-Text([string]$path) { try { return [System.IO.File]::ReadAllText($path) } catch { return '' } }
function Read-Lines([string]$path) { try { return , ([string[]][System.IO.File]::ReadAllLines($path)) } catch { return , ([string[]]@()) } }
function Get-RelPath([string]$full) {
    if ($full.Length -le $RepoRoot.Length) { return $full }
    return ($full.Substring($RepoRoot.Length)).TrimStart('\', '/').Replace('\', '/')
}
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
function Get-CellTrim([string]$s) { return ($s -replace '^[\s\*`]+', '' -replace '[\s\*`]+$', '') }
function Test-SeparatorRow([string]$l) { return ($l -match '^\s*\|[\s:|-]*$') }

function Get-BacklogDir([string]$specDir) {
    # Return the on-disk folder (Backlog preferred, legacy backlog accepted) with its real casing.
    $cands = @(Get-ChildItem -LiteralPath $specDir -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -ieq 'backlog' })
    if ($cands.Count -eq 0) { return $null }
    foreach ($c in $cands) { if ($c.Name -ceq 'Backlog') { return $c.FullName } }
    return $cands[0].FullName
}
function Get-Items($sp) {
    $out = New-Object System.Collections.ArrayList
    $bd = Get-BacklogDir $sp.Dir
    if (-not $bd) { return , @() }
    foreach ($f in @(Get-ChildItem -LiteralPath $bd -File -Filter '*.md' -ErrorAction SilentlyContinue | Sort-Object Name)) {
        $m = [regex]::Match($f.Name, '^(Story|Enabler|Bug)-\d+')
        if ($m.Success) { [void]$out.Add([pscustomobject]@{ Key = $m.Value; Type = $m.Groups[1].Value; File = $f.FullName }) }
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
        if ($ii -ge 0 -and $ii -lt $cells.Count) { $m = [regex]::Match($cells[$ii], '(Story|Enabler|Bug)-\d+'); if ($m.Success) { $item = $m.Value } }
        $ac = ''
        if ($ai -ge 0 -and $ai -lt $cells.Count) { $ac = Get-CellTrim $cells[$ai] }
        [void]$out.Add([pscustomobject]@{ Id = $id; Item = $item; AC = $ac })
    }
    return , ($out.ToArray())
}
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
function Get-AllSpecs {
    $out = New-Object System.Collections.ArrayList
    $specsDir = Join-Path $RepoRoot 'specs'
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
        [void]$out.Add([pscustomobject]@{ Id = $m.Value; Name = $d.Name; Dir = $d.FullName; File = $note; IdeaId = $ideaId })
    }
    return , ($out.ToArray())
}
function Test-SpecMatch($sp) {
    if (-not $Spec) { return $true }
    $s = $Spec.ToLower(); $n = $sp.Name.ToLower()
    return (($n -eq $s) -or $n.StartsWith($s + '-') -or ($sp.Id.ToLower() -eq $s))
}

# Test ID -> case-sensitive regex accepting T-001 / T_001 / T001.
function Get-IdPattern([string]$id) {
    $m = [regex]::Match($id, '^([A-Za-z]+)[-_]?(\d+)$')
    if ($m.Success) { $core = $m.Groups[1].Value + '[-_]?' + $m.Groups[2].Value }
    else { $core = [regex]::Escape($id) }
    return ('(?<![A-Za-z0-9])' + $core + '(?![0-9])')
}

$ExcludedDirs = @('node_modules', '.git', 'bin', 'obj', 'dist', 'build', '.venv', 'venv', '__pycache__', 'target', '.next', 'coverage')
$DocExt = @('.md', '.txt', '.log', '.lock', '.csv', '.png', '.jpg', '.jpeg', '.gif', '.svg', '.pdf', '.ico')
function Get-TestFiles([string]$root) {
    $out = New-Object System.Collections.ArrayList
    foreach ($f in @(Get-ChildItem -LiteralPath $root -Recurse -File -ErrorAction SilentlyContinue)) {
        $rel = $f.FullName.Substring($root.Length).Replace('\', '/').ToLower()
        $skip = $false
        foreach ($seg in $rel.Split('/')) { if ($ExcludedDirs -contains $seg) { $skip = $true; break } }
        if ($skip) { continue }
        if ($DocExt -contains $f.Extension.ToLower()) { continue }
        if ($rel -match '(test|spec)') { [void]$out.Add($f.FullName) }
    }
    return , ($out.ToArray())
}

# JUnit testcases for one spec: list of {Name, Status} where Status in pass|fail|skip.
# Scope: XML under TestResults/IDEA-{ID}/SPEC-{ID}/, plus shared XML anywhere under
# TestResults/ that is not inside some other IDEA-*/SPEC-* folder (Test IDs are per spec).
function Get-JUnitCases([string]$IdeaId, [string]$SpecId) {
    $out = New-Object System.Collections.ArrayList
    $tr = Join-Path $RepoRoot 'TestResults'
    if (-not (Test-Path -LiteralPath $tr)) { return , @() }
    $own = ('/' + $IdeaId + '/' + $SpecId + '/').ToLower()
    foreach ($x in @(Get-ChildItem -LiteralPath $tr -Recurse -File -Filter '*.xml' -ErrorAction SilentlyContinue)) {
        $rel = ('/' + $x.FullName.Substring($tr.Length).TrimStart('\', '/').Replace('\', '/')).ToLower()
        $inSpecDir = [regex]::IsMatch($rel, '^/idea-[^/]+/spec-[^/]+/')
        if ($inSpecDir -and -not $rel.StartsWith($own)) { continue }
        $t = (Read-Text $x.FullName) -replace "[\r\n]", ' '
        $chunks = [regex]::Split($t, '<testcase')
        for ($i = 1; $i -lt $chunks.Count; $i++) {
            $c = $chunks[$i]
            $nm = [regex]::Match($c, '\sname="([^"]*)"')
            if (-not $nm.Success) { continue }
            $st = 'pass'
            if ($c -match '<failure' -or $c -match '<error') { $st = 'fail' } elseif ($c -match '<skipped') { $st = 'skip' }
            [void]$out.Add([pscustomobject]@{ Name = $nm.Groups[1].Value; Status = $st })
        }
    }
    return , ($out.ToArray())
}

$allSpecs = Get-AllSpecs
$specs = @($allSpecs | Where-Object { Test-SpecMatch $_ })
if ($Spec -and $specs.Count -eq 0) {
    Add-Violation 'TRC-000' 'error' 'planner' ("No spec folder matches {0}." -f $Spec) 'specs'
}

foreach ($sp in $specs) {
    $plan = Join-Path $sp.Dir 'plan.md'
    $prel = (Get-RelPath $sp.Dir) + '/plan.md'
    # Without -Spec only specs at review/done (or with a review.md) are traced.
    if (-not $Spec) {
        $rank = Get-StatusRank ([string](Get-KeyTableField (Read-Lines $sp.File) 'Status'))
        if ($rank -lt 4 -and -not (Test-Path -LiteralPath (Join-Path $sp.Dir 'review.md'))) { continue }
    }
    $allItems = Get-Items $sp
    $items = @($allItems | Where-Object { $_.Type -ne 'Bug' })
    if ($items.Count -eq 0) { continue }
    if (-not (Test-Path -LiteralPath $plan)) {
        Add-Violation 'TRC-000' 'error' 'planner' ("{0} has no plan.md, so no AC can be traced to a Test ID." -f $sp.Name) $prel
        continue
    }
    $tests = Get-PlanTests $plan
    $ids = New-Object System.Collections.ArrayList
    foreach ($it in $items) {
        foreach ($ac in (Get-ItemACs $it.File)) {
            $hit = $false
            foreach ($t in $tests) {
                if ($t.Item -eq $it.Key -and [regex]::IsMatch($t.AC, ([regex]::Escape($ac) + '(?![0-9])'))) {
                    $hit = $true
                    if (-not $ids.Contains($t.Id)) { [void]$ids.Add($t.Id) }
                }
            }
            if (-not $hit) {
                Add-Violation 'TRC-001' 'error' 'planner' ("{0} {1} {2} has no Test ID in plan.md atomic test cases." -f $sp.Id, $it.Key, $ac) $prel
            }
        }
    }
    if ($ids.Count -eq 0) { continue }

    # Test files under src/IDEA-{ID}-*/
    $srcDirs = @()
    $srcRoot = Join-Path $RepoRoot 'src'
    if ($sp.IdeaId -and (Test-Path -LiteralPath $srcRoot)) {
        $srcDirs = @(Get-ChildItem -LiteralPath $srcRoot -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -like ($sp.IdeaId + '-*') -or $_.Name -eq $sp.IdeaId })
    }
    $testTexts = New-Object System.Collections.ArrayList
    if ($srcDirs.Count -eq 0) {
        Add-Violation 'TRC-005' 'error' 'implementer' ("No source workspace src/{0}-*/ exists for {1}." -f $sp.IdeaId, $sp.Id) ('src/' + $sp.IdeaId)
    }
    else {
        foreach ($sd in $srcDirs) { foreach ($f in (Get-TestFiles $sd.FullName)) { [void]$testTexts.Add((Read-Text $f)) } }
    }

    # Result sources
    $junit = Get-JUnitCases $sp.IdeaId $sp.Id
    $summaryLines = @()
    $trDir = Join-Path $RepoRoot 'TestResults'
    $summary = $null
    if ($sp.IdeaId) { $summary = Join-Path (Join-Path (Join-Path $trDir $sp.IdeaId) $sp.Id) 'test-run-summary.md' }
    if ($summary -and (Test-Path -LiteralPath $summary)) { $summaryLines = Read-Lines $summary }
    $srel = 'TestResults/' + $sp.IdeaId + '/' + $sp.Id + '/test-run-summary.md'

    foreach ($id in $ids) {
        $pat = Get-IdPattern $id
        if ($srcDirs.Count -gt 0) {
            $found = $false
            foreach ($tt in $testTexts) { if ([regex]::IsMatch($tt, $pat)) { $found = $true; break } }
            if (-not $found) {
                Add-Violation 'TRC-002' 'error' 'implementer' ("{0} Test ID {1} is not referenced by any test file under src/{2}-*/." -f $sp.Id, $id, $sp.IdeaId) ('src/' + $sp.IdeaId)
            }
        }
        $pass = $false; $fail = $false
        foreach ($l in $summaryLines) {
            if ([regex]::IsMatch($l, $pat)) {
                if ($l -match '(?i)\bFAIL(ED|URE)?\b') { $fail = $true }
                elseif ($l -match '(?i)\bPASS(ED)?\b') { $pass = $true }
            }
        }
        foreach ($jc in $junit) {
            if ([regex]::IsMatch($jc.Name, $pat)) {
                if ($jc.Status -eq 'pass') { $pass = $true } elseif ($jc.Status -eq 'fail') { $fail = $true }
            }
        }
        if (-not $pass) {
            if ($fail) {
                Add-Violation 'TRC-004' 'error' 'implementer' ("{0} Test ID {1} has a FAIL result." -f $sp.Id, $id) $srel
            }
            else {
                Add-Violation 'TRC-003' 'error' 'verifier' ("{0} Test ID {1} has no PASS result in test-run-summary.md or JUnit XML under TestResults/." -f $sp.Id, $id) $srel
            }
        }
    }
}

$errors = @($violations | Where-Object { $_.severity -eq 'error' })
$warnings = @($violations | Where-Object { $_.severity -eq 'warning' })
$status = 'pass'
if ($errors.Count -gt 0) { $status = 'fail' }
if ($Json) {
    [pscustomobject]@{
        tool = 'check-traceability'; version = $ToolVersion; scope = $Scope; spec = $Spec
        errors = $errors.Count; warnings = $warnings.Count; status = $status; violations = $violations
    } | ConvertTo-Json -Depth 5
}
else {
    Write-Output ("KCC traceability: {0}" -f $RepoRoot)
    foreach ($v in $violations) {
        Write-Output ("[{0}] {1} ({2}) {3}: {4}" -f $v.severity.ToUpper(), $v.id, $v.fix_owner, $v.file, $v.message)
    }
    Write-Output ("Errors: {0}  Warnings: {1}" -f $errors.Count, $warnings.Count)
}
if ($errors.Count -gt 0) { exit 1 } else { exit 0 }
