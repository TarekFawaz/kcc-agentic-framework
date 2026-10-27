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

    Files an earlier wave of the same spec declared are accepted too: the
    baseline is a tag on HEAD and nothing commits between waves, so earlier
    waves' work still shows up as changed.

    IDs: WAVE-001 implementer (undeclared change), WAVE-002 implementer
    (-TestCommand failed), WAVE-003 planner (wave missing from plan.md),
    WAVE-004 implementer (the wave declares src/ files and none of them changed).
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
    [string]$TestCommand,   # a command, or 'auto' to run the tests the workspace already has
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
            # Every backticked path on the bullet counts ("`a/package.json`, `a/tsconfig*.json` and `a/x.ts`"),
            # not only the first; a backticked route such as `/healthz` is not a file.
            $ps = @([regex]::Matches($l, '`([^`\s]+)`') | ForEach-Object { $_.Groups[1].Value } | Where-Object { $_ -notmatch '^/' -and $_ -match '[./]' })
            if (-not $ps.Count) { $ps = @((($l -replace '^\s*[-*]\s+', '').Trim() -split '\s+')[0]) }
            foreach ($p in $ps) {
                $p = $p.Trim().Replace('\', '/')
                if ($p.StartsWith('./')) { $p = $p.Substring(2) }
                [void]$out.Add($p)
            }
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
# Only the items' own Impacted Files count as proof that the wave did its work (WAVE-004); allowances
# (tests, fixtures, lockfiles, item 'any') are extras and must not make a wave that wrote nothing look done.
$declaredImpacted = @($declared.ToArray())
# Files declared by earlier waves of this spec (already accepted, possibly still uncommitted).
$declaredEarlier = New-Object System.Collections.ArrayList
$earlierItems = New-Object System.Collections.ArrayList
foreach ($w in (ConvertTo-WaveList $planLines)) {
    if ([int]$w.Wave -lt [int]$WaveN -and -not $earlierItems.Contains($w.Item)) { [void]$earlierItems.Add($w.Item) }
}
foreach ($it in $earlierItems) {
    if (-not $bd) { break }
    foreach ($f in @(Get-ChildItem -LiteralPath $bd -File -Filter ($it + '*.md') -ErrorAction SilentlyContinue)) {
        if (-not [regex]::IsMatch($f.Name, ('^' + [regex]::Escape($it) + '(?![0-9])'))) { continue }
        foreach ($p in (Get-ImpactedFiles $f.FullName)) { [void]$declaredEarlier.Add($p.ToLower()) }
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
$curHit = 0
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
    foreach ($d in $declaredImpacted) {
        if (($d -eq $low) -or ($d.EndsWith('/') -and $low.StartsWith($d)) -or ($d.Contains('*') -and ($low -like $d))) { $curHit++; break }
    }
    if (-not $ok) {
        foreach ($d in $declaredEarlier) {
            if ($d -eq $low) { $ok = $true; break }
            if ($d.EndsWith('/') -and $low.StartsWith($d)) { $ok = $true; break }
            if ($d.Contains('*') -and ($low -like $d)) { $ok = $true; break }
        }
    }
    if (-not $ok) {
        Add-Violation 'WAVE-001' 'error' 'implementer' ("{0} changed but is not in the Impacted Files of any wave {1} item ({2})." -f $rel, $WaveN, ($waveItems -join ', ')) $rel
    }
}

# --- WAVE-004: a wave that declares src/ files must change at least one of them ---
$declaresSrc = $false
foreach ($d in $declaredImpacted) { if ($d.StartsWith('src/')) { $declaresSrc = $true; break } }
if ($waveItems.Count -gt 0 -and $declaresSrc -and $curHit -eq 0) {
    Add-Violation 'WAVE-004' 'error' 'implementer' ("Wave {0} ({1}) declares src/ files but none of them changed: the implementer wrote nothing." -f $WaveN, ($waveItems -join ', ')) $prel
}

# --- WAVE-002 ---
# -TestCommand auto: run the tests the workspace already has, per project (npm test where a test script exists and
# dependencies are installed, go test, dotnet test, pytest), so a later wave that breaks an earlier wave's test fails
# at the wave that broke it, not three stages later. Nothing runnable yet (a scaffold wave) is a warning, not a failure.
function Get-AutoTestCommands {
    $found = @()
    $srcRoot = Join-Path $RepoRoot 'src'
    if (-not (Test-Path -LiteralPath $srcRoot)) { return $found }
    $skip = @('node_modules', 'dist', 'build', 'coverage', '.venv', 'venv', '__pycache__', 'bin', 'obj', 'target')
    $dirs = @()
    foreach ($top in @(Get-ChildItem -LiteralPath $srcRoot -Directory -ErrorAction SilentlyContinue)) {
        $dirs += $top.FullName
        foreach ($sub in @(Get-ChildItem -LiteralPath $top.FullName -Directory -ErrorAction SilentlyContinue)) { if ($skip -notcontains $sub.Name) { $dirs += $sub.FullName } }
    }
    foreach ($d in $dirs) {
        $pj = Join-Path $d 'package.json'
        if ((Test-Path -LiteralPath $pj) -and (Test-Path -LiteralPath (Join-Path $d 'node_modules'))) {
            $has = $false
            try { $o = [System.IO.File]::ReadAllText($pj) | ConvertFrom-Json; if ($o.scripts -and ($o.scripts.PSObject.Properties.Name -contains 'test')) { $has = $true } } catch { $has = $false }
            if ($has) { $found += , @($d, 'npm test --silent'); continue }
        }
        if (Test-Path -LiteralPath (Join-Path $d 'go.mod')) { $found += , @($d, 'go test ./...'); continue }
        $dn = @(Get-ChildItem -LiteralPath $d -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '\.(sln|csproj)$' })
        if ($dn.Count -gt 0) { $found += , @($d, 'dotnet test --nologo'); continue }
        $py = @(Get-ChildItem -LiteralPath $d -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq 'pytest.ini' -or $_.Name -eq 'pyproject.toml' -or $_.Name -match '^test_.*\.py$' })
        if ($py.Count -gt 0) { $found += , @($d, 'python -m pytest -q') }
    }
    return $found
}
$testExit = $null
if ($TestCommand -eq 'auto') {
    $auto = @(Get-AutoTestCommands)
    if ($auto.Count -eq 0) {
        Add-Violation 'WAVE-005' 'warning' 'implementer' 'No runnable tests in the workspace yet (no test script with installed dependencies); nothing to run for this wave.' ''
    }
    $failedProjects = @()
    $old = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    foreach ($pair in $auto) {
        Push-Location -LiteralPath $pair[0]
        try {
            if ($env:OS -eq 'Windows_NT') { $txt = (& $env:ComSpec /d /c ($pair[1] + ' 2>&1') | Out-String) } else { $txt = (& /bin/sh -c ($pair[1] + ' 2>&1') | Out-String) }
            $rc = $LASTEXITCODE
        }
        catch { $txt = [string]$_; $rc = 1 }
        finally { Pop-Location }
        [Console]::Error.WriteLine($txt)
        if ($rc -ne 0) {
            $tail = @(($txt -split "[\r\n]+") | Where-Object { $_.Trim() } | Select-Object -Last 8) -join ' | '
            if ($tail.Length -gt 500) { $tail = $tail.Substring($tail.Length - 500) }
            $failedProjects += ((Get-RelPath $pair[0]) + ' (' + $pair[1] + ', exit ' + $rc + '): ' + $tail)
        }
    }
    $ErrorActionPreference = $old
    $testExit = 0; if ($failedProjects.Count -gt 0) { $testExit = 1 }
    if ($failedProjects.Count -gt 0) {
        Add-Violation 'WAVE-002' 'error' 'implementer' ('The workspace tests fail after this wave; fix the code or the stale test that now disagrees with it. ' + ($failedProjects -join ' ;; ')) ''
    }
}
elseif ($TestCommand) {
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
