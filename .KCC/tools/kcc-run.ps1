<#
KCC framework (c) 2026 Tarek Fawaz, https://tikasway.dev/kcc. Licensed under the terms in LICENSE.

.SYNOPSIS
    kcc-run: deterministic, harness-neutral driver for the KCC `auto` lifecycle.

.DESCRIPTION
    Executes the state table in .KCC/kernel/auto-states.json (source of truth)
    one state at a time: runs each state's command through the configured
    harness NON-interactively (settings.json continuity.start[harness]), then
    decides NEXT / PAUSE / STOP from the state's exit-check script, never from
    the agent's own word. Run state lives in coordination/run/run.json, gates in
    coordination/gates/GATE-NNN.md, harness logs in coordination/run/logs/.
    Protocol: .KCC/kernel/protocols/kcc-run.md.

    -Until <id> stops after that state has finished for every spec and wave (status 'stopped',
    reason 'until <id>'; a later -Resume continues). Used to hand the per-spec states to `kcc lanes`.

    Exit codes: 0 done (or dry-run / -Only / -Until finished), 2 usage or environment
    error, 4 paused at a human gate, 5 suspended (usage limit; restore point
    written and kcc-limit-watch armed), 6 stopped or aborted.

    PowerShell 5.1 compatible, ASCII-only source. No python/jq.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .KCC\tools\kcc-run.ps1 -Input "build a login page" -Silent -Assume

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .KCC\tools\kcc-run.ps1 -Answer approve
#>
[CmdletBinding()]
param(
    [Alias('Input')][string]$InputText,
    [switch]$Silent,
    [switch]$Assume,
    [string]$Accuracy,
    [string]$Budget,
    [string]$Currency,
    [switch]$Parallel,
    [switch]$Fasttrack,
    [switch]$OpenDashboard,
    [switch]$NoOpenDashboard,
    [string]$DepthLevel,
    [string]$Harness,
    [switch]$Resume,
    [string]$Answer,
    [string]$From,
    [string]$Only,
    [string]$Until,
    [switch]$DryRun,
    [switch]$Json,
    [int]$MaxAttempts = 0,
    [string]$RepoRoot,
    [string]$RemoteUrl,
    [string]$Note
)

$ErrorActionPreference = 'Stop'
$ToolVersion = '1.0.0'
$Utf8 = New-Object System.Text.UTF8Encoding($false)
$psExe = (Get-Process -Id $PID).Path
$onWindows = ($env:OS -eq 'Windows_NT')

function Say([string]$m) { if ($Json) { [Console]::Error.WriteLine($m) } else { [Console]::Out.WriteLine($m) } }
function Fail-Usage([string]$m) { [Console]::Error.WriteLine('kcc-run: ' + $m); exit 2 }
function Iso { return [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ') }
function Str($v) { if ($null -eq $v) { return '' } return [string]$v }
function Write-Lf([string]$path, [string]$text) {
    $d = Split-Path -Parent $path
    if ($d -and -not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
    [System.IO.File]::WriteAllText($path, ($text -replace "`r`n", "`n"), $Utf8)
}
function Append-Lf([string]$path, [string]$text) { [System.IO.File]::AppendAllText($path, ($text -replace "`r`n", "`n"), $Utf8) }

# ---- arguments ---------------------------------------------------------------------
if ($Silent -xor $Assume) { Fail-Usage '--silent and --assume must be used together' }
if ($Accuracy) { $Accuracy = $Accuracy.TrimEnd('%'); if ($Accuracy -notmatch '^\d{1,3}$') { Fail-Usage '-Accuracy must be a percentage (e.g. 95)' } }
if ($Budget -and $Budget -notmatch '^\d+(\.\d+)?$') { Fail-Usage '-Budget must be a number' }
if ($DepthLevel -and $DepthLevel -notmatch '^[1-5]$') { Fail-Usage '-DepthLevel must be 1-5' }
if ($Harness -and (@('claude', 'codex', 'opencode', 'generic') -notcontains $Harness)) { Fail-Usage '-Harness must be claude|codex|opencode|generic' }
if ($From -and $From -notmatch '^\d+$') { Fail-Usage '-From must be a state id' }
if ($Only -and $Only -notmatch '^\d+$') { Fail-Usage '-Only must be a state id' }
if ($Until -and $Until -notmatch '^\d+$') { Fail-Usage '-Until must be a state id' }
if ($MaxAttempts -lt 0) { Fail-Usage '-MaxAttempts must be >= 1' }

if (-not $RepoRoot) {
    $toolDir = $PSScriptRoot
    if (-not $toolDir) { $toolDir = Split-Path -Parent $MyInvocation.MyCommand.Path }
    $RepoRoot = Split-Path -Parent (Split-Path -Parent $toolDir)
}
if (-not (Test-Path -LiteralPath $RepoRoot -PathType Container)) { Fail-Usage "workspace not found: $RepoRoot" }
$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path.TrimEnd('\', '/')
$KccDir = Join-Path $RepoRoot '.KCC'
$ToolsDir = Join-Path $KccDir 'tools'
$StatesPath = Join-Path $KccDir 'kernel\auto-states.json'
if (-not (Test-Path -LiteralPath $StatesPath)) { Fail-Usage "state table not found: $StatesPath" }
$Coord = Join-Path $RepoRoot 'coordination'
$RunDir = Join-Path $Coord 'run'
$RunFile = Join-Path $RunDir 'run.json'
$LogDir = Join-Path $RunDir 'logs'
$GateDir = Join-Path $Coord 'gates'
# --fasttrack has its own lifecycle table (a running app first, no ROI/CONFIRM/ARCH-GATE/BUDGET/WINDOWS states);
# a resumed fast-track run keeps it.
$ftStates = Join-Path $KccDir 'kernel\auto-states-fasttrack.json'
$useFt = [bool]$Fasttrack
if (-not $useFt -and (Test-Path -LiteralPath $RunFile)) { try { $useFt = ((Get-Content -LiteralPath $RunFile -Raw) -match '"fasttrack"\s*:\s*"1"') } catch { } }
if ($useFt -and (Test-Path -LiteralPath $ftStates)) { $StatesPath = $ftStates }

try { $SM = Get-Content -LiteralPath $StatesPath -Raw | ConvertFrom-Json } catch { Fail-Usage "cannot parse $StatesPath" }
$States = @($SM.states)
$GateTable = $SM.gates

$Settings = $null
$settingsPath = Join-Path $KccDir 'settings.json'
if (Test-Path -LiteralPath $settingsPath) { try { $Settings = Get-Content -LiteralPath $settingsPath -Raw | ConvertFrom-Json } catch { $Settings = $null } }
function Get-Setting([string[]]$pathParts, $default) {
    $o = $Settings
    foreach ($p in $pathParts) {
        if ($null -eq $o) { return $default }
        if ($o.PSObject.Properties.Name -contains $p) { $o = $o.$p } else { return $default }
    }
    if ($null -eq $o) { return $default }
    return $o
}
$cfgMax = [int](Get-Setting @('run', 'max_attempts') (Str $SM.max_attempts))
if ($cfgMax -lt 1) { $cfgMax = 3 }
if ($MaxAttempts -gt 0) { $cfgMax = $MaxAttempts }
$cfgTimeoutMin = [int](Get-Setting @('run', 'state_timeout_minutes') 60)
if ($cfgTimeoutMin -lt 1) { $cfgTimeoutMin = 60 }

# ---- state table helpers -----------------------------------------------------------
function Get-Idx([int]$id) { for ($i = 0; $i -lt $States.Count; $i++) { if ([int]$States[$i].id -eq $id) { return $i } }; return -1 }
function Has($o, [string]$n) { return ($null -ne $o -and $o.PSObject.Properties.Name -contains $n -and $null -ne $o.$n) }
$SpecFirst = -1; $SpecLast = -1
for ($i = 0; $i -lt $States.Count; $i++) { if ($States[$i].scope -ne 'run') { if ($SpecFirst -lt 0) { $SpecFirst = $i }; $SpecLast = $i } }
$ApprovalGates = @('confirm', 'budget', 'budget-cap', 'windows')

# ---- run.json ----------------------------------------------------------------------
$RunKeys = @('schema', 'status', 'reason', 'created', 'updated', 'harness', 'input', 'input_class', 'scenario', 'silent', 'assume',
    'accuracy', 'budget', 'currency', 'parallel', 'fasttrack', 'depthlevel', 'dashboard_opened', 'sequential', 'idea', 'ideas_before', 'specs', 'state', 'spec_index', 'wave',
    'attempts', 'force', 'pending_action', 'gate_id', 'gate_name', 'gate_kind', 'gate_answers', 'gate_state', 'gate_spec',
    'gate_wave', 'gate_event', 'last_log', 'last_violations', 'note', 'until')
function New-Run {
    $tr = [ordered]@{}
    foreach ($k in $RunKeys) { $tr[$k] = '' }
    $tr.schema = 'kcc-run/1'; $tr.status = 'running'; $tr.created = (Iso); $tr.scenario = 'S1'; $tr.silent = '0'; $tr.assume = '0'
    $tr.accuracy = '95'; $tr.currency = 'USD'; $tr.parallel = '0'; $tr.fasttrack = '0'; $tr.depthlevel = '5'; $tr.sequential = '0'; $tr.state = '0'; $tr.spec_index = '0'
    return $tr
}
function Load-Run {
    $tr = New-Run
    $o = Get-Content -LiteralPath $RunFile -Raw | ConvertFrom-Json
    foreach ($k in $RunKeys) { if ($o.PSObject.Properties.Name -contains $k) { $tr[$k] = Str $o.$k } }
    return $tr
}
function Esc([string]$s) {
    $sb = New-Object System.Text.StringBuilder
    foreach ($ch in $s.ToCharArray()) {
        $c = [int]$ch
        if ($ch -eq '\') { [void]$sb.Append('\\') }
        elseif ($ch -eq '"') { [void]$sb.Append('\"') }
        elseif ($c -eq 10) { [void]$sb.Append('\n') }
        elseif ($c -eq 9) { [void]$sb.Append('\t') }
        elseif ($c -lt 32) { }
        elseif ($c -gt 126) { [void]$sb.Append(('\u{0:x4}' -f $c)) }
        else { [void]$sb.Append($ch) }
    }
    return $sb.ToString()
}
function Save-Run {
    if ($DryRun) { return }
    $R.updated = (Iso)
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('{')
    for ($i = 0; $i -lt $RunKeys.Count; $i++) {
        $k = $RunKeys[$i]; $sep = ','; if ($i -eq $RunKeys.Count - 1) { $sep = '' }
        $lines.Add(('  "{0}": "{1}"{2}' -f $k, (Esc (Str $R[$k])), $sep))
    }
    $lines.Add('}')
    Write-Lf $RunFile (($lines -join "`n") + "`n")
}
function Get-Att([string]$key) {
    foreach ($p in ((Str $R.attempts) -split ';')) { $kv = $p -split '=', 2; if ($kv.Count -eq 2 -and $kv[0] -eq $key) { return [int]$kv[1] } }
    return 0
}
function Set-Att([string]$key, [int]$n) {
    $out = @()
    foreach ($p in ((Str $R.attempts) -split ';')) { if (-not $p) { continue }; $kv = $p -split '=', 2; if ($kv[0] -ne $key) { $out += $p } }
    if ($n -gt 0) { $out += ('{0}={1}' -f $key, $n) }
    $R.attempts = ($out -join ';')
}
function Test-Force([int]$id) { return ((' ' + (Str $R.force) + ' ') -match (' ' + $id + ' ')) }
function Add-Force([int]$id) { if (-not (Test-Force $id)) { $R.force = ((Str $R.force) + ' ' + $id).Trim() } }
function Clear-Force([int]$id) { $R.force = ((@((Str $R.force) -split ' ') | Where-Object { $_ -and $_ -ne [string]$id }) -join ' ') }

# ---- workspace discovery -----------------------------------------------------------
function Get-IdeaFolders {
    $d = Join-Path $RepoRoot 'ideation'
    if (-not (Test-Path -LiteralPath $d)) { return @() }
    return @(Get-ChildItem -LiteralPath $d -Directory | Where-Object { $_.Name -match '^IDEA-\d+' } | ForEach-Object { $_.Name } | Sort-Object)
}
function Get-IdeaNum([string]$n) { if ($n -match '^IDEA-(\d+)') { return [int]$Matches[1] }; return 0 }
function Get-SpecId([string]$folder) { if ($folder -match '^(SPEC-\d+)') { return $Matches[1] }; if ($folder -match '^(SPEC-[0-9A-Za-z]+)') { return $Matches[1] }; return $folder }
function Get-TableRows([string[]]$lines) {
    # returns list of string[] cell arrays for markdown table rows (separator rows skipped)
    $rows = New-Object System.Collections.ArrayList
    foreach ($l in $lines) {
        $t = $l.Trim()
        if (-not $t.StartsWith('|')) { continue }
        if ($t -match '^\|[\s\-:|]+\|?$') { continue }
        $cells = @($t.Trim('|').Split('|') | ForEach-Object { $_.Trim() })
        [void]$rows.Add([object]$cells)
    }
    return , $rows
}
function Get-Section([string[]]$lines, [string]$headRe) {
    $out = New-Object System.Collections.ArrayList
    $inside = $false
    foreach ($l in $lines) {
        if ($l -match '^##\s') { if ($inside) { break }; if ($l -match $headRe) { $inside = $true }; continue }
        if ($inside) { [void]$out.Add($l) }
    }
    return , ([string[]]$out.ToArray())
}
function Read-Lines([string]$p) { if (Test-Path -LiteralPath $p) { return , ([string[]][System.IO.File]::ReadAllLines($p)) }; return , ([string[]]@()) }
function Get-SpecsFromRoadmap([string]$idea) {
    $sdir = Join-Path $RepoRoot ('specs\' + $idea + '-Specs')
    if (-not (Test-Path -LiteralPath $sdir)) { return @() }
    $folders = @(Get-ChildItem -LiteralPath $sdir -Directory | Where-Object { $_.Name -match '^SPEC-' } | ForEach-Object { $_.Name } | Sort-Object)
    $rm = Join-Path $sdir 'ROADMAP.md'
    $ordered = New-Object System.Collections.ArrayList
    if (Test-Path -LiteralPath $rm) {
        $rows = Get-TableRows (Read-Lines $rm)
        $orderCol = -1; $n = 0
        $items = New-Object System.Collections.ArrayList
        foreach ($cells in $rows) {
            if ($orderCol -lt 0) {
                for ($c = 0; $c -lt $cells.Count; $c++) { if ($cells[$c] -match '^(?i)order$') { $orderCol = $c } }
                if ($orderCol -ge 0) { continue }
            }
            $rowText = $cells -join '|'
            $m = [regex]::Match($rowText, 'SPEC-[0-9A-Za-z]+')
            if (-not $m.Success) { continue }
            $sid = Get-SpecId $m.Value
            $folder = $folders | Where-Object { $_ -eq $sid -or $_.StartsWith($sid + '-') } | Select-Object -First 1
            if (-not $folder) { continue }
            $ord = 1000 + $n
            if ($orderCol -ge 0 -and $orderCol -lt $cells.Count -and $cells[$orderCol] -match '(\d+)') { $ord = [int]$Matches[1] }
            [void]$items.Add([pscustomobject]@{ ord = $ord; n = $n; f = $folder }); $n++
        }
        foreach ($it in @($items | Sort-Object ord, n)) { if (-not $ordered.Contains($it.f)) { [void]$ordered.Add($it.f) } }
    }
    if ($ordered.Count -eq 0) { foreach ($f in $folders) { [void]$ordered.Add($f) } }
    return @($ordered | ForEach-Object { $idea + '/' + $_ })
}
function Get-SpecDir([string]$entry) {
    $p = $entry -split '/', 2
    return (Join-Path $RepoRoot ('specs\' + $p[0] + '-Specs\' + $p[1]))
}
function Get-SpecStatus([string]$entry) {
    $p = $entry -split '/', 2
    $f = Join-Path (Get-SpecDir $entry) ($p[1] + '.md')
    $rows = Get-TableRows (Read-Lines $f)
    if ($rows.Count -lt 2) { return '' }
    $h = $rows[0]
    for ($c = 0; $c -lt $h.Count; $c++) { if ($h[$c] -match '^(?i)status$' -and $c -lt $rows[1].Count) { return $rows[1][$c] } }
    return ''
}
function Get-Waves([string]$entry) {
    $dir = Get-SpecDir $entry
    $sec = Get-Section (Read-Lines (Join-Path $dir 'plan.md')) '^##\s+(?i)waves?\b'
    if ($sec.Count -eq 0) {
        $par = Read-Lines (Join-Path $dir 'parallelization.md')
        $sec = Get-Section $par '^##\s+(?i).*waves?'
        if ($sec.Count -eq 0) { $sec = $par }
    }
    $waves = New-Object System.Collections.ArrayList
    foreach ($cells in (Get-TableRows $sec)) {
        if ($cells.Count -gt 0 -and $cells[0] -match '^(?i)(wave\s*)?(\d+)$') { $w = [string][int]$Matches[2]; if (-not $waves.Contains($w)) { [void]$waves.Add($w) } }
    }
    return @($waves)
}
function Get-SpecEntries { return , @((Str $R.specs) -split ' ' | Where-Object { $_ }) }  # the comma keeps a single spec an array (indexing a lone string yields its first character)
function Get-DerivedTools([string]$entry) {
    $text = ''
    $parts = $entry -split '/', 2
    foreach ($f in @((Join-Path (Get-SpecDir $entry) ($parts[1] + '.md')), (Join-Path (Get-SpecDir $entry) 'plan.md'), (Join-Path $RepoRoot ('ideation\' + $parts[0] + '\TechnicalDecisionBrief.md')))) {
        if (Test-Path -LiteralPath $f) { $text += [System.IO.File]::ReadAllText($f) + "`n" }
    }
    $t = $text.ToLowerInvariant()
    $tools = New-Object System.Collections.ArrayList
    $map = [ordered]@{ 'fullstack-nextjs|frontend-react|backend-nodejs' = 'node,npm'; 'fullstack-python|backend-python' = 'python'; 'backend-go' = 'go'; 'backend-rust' = 'cargo';
        'backend-java' = 'java'; 'backend-dotnet|fullstack-dotnet' = 'dotnet'; 'flutter' = 'dart,flutter'; 'mobile-kotlin' = 'java'; 'mobile-swift' = 'swift'; 'backend-ruby' = 'ruby'; 'scripting-lua' = 'lua';
        'devops-cloud' = 'terraform'; 'devops-k8s-onprem-agnostic' = 'terraform,kubectl,helm'; '\bpnpm\b' = 'pnpm' }
    foreach ($k in $map.Keys) { if ($t -match $k) { foreach ($x in ($map[$k] -split ',')) { if (-not $tools.Contains($x)) { [void]$tools.Add($x) } } } }
    if (-not $tools.Contains('git')) { [void]$tools.Add('git') }
    # plan.md '## Toolchain' rows '| node | >=20 |' pin a major version: the preflight checks node@>=20.
    foreach ($l in (Get-Section (Read-Lines (Join-Path (Get-SpecDir $entry) 'plan.md')) '(?i)^##\s+toolchain')) {
        # Only tools the stack already needs get a version; a row like '| typescript | ^5.5 |' names a
        # package, not a command, and must not turn into a MISSING tool. The range is the cell's leading
        # constraint: '>=22 (LTS)' -> '>=22'.
        $c = @($l.Trim().Trim('|').Split('|') | ForEach-Object { $_.Trim().Trim('`') })
        if ($c.Count -lt 2) { continue }
        $i = $tools.IndexOf($c[0].ToLowerInvariant()); if ($i -lt 0) { continue }
        $m = [regex]::Match(($c[1] -replace '[\s`]', ''), '^(>=|<=|>|<|=)?\d+((>=|<=|>|<)\d+)?')
        if (-not $m.Success) { continue }
        $tools[$i] = $c[0].ToLowerInvariant() + '@' + $m.Value
    }
    return ($tools -join ',')
}

# ---- context + rendering -------------------------------------------------------------
function New-Ctx([string]$entry, [string]$wave) {
    $idea = Str $R.idea; $spec = ''; $specFolder = ''
    if ($entry) { $p = $entry -split '/', 2; $idea = $p[0]; $specFolder = $p[1]; $spec = Get-SpecId $p[1] }
    return @{ IDEA = $idea; SPEC = $spec; SPECFOLDER = $specFolder; ENTRY = $entry; WAVE = $wave }
}
function Render([string]$text, $ctx) {
    $sa = ''; if ($R.scenario -ne 'S1') { $sa = '--silent --assume' }
    $par = ''; if ($R.parallel -eq '1') { $par = '--parallel' }
    $ft = ''; if ($R.fasttrack -eq '1') { $ft = '--fasttrack' }
    $dl = ''; if ($R.depthlevel -match '^[1-4]$') { $dl = '--depthlevel ' + $R.depthlevel }
    $flags = (($sa + ' ' + $par + ' ' + $ft + ' ' + $dl).Trim())
    $tools = ''; if ($text.Contains('{TOOLS}') -and $ctx.ENTRY) { $tools = Get-DerivedTools $ctx.ENTRY }
    $o = $text.Replace('{input}', (Str $R.input)).Replace('{IDEA}', $ctx.IDEA).Replace('{SPEC}', $ctx.SPEC).Replace('{WAVE}', $ctx.WAVE)
    $o = $o.Replace('{ITEM}', '').Replace('{silent_assume}', $sa).Replace('{parallel}', $par).Replace('{fasttrack}', $ft).Replace('{depthlevel}', $dl).Replace('{flags}', $flags).Replace('{TOOLS}', $tools)
    return (($o -replace '\s{2,}', ' ').Trim())
}
# A state with precheck_requires only counts as already done when that artifact exists.
# Without it a vacuous exit check (no architecture/ or specs/ folder yet) would skip the work.
function Test-PrecheckReady($st, $ctx) {
    if (-not (Has $st 'precheck_requires')) { return $true }
    $rel = Render ([string]$st.precheck_requires) $ctx
    return (Test-Path -LiteralPath (Join-Path $RepoRoot ($rel -replace '/', [string][IO.Path]::DirectorySeparatorChar)))
}
function Get-StateCommand($st) {
    if ($R.fasttrack -eq '1' -and (Has $st 'command_fasttrack')) { return [string]$st.command_fasttrack }
    return [string]$st.command
}
function Get-SkipFlag($st) {
    if (-not (Has $st 'skip_if_flag')) { return '' }
    foreach ($f in @($st.skip_if_flag)) {
        if ($f -eq 'parallel' -and $R.parallel -eq '1') { return '--parallel' }
        if ($f -eq 'fasttrack' -and $R.fasttrack -eq '1') { return '--fasttrack' }
    }
    return ''
}
function Get-GateName($st) {
    if (-not (Has $st 'gate')) { return '' }
    $g = $st.gate; $n = ''
    if (Has $g $R.scenario) { $n = Str $g.($R.scenario) } elseif (Has $g 'all') { $n = Str $g.all }
    if ($n -eq 'none') { return '' }
    return $n
}
function Get-Answers([string]$gate) {
    if ($gate -eq 'interactive') { return @('done', 'abort') }
    if (Has $GateTable $gate) { return @($GateTable.$gate | ForEach-Object { [string]$_ }) }
    return @('proceed', 'abort')
}
function Unit-Label($st, $ctx) {
    $s = 'state ' + $st.id + ' ' + $st.name
    if ($ctx.SPEC) { $s += ' ' + $ctx.SPEC }
    if ($ctx.WAVE) { $s += ' wave ' + $ctx.WAVE }
    return $s
}
function Unit-Key($st, $ctx) { $k = [string]$st.id; if ($ctx.SPEC) { $k += ':' + $ctx.SPEC }; if ($ctx.WAVE) { $k += ':' + $ctx.WAVE }; return $k }
function QArg([string]$a) { if ($a -match '\s') { return '"' + $a + '"' }; return $a }
function Rel([string]$full) {
    if ($full.Length -le $RepoRoot.Length) { return $full }
    return (($full.Substring($RepoRoot.Length)).TrimStart('\', '/') -replace '\\', '/')
}
function Safe-Name([string]$s) { return ($s -replace '[^A-Za-z0-9_.-]', '_') }

# ---- tools ---------------------------------------------------------------------------
function Quote-Native([string]$a) {
    # PS 5.1 (and 7.x Legacy mode) neither quotes arguments that contain quotes nor escapes them.
    $legacy = $true
    if ($PSVersionTable.PSVersion.Major -ge 7) {
        $v = Get-Variable -Name PSNativeCommandArgumentPassing -ValueOnly -ErrorAction SilentlyContinue
        if ($v -and [string]$v -ne 'Legacy') { $legacy = $false }
    }
    if (-not $legacy) { return $a }
    if ($a -eq '') { return '""' }
    if ($a -notmatch '[\s"]') { return $a }
    $e = [regex]::Replace($a, '(\\*)"', { param($m) ($m.Groups[1].Value * 2) + '\"' })
    $e = [regex]::Replace($e, '(\\+)$', { param($m) $m.Groups[1].Value * 2 })
    return ('"' + $e + '"')
}
function Invoke-Tool([string]$tool, [string[]]$toolArgs, [string]$outFile) {
    $path = Join-Path $ToolsDir ($tool + '.ps1')
    if (-not (Test-Path -LiteralPath $path)) { return @{ rc = 2; text = "tool not found: $tool" } }
    $a = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $path) + @($toolArgs | ForEach-Object { Quote-Native $_ })
    if ($tool -ne 'toolchain-preflight') { $a += @('-RepoRoot', $RepoRoot) }
    $old = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    Push-Location -LiteralPath $RepoRoot
    $out = @()
    try { $out = @(& $psExe @a 2>$null | ForEach-Object { [string]$_ }); $rc = $LASTEXITCODE } catch { $rc = 2 } finally { Pop-Location; $ErrorActionPreference = $old }
    if ($null -eq $rc) { $rc = 0 }
    $text = ($out -join "`n")
    if ($outFile) { Write-Lf $outFile ($text + "`n") }
    return @{ rc = [int]$rc; text = $text }
}
function Parse-JsonText([string]$text) {
    $a = $text.IndexOf('{'); $b = $text.LastIndexOf('}')
    if ($a -lt 0 -or $b -le $a) { return $null }
    try { return ($text.Substring($a, $b - $a + 1) | ConvertFrom-Json) } catch { return $null }
}
# Best-effort dashboard refresh (a child process, so a failure can never stop the run).
function Refresh-Dashboard {
    if ($DryRun -or $env:KCC_SKIP_DASHBOARD -eq '1') { return }
    $b = Join-Path $ToolsDir 'build-dashboard.ps1'
    if (-not (Test-Path -LiteralPath $b)) { return }
    try { & $psExe -NoProfile -ExecutionPolicy Bypass -File $b -RepoRoot $RepoRoot *> $null } catch { }
}
# ---- dashboard: opened once per run, only with the human's permission -------------------
# Permission comes from -OpenDashboard / -NoOpenDashboard, else settings dashboard.auto_open
# (yes | no | ask). `ask` prompts on a console and records always/never; with no console
# (unattended, silent, or piped) nothing is opened and a hint is printed.
function Save-DashboardMode([string]$mode) {
    $sp = Join-Path $KccDir 'settings.json'
    if (-not (Test-Path -LiteralPath $sp)) { return }
    $t = [System.IO.File]::ReadAllText($sp)
    if ($t -match '"auto_open"\s*:\s*"[^"]*"') { $t = [regex]::Replace($t, '("auto_open"\s*:\s*")[^"]*(")', ('${1}' + $mode + '${2}')) }
    elseif ($t -match '"dashboard"\s*:\s*\{') { $t = [regex]::Replace($t, '("dashboard"\s*:\s*\{)', ('${1} "auto_open": "' + $mode + '",'), 1) }
    else { $t = [regex]::Replace($t, '\}\s*$', (",`n" + '  "dashboard": { "auto_open": "' + $mode + '" }' + "`n}")) }
    [System.IO.File]::WriteAllText($sp, $t, (New-Object System.Text.UTF8Encoding($false)))
}
function Resolve-DashboardOpen {
    if ($NoOpenDashboard) { return 'no' }
    if ($OpenDashboard) { return 'yes' }
    $mode = ([string](Get-Setting @('dashboard', 'auto_open') 'ask')).ToLowerInvariant()
    if ($mode -eq 'yes' -or $mode -eq 'no') { return $mode }
    $ans = $env:KCC_DASHBOARD_ANSWER   # automation hook: answers the prompt without a console
    # --silent means nobody answers prompts: a silent run never asks, even on a console (it hung a measured round).
    $console = [Environment]::UserInteractive -and -not [Console]::IsInputRedirected -and -not $Json -and -not $Silent
    if (-not $ans -and $console) {
        Write-Host 'kcc-run: open the live dashboard in your browser? It follows this run and reads only local files.'
        $ans = Read-Host '  [y]es now / [n]o / [a]lways / ne[v]er (saved in .KCC/settings.json -> dashboard.auto_open)'
    }
    if (-not $ans) { return 'ask' }
    switch -regex (([string]$ans).Trim().ToLowerInvariant()) {
        '^(y|yes|open)$' { return 'yes' }
        '^(a|always)$' { Save-DashboardMode 'yes'; return 'yes' }
        '^(v|never)$' { Save-DashboardMode 'no'; return 'no' }
        default { return 'no' }
    }
}
function Offer-Dashboard([bool]$isNew) {
    if ($DryRun -or $R.dashboard_opened) { return }
    $d = Resolve-DashboardOpen
    if ($d -eq 'no') { $R.dashboard_opened = 'declined'; return }
    if ($d -eq 'ask') {
        if ($isNew) { Say 'kcc-run: dashboard not opened (no permission recorded). Open it with: kcc run --open-dashboard, or set .KCC/settings.json -> dashboard.auto_open to "yes".' }
        return
    }
    $b = Join-Path $ToolsDir 'build-dashboard.ps1'
    if (-not (Test-Path -LiteralPath $b)) { return }
    try { & $psExe -NoProfile -ExecutionPolicy Bypass -File $b -RepoRoot $RepoRoot -Open *> $null; $R.dashboard_opened = '1'; Say 'kcc-run: dashboard opened (dashboard/index.html); it refreshes as the run progresses' } catch { Say 'kcc-run: could not open the dashboard' }
}
function Emit([string]$kind, [string]$spec, $payload, [switch]$Dashboard) {
    if ($DryRun) { return '' }
    $bc = Join-Path $ToolsDir 'backchannel-append.ps1'
    if (-not (Test-Path -LiteralPath $bc)) { return '' }
    $pj = ($payload | ConvertTo-Json -Compress -Depth 6)
    # In-process call: powershell.exe -File re-parses argv and mangles JSON that contains quotes and spaces.
    $text = ''
    $oldEap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    Push-Location -LiteralPath $RepoRoot
    try {
        if ($Dashboard) { $o = & $bc -Kind $kind -From 'kcc-run' -Spec $spec -Payload $pj -RepoRoot $RepoRoot 2>$null }
        else { $o = & $bc -Kind $kind -From 'kcc-run' -Spec $spec -Payload $pj -RepoRoot $RepoRoot -NoDashboard 2>$null }
        $text = (@($o) | ForEach-Object { [string]$_ }) -join "`n"
    } catch { Say ('kcc-run: warning: could not emit ' + $kind) } finally { Pop-Location; $ErrorActionPreference = $oldEap }
    $tr = @{ text = $text }
    $m = [regex]::Match($tr.text, '"id":"(BC-\d+)"')
    if ($m.Success) { return $m.Groups[1].Value }
    return ''
}
function Test-PassWhen([string]$expr, $obj) {
    if ($null -eq $obj) { return $false }
    foreach ($clause in ($expr -split '\|')) {
        $ok = $true
        foreach ($cond in ($clause -split '&')) {
            $m = [regex]::Match($cond.Trim(), '^([A-Za-z_]+)\s*(=|>|<)\s*(.*)$')
            if (-not $m.Success) { $ok = $false; break }
            $k = $m.Groups[1].Value; $op = $m.Groups[2].Value; $v = $m.Groups[3].Value.Trim()
            $actual = ''; if ($obj.PSObject.Properties.Name -contains $k) { $actual = Str $obj.$k }
            if ($op -eq '=') { if ($actual -ne $v) { $ok = $false; break } }
            else {
                $num = 0.0
                if (-not [double]::TryParse($actual, [ref]$num)) { $ok = $false; break }
                if ($op -eq '>' -and -not ($num -gt [double]$v)) { $ok = $false; break }
                if ($op -eq '<' -and -not ($num -lt [double]$v)) { $ok = $false; break }
            }
        }
        if ($ok) { return $true }
    }
    return $false
}
function Format-Violations($obj) {
    if ($null -eq $obj -or -not ($obj.PSObject.Properties.Name -contains 'violations')) { return '' }
    $parts = @()
    foreach ($v in @($obj.violations)) {
        if ($null -eq $v) { continue }
        if ((Str $v.severity) -eq 'warning') { continue }
        $parts += ('{0} ({1}): {2}' -f (Str $v.id), (Str $v.fix_owner), (Str $v.message))
    }
    return ($parts -join '; ')
}
function Check-Desc($chk, $ctx) {
    if ($null -eq $chk) { return '-' }
    $t = Str $chk.tool
    $s = $t
    if (Has $chk 'args') { $s += ' ' + ((@($chk.args) | ForEach-Object { Render ([string]$_) $ctx }) -join ' ') }
    if (Has $chk 'path') { $s += ' ' + (Render $chk.path $ctx) }
    if (Has $chk 'paths') { $s += ' ' + ((@($chk.paths) | ForEach-Object { Render ([string]$_) $ctx }) -join ',') + $(if ((Has $chk 'any') -and ([string]$chk.any -match '^(?i)true$')) { ' [any]' } else { '' }) }
    if (Has $chk 'pass_when') { $s += ' [pass_when ' + $chk.pass_when + ']' }
    if (Has $chk 'then') { $s += ' THEN ' + (Check-Desc $chk.then $ctx) }
    return $s
}
$script:LastHarnessRc = -1
function Run-Check($chk, $ctx, [string]$label) {
    $tool = Str $chk.tool
    if ($tool -eq 'internal:roi-confidence') {
        $f = Join-Path $RepoRoot ('ideation\' + $ctx.IDEA + '\ROI.md')
        $min = 60; if (Has $chk 'min_pct') { $min = [int]$chk.min_pct }
        $txt = ''; if ($ctx.IDEA -and (Test-Path -LiteralPath $f)) { $txt = [System.IO.File]::ReadAllText($f) }
        $m = [regex]::Match($txt, '(?i)ROI confidence[^0-9\r\n]*(\d{1,3})\s*%')
        if (-not $m.Success) { $m = [regex]::Match($txt, '(?i)confidence[^0-9\r\n]*(\d{1,3})\s*%') }
        if (-not $m.Success) { return @{ rc = 1; viol = ('ROI-001 (idea-interrogator): ROI confidence % not recorded in ideation/' + $ctx.IDEA + '/ROI.md'); value = '' } }
        $pct = [int]$m.Groups[1].Value
        if ($pct -ge $min) { return @{ rc = 0; viol = ''; value = [string]$pct } }
        return @{ rc = 1; viol = ('ROI-002 (human): ROI confidence ' + $pct + '% is below ' + $min + '%'); value = [string]$pct }
    }
    if ($tool -eq 'internal:review-verdict') {
        $rf = ''
        if ($ctx.ENTRY) { $rf = Join-Path (Get-SpecDir $ctx.ENTRY) 'review.md' }
        if (-not $rf -or -not (Test-Path -LiteralPath $rf)) { return @{ rc = 1; viol = ('REVIEW-001 (verifier): review.md not found for ' + $ctx.SPEC) } }
        $rtxt = [System.IO.File]::ReadAllText($rf)
        $v = ''
        $vm = [regex]::Match($rtxt, '(?im)^verdict\s*:\s*"?([A-Za-z_-]+)')
        if (-not $vm.Success) { $vm = [regex]::Match($rtxt, '(?i)\b(APPROVED|CHANGES[_-]NEEDED|TOOLCHAIN[_-]DEFERRED|BLOCKED)\b') }
        # The review template writes the verdict lower-case with hyphens (status/toolchain-deferred); read it the same as TOOLCHAIN_DEFERRED.
        if ($vm.Success) { $v = ($vm.Groups[1].Value.ToUpperInvariant() -replace '-', '_') }
        if ($v -eq 'APPROVED') { return @{ rc = 0; viol = '' } }
        if ($v -eq 'TOOLCHAIN_DEFERRED') { return @{ rc = 3; viol = 'REVIEW-003 (human): review verdict TOOLCHAIN_DEFERRED (a required scanner is missing); this is not a pass' } }
        if (-not $v) { $v = 'missing' }
        return @{ rc = 1; viol = ('REVIEW-002 (implementer): ' + $ctx.SPEC + ' review verdict is ' + $v + '; fix the open bugs and failing acceptance criteria listed in review.md, then re-review') }
    }
    if ($tool -eq 'internal:no-open-bugs') {
        # Bug items of the spec (Backlog/Bug-*.md) whose Status cell is open or fixing: the FIX state is done when none is left.
        $open = @()
        if ($ctx.ENTRY) {
            $bd = Join-Path (Get-SpecDir $ctx.ENTRY) 'Backlog'
            if (Test-Path -LiteralPath $bd) {
                foreach ($bf in @(Get-ChildItem -LiteralPath $bd -Filter 'Bug-*.md' -File -ErrorAction SilentlyContinue | Sort-Object Name)) {
                    $bl = [System.IO.File]::ReadAllLines($bf.FullName); $col = -1; $stv = ''
                    for ($bi = 0; $bi -lt $bl.Count - 2; $bi++) {
                        if ($bl[$bi] -match '^\|\s*Type\s*\|') {
                            $cells = @($bl[$bi].Trim().Trim('|') -split '\|' | ForEach-Object { $_.Trim().ToLowerInvariant() })
                            $col = [array]::IndexOf($cells, 'status')
                            if ($col -ge 0) { $vals = @($bl[$bi + 2].Trim().Trim('|') -split '\|' | ForEach-Object { $_.Trim().ToLowerInvariant() }); if ($vals.Count -gt $col) { $stv = $vals[$col] } }
                            break
                        }
                    }
                    if ($stv -eq 'open' -or $stv -eq 'fixing') { $open += ($bf.BaseName -replace '^(Bug-\d+).*$', '$1') }
                }
            }
        }
        if ($open.Count -eq 0) { return @{ rc = 0; viol = '' } }
        return @{ rc = 1; viol = ('BUG-OPEN (implementer): ' + $ctx.SPEC + ' still has open bug item(s) ' + ($open -join ', ') + '; fix each test-first and set its Status to fixed') }
    }
    if ($tool -eq 'internal:file-exists') {
        $rel = Render (Str $chk.path) $ctx
        if (Test-Path -LiteralPath (Join-Path $RepoRoot $rel)) { return @{ rc = 0; viol = '' } }
        return @{ rc = 1; viol = ('FILE-001 (agent): missing ' + $rel) }
    }
    if ($tool -eq 'internal:files-exist') {
        $paths = @(); if (Has $chk 'paths') { $paths = @(@($chk.paths) | ForEach-Object { Render ([string]$_) $ctx }) }
        if ($paths.Count -eq 0) { return @{ rc = 2; viol = 'FILE-000: internal:files-exist needs a paths list' } }
        $any = (Has $chk 'any') -and ([string]$chk.any -eq 'True' -or [string]$chk.any -eq 'true')
        $missing = @($paths | Where-Object { -not (Test-Path -LiteralPath (Join-Path $RepoRoot $_)) })
        if ($any) { if ($missing.Count -lt $paths.Count) { return @{ rc = 0; viol = '' } }; return @{ rc = 1; viol = ('FILE-002 (agent): none of ' + ($paths -join ', ') + ' exists') } }
        if ($missing.Count -eq 0) { return @{ rc = 0; viol = '' } }
        return @{ rc = 1; viol = ('FILE-001 (agent): missing ' + ($missing -join ', ')) }
    }
    if ($tool -eq 'internal:agent-report') {
        if ($script:LastHarnessRc -eq 0) { return @{ rc = 0; viol = '' } }
        return @{ rc = 1; viol = ('AGENT-001 (agent): harness exited ' + $script:LastHarnessRc + '; expected: ' + (Str $chk.expect)) }
    }
    $targs = @()
    if (Has $chk 'args') { $targs = @(@($chk.args) | ForEach-Object { Render ([string]$_) $ctx }) }
    if ($tool -ne 'toolchain-preflight' -and ($targs -notcontains '-Json')) { $targs += '-Json' }
    $outFile = Join-Path $LogDir ('check-' + (Safe-Name $label) + '-' + $tool + '.out')
    $tr = Invoke-Tool $tool $targs $outFile
    $obj = Parse-JsonText $tr.text
    $rc = $tr.rc
    if ((Has $chk 'pass_when') -and $rc -ne 2) { if (Test-PassWhen (Str $chk.pass_when) $obj) { $rc = 0 } elseif ($rc -eq 0) { $rc = 1 } }
    $viol = Format-Violations $obj
    if ($rc -ne 0 -and -not $viol) {
        $viol = ($tool + ' exited ' + $rc + ' (output: ' + (Rel $outFile) + ')')
        if ($null -ne $obj -and $tool -eq 'repo-bootstrap') { $viol = 'RB-GATE (human): git ' + (Str $obj.git) + ', commits ' + (Str $obj.commits) + ', decision ' + (Str $obj.decision) }
    }
    $res = @{ rc = $rc; viol = $viol; out = $outFile }
    if ($rc -eq 0 -and (Has $chk 'then')) { return (Run-Check $chk.then $ctx $label) }
    return $res
}

# ---- harness ---------------------------------------------------------------------------
$limitReBuiltin = 'usage limit|rate limit|rate-limit|ratelimit|limit reached|quota exceeded|exceeded your (current )?quota|too many requests|resource_exhausted|limit exceeded'
# kernel/limit-patterns.json is the shared table (kcc-run, kcc-limit-watch, and the kcc CLI); the built-in is the fallback.
function Get-LimitRe([string]$harness) {
    $f = Join-Path $RepoRoot '.KCC/kernel/limit-patterns.json'
    if (-not (Test-Path -LiteralPath $f)) { return $limitReBuiltin }
    try {
        $j = Get-Content -LiteralPath $f -Raw | ConvertFrom-Json
        $parts = @()
        foreach ($k in @('limit_regex.default', ('limit_regex.' + $harness))) { $p = $j.PSObject.Properties[$k]; if ($p -and $p.Value) { $parts += [string]$p.Value } }
        if ($parts.Count -gt 0) { return ($parts -join '|') }
    } catch { }
    return $limitReBuiltin
}
function Test-LimitHit([string[]]$lines, [int]$rc) {
    if ($rc -ne 0) {
        $t = (@($lines | Select-Object -Last 60) -join "`n").ToLowerInvariant()
        if ($t -match (Get-LimitRe $script:HarnessName)) { return $true }
        return ($t -match '(^|[^0-9])429([^0-9]|$)')
    }
    # Exit 0: the session finished its turn, so prose such as "rate-limit values are assumptions" is not
    # a limit. Only the harness's own limit notice on the final lines counts.
    $f = Join-Path $RepoRoot '.KCC/kernel/limit-patterns.json'
    $re = ''
    if (Test-Path -LiteralPath $f) { try { $p = (Get-Content -LiteralPath $f -Raw | ConvertFrom-Json).PSObject.Properties[('limit_regex.' + $script:HarnessName)]; if ($p) { $re = [string]$p.Value } } catch { } }
    if (-not $re) { return $false }
    $last = (@($lines | Where-Object { $_ -and $_.Trim() } | Select-Object -Last 3) -join "`n").ToLowerInvariant()
    return ($last -match $re)
}
function Get-ResetEpoch([string[]]$lines) {
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $tail = @($lines | Select-Object -Last 80)
    for ($i = $tail.Count - 1; $i -ge 0; $i--) {
        $orig = [string]$tail[$i]; $t = $orig.ToLowerInvariant()
        if ($t -match '\|(\d{10})') { return [int64]$Matches[1] }
        if ($t -match '"?resets?_?at"?[: =]+(\d{10})') { return [int64]$Matches[1] }
        if ($t -match 'retry-after:? *(\d+)') { return $now + [int64]$Matches[1] }
        if ($t -match '(again|retry|resets?|available|wait)[a-z ]* in ([0-9][0-9a-z .,]*)') {
            $s = $Matches[2]; $tot = 0.0
            foreach ($m in [regex]::Matches($s, '(\d+(?:\.\d+)?)\s*([a-z]+)')) {
                $num = [double]::Parse($m.Groups[1].Value, [System.Globalization.CultureInfo]::InvariantCulture); $u = $m.Groups[2].Value
                if ($u -match '^(h|hr|hrs|hour|hours)$') { $tot += $num * 3600 }
                elseif ($u -match '^(m|min|mins|minute|minutes)$') { $tot += $num * 60 }
                elseif ($u -match '^(s|sec|secs|second|seconds)$') { $tot += $num }
                elseif ($u -ne 'and') { break }
            }
            if ($tot -gt 0) { return $now + [int64]$tot }
        }
        $dm = [regex]::Match($orig, '\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}(:\d{2})?(Z|[+-]\d{2}:?\d{2})?')
        if ($dm.Success) {
            $d = [DateTimeOffset]::MinValue
            if ([DateTimeOffset]::TryParse($dm.Value, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AssumeUniversal, [ref]$d)) { return $d.ToUnixTimeSeconds() }
        }
    }
    return $null
}
function Test-Bypass([string]$c) {
    $l = $c.ToLowerInvariant()
    return ($l.Contains('dangerously-skip') -or $l.Contains('dangerously-bypass') -or $l.Contains('bypasspermissions') -or $l.Contains('--yolo') -or $l -match 'permission-mode\s+bypass')
}
function Sanitize-Prompt([string]$p) {
    $s = $p -replace "[`r`n`t]+", ' '
    $s = $s.Replace('"', "'").Replace('`', "'").Replace('$', '').Replace('%', ' pct').Replace('!', '.').Replace('\', '/')
    return (($s -replace '\s{2,}', ' ').Trim())
}
# ---- fasttrack worker states run AS the agent (`claude --agent`): no orchestrator session above them ----
# The orchestrator wrapper session cost more than the worker it spawned. The agent keeps its own model,
# effort, and tools. Complexity high (the planner marks security-sensitive items high) or a retry after a
# failed check runs the implementer on the `run.escalation_tier` model (balanced by default) of the active harness instead (the orchestrator complexity rule).
$script:HarnessExtra = ''
function Get-WaveComplexity([string]$entry, [string]$wave) {
    $rank = @{ 'low' = 1; 'medium' = 2; 'high' = 3; 'extra-high' = 4 }
    $best = ''
    $pf = Join-Path (Get-SpecDir $entry) 'plan.md'
    if (-not (Test-Path -LiteralPath $pf)) { return '' }
    $hdr = $null
    $plines = Read-Lines $pf
    foreach ($l in $plines) {
        if ($l -notmatch '^\s*\|') { if ($hdr) { break } else { continue } }
        $cells = @(($l.Trim().Trim('|') -split '\|') | ForEach-Object { $_.Trim() })
        if (-not $hdr) { $low = @($cells | ForEach-Object { $_.ToLowerInvariant() }); if (($low -contains 'complexity') -and ($low -contains 'wave')) { $hdr = $low }; continue }
        if ($l -match '^\s*\|[\s:|\-]+\|?\s*$') { continue }
        $wi = [array]::IndexOf($hdr, 'wave'); $ci = [array]::IndexOf($hdr, 'complexity')
        if ($cells.Count -gt [Math]::Max($wi, $ci) -and $cells[$wi] -eq $wave) {
            $c = $cells[$ci].ToLowerInvariant()
            if ($rank.ContainsKey($c) -and ($best -eq '' -or $rank[$c] -gt $rank[$best])) { $best = $c }
        }
    }
    return $best
}
# Full model IDs, never the bare aliases: `haiku` still resolves to Haiku 4.5 on some Claude Code builds, and 4.5 has no
# auto mode. An older settings.json that still says haiku/sonnet/opus is mapped to the pinned 5.5 IDs here.
function Resolve-ClaudeModel([string]$m) {
    switch -Regex ($m.ToLowerInvariant()) {
        '^haiku$'  { return 'claude-haiku-5-5' }
        '^sonnet$' { return 'claude-sonnet-5-5' }
        '^opus$'   { return 'claude-opus-5-5' }
        default    { return $m }
    }
}
# ---- harness profile and model registry: nothing below assumes a particular harness --------------------------
# kernel/harnesses.json says how each harness takes an agent, a model and an effort; kernel/models.json says which model each
# tier is on each harness (settings run.registry picks another column, e.g. 'ollama' behind the opencode harness).
$script:HarnessProfiles = $null; $script:ModelRegistry = $null
function Read-KernelJson([string]$name) {
    $f = Join-Path (Join-Path $KccDir 'kernel') $name
    if (Test-Path -LiteralPath $f) { try { return ([System.IO.File]::ReadAllText($f) | ConvertFrom-Json) } catch { } }
    return $null
}
function Get-HProfile([string]$key) {
    $v = Get-Setting @('harness_invoke', $script:HarnessName, $key) $null
    if ($null -ne $v) { return [string]$v }
    if ($null -eq $script:HarnessProfiles) { $script:HarnessProfiles = Read-KernelJson 'harnesses.json' }
    if ($script:HarnessProfiles -and $script:HarnessProfiles.harnesses) {
        $p = $script:HarnessProfiles.harnesses.PSObject.Properties[$script:HarnessName]
        if ($p -and $p.Value.PSObject.Properties[$key]) { return [string]$p.Value.$key }
    }
    return ''
}
function Get-HEffort([string]$e) {
    if (-not $e) { return '' }
    if ($null -eq $script:HarnessProfiles) { $script:HarnessProfiles = Read-KernelJson 'harnesses.json' }
    if ($script:HarnessProfiles -and $script:HarnessProfiles.harnesses) {
        $p = $script:HarnessProfiles.harnesses.PSObject.Properties[$script:HarnessName]
        if ($p -and $p.Value.PSObject.Properties['effort_map'] -and $p.Value.effort_map.PSObject.Properties[$e]) { return [string]$p.Value.effort_map.$e }
    }
    return $e
}
function Get-TierModel([string]$tier) {
    $reg = [string](Get-Setting @('run', 'registry') ''); if (-not $reg) { $reg = $script:HarnessName }
    if ($null -eq $script:ModelRegistry) { $script:ModelRegistry = Read-KernelJson 'models.json' }
    if (-not $script:ModelRegistry -or -not $script:ModelRegistry.harnesses) { return '' }
    $h = $script:ModelRegistry.harnesses.PSObject.Properties[$reg]
    if (-not $h) { return '' }
    $t = $h.Value.PSObject.Properties[$tier]
    if (-not $t -or -not $t.Value.PSObject.Properties['id']) { return '' }
    $prefix = ''; if ($h.Value.PSObject.Properties['_prefix']) { $prefix = [string]$h.Value._prefix }
    return ($prefix + [string]$t.Value.id)
}
# The model for the orchestrator wrapper or the escalation: an explicit run.<kind>_model wins, except that a Claude id is
# never passed to another harness; otherwise the tier (run.<kind>_tier) on the active harness's registry column.
function Get-RunModel([string]$kind, [string]$defaultTier) {
    $explicit = (([string](Get-Setting @('run', ($kind + '_model')) '')) -replace '[^A-Za-z0-9._:/-]', '')
    if ($explicit -and ($script:HarnessName -eq 'claude' -or $explicit -notmatch '^(claude-|opus$|sonnet$|haiku$)')) {
        if ($script:HarnessName -eq 'claude') { return (Resolve-ClaudeModel $explicit) }
        return $explicit
    }
    $tier = ([string](Get-Setting @('run', ($kind + '_tier')) $defaultTier)) -replace '[^a-z]', ''
    return (Get-TierModel $tier)
}
# Every dispatch, in every cycle, asks the router (`.KCC/tools/kcc-route`, the port of cli/src/run/router.ts) which tier,
# model and effort the state's agent gets: from the agent's profile, the plan's Complexity and files for this wave or spec,
# the idea's domain, CR-7 words and the attempt. One rulebook (kernel/protocols/model-routing.md), three identical copies.
function Get-Route([string]$agent, $ctx, [int]$attempt) {
    if (-not $agent) { return $null }
    $a = @('-Agent', $agent, '-Attempt', [string]$attempt, '-Harness', $script:HarnessName)
    if ($ctx.SPEC) { $a += @('-Spec', $ctx.SPEC) }
    if ($ctx.WAVE) { $a += @('-Wave', $ctx.WAVE) }
    $r = Invoke-Tool 'kcc-route' $a ''
    if ($r.rc -ne 0) { return $null }
    $line = @(($r.text -split "`n") | Where-Object { $_ -match "`t" })
    if ($line.Count -eq 0) { return $null }
    $f = $line[-1] -split "`t"
    if ($f.Count -lt 3) { return $null }
    return @{ tier = $f[0]; model = $f[1]; effort = $f[2]; why = $(if ($f.Count -gt 3) { $f[3] } else { '' }); items = $(if ($f.Count -gt 4) { $f[4] } else { '' }) }
}
function Get-AgentMode($st, $ctx, [int]$att) {
    # The state's agent (the table's agent_fasttrack) is routed in every cycle. Under --fasttrack, when the harness can select an
    # agent and run.fasttrack_direct is not false, the state runs AS that agent with the routed model and effort; otherwise an
    # orchestrator session runs the state (on the fast tier, low effort under fast track; the harness default in a full run) and is
    # told which tier, model and effort to spawn the agent on.
    $agent = ''; if (Has $st 'agent_fasttrack') { $agent = [string]$st.agent_fasttrack }
    $model = ''; $why = ''; $effort = ''; $tier = ''; $source = ''
    $route = Get-Route $agent $ctx ($att + 1)
    if ($route) { $tier = $route.tier; $model = $route.model; $effort = $route.effort; $why = $route.why; $source = 'kcc-route' }
    $fast = ($R.fasttrack -eq '1')
    # Direct needs fast track, a harness that selects an agent by flag, and an agent file in that harness's agent folder.
    $agentDir = Get-HProfile 'agent_dir'
    $direct = $fast -and (([string](Get-Setting @('run', 'fasttrack_direct') 'true')).ToLowerInvariant() -ne 'false') -and $agent -and (Get-HProfile 'agent') -and $agentDir -and (Test-Path -LiteralPath (Join-Path $RepoRoot ($agentDir + '/' + $agent + '.md')))
    $wm = ''; $we = ''
    if ($fast) { $wm = Get-RunModel 'orchestrator' 'fast'; $we = ([string](Get-Setting @('run', 'orchestrator_effort') 'low')) -replace '[^a-z]', '' }
    $mode = 'wrapper'; if ($direct) { $mode = 'direct' }
    if (-not $agent -and -not $fast) { return $null }
    return @{ mode = $mode; agent = $agent; model = $model; effort = $effort; why = $why; source = $source; tier = $tier; wrapperModel = $wm; wrapperEffort = $we }
}
function Get-IdeaDomain([string]$idea) {
    # Research.md -> '## Domain' (common | specialised | novel), written by the idea-interrogator.
    if (-not $idea) { return '' }
    $f = Join-Path $RepoRoot ('ideation\' + $idea + '\Research.md')
    if (-not (Test-Path -LiteralPath $f)) { return '' }
    $t = [System.IO.File]::ReadAllText($f)
    $m = [regex]::Match($t, '(?is)##\s+Domain[^\n]*\n+\s*[-*]?\s*`?(common|specialised|specialized|novel)')
    if (-not $m.Success) { $m = [regex]::Match($t, '(?i)##\s+Domain\s*:\s*`?(common|specialised|specialized|novel)') }
    if (-not $m.Success) { return '' }
    $v = $m.Groups[1].Value.ToLowerInvariant(); if ($v -eq 'specialized') { $v = 'specialised' }
    return $v
}
function Format-HFlag([string]$tpl, [string]$key, [string]$value) {
    if (-not $tpl -or -not $value) { return '' }
    return $tpl.Replace('{' + $key + '}', $value)
}
# The flags that pick the agent, model and effort, written the way the active harness takes them (kernel/harnesses.json).
function Get-HarnessExtra($am) {
    if (-not $am) { return '' }
    $parts = @()
    if ($am.mode -eq 'direct') { $parts += (Format-HFlag (Get-HProfile 'agent') 'agent' $am.agent); $m = $am.model; $e = $am.effort }
    else { $m = $am.wrapperModel; $e = $am.wrapperEffort }
    $parts += (Format-HFlag (Get-HProfile 'model') 'model' $m)
    $parts += (Format-HFlag (Get-HProfile 'effort') 'effort' (Get-HEffort $e))
    return ((@($parts | Where-Object { $_ })) -join ' ')
}
function Convert-AgentBody([string]$body) {
    $m = [regex]::Match($body, '^/([a-z][a-z0-9-]*)\s*(.*)$')
    if (-not $m.Success) { return $body }
    $sp = Get-HProfile 'skill_path'; if (-not $sp) { $sp = '.claude/skills/{skill}/SKILL.md' }
    return ('Do the work of the skill described in ' + $sp.Replace('{skill}', $m.Groups[1].Value) + ' (read it first) with these arguments: ' + $m.Groups[2].Value)
}
function Get-HarnessCommand([string]$prompt) {
    $tpl = Str (Get-Setting @('continuity', 'start', $script:HarnessName) '')
    if (-not $tpl) { return $null }
    $ins = Get-HProfile 'insert_after'
    if ($script:HarnessExtra -and $ins) { $tpl = [regex]::Replace($tpl, ('(\s' + [regex]::Escape($ins) + ')(\s)'), ('$1 ' + $script:HarnessExtra + '$2'), 1) }
    $perm = (Str (Get-Setting @('continuity', 'permission_mode') 'auto')) -replace '[^A-Za-z]', ''
    if (-not $perm) { $perm = 'auto' }
    return $tpl.Replace('{resume_prompt}', (Sanitize-Prompt $prompt)).Replace('{permission_mode}', $perm).Replace('{session_id}', '')
}
function Invoke-Harness([string]$prompt, [string]$logFile) {
    $cmd = Get-HarnessCommand $prompt
    if (-not $cmd) { Stop-Run 'env' ('no continuity.start template for harness ' + $script:HarnessName + ' in .KCC/settings.json') 2 }
    if (Test-Bypass $cmd) { Stop-Run 'env' ('refusing a harness template with a permission-bypass flag: ' + $cmd) 2 }
    Write-Lf $logFile ('# kcc-run ' + (Iso) + ' harness ' + $script:HarnessName + "`n# " + $cmd + "`n")
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    if ($onWindows) {
        $psi.FileName = $env:ComSpec; if (-not $psi.FileName) { $psi.FileName = 'cmd.exe' }
        $psi.Arguments = '/d /s /c "' + $cmd + ' >> "' + $logFile + '" 2>&1 < NUL"'
    } else {
        $psi.FileName = '/bin/sh'
        $psi.Arguments = '-c "' + ($cmd + ' >> ''' + $logFile + ''' 2>&1 < /dev/null').Replace('"', '\"') + '"'
    }
    $psi.WorkingDirectory = $RepoRoot
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $proc = [System.Diagnostics.Process]::Start($psi)
    $rc = 0
    if (-not $proc.WaitForExit($cfgTimeoutMin * 60000)) {
        if ($onWindows) { & taskkill.exe /T /F /PID $proc.Id 2>$null | Out-Null } else { try { $proc.Kill() } catch { } }
        Append-Lf $logFile ("`n# kcc-run: harness timed out after $cfgTimeoutMin minute(s)`n")
        $rc = 124
    } else { $proc.WaitForExit(); $rc = $proc.ExitCode }
    $script:LastHarnessRc = $rc
    $script:LastHarnessLines = @(Read-Lines $logFile)
    $R.last_log = ($logFile.Substring($RepoRoot.Length).TrimStart('\', '/') -replace '\\', '/')
    return $rc
}

# ---- terminal / status output -------------------------------------------------------------
function Status-Object([string]$status) {
    $st = $null; $idx = Get-Idx ([int]$R.state); if ($idx -ge 0) { $st = $States[$idx] }
    $spec = ''; $entries = Get-SpecEntries
    if ($st -and $st.scope -ne 'run' -and [int]$R.spec_index -lt $entries.Count) { $spec = Get-SpecId (($entries[[int]$R.spec_index] -split '/', 2)[1]) }
    $gate = $null
    if ($R.gate_id) { $gate = [ordered]@{ id = $R.gate_id; name = $R.gate_name; answers = @($R.gate_answers -split '/'); file = ('coordination/gates/' + $R.gate_id + '.md') } }
    $name = ''; if ($st) { $name = [string]$st.name }
    return [ordered]@{ tool = 'kcc-run'; version = $ToolVersion; status = $status; scenario = $R.scenario; state = [int]$R.state; state_name = $name
        spec = $spec; wave = $R.wave; gate = $gate; log = $R.last_log; reason = $R.reason; run_file = 'coordination/run/run.json' }
}
function Finish([string]$status, [int]$code) {
    if ($Json) { Write-Output ((Status-Object $status) | ConvertTo-Json -Depth 5 -Compress) }
    exit $code
}
function Stop-Run([string]$kind, [string]$reason, [int]$code) {
    $R.reason = $reason
    if ($kind -eq 'aborted') { $R.status = 'aborted' } else { $R.status = 'stopped' }
    Save-Run
    [Console]::Error.WriteLine('kcc-run: ' + $R.status.ToUpper() + ' - ' + $reason)
    if ($code -ne 2) { [void](Emit 'session-closed' (Str $R.idea) ([ordered]@{ terminal = $R.status.ToUpper(); reason = $reason; state = [int]$R.state; source = 'kcc-run' })) }
    Finish $R.status $code
}

# ---- gates ---------------------------------------------------------------------------------
function Next-GateId {
    $max = 0
    if (Test-Path -LiteralPath $GateDir) { foreach ($f in Get-ChildItem -LiteralPath $GateDir -Filter 'GATE-*.md' -File) { if ($f.Name -match '^GATE-(\d+)\.md$') { $n = [int]$Matches[1]; if ($n -gt $max) { $max = $n } } } }
    return ('GATE-{0:D3}' -f ($max + 1))
}
function Show-Pause {
    $pol = 'accuracy ' + $R.accuracy + '%, budget ' + $(if ($R.budget) { $R.budget + ' ' + $R.currency } else { 'none' }) + ', parallel ' + $(if ($R.parallel -eq '1') { 'yes' } else { 'no' })
    Say ('kcc-run: PAUSED at state ' + $R.gate_state + $(if ($R.gate_spec) { ' ' + $R.gate_spec } else { '' }) + $(if ($R.gate_wave) { ' wave ' + $R.gate_wave } else { '' }) + ' - gate ' + $R.gate_name + ' (' + $R.gate_id + ')')
    Say ('  scenario: ' + $R.scenario + '  policy: ' + $pol)
    Say ('  gate file: coordination/gates/' + $R.gate_id + '.md')
    if ($R.last_log) { Say ('  last log: ' + $R.last_log) }
    if ($R.attempts) { Say ('  loop counters: ' + $R.attempts) }
    Say ('  allowed answers: ' + ($R.gate_answers -replace '/', ' | '))
    Say ('  answer with: kcc-run -Answer <choice>   (bash: kcc-run.sh --answer <choice>)')
}
function Open-Gate([string]$name, [string]$kind, [string]$question, $st, $ctx, [string]$extra) {
    $answers = Get-Answers $name
    $gid = Next-GateId
    $lines = @('---', "id: $gid", "gate: $name", "kind: $kind", ('state: ' + $st.id), ('state_name: ' + $st.name), ('spec: ' + $ctx.SPEC), ('wave: ' + $ctx.WAVE),
        ('scenario: ' + $R.scenario), 'status: open', ('allowed_answers: ' + ($answers -join ' / ')), ('created: ' + (Iso)), 'tags:', '  - kcc/gate', '---', '',
        "# $gid - $name", '', '## Question', '', $question, '', '## Allowed answers', '')
    foreach ($a in $answers) { $lines += ('- `' + $a + '`') }
    $lines += @('', '## Context', '', '- coordination/run/run.json')
    if ($R.last_log) { $lines += ('- ' + $R.last_log) }
    if ($ctx.IDEA) { $lines += ('- ideation/' + $ctx.IDEA + '/') }
    if ($ctx.ENTRY) { $lines += ('- ' + ((Get-SpecDir $ctx.ENTRY).Substring($RepoRoot.Length).TrimStart('\', '/') -replace '\\', '/') + '/') }
    if ($extra) { $lines += @('', '## Details', '', $extra) }
    $lines += @('', '## Answer', '', ('Run `kcc-run -Answer <choice>` (bash: `kcc-run.sh --answer <choice>`).'))
    Write-Lf (Join-Path $GateDir ($gid + '.md')) (($lines -join "`n") + "`n")
    $ev = Emit 'human-gate-triggered' $ctx.SPEC ([ordered]@{ gate = $name; gate_id = $gid; kind = $kind; state = [int]$st.id; state_name = [string]$st.name; wave = $ctx.WAVE; reason = $question; allowed_answers = $answers; gate_file = "coordination/gates/$gid.md"; source = 'kcc-run' }) -Dashboard
    $R.gate_id = $gid; $R.gate_name = $name; $R.gate_kind = $kind; $R.gate_answers = ($answers -join '/'); $R.gate_state = [string]$st.id
    $R.gate_spec = $ctx.SPEC; $R.gate_wave = $ctx.WAVE; $R.gate_event = $ev; $R.status = 'paused'
    Save-Run
    Show-Pause
    return (Prompt-Gate)
}
function Prompt-Gate {
    # A silent run has no human. The one gate it answers itself is a deferred quality check (a scanner that is not
    # installed): accepting it is recorded in the gate file, the decision event and closed.md, and is never a pass.
    # Every other gate pauses the run, and a silent run never waits on a console that nobody answers.
    if ($R.silent -eq '1') {
        if ($R.gate_name -eq 'quality-deferred-on-exit-3') {
            $script:Note = 'silent run: deferred quality check accepted by policy (not a pass); install the missing tool and re-run the gate to close it'
            Say ('kcc-run: ' + $script:Note)
            Apply-Answer 'accept-deferred'
            return 'answered'
        }
        return 'paused'
    }
    $tty = $false
    try { $tty = (-not [Console]::IsInputRedirected) -and (-not [Console]::IsOutputRedirected) -and [Environment]::UserInteractive } catch { $tty = $false }
    if ($Json -or -not $tty -or $env:KCC_RUN_NO_PROMPT -eq '1') { return 'paused' }
    $allowed = @($R.gate_answers -split '/')
    while ($true) {
        $a = (Read-Host ('answer [' + ($allowed -join '/') + ']')).Trim()
        if ($allowed -contains $a) { Apply-Answer $a; return 'answered' }
        Say ('  not an allowed answer: ' + $a)
    }
}
function Find-PrevCommandState([int]$idx) {
    for ($j = $idx - 1; $j -ge 0; $j--) { if (Has $States[$j] 'command') { return $j } }
    return $idx
}
function Apply-Answer([string]$ans) {
    if (-not $R.gate_id) { Fail-Usage 'no pending gate to answer' }
    $allowed = @($R.gate_answers -split '/')
    $match = $allowed | Where-Object { $_ -eq $ans.ToLowerInvariant() -or $_ -eq $ans } | Select-Object -First 1
    if (-not $match) { Fail-Usage ("'" + $ans + "' is not an allowed answer for gate " + $R.gate_name + ' (' + ($allowed -join ' | ') + ')') }
    $ans = [string]$match
    $gname = $R.gate_name; $gid = $R.gate_id
    $idx = Get-Idx ([int]$R.gate_state); $st = $States[$idx]
    $gf = Join-Path $GateDir ($gid + '.md')
    if (Test-Path -LiteralPath $gf) {
        $t = [System.IO.File]::ReadAllText($gf) -replace "`r`n", "`n"
        $t = $t -replace "(?m)^status: open$", ("status: answered`nanswer: " + $ans + "`nanswered: " + (Iso))
        $t += "`n## Decision`n`n- " + (Iso) + ': `' + $ans + '` (kcc-run)' + $(if ($Note) { ' - ' + $Note } else { '' }) + "`n"
        Write-Lf $gf $t
    }
    [void](Emit 'human-gate-decision' $R.gate_spec ([ordered]@{ gate = $gname; gate_id = $gid; answer = $ans; state = [int]$R.gate_state; wave = $R.gate_wave; trigger_event_id = $R.gate_event; note = (Str $Note); source = 'kcc-run' }) -Dashboard)
    $orch = Join-Path $Coord 'orchestrator.json'
    if (Test-Path -LiteralPath $orch) {
        $ot = [System.IO.File]::ReadAllText($orch)
        $m = [regex]::Match($ot, '"active_session"\s*:\s*"([^"]+)"')
        if ($m.Success) {
            $hd = Join-Path (Join-Path $RepoRoot $m.Groups[1].Value) 'HumanDecisions.md'
            if (Test-Path -LiteralPath $hd) { Append-Lf $hd ("`n- " + (Iso) + " kcc-run $gid gate ``$gname`` state " + $R.gate_state + ' ' + $R.gate_spec + ': **' + $ans + '**' + $(if ($Note) { ' - ' + $Note } else { '' }) + "`n") }
        }
    }
    if ($Note) { $R.note = $Note }
    $key = [string]$R.gate_state; if ($R.gate_spec) { $key += ':' + $R.gate_spec }; if ($R.gate_wave) { $key += ':' + $R.gate_wave }
    $pa = 'recheck'
    if ($ans -eq 'abort') { $pa = 'abort' }
    else {
        switch ($gname) {
            'repo-bootstrap' {
                $ra = @('-Apply', $ans, '-Emit'); if ($ans -eq 'connect-remote') { if (-not $RemoteUrl) { Fail-Usage 'connect-remote needs -RemoteUrl <url>' }; $ra += @('-RemoteUrl', $RemoteUrl) }
                $tr = Invoke-Tool 'repo-bootstrap' $ra (Join-Path $LogDir 'repo-bootstrap-apply.out')
                Say ('kcc-run: repo-bootstrap -Apply ' + $ans + ' exited ' + $tr.rc)
                $pa = 'recheck'
            }
            'roi-gate' { if ($ans -eq 'proceed') { $pa = 'done' } else { $pa = 'goto:' + $States[(Find-PrevCommandState $idx)].id } }
            'confirm' { if ($ans -eq 'confirm') { $pa = 'done' } else { $pa = 'goto:' + $States[(Find-PrevCommandState $idx)].id } }
            'budget' {
                if ($ans -eq 'approve') {
                    $sp = $R.gate_spec; if (-not $sp) { $sp = $R.idea }
                    [void](Emit 'estimate-approved' $sp ([ordered]@{ state = [int]$R.gate_state; gate_id = $gid; scope = $(if ($R.gate_spec) { 'implement' } else { 'idea' }); approved_by = 'human'; source = 'kcc-run' }))
                    $pa = 'approved'
                } else { $pa = 'rerun' }
            }
            'budget-cap' {
                if ($ans -eq 'increase') { if (-not $Budget) { Fail-Usage 'increase needs -Budget <amount>' }; $R.budget = $Budget; $R.scenario = 'S3'; $pa = 'gatecheck' } else { $pa = 'rerun' }
            }
            'windows' { if ($ans -eq 'sequential') { $R.sequential = '1' }; $pa = 'done' }
            'toolchain' {
                if ($ans -eq 'install') { $pa = 'install' } elseif ($ans -eq 'defer') {
                    [void](Emit 'toolchain-gate-decision' $R.gate_spec ([ordered]@{ choice = 'defer'; verdict = 'TOOLCHAIN_DEFERRED'; source = 'kcc-run' })); $pa = 'done'
                } else { $pa = 'recheck' }
            }
            'quality-deferred-on-exit-3' { if ($ans -eq 'install') { $pa = 'install' } else { $pa = 'done' } }
            'loop' { Set-Att $key 0; $pa = 'rerun' }
            'interactive' { $pa = 'recheck' }
            default { $pa = 'recheck' }
        }
    }
    $R.pending_action = $pa
    $R.gate_id = ''; $R.gate_name = ''; $R.gate_kind = ''; $R.gate_answers = ''; $R.gate_event = ''
    $R.status = 'running'
    Save-Run
    Say ('kcc-run: ' + $gid + ' answered ' + $ans + ' -> ' + $pa)
    if ($pa -eq 'abort') { Stop-Run 'aborted' ('human chose abort at ' + $gid + ' (' + $gname + ')') 6 }
}

# ---- budget ------------------------------------------------------------------------------
function Get-LatestEstimate {
    $bc = Join-Path $Coord 'backchannel.jsonl'
    if (-not (Test-Path -LiteralPath $bc)) { return $null }
    $last = $null
    foreach ($l in (Get-Content -LiteralPath $bc -Tail 400 -Encoding UTF8)) {
        if ($l -notmatch '"kind"\s*:\s*"estimate-issued"') { continue }
        if ($l -match '"from"\s*:\s*"kcc-run"') { continue }
        $m = [regex]::Match($l, '"(cost_total_usd|total_cost_usd|estimate_usd|cost_usd|total_usd|amount|cost)"\s*:\s*"?([0-9]+(\.[0-9]+)?)')
        if ($m.Success) { $last = [double]::Parse($m.Groups[2].Value, [System.Globalization.CultureInfo]::InvariantCulture) } else { $last = $null }
    }
    return $last
}

# ---- checkpoints / limit ----------------------------------------------------------------------
function Invoke-Checkpoint([string]$reason, [string]$next) {
    if ($DryRun) { return }
    $tr = Invoke-Tool 'kcc-checkpoint' @('-Reason', $reason, '-Harness', $script:HarnessName, '-NextAction', $next) (Join-Path $LogDir ('checkpoint-' + $reason + '.out'))
    if ($tr.rc -ne 0) { Say ('kcc-run: warning: kcc-checkpoint -Reason ' + $reason + ' exited ' + $tr.rc) }
}
function Suspend-Run($st, $ctx, [string[]]$lines) {
    $reset = Get-ResetEpoch $lines
    $label = Unit-Label $st $ctx
    Invoke-Checkpoint 'limit-hard' ('Run kcc-run -Resume (' + $label + ')')
    $self = $PSCommandPath; if (-not $self) { $self = $MyInvocation.MyCommand.Path }
    $resumeCmd = (QArg $psExe) + ' -NoProfile -ExecutionPolicy Bypass -File ' + (QArg $self) + ' -Resume -RepoRoot ' + (QArg $RepoRoot)
    $lw = Join-Path $ToolsDir 'kcc-limit-watch.ps1'
    $resetJson = 'null'; if ($null -ne $reset) { $resetJson = [string]$reset }
    Write-Lf (Join-Path $RunDir 'limit.json') ('{"harness":"' + $script:HarnessName + '","source":"kcc-run","at":' + [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() + ',"resets_at":' + $resetJson + ',"resume_at":null,"resumes":0,"status":"waiting"}' + "`n")
    # KCC_SUPERVISED=1: 'kcc run' owns the wait and the resume, so no detached watcher is armed.
    $supervised = ($env:KCC_SUPERVISED -eq '1')
    $armOut = ''
    $oldEap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try {
        if ($supervised) { $o = 'supervised by kcc run; watcher not armed' }
        elseif ($null -ne $reset) { $o = & $lw -Arm -Harness $script:HarnessName -RepoRoot $RepoRoot -ResetAt ([string]$reset) -Command $resumeCmd 2>$null }
        else { $o = & $lw -Arm -Harness $script:HarnessName -RepoRoot $RepoRoot -Command $resumeCmd 2>$null }
        $armOut = (@($o) | ForEach-Object { [string]$_ }) -join ' '
    } catch { $armOut = 'arm failed: ' + $_.Exception.Message } finally { $ErrorActionPreference = $oldEap }
    Write-Lf (Join-Path $LogDir 'limit-watch-arm.out') ($armOut + "`n")
    $tr = @{ text = $armOut }
    [void](Emit 'limit-reached' $ctx.SPEC ([ordered]@{ level = 'hard'; harness = $script:HarnessName; source = 'kcc-run'; state = [int]$st.id; wave = $ctx.WAVE; resets_at = $reset; log = $R.last_log }))
    $R.status = 'suspended'; $R.reason = 'usage limit reached during ' + $label
    Save-Run
    Say ('kcc-run: SUSPENDED - usage limit reached during ' + $label + '; restore point written, kcc-limit-watch armed (' + ($tr.text -replace "`n", ' ') + ')')
    Finish 'suspended' 5
}

# ---- unit processing ----------------------------------------------------------------------------
function Complete-Unit($st, $ctx, [bool]$skipped) {
    $key = Unit-Key $st $ctx
    $kind = 'run-state-completed'; if (Has $st 'event') { $kind = [string]$st.event }
    $sp = $ctx.SPEC; if (-not $sp) { $sp = $ctx.IDEA }
    [void](Emit $kind $sp ([ordered]@{ state = [int]$st.id; state_name = [string]$st.name; wave = $ctx.WAVE; attempt = (Get-Att $key); skipped = $skipped; source = 'kcc-run' }))
    Set-Att $key 0
    $R.last_violations = ''
    if ([int]$st.id -eq 1 -or -not $R.idea) { Detect-Idea }
    if ([string]$st.name -eq 'SPECS' -or ((Has $st 'command') -and ([string]$st.command).StartsWith('/spec-create'))) { Load-Specs }
    $cpReason = ''
    if (Has $st 'checkpoint') { $cpReason = [string]$st.checkpoint } elseif ([string]$st.name -eq 'REVIEW') { $cpReason = 'spec-reviewed' }
    if ($cpReason) { Invoke-Checkpoint $cpReason ('kcc-run: ' + (Unit-Label $st $ctx) + ' completed; run kcc-run -Resume') }
    Say ('kcc-run: done   ' + (Unit-Label $st $ctx) + $(if ($skipped) { ' (exit check already passes)' } else { '' }))
    Refresh-Dashboard
}
function Detect-Idea {
    if ($R.idea) { return }
    $before = @((Str $R.ideas_before) -split ' ' | Where-Object { $_ })
    $all = Get-IdeaFolders
    $new = @($all | Where-Object { $before -notcontains $_ })
    $pick = $null
    if ($new.Count -gt 0) { $pick = @($new | Sort-Object { Get-IdeaNum $_ })[-1] }
    if ($pick) { $R.idea = $pick; Say ('kcc-run: idea detected: ' + $pick) }
}
function Load-Specs {
    if (-not $R.idea) { return }
    $list = @(Get-SpecsFromRoadmap $R.idea)
    if ($list.Count -gt 0) { $R.specs = ($list -join ' ') }
}

function Process-Unit($st, $ctx) {
    $key = Unit-Key $st $ctx
    $label = Unit-Label $st $ctx
    $pa = Str $R.pending_action; $R.pending_action = ''
    if ((Has $st 'only_in') -and (@($st.only_in) -notcontains $R.scenario)) { return 'next' }
    $skipFlag = Get-SkipFlag $st
    if ($skipFlag) { Say ("kcc-run: skip   $label ($skipFlag)"); return 'next' }
    if ($pa -eq 'abort') { Stop-Run 'aborted' 'human chose abort' 6 }
    if ($pa -eq 'done') { Complete-Unit $st $ctx $false; return 'next' }
    if ($pa -like 'goto:*') {
        $target = [int]($pa.Substring(5)); $R.state = [string]$target; Add-Force $target
        if ($States[(Get-Idx $target)].scope -eq 'wave') { $R.wave = '' }
        return 'goto'
    }
    $gname = Get-GateName $st
    $gkind = 'failure'; if ($ApprovalGates -contains $gname) { $gkind = 'approval' }
    $hasCheck = Has $st 'check'
    $chk = $null; if ($hasCheck) { $chk = $st.check }
    $interactive = (Has $st 'interactive_in') -and (@($st.interactive_in) -contains $R.scenario)
    $force = (Test-Force ([int]$st.id)) -or $pa -eq 'rerun'
    if ($pa -eq 'rerun') { Set-Att $key 0 }
    $skipDispatch = ($pa -eq 'recheck' -or $pa -eq 'approved' -or $pa -eq 'gatecheck')
    $script:LastHarnessRc = -1

    if ($pa -eq 'install') {
        $prompt = 'KCC run state ' + $st.id + ' ' + $st.name + '. Follow coordination/orchestrator.md Spawn protocol. The human approved INSTALL of the missing toolchain for ' + $ctx.SPEC + ' (.KCC/kernel/protocols/toolchain-preflight.md): install the declared stack tools, re-detect, then stop. Do only this, then stop.'
        $log = Join-Path $LogDir ('state-' + $st.id + '-' + (Safe-Name $ctx.SPEC) + '-install.log')
        $rc = Invoke-Harness $prompt $log
        if (Test-LimitHit $script:LastHarnessLines $rc) { Suspend-Run $st $ctx $script:LastHarnessLines }
        if ($st.name -eq 'PREFLIGHT') { $skipDispatch = $true } else { $force = $true }
    }

    if ($interactive -and $pa -ne 'recheck') {
        if ($hasCheck -and $chk.tool -ne 'internal:agent-report' -and -not $force -and $R.idea) {
            $pre = Run-Check $chk $ctx $key
            if ($pre.rc -eq 0) { Complete-Unit $st $ctx $true; return 'next' }
        }
        $cmdText = Render (Get-StateCommand $st) $ctx
        $q = 'Scenario S1: state ' + $st.id + ' ' + $st.name + ' is an interactive interrogation. Run it yourself in your harness: `' + $cmdText + '`. When it has finished, answer `done` (the exit check then runs) or `abort`.'
        Say ('kcc-run: interactive ' + $label + ' - run in your harness: ' + $cmdText)
        $ex = 'Command: `' + $cmdText + '`'
        if ($R.last_violations) { $ex += "`n`nLast exit-check violations: " + $R.last_violations }
        return (Open-Gate 'interactive' 'interactive' $q $st $ctx $ex)
    }
    if ($interactive -and $pa -eq 'recheck' -and $hasCheck -and $chk.tool -eq 'internal:agent-report') { Complete-Unit $st $ctx $false; return 'next' }

    $preResult = $null
    if (-not $skipDispatch -and $hasCheck -and -not $force -and (Get-Att $key) -eq 0 -and $st.scope -ne 'wave' -and $chk.tool -ne 'internal:agent-report' -and ($R.idea -or [int]$st.id -eq 0) -and -not ($gkind -eq 'approval' -and $gname) -and (Test-PrecheckReady $st $ctx)) {
        $preResult = Run-Check $chk $ctx $key
        if ($preResult.rc -eq 0) { Complete-Unit $st $ctx $true; return 'next' }
    }

    # ---- dispatch -------------------------------------------------------------------------
    $hasCmd = Has $st 'command'
    $att = Get-Att $key
    $needFix = (-not $hasCmd) -and $att -gt 0 -and $hasCheck -and ($ApprovalGates -notcontains $gname) -and $gname -eq ''
    if (-not $skipDispatch -and ($hasCmd -or $needFix)) {
        $body = ''
        if ($hasCmd) { $body = Render (Get-StateCommand $st) $ctx } else { $body = 'The exit check `' + (Check-Desc $chk $ctx) + '` failed. Route each violation to its fix_owner and fix it.' }
        # Full runs wrap each unit with the butler (CR-8: brief first, remember after); fasttrack keeps it to the run's
        # first and last states, which name it in their command. CLOSE already names it.
        $butlerLine = ''
        if ($R.fasttrack -ne '1' -and $st.name -ne 'CLOSE' -and ([string](Get-Setting @('run', 'butler') 'on')).ToLowerInvariant() -ne 'off') { $butlerLine = 'Wrap the work with the butler as the spawn protocol requires: spawn it to brief you first (butler-brief) and to remember afterwards (butler-remember). ' }
        $lead = '. Follow coordination/orchestrator.md Spawn protocol and the state''s contract. ' + $butlerLine + 'Do only this state, then stop. This is a non-interactive session that ends when you reply: run every subagent in the foreground (never run_in_background) and wait for all of them, including parallel ones, before you finish. '
        $script:HarnessExtra = ''
        $am = Get-AgentMode $st $ctx $att
        if ($am) {
            $script:HarnessExtra = Get-HarnessExtra $am
            if ($am.mode -eq 'direct') {
                $body = Convert-AgentBody $body
                $lead = '. You are the ' + $am.agent + ' agent running this state directly, with no orchestrator above you: do the work yourself and spawn no other agent. Do only this state, then stop. '
            } else {
                if ($R.fasttrack -eq '1') { $lead = $lead.TrimEnd() + ' Put the skill''s arguments (`--fasttrack`, `--depthlevel N`, and the rest) verbatim in each subagent''s handover packet and tell it to follow its "Fast track and depth" section; do not paraphrase them. ' }
                if ($am.tier) { $lead = $lead.TrimEnd() + ' Routing (kcc-route): spawn the ' + $am.agent + ' subagent on tier ' + $am.tier + $(if ($am.model) { ', model ' + $am.model } else { '' }) + ', effort ' + $am.effort + ' (' + $am.why + '). Before any other spawn run `.KCC/tools/kcc-route -Agent <name> [-Spec ' + $(if ($ctx.SPEC) { $ctx.SPEC } else { 'SPEC-ID' }) + ']` and use its tier, model and effort. ' }
            }
            if ($am.tier) { [void](Emit 'model-selected' $ctx.SPEC ([ordered]@{ agent = $am.agent; item = $(if ($ctx.WAVE) { 'wave ' + $ctx.WAVE } elseif ($ctx.SPEC) { 'spec' } else { 'run' }); tier = $am.tier; model = $am.model; effort = $am.effort; reasons = $am.why; mode = $am.mode; source = 'kcc-route' })) }
        }
        $prompt = 'KCC run state ' + $st.id + ' ' + $st.name + $(if ($ctx.SPEC) { ' for ' + $ctx.SPEC } else { '' }) + $(if ($ctx.WAVE) { ' wave ' + $ctx.WAVE } else { '' }) + $lead + $body
        if ($att -gt 0 -and $R.last_violations) { $prompt += ' RETRY ' + ($att + 1) + '/' + $cfgMax + ' - fix these exit-check violations: ' + $R.last_violations }
        elseif ((Test-Force $st.id) -and $R.last_violations) { $prompt += ' A later stage failed and sent this spec back. The open Bug items in the spec Backlog and these violations are the work of this pass; fix them test-first and write only the files they name: ' + $R.last_violations }
        if ($R.note) { $prompt += ' Human note: ' + $R.note; $R.note = '' }
        if ($st.scope -eq 'wave' -and $att -eq 0) { Invoke-Checkpoint 'manual' ('kcc-run: baseline before ' + $label) }
        $log = Join-Path $LogDir ('state-' + $st.id + '-' + (Safe-Name $(if ($ctx.SPEC) { $ctx.SPEC + $(if ($ctx.WAVE) { '-w' + $ctx.WAVE } else { '' }) } else { 'run' })) + '-' + ($att + 1) + '.log')
        Say ('kcc-run: run    ' + $label + ' (attempt ' + ($att + 1) + '/' + $cfgMax + ') -> ' + ($log.Substring($RepoRoot.Length).TrimStart('\', '/') -replace '\\', '/'))
        Save-Run
        Refresh-Dashboard
        $rc = Invoke-Harness $prompt $log
        $script:HarnessExtra = ''
        if (Test-LimitHit $script:LastHarnessLines $rc) { Suspend-Run $st $ctx $script:LastHarnessLines }
        if ($rc -eq 124) { Say ('kcc-run: harness timed out for ' + $label) }
        $preResult = $null
    }

    # ---- approval gate -----------------------------------------------------------------------
    if ($pa -ne 'approved') {
        if ($gkind -eq 'approval' -and $gname) {
            if ($gname -eq 'budget-cap') {
                $amt = Get-LatestEstimate; $cap = 0.0
                $capOk = [double]::TryParse((Str $R.budget), [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$cap)
                if ($null -ne $amt -and $capOk -and $amt -le $cap) {
                    $sp = $ctx.SPEC; if (-not $sp) { $sp = $ctx.IDEA }
                    [void](Emit 'auto-policy-approved-bounded' $sp ([ordered]@{ estimate = $amt; cap = $cap; currency = $R.currency; state = [int]$st.id; source = 'kcc-run' }))
                } else {
                    $sp = $ctx.SPEC; if (-not $sp) { $sp = $ctx.IDEA }
                    $why = 'no parseable estimate-issued amount in coordination/backchannel.jsonl'
                    if ($null -ne $amt) { $why = 'estimate ' + $amt + ' exceeds the cap ' + $R.budget + ' ' + $R.currency; [void](Emit 'auto-policy-cap-exceeded' $sp ([ordered]@{ estimate = $amt; cap = $R.budget; currency = $R.currency; source = 'kcc-run' })) }
                    return (Open-Gate $gname 'approval' ('Budget cap check for ' + $label + ': ' + $why + '. Revise the scope, increase the cap (-Answer increase -Budget NN), or abort.') $st $ctx '')
                }
            } else {
                $q = switch ($gname) {
                    'budget' { 'Approve the token estimate for ' + $label + ' (see the latest estimate-issued event and ROADMAP Token Plan)?' }
                    'confirm' { 'Confirm every captured interrogation answer (recap in ideation/' + $ctx.IDEA + '/HumanAnswers.md)?' }
                    'windows' { 'Approve the parallel session windows for ' + $ctx.SPEC + ' (plan.md -> ## Waves), or run sequentially?' }
                    default { 'Approve ' + $label + '?' }
                }
                return (Open-Gate $gname 'approval' $q $st $ctx '')
            }
        } elseif (-not $gname -and (Has $st 'event') -and $st.event -eq 'estimate-issued' -and $R.scenario -eq 'S2') {
            $sp = $ctx.SPEC; if (-not $sp) { $sp = $ctx.IDEA }
            [void](Emit 'auto-policy-approved-unlimited' $sp ([ordered]@{ state = [int]$st.id; scenario = 'S2'; source = 'kcc-run' }))
        }
    }

    # ---- exit check --------------------------------------------------------------------------------
    if (-not $hasCheck) { Complete-Unit $st $ctx $false; return 'next' }
    $res = $preResult
    # A check that names {IDEA} (files-exist, -Spec paths) needs the idea the dispatch just created.
    if ($null -eq $res -and -not $R.idea) { Detect-Idea; if ($R.idea) { $ctx = New-Ctx $ctx.ENTRY $ctx.WAVE } }
    if ($null -eq $res) { $res = Run-Check $chk $ctx ($key + '-' + ((Get-Att $key) + 1)) }
    # A passing check proves nothing when the state's artifact was never written (a conformance scope with
    # nothing in it passes): precheck_requires is also the state's required output.
    if ($res.rc -eq 0 -and (Has $st 'precheck_requires') -and -not $R.idea) { Detect-Idea; $ctx = New-Ctx $ctx.ENTRY $ctx.WAVE }
    if ($res.rc -eq 0 -and -not (Test-PrecheckReady $st $ctx)) {
        $res = @{ rc = 1; viol = ('REQ-001: state ' + $st.id + ' ' + $st.name + ' finished but did not produce ' + (Render ([string]$st.precheck_requires) $ctx)) }
    }
    if ($res.rc -eq 0) { Complete-Unit $st $ctx $false; return 'next' }
    $R.last_violations = (Sanitize-Prompt (Str $res.viol))
    if ($R.last_violations.Length -gt 1500) { $R.last_violations = $R.last_violations.Substring(0, 1500) + ' ...' }
    if ($res.rc -eq 2) { Stop-Run 'stopped' ('exit check for ' + $label + ' returned a usage/environment error: ' + $R.last_violations) 6 }
    if ($res.rc -eq 3) {
        $g = $gname; if (-not $g -or $gkind -eq 'approval') { $g = 'quality-deferred-on-exit-3' }
        return (Open-Gate $g 'failure' ('Exit check for ' + $label + ' is DEFERRED (exit 3): a required external tool is missing. This is not a pass.') $st $ctx $R.last_violations)
    }
    if ($gname -and $gkind -eq 'failure' -and $gname -ne 'quality-deferred-on-exit-3') {
        $q = switch ($gname) {
            'repo-bootstrap' { 'No usable git repository (or no recorded decision). Choose how to bootstrap the workspace repository.' }
            'roi-gate' { 'ROI confidence is below the minimum or not recorded. Proceed anyway, revise the idea, or abort?' }
            'toolchain' { 'Required toolchain missing for ' + $ctx.SPEC + '. Install (AI installs after this approval), human-install, or defer (verdict TOOLCHAIN_DEFERRED)?' }
            default { 'Exit check failed for ' + $label + '.' }
        }
        return (Open-Gate $gname 'failure' $q $st $ctx $R.last_violations)
    }
    $att = (Get-Att $key) + 1
    Set-Att $key $att
    Say ('kcc-run: FAIL   ' + $label + ' exit check (attempt ' + $att + '/' + $cfgMax + '): ' + $R.last_violations)
    if ($att -ge $cfgMax) {
        return (Open-Gate 'loop' 'loop' ('Exit check for ' + $label + ' failed ' + $att + ' consecutive times (CR-3). Revise (retry with a -Note), escalate, or abort?') $st $ctx $R.last_violations)
    }
    if (Has $st 'on_fail_goto') {
        $target = [int]$st.on_fail_goto
        Say ('kcc-run: goto   state ' + $target + ' for ' + $ctx.SPEC + ' (on_fail_goto)')
        $R.state = [string]$target; $R.wave = ''; Add-Force $target
        return 'goto'
    }
    return 'retry'
}

# ---- navigation ----------------------------------------------------------------------------
function Advance {
    $idx = Get-Idx ([int]$R.state); $st = $States[$idx]
    if ($st.scope -eq 'wave') {
        $entry = (Get-SpecEntries)[[int]$R.spec_index]
        $waves = @(Get-Waves $entry)
        $pos = [array]::IndexOf($waves, [string]$R.wave)
        if ($pos -ge 0 -and $pos + 1 -lt $waves.Count) { $R.wave = $waves[$pos + 1]; return }
    }
    $R.wave = ''
    Clear-Force ([int]$st.id)
    if ($idx -ge $SpecFirst -and $idx -le $SpecLast) {
        if ($idx -lt $SpecLast) { $R.state = [string]$States[$idx + 1].id; return }
        $R.spec_index = [string]([int]$R.spec_index + 1)
        if ([int]$R.spec_index -lt (Get-SpecEntries).Count) { $R.state = [string]$States[$SpecFirst].id; $R.force = ''; return }
        if ($idx + 1 -lt $States.Count) { $R.state = [string]$States[$idx + 1].id } else { $R.state = '-1' }
        return
    }
    if ($idx + 1 -lt $States.Count) {
        $R.state = [string]$States[$idx + 1].id
        if ($idx + 1 -eq $SpecFirst) { $R.spec_index = '0' }
    } else { $R.state = '-1' }
}
function Resolve-Unit {
    # returns @{ st; ctx } or stops the run
    $idx = Get-Idx ([int]$R.state)
    if ($idx -lt 0) { return $null }
    $st = $States[$idx]
    if ($st.scope -eq 'run') { return @{ st = $st; ctx = (New-Ctx '' '') } }
    $entries = Get-SpecEntries
    if ($entries.Count -eq 0) { Load-Specs; $entries = Get-SpecEntries }
    if ($entries.Count -eq 0) { Stop-Run 'stopped' ('no specs found for ' + $R.idea + ' (ROADMAP.md) at state ' + $st.id) 6 }
    if ([int]$R.spec_index -ge $entries.Count) { $R.spec_index = '0' }
    $entry = $entries[[int]$R.spec_index]
    $wave = ''
    if ($st.scope -eq 'wave') {
        $waves = @(Get-Waves $entry)
        if ($waves.Count -eq 0) { Stop-Run 'stopped' ('plan.md for ' + $entry + ' has no ## Waves table') 6 }
        if (-not $R.wave -or ($waves -notcontains $R.wave)) { $R.wave = $waves[0] }
        $wave = $R.wave
    }
    return @{ st = $st; ctx = (New-Ctx $entry $wave) }
}

# ---- dry run -------------------------------------------------------------------------------------
function Show-Plan {
    $plan = New-Object System.Collections.ArrayList
    $entries = Get-SpecEntries
    if ($entries.Count -eq 0 -and $R.idea) { $entries = @(Get-SpecsFromRoadmap $R.idea) }
    $startIdx = Get-Idx ([int]$R.state); if ($startIdx -lt 0) { $startIdx = 0 }
    for ($i = $startIdx; $i -lt $States.Count; $i++) {
        $st = $States[$i]
        if ($i -eq $SpecFirst) {
            $list = $entries; if ($list.Count -eq 0) { $list = @('{IDEA}/{SPEC}') }
            foreach ($e in $list) {
                for ($j = $SpecFirst; $j -le $SpecLast; $j++) {
                    $s2 = $States[$j]
                    $wl = @('')
                    if ($s2.scope -eq 'wave') { $wl = @(); if ($e -ne '{IDEA}/{SPEC}') { $wl = @(Get-Waves $e) }; if ($wl.Count -eq 0) { $wl = @('{WAVE}') } }
                    foreach ($w in $wl) {
                        $ctx = New-Ctx $e $w
                        if ($e -eq '{IDEA}/{SPEC}') { $ctx.SPEC = '{SPEC}'; $ctx.IDEA = $(if ($R.idea) { $R.idea } else { '{IDEA}' }) }
                        [void]$plan.Add((Plan-Line $s2 $ctx))
                    }
                }
            }
            $i = $SpecLast; continue
        }
        $ctx = New-Ctx '' ''; if (-not $ctx.IDEA) { $ctx.IDEA = '{IDEA}' }
        [void]$plan.Add((Plan-Line $st $ctx))
    }
    if ($Json) {
        $o = Status-Object 'dry-run'; $o['plan'] = @($plan)
        Write-Output ($o | ConvertTo-Json -Depth 5 -Compress)
    } else {
        Say ('kcc-run DRY RUN - scenario ' + $R.scenario + ', harness ' + $script:HarnessName + ', input "' + $R.input + '", max_attempts ' + $cfgMax + ', timeout ' + $cfgTimeoutMin + 'm')
        foreach ($p in $plan) { Say $p }
        Say ('Nothing was changed.')
    }
    exit 0
}
function Plan-Line($st, $ctx) {
    $lbl = Unit-Label $st $ctx
    if ((Has $st 'only_in') -and (@($st.only_in) -notcontains $R.scenario)) { return ('[skip] ' + $lbl + ' (only_in ' + (@($st.only_in) -join ',') + ')') }
    $skipFlag = Get-SkipFlag $st
    if ($skipFlag) { return ('[skip] ' + $lbl + ' (' + $skipFlag + ')') }
    $parts = @('[' + $st.id + '] ' + $lbl)
    if (Has $st 'command') {
        $c = Render (Get-StateCommand $st) $ctx
        if ((Has $st 'interactive_in') -and (@($st.interactive_in) -contains $R.scenario)) { $parts += ('  interactive (human runs): ' + $c) }
        else {
            $am = Get-AgentMode $st $ctx 0
            $script:HarnessExtra = Get-HarnessExtra $am
            $parts += ('  harness: ' + (Get-HarnessCommand ('KCC run state ' + $st.id + ' ' + $st.name + '. ... ' + $c)))
            $script:HarnessExtra = ''
        }
    }
    if (Has $st 'check') { $parts += ('  check: ' + (Check-Desc $st.check $ctx)) }
    $g = Get-GateName $st; if ($g) { $parts += ('  gate: ' + $g + ' (' + ((Get-Answers $g) -join '/') + ')') }
    if (Has $st 'on_fail_goto') { $parts += ('  on_fail_goto: ' + $st.on_fail_goto) }
    return ($parts -join "`n")
}

# ---- main ------------------------------------------------------------------------------------------
$script:HarnessName = 'claude'
$runExists = Test-Path -LiteralPath $RunFile
$R = $null
if ($runExists) { try { $R = Load-Run } catch { Fail-Usage "cannot parse $RunFile" } }
$terminal = ($null -ne $R) -and (@('done', 'aborted') -contains $R.status)

$startNew = $false
if ($InputText -and -not $Resume) {
    if ($runExists -and -not $terminal) { Fail-Usage ('a run is in progress (' + $R.status + ' at state ' + $R.state + '); use -Resume / -Answer, or delete coordination/run/run.json') }
    $startNew = $true
} elseif (-not $runExists) {
    if ($Resume) { Fail-Usage 'nothing to resume: coordination/run/run.json not found' }
    if (-not $InputText) { Fail-Usage 'usage: kcc-run -Input "<idea|path|IDEA-ID|SPEC-ID|all>" [-Silent -Assume] [-Accuracy NN] [-Budget NN -Currency USD] [-Parallel] [-Fasttrack] [-DepthLevel 1-5] [-Harness h] [-Resume] [-Answer x] [-From N] [-Only N] [-DryRun] [-Json] [-MaxAttempts N]' }
}

if ($startNew) {
    if ($runExists -and -not $DryRun) { Move-Item -LiteralPath $RunFile -Destination (Join-Path $RunDir ('run-' + [DateTime]::UtcNow.ToString('yyyyMMddHHmmss') + '.json')) -Force }
    $R = New-Run
    $txt = $InputText.Trim()
    if ($txt -match '^<(.*)>$') { $txt = $Matches[1].Trim() }
    $R.input = $txt
    $R.ideas_before = ((Get-IdeaFolders) -join ' ')
    if ($txt -eq 'all') {
        $R.input_class = 'all'
        $list = @()
        foreach ($f in (Get-IdeaFolders)) { foreach ($e in (Get-SpecsFromRoadmap $f)) { if ((Get-SpecStatus $e) -notmatch '^(?i)done$') { $list += $e } } }
        $sd = Join-Path $RepoRoot 'specs'
        if (Test-Path -LiteralPath $sd) {
            foreach ($g in @(Get-ChildItem -LiteralPath $sd -Directory | Where-Object { $_.Name -match '^(IDEA-.+)-Specs$' })) {
                $iname = $g.Name.Substring(0, $g.Name.Length - 6)
                if ((Get-IdeaFolders) -contains $iname) { continue }
                foreach ($e in (Get-SpecsFromRoadmap $iname)) { if ((Get-SpecStatus $e) -notmatch '^(?i)done$') { $list += $e } }
            }
        }
        if ($list.Count -eq 0) { Say 'kcc-run: all specs are Done; nothing to run'; if ($Json) { Write-Output '{"tool":"kcc-run","status":"done","reason":"no open specs"}' }; exit 0 }
        $R.specs = ($list -join ' '); $R.idea = ($list[0] -split '/', 2)[0]; $R.state = [string]$States[$SpecFirst].id
    } elseif ($txt -match '^(IDEA-\d+)(-.*)?$') {
        $R.input_class = 'idea'
        $want = $txt
        $cands = @(Get-IdeaFolders | Where-Object { $_ -eq $want -or $_.StartsWith($Matches[1] + '-') -or $_ -eq $Matches[1] })
        if ($txt -ne $Matches[1]) { $exact = @($cands | Where-Object { $_ -eq $want }); if ($exact.Count -eq 1) { $cands = $exact } }
        if ($cands.Count -eq 0) { [Console]::Error.WriteLine('auto: idea ' + $txt + ' not found under ideation/'); exit 6 }
        if ($cands.Count -gt 1) { [Console]::Error.WriteLine('auto: ambiguous idea ' + $txt + ': ' + ($cands -join ', ')); exit 6 }
        $R.idea = $cands[0]; $R.state = '0'
        $sl = @(Get-SpecsFromRoadmap $R.idea); if ($sl.Count -gt 0) { $R.specs = ($sl -join ' ') }
    } elseif ($txt -match '^(SPEC-[0-9A-Za-z]+)') {
        $R.input_class = 'spec'
        $sid = Get-SpecId $txt; $found = @()
        $sd = Join-Path $RepoRoot 'specs'
        if (Test-Path -LiteralPath $sd) {
            foreach ($g in @(Get-ChildItem -LiteralPath $sd -Directory | Where-Object { $_.Name -match '^IDEA-.+-Specs$' })) {
                foreach ($s in @(Get-ChildItem -LiteralPath $g.FullName -Directory | Where-Object { $_.Name -eq $txt -or $_.Name -eq $sid -or $_.Name.StartsWith($sid + '-') })) { $found += ($g.Name.Substring(0, $g.Name.Length - 6) + '/' + $s.Name) }
            }
        }
        if ($found.Count -ne 1) { [Console]::Error.WriteLine('auto: spec ' + $txt + ' ' + $(if ($found.Count -eq 0) { 'not found under specs/' } else { 'is ambiguous: ' + ($found -join ', ') })); exit 6 }
        $R.specs = $found[0]; $R.idea = ($found[0] -split '/', 2)[0]; $R.state = [string]$States[$SpecFirst].id
    } elseif (Test-Path -LiteralPath (Join-Path $RepoRoot $txt)) {
        if (Test-Path -LiteralPath (Join-Path $RepoRoot $txt) -PathType Container) { $R.input_class = 'existing-solution-plus-idea' } else { $R.input_class = 'file-path' }
    } elseif (Test-Path -LiteralPath $txt) {
        if (Test-Path -LiteralPath $txt -PathType Container) { $R.input_class = 'existing-solution-plus-idea' } else { $R.input_class = 'file-path' }
    } else { $R.input_class = 'text' }
}

# policy flags (new run or continuation)
if ($Silent -and $Assume) { $R.silent = '1'; $R.assume = '1'; if ($Budget -or $R.budget) { $R.scenario = 'S3' } else { $R.scenario = 'S2' } }
if ($Budget) { $R.budget = $Budget; if ($R.scenario -eq 'S2') { $R.scenario = 'S3' } }
if ($Currency) { $R.currency = $Currency.ToUpperInvariant() }
if ($Accuracy) { $R.accuracy = $Accuracy }
if ($Parallel) { $R.parallel = '1' }
if ($Fasttrack) { $R.fasttrack = '1' }
# -Until is kept in run.json so a resume (by a human or by kcc-limit-watch after a usage limit) still stops there.
if ($Until) { $R.until = $Until } elseif ((Str $R.until) -match '^\d+$') { $Until = [string]$R.until }
if ($DepthLevel) { $R.depthlevel = $DepthLevel }
elseif ($startNew) {
    $dl0 = [string](Get-Setting @('defaults', 'depthlevel') 5)
    if ($dl0 -notmatch '^[1-5]$') { $dl0 = '5' }
    if ($R.fasttrack -eq '1' -and $dl0 -eq '5') { $dl0 = '2' }
    $R.depthlevel = $dl0
}
if ($Harness) { $R.harness = $Harness }
if (-not $R.harness) { $R.harness = Str (Get-Setting @('run', 'harness') 'claude') }
$script:HarnessName = $R.harness
if (@('claude', 'codex', 'opencode', 'generic') -notcontains $script:HarnessName) { Fail-Usage ('unknown harness in settings/run.json: ' + $script:HarnessName) }
if ($From) { if ((Get-Idx ([int]$From)) -lt 0) { Fail-Usage "unknown state $From" }; $R.state = $From; $R.wave = ''; $R.pending_action = ''; $R.gate_id = ''; $R.attempts = ''; $R.force = [string]$From; if ((Get-Idx ([int]$From)) -ge $SpecFirst -and (Get-Idx ([int]$From)) -le $SpecLast) { $R.spec_index = '0' }; if ($R.status -ne 'done') { $R.status = 'running' } }
if ($Until -and (Get-Idx ([int]$Until)) -lt 0) { Fail-Usage "unknown state $Until" }
if ($Only) {
    if ((Get-Idx ([int]$Only)) -lt 0) { Fail-Usage "unknown state $Only" }
    if ($R.gate_id -and -not $Answer) { Fail-Usage ('gate ' + $R.gate_id + ' is pending; answer it first') }
}

if ($DryRun) { Show-Plan }

if (-not (Test-Path -LiteralPath $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }
if ($startNew) {
    Save-Run
    [void](Emit 'auto-policy-parsed' '' ([ordered]@{ scenario = $R.scenario; silent = ($R.silent -eq '1'); assume = ($R.assume -eq '1'); accuracy_threshold_pct = [int]$R.accuracy; budget_cap_amount = $(if ($R.budget) { [double]$R.budget } else { $null }); budget_cap_currency = $R.currency; parallel = ($R.parallel -eq '1'); fasttrack = ($R.fasttrack -eq '1'); depthlevel = [int]$R.depthlevel; input_class = $R.input_class; harness = $script:HarnessName; source = 'kcc-run' }))
    if ($R.fasttrack -eq '1') { [void](Emit 'fasttrack-approved' '' ([ordered]@{ depthlevel = [int]$R.depthlevel; scope = 'budget-gates-skipped'; source = 'kcc-run' })) }
    Say ('kcc-run: new run - scenario ' + $R.scenario + ', input class ' + $R.input_class + ', starting at state ' + $R.state)
    Offer-Dashboard $true
    Save-Run
} else {
    if ($R.status -eq 'done' -and -not $From -and -not $Only) { Say 'kcc-run: run is DONE; nothing to resume'; Finish 'done' 0 }
    if ($R.status -eq 'aborted' -and -not $From) { Say ('kcc-run: run was ABORTED (' + $R.reason + '); start a new run with -Input'); Finish 'aborted' 6 }
    if ($R.status -eq 'suspended' -or $R.status -eq 'stopped') { $R.status = 'running'; $R.reason = '' }
}

if ($Answer) {
    if (-not $R.gate_id) { Fail-Usage 'no pending gate to answer' }
    Apply-Answer $Answer
} elseif ($R.gate_id) {
    Show-Pause
    $pr = Prompt-Gate
    if ($pr -eq 'paused') { Save-Run; Finish 'paused' 4 }
}

$prevStatus = $R.status
$R.status = 'running'
Save-Run
$onlyIdx = -1; $saved = $null
if ($Only) {
    $saved = @{ state = $R.state; spec_index = $R.spec_index; wave = $R.wave }
    $R.state = $Only; $R.wave = ''; $R.spec_index = '0'; Add-Force ([int]$Only)
    $onlyIdx = Get-Idx ([int]$Only)
}
$guard = 0
while ($true) {
    $guard++; if ($guard -gt 5000) { Stop-Run 'stopped' 'internal loop guard tripped' 6 }
    if ($onlyIdx -ge 0 -and $R.state -ne $Only) {
        Clear-Force ([int]$Only)
        $R.state = $saved.state; $R.spec_index = $saved.spec_index; $R.wave = $saved.wave; if ($prevStatus -eq 'done') { $R.status = 'done' }
        Save-Run
        Say ('kcc-run: -Only ' + $Only + ' finished')
        Finish 'only-done' 0
    }
    if ([int]$R.state -lt 0) {
        $R.status = 'done'; $R.reason = ''
        Save-Run
        $last = $States[$States.Count - 1]
        if (-not ((Has $last 'event') -and $last.event -eq 'session-closed')) { [void](Emit 'session-closed' (Str $R.idea) ([ordered]@{ terminal = 'DONE'; source = 'kcc-run' })) }
        Say 'kcc-run: DONE'
        Finish 'done' 0
    }
    $u = Resolve-Unit
    if ($null -eq $u) { Stop-Run 'stopped' ('unknown state ' + $R.state) 6 }
    $out = Process-Unit $u.st $u.ctx
    if ($out -eq 'paused') { Save-Run; Finish 'paused' 4 }
    if ($out -eq 'answered') { Save-Run; continue }
    if ($out -eq 'retry' -or $out -eq 'goto') { Save-Run; continue }
    if ($out -eq 'next') {
        if ($onlyIdx -ge 0) {
            $moved = $false
            if ($u.st.scope -eq 'wave') {
                $wl = @(Get-Waves $u.ctx.ENTRY); $pos = [array]::IndexOf($wl, [string]$R.wave)
                if ($pos -ge 0 -and $pos + 1 -lt $wl.Count) { $R.wave = $wl[$pos + 1]; $moved = $true }
            }
            if (-not $moved -and $u.st.scope -ne 'run' -and [int]$R.spec_index + 1 -lt (Get-SpecEntries).Count) { $R.spec_index = [string]([int]$R.spec_index + 1); $R.wave = ''; $moved = $true }
            if (-not $moved) { $R.state = '-99' }
        }
        else {
            Advance
            if ($Until -and [int]$u.st.id -eq [int]$Until) {
                $ui = Get-Idx ([int]$Until); $ni = Get-Idx ([int]$R.state)
                if ([int]$R.state -lt 0 -or $ni -gt $ui) {
                    $R.status = 'stopped'; $R.reason = 'until ' + $Until; $R.until = ''
                    Save-Run
                    Say ('kcc-run: -Until ' + $Until + ' reached; run stopped (resume with -Resume)')
                    Finish 'until-done' 0
                }
            }
        }
        Save-Run
        continue
    }
    Stop-Run 'stopped' ('unexpected unit outcome ' + $out) 6
}
