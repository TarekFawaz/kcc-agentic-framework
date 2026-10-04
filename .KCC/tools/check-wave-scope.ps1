<#
KCC framework (c) 2026 Tarek Fawaz, https://tikasway.dev/kcc. Licensed under the terms in LICENSE.

.SYNOPSIS
    Wave scope gate: every changed file under src/ must be declared in the
    Impacted Files of an item planned for that wave.

.DESCRIPTION
    Waves come from plan.md '## Waves' (legacy fallback: parallelization.md).
    Changed files:
      git repo  - git diff --name-only <Base> plus untracked files. Base default:
                  newest kcc/cp-* tag, else HEAD (working tree vs HEAD).
      no git    - compare src/ against coordination/checkpoints/latest.manifest
                  (path<TAB>sha256), or the manifest file given as -Base.
    Also accepted: paths/globs a wave item declares in plan.md
    '## Wave file allowances' (| Item | `path` `glob/**` |; item 'any' = every
    wave) for tests, project and lock files beyond the item's Impacted Files.
    Generated folders (node_modules, __pycache__, bin, obj, dist, build, .venv,
    venv, target, coverage, .pytest_cache) are ignored.

    IDs: WAVE-001 implementer (undeclared change), WAVE-002 implementer
    (-TestCommand failed), WAVE-003 planner (wave missing from plan.md).
    Exit 2 on usage/environment errors (missing -Spec/-Wave, unknown spec,
    bad base, no git and no manifest).

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .KCC\tools\check-wave-scope.ps1 -Spec SPEC-001 -Wave 2 -TestCommand "pytest -q" -Json
#>

[CmdletBinding()]
param(
    [string]$RepoRoot,
    [string]$Spec,
    [string]$Wave,
    [string]$Base,
    [string]$TestCommand,
    [string]$Scope = 'all',
    [switch]$Json
)

$ErrorActionPreference = 'Stop'
$ToolVersion = '1.0.0'
function Fail-Usage([string]$msg) { [Console]::Error.WriteLine($msg); exit 2 }

if ($PSScriptRoot) { $ToolDir = $PSScriptRoot } else { $ToolDir = Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $RepoRoot) {
    $parent = Split-Path -Parent $ToolDir
    if ((Split-Path -Leaf $parent) -eq '.KCC') { $RepoRoot = Split-Path -Parent $parent } else { $RepoRoot = $parent }
}
if (-not (Test-Path -LiteralPath $RepoRoot)) { Fail-Usage "workspace not found: $RepoRoot" }
$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path.TrimEnd('\', '/')
if (-not $Spec) { Fail-Usage 'usage: check-wave-scope -Spec SPEC-{ID} -Wave N [-Base <ref|manifest>] [-TestCommand "<cmd>"] [-Json]' }
if (-not ($Wave -match '^\d+$')) { Fail-Usage '-Wave N is required (a number).' }
$WaveN = [string][int]$Wave

$violations = New-Object System.Collections.ArrayList
function Add-Violation([string]$Code, [string]$Severity, [string]$Owner, [string]$Message, [string]$File = '') {
    [void]$violations.Add([pscustomobject]@{ id = $Code; severity = $Severity; fix_owner = $Owner; file = $File; message = $Message })
}
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
    $cands = @(Get-ChildItem -LiteralPath $specDir -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -ieq 'backlog' })
    if ($cands.Count -eq 0) { return $null }
    foreach ($c in $cands) { if ($c.Name -ceq 'Backlog') { return $c.FullName } }
    return $cands[0].FullName
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
            foreach ($mk in [regex]::Matches($s, $keyRx)) { [void]$out.Add([pscustomobject]@{ Wave = $w; Item = $mk.Value }) }
        }
    }
    return , ($out.ToArray())
}

$IgnoredSegments = @('node_modules', '__pycache__', 'bin', 'obj', 'dist', 'build', '.venv', 'venv', 'target', 'coverage', '.pytest_cache')
function Test-Ignored([string]$rel) {
    foreach ($seg in $rel.ToLower().Split('/')) { if ($IgnoredSegments -contains $seg) { return $true } }
    return $false
}

function Invoke-Git([string[]]$GitArgs) {
    $old = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $out = @()
    $code = 1
    try {
        $out = @(& git -C $RepoRoot -c core.quotepath=off @GitArgs 2>$null)
        $code = $LASTEXITCODE
    }
    catch { $code = 1 }
    $ErrorActionPreference = $old
    return [pscustomobject]@{ Code = $code; Out = $out }
}

# --- locate spec ---
$specDir = $null
$specsRoot = Join-Path $RepoRoot 'specs'
if (Test-Path -LiteralPath $specsRoot) {
    foreach ($d in @(Get-ChildItem -LiteralPath $specsRoot -Recurse -Directory -Filter 'SPEC-*' -ErrorAction SilentlyContinue | Sort-Object FullName)) {
        if (-not (Test-Path -LiteralPath (Join-Path $d.FullName ($d.Name + '.md')))) { continue }
        $n = $d.Name.ToLower(); $s = $Spec.ToLower()
        $id = [regex]::Match($d.Name, '^SPEC-\d+').Value.ToLower()
        if ($n -eq $s -or $n.StartsWith($s + '-') -or $id -eq $s) { $specDir = $d.FullName; break }
    }
}
if (-not $specDir) { Fail-Usage "no spec folder matches $Spec" }

# --- declared files for the wave ---
$planLines = @()
$plan = Join-Path $specDir 'plan.md'
if (Test-Path -LiteralPath $plan) { $planLines = Get-Section (Read-Lines $plan) 'waves' }
if ($planLines.Count -eq 0) {
    $par = Join-Path $specDir 'parallelization.md'
    if (Test-Path -LiteralPath $par) {
        $pl = Read-Lines $par
        $planLines = Get-Section $pl 'waves'
        if ($planLines.Count -eq 0) { $planLines = $pl }
    }
}
$waveItems = New-Object System.Collections.ArrayList
foreach ($w in (ConvertTo-WaveList $planLines)) {
    if ($w.Wave -eq $WaveN -and -not $waveItems.Contains($w.Item)) { [void]$waveItems.Add($w.Item) }
}
$declared = New-Object System.Collections.ArrayList
$bd = Get-BacklogDir $specDir
foreach ($it in $waveItems) {
    if (-not $bd) { break }
    foreach ($f in @(Get-ChildItem -LiteralPath $bd -File -Filter ($it + '*.md') -ErrorAction SilentlyContinue)) {
        if (-not [regex]::IsMatch($f.Name, ('^' + [regex]::Escape($it) + '(?![0-9])'))) { continue }
        foreach ($p in (Get-ImpactedFiles $f.FullName)) { [void]$declared.Add($p.ToLower()) }
    }
}
# Plan-declared allowances: plan.md '## Wave file allowances' rows
# '| Story-001 | `src/.../tests/x/**` `src/.../*.csproj` |'. Item 'any' applies to every wave.
if (Test-Path -LiteralPath $plan) {
    foreach ($l in (Get-Section (Read-Lines $plan) 'wave file allowances')) {
        if (-not ($l -match '^\s*\|') -or (Test-SeparatorRow $l)) { continue }
        $cells = $l.Split('|')
        if ($cells.Count -lt 3) { continue }
        $item = Get-CellTrim $cells[1]
        if (-not (($item -ieq 'any') -or $waveItems.Contains($item))) { continue }
        for ($c = 2; $c -lt $cells.Count; $c++) {
            foreach ($m in [regex]::Matches($cells[$c], '`([^`]+)`')) {
                $p = $m.Groups[1].Value.Trim().Replace('\', '/')
                if ($p.StartsWith('./')) { $p = $p.Substring(2) }
                if ($p.EndsWith('/**')) { $p = $p.Substring(0, $p.Length - 2) }
                if ($p) { [void]$declared.Add($p.ToLower()) }
            }
        }
    }
}
$prel = (Get-RelPath $specDir) + '/plan.md'
if ($waveItems.Count -eq 0) {
    Add-Violation 'WAVE-003' 'error' 'planner' ("{0} has no items for wave {1} in plan.md '## Waves' (or legacy parallelization.md)." -f (Split-Path -Leaf $specDir), $WaveN) $prel
}

# --- changed files ---
$changed = New-Object System.Collections.ArrayList
$mode = ''
$baseUsed = ''
$inGit = (Invoke-Git @('rev-parse', '--is-inside-work-tree')).Code -eq 0
if ($inGit) {
    $mode = 'git'
    $hasHead = (Invoke-Git @('rev-parse', '--verify', '--quiet', 'HEAD^{commit}')).Code -eq 0
    if ($Base) { $baseUsed = $Base }
    elseif ($hasHead) {
        $tags = (Invoke-Git @('tag', '-l', 'kcc/cp-*', '--sort=-creatordate')).Out
        if ($tags.Count -gt 0 -and $tags[0]) { $baseUsed = [string]$tags[0] } else { $baseUsed = 'HEAD' }
    }
    if ($baseUsed) {
        if ((Invoke-Git @('rev-parse', '--verify', '--quiet', ($baseUsed + '^{commit}'))).Code -ne 0) { Fail-Usage "git base not found: $baseUsed" }
        $r = Invoke-Git @('diff', '--name-only', '--relative', $baseUsed)
        foreach ($p in $r.Out) { if ($p) { [void]$changed.Add([string]$p) } }
    }
    else {
        $baseUsed = '(no commits)'
        foreach ($p in (Invoke-Git @('ls-files')).Out) { if ($p) { [void]$changed.Add([string]$p) } }
    }
    foreach ($p in (Invoke-Git @('ls-files', '--others', '--exclude-standard')).Out) { if ($p -and -not $changed.Contains([string]$p)) { [void]$changed.Add([string]$p) } }
}
else {
    $manifest = Join-Path (Join-Path (Join-Path $RepoRoot 'coordination') 'checkpoints') 'latest.manifest'
    if ($Base) {
        if (Test-Path -LiteralPath $Base -PathType Leaf) { $manifest = (Resolve-Path -LiteralPath $Base).Path }
        elseif (Test-Path -LiteralPath (Join-Path $RepoRoot $Base) -PathType Leaf) { $manifest = Join-Path $RepoRoot $Base }
        else { Fail-Usage "not a git repository and base manifest not found: $Base" }
    }
    if (-not (Test-Path -LiteralPath $manifest)) { Fail-Usage 'not a git repository and no coordination/checkpoints/latest.manifest to compare against.' }
    $mode = 'manifest'
    $baseUsed = Get-RelPath $manifest
    $known = @{}
    foreach ($l in (Read-Lines $manifest)) {
        $parts = $l.Split("`t")
        if ($parts.Count -lt 2) { continue }
        $p = $parts[0].Trim().Replace('\', '/')
        if ($p.StartsWith('./')) { $p = $p.Substring(2) }
        if ($p) { $known[$p.ToLower()] = @($p, $parts[1].Trim().ToLower()) }
    }
    $srcDir = Join-Path $RepoRoot 'src'
    $seen = @{}
    if (Test-Path -LiteralPath $srcDir) {
        foreach ($f in @(Get-ChildItem -LiteralPath $srcDir -Recurse -File -ErrorAction SilentlyContinue)) {
            $rel = Get-RelPath $f.FullName
            if (Test-Ignored $rel) { continue }
            $seen[$rel.ToLower()] = $true
            $h = (Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash.ToLower()
            if (-not $known.ContainsKey($rel.ToLower()) -or $known[$rel.ToLower()][1] -ne $h) { [void]$changed.Add($rel) }
        }
    }
    foreach ($k in $known.Keys) {
        if ($k.StartsWith('src/') -and -not $seen.ContainsKey($k)) { [void]$changed.Add($known[$k][0]) }
    }
}

# --- WAVE-001 ---
$srcChanged = 0
foreach ($c in ($changed | Sort-Object -Unique)) {
    $rel = ([string]$c).Replace('\', '/')
    if (-not $rel.ToLower().StartsWith('src/')) { continue }
    if (Test-Ignored $rel) { continue }
    $srcChanged++
    $low = $rel.ToLower()
    $ok = $false
    foreach ($d in $declared) {
        if ($d -eq $low) { $ok = $true; break }
        if ($d.EndsWith('/') -and $low.StartsWith($d)) { $ok = $true; break }
        if ($d.Contains('*') -and ($low -like $d)) { $ok = $true; break }
    }
    if (-not $ok) {
        Add-Violation 'WAVE-001' 'error' 'implementer' ("{0} changed but is not in the Impacted Files of any wave {1} item ({2})." -f $rel, $WaveN, ($waveItems -join ', ')) $rel
    }
}

# --- WAVE-002 ---
$testExit = $null
if ($TestCommand) {
    $old = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    Push-Location -LiteralPath $RepoRoot
    try {
        if ($env:OS -eq 'Windows_NT') { & $env:ComSpec /d /c $TestCommand 2>&1 | ForEach-Object { [Console]::Error.WriteLine([string]$_) } }
        else { & /bin/sh -c $TestCommand 2>&1 | ForEach-Object { [Console]::Error.WriteLine([string]$_) } }
        $testExit = $LASTEXITCODE
    }
    catch { $testExit = 1 }
    finally { Pop-Location }
    $ErrorActionPreference = $old
    if ($null -eq $testExit) { $testExit = 0 }
    if ($testExit -ne 0) {
        Add-Violation 'WAVE-002' 'error' 'implementer' ("Test command failed with exit {0}: {1}" -f $testExit, $TestCommand) ''
    }
}

$errors = @($violations | Where-Object { $_.severity -eq 'error' })
$warnings = @($violations | Where-Object { $_.severity -eq 'warning' })
$status = 'pass'
if ($errors.Count -gt 0) { $status = 'fail' }
if ($Json) {
    [pscustomobject]@{
        tool = 'check-wave-scope'; version = $ToolVersion; scope = $Scope; spec = $Spec; wave = [int]$WaveN
        mode = $mode; base = $baseUsed; src_changed = $srcChanged; test_exit = $testExit
        errors = $errors.Count; warnings = $warnings.Count; status = $status; violations = $violations
    } | ConvertTo-Json -Depth 5
}
else {
    Write-Output ("KCC wave scope: {0} wave {1} (mode: {2}, base: {3}, src changes: {4})" -f $Spec, $WaveN, $mode, $baseUsed, $srcChanged)
    foreach ($v in $violations) {
        Write-Output ("[{0}] {1} ({2}) {3}: {4}" -f $v.severity.ToUpper(), $v.id, $v.fix_owner, $v.file, $v.message)
    }
    Write-Output ("Errors: {0}  Warnings: {1}" -f $errors.Count, $warnings.Count)
}
if ($errors.Count -gt 0) { exit 1 } else { exit 0 }
