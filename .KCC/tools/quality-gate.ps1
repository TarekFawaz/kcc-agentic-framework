<#
KCC framework (c) 2026 Tarek Fawaz, https://tikasway.dev/kcc. Licensed under the terms in LICENSE.

.SYNOPSIS
    Deterministic quality gate for a KCC workspace (build, lint, tests,
    coverage, lockfile, secrets, dependencies, SAST, static rules, SBOM, image scan).

.DESCRIPTION
    Mirror of quality-gate.sh (same check IDs, JSON shape, exit codes).
    Contract: .KCC/kernel/contracts/tool-contract.md

    Checks: QG-STACK QG-LOCK QG-BUILD QG-LINT QG-TEST QG-COV QG-SECRETS
            QG-DEPS QG-SAST QG-STATIC QG-SBOM QG-IMAGE

    Exit: 0 pass | 1 violations | 2 usage/environment | 3 deferred (a scanner
    or toolchain is missing; NOT a pass). This tool NEVER installs anything;
    it prints the toolchain-preflight command for the human to approve.

    PowerShell 5.1 compatible. ASCII-only. No && operator, no ternary.

.PARAMETER Spec
    SPEC-{ID}: resolves src/IDEA-{ID}-*/ and writes
    TestResults/IDEA-{ID}/SPEC-{ID}/quality-gate.json + quality-gate.md.

.PARAMETER Path
    Explicit workspace directory (overrides the spec workspace).

.PARAMETER Fast
    Secrets scan of staged files only (pre-commit mode).

.PARAMETER Require
    A missing scanner/toolchain is an error instead of deferred (use in CI).

.PARAMETER Emit
    Append a quality-gate-result backchannel event via backchannel-append.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .KCC\tools\quality-gate.ps1 -Spec SPEC-001
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .KCC\tools\quality-gate.ps1 -Fast
#>

[CmdletBinding()]
param(
    [string]$RepoRoot,
    [switch]$Json,
    [string]$Spec,
    [string]$Path,
    [string]$Scope = 'all',
    [switch]$Fast,
    [switch]$Require,
    [switch]$Emit
)

$ErrorActionPreference = 'Stop'
$Version = '1.0.0'

function Exit-Env([string]$Message) {
    [Console]::Error.WriteLine('error: ' + $Message)
    exit 2
}

function Resolve-RepoRootFromTool {
    if ($PSScriptRoot) { $toolDir = $PSScriptRoot }
    elseif ($MyInvocation.MyCommand.Path) { $toolDir = Split-Path -Parent $MyInvocation.MyCommand.Path }
    else { return (Get-Location).Path }
    $parent = Split-Path -Parent $toolDir
    if ((Split-Path -Leaf $parent) -eq '.KCC') { return (Split-Path -Parent $parent) }
    return $parent
}

if (-not $RepoRoot) { $RepoRoot = Resolve-RepoRootFromTool }
if (-not (Test-Path -LiteralPath $RepoRoot -PathType Container)) { Exit-Env "repo root not found: $RepoRoot" }
$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).ProviderPath.TrimEnd('\', '/')

if ($Spec -and ($Spec -notmatch '^SPEC-[0-9A-Za-z]+$')) { Exit-Env "invalid -Spec '$Spec' (expected SPEC-{ID})" }
$Scope = ($Scope.ToLowerInvariant() -replace '\s', '')
$validScopes = @('all', 'lock', 'build', 'lint', 'test', 'coverage', 'secrets', 'deps', 'sast', 'static', 'sbom', 'image')
foreach ($s in ($Scope -split ',')) { if ($validScopes -notcontains $s) { Exit-Env "unknown scope '$s'" } }
if ($Fast) { $Scope = 'secrets' }
$scopeList = @($Scope -split ',')
function Test-InScope([string]$Name) { return (($scopeList -contains 'all') -or ($scopeList -contains $Name)) }
$ScopeGiven = $PSBoundParameters.ContainsKey('Scope')
$ScopeSource = 'default (all)'
if ($ScopeGiven -or $Fast) { $ScopeSource = 'option' }
# The architect decides which gates apply (architecture/quality-gates.md), the planner maps them in plan.md -> ## Gates coverage
# (check:QG-ID tokens; PLAN-007). Without -Scope, a spec's gate runs exactly the checks that table covers, so a gate the
# architecture excluded (round 12: image scans for a local tool) is reported as out of scope, not as a failure. No table: all.
function Get-PlanScope([string]$SpecFolder) {
    if (-not $SpecFolder) { return '' }
    $plan = Join-Path $SpecFolder 'plan.md'
    if (-not (Test-Path -LiteralPath $plan)) { return '' }
    $lines = [IO.File]::ReadAllLines($plan)
    $tbl = @(); $in = $false
    foreach ($l in $lines) {
        if ($l -match '^## Gates coverage') { $in = $true; continue }
        if ($in -and ($l -match '^## ')) { break }
        if ($in) { $tbl += $l }
    }
    if ($tbl.Count -eq 0) { return '' }
    $text = ($tbl -join "`n")
    $ids = New-Object System.Collections.ArrayList
    foreach ($m in [regex]::Matches($text, 'check:(QG-[A-Z]+)')) { if (-not ($ids -contains $m.Groups[1].Value)) { [void]$ids.Add($m.Groups[1].Value) } }
    if ($text -match '(?m)^\|\s*QG-QUALITY\s*\|') { foreach ($q in @('QG-LOCK', 'QG-BUILD', 'QG-LINT', 'QG-TEST', 'QG-COV', 'QG-SECRETS', 'QG-DEPS', 'QG-SAST')) { if (-not ($ids -contains $q)) { [void]$ids.Add($q) } } }
    if ($text -match '(?m)^\|\s*QG-STATIC\s*\|') { if (-not ($ids -contains 'QG-STATIC')) { [void]$ids.Add('QG-STATIC') } }
    $map = @{ 'QG-LOCK' = 'lock'; 'QG-BUILD' = 'build'; 'QG-LINT' = 'lint'; 'QG-TEST' = 'test'; 'QG-COV' = 'coverage'; 'QG-SECRETS' = 'secrets'; 'QG-DEPS' = 'deps'; 'QG-SAST' = 'sast'; 'QG-STATIC' = 'static'; 'QG-SBOM' = 'sbom'; 'QG-IMAGE' = 'image' }
    $out = @()
    foreach ($id in $ids) { if ($map.ContainsKey($id) -and -not ($out -contains $map[$id])) { $out += $map[$id] } }
    return ($out -join ',')
}

$IsWin = ($env:OS -eq 'Windows_NT')
$Sep = [IO.Path]::DirectorySeparatorChar

# ------------------------------------------------------------------ settings
$settingsFile = Join-Path (Join-Path $RepoRoot '.KCC') 'settings.json'
$Settings = $null
if (Test-Path -LiteralPath $settingsFile) {
    try { $Settings = Get-Content -LiteralPath $settingsFile -Raw | ConvertFrom-Json } catch { $Settings = $null }
}
function Get-Setting([string]$Key, $Default) {
    $cur = $Settings
    foreach ($part in ($Key -split '\.')) {
        if ($null -eq $cur) { return $Default }
        $prop = $cur.PSObject.Properties[$part]
        if ($null -eq $prop) { return $Default }
        $cur = $prop.Value
    }
    if ($null -eq $cur) { return $Default }
    if (($cur -is [string]) -and ($cur -eq '')) { return $Default }
    return $cur
}

$CovMin = [double](Get-Setting 'quality.coverage_min_pct' 80)
$CovSrc = 'settings.quality.coverage_min_pct'
if (-not (Test-Path -LiteralPath $settingsFile)) { $CovSrc = 'default' }
$FailDeps = ([string](Get-Setting 'quality.fail_on.dependencies' 'high')).ToLowerInvariant()
# The npm audit gate covers what ships. Dev-only advisories (a test runner or bundler) are not exposed in production and
# an unattended run cannot major-bump them without breaking its own pinned stack, so they gate only when asked to.
$AuditDev = (([string](Get-Setting 'quality.audit_dev_dependencies' 'false')).ToLowerInvariant() -eq 'true')
$FailSast = ([string](Get-Setting 'quality.fail_on.sast' 'error')).ToLowerInvariant()
# 'local' (semgrep on PATH) or 'docker' (semgrep/semgrep image; for Windows, where semgrep has no native build).
$SastRunner = ([string](Get-Setting 'quality.scanners.sast_runner' 'auto')).ToLowerInvariant()   # auto | local | docker
$SastTool = ([string](Get-Setting 'quality.scanners.sast' 'semgrep')).ToLowerInvariant()
$SastRules = [string](Get-Setting 'quality.sast_rules' 'auto')
$FailSecrets = ([string](Get-Setting 'quality.fail_on.secrets' 'any')).ToLowerInvariant()

function Get-CovOverride([string]$File) {
    $v = $null
    foreach ($line in (Get-Content -LiteralPath $File -ErrorAction SilentlyContinue)) {
        $m = [regex]::Match($line, 'coverage_min_pct:\s*([0-9]+(\.[0-9]+)?)')
        if ($m.Success) { $v = $m.Groups[1].Value }
    }
    return $v
}
$qgFile = Join-Path $RepoRoot 'architecture/quality-gates.md'
if (Test-Path -LiteralPath $qgFile) {
    $v = Get-CovOverride $qgFile
    if ($v) { $CovMin = [double]$v; $CovSrc = 'architecture/quality-gates.md' }
}
$adrDir = Join-Path $RepoRoot 'architecture/adrs'
if (($CovSrc -ne 'architecture/quality-gates.md') -and (Test-Path -LiteralPath $adrDir)) {
    foreach ($f in (Get-ChildItem -LiteralPath $adrDir -Filter '*.md' -File | Sort-Object Name)) {
        $v = Get-CovOverride $f.FullName
        if ($v) { $CovMin = [double]$v; $CovSrc = 'architecture/adrs/' + $f.Name }
    }
}

function Get-SevFloor([string]$Name) {
    switch ($Name) {
        'critical' { return 9.0 }
        'high' { return 7.0 }
        'medium' { return 4.0 }
        'moderate' { return 4.0 }
        'low' { return 0.1 }
    }
    return 0.0
}
$DepsFloor = Get-SevFloor $FailDeps

function Get-Rel([string]$P) {
    if (-not $P) { return '' }
    $full = $P
    try { $full = [IO.Path]::GetFullPath($P) } catch { $full = $P }
    $full = $full.TrimEnd('\', '/')
    if ($full -ieq $RepoRoot) { return '.' }
    $prefix = $RepoRoot + $Sep
    if ($full.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { return ($full.Substring($prefix.Length) -replace '\\', '/') }
    return ($full -replace '\\', '/')
}

# ------------------------------------------------------------------ workspace
$SpecDir = $null
$IdeaId = $null
$OutDir = $null
$WS = $null
if ($Spec) {
    $specsRoot = Join-Path $RepoRoot 'specs'
    if (-not (Test-Path -LiteralPath $specsRoot)) { Exit-Env "no specs/ folder under $RepoRoot" }
    $cand = @(Get-ChildItem -LiteralPath $specsRoot -Directory -Recurse -Depth 2 -ErrorAction SilentlyContinue | Where-Object { ($_.Name -eq $Spec) -or ($_.Name -like ($Spec + '-*')) })
    if ($cand.Count -eq 0) { Exit-Env "spec $Spec not found under specs/" }
    $SpecDir = $cand[0].FullName
    $parentName = Split-Path -Leaf (Split-Path -Parent $SpecDir)
    $m = [regex]::Match($parentName, '^IDEA-([0-9A-Za-z]+)-')
    if ($m.Success) { $IdeaId = $m.Groups[1].Value }
    if (-not $IdeaId) {
        foreach ($md in (Get-ChildItem -LiteralPath $SpecDir -Filter '*.md' -File)) {
            $mm = Select-String -LiteralPath $md.FullName -Pattern 'IDEA-([0-9]+)' -CaseSensitive | Select-Object -First 1
            if ($mm) { $IdeaId = $mm.Matches[0].Groups[1].Value; break }
        }
    }
    if (-not $IdeaId) { Exit-Env "cannot resolve IDEA id for $Spec" }
    $OutDir = Join-Path $RepoRoot ('TestResults/IDEA-' + $IdeaId + '/' + $Spec)
    if (-not $Path) {
        $srcRoot = Join-Path $RepoRoot 'src'
        $wsc = @()
        if (Test-Path -LiteralPath $srcRoot) {
            $wsc = @(Get-ChildItem -LiteralPath $srcRoot -Directory | Where-Object { ($_.Name -eq ('IDEA-' + $IdeaId)) -or ($_.Name -like ('IDEA-' + $IdeaId + '-*')) })
        }
        if ($wsc.Count -eq 0) { Exit-Env "no workspace src/IDEA-$IdeaId-*/ for $Spec (use -Path)" }
        $WS = $wsc[0].FullName
    }
}
if ($Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { Exit-Env "workspace path not found: $Path" }
    $WS = (Resolve-Path -LiteralPath $Path).ProviderPath
}
if (-not $WS) { $WS = $RepoRoot }
$WS = $WS.TrimEnd('\', '/')

if ($OutDir) { $Art = Join-Path $OutDir 'quality-gate-artifacts'; if (Test-Path -LiteralPath $Art) { Remove-Item -LiteralPath $Art -Recurse -Force -ErrorAction SilentlyContinue } }
else { $Art = Join-Path ([IO.Path]::GetTempPath()) ('kcc-quality-gate-' + $PID) }
if (-not (Test-Path -LiteralPath $Art)) { New-Item -ItemType Directory -Path $Art -Force | Out-Null }

# ------------------------------------------------------------------ check registry
$Checks = New-Object System.Collections.ArrayList
$Missing = New-Object System.Collections.ArrayList
function Add-Check {
    param([string]$Id, [string]$Name, [string]$Stack, [string]$Project, [string]$Status, [string]$Severity,
          [string]$Command, $ExitCode, [string]$Message, [string]$Owner, [string]$Evidence)
    $rc = $null
    if (($null -ne $ExitCode) -and ("$ExitCode" -ne '')) { $rc = [int]$ExitCode }
    [void]$Checks.Add([ordered]@{
        id = $Id; name = $Name; stack = (Get-NullIfEmpty $Stack); project = (Get-NullIfEmpty $Project)
        status = $Status; severity = $Severity; command = (Get-NullIfEmpty $Command); exit_code = $rc
        message = $Message; fix_owner = $Owner; evidence = (Get-NullIfEmpty $Evidence)
    })
}
function Get-NullIfEmpty([string]$S) { if ($S) { return $S } return $null }
function Add-Missing([string]$Tool) { if (-not ($Missing -contains $Tool)) { [void]$Missing.Add($Tool) } }
function Add-Deferred([string]$Id, [string]$Name, [string]$Stack, [string]$Project, [string]$Tool, [string]$Message) {
    Add-Missing $Tool
    if ($Require) {
        Add-Check $Id $Name $Stack $Project 'fail' 'error' '' $null ($Message + ": required tool '" + $Tool + "' is missing (-Require)") 'human' ('tool-missing:' + $Tool)
    } else {
        Add-Check $Id $Name $Stack $Project 'deferred' 'warning' '' $null ($Message + ": tool '" + $Tool + "' is missing; deferred (not a pass)") 'human' ('tool-missing:' + $Tool)
    }
}

$ToolCache = @{}
function Get-ToolPath([string]$Name) {
    if ($ToolCache.ContainsKey($Name)) { return $ToolCache[$Name] }
    $all = @(Get-Command $Name -CommandType Application -ErrorAction SilentlyContinue)
    $p = $null
    foreach ($c in $all) {
        if (-not $IsWin) { $p = $c.Source; break }
        $ext = [IO.Path]::GetExtension($c.Source).ToLowerInvariant()
        if (@('.exe', '.cmd', '.bat', '.com') -contains $ext) { $p = $c.Source; break }
    }
    $ToolCache[$Name] = $p
    return $p
}
function Test-Tool([string]$Name) { return ($null -ne (Get-ToolPath $Name)) }

# ------------------------------------------------------------------ process runner
function ConvertTo-ArgString([string]$A) {
    if (($A.Length -gt 0) -and ($A -notmatch '[\s"]')) { return $A }
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('"')
    $bs = 0
    foreach ($ch in $A.ToCharArray()) {
        if ($ch -eq '\') { $bs++; continue }
        if ($ch -eq '"') { [void]$sb.Append('\' * ($bs * 2 + 1)); [void]$sb.Append('"'); $bs = 0; continue }
        if ($bs -gt 0) { [void]$sb.Append('\' * $bs); $bs = 0 }
        [void]$sb.Append($ch)
    }
    [void]$sb.Append('\' * ($bs * 2))
    [void]$sb.Append('"')
    return $sb.ToString()
}
function Format-Cmd([string[]]$Argv) {
    $parts = @()
    foreach ($a in $Argv) { if ($a -match '\s') { $parts += ('"' + $a + '"') } else { $parts += $a } }
    return ($parts -join ' ')
}

$script:LogN = 0
$script:LastLog = $null
$script:LastOut = $null
# Invoke-Logged -Dir <dir> -Argv @('exe','arg',...) [-Shell '<command line>'] -> exit code.
# stdout -> $script:LastOut, merged stdout+stderr -> $script:LastLog.
function Invoke-Logged {
    param([string]$Dir, [string[]]$Argv, [string]$Shell)
    $script:LogN++
    $script:LastLog = Join-Path $Art ('log-' + $script:LogN + '.txt')
    $script:LastOut = Join-Path $Art ('out-' + $script:LogN + '.json')
    $errFile = Join-Path $Art ('err-' + $script:LogN + '.txt')
    $file = $null
    $argLine = ''
    if ($Shell) {
        if ($IsWin) { $file = $env:ComSpec; if (-not $file) { $file = 'cmd.exe' }; $argLine = '/d /s /c "' + $Shell + '"' }
        else { $file = '/bin/sh'; $argLine = '-c ' + (ConvertTo-ArgString $Shell) }
    } else {
        $exe = Get-ToolPath $Argv[0]
        if (-not $exe) {
            if (Test-Path -LiteralPath (Join-Path $Dir $Argv[0])) { $exe = (Join-Path $Dir $Argv[0]) } else { $exe = $Argv[0] }
        }
        $rest = @()
        for ($i = 1; $i -lt $Argv.Count; $i++) { $rest += (ConvertTo-ArgString $Argv[$i]) }
        $ext = [IO.Path]::GetExtension($exe).ToLowerInvariant()
        if ($IsWin -and (($ext -eq '.cmd') -or ($ext -eq '.bat'))) {
            $file = $env:ComSpec; if (-not $file) { $file = 'cmd.exe' }
            $argLine = '/d /s /c "' + (ConvertTo-ArgString $exe) + ' ' + ($rest -join ' ') + '"'
        } elseif ($IsWin -and ($ext -eq '.ps1')) {
            $file = (Get-Command powershell -ErrorAction SilentlyContinue).Source
            $argLine = '-NoProfile -ExecutionPolicy Bypass -File ' + (ConvertTo-ArgString $exe) + ' ' + ($rest -join ' ')
        } else {
            $file = $exe
            $argLine = ($rest -join ' ')
        }
    }
    $rc = 1
    try {
        $spArgs = @{ FilePath = $file; WorkingDirectory = $Dir; NoNewWindow = $true; PassThru = $true
                     RedirectStandardOutput = $script:LastOut; RedirectStandardError = $errFile }
        if ($argLine.Trim()) { $spArgs['ArgumentList'] = $argLine }
        $p = Start-Process @spArgs
        $null = $p.Handle
        $p.WaitForExit()
        $rc = $p.ExitCode
        if ($null -eq $rc) { $rc = 1 }
    } catch {
        [IO.File]::WriteAllText($errFile, ('failed to start: ' + $_.Exception.Message))
        if (-not (Test-Path -LiteralPath $script:LastOut)) { [IO.File]::WriteAllText($script:LastOut, '') }
        $rc = 127
    }
    $merged = ''
    if (Test-Path -LiteralPath $script:LastOut) { $merged += [IO.File]::ReadAllText($script:LastOut) }
    if (Test-Path -LiteralPath $errFile) { $merged += [IO.File]::ReadAllText($errFile); Remove-Item -LiteralPath $errFile -Force -ErrorAction SilentlyContinue }
    [IO.File]::WriteAllText($script:LastLog, $merged)
    return [int]$rc
}

function Invoke-Native([string]$Exe, [string[]]$ArgList) {
    $old = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $out = @()
    $code = 1
    try { $out = @(& $Exe @ArgList 2>$null); $code = $LASTEXITCODE } catch { $code = 1 } finally { $ErrorActionPreference = $old }
    return @{ Out = $out; Code = $code }
}

# ------------------------------------------------------------------ python
$script:Py = $null
function Resolve-Python {
    if ($script:Py) { return $true }
    $order = @('python3', 'python')
    if ($IsWin) { $order = @('python', 'python3', 'py') }
    foreach ($c in $order) {
        if (Test-Tool $c) {
            $r = Invoke-Native $c @('--version')
            if ((($r.Out -join ' ') -match 'Python 3') -and ($r.Code -eq 0)) { $script:Py = $c; return $true }
        }
    }
    return $false
}
function Test-PyModule([string]$Mod) {
    $r = Invoke-Native $script:Py @('-c', ('import ' + $Mod))
    return ($r.Code -eq 0)
}

# ------------------------------------------------------------------ discovery
$PruneNames = @('node_modules', 'vendor', 'target', 'bin', 'obj', 'dist', 'build', 'out', 'TestResults', '__pycache__', 'venv', '.venv')
function Test-Pruned([string]$Name) { return (($PruneNames -contains $Name) -or ($Name.StartsWith('.') -and ($Name.Length -gt 1))) }
# Walk files under Root up to MaxDepth directory levels, pruning build/vendor/dot dirs.
function Get-WalkFiles([string]$Root, [int]$MaxDepth) {
    $result = New-Object System.Collections.ArrayList
    $queue = New-Object System.Collections.Queue
    $queue.Enqueue(@($Root, 0))
    while ($queue.Count -gt 0) {
        $item = $queue.Dequeue()
        $dir = $item[0]; $depth = $item[1]
        try { foreach ($f in [IO.Directory]::GetFiles($dir)) { [void]$result.Add($f) } } catch { }
        if (($MaxDepth -ge 0) -and ($depth + 1 -ge $MaxDepth)) { continue }
        try {
            foreach ($d in [IO.Directory]::GetDirectories($dir)) {
                if (Test-Pruned (Split-Path -Leaf $d)) { continue }
                $queue.Enqueue(@($d, ($depth + 1)))
            }
        } catch { }
    }
    return $result
}

function Get-Projects {
    $found = New-Object System.Collections.ArrayList
    foreach ($f in (Get-WalkFiles $WS 4)) {
        $b = Split-Path -Leaf $f
        $st = $null
        if ($b -eq 'package.json') { $st = 'node' }
        elseif (@('pyproject.toml', 'requirements.txt', 'setup.py') -contains $b) { $st = 'python' }
        elseif ($b -like '*.sln' -or $b -like '*.csproj' -or $b -like '*.fsproj') { $st = 'dotnet' }
        elseif ($b -eq 'go.mod') { $st = 'go' }
        elseif ($b -eq 'Cargo.toml') { $st = 'rust' }
        elseif (@('pom.xml', 'build.gradle', 'build.gradle.kts') -contains $b) { $st = 'java' }
        elseif ($b -eq 'CMakeLists.txt') { $st = 'cpp' }
        elseif ($b -eq 'composer.json') { $st = 'php' }
        if ($st) {
            $d = (Split-Path -Parent $f).TrimEnd('\', '/')
            $key = $st + '|' + $d
            $dup = $false
            foreach ($x in $found) { if ($x.key -eq $key) { $dup = $true } }
            if (-not $dup) { [void]$found.Add(@{ key = $key; stack = $st; dir = $d }) }
        }
    }
    $sorted = @($found | Sort-Object { $_.dir.Length }, { $_.dir })
    $kept = New-Object System.Collections.ArrayList
    foreach ($p in $sorted) {
        $keep = $true
        foreach ($k in $kept) {
            if (($k.stack -eq $p.stack) -and ($p.dir -ne $k.dir) -and ($p.dir + $Sep).StartsWith($k.dir + $Sep, [StringComparison]::OrdinalIgnoreCase)) { $keep = $false; break }
        }
        if ($keep) { [void]$kept.Add($p) }
    }
    return ,$kept
}

function Get-DialectStacks {
    $res = New-Object System.Collections.ArrayList
    if (-not $SpecDir) { return ,$res }
    $map = @{
        'backend-nodejs' = 'node'; 'fullstack-mern' = 'node'; 'fullstack-nestjs' = 'node'; 'frontend-react' = 'node'
        'frontend-angular' = 'node'; 'frontend-vanilla-js' = 'node'; 'backend-python' = 'python'; 'fullstack-python' = 'python'
        'backend-csharp' = 'dotnet'; 'fullstack-dotnet' = 'dotnet'; 'backend-go' = 'go'; 'fullstack-go' = 'go'
        'backend-rust' = 'rust'; 'embedded-rust' = 'rust'; 'backend-java' = 'java'; 'backend-cpp' = 'cpp'
        'embedded-c' = 'cpp'; 'embedded-cpp' = 'cpp'; 'backend-php' = 'php'
        'mobile-flutter' = 'flutter'; 'mobile-kotlin' = 'kotlin'; 'mobile-swift' = 'swift'
        'backend-ruby' = 'ruby'; 'scripting-lua' = 'lua'
    }
    $seen = @{}
    foreach ($f in (Get-ChildItem -LiteralPath $SpecDir -Recurse -File -Filter '*.md' -ErrorAction SilentlyContinue)) {
        $text = [IO.File]::ReadAllText($f.FullName)
        foreach ($m in [regex]::Matches($text, '\b(backend|fullstack|frontend|embedded|mobile|scripting)-(nodejs|mern|nestjs|react|angular|vanilla-js|python|csharp|dotnet|go|rust|java|cpp|c|php|flutter|kotlin|swift|ruby|lua)\b')) {
            $d = $m.Value
            if ($map.ContainsKey($d) -and (-not $seen.ContainsKey($d))) { $seen[$d] = $true; [void]$res.Add(@{ stack = $map[$d]; dialect = $d }) }
        }
    }
    return ,$res
}

function Find-Up([string]$Dir, [string[]]$Names) {
    $d = $Dir
    while ($true) {
        foreach ($n in $Names) { $c = Join-Path $d $n; if (Test-Path -LiteralPath $c) { return $c } }
        if ($d -ieq $WS) { return $null }
        $p = Split-Path -Parent $d
        if ((-not $p) -or ($p -eq $d)) { return $null }
        $d = $p
    }
}

# ------------------------------------------------------------------ coverage parsers
function Get-LcovPct([string]$File) {
    if (-not (Test-Path -LiteralPath $File)) { return $null }
    $lf = 0; $lh = 0
    foreach ($line in [IO.File]::ReadAllLines($File)) {
        if ($line.StartsWith('LF:')) { $lf += [int]$line.Substring(3) }
        elseif ($line.StartsWith('LH:')) { $lh += [int]$line.Substring(3) }
    }
    if ($lf -le 0) { return $null }
    return [math]::Round(($lh * 100.0) / $lf, 2)
}
function Get-NodeCov([string]$Dir) {
    $sum = Join-Path $Dir 'coverage/coverage-summary.json'
    if (Test-Path -LiteralPath $sum) {
        try { $j = Get-Content -LiteralPath $sum -Raw | ConvertFrom-Json; if ($null -ne $j.total.lines.pct) { return [double]$j.total.lines.pct } } catch { }
    }
    return (Get-LcovPct (Join-Path $Dir 'coverage/lcov.info'))
}
function Get-PyJsonCov([string]$File) {
    if (-not (Test-Path -LiteralPath $File)) { return $null }
    try { $j = Get-Content -LiteralPath $File -Raw | ConvertFrom-Json; if ($null -ne $j.totals.percent_covered) { return [math]::Round([double]$j.totals.percent_covered, 2) } } catch { }
    return $null
}
function Get-CoberturaCov([string]$File) {
    if ((-not $File) -or (-not (Test-Path -LiteralPath $File))) { return $null }
    $m = [regex]::Match([IO.File]::ReadAllText($File), '<coverage[^>]*line-rate="([0-9.]+)"')
    if ($m.Success) { return [math]::Round([double]$m.Groups[1].Value * 100, 2) }
    return $null
}
function Get-JacocoCov([string]$File) {
    if (-not (Test-Path -LiteralPath $File)) { return $null }
    $miss = 0; $cov = 0; $first = $true
    foreach ($line in [IO.File]::ReadAllLines($File)) {
        if ($first) { $first = $false; continue }
        $c = $line.Split(',')
        if ($c.Count -ge 9) { $miss += [double]$c[7]; $cov += [double]$c[8] }
    }
    if (($miss + $cov) -le 0) { return $null }
    return [math]::Round(($cov * 100.0) / ($miss + $cov), 2)
}
function Get-GenericPct([string]$File, [string]$LinePattern) {
    if (-not (Test-Path -LiteralPath $File)) { return $null }
    $val = $null
    foreach ($line in [IO.File]::ReadAllLines($File)) {
        if ($LinePattern -and ($line -notmatch $LinePattern)) { continue }
        foreach ($m in [regex]::Matches($line, '([0-9]+(\.[0-9]+)?)%')) { $val = [double]$m.Groups[1].Value }
    }
    return $val
}

# ------------------------------------------------------------------ step helpers
function Invoke-Step {
    param([string]$Id, [string]$Name, [string]$Stack, [string]$Project, [string]$Dir, [string]$Owner, [string[]]$Argv, [string]$Shell)
    if ($Shell) { $rc = Invoke-Logged -Dir $Dir -Shell $Shell; $shown = $Shell }
    else { $rc = Invoke-Logged -Dir $Dir -Argv $Argv; $shown = Format-Cmd $Argv }
    if ($rc -eq 0) { Add-Check $Id $Name $Stack $Project 'pass' 'none' $shown $rc 'ok' $Owner (Get-Rel $script:LastLog) }
    else { Add-Check $Id $Name $Stack $Project 'fail' 'error' $shown $rc ('command failed (exit ' + $rc + '); see log') $Owner (Get-Rel $script:LastLog) }
    return $rc
}
function Get-Override([string]$Stack, [string]$Check) { return [string](Get-Setting ('quality.commands.' + $Stack + '.' + $Check) '') }
# Returns $null when no override exists, otherwise the exit code (0 for 'skip').
function Invoke-Override([string]$Stack, [string]$Check, [string]$Id, [string]$Name, [string]$Project, [string]$Dir) {
    $ov = Get-Override $Stack $Check
    if (-not $ov) { return $null }
    if ($ov -eq 'skip') {
        Add-Check $Id $Name $Stack $Project 'skipped' 'warning' '' $null ('skipped by settings quality.commands.' + $Stack + '.' + $Check) 'human' 'settings'
        return 0
    }
    return (Invoke-Step -Id $Id -Name $Name -Stack $Stack -Project $Project -Dir $Dir -Owner 'implementer' -Shell $ov)
}
function Add-Cov([string]$Stack, [string]$Project, $Pct, [string]$Evidence, [string]$Command) {
    if ($null -eq $Pct) {
        Add-Check 'QG-COV' 'coverage' $Stack $Project 'fail' 'error' $Command $null ('no coverage report found; configure a coverage command (quality.commands.' + $Stack + '.coverage) or reporter') 'implementer' $Evidence
    } elseif ([double]$Pct -ge $CovMin) {
        Add-Check 'QG-COV' 'coverage' $Stack $Project 'pass' 'none' $Command $null ('coverage ' + $Pct + '% >= ' + $CovMin + '% (' + $CovSrc + ')') 'implementer' $Evidence
    } else {
        Add-Check 'QG-COV' 'coverage' $Stack $Project 'fail' 'error' $Command $null ('coverage ' + $Pct + '% < ' + $CovMin + '% (' + $CovSrc + ')') 'implementer' $Evidence
    }
}
function Invoke-CovOverride([string]$Stack, [string]$Project, [string]$Dir, [string]$Ov) {
    if ($Ov -eq 'skip') {
        Add-Check 'QG-COV' 'coverage' $Stack $Project 'skipped' 'warning' '' $null ('skipped by settings quality.commands.' + $Stack + '.coverage') 'human' 'settings'
        return
    }
    $rc = Invoke-Logged -Dir $Dir -Shell $Ov
    if ($rc -ne 0) { Add-Check 'QG-COV' 'coverage' $Stack $Project 'fail' 'error' $Ov $rc ('coverage command failed (exit ' + $rc + ')') 'implementer' (Get-Rel $script:LastLog); return }
    Add-Cov $Stack $Project (Get-GenericPct $script:LastLog '') (Get-Rel $script:LastLog) $Ov
}
function Add-CovSkipped([string]$Stack, [string]$Project) {
    Add-Check 'QG-COV' 'coverage' $Stack $Project 'skipped' 'none' '' $null 'tests did not pass; coverage not evaluated' 'implementer' ''
}
function Add-DeferProject([string]$Stack, [string]$Project, [string]$Tool) {
    if (Test-InScope 'build') { Add-Deferred 'QG-BUILD' 'build' $Stack $Project $Tool ($Stack + ' build') }
    if (Test-InScope 'lint') { Add-Deferred 'QG-LINT' 'lint' $Stack $Project $Tool ($Stack + ' lint') }
    if (Test-InScope 'test') { Add-Deferred 'QG-TEST' 'test' $Stack $Project $Tool ($Stack + ' tests') }
    if (Test-InScope 'coverage') { Add-Deferred 'QG-COV' 'coverage' $Stack $Project $Tool ($Stack + ' coverage') }
}
# Run build/lint with override support; default argv when no override.
function Invoke-Simple([string]$Stack, [string]$Check, [string]$Id, [string]$Project, [string]$Dir, [string[]]$Argv) {
    $r = Invoke-Override $Stack $Check $Id $Check $Project $Dir
    if ($null -ne $r) { return $r }
    return (Invoke-Step -Id $Id -Name $Check -Stack $Stack -Project $Project -Dir $Dir -Owner 'implementer' -Argv $Argv)
}

# ------------------------------------------------------------------ lockfiles
$NodeLockNames = @('package-lock.json', 'npm-shrinkwrap.json', 'pnpm-lock.yaml', 'yarn.lock', 'bun.lockb', 'bun.lock')
# The lockfile of an ancestor npm/yarn/pnpm workspace root (above the workspace, up to the repository root), or $null.
function Get-NodeWsRootLock {
    $a = Split-Path -Parent $WS
    while ($a -and ($a.Length -ge $RepoRoot.Length)) {
        $pj = Join-Path $a 'package.json'
        $isWs = ((Test-Path -LiteralPath $pj) -and ([System.IO.File]::ReadAllText($pj) -match '"workspaces"')) -or (Test-Path -LiteralPath (Join-Path $a 'pnpm-workspace.yaml'))
        if ($isWs) { foreach ($n in $NodeLockNames) { $c = Join-Path $a $n; if (Test-Path -LiteralPath $c) { return $c } } }
        if ($a -ieq $RepoRoot) { break }
        $a = Split-Path -Parent $a
    }
    return $null
}

function Test-Lock([string]$Stack, [string]$Project, [string]$Dir) {
    if (-not (Test-InScope 'lock')) { return }
    $f = $null
    switch ($Stack) {
        'node' {
            $f = Find-Up $Dir $NodeLockNames
            # A monorepo keeps ONE lockfile at the workspace root, which can sit above the spec's src folder (npm/yarn/pnpm
            # workspaces). Accept it from an ancestor, up to the repository root, when that ancestor declares workspaces.
            if (-not $f) { $f = Get-NodeWsRootLock }
        }
        'python' {
            $f = Find-Up $Dir @('poetry.lock', 'uv.lock', 'Pipfile.lock', 'pdm.lock')
            $req = Join-Path $Dir 'requirements.txt'
            if ((-not $f) -and (Test-Path -LiteralPath $req)) {
                $unpinned = @(Get-Content -LiteralPath $req | Where-Object { ($_ -notmatch '^\s*(#|$|-)') -and ($_ -notmatch '==') })
                if ($unpinned.Count -eq 0) { $f = $req }
                else {
                    Add-Check 'QG-LOCK' 'lockfile' $Stack $Project 'fail' 'error' '' $null 'requirements.txt has unpinned entries (use == pins, or a lockfile: uv.lock/poetry.lock)' 'implementer' (Get-Rel $req)
                    return
                }
            }
        }
        'dotnet' {
            $hit = @(Get-WalkFiles $Dir 4 | Where-Object { (Split-Path -Leaf $_) -eq 'packages.lock.json' })
            if ($hit.Count -gt 0) { $f = $hit[0] }
        }
        'go' {
            $f = Find-Up $Dir @('go.sum')
            if (-not $f) {
                $hasReq = Select-String -LiteralPath (Join-Path $Dir 'go.mod') -Pattern '^\s*require' -Quiet
                if (-not $hasReq) { Add-Check 'QG-LOCK' 'lockfile' $Stack $Project 'pass' 'none' '' $null 'go.mod has no requirements; go.sum not needed' 'implementer' (Get-Rel (Join-Path $Dir 'go.mod')); return }
            }
        }
        'rust' { $f = Find-Up $Dir @('Cargo.lock') }
        'java' {
            if (Test-Path -LiteralPath (Join-Path $Dir 'pom.xml')) {
                Add-Check 'QG-LOCK' 'lockfile' $Stack $Project 'skipped' 'warning' '' $null 'maven has no native lockfile; pin versions and rely on QG-DEPS' 'implementer' (Get-Rel (Join-Path $Dir 'pom.xml'))
                return
            }
            $f = Find-Up $Dir @('gradle.lockfile')
            if ((-not $f) -and (Test-Path -LiteralPath (Join-Path $Dir 'gradle/dependency-locks'))) { $f = Join-Path $Dir 'gradle/dependency-locks' }
        }
        'cpp' {
            if (Test-Path -LiteralPath (Join-Path $Dir 'conan.lock')) { $f = Join-Path $Dir 'conan.lock' }
            elseif (Test-Path -LiteralPath (Join-Path $Dir 'vcpkg.json')) {
                $vj = Join-Path $Dir 'vcpkg.json'
                if ((Select-String -LiteralPath $vj -Pattern 'builtin-baseline' -Quiet) -or (Test-Path -LiteralPath (Join-Path $Dir 'vcpkg-configuration.json'))) { $f = $vj }
            } elseif ((-not (Test-Path -LiteralPath (Join-Path $Dir 'conanfile.txt'))) -and (-not (Test-Path -LiteralPath (Join-Path $Dir 'conanfile.py')))) {
                Add-Check 'QG-LOCK' 'lockfile' $Stack $Project 'skipped' 'none' '' $null 'no C/C++ package manager in use' 'implementer' ''
                return
            }
        }
        'php' { $f = Find-Up $Dir @('composer.lock') }
    }
    if ($f) { Add-Check 'QG-LOCK' 'lockfile' $Stack $Project 'pass' 'none' '' $null 'lockfile present' 'implementer' (Get-Rel $f) }
    else { Add-Check 'QG-LOCK' 'lockfile' $Stack $Project 'fail' 'error' '' $null ('no lockfile for ' + $Stack + ' project; commit one for reproducible builds') 'implementer' (Get-Rel $Dir) }
}

# ------------------------------------------------------------------ stacks
function Invoke-StackNode([string]$Project, [string]$Dir, [int]$Idx) {
    $pm = 'npm'
    if (Find-Up $Dir @('pnpm-lock.yaml')) { $pm = 'pnpm' }
    elseif (Find-Up $Dir @('yarn.lock')) { $pm = 'yarn' }
    elseif (Find-Up $Dir @('bun.lockb', 'bun.lock')) { $pm = 'bun' }
    if (-not (Test-Tool 'node')) { Add-DeferProject 'node' $Project 'node'; return }
    if (-not (Test-Tool $pm)) { Add-DeferProject 'node' $Project $pm; return }
    $pkg = $null
    try { $pkg = Get-Content -LiteralPath (Join-Path $Dir 'package.json') -Raw | ConvertFrom-Json } catch { $pkg = $null }
    $scripts = @{}
    if ($pkg -and $pkg.scripts) { foreach ($p in $pkg.scripts.PSObject.Properties) { $scripts[$p.Name] = [string]$p.Value } }
    $hasDeps = $false
    if ($pkg) {
        foreach ($k in @('dependencies', 'devDependencies')) {
            $o = $pkg.PSObject.Properties[$k]
            if ($o -and $o.Value -and (@($o.Value.PSObject.Properties).Count -gt 0)) { $hasDeps = $true }
        }
    }
    if ($hasDeps -and (-not (Find-Up $Dir @('node_modules')))) {
        foreach ($c in @(@('build', 'QG-BUILD'), @('lint', 'QG-LINT'), @('test', 'QG-TEST'), @('coverage', 'QG-COV'))) {
            if (Test-InScope $c[0]) { Add-Check $c[1] $c[0] 'node' $Project 'fail' 'error' '' $null ("dependencies not installed (node_modules missing); run '" + $pm + " install' / '" + $pm + " ci' first") 'human' (Get-Rel $Dir) }
        }
        return
    }
    $testOk = $true
    if (Test-InScope 'build') {
        $r = Invoke-Override 'node' 'build' 'QG-BUILD' 'build' $Project $Dir
        if ($null -eq $r) {
            if ($scripts.ContainsKey('build')) { [void](Invoke-Step -Id 'QG-BUILD' -Name 'build' -Stack 'node' -Project $Project -Dir $Dir -Owner 'implementer' -Argv @($pm, 'run', 'build')) }
            else { Add-Check 'QG-BUILD' 'build' 'node' $Project 'skipped' 'none' '' $null 'no build script in package.json' 'implementer' (Get-Rel (Join-Path $Dir 'package.json')) }
        }
    }
    if (Test-InScope 'lint') {
        $r = Invoke-Override 'node' 'lint' 'QG-LINT' 'lint' $Project $Dir
        if ($null -eq $r) {
            if ($scripts.ContainsKey('lint')) { [void](Invoke-Step -Id 'QG-LINT' -Name 'lint' -Stack 'node' -Project $Project -Dir $Dir -Owner 'implementer' -Argv @($pm, 'run', 'lint')) }
            else { Add-Check 'QG-LINT' 'lint' 'node' $Project 'skipped' 'warning' '' $null 'no lint script in package.json' 'implementer' (Get-Rel (Join-Path $Dir 'package.json')) }
        }
    }
    if (Test-InScope 'test') {
        $r = Invoke-Override 'node' 'test' 'QG-TEST' 'test' $Project $Dir
        if ($null -ne $r) { if ($r -ne 0) { $testOk = $false } }
        elseif ($scripts.ContainsKey('test')) {
            $r = Invoke-Step -Id 'QG-TEST' -Name 'test' -Stack 'node' -Project $Project -Dir $Dir -Owner 'implementer' -Argv @($pm, 'run', 'test')
            if ($r -ne 0) { $testOk = $false }
        } else { Add-Check 'QG-TEST' 'test' 'node' $Project 'fail' 'error' '' $null 'no test script in package.json' 'implementer' (Get-Rel (Join-Path $Dir 'package.json')); $testOk = $false }
    }
    if (Test-InScope 'coverage') {
        if (-not $testOk) { Add-CovSkipped 'node' $Project; return }
        $ov = Get-Override 'node' 'coverage'
        if ($ov -eq 'skip') { Invoke-CovOverride 'node' $Project $Dir $ov; return }
        $shown = ''
        $log = $null
        $rc = $null
        if ($ov) { $rc = Invoke-Logged -Dir $Dir -Shell $ov; $shown = $ov }
        elseif ($scripts.ContainsKey('coverage')) { $rc = Invoke-Logged -Dir $Dir -Argv @($pm, 'run', 'coverage'); $shown = $pm + ' run coverage' }
        elseif ($scripts.ContainsKey('test:coverage')) { $rc = Invoke-Logged -Dir $Dir -Argv @($pm, 'run', 'test:coverage'); $shown = $pm + ' run test:coverage' }
        if ($null -ne $rc) {
            $log = $script:LastLog
            if ($rc -ne 0) { Add-Check 'QG-COV' 'coverage' 'node' $Project 'fail' 'error' $shown $rc ('coverage command failed (exit ' + $rc + ')') 'implementer' (Get-Rel $log); return }
        }
        $pct = Get-NodeCov $Dir
        if (($null -eq $pct) -and $log) { $pct = Get-GenericPct $log '' }
        Add-Cov 'node' $Project $pct (Get-Rel (Join-Path $Dir 'coverage')) $shown
    }
}

function Invoke-StackPython([string]$Project, [string]$Dir, [int]$Idx) {
    if (-not (Resolve-Python)) { Add-DeferProject 'python' $Project 'python'; return }
    $py = $script:Py
    $testOk = $true
    $covJson = Join-Path $Art ('py-cov-' + $Idx + '.json')
    $covMode = 'none'
    if (Test-InScope 'build') {
        [void](Invoke-Simple 'python' 'build' 'QG-BUILD' $Project $Dir @($py, '-m', 'compileall', '-q', '-x', '(^|[\\/])(\.venv|venv|node_modules|\.git|build|dist)([\\/]|$)', '.'))
    }
    if (Test-InScope 'lint') {
        $r = Invoke-Override 'python' 'lint' 'QG-LINT' 'lint' $Project $Dir
        if ($null -eq $r) {
            if (Test-Tool 'ruff') { [void](Invoke-Step -Id 'QG-LINT' -Name 'lint' -Stack 'python' -Project $Project -Dir $Dir -Owner 'implementer' -Argv @('ruff', 'check', '.')) }
            elseif (Test-PyModule 'flake8') { [void](Invoke-Step -Id 'QG-LINT' -Name 'lint' -Stack 'python' -Project $Project -Dir $Dir -Owner 'implementer' -Argv @($py, '-m', 'flake8', '--exclude', '.venv,venv,node_modules,build,dist', '.')) }
            else { Add-Deferred 'QG-LINT' 'lint' 'python' $Project 'ruff' 'python lint' }
        }
    }
    $hasPytest = Test-PyModule 'pytest'
    $hasCov = Test-PyModule 'pytest_cov'
    $hasCoverage = Test-PyModule 'coverage'
    if (Test-InScope 'test') {
        $r = Invoke-Override 'python' 'test' 'QG-TEST' 'test' $Project $Dir
        if ($null -ne $r) { if ($r -ne 0) { $testOk = $false } }
        else {
            $tests = @(Get-WalkFiles $Dir 6 | Where-Object { $n = Split-Path -Leaf $_; ($n -like 'test_*.py') -or ($n -like '*_test.py') })
            if ($tests.Count -eq 0) { Add-Check 'QG-TEST' 'test' 'python' $Project 'fail' 'error' '' $null 'no tests found (test_*.py / *_test.py)' 'implementer' (Get-Rel $Dir); $testOk = $false }
            elseif (-not $hasPytest) { Add-Deferred 'QG-TEST' 'test' 'python' $Project 'pytest' 'python tests'; $testOk = $false; Add-Missing 'pytest-cov' }
            elseif ($hasCov) {
                $covMode = 'pytestcov'
                $r = Invoke-Step -Id 'QG-TEST' -Name 'test' -Stack 'python' -Project $Project -Dir $Dir -Owner 'implementer' -Argv @($py, '-m', 'pytest', '-q', '--cov=.', ('--cov-report=json:' + $covJson))
                if ($r -ne 0) { $testOk = $false }
            } elseif ($hasCoverage) {
                $covMode = 'coverage'
                $r = Invoke-Step -Id 'QG-TEST' -Name 'test' -Stack 'python' -Project $Project -Dir $Dir -Owner 'implementer' -Argv @($py, '-m', 'coverage', 'run', '-m', 'pytest', '-q')
                if ($r -ne 0) { $testOk = $false }
            } else {
                $r = Invoke-Step -Id 'QG-TEST' -Name 'test' -Stack 'python' -Project $Project -Dir $Dir -Owner 'implementer' -Argv @($py, '-m', 'pytest', '-q')
                if ($r -ne 0) { $testOk = $false }
            }
        }
    }
    if (Test-InScope 'coverage') {
        $ov = Get-Override 'python' 'coverage'
        if ($ov) { Invoke-CovOverride 'python' $Project $Dir $ov; return }
        if (-not $testOk) {
            if (-not $hasPytest) { Add-Deferred 'QG-COV' 'coverage' 'python' $Project 'pytest-cov' 'python coverage' }
            else { Add-CovSkipped 'python' $Project }
            return
        }
        if ($covMode -eq 'pytestcov') { Add-Cov 'python' $Project (Get-PyJsonCov $covJson) (Get-Rel $covJson) 'pytest --cov' }
        elseif ($covMode -eq 'coverage') {
            [void](Invoke-Logged -Dir $Dir -Argv @($py, '-m', 'coverage', 'json', '-o', $covJson))
            Add-Cov 'python' $Project (Get-PyJsonCov $covJson) (Get-Rel $covJson) ($py + ' -m coverage json')
        } else { Add-Deferred 'QG-COV' 'coverage' 'python' $Project 'pytest-cov' 'python coverage' }
    }
}

function Invoke-StackDotnet([string]$Project, [string]$Dir, [int]$Idx) {
    if (-not (Test-Tool 'dotnet')) { Add-DeferProject 'dotnet' $Project 'dotnet'; return }
    $t = @(Get-ChildItem -LiteralPath $Dir -File -Filter '*.sln' | Select-Object -First 1)
    if ($t.Count -eq 0) { $t = @(Get-ChildItem -LiteralPath $Dir -File | Where-Object { ($_.Extension -eq '.csproj') -or ($_.Extension -eq '.fsproj') } | Select-Object -First 1) }
    $target = $t[0].Name
    $res = Join-Path $Art ('dotnet-' + $Idx)
    $testOk = $true
    if (Test-InScope 'build') { [void](Invoke-Simple 'dotnet' 'build' 'QG-BUILD' $Project $Dir @('dotnet', 'build', $target, '--nologo')) }
    if (Test-InScope 'lint') { [void](Invoke-Simple 'dotnet' 'lint' 'QG-LINT' $Project $Dir @('dotnet', 'format', $target, '--verify-no-changes')) }
    if (Test-InScope 'test') {
        $r = Invoke-Simple 'dotnet' 'test' 'QG-TEST' $Project $Dir @('dotnet', 'test', $target, '--nologo', '--collect', 'XPlat Code Coverage', '--results-directory', $res)
        if ($r -ne 0) { $testOk = $false }
    }
    if (Test-InScope 'coverage') {
        if (-not $testOk) { Add-CovSkipped 'dotnet' $Project; return }
        $f = $null
        if (Test-Path -LiteralPath $res) { $f = @(Get-ChildItem -LiteralPath $res -Recurse -File -Filter 'coverage.cobertura.xml' | Select-Object -First 1 | ForEach-Object { $_.FullName }) | Select-Object -First 1 }
        $ev = $res
        if ($f) { $ev = $f }
        Add-Cov 'dotnet' $Project (Get-CoberturaCov $f) (Get-Rel $ev) 'dotnet test --collect "XPlat Code Coverage"'
    }
}

function Invoke-StackGo([string]$Project, [string]$Dir, [int]$Idx) {
    if (-not (Test-Tool 'go')) { Add-DeferProject 'go' $Project 'go'; return }
    $prof = Join-Path $Art ('go-cover-' + $Idx + '.out')
    $testOk = $true
    if (Test-InScope 'build') { [void](Invoke-Simple 'go' 'build' 'QG-BUILD' $Project $Dir @('go', 'build', './...')) }
    if (Test-InScope 'lint') { [void](Invoke-Simple 'go' 'lint' 'QG-LINT' $Project $Dir @('go', 'vet', './...')) }
    if (Test-InScope 'test') {
        $r = Invoke-Simple 'go' 'test' 'QG-TEST' $Project $Dir @('go', 'test', './...', ('-coverprofile=' + $prof))
        if ($r -ne 0) { $testOk = $false }
    }
    if (Test-InScope 'coverage') {
        if ((-not $testOk) -or (-not (Test-Path -LiteralPath $prof))) {
            Add-Check 'QG-COV' 'coverage' 'go' $Project 'skipped' 'none' '' $null 'tests did not pass or no profile; coverage not evaluated' 'implementer' ''
            return
        }
        [void](Invoke-Logged -Dir $Dir -Argv @('go', 'tool', 'cover', ('-func=' + $prof)))
        Add-Cov 'go' $Project (Get-GenericPct $script:LastLog '^total:') (Get-Rel $prof) 'go tool cover -func'
    }
}

function Invoke-StackRust([string]$Project, [string]$Dir, [int]$Idx) {
    if (-not (Test-Tool 'cargo')) { Add-DeferProject 'rust' $Project 'cargo'; return }
    $testOk = $true
    if (Test-InScope 'build') { [void](Invoke-Simple 'rust' 'build' 'QG-BUILD' $Project $Dir @('cargo', 'build')) }
    if (Test-InScope 'lint') {
        $r = Invoke-Override 'rust' 'lint' 'QG-LINT' 'lint' $Project $Dir
        if ($null -eq $r) {
            if (Test-Tool 'cargo-clippy') { [void](Invoke-Step -Id 'QG-LINT' -Name 'lint' -Stack 'rust' -Project $Project -Dir $Dir -Owner 'implementer' -Argv @('cargo', 'clippy', '--all-targets', '--', '-D', 'warnings')) }
            else { Add-Deferred 'QG-LINT' 'lint' 'rust' $Project 'cargo-clippy' 'rust lint' }
        }
    }
    if (Test-InScope 'test') {
        $r = Invoke-Simple 'rust' 'test' 'QG-TEST' $Project $Dir @('cargo', 'test')
        if ($r -ne 0) { $testOk = $false }
    }
    if (Test-InScope 'coverage') {
        if (-not $testOk) { Add-CovSkipped 'rust' $Project; return }
        $ov = Get-Override 'rust' 'coverage'
        if ($ov) { Invoke-CovOverride 'rust' $Project $Dir $ov; return }
        if (-not (Test-Tool 'cargo-llvm-cov')) { Add-Deferred 'QG-COV' 'coverage' 'rust' $Project 'cargo-llvm-cov' 'rust coverage'; return }
        $rc = Invoke-Logged -Dir $Dir -Argv @('cargo', 'llvm-cov', '--summary-only')
        if ($rc -ne 0) { Add-Check 'QG-COV' 'coverage' 'rust' $Project 'fail' 'error' 'cargo llvm-cov --summary-only' $rc 'coverage command failed' 'implementer' (Get-Rel $script:LastLog); return }
        $pct = Get-GenericPct $script:LastLog '^TOTAL'
        if ($null -eq $pct) { $pct = Get-GenericPct $script:LastLog '' }
        Add-Cov 'rust' $Project $pct (Get-Rel $script:LastLog) 'cargo llvm-cov --summary-only'
    }
}

function Invoke-StackJava([string]$Project, [string]$Dir, [int]$Idx) {
    $kind = 'maven'
    $tool = @()
    if (Test-Path -LiteralPath (Join-Path $Dir 'pom.xml')) {
        if ($IsWin -and (Test-Path -LiteralPath (Join-Path $Dir 'mvnw.cmd'))) { $tool = @((Join-Path $Dir 'mvnw.cmd')) }
        elseif ((-not $IsWin) -and (Test-Path -LiteralPath (Join-Path $Dir 'mvnw'))) { $tool = @('sh', './mvnw') }
        elseif (Test-Tool 'mvn') { $tool = @('mvn') }
        else { Add-DeferProject 'java' $Project 'mvn'; return }
    } else {
        $kind = 'gradle'
        if ($IsWin -and (Test-Path -LiteralPath (Join-Path $Dir 'gradlew.bat'))) { $tool = @((Join-Path $Dir 'gradlew.bat')) }
        elseif ((-not $IsWin) -and (Test-Path -LiteralPath (Join-Path $Dir 'gradlew'))) { $tool = @('sh', './gradlew') }
        elseif (Test-Tool 'gradle') { $tool = @('gradle') }
        else { Add-DeferProject 'java' $Project 'gradle'; return }
    }
    if (-not (Test-Tool 'java')) { Add-DeferProject 'java' $Project 'java'; return }
    $testOk = $true
    if (Test-InScope 'build') {
        if ($kind -eq 'maven') { [void](Invoke-Simple 'java' 'build' 'QG-BUILD' $Project $Dir ($tool + @('-B', '-q', '-DskipTests', 'package'))) }
        else { [void](Invoke-Simple 'java' 'build' 'QG-BUILD' $Project $Dir ($tool + @('build', '-x', 'test'))) }
    }
    if (Test-InScope 'lint') {
        if ($kind -eq 'gradle') { [void](Invoke-Simple 'java' 'lint' 'QG-LINT' $Project $Dir ($tool + @('check', '-x', 'test'))) }
        else {
            $r = Invoke-Override 'java' 'lint' 'QG-LINT' 'lint' $Project $Dir
            if ($null -eq $r) { Add-Check 'QG-LINT' 'lint' 'java' $Project 'skipped' 'warning' '' $null 'no default maven lint; set quality.commands.java.lint (e.g. mvn checkstyle:check)' 'implementer' '' }
        }
    }
    if (Test-InScope 'test') {
        $r = Invoke-Simple 'java' 'test' 'QG-TEST' $Project $Dir ($tool + @('-B', 'test'))
        if ($r -ne 0) { $testOk = $false }
    }
    if (Test-InScope 'coverage') {
        if (-not $testOk) { Add-CovSkipped 'java' $Project; return }
        $csv = Join-Path $Dir 'target/site/jacoco/jacoco.csv'
        if ($kind -eq 'gradle') {
            [void](Invoke-Logged -Dir $Dir -Argv ($tool + @('jacocoTestReport')))
            $csv = Join-Path $Dir 'build/reports/jacoco/test/jacocoTestReport.csv'
        }
        Add-Cov 'java' $Project (Get-JacocoCov $csv) (Get-Rel $csv) 'jacoco csv'
    }
}

function Invoke-StackCpp([string]$Project, [string]$Dir, [int]$Idx) {
    if (-not (Test-Tool 'cmake')) { Add-DeferProject 'cpp' $Project 'cmake'; return }
    $bdir = Join-Path $Art ('cmake-' + $Idx)
    $buildOk = $true
    $testOk = $true
    if ((Test-InScope 'build') -or (Test-InScope 'test')) {
        $r = Invoke-Override 'cpp' 'build' 'QG-BUILD' 'build' $Project $Dir
        if ($null -ne $r) { if ($r -ne 0) { $buildOk = $false } }
        else {
            $rc = Invoke-Logged -Dir $Dir -Argv @('cmake', '-S', '.', '-B', $bdir)
            if ($rc -ne 0) { Add-Check 'QG-BUILD' 'build' 'cpp' $Project 'fail' 'error' 'cmake -S . -B <build>' $rc 'cmake configure failed' 'implementer' (Get-Rel $script:LastLog); $buildOk = $false }
            else {
                $r = Invoke-Step -Id 'QG-BUILD' -Name 'build' -Stack 'cpp' -Project $Project -Dir $Dir -Owner 'implementer' -Argv @('cmake', '--build', $bdir)
                if ($r -ne 0) { $buildOk = $false }
            }
        }
    }
    if (Test-InScope 'lint') {
        $r = Invoke-Override 'cpp' 'lint' 'QG-LINT' 'lint' $Project $Dir
        if ($null -eq $r) { Add-Check 'QG-LINT' 'lint' 'cpp' $Project 'skipped' 'warning' '' $null 'no default C/C++ lint; set quality.commands.cpp.lint (e.g. clang-tidy)' 'implementer' '' }
    }
    if (Test-InScope 'test') {
        $r = Invoke-Override 'cpp' 'test' 'QG-TEST' 'test' $Project $Dir
        if ($null -ne $r) { if ($r -ne 0) { $testOk = $false } }
        elseif (-not $buildOk) { Add-Check 'QG-TEST' 'test' 'cpp' $Project 'fail' 'error' '' $null 'build failed; tests not run' 'implementer' ''; $testOk = $false }
        elseif (Test-Tool 'ctest') {
            $r = Invoke-Step -Id 'QG-TEST' -Name 'test' -Stack 'cpp' -Project $Project -Dir $Dir -Owner 'implementer' -Argv @('ctest', '--test-dir', $bdir, '--output-on-failure', '--no-tests=error')
            if ($r -ne 0) { $testOk = $false }
        } else { Add-Deferred 'QG-TEST' 'test' 'cpp' $Project 'ctest' 'cpp tests'; $testOk = $false }
    }
    if (Test-InScope 'coverage') {
        if (-not $testOk) { Add-CovSkipped 'cpp' $Project; return }
        $ov = Get-Override 'cpp' 'coverage'
        if ($ov) { Invoke-CovOverride 'cpp' $Project $Dir $ov; return }
        if (-not (Test-Tool 'gcovr')) { Add-Deferred 'QG-COV' 'coverage' 'cpp' $Project 'gcovr' 'cpp coverage'; return }
        [void](Invoke-Logged -Dir $Dir -Argv @('gcovr', '-r', '.', $bdir, '--print-summary'))
        $pct = Get-GenericPct $script:LastLog '^lines:'
        if ($null -eq $pct) { $pct = Get-GenericPct $script:LastLog '' }
        Add-Cov 'cpp' $Project $pct (Get-Rel $script:LastLog) 'gcovr --print-summary'
    }
}

function Invoke-StackPhp([string]$Project, [string]$Dir, [int]$Idx) {
    if (-not (Test-Tool 'composer')) { Add-DeferProject 'php' $Project 'composer'; return }
    $testOk = $true
    $tlog = $null
    if (Test-InScope 'build') { [void](Invoke-Simple 'php' 'build' 'QG-BUILD' $Project $Dir @('composer', 'validate', '--no-check-publish')) }
    if (Test-InScope 'lint') {
        $r = Invoke-Override 'php' 'lint' 'QG-LINT' 'lint' $Project $Dir
        if ($null -eq $r) { Add-Check 'QG-LINT' 'lint' 'php' $Project 'skipped' 'warning' '' $null 'no default PHP lint; set quality.commands.php.lint (e.g. vendor/bin/phpcs)' 'implementer' '' }
    }
    if (Test-InScope 'test') {
        $r = Invoke-Override 'php' 'test' 'QG-TEST' 'test' $Project $Dir
        if ($null -ne $r) { if ($r -ne 0) { $testOk = $false } }
        elseif (Test-Path -LiteralPath (Join-Path $Dir 'vendor/bin/phpunit')) {
            $r = Invoke-Step -Id 'QG-TEST' -Name 'test' -Stack 'php' -Project $Project -Dir $Dir -Owner 'implementer' -Argv @('php', 'vendor/bin/phpunit', '--coverage-text')
            $tlog = $script:LastLog
            if ($r -ne 0) { $testOk = $false }
        } else { Add-Check 'QG-TEST' 'test' 'php' $Project 'fail' 'error' '' $null 'vendor/bin/phpunit not found (composer install?)' 'implementer' ''; $testOk = $false }
    }
    if (Test-InScope 'coverage') {
        if (-not $testOk) { Add-CovSkipped 'php' $Project; return }
        $pct = $null
        $ev = $Dir
        if ($tlog) { $pct = Get-GenericPct $tlog 'Lines:'; $ev = $tlog }
        Add-Cov 'php' $Project $pct (Get-Rel $ev) 'phpunit --coverage-text'
    }
}

# ------------------------------------------------------------------ scanners
$SecretPatterns = @(
    @('private-key', '-----BEGIN[ A-Z]*PRIVATE KEY-----'),
    @('aws-access-key', '(A3T[A-Z0-9]|AKIA|ASIA)[A-Z0-9]{16}'),
    @('github-token', 'gh[pousr]_[A-Za-z0-9]{36,}'),
    @('github-pat', 'github_pat_[A-Za-z0-9_]{60,}'),
    @('gitlab-token', 'glpat-[A-Za-z0-9_-]{20,}'),
    @('slack-token', 'xox[baprs]-[A-Za-z0-9-]{10,}'),
    @('stripe-live-key', '[sr]k_live_[0-9A-Za-z]{24,}'),
    @('google-api-key', 'AIza[0-9A-Za-z_-]{35}'),
    @('openai-key', 'sk-(proj-)?[A-Za-z0-9_-]{40,}')
)
function Test-BinaryFile([string]$File) {
    try {
        $fs = [IO.File]::OpenRead($File)
        try {
            $buf = New-Object byte[] 8000
            $n = $fs.Read($buf, 0, 8000)
            for ($i = 0; $i -lt $n; $i++) { if ($buf[$i] -eq 0) { return $true } }
        } finally { $fs.Dispose() }
    } catch { return $true }
    return $false
}
# Returns "file:line:rule" strings; never the secret value.
function Invoke-BuiltinSecretScan([string[]]$Files) {
    $hits = New-Object System.Collections.ArrayList
    foreach ($f in $Files) {
        if (-not (Test-Path -LiteralPath $f -PathType Leaf)) { continue }
        if ((Get-Item -LiteralPath $f).Length -gt 2MB) { continue }
        if (Test-BinaryFile $f) { continue }
        $lines = [IO.File]::ReadAllLines($f)
        for ($ln = 0; $ln -lt $lines.Count; $ln++) {
            foreach ($p in $SecretPatterns) {
                if ([regex]::IsMatch($lines[$ln], $p[1])) {
                    $entry = (Get-Rel $f) + ':' + ($ln + 1) + ':' + $p[0]
                    if (-not ($hits -contains $entry)) { [void]$hits.Add($entry) }
                }
            }
        }
    }
    return ,$hits
}

$GitTop = $null
if (Test-Tool 'git') {
    $r = Invoke-Native 'git' @('-C', $WS, 'rev-parse', '--show-toplevel')
    if (($r.Code -eq 0) -and ($r.Out.Count -gt 0)) { $GitTop = ([IO.Path]::GetFullPath([string]$r.Out[0])).TrimEnd('\', '/') }
}

function Invoke-SecretsCheck {
    if (-not (Test-InScope 'secrets')) { return }
    $mode = 'full'
    $files = $null
    if ($Fast -and $GitTop) {
        $mode = 'staged'
        $r = Invoke-Native 'git' @('-C', $GitTop, 'diff', '--cached', '--name-only', '--diff-filter=ACMR')
        $files = @($r.Out | Where-Object { $_ } | ForEach-Object { Join-Path $GitTop ([string]$_) })
        if ($files.Count -eq 0) { Add-Check 'QG-SECRETS' 'secrets' '' '' 'pass' 'none' 'git diff --cached --name-only' 0 'no staged files' 'human' ''; return }
    }
    if (Test-Tool 'gitleaks') {
        $report = Join-Path $Art 'gitleaks.json'
        $glCfg = @(); $glRoot = $GitTop; if (-not $glRoot) { $glRoot = $RepoRoot }
        if ($glRoot -and (Test-Path -LiteralPath (Join-Path $glRoot '.gitleaks.toml'))) { $glCfg = @('-c', (Join-Path $glRoot '.gitleaks.toml')) }
        elseif ($mode -eq 'staged') {
            # Pre-commit scan: a freshly staged lockfile is megabytes of generated hashes and made every commit wait
            # minutes. Skip lockfiles here; the full quality gate still scans them.
            $fastCfg = Join-Path $Art 'gitleaks-fast.toml'
            $toml = @('[extend]', 'useDefault = true', '[allowlist]', 'description = "KCC fast (pre-commit) scan: lockfiles are generated, skip them"',
                "paths = ['''(^|/)(package-lock\.json|npm-shrinkwrap\.json|pnpm-lock\.yaml|yarn\.lock|bun\.lockb|poetry\.lock|Pipfile\.lock|Cargo\.lock|go\.sum|composer\.lock|Gemfile\.lock)$''']") -join "`n"
            [System.IO.File]::WriteAllText($fastCfg, $toml + "`n")
            $glCfg = @('-c', $fastCfg)
        }
        $newCli = ((Invoke-Native 'gitleaks' @('dir', '--help')).Code -eq 0)
        if ($mode -eq 'staged') {
            if ($newCli) { $argv = @('gitleaks', 'git') + $glCfg + @('--staged', '--no-banner', '--redact', '--exit-code', '1', '--report-format', 'json', '--report-path', $report, $GitTop) }
            else { $argv = @('gitleaks', 'protect', '--staged', '--no-banner', '--redact', '--exit-code', '1', '--report-format', 'json', '--report-path', $report, '--source', $GitTop) }
        } else {
            if ($newCli) { $argv = @('gitleaks', 'dir') + $glCfg + @('--no-banner', '--redact', '--exit-code', '1', '--report-format', 'json', '--report-path', $report, $WS) }
            else { $argv = @('gitleaks', 'detect', '--no-git', '--no-banner', '--redact', '--exit-code', '1', '--report-format', 'json', '--report-path', $report, '--source', $WS) }
        }
        $rc = Invoke-Logged -Dir $WS -Argv $argv
        $shown = 'gitleaks ' + $argv[1] + ' --redact (' + $mode + ')'
        $count = 0
        if (Test-Path -LiteralPath $report) { $count = ([regex]::Matches([IO.File]::ReadAllText($report), '"RuleID"')).Count }
        if ($rc -eq 0) { Add-Check 'QG-SECRETS' 'secrets' '' '' 'pass' 'none' $shown $rc ('gitleaks: no leaks (' + $mode + ')') 'human' (Get-Rel $report) }
        elseif ($count -gt 0) { Add-Check 'QG-SECRETS' 'secrets' '' '' 'fail' 'error' $shown $rc ('gitleaks: ' + $count + ' potential secret(s) (redacted; fail_on=' + $FailSecrets + '); rotate and remove') 'human' (Get-Rel $report) }
        else { Add-Check 'QG-SECRETS' 'secrets' '' '' 'deferred' 'warning' $shown $rc ('gitleaks exited ' + $rc + ' without a report (a tool error, not a finding); deferred (not a pass)') 'human' (Get-Rel $script:LastLog) }
        return
    }
    if ($null -eq $files) { $files = @(Get-WalkFiles $WS -1) }
    $hits = Invoke-BuiltinSecretScan $files
    $hitFile = Join-Path $Art 'builtin-secrets.txt'
    [IO.File]::WriteAllText($hitFile, (($hits -join "`n") + "`n"))
    if ($hits.Count -gt 0) {
        Add-Missing 'gitleaks'
        $shownHits = (@($hits | Select-Object -First 5) -join ' ')
        Add-Check 'QG-SECRETS' 'secrets' '' '' 'fail' 'error' 'builtin-secret-scan' 1 ('builtin fallback found ' + $hits.Count + ' potential secret(s) in ' + $files.Count + ' ' + $mode + ' file(s): ' + $shownHits + ' (values redacted); install gitleaks for full coverage') 'human' (Get-Rel $hitFile)
    } else {
        Add-Deferred 'QG-SECRETS' 'secrets' '' '' 'gitleaks' ('secrets scan (builtin fallback clean over ' + $files.Count + ' ' + $mode + ' file(s))')
    }
}

$script:OsvError = ''
function Invoke-DepsFallback([string]$Stack, [string]$Dir, [string]$Project) {
    if (($Stack -eq 'node') -and (Test-Path -LiteralPath (Join-Path $Dir 'package-lock.json')) -and (Test-Tool 'npm')) {
        $lvl = $FailDeps
        if ($lvl -eq 'medium') { $lvl = 'moderate' }
        if ($lvl -eq 'any') { $lvl = 'low' }
        $auditArgs = @('npm', 'audit', '--json', ('--audit-level=' + $lvl)); if (-not $AuditDev) { $auditArgs += '--omit=dev' }
        $rc = Invoke-Logged -Dir $Dir -Argv $auditArgs
        $j = $null
        try { $j = [IO.File]::ReadAllText($script:LastOut) | ConvertFrom-Json } catch { $j = $null }
        $shown = 'npm audit --json --audit-level=' + $lvl + $(if ($AuditDev) { '' } else { ' --omit=dev' })
        if (($null -eq $j) -or ($null -eq $j.metadata) -or ($null -eq $j.metadata.vulnerabilities)) {
            if ($Require) { Add-Check 'QG-DEPS' 'dependencies' 'node' $Project 'fail' 'error' $shown $rc 'npm audit did not complete (registry unreachable?)' 'human' (Get-Rel $script:LastLog) }
            else { Add-Missing 'osv-scanner'; Add-Check 'QG-DEPS' 'dependencies' 'node' $Project 'deferred' 'warning' $shown $rc 'npm audit did not complete (registry unreachable?); install osv-scanner or retry online' 'human' (Get-Rel $script:LastLog) }
            return
        }
        $v = $j.metadata.vulnerabilities
        $c = 0
        foreach ($pair in @(@('critical', 9.0), @('high', 7.0), @('moderate', 4.0), @('low', 0.1))) {
            if ($pair[1] -ge $DepsFloor) { $n = $v.($pair[0]); if ($n) { $c += [int]$n } }
        }
        $total = $v.total
        if ($c -gt 0) { Add-Check 'QG-DEPS' 'dependencies' 'node' $Project 'fail' 'error' $shown $rc ('npm audit: ' + $c + " vulnerable package(s) at or above '" + $FailDeps + "' (total " + $total + ')') 'implementer' (Get-Rel $script:LastOut) }
        else { Add-Check 'QG-DEPS' 'dependencies' 'node' $Project 'pass' 'none' $shown $rc ("npm audit: none at or above '" + $FailDeps + "' (total " + $total + ')') 'implementer' (Get-Rel $script:LastOut) }
        return
    }
    if (($Stack -eq 'python') -and (Test-Tool 'pip-audit')) {
        $argv = @('pip-audit', '-f', 'json')
        if (Test-Path -LiteralPath (Join-Path $Dir 'requirements.txt')) { $argv += @('-r', 'requirements.txt') }
        $rc = Invoke-Logged -Dir $Dir -Argv $argv
        $n = ([regex]::Matches([IO.File]::ReadAllText($script:LastOut), '"fix_versions"')).Count
        $shown = Format-Cmd $argv
        if ($rc -eq 0) { Add-Check 'QG-DEPS' 'dependencies' 'python' $Project 'pass' 'none' $shown $rc 'pip-audit: no known vulnerabilities' 'implementer' (Get-Rel $script:LastOut) }
        elseif ($n -gt 0) { Add-Check 'QG-DEPS' 'dependencies' 'python' $Project 'fail' 'error' $shown $rc ('pip-audit: ' + $n + ' vulnerability(ies) (no severity data; any counts)') 'implementer' (Get-Rel $script:LastOut) }
        else { Add-Check 'QG-DEPS' 'dependencies' 'python' $Project 'fail' 'error' $shown $rc ('pip-audit failed (exit ' + $rc + ')') 'implementer' (Get-Rel $script:LastLog) }
        return
    }
    if (($Stack -eq 'dotnet') -and (Test-Tool 'dotnet')) {
        $rc = Invoke-Logged -Dir $Dir -Argv @('dotnet', 'list', 'package', '--vulnerable', '--include-transitive')
        $pat = 'Critical'
        switch ($FailDeps) { 'high' { $pat = 'Critical|High' } 'medium' { $pat = 'Critical|High|Moderate' } 'moderate' { $pat = 'Critical|High|Moderate' } 'low' { $pat = 'Critical|High|Moderate|Low' } 'any' { $pat = 'Critical|High|Moderate|Low' } }
        $n = @([IO.File]::ReadAllLines($script:LastLog) | Where-Object { $_ -cmatch ('\s(' + $pat + ')\s') }).Count
        $shown = 'dotnet list package --vulnerable --include-transitive'
        if ($rc -ne 0) { Add-Check 'QG-DEPS' 'dependencies' 'dotnet' $Project 'fail' 'error' $shown $rc ('dotnet vulnerability listing failed (exit ' + $rc + ')') 'implementer' (Get-Rel $script:LastLog) }
        elseif ($n -gt 0) { Add-Check 'QG-DEPS' 'dependencies' 'dotnet' $Project 'fail' 'error' $shown $rc ($n + " vulnerable package(s) at or above '" + $FailDeps + "'") 'implementer' (Get-Rel $script:LastLog) }
        else { Add-Check 'QG-DEPS' 'dependencies' 'dotnet' $Project 'pass' 'none' $shown $rc ("no vulnerable packages at or above '" + $FailDeps + "'") 'implementer' (Get-Rel $script:LastLog) }
        return
    }
    $fb = ''
    if ($Stack -eq 'python') { $fb = ' (or pip-audit)' }
    if ($script:OsvError) {
        Add-Check 'QG-DEPS' 'dependencies' $Stack $Project 'deferred' 'warning' '' $null ('dependency scan' + $fb + ': ' + $script:OsvError + ' and no stack audit for ' + $Stack + '; deferred (not a pass): run the scanner by hand or set quality.scanners.dependencies') 'human' (Get-Rel $Dir)
        return
    }
    Add-Deferred 'QG-DEPS' 'dependencies' $Stack $Project 'osv-scanner' ('dependency scan' + $fb)
}

# The lockfiles of the workspace (and, when it has no node lockfile of its own, the lockfile of an ancestor npm/yarn/pnpm
# workspace root, as QG-LOCK accepts it), for `osv-scanner -L`. Same set as deps_lockfiles in quality-gate.sh.
function Get-DepsLockfiles([System.Collections.ArrayList]$Projects) {
    $names = @('package-lock.json', 'npm-shrinkwrap.json', 'pnpm-lock.yaml', 'yarn.lock', 'poetry.lock', 'uv.lock', 'Pipfile.lock', 'Cargo.lock', 'composer.lock', 'packages.lock.json', 'gradle.lockfile')
    $found = @(Get-WalkFiles $WS 5 | Where-Object { $names -ccontains (Split-Path -Leaf $_) } | Sort-Object)
    $nodeNames = @('package-lock.json', 'npm-shrinkwrap.json', 'pnpm-lock.yaml', 'yarn.lock')
    $nodeFound = @($found | Where-Object { $nodeNames -ccontains (Split-Path -Leaf $_) }).Count -gt 0
    if ((-not $nodeFound) -and (@($Projects | Where-Object { $_.stack -eq 'node' }).Count -gt 0)) {
        $anc = Get-NodeWsRootLock
        if ($anc -and ($nodeNames -ccontains (Split-Path -Leaf $anc))) { $found += $anc }
    }
    return $found
}

function Invoke-DepsCheck([System.Collections.ArrayList]$Projects) {
    if (-not (Test-InScope 'deps')) { return }
    if ($Projects.Count -eq 0) { Add-Check 'QG-DEPS' 'dependencies' '' '' 'skipped' 'none' '' $null 'no dependency manifests detected' 'implementer' ''; return }
    if (Test-Tool 'osv-scanner') {
        $out = Join-Path $Art 'osv.json'
        # Scan the lockfiles by name as well as the directory: a directory walk can come back with "no packages" (gitignore, path form)
        # although the workspace has a lockfile (round 11, npm workspaces). A lockfile named with -L is always read.
        # The lockfiles by name (-L): a directory walk can come back with "no packages" although the workspace has a lockfile (round 11,
        # npm workspaces). osv-scanner 2.x takes either -L or -r; given both it stops with exit 127 before scanning (round 12: QG-DEPS
        # red for a whole run), so the directory walk runs only when no lockfile was found.
        $lockfiles = @(Get-DepsLockfiles $Projects)
        $argv = @('osv-scanner', '--format', 'json')
        if ($lockfiles.Count -gt 0) { foreach ($lf in $lockfiles) { $argv += @('-L', $lf) }; $shown = 'osv-scanner --format json -L <lockfile>...' }
        else { $argv += @('-r', $WS); $shown = 'osv-scanner --format json -r <ws>' }
        $rc = Invoke-Logged -Dir $WS -Argv $argv
        Copy-Item -LiteralPath $script:LastOut -Destination $out -Force
        if ($rc -eq 0) { Add-Check 'QG-DEPS' 'dependencies' '' '' 'pass' 'none' $shown $rc 'osv-scanner: no known vulnerabilities' 'implementer' (Get-Rel $out); return }
        if ($rc -eq 128) {
            # The scanner looked and found no packages: nothing was checked, so this is not a pass.
            $nomsg = 'osv-scanner found no packages to scan (nothing was checked)'
            if ($Require) { Add-Check 'QG-DEPS' 'dependencies' '' '' 'fail' 'error' $shown $rc ($nomsg + ' (--require)') 'implementer' (Get-Rel $out) }
            else { Add-Check 'QG-DEPS' 'dependencies' '' '' 'deferred' 'warning' $shown $rc ($nomsg + '; deferred (not a pass)') 'human' (Get-Rel $out) }
            return
        }
        if ($rc -ne 1) {
            # The scanner stopped before it produced a result (a flag it rejects, a crash, a database it cannot load). That is a tool
            # error, not a finding and not the implementer's code: the per-stack audit stands in where there is one, else the check is
            # deferred to a human (never a pass, never a FIX pass).
            $first = ''
            try { $first = @([IO.File]::ReadAllLines($script:LastLog) | Where-Object { $_.Trim() } | Select-Object -First 1)[0]; if ($first -and $first.Length -gt 160) { $first = $first.Substring(0, 160) } } catch { $first = '' }
            $script:OsvError = 'osv-scanner exited ' + $rc + ' before scanning (a tool error, not a result' + $(if ($first) { ': ' + $first } else { '' }) + ')'
            Add-Check 'QG-DEPS' 'dependencies' '' '' 'skipped' 'warning' $shown $rc ($script:OsvError + '; the stack audit below stands in') 'human' (Get-Rel $script:LastLog)
            foreach ($p in $Projects) { Invoke-DepsFallback $p.stack $p.dir (Get-Rel $p.dir) }
            return
        }
        # osv-scanner marks each package with its dependency_groups (npm, pip, bundler...); a "dev" package gates only when
        # quality.audit_dev_dependencies is true (round 12: vitest and tinypool advisories are not what ships). Unknown severity counts.
        $above = 0; $total = 0; $devn = 0
        $j = $null
        try { $j = [IO.File]::ReadAllText($out) | ConvertFrom-Json } catch { $j = $null }
        if ($null -ne $j -and $null -ne $j.results) {
            foreach ($r in @($j.results)) {
                foreach ($pk in @($r.packages)) {
                    $isdev = (@($pk.dependency_groups) -contains 'dev')
                    foreach ($g in @($pk.groups)) {
                        if ($isdev -and -not $AuditDev) { $devn++; continue }
                        $total++
                        $sv = [string]$g.max_severity
                        if ((-not $sv) -or ([double]$sv -ge $DepsFloor)) { $above++ }
                    }
                }
            }
        } else {
            foreach ($m in [regex]::Matches([IO.File]::ReadAllText($out), '"max_severity"\s*:\s*"([0-9.]*)"')) {
                $total++
                $sv = $m.Groups[1].Value
                if ((-not $sv) -or ([double]$sv -ge $DepsFloor)) { $above++ }
            }
        }
        $devnote = ''; if ($devn -gt 0) { $devnote = '; ' + $devn + ' dev-only group(s) not gating (quality.audit_dev_dependencies=false)' }
        if ($above -gt 0) { Add-Check 'QG-DEPS' 'dependencies' '' '' 'fail' 'error' $shown $rc ('osv-scanner: ' + $above + ' of ' + $total + " production vulnerability group(s) at or above '" + $FailDeps + "' (unknown severity counts)" + $devnote) 'implementer' (Get-Rel $out) }
        else { Add-Check 'QG-DEPS' 'dependencies' '' '' 'pass' 'none' $shown $rc ('osv-scanner: ' + $total + " production group(s), none at or above '" + $FailDeps + "'" + $devnote) 'implementer' (Get-Rel $out) }
        return
    }
    Add-Missing 'osv-scanner'
    foreach ($p in $Projects) { Invoke-DepsFallback $p.stack $p.dir (Get-Rel $p.dir) }
}

function Invoke-SastCheck {
    if (-not (Test-InScope 'sast')) { return }
    $useDocker = $false
    # quality.scanners.sast names the scanner (semgrep, the default, or opengrep, its LGPL fork that takes the same rules and flags);
    # when the named one is missing the other stands in, so a machine with either runs SAST. Rules: quality.sast_rules
    # (default `auto`, the registry; opengrep has no registry, so give it a local rules folder or it is deferred).
    $sast = 'semgrep'; if ($SastTool -eq 'opengrep') { $sast = 'opengrep' }
    if (-not (Test-Tool $sast)) {
        if (($sast -eq 'semgrep') -and (Test-Tool 'opengrep')) { $sast = 'opengrep' }
        elseif (($sast -eq 'opengrep') -and (Test-Tool 'semgrep')) { $sast = 'semgrep' }
        elseif (($SastRunner -eq 'docker' -or $SastRunner -eq 'auto') -and (Test-Tool 'docker')) { $useDocker = $true }   # auto: the image stands in when no scanner is on PATH (Windows has no native semgrep)
        else { Add-Deferred 'QG-SAST' 'sast' '' '' $sast 'SAST'; return }
    }
    $rules = $SastRules
    if (($sast -eq 'opengrep') -and ($rules -eq 'auto')) {
        $local = Join-Path (Join-Path $RepoRoot 'architecture') 'sast-rules'
        if (Test-Path -LiteralPath $local -PathType Container) { $rules = $local }
        else { Add-Check 'QG-SAST' 'sast' '' '' 'deferred' 'warning' 'opengrep scan' $null 'opengrep has no rule registry: put rules under architecture/sast-rules/ or set quality.sast_rules; deferred (not a pass)' 'human' ''; return }
    }
    $out = Join-Path $Art 'semgrep.json'
    if ($useDocker) {
        # KCC_CA_BUNDLE: the user-scope registry value wins over a stale inherited process value
        # (long-lived harness processes keep the value they started with).
        $caBundle = $env:KCC_CA_BUNDLE
        if ($IsWin) { $caReg = [Environment]::GetEnvironmentVariable('KCC_CA_BUNDLE', 'User'); if ($caReg -and (Test-Path -LiteralPath $caReg)) { $caBundle = $caReg } }
        $caArgs = @(); if ($caBundle -and (Test-Path -LiteralPath $caBundle)) { $caArgs = @('-v', ($caBundle + ':/certs/ca.pem:ro'), '-e', 'SSL_CERT_FILE=/certs/ca.pem', '-e', 'REQUESTS_CA_BUNDLE=/certs/ca.pem', '-e', 'CURL_CA_BUNDLE=/certs/ca.pem') }
        $rc = Invoke-Logged -Dir $WS -Argv (@('docker', 'run', '--rm', '-v', ($WS + ':/src'), '-v', ($Art + ':/out')) + $caArgs + @('semgrep/semgrep', 'semgrep', 'scan', '--config', 'auto', '--json', '--quiet', '--output', '/out/semgrep.json', '/src'))
        $shown = 'docker run --rm semgrep/semgrep semgrep scan --config auto --json'
    } else {
        $rc = Invoke-Logged -Dir $WS -Argv @($sast, 'scan', '--config', $rules, '--json', '--quiet', '--output', $out, $WS)
        $shown = $sast + ' scan --config ' + $rules + ' --json'
    }
    if (-not (Test-Path -LiteralPath $out)) {
        # No result file: the scanner did not run to completion (rules unreachable, a crash). A tool error is deferred, never a code finding.
        $first = ''
        try { $first = @([IO.File]::ReadAllLines($script:LastLog) | Where-Object { $_.Trim() } | Select-Object -First 1)[0]; if ($first -and $first.Length -gt 160) { $first = $first.Substring(0, 160) } } catch { $first = '' }
        Add-Check 'QG-SAST' 'sast' '' '' 'deferred' 'warning' $shown $rc ($sast + ' exited ' + $rc + ' without a result (a tool error, not a finding' + $(if ($first) { ': ' + $first } else { '' }) + '); deferred (not a pass)') 'human' (Get-Rel $script:LastLog); return
    }
    $pat = 'ERROR'
    if ($FailSast -eq 'warning') { $pat = 'ERROR|WARNING' }
    if (($FailSast -eq 'info') -or ($FailSast -eq 'any')) { $pat = 'ERROR|WARNING|INFO' }
    $n = ([regex]::Matches([IO.File]::ReadAllText($out), ('"severity"\s*:\s*"(' + $pat + ')"'))).Count
    if ($n -gt 0) { Add-Check 'QG-SAST' 'sast' '' '' 'fail' 'error' $shown $rc ($sast + ': ' + $n + ' finding(s) at severity >= ' + $FailSast) 'implementer' (Get-Rel $out) }
    elseif (($rc -ne 0) -and ($rc -ne 1)) { Add-Check 'QG-SAST' 'sast' '' '' 'deferred' 'warning' $shown $rc ($sast + ' exited ' + $rc + ' (a tool error, not a finding); deferred (not a pass)') 'human' (Get-Rel $out) }
    else { Add-Check 'QG-SAST' 'sast' '' '' 'pass' 'none' $shown $rc ($sast + ': no findings at severity >= ' + $FailSast) 'implementer' (Get-Rel $out) }
}

# ------------------------------------------------------------------ QG-STATIC (architecture/static-rules.tsv)
# One rule per line, tab-separated: id <TAB> files <TAB> forbidden <TAB> allowed_in <TAB> message
#   files      regex matched against the path relative to the workspace (which files the rule scans)
#   forbidden  regex searched in every matching file (keep to the POSIX ERE subset so both shells agree)
#   allowed_in regex of relative paths where the pattern IS permitted (may be empty)
# '#' starts a comment line; a header row "id<TAB>files<TAB>..." is ignored. node_modules, dist, build, .git, coverage,
# TestResults, lockfiles and the rules file itself are never scanned; test files are scanned like any other.
function Test-RegexOk([string]$Pattern) {
    try { $null = New-Object System.Text.RegularExpressions.Regex($Pattern); return $true } catch { return $false }
}
function Invoke-StaticCheck {
    if (-not (Test-InScope 'static')) { return }
    $rrel = 'architecture/static-rules.tsv'
    $rules = Join-Path (Join-Path $RepoRoot 'architecture') 'static-rules.tsv'
    if (-not (Test-Path -LiteralPath $rules -PathType Leaf)) {
        Add-Check 'QG-STATIC' 'static-rules' '' '' 'skipped' 'none' '' $null 'no architecture/static-rules.tsv declared' 'architect' ''
        return
    }
    $rid = New-Object System.Collections.ArrayList
    $rfiles = New-Object System.Collections.ArrayList
    $rpat = New-Object System.Collections.ArrayList
    $rallow = New-Object System.Collections.ArrayList
    $bad = New-Object System.Collections.ArrayList
    $n = 0
    foreach ($raw in [IO.File]::ReadAllLines($rules)) {
        $n++
        $line = $raw.TrimEnd("`r")
        $t = $line.TrimStart()
        if (($t.Length -eq 0) -or $t.StartsWith('#')) { continue }
        $cols = $line.Split([char]9)
        if ($cols.Count -lt 5) { [void]$bad.Add('line ' + $n + ': expected 5 tab-separated columns (id, files, forbidden, allowed_in, message), found ' + $cols.Count); continue }
        $id = $cols[0]; $files = $cols[1]; $pat = $cols[2]; $allow = $cols[3]
        $msg = ($cols[4..($cols.Count - 1)] -join "`t")
        if (($id -eq 'id') -and ($files -eq 'files')) { continue }
        if ((-not $id) -or (-not $files) -or (-not $pat) -or (-not $msg)) { [void]$bad.Add('line ' + $n + ': id, files, forbidden and message must not be empty'); continue }
        if (-not (Test-RegexOk $files)) { [void]$bad.Add('line ' + $n + ' (' + $id + "): 'files' is not a valid regex"); continue }
        if (-not (Test-RegexOk $pat)) { [void]$bad.Add('line ' + $n + ' (' + $id + "): 'forbidden' is not a valid regex"); continue }
        if ($allow -and (-not (Test-RegexOk $allow))) { [void]$bad.Add('line ' + $n + ' (' + $id + "): 'allowed_in' is not a valid regex"); continue }
        [void]$rid.Add($id); [void]$rfiles.Add($files); [void]$rpat.Add($pat); [void]$rallow.Add($allow)
    }
    if ($bad.Count -gt 0) {
        $shownBad = @($bad | Select-Object -First 5)
        Add-Check 'QG-STATIC' 'static-rules' '' '' 'fail' 'error' '' $null ($rrel + ' is malformed (' + $bad.Count + ' line(s)): ' + (($shownBad | ForEach-Object { $_ + '; ' }) -join '') + 'fix the rules file') 'architect' $rrel
        return
    }
    if ($rid.Count -eq 0) {
        Add-Check 'QG-STATIC' 'static-rules' '' '' 'skipped' 'none' '' $null ($rrel + ' declares no rules') 'architect' $rrel
        return
    }
    # file list: relative paths (forward slashes), ordinal order, same pruning as the bash mirror
    $skipDirs = @('node_modules', 'dist', 'build', '.git', 'coverage', 'TestResults')
    $skipFiles = @('package-lock.json', 'npm-shrinkwrap.json', 'pnpm-lock.yaml', 'yarn.lock', 'bun.lockb', 'bun.lock', 'poetry.lock', 'Pipfile.lock', 'Cargo.lock', 'go.sum', 'composer.lock', 'Gemfile.lock')
    $rels = New-Object System.Collections.ArrayList
    $queue = New-Object System.Collections.Queue
    $queue.Enqueue($WS)
    $wsPrefix = $WS.TrimEnd('\', '/') + $Sep
    $wsIsRoot = ($WS -ieq $RepoRoot)
    while ($queue.Count -gt 0) {
        $dir = $queue.Dequeue()
        try {
            foreach ($f in [IO.Directory]::GetFiles($dir)) {
                $leaf = Split-Path -Leaf $f
                if ($skipFiles -contains $leaf) { continue }
                $r = $f.Substring($wsPrefix.Length).Replace('\', '/')
                if ($wsIsRoot -and ($r -eq $rrel)) { continue }
                [void]$rels.Add($r)
            }
        } catch { }
        try {
            foreach ($d in [IO.Directory]::GetDirectories($dir)) {
                if ($skipDirs -contains (Split-Path -Leaf $d)) { continue }
                $queue.Enqueue($d)
            }
        } catch { }
    }
    $relArr = $rels.ToArray()
    [Array]::Sort($relArr, [StringComparer]::Ordinal)
    $hits = New-Object System.Collections.ArrayList
    for ($i = 0; $i -lt $rid.Count; $i++) {
        $reFiles = New-Object System.Text.RegularExpressions.Regex($rfiles[$i])
        $reAllow = $null
        if ($rallow[$i]) { $reAllow = New-Object System.Text.RegularExpressions.Regex($rallow[$i]) }
        $rePat = New-Object System.Text.RegularExpressions.Regex($rpat[$i])
        $reAny = New-Object System.Text.RegularExpressions.Regex($rpat[$i], [System.Text.RegularExpressions.RegexOptions]::Multiline)
        foreach ($r in $relArr) {
            if (-not $reFiles.IsMatch($r)) { continue }
            if ($reAllow -and $reAllow.IsMatch($r)) { continue }
            $text = $null
            try { $text = [IO.File]::ReadAllText($wsPrefix + ($r -replace '/', $Sep)) } catch { continue }
            if ($text.IndexOf([char]0) -ge 0) { continue }
            if (-not $reAny.IsMatch($text)) { continue }
            # Multi-stage Dockerfiles: `FROM <stage> AS <next>` names a stage declared earlier, not an untagged image (round 14, SR-018).
            $stages = @()
            if ($r -match '(^|/)Dockerfile[^/]*$') { $stages = @([regex]::Matches($text, '(?im)^\s*FROM\s+\S+\s+AS\s+([\w.-]+)') | ForEach-Object { $_.Groups[1].Value.ToLowerInvariant() }) }
            $ln = 0
            foreach ($l in $text.Split([char]10)) {
                $ln++
                if (-not $rePat.IsMatch($l)) { continue }
                if ($stages.Count -gt 0 -and $l -match '^\s*FROM\s+(\S+)' -and ($stages -contains $Matches[1].ToLowerInvariant())) { continue }
                [void]$hits.Add($r + ':' + $ln + ' ' + $rid[$i])
            }
        }
    }
    $cmdShown = 'static-rules scan (' + $rid.Count + ' rule(s) from ' + $rrel + ')'
    if ($hits.Count -eq 0) {
        Add-Check 'QG-STATIC' 'static-rules' '' '' 'pass' 'none' $cmdShown 0 ('static rules: ' + $rid.Count + ' rule(s) over ' + $relArr.Count + ' file(s), no forbidden pattern found') 'implementer' ''
        return
    }
    $ev = Join-Path $Art 'static-hits.txt'
    $evLines = New-Object System.Collections.ArrayList
    foreach ($h in ($hits | Select-Object -First 20)) { [void]$evLines.Add($h) }
    if ($hits.Count -gt 20) { [void]$evLines.Add('... and ' + ($hits.Count - 20) + ' more') }
    [IO.File]::WriteAllText($ev, (($evLines -join "`n") + "`n"))
    $ids = @($hits | ForEach-Object { $_.Substring($_.LastIndexOf(' ') + 1) } | Sort-Object -Unique) -join ','
    $first = (@($hits | Select-Object -First 3) -join ', ')
    Add-Check 'QG-STATIC' 'static-rules' '' '' 'fail' 'error' $cmdShown 1 ('static rules: ' + $hits.Count + ' forbidden-pattern hit(s) (rule(s): ' + $ids + '); first: ' + $first + '; first 20 in the evidence file') 'implementer' (Get-Rel $ev)
}

# ------------------------------------------------------------------ QG-IMAGE image-scan-built (compose-built images)
# Images come from the compose file(s) in the workspace or the repo root: the image: value of every service that has build:, or
# <project>-<service> (what compose names it) when no image: is set. The compose file is parsed, not rendered with
# "docker compose config", because that needs every required ${VAR:?} to be set and fails on a clean checkout.
function Get-ComposeFiles {
    $seen = @{}
    $found = New-Object System.Collections.ArrayList
    foreach ($d in @($WS, $RepoRoot)) {
        foreach ($n in @('docker-compose.yml', 'docker-compose.yaml', 'compose.yml', 'compose.yaml')) {
            $p = Join-Path $d $n
            if ((Test-Path -LiteralPath $p -PathType Leaf) -and (-not $seen.ContainsKey($p.ToLowerInvariant()))) {
                $seen[$p.ToLowerInvariant()] = $true
                [void]$found.Add($p)
            }
        }
    }
    return ,$found
}
function Get-YamlValue([string]$Text) {
    $v = $Text -replace '^[^:]*:\s*', ''
    $v = $v -replace '\s+#.*$', ''
    $v = $v.Trim()
    if (($v.Length -ge 2) -and (($v.StartsWith('"') -and $v.EndsWith('"')) -or ($v.StartsWith("'") -and $v.EndsWith("'")))) { $v = $v.Substring(1, $v.Length - 2) }
    return $v
}
# Returns @{ project = '<top-level name:>'; services = @( @{ name; image; build } ) }
function Read-Compose([string]$File) {
    $project = ''
    $services = New-Object System.Collections.ArrayList
    $insvc = $false; $svcind = 0; $propind = 0
    $cur = $null
    foreach ($raw in [IO.File]::ReadAllLines($File)) {
        $line = $raw.TrimEnd("`r")
        if ($line -match '^\s*(#.*)?$') { continue }
        $ind = $line.Length - $line.TrimStart(' ').Length
        $txt = $line.TrimStart(' ')
        if ($ind -eq 0) {
            if ($cur) { [void]$services.Add($cur); $cur = $null }
            $insvc = ($txt -match '^services:\s*(#.*)?$')
            if ($txt -match '^name:') { $project = Get-YamlValue $txt }
            continue
        }
        if (-not $insvc) { continue }
        if ($svcind -eq 0) { $svcind = $ind }
        if ($ind -eq $svcind) {
            if ($cur) { [void]$services.Add($cur) }
            $nm = ($txt -replace ':.*$', '') -replace '["'' ]', ''
            $cur = @{ name = $nm; image = ''; build = $false }
            continue
        }
        if ($propind -eq 0) { $propind = $ind }
        if (($ind -eq $propind) -and $cur) {
            if ($txt -match '^build:') { $cur.build = $true }
            elseif ($txt -match '^image:') { $cur.image = Get-YamlValue $txt }
        }
    }
    if ($cur) { [void]$services.Add($cur) }
    return @{ project = $project; services = $services }
}
function Expand-EnvRefs([string]$S) {
    $re = '\$\{([A-Za-z_][A-Za-z0-9_]*)(:?-([^}]*))?\}'
    for ($k = 0; $k -lt 10; $k++) {
        $m = [regex]::Match($S, $re)
        if (-not $m.Success) { break }
        $val = [Environment]::GetEnvironmentVariable($m.Groups[1].Value)
        if (-not $val) { $val = $m.Groups[3].Value }
        $S = $S.Substring(0, $m.Index) + $val + $S.Substring($m.Index + $m.Length)
    }
    return $S
}
function Get-TrivyCount([string]$File) {
    if (-not (Test-Path -LiteralPath $File)) { return 0 }
    return ([regex]::Matches([IO.File]::ReadAllText($File), '"Severity"\s*:\s*"[A-Z]+"')).Count
}
# The first workspace file newer than the image's Created time (sources, manifests, lockfiles, Dockerfiles; build output and
# dependency folders pruned), or '' when the image is newer than all of them or its time cannot be read.
function Get-ImageStaleFile([string]$Img) {
    $created = ''
    try { $created = [string](& docker image inspect -f '{{.Created}}' $Img 2>$null | Select-Object -First 1) } catch { $created = '' }
    if (-not $created) { return '' }
    $created = ($created.Trim() -replace '\.(\d{1,7})\d*', '.$1')
    $t = [DateTime]::MinValue
    $styles = [Globalization.DateTimeStyles]::AdjustToUniversal -bor [Globalization.DateTimeStyles]::AssumeUniversal
    if (-not [DateTime]::TryParse($created, [Globalization.CultureInfo]::InvariantCulture, $styles, [ref]$t)) { return '' }
    foreach ($f in (Get-WalkFiles $WS -1)) { try { if ([IO.File]::GetLastWriteTimeUtc($f) -gt $t) { return $f } } catch { } }
    return ''
}
function Invoke-ImageBuiltCheck([bool]$HasDockerfile) {
    $files = Get-ComposeFiles
    if ($files.Count -eq 0) {
        if ($HasDockerfile) { Add-Check 'QG-IMAGE' 'image-scan-built' '' '' 'skipped' 'none' '' $null 'no compose file declared (docker-compose.yml/compose.yml): built-image scan skipped' 'infrastructure-implementer' '' }
        return
    }
    $imgs = New-Object System.Collections.ArrayList
    foreach ($f in $files) {
        $c = Read-Compose $f
        $proj = $env:COMPOSE_PROJECT_NAME
        if (-not $proj) { $proj = $c.project }
        if (-not $proj) { $proj = Split-Path -Leaf (Split-Path -Parent $f) }
        $proj = ($proj.ToLowerInvariant() -replace '[^a-z0-9_-]', '')
        foreach ($s in $c.services) {
            if (-not $s.build) { continue }
            $img = Expand-EnvRefs $s.image
            if (-not $img) { $img = $proj + '-' + $s.name }
            if (-not ($imgs -contains $img)) { [void]$imgs.Add($img) }
        }
    }
    if ($imgs.Count -eq 0) {
        if ($HasDockerfile) { Add-Check 'QG-IMAGE' 'image-scan-built' '' '' 'skipped' 'none' '' $null 'compose file declares no service with build: built-image scan skipped' 'infrastructure-implementer' '' }
        return
    }
    if (-not (Test-Tool 'docker')) { Add-Deferred 'QG-IMAGE' 'image-scan-built' '' '' 'docker' 'built-image scan'; return }
    if (-not (Test-Tool 'trivy')) { Add-Deferred 'QG-IMAGE' 'image-scan-built' '' '' 'trivy' 'built-image scan'; return }
    $sevs = 'CRITICAL'
    switch ($FailDeps) { 'high' { $sevs = 'HIGH,CRITICAL' } 'medium' { $sevs = 'MEDIUM,HIGH,CRITICAL' } 'moderate' { $sevs = 'MEDIUM,HIGH,CRITICAL' } 'low' { $sevs = 'LOW,MEDIUM,HIGH,CRITICAL' } 'any' { $sevs = 'LOW,MEDIUM,HIGH,CRITICAL' } }
    $i = 0
    foreach ($img in $imgs) {
        $i++
        $rc = Invoke-Logged -Dir $WS -Argv @('docker', 'image', 'inspect', $img)
        if ($rc -ne 0) {
            # not built (or the daemon is unreachable): never a pass, and this tool does not build (builds are slow)
            if ($Require) { Add-Check 'QG-IMAGE' 'image-scan-built' '' '' 'fail' 'error' ('docker image inspect ' + $img) $rc ("built image '" + $img + "' not found locally: image not built: run docker compose build (-Require)") 'infrastructure-implementer' ('image-not-built:' + $img) }
            else { Add-Check 'QG-IMAGE' 'image-scan-built' '' '' 'deferred' 'warning' ('docker image inspect ' + $img) $rc ("built image '" + $img + "' not found locally: image not built: run docker compose build; deferred (not a pass)") 'infrastructure-implementer' ('image-not-built:' + $img) }
            continue
        }
        # An image older than the workspace files was not built from this code (round 12: images left over from an earlier run were
        # scanned and failed the gate). Stale = deferred with a rebuild hint; only an image newer than every source file is scanned.
        $newer = Get-ImageStaleFile $img
        if ($newer) {
            $when = ''; try { $when = ([string](& docker image inspect -f '{{.Created}}' $img 2>$null | Select-Object -First 1)).Trim(); if ($when.Length -gt 19) { $when = $when.Substring(0, 19) } } catch { $when = '' }
            Add-Check 'QG-IMAGE' 'image-scan-built' '' '' 'deferred' 'warning' ('docker image inspect ' + $img) 0 ("built image '" + $img + "' is older than the workspace file " + (Get-Rel $newer) + ' (built ' + $when + '): stale, not scanned; run docker compose build and re-run the gate; deferred (not a pass)') 'infrastructure-implementer' ('image-stale:' + $img)
            continue
        }
        $out = Join-Path $Art ('trivy-image-' + $i + '.json')
        $all = Join-Path $Art ('trivy-image-' + $i + '-all.json')
        $shown = 'trivy image --severity ' + $sevs + ' --ignore-unfixed --exit-code 1 ' + $img
        $rc = Invoke-Logged -Dir $WS -Argv @('trivy', 'image', '--severity', $sevs, '--ignore-unfixed', '--exit-code', '1', '--format', 'json', '--output', $out, $img)
        $logf = $script:LastLog
        if (($rc -ne 0) -and (($rc -ne 1) -or (-not (Test-Path -LiteralPath $out)))) {
            Add-Check 'QG-IMAGE' 'image-scan-built' '' '' 'deferred' 'warning' $shown $rc ('trivy image ' + $img + ' exited ' + $rc + ' without a report (a tool error or an unreachable database, not a finding); deferred (not a pass)') 'human' (Get-Rel $logf)
            continue
        }
        $nfix = 0
        if ($rc -eq 1) { $nfix = Get-TrivyCount $out }
        # second pass without --ignore-unfixed: only to report how many findings have no fix (visible, never gating)
        $unf = 'unfixed count unavailable'
        $rc2 = Invoke-Logged -Dir $WS -Argv @('trivy', 'image', '--severity', $sevs, '--format', 'json', '--output', $all, $img)
        if (($rc2 -eq 0) -and (Test-Path -LiteralPath $all)) {
            $ntot = Get-TrivyCount $all
            $nun = $ntot - $nfix
            if ($nun -lt 0) { $nun = 0 }
            $unf = [string]$nun + ' unfixed, not gating'
        }
        if ($rc -eq 0) {
            $evf = $out
            if (Test-Path -LiteralPath $all) { $evf = $all }
            Add-Check 'QG-IMAGE' 'image-scan-built' '' '' 'pass' 'none' $shown $rc ('trivy image ' + $img + ': no fixable finding at ' + $sevs + ' (' + $unf + ')') 'infrastructure-implementer' (Get-Rel $evf)
        } else {
            Add-Check 'QG-IMAGE' 'image-scan-built' '' '' 'fail' 'error' $shown $rc ('trivy image ' + $img + ': ' + $nfix + ' fixable finding(s) at ' + $sevs + ' (' + $unf + ')') 'infrastructure-implementer' (Get-Rel $out)
        }
    }
}

function Invoke-ContainerChecks {
    if ((-not (Test-InScope 'sbom')) -and (-not (Test-InScope 'image'))) { return }
    $docker = @(Get-WalkFiles $WS 3 | Where-Object { $n = Split-Path -Leaf $_; ($n -eq 'Dockerfile') -or ($n -like 'Dockerfile.*') -or ($n -like '*.Dockerfile') -or ($n -eq 'Containerfile') })
    if ($docker.Count -eq 0) {
        if (Test-InScope 'sbom') { Add-Check 'QG-SBOM' 'sbom' '' '' 'skipped' 'none' '' $null 'not a deployable (no Dockerfile/Containerfile)' 'infrastructure-implementer' '' }
        if (Test-InScope 'image') { Add-Check 'QG-IMAGE' 'image-scan' '' '' 'skipped' 'none' '' $null 'not a deployable (no Dockerfile/Containerfile)' 'infrastructure-implementer' '' }
        if (Test-InScope 'image') { Invoke-ImageBuiltCheck $false }
        return
    }
    if (Test-InScope 'sbom') {
        if (Test-Tool 'syft') {
            $sbom = Join-Path $Art 'sbom.cdx.json'
            $rc = Invoke-Logged -Dir $WS -Argv @('syft', ('dir:' + $WS), '-o', ('cyclonedx-json=' + $sbom))
            if (($rc -eq 0) -and (Test-Path -LiteralPath $sbom) -and ((Get-Item -LiteralPath $sbom).Length -gt 0)) { Add-Check 'QG-SBOM' 'sbom' '' '' 'pass' 'none' 'syft dir:<ws> -o cyclonedx-json' $rc 'SBOM generated' 'infrastructure-implementer' (Get-Rel $sbom) }
            else { Add-Check 'QG-SBOM' 'sbom' '' '' 'fail' 'error' 'syft dir:<ws> -o cyclonedx-json' $rc ('syft failed (exit ' + $rc + ')') 'infrastructure-implementer' (Get-Rel $script:LastLog) }
        } else { Add-Deferred 'QG-SBOM' 'sbom' '' '' 'syft' 'SBOM' }
    }
    if (Test-InScope 'image') {
        if (Test-Tool 'trivy') {
            $sevs = 'CRITICAL'
            switch ($FailDeps) { 'high' { $sevs = 'HIGH,CRITICAL' } 'medium' { $sevs = 'MEDIUM,HIGH,CRITICAL' } 'moderate' { $sevs = 'MEDIUM,HIGH,CRITICAL' } 'low' { $sevs = 'LOW,MEDIUM,HIGH,CRITICAL' } 'any' { $sevs = 'LOW,MEDIUM,HIGH,CRITICAL' } }
            $out = Join-Path $Art 'trivy.json'
            $rc = Invoke-Logged -Dir $WS -Argv @('trivy', 'fs', '--scanners', 'vuln,misconfig', '--severity', $sevs, '--exit-code', '1', '--format', 'json', '--output', $out, $WS)
            $shown = 'trivy fs --severity ' + $sevs + ' --exit-code 1'
            if ($rc -eq 0) { Add-Check 'QG-IMAGE' 'image-scan' '' '' 'pass' 'none' $shown $rc ('trivy: no findings at ' + $sevs) 'infrastructure-implementer' (Get-Rel $out) }
            elseif (($rc -eq 1) -and (Test-Path -LiteralPath $out)) {
                $n = ([regex]::Matches([IO.File]::ReadAllText($out), '"Severity"\s*:\s*"[A-Z]+"')).Count
                Add-Check 'QG-IMAGE' 'image-scan' '' '' 'fail' 'error' $shown $rc ('trivy: ' + $n + ' finding(s) at ' + $sevs) 'infrastructure-implementer' (Get-Rel $out)
            } else { Add-Check 'QG-IMAGE' 'image-scan' '' '' 'deferred' 'warning' $shown $rc ('trivy fs exited ' + $rc + ' without a report (a tool error or an unreachable database, not a finding); deferred (not a pass)') 'human' (Get-Rel $script:LastLog) }
        } else { Add-Deferred 'QG-IMAGE' 'image-scan' '' '' 'trivy' 'image/fs scan' }
        Invoke-ImageBuiltCheck $true
    }
}

# ------------------------------------------------------------------ run
if ((-not $ScopeGiven) -and (-not $Fast) -and $Spec) {
    $planScope = Get-PlanScope $SpecDir
    if ($planScope) {
        $Scope = $planScope; $scopeList = @($Scope -split ','); $ScopeSource = 'plan.md Gates coverage'
        $notc = @(); foreach ($n in @('lock', 'build', 'lint', 'test', 'coverage', 'secrets', 'deps', 'sast', 'static', 'sbom', 'image')) { if (-not (Test-InScope $n)) { $notc += $n } }
        $notMsg = ''; if ($notc.Count -gt 0) { $notMsg = '; not covered by the plan (the architecture decides the gates): ' + ($notc -join ', ') }
        Add-Check 'QG-SCOPE' 'gate-scope' '' '' 'pass' 'none' '' $null ('scope from ' + (Get-Rel $SpecDir) + '/plan.md -> ## Gates coverage: ' + $Scope + $notMsg) 'architect' (Get-Rel (Join-Path $SpecDir 'plan.md'))
    }
}
$Projects = New-Object System.Collections.ArrayList
$StacksOut = New-Object System.Collections.ArrayList
if (-not $Fast) {
    $Projects = Get-Projects
    $needStacks = (Test-InScope 'lock') -or (Test-InScope 'build') -or (Test-InScope 'lint') -or (Test-InScope 'test') -or (Test-InScope 'coverage') -or (Test-InScope 'deps')
    if ($needStacks) {
        if ($Projects.Count -eq 0) {
            Add-Check 'QG-STACK' 'stack-detection' '' '' 'skipped' 'warning' '' $null ('no stack markers found in ' + (Get-Rel $WS)) 'implementer' (Get-Rel $WS)
        } else {
            $names = @()
            foreach ($p in $Projects) { $names += $p.stack }
            Add-Check 'QG-STACK' 'stack-detection' '' '' 'pass' 'none' '' $null ('detected: ' + ($names -join ', ')) 'implementer' (Get-Rel $WS)
        }
        foreach ($ds in (Get-DialectStacks)) {
            $has = $false
            foreach ($p in $Projects) { if ($p.stack -eq $ds.stack) { $has = $true } }
            if (-not $has) {
                $ev = $WS
                if ($SpecDir) { $ev = $SpecDir }
                Add-Check 'QG-STACK' 'stack-detection' $ds.stack '' 'fail' 'warning' '' $null ('dialect ' + $ds.dialect + ' selected but no ' + $ds.stack + ' project markers found') 'implementer' (Get-Rel $ev)
            }
        }
    }
    $idx = 0
    foreach ($p in $Projects) {
        $idx++
        $proj = Get-Rel $p.dir
        [void]$StacksOut.Add([ordered]@{ stack = $p.stack; dir = $proj })
        Test-Lock $p.stack $proj $p.dir
        if ((Test-InScope 'build') -or (Test-InScope 'lint') -or (Test-InScope 'test') -or (Test-InScope 'coverage')) {
            switch ($p.stack) {
                'node' { Invoke-StackNode $proj $p.dir $idx }
                'python' { Invoke-StackPython $proj $p.dir $idx }
                'dotnet' { Invoke-StackDotnet $proj $p.dir $idx }
                'go' { Invoke-StackGo $proj $p.dir $idx }
                'rust' { Invoke-StackRust $proj $p.dir $idx }
                'java' { Invoke-StackJava $proj $p.dir $idx }
                'cpp' { Invoke-StackCpp $proj $p.dir $idx }
                'php' { Invoke-StackPhp $proj $p.dir $idx }
            }
        }
    }
}
Invoke-SecretsCheck
if (-not $Fast) {
    Invoke-DepsCheck $Projects
    Invoke-SastCheck
    Invoke-StaticCheck
    Invoke-ContainerChecks
}

# ------------------------------------------------------------------ summarize
$Errors = 0; $Warnings = 0; $Deferred = 0
foreach ($c in $Checks) {
    if ($c.severity -eq 'error') { $Errors++ }
    elseif ($c.severity -eq 'warning') { $Warnings++ }
    if ($c.status -eq 'deferred') { $Deferred++ }
}
$Status = 'pass'; $ExitCode = 0
if ($Errors -gt 0) { $Status = 'fail'; $ExitCode = 1 }
elseif ($Deferred -gt 0) { $Status = 'deferred'; $ExitCode = 3 }

$hint = $null
if ($Missing.Count -gt 0) {
    $hint = [ordered]@{
        powershell = 'powershell -ExecutionPolicy Bypass -File .KCC\tools\toolchain-preflight.ps1 -Tools ' + ($Missing -join ',')
        bash = 'bash .KCC/tools/toolchain-preflight.sh ' + ($Missing -join ' ')
        note = 'human-gated: run only after approval via the toolchain-preflight gate'
    }
}
$mode = 'full'
if ($Fast) { $mode = 'fast' }
$scopeOut = $Scope
if ($Fast) { $scopeOut = 'fast' }

$reportJson = $null; $reportMd = $null
if ($OutDir) { $reportJson = Join-Path $OutDir 'quality-gate.json'; $reportMd = Join-Path $OutDir 'quality-gate.md' }
$dropArt = ((-not $OutDir) -and ($ExitCode -eq 0) -and ($env:KCC_QG_KEEP_ARTIFACTS -ne '1'))

$violations = New-Object System.Collections.ArrayList
foreach ($c in $Checks) {
    if (($c.severity -ne 'error') -and ($c.severity -ne 'warning')) { continue }
    $file = $c.project
    if (-not $file) { $file = $c.evidence }
    $msg = $c.message
    if ($c.stack) { $msg = '[' + $c.stack + '] ' + $msg }
    [void]$violations.Add([ordered]@{ id = $c.id; severity = $c.severity; fix_owner = $c.fix_owner; file = $file; message = $msg })
}
$ideaOut = $null
if ($IdeaId) { $ideaOut = 'IDEA-' + $IdeaId }
$specOut = $null
if ($Spec) { $specOut = $Spec }
$artOut = $null
if (-not $dropArt) { $artOut = ($Art -replace '\\', '/') }
$reportOut = $null
if ($reportJson) { $reportOut = [ordered]@{ json = (Get-Rel $reportJson); md = (Get-Rel $reportMd) } }

$doc = [ordered]@{
    tool = 'quality-gate'; version = $Version; scope = $scopeOut; scope_source = $ScopeSource; mode = $mode; spec = $specOut; idea = $ideaOut
    workspace = (Get-Rel $WS); require = [bool]$Require; coverage_min_pct = $CovMin; coverage_min_source = $CovSrc
    errors = $Errors; warnings = $Warnings; deferred = $Deferred; status = $Status; exit_code = $ExitCode
    stacks = @($StacksOut); checks = @($Checks); violations = @($violations); missing_tools = @($Missing)
    install_hint = $hint; artifacts = $artOut; report = $reportOut
}
$jsonText = ConvertTo-Json -InputObject $doc -Depth 8 -Compress
$utf8 = New-Object System.Text.UTF8Encoding($false)

if ($OutDir) {
    if (-not (Test-Path -LiteralPath $OutDir)) { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }
    [IO.File]::WriteAllText($reportJson, ($jsonText + "`n"), $utf8)
    $md = New-Object System.Text.StringBuilder
    [void]$md.Append("---`ntitle: `"Quality Gate $Spec`"`ntags:`n  - kcc/quality-gate`nstatus: $Status`n---`n`n")
    [void]$md.Append("# Quality Gate - $Spec (IDEA-$IdeaId)`n`n")
    $req = ''
    if ($Require) { $req = ', require' }
    [void]$md.Append("- Status: **$Status** (exit $ExitCode)`n- Workspace: ``" + (Get-Rel $WS) + "```n- Mode: $mode$req`n- Coverage minimum: $CovMin% ($CovSrc)`n- Errors: $Errors  Warnings: $Warnings  Deferred: $Deferred`n`n")
    [void]$md.Append("| Check | Stack | Project | Status | Command | Exit | Message | Evidence |`n|--|--|--|--|--|--|--|--|`n")
    foreach ($c in $Checks) {
        $st = '-'; if ($c.stack) { $st = $c.stack }
        $pj = '-'; if ($c.project) { $pj = $c.project }
        $cm = '-'; if ($c.command) { $cm = ($c.command -replace '\|', '\|') }
        $ex = '-'; if ($null -ne $c.exit_code) { $ex = [string]$c.exit_code }
        $ev = '-'; if ($c.evidence) { $ev = $c.evidence }
        [void]$md.Append('| ' + $c.id + ' | ' + $st + ' | ' + $pj + ' | ' + $c.status + ' | `' + $cm + '` | ' + $ex + ' | ' + ($c.message -replace '\|', '\|') + ' | ' + $ev + " |`n")
    }
    if ($hint) {
        [void]$md.Append("`n## Missing tools (deferred - NOT a pass)`n`nApprove through the toolchain-preflight gate, then re-run:`n`n``````powershell`n" + $hint.powershell + "`n```````n`n``````bash`n" + $hint.bash + "`n```````n")
    }
    [IO.File]::WriteAllText($reportMd, $md.ToString(), $utf8)
}

if ($Emit) {
    $payload = [ordered]@{ status = $Status; errors = $Errors; warnings = $Warnings; deferred = $Deferred; mode = $mode; missing_tools = ($Missing -join ','); report = $null }
    if ($reportJson) { $payload.report = (Get-Rel $reportJson) }
    try {
        $bc = Join-Path $PSScriptRoot 'backchannel-append.ps1'
        $bcArgs = @{ Kind = 'quality-gate-result'; From = 'quality-gate'; Payload = (ConvertTo-Json -InputObject $payload -Compress); RepoRoot = $RepoRoot }
        if ($Spec) { $bcArgs['Spec'] = $Spec }
        & $bc @bcArgs | Out-Null
    } catch { [Console]::Error.WriteLine('warning: backchannel emit failed: ' + $_.Exception.Message) }
}

if ($Json) {
    [Console]::Out.WriteLine($jsonText)
} else {
    foreach ($c in $Checks) {
        $where = ''
        if ($c.stack) { $where = ' [' + $c.stack; if ($c.project) { $where += ' ' + $c.project }; $where += ']' }
        $extra = ''
        if ($c.command) { $rcShown = '?'; if ($null -ne $c.exit_code) { $rcShown = [string]$c.exit_code }; $extra = ' (' + $c.command + ' -> exit ' + $rcShown + ')' }
        Write-Output (('{0,-8} {1,-10}' -f $c.status.ToUpperInvariant(), $c.id) + $where + ' ' + $c.message + $extra)
    }
    if ($hint) {
        Write-Output 'Missing tools (human-gated install; not run by this tool):'
        Write-Output ('  ' + $hint.powershell)
        Write-Output ('  ' + $hint.bash)
    }
    if ($reportMd) { Write-Output ('Report: ' + (Get-Rel $reportMd)) }
    Write-Output ('Errors: ' + $Errors + '  Warnings: ' + $Warnings)
    Write-Output ('Status: ' + $Status + ' (exit ' + $ExitCode + ')')
}

if ($dropArt) { Remove-Item -LiteralPath $Art -Recurse -Force -ErrorAction SilentlyContinue }
exit $ExitCode
