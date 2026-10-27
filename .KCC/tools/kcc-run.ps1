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
    written and kcc-limit-watch armed), 6 stopped or aborted, 7 finished or stopped
    with items that need a human (only under -Silent -Assume, which never pauses:
    every gate is answered by policy and the open items are in coordination/NeedsAttention.md).

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
        'devops-cloud' = 'terraform'; 'devops-k8s-onprem-agnostic' = 'terraform,kubectl,helm'; '\bpnpm\b' = 'pnpm'; 'docker|compose\.ya?ml|containerfile' = 'docker' }
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
# Starting a PowerShell process costs 0.5-0.9 s here, and a run asks for one per dispatch (the router) and per exit check. These tools
# run in this process instead, each in a fresh runspace (its own variables and functions, so nothing leaks either way), with the
# console streams captured the way the child's stdout was. Everything else (and any argument list that is not -Name value pairs) still
# runs as a child process. KCC_TOOLS_CHILD=1 forces the child for every tool.
$script:InProcTools = @('kcc-route', 'kcc-checkpoint', 'check-traceability', 'check-run-conformance', 'quality-gate', 'build-dashboard', 'repo-bootstrap')
function ConvertTo-ParamTable([string[]]$toolArgs) {
    $h = @{}
    $i = 0
    $n = @($toolArgs).Count
    while ($i -lt $n) {
        $t = [string]$toolArgs[$i]
        if ($t -notmatch '^-([A-Za-z][A-Za-z0-9]*)$') { return $null }
        $name = $Matches[1]
        if (($i + 1) -lt $n -and ([string]$toolArgs[$i + 1]) -notmatch '^-[A-Za-z][A-Za-z0-9]*$') { $h[$name] = [string]$toolArgs[$i + 1]; $i += 2 }
        else { $h[$name] = $true; $i++ }
    }
    return $h
}
function Invoke-ToolIsolated([string]$path, $params, [string[]]$tokens, [string]$outFile) {
    $oldOut = [Console]::Out; $oldErr = [Console]::Error
    $swo = New-Object System.IO.StringWriter
    $swe = New-Object System.IO.StringWriter
    $rc = 0
    $lines = @()
    $ps = $null
    try {
        [Console]::SetOut($swo); [Console]::SetError($swe)
        $ps = [powershell]::Create()
        # A script with a param block gets its arguments by name (a hashtable); one without (a stub, a user's own tool) gets them as the
        # tokens of a command line in $args, as it would from a child process.
        $null = $ps.AddScript('param($p, $h, $tok, $root) $ErrorActionPreference = "Continue"; Set-Location -LiteralPath $root; $global:LASTEXITCODE = 0; $cmd = Get-Command -Name $p -CommandType ExternalScript; if ($cmd.ScriptBlock.Ast.ParamBlock) { & $p @h 2>$null } else { & $p @tok 2>$null }; $global:LASTEXITCODE')
        $null = $ps.AddArgument($path)
        $null = $ps.AddArgument($params)
        $null = $ps.AddArgument($tokens)
        $null = $ps.AddArgument($RepoRoot)
        $res = @($ps.Invoke())
        if ($res.Count -gt 0) {
            $rc = [int]($res[$res.Count - 1]).ToString()
            if ($res.Count -gt 1) { $lines = @($res[0..($res.Count - 2)] | ForEach-Object { [string]$_ }) }
        }
        $info = @($ps.Streams.Information | ForEach-Object { [string]$_ })
        $lines = @($info) + @($lines)
    } catch { $rc = 1 } finally {
        [Console]::SetOut($oldOut); [Console]::SetError($oldErr)
        if ($null -ne $ps) { $ps.Dispose() }
    }
    $con = $swo.ToString()
    $text = ($lines -join "`n")
    if ($con) { $text = $(if ($text) { $text + "`n" } else { '' }) + $con.TrimEnd("`r", "`n") }
    if ($outFile) { Write-Lf $outFile ($text + "`n") }
    return @{ rc = [int]$rc; text = $text }
}
function Invoke-Tool([string]$tool, [string[]]$toolArgs, [string]$outFile) {
    $path = Join-Path $ToolsDir ($tool + '.ps1')
    if (-not (Test-Path -LiteralPath $path)) { return @{ rc = 2; text = "tool not found: $tool" } }
    if ($script:InProcTools -contains $tool -and $env:KCC_TOOLS_CHILD -ne '1') {
        $params = ConvertTo-ParamTable $toolArgs
        if ($null -ne $params) { $params['RepoRoot'] = $RepoRoot; return (Invoke-ToolIsolated $path $params (@($toolArgs) + @('-RepoRoot', $RepoRoot)) $outFile) }
    }
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
# Best-effort dashboard refresh (isolated from this run's state, so a failure can never stop it).
function Refresh-Dashboard {
    if ($DryRun -or $env:KCC_SKIP_DASHBOARD -eq '1') { return }
    $b = Join-Path $ToolsDir 'build-dashboard.ps1'
    if (-not (Test-Path -LiteralPath $b)) { return }
    try { $null = Invoke-Tool 'build-dashboard' @() '' } catch { }
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
# ---- Bug items: status, the ruling a blocked one waits for, scoped re-verification -----------------------------
function Get-BugField([string]$file, [string]$col) { # the cell of the bug table row under that column header, lower case
    $bl = [System.IO.File]::ReadAllLines($file)
    for ($bi = 0; $bi -lt $bl.Count - 2; $bi++) {
        if ($bl[$bi] -match '^\|\s*Type\s*\|') {
            $cells = @($bl[$bi].Trim().Trim('|') -split '\|' | ForEach-Object { $_.Trim().ToLowerInvariant() })
            $c = [array]::IndexOf($cells, $col)
            if ($c -ge 0) { $vals = @($bl[$bi + 2].Trim().Trim('|') -split '\|' | ForEach-Object { $_.Trim().ToLowerInvariant() }); if ($vals.Count -gt $c) { return $vals[$c] } }
            return ''
        }
    }
    return ''
}
function Get-BugKey([string]$file) { return ([System.IO.Path]::GetFileNameWithoutExtension($file) -replace '^(Bug-\d+).*$', '$1') }
function Set-BugStatus([string]$file, [string]$new) { # rewrites the Status cell of the bug table row, nothing else (line endings kept)
    $text = [System.IO.File]::ReadAllText($file)
    $nl = "`n"; if ($text.Contains("`r`n")) { $nl = "`r`n" }
    $lines = @($text -split "`r?`n")
    for ($bi = 0; $bi -lt $lines.Count - 2; $bi++) {
        if ($lines[$bi] -match '^\|\s*Type\s*\|') {
            $hc = @($lines[$bi].Trim().Trim('|') -split '\|' | ForEach-Object { $_.Trim().ToLowerInvariant() })
            $c = [array]::IndexOf($hc, 'status')
            if ($c -ge 0) {
                $cells = @($lines[$bi + 2].Trim().Trim('|') -split '\|')
                if ($cells.Count -gt $c) { $cells[$c] = ' ' + $new + ' '; $lines[$bi + 2] = '|' + ($cells -join '|') + '|' }
            }
            break
        }
    }
    [System.IO.File]::WriteAllText($file, ($lines -join $nl), $Utf8)
}
function Get-RulingText([string]$file) { # the '## Ruling needed' section on one line (at most 600 characters)
    $t = ((Get-Section (Read-Lines $file) '(?i)^##\s+ruling needed') -join ' ') -replace '\s+', ' '
    $t = $t.Trim(); if ($t.Length -gt 600) { $t = $t.Substring(0, 600) + ' ...' }
    return $t
}
function Get-OpenBugList([string]$entry) { # 'Bug-003 (major, blocked); Bug-004 (major, open)' for every bug that is not fixed, verified or wontfix
    $bd = Join-Path (Get-SpecDir $entry) 'Backlog'; $out = @()
    if (-not (Test-Path -LiteralPath $bd)) { return '' }
    foreach ($bf in @(Get-ChildItem -LiteralPath $bd -Filter 'Bug-*.md' -File -ErrorAction SilentlyContinue | Sort-Object Name)) {
        $s = Get-BugField $bf.FullName 'status'
        if (@('fixed', 'verified', 'wontfix') -contains $s) { continue }
        $sv = $s; if (-not $sv) { $sv = 'no status' }
        $out += ((Get-BugKey $bf.FullName) + ' (' + (Get-BugField $bf.FullName 'severity') + ', ' + $sv + ')')
    }
    return ($out -join '; ')
}
function Get-ReviewVerdictOf([string]$rf) { # APPROVED | CHANGES_NEEDED | QUALITY_DEFERRED | TOOLCHAIN_DEFERRED | WAIVER_NEEDED | BLOCKED | ''
    if (-not (Test-Path -LiteralPath $rf)) { return '' }
    $rtxt = [System.IO.File]::ReadAllText($rf)
    $vm = [regex]::Match($rtxt, '(?im)^verdict\s*:\s*"?([A-Za-z_-]+)')
    if (-not $vm.Success) { $vm = [regex]::Match($rtxt, '(?i)\b(APPROVED|CHANGES[_-]NEEDED|QUALITY[_-]DEFERRED|TOOLCHAIN[_-]DEFERRED|WAIVER[_-]NEEDED|BLOCKED)\b') }
    if ($vm.Success) { return ($vm.Groups[1].Value.ToUpperInvariant() -replace '-', '_') }
    return ''
}
# Scoped re-verification (kernel/protocols/model-routing.md, agents/verifier.md -> Re-verification mode): the first TEST of a spec is a
# full pass; once a review.md with the verdict CHANGES_NEEDED exists, the next TEST re-verifies only what changed. At most
# $VerifyFullMax full passes per spec; the counter lives in run.json -> attempts under the key full:SPEC-ID.
$VerifyFullMax = 2
$script:VmMode = ''; $script:VmBase = ''; $script:VmVerdict = ''
function Set-VerifyMode([string]$entry) { # sets VmMode (full|scoped) and VmBase (the commit the last review recorded, or '')
    $script:VmMode = 'full'; $script:VmBase = ''; $script:VmVerdict = ''
    $rf = Join-Path (Get-SpecDir $entry) 'review.md'
    $pv = Get-ReviewVerdictOf $rf
    # A QUALITY_DEFERRED or WAIVER_NEEDED review (everything verified, only a scanner or the environment in the way) is re-verified like CHANGES_NEEDED: scoped, so a deferred-only outcome never uses a full pass.
    if ($pv -eq 'CHANGES_NEEDED' -or $pv -eq 'QUALITY_DEFERRED' -or $pv -eq 'WAIVER_NEEDED') {
        $script:VmMode = 'scoped'; $script:VmVerdict = $pv
        $m = [regex]::Match([System.IO.File]::ReadAllText($rf), '(?im)^\s*(?:reviewed[-_ ]?)?commit\s*:\s*"?([0-9a-f]{7,40})')
        if ($m.Success) { $script:VmBase = $m.Groups[1].Value }
        else {
            try { $g = & git -C $RepoRoot log -1 '--format=%H' -- (Rel $rf) 2>$null; if ($LASTEXITCODE -eq 0 -and $g) { $script:VmBase = ([string]($g | Select-Object -First 1)).Trim() } } catch { $script:VmBase = '' }
        }
    }
}
function Get-ScopedPrompt($ctx) { # the sentence added to the verifier's prompt in a scoped re-verification
    if ($script:VmBase) { $base = 'the diff since commit ' + $script:VmBase + ' (git diff ' + $script:VmBase + '..HEAD, plus uncommitted changes)' }
    else { $base = 'the diff since the last review.md was written (no commit is recorded in it: use git log and git status, and the Bug files'' Status)' }
    return ('RE-VERIFICATION MODE (agents/verifier.md -> Re-verification mode): this is not the first verification of ' + $ctx.SPEC + '; a review.md with the verdict ' + $script:VmVerdict + ' exists. Do NOT run a full pass. Re-verify only (a) every Bug item whose Status changed since that review (fixed, wontfix, blocked), and (b) the acceptance criteria and Test IDs whose files changed in ' + $base + '. Always run the mandatory mechanical checks: quality-gate and check-traceability. Copy every other verdict row from the previous review.md unchanged, and state in the new review.md that those rows were carried over from the previous review and not re-run. Verify a fix for real (run its regression test and the commands that exercise it); file a new Bug only for a failure in the re-verified scope or in a changed file. If an orchestrator session runs this state, put this paragraph verbatim in the verifier subagent''s handover packet.')
}
function Open-RulingGate($st, $ctx, [string]$blocked) { # opens the ruling gate for the blocked Bug items; no attempt is used
    $d = @(); $sd = Join-Path (Get-SpecDir $ctx.ENTRY) 'Backlog'
    foreach ($k in @($blocked -split ' ' | Where-Object { $_ })) {
        $bf = Get-ChildItem -LiteralPath $sd -Filter 'Bug-*.md' -File -ErrorAction SilentlyContinue | Where-Object { (Get-BugKey $_.FullName) -eq $k } | Select-Object -First 1
        if ($bf) { $d += ('- ' + $k + ' (' + (Rel $bf.FullName) + '): ' + (Get-RulingText $bf.FullName)) }
    }
    $q = 'Bug item(s) ' + (($blocked -split ' ' | Where-Object { $_ }) -join ', ') + ' of ' + $ctx.SPEC + ' are blocked: the fix cannot proceed without a human ruling, so the implementer is not run again and no attempt is used. Read each ''## Ruling needed'' section (the options and the recommended one), then answer: revise (retry the fix with your ruling; give it with -Note, without a note the recommended option applies), waive (record the bug as wontfix, a human decision), escalate (reopen it and retry, recorded as an escalation), or abort. A silent run never answers this gate itself.'
    return (Open-Gate 'ruling' 'ruling' $q $st $ctx ($d -join "`n`n"))
}
# ---- needs attention: a silent run never stops for a human -------------------------------------------------------
# Under -Silent -Assume every gate is answered by policy (Policy-Gate) and the decision is recorded in
# coordination/NeedsAttention.md (one section per item). status 'decided' = the run went on, check the decision;
# status 'open' = the spec had to be left and a human must act. Exit code 7 = the run ended with open items.
$AttentionFile = Join-Path $Coord 'NeedsAttention.md'
$script:AnsweredBy = 'human'
function Flat([string]$s) { return ((Str $s) -replace '\s+', ' ').Trim() }
function Get-LaneName { if ($RepoRoot -match '[\\/]\.kcc-lanes[\\/]([^\\/]+)$') { return $Matches[1] }; return '' }
function Get-AttentionCounts {
    $items = 0; $open = 0
    if (Test-Path -LiteralPath $AttentionFile) {
        foreach ($al in [System.IO.File]::ReadAllLines($AttentionFile)) {
            if ($al -match '^## \[(open|decided)\]') { $items++; if ($Matches[1] -eq 'open') { $open++ } }
        }
    }
    return @{ items = $items; open = $open }
}
function Show-Attention {
    $c = Get-AttentionCounts
    if ($c.items -gt 0) { Say ('kcc-run: needs attention: ' + (Rel $AttentionFile) + ' - ' + $c.items + ' item(s), ' + $c.open + ' open') }
}
function Add-Attention([string]$spec, $st, [string]$gate, [string]$status, [string]$decided, [string]$why, [string]$todo, [string]$links) {
    if ($DryRun) { return }
    $when = Iso
    $stl = ''; if ($st) { $stl = [string]$st.id + ' ' + [string]$st.name }
    $who = $spec; if (-not $who) { $who = 'run' }
    $sb = New-Object System.Text.StringBuilder
    if (-not (Test-Path -LiteralPath $AttentionFile)) {
        [void]$sb.Append("# Needs attention`n`nWritten by kcc-run under --silent --assume, which never stops for a human: every gate is answered by policy and recorded here.`n`n- status: decided = the run went on with the safest continuing choice; check the decision.`n- status: open = the spec could not continue and was left; a human must act (the run finished everything else, exit code 7).`n`n")
    }
    [void]$sb.Append('## [' + $status + '] ' + $who + ' | ' + $gate + ' | state ' + $stl + ' | ' + $when + "`n`n")
    [void]$sb.Append('- when: ' + $when + "`n- spec: " + $who + "`n- state: " + $stl + "`n- gate: " + $gate + "`n- status: " + $status + "`n")
    [void]$sb.Append('- decided: ' + (Flat $decided) + "`n- why: " + (Flat $why) + "`n- todo: " + (Flat $todo) + "`n- links: " + (Flat $links) + "`n`n")
    Append-Lf $AttentionFile $sb.ToString()
    [void](Emit 'needs-attention' $spec ([ordered]@{ state = $(if ($st) { [int]$st.id } else { 0 }); state_name = $(if ($st) { [string]$st.name } else { '' }); gate = $gate; status = $status; decided = (Flat $decided); reason = (Flat $why); todo = (Flat $todo); file = (Rel $AttentionFile); source = 'kcc-run' }))
}
function Get-ResumeHint([string]$spec, $st) {
    $from = ''; if ($st) { $from = ' --from ' + $st.id }
    $lane = Get-LaneName
    if ($lane) { return ('fix the cause, then: kcc run --lane ' + $lane + $from + ' ; kcc run --resume') }
    return ('fix the cause, then: kcc-run' + $from + ' (kcc-run -Resume continues)')
}
function Find-Entry([string]$specId) {
    foreach ($e in (Get-SpecEntries)) { if ((Get-SpecId (($e -split '/', 2)[1])) -eq $specId) { return $e } }
    return ''
}
# The unit cannot go on and a silent run does not wait: record it as open, then move to the next spec (a bare multi-spec run),
# stop here with exit 7 (a lane, -Until or -Only run), or on to the states after the per-spec ones (last spec of a bare run).
function Block-Unit($st, [string]$spec, [string]$gate, [string]$why, [string]$todo, [string]$links) {
    $key = [string]$st.id; if ($spec) { $key += ':' + $spec }
    $waveKey = ''; if ($R.wave) { $waveKey = $key + ':' + $R.wave }
    Set-Att $key 0; if ($waveKey) { Set-Att $waveKey 0 }
    if ($spec) { Set-Att ('cap:' + $spec) 0 }
    Add-Attention $spec $st $gate 'open' ('the spec was left (needs attention); the run goes on with whatever else can run') $why $todo $links
    $R.last_violations = ''; $R.pending_action = ''
    $ents = Get-SpecEntries; $i = [int]$R.spec_index
    $isSpec = ($spec -and [string]$st.scope -ne 'run')
    if ($isSpec -and ($i + 1) -lt $ents.Count -and $onlyIdx -lt 0) {
        $R.spec_index = [string]($i + 1); $R.state = [string]$States[$SpecFirst].id; $R.wave = ''; $R.force = ''
        Say ('kcc-run: NEEDS ATTENTION ' + $spec + ' (' + $gate + '): ' + (Flat $why) + ' - continuing with the next spec')
        Save-Run
        return
    }
    if (-not $isSpec -or $Until -or $onlyIdx -ge 0) {
        $R.status = 'stopped'; $R.reason = 'needs attention: ' + $(if ($spec) { $spec + ' ' } else { '' }) + $gate + ' at state ' + $st.id + ' ' + $st.name
        Save-Run
        Say ('kcc-run: NEEDS ATTENTION ' + $spec + ' (' + $gate + '): ' + (Flat $why))
        Show-Attention
        Finish 'needs-attention' 7
    }
    $R.wave = ''; $R.force = ''
    if ($SpecLast + 1 -lt $States.Count) { $R.state = [string]$States[$SpecLast + 1].id } else { $R.state = '-1' }
    Say ('kcc-run: NEEDS ATTENTION ' + $spec + ' (' + $gate + '): ' + (Flat $why) + ' - moving on')
    Save-Run
}
function Close-GateByPolicy([string]$answer, [string]$note) {
    $gid = $R.gate_id; $gname = $R.gate_name
    $gf = Join-Path $GateDir ($gid + '.md')
    if (Test-Path -LiteralPath $gf) {
        $t = [System.IO.File]::ReadAllText($gf) -replace "`r`n", "`n"
        $t = $t -replace "(?m)^status: open$", ("status: answered`nanswer: " + $answer + "`nanswered: " + (Iso))
        $t += "`n## Decision`n`n- " + (Iso) + ': `' + $answer + '` (kcc-run, policy: silent run) - ' + $note + "`n"
        Write-Lf $gf $t
    }
    [void](Emit 'human-gate-decision' $R.gate_spec ([ordered]@{ gate = $gname; gate_id = $gid; answer = $answer; answered_by = 'policy'; state = [int]$R.gate_state; wave = $R.gate_wave; trigger_event_id = $R.gate_event; note = $note; source = 'kcc-run' }) -Dashboard)
    $R.gate_id = ''; $R.gate_name = ''; $R.gate_kind = ''; $R.gate_answers = ''; $R.gate_event = ''
    $R.status = 'running'; $R.pending_action = ''
    Save-Run
}
function Policy-Gate {
    $g = [string]$R.gate_name; $gid = [string]$R.gate_id; $gspec = [string]$R.gate_spec
    $sidx = Get-Idx ([int]$R.gate_state); $gst = $States[$sidx]
    $gateFile = 'coordination/gates/' + $gid + '.md'
    $logL = ''; if ($R.last_log) { $logL = ', ' + $R.last_log }
    $ans = ''; $note = ''; $decided = ''; $todo = ''; $why = Flat (Str $R.last_violations)
    switch ($g) {
        'quality-deferred-on-exit-3' {
            $ans = 'accept-deferred'
            $note = 'silent run: deferred quality check accepted by policy (not a pass); install the missing tool and re-run the gate to close it'
            $decided = 'accepted the deferred check by policy (not a pass)'
            $tools = Get-ViolTools $why
            $todo = 'install the missing tool' + $(if ($tools) { ' (' + $tools + ')' } else { '' }) + ' and re-run the quality gate: .KCC/tools/quality-gate -Spec ' + $(if ($gspec) { $gspec } else { 'SPEC-ID' })
        }
        'waiver' {
            $ans = 'waive'
            $note = 'silent run: the code is done and what keeps the gate red needs an environment fix or a human waiver; closed as WAIVER_NEEDED by policy (not a pass)'
            $decided = 'closed the spec as WAIVER_NEEDED by policy (not a pass): the code is done, the remaining gate items need an environment fix or your waiver'
            $todo = 'fix the environment (or record a waiver in review.md -> ## Waivers), then run the verification again: ' + (Get-ResumeHint $gspec ([pscustomobject]@{ id = (Get-TestStateId) }))
        }
        'toolchain' {
            $ans = 'defer'
            $note = 'silent run: toolchain missing -> defer (the declared-stack code is written, build and test are marked TOOLCHAIN_DEFERRED, never a pass)'
            $decided = 'deferred the missing toolchain by policy (TOOLCHAIN_DEFERRED, not a pass)'
            $todo = 'install the missing toolchain (' + (Get-ViolTools $why) + ') and re-run the TEST state for ' + $gspec
        }
        'roi-gate' {
            $ans = 'proceed'
            $note = 'silent run: ROI confidence is below the minimum or not recorded; proceeding on the recorded assumption'
            $decided = 'proceeded despite low or missing ROI confidence'
            $todo = 'review ideation/' + $R.idea + '/ROI.md and decide whether the idea is worth building'
        }
        'repo-bootstrap' {
            $ans = 'skip'
            $note = 'silent run: no usable git repository; skipped the bootstrap (no repository was created or changed)'
            $decided = 'skipped repo-bootstrap'
            $todo = 'run .KCC/tools/repo-bootstrap to create the repository and the protected-main workflow'
        }
        'confirm' { $ans = 'confirm'; $note = 'silent run: interrogation answers confirmed as assumed'; $decided = 'confirmed the assumed answers'; $todo = 'review the assumptions recorded in ideation/' + $R.idea + '/Assumptions.md' }
        'budget' { $ans = 'approve'; $note = 'silent run: estimate approved by policy'; $decided = 'approved the estimate'; $todo = 'compare the estimate with the actual cost' }
        'windows' { $ans = 'sequential'; $note = 'silent run: parallel windows not approved, running sequentially'; $decided = 'ran sequentially'; $todo = 'none unless parallel windows are wanted' }
        'ruling' {
            $n = Get-Att ('ruled:' + $gspec)
            if ($n -lt 2) {
                Set-Att ('ruled:' + $gspec) ($n + 1)
                $ans = 'revise'
                $note = 'silent run: no human ruling; apply the recommended option of the Ruling needed section of each reopened Bug item'
                $decided = 'applied the recommended option of the ruling (as revise, ruling ' + ($n + 1) + ' of 2 allowed by policy)'
                $todo = 'check that the Bug file(s) under Backlog/ and the Ruling section show the recommended option, and that it is acceptable (an architect-owned change such as a Decisions-table edit needs your approval)'
            }
        }
    }
    $links = $gateFile + $logL
    if ($ans) {
        $prevNote = $Note; $script:Note = $note; $script:AnsweredBy = 'policy'
        Say ('kcc-run: silent run, gate ' + $g + ' answered by policy: ' + $ans)
        Apply-Answer $ans
        $script:AnsweredBy = 'human'; $script:Note = $prevNote
        Add-Attention $gspec $gst $g 'decided' $decided $(if ($why) { $why } else { $note }) $todo $links
        return 'answered'
    }
    # No safe continuing answer: the spec (or the run) is left and recorded as open.
    $reason = $why
    $d = 'stopped retrying; left the spec for a human'
    switch ($g) {
        'loop' { if (-not $reason) { $reason = 'the exit check kept failing' }; $reason = 'retry limit reached (CR-3): ' + $reason }
        'budget-cap' { $reason = 'the estimate exceeds the budget cap and a silent run does not raise it: ' + $reason }
        'ruling' { $reason = 'the automatic rulings allowed per spec (2) are used up and the bug is blocked again: ' + $reason }
    }
    $todo = Get-ResumeHint $gspec $gst
    if ($g -eq 'budget-cap') { $todo = 'raise the cap or cut the scope, then: kcc-run -Answer increase -Budget NN, or re-run with a larger -Budget' }
    Close-GateByPolicy 'needs-attention' ('silent run: ' + $d + '. ' + $reason)
    Block-Unit $gst $gspec $g $reason $todo $links
    return 'answered'
}
# ---- deferred checks: accepted, never a pass ----------------------------------------------------------------------
function Get-ViolTools([string]$v) {
    $m = [regex]::Match((Str $v), 'missing tools?:\s*(.*?)(?:\.\s|;|$)')
    if ($m.Success) { return (Flat $m.Groups[1].Value) }
    return ''
}
function Get-LastMissingTools([string]$spec) {
    if (-not (Test-Path -LiteralPath $LogDir)) { return '' }
    $f = Get-ChildItem -LiteralPath $LogDir -Filter ('check-*' + (Safe-Name $spec) + '*-quality-gate.out') -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1
    if (-not $f) { return '' }
    $m = [regex]::Match([System.IO.File]::ReadAllText($f.FullName), '"missing_tools"\s*:\s*\[([^\]]*)\]')
    if (-not $m.Success) { return '' }
    return ((($m.Groups[1].Value -replace '"', '') -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }) -join ', ')
}
# ---- what keeps a gate red, and who owns it ---------------------------------------------------------------------------
# Get-GateOwnerSummary SPEC -> @{ impl = failing checks an implementer owns; items = every failing or deferred check with its owner and
# message } from the newest quality-gate output of the spec. Round 12: a gate red for a tool error and a stale image sent the
# implementer back three times for nothing; the owner column says whether a FIX pass can change anything.
function Get-GateOwnerSummary([string]$spec) {
    $res = @{ impl = 0; items = '' }
    if (-not (Test-Path -LiteralPath $LogDir)) { return $res }
    $f = Get-ChildItem -LiteralPath $LogDir -Filter ('check-*' + (Safe-Name $spec) + '*-quality-gate.out') -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1
    if (-not $f) { return $res }
    $txt = [System.IO.File]::ReadAllText($f.FullName); $b = $txt.IndexOf('{'); if ($b -lt 0) { return $res }
    try { $j = $txt.Substring($b) | ConvertFrom-Json } catch { return $res }
    if ($null -eq $j) { return $res }
    $items = @()
    foreach ($c in @($j.checks)) {
        if ($null -eq $c) { continue }
        $stv = Str $c.status; if ($stv -ne 'fail' -and $stv -ne 'deferred') { continue }
        $o = Str $c.fix_owner
        if ($stv -eq 'fail' -and ($o -eq 'implementer' -or $o -eq 'infrastructure-implementer')) { $res.impl = [int]$res.impl + 1 }
        $m = Str $c.message; if ($m.Length -gt 110) { $m = $m.Substring(0, 110) + '...' }
        $items += ((Str $c.id) + ' (' + $stv + ', ' + $o + '): ' + $m)
    }
    $res.items = ($items -join '; ')
    return $res
}
function Get-TraceabilityErrors([string]$spec) { # the error count of the newest check-traceability output, or ''
    if (-not (Test-Path -LiteralPath $LogDir)) { return '' }
    $f = Get-ChildItem -LiteralPath $LogDir -Filter ('check-*' + (Safe-Name $spec) + '*-check-traceability.out') -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1
    if (-not $f) { return '' }
    $ms = [regex]::Matches([System.IO.File]::ReadAllText($f.FullName), '"errors"\s*:\s*([0-9]+)')
    if ($ms.Count -gt 0) { return $ms[$ms.Count - 1].Groups[1].Value }
    return ''
}
# Test-ReviewWaiverOnly ENTRY SPEC -> $true when a CHANGES_NEEDED review leaves the implementer nothing: no open Bug, no failing gate
# check an implementer owns, no traceability error. What is left needs a human (environment, waiver), so the spec is not sent back to FIX.
function Test-ReviewWaiverOnly([string]$entry, [string]$spec) {
    if (Get-OpenBugList $entry) { return $false }
    $g = Get-GateOwnerSummary $spec
    if ([int]$g.impl -ne 0) { return $false }
    $te = Get-TraceabilityErrors $spec
    return ((-not $te) -or ([int]$te -eq 0))
}
function Get-TestStateId { foreach ($s in $States) { if ([string]$s.name -eq 'TEST') { return [string]$s.id } }; return '16' }
# Test-NothingToVerify ENTRY -> $true when HEAD is the reviewed commit, nothing changed under src/ and no Bug is open or fixed-but-unverified:
# a scoped TEST would re-read an unchanged tree (round 12: a third verifier pass for nothing), so only the mechanical checks run.
function Test-NothingToVerify([string]$entry) {
    $head = ''
    try { $h = & git -C $RepoRoot rev-parse HEAD 2>$null; if ($LASTEXITCODE -eq 0 -and $h) { $head = ([string]($h | Select-Object -First 1)).Trim() } } catch { $head = '' }
    if (-not $script:VmBase -or -not $head -or -not $head.StartsWith($script:VmBase)) { return $false }
    $chg = @()
    try { $chg = @(& git -C $RepoRoot status --porcelain -- src 2>$null | Where-Object { $_ }) } catch { $chg = @() }
    if ($chg.Count -gt 0) { return $false }
    if (Get-OpenBugList $entry) { return $false }
    $bd = Join-Path (Get-SpecDir $entry) 'Backlog'
    if (Test-Path -LiteralPath $bd) {
        foreach ($bf in @(Get-ChildItem -LiteralPath $bd -Filter 'Bug-*.md' -File -ErrorAction SilentlyContinue)) { if ((Get-BugField $bf.FullName 'status') -eq 'fixed') { return $false } }
    }
    return $true
}
# Get-EnvLimits SPEC -> the LIMIT lines of the newest toolchain-preflight output (a Docker daemon that cannot reach a registry, ...), joined
function Get-EnvLimits([string]$spec) {
    if (-not (Test-Path -LiteralPath $LogDir)) { return '' }
    $f = Get-ChildItem -LiteralPath $LogDir -Filter ('check-*' + (Safe-Name $spec) + '*-toolchain-preflight.out') -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1
    if (-not $f) { return '' }
    $lim = @([System.IO.File]::ReadAllLines($f.FullName) | ForEach-Object { $_.TrimEnd("`r") } | Where-Object { $_ -match '^LIMIT ' } | ForEach-Object { $_ -replace '^LIMIT ', '' })
    return ($lim -join '; ')
}
# Records that the human (or the silent policy) accepted a deferred external tool for this spec: REVIEW then closes the spec as
# deferred-accepted instead of looping through FIX and another full test pass.
function Register-Deferral([string]$spec, $st, [string]$gate, [string]$by) {
    if (-not $spec) { return }
    $viol = Str $R.last_violations
    $tools = Get-ViolTools $viol
    if (-not $tools) { $tools = Get-LastMissingTools $spec }
    $verdict = 'QUALITY_DEFERRED'; if ($viol -match 'TOOLCHAIN_DEFERRED' -or $gate -eq 'toolchain') { $verdict = 'TOOLCHAIN_DEFERRED' }
    $checks = ''; $cm = [regex]::Match($viol, 'deferred checks?\s+([A-Z0-9, -]+?)(?:,\s*not a pass|\.|;|$)'); if ($cm.Success) { $checks = (Flat $cm.Groups[1].Value) }
    if ($gate -eq 'waiver') { $verdict = 'WAIVER_NEEDED'; $tools = ''; $checks = (Flat (Str (Get-GateOwnerSummary $spec).items)) }
    Set-Att ('defer:' + $spec) 1
    [void](Emit 'deferral-accepted' $spec ([ordered]@{ state = [int]$st.id; state_name = [string]$st.name; gate = $gate; verdict = $verdict; by = $by; tools = $tools; checks = $checks; source = 'kcc-run' }))
}
function Get-DeferredItems {
    $bc = Join-Path $Coord 'backchannel.jsonl'; $seen = @{}; $out = @()
    if (-not (Test-Path -LiteralPath $bc)) { return @() }
    $mine = @(Get-SpecEntries | ForEach-Object { Get-SpecId (($_ -split '/', 2)[1]) })
    foreach ($l in [System.IO.File]::ReadAllLines($bc)) {
        if ($l -notmatch '"kind"\s*:\s*"deferral-accepted"') { continue }
        $sp = [regex]::Match($l, '"spec"\s*:\s*"([^"]*)"').Groups[1].Value
        if ($mine.Count -gt 0 -and $mine -notcontains $sp) { continue }
        $tl = [regex]::Match($l, '"tools"\s*:\s*"([^"]*)"').Groups[1].Value
        $k = $sp + '|' + $tl
        $vd = [regex]::Match($l, '"verdict"\s*:\s*"([^"]*)"').Groups[1].Value
        $item = [pscustomobject]@{ spec = $sp; tools = $tl; checks = [regex]::Match($l, '"checks"\s*:\s*"([^"]*)"').Groups[1].Value; verdict = $vd }
        # A waiver recorded after a deferral of the same spec (TEST deferred a check, REVIEW ended WAIVER_NEEDED) is the verdict that counts.
        if ($seen.ContainsKey($k)) { if ($vd -eq 'WAIVER_NEEDED') { $out[$seen[$k]] = $item }; continue }
        $seen[$k] = $out.Count
        $out += $item
    }
    return @($out)
}
function Get-DeferralLines($d) {
    $sp = $d.spec; if (-not $sp) { $sp = 'SPEC-ID' }
    if ($d.verdict -eq 'WAIVER_NEEDED') {
        $ck = $d.checks; if (-not $ck) { $ck = 'see review.md -> Verdict' }
        return @(
            ('WAIVER NEEDED, NOT A PASS - ' + $sp + ': the code is done; these gate items need an environment fix or your waiver: ' + $ck),
            ('  fix the environment or record the waiver in review.md -> ## Waivers, then run the verification again: kcc-run -From ' + (Get-TestStateId) + '   |   kcc run --lane ' + $sp))
    }
    if (-not $d.tools) {
        $c = ''; if ($d.checks) { $c = ' (' + $d.checks + ' not run)' }
        return @(
            ('DEFERRED, NOT A PASS - ' + $sp + $c + ': a check could not run on this machine (a tool or service the tests need is unusable here; see review.md -> Test Status and Quality Gate Check).'),
            ('  fix the environment, then re-run the verification: kcc-run -From ' + (Get-TestStateId) + '   |   kcc run --lane ' + $sp))
    }
    $t = $d.tools
    $c = ''; if ($d.checks) { $c = ' (' + $d.checks + ' not run)' }
    $tl = ($d.tools -replace ',\s*', ','); if (-not $tl) { $tl = '<tool>' }
    return @(
        ('DEFERRED, NOT A PASS - ' + $sp + $c + ': missing tool(s) ' + $t + '.'),
        ('  install (human-gated): powershell -ExecutionPolicy Bypass -File .KCC\tools\toolchain-preflight.ps1 -Tools ' + $tl + '   |   bash .KCC/tools/toolchain-preflight.sh ' + ($tl -replace ',', ' ')),
        ('  then re-run the gate : powershell -ExecutionPolicy Bypass -File .KCC\tools\quality-gate.ps1 -Spec ' + $sp + '   |   bash .KCC/tools/quality-gate.sh --spec ' + $sp))
}
function Show-Deferred {
    foreach ($d in @(Get-DeferredItems)) { foreach ($ln in (Get-DeferralLines $d)) { Say ('kcc-run: ' + $ln) } }
}
function Add-ClosedDeferred {
    $f = Join-Path $RunDir 'closed.md'
    if (-not (Test-Path -LiteralPath $f)) { return }
    if ([System.IO.File]::ReadAllText($f).Contains('<!-- kcc-run:deferred -->')) { return }
    $items = @(Get-DeferredItems); $c = Get-AttentionCounts
    if ($items.Count -eq 0 -and $c.items -eq 0) { return }
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append("`n<!-- kcc-run:deferred -->`n")
    if ($items.Count -gt 0) {
        [void]$sb.Append("## Deferred checks (NOT a pass)`n`n")
        foreach ($d in $items) { foreach ($ln in (Get-DeferralLines $d)) { [void]$sb.Append('- ' + $ln.Trim() + "`n") } }
    }
    if ($c.items -gt 0) { [void]$sb.Append("`n## Needs attention`n`n- " + (Rel $AttentionFile) + ': ' + $c.items + ' item(s), ' + $c.open + " open`n") }
    Append-Lf $f $sb.ToString()
}
function Set-RulingOnBugs([string]$ans) { # applies the human's ruling to every blocked Bug item of the gate's spec (revise|escalate -> open, waive -> wontfix) and records it in the bug file
    $ents = Get-SpecEntries; $i = [int]$R.spec_index
    if ($i -ge $ents.Count) { return }
    $sd = Join-Path (Get-SpecDir $ents[$i]) 'Backlog'
    if (-not (Test-Path -LiteralPath $sd)) { return }
    $new = 'open'; if ($ans -eq 'waive') { $new = 'wontfix' }
    foreach ($bf in @(Get-ChildItem -LiteralPath $sd -Filter 'Bug-*.md' -File -ErrorAction SilentlyContinue | Sort-Object Name)) {
        if ((Get-BugField $bf.FullName 'status') -ne 'blocked') { continue }
        Set-BugStatus $bf.FullName $new
        $line = "`n## Ruling`n`n- " + (Iso) + ' human: `' + $ans + '` -> Status ' + $new + $(if ($Note) { ' - ' + $Note } else { '' }) + "`n"
        $raw = [System.IO.File]::ReadAllText($bf.FullName)
        $nlf = $line; if ($raw.Contains("`r`n")) { $nlf = $line -replace "`n", "`r`n" }
        [System.IO.File]::AppendAllText($bf.FullName, $nlf, $Utf8)
    }
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
        # The review template writes the verdict lower-case with hyphens (status/toolchain-deferred); read it the same as TOOLCHAIN_DEFERRED.
        $v = Get-ReviewVerdictOf $rf
        if ($v -eq 'APPROVED') { return @{ rc = 0; viol = '' } }
        if ($v -eq 'WAIVER_NEEDED' -or ($v -eq 'CHANGES_NEEDED' -and (Test-ReviewWaiverOnly $ctx.ENTRY $ctx.SPEC))) {
            # The code is done: no open Bug, no failing check an implementer owns. What keeps the gate red (an environment limit, a stale
            # artifact, a gate tool error, a check the architecture excluded) needs a human: exit 3 opens the waiver gate, never FIX.
            $ob = Get-OpenBugList $ctx.ENTRY
            if ($ob) { return @{ rc = 1; viol = ('REVIEW-002 (implementer): ' + $ctx.SPEC + ' review verdict is ' + $v + ' but these bug items are not closed: ' + $ob + '; fix them, then re-test') } }
            $gs = Get-GateOwnerSummary $ctx.SPEC
            $how = 'review verdict ' + $v; if ($v -eq 'CHANGES_NEEDED') { $how = 'review verdict CHANGES_NEEDED with no open bug and no failing check an implementer owns (read as WAIVER_NEEDED)' }
            return @{ rc = 3; viol = ('REVIEW-004 (human): ' + $how + '; the code is done and what keeps the gate red needs an environment fix or a recorded waiver, not another fix pass: ' + $(if ($gs.items) { $gs.items } else { 'see review.md -> Verdict' }) + '. not a pass') }
        }
        if ($v -eq 'QUALITY_DEFERRED' -or $v -eq 'TOOLCHAIN_DEFERRED') {
            # Deferred = every check that could run has run and the only blocker is an external tool that is missing (quality-gate exit 3).
            # With every bug fixed, verified or waived that is exit 3 (closed as deferred-accepted, never a pass, no FIX and no second full pass);
            # with a bug still open the implementer has work, so it is a failure like CHANGES_NEEDED.
            $ob = Get-OpenBugList $ctx.ENTRY
            if ($ob) { return @{ rc = 1; viol = ('REVIEW-002 (implementer): ' + $ctx.SPEC + ' review verdict is ' + $v + ' but these bug items are not closed: ' + $ob + '; fix them, then re-test') } }
            $mt = Get-LastMissingTools $ctx.SPEC
            return @{ rc = 3; viol = ('REVIEW-003 (human): review verdict ' + $v + '; every bug is closed and the only blocker is a deferred external tool, so this is not a pass' + $(if ($mt) { '. missing tools: ' + $mt } else { '' })) }
        }
        if (-not $v) { $v = 'missing' }
        return @{ rc = 1; viol = ('REVIEW-002 (implementer): ' + $ctx.SPEC + ' review verdict is ' + $v + '; fix the open bugs and failing acceptance criteria listed in review.md, then re-review') }
    }
    if ($tool -eq 'internal:no-open-bugs') {
        # Bug items of the spec (Backlog/Bug-*.md) by Status cell. open or fixing: the FIX state is done when none is left.
        # blocked: the fix needs a human ruling (a '## Ruling needed' section); it is its own finding (BUG-006, owner human), is never
        # retried, and opens the ruling gate (blocked lists the bugs, open the ones an implementer can still fix).
        $open = @(); $blocked = @(); $bq = @()
        if ($ctx.ENTRY) {
            $bd = Join-Path (Get-SpecDir $ctx.ENTRY) 'Backlog'
            if (Test-Path -LiteralPath $bd) {
                foreach ($bf in @(Get-ChildItem -LiteralPath $bd -Filter 'Bug-*.md' -File -ErrorAction SilentlyContinue | Sort-Object Name)) {
                    $stv = Get-BugField $bf.FullName 'status'
                    if ($stv -eq 'open' -or $stv -eq 'fixing') { $open += (Get-BugKey $bf.FullName) }
                    if ($stv -eq 'blocked') { $blocked += (Get-BugKey $bf.FullName); $bq += ((Get-BugKey $bf.FullName) + ' needs a ruling: ' + (Get-RulingText $bf.FullName) + ';') }
                }
            }
        }
        $bs = ($blocked -join ' '); $os = ($open -join ' ')
        if ($blocked.Count -gt 0 -and $open.Count -eq 0) { return @{ rc = 1; viol = ('BUG-006 (human): ' + $ctx.SPEC + ' has blocked bug item(s) ' + ($blocked -join ', ') + '; no fix can proceed without a human ruling. ' + (($bq -join ' ').TrimEnd(';'))); blocked = $bs; open = $os } }
        if ($open.Count -gt 0) { return @{ rc = 1; viol = ('BUG-OPEN (implementer): ' + $ctx.SPEC + ' still has open bug item(s) ' + ($open -join ', ') + '; fix each test-first and set its Status to fixed'); blocked = $bs; open = $os } }
        return @{ rc = 0; viol = '' }
    }
    if ($tool -eq 'internal:file-exists') {
        $rel = Render (Str $chk.path) $ctx
        if (Test-Path -LiteralPath (Join-Path $RepoRoot $rel)) { return @{ rc = 0; viol = '' } }
        return @{ rc = 1; viol = ('FILE-001 (agent): missing ' + $rel) }
    }
    if ($tool -eq 'internal:roadmap-specs') {
        # SPECS (fast track) writes only the split: ROADMAP.md plus a folder with a stub note for every spec it lists.
        $rd = Join-Path $RepoRoot ('specs\' + $ctx.IDEA + '-Specs')
        $rm = Join-Path $rd 'ROADMAP.md'
        if (-not $ctx.IDEA -or -not (Test-Path -LiteralPath $rm)) { return @{ rc = 1; viol = ('SPEC-005 (spec-writer): missing specs/' + $(if ($ctx.IDEA) { $ctx.IDEA } else { 'IDEA' }) + '-Specs/ROADMAP.md') } }
        $ids = @()
        foreach ($rl in [System.IO.File]::ReadAllLines($rm)) {
            if ($rl -match '^\s*\|' -and $rl -notmatch '^\s*\|[\s:|-]+\|?\s*$') { $rmm = [regex]::Match($rl, 'SPEC-\d+'); if ($rmm.Success -and $ids -notcontains $rmm.Value) { $ids += $rmm.Value } }
        }
        if ($ids.Count -eq 0) { return @{ rc = 1; viol = 'SPEC-005 (spec-writer): ROADMAP.md lists no SPEC-NNN in its Execution Plan' } }
        $miss = @($ids | Where-Object { $sid = $_; -not (Get-ChildItem -LiteralPath $rd -Directory -ErrorAction SilentlyContinue | Where-Object { ($_.Name -eq $sid -or $_.Name.StartsWith($sid + '-')) -and (Get-ChildItem -LiteralPath $_.FullName -Filter ($sid + '*.md') -File -ErrorAction SilentlyContinue) }) })
        if ($miss.Count -eq 0) {
            # The split also writes the per-idea index (IDEA-NNN-slug-Specs.md): the planners and the LINK-002/003 checks read it.
            if (-not (Test-Path -LiteralPath (Join-Path $rd ($ctx.IDEA + '-Specs.md')))) { return @{ rc = 1; viol = ('SPEC-006 (spec-writer): missing the per-idea index specs/' + $ctx.IDEA + '-Specs/' + $ctx.IDEA + '-Specs.md (a table of the SPEC notes that wikilinks the idea note)') } }
            return @{ rc = 0; viol = '' }
        }
        return @{ rc = 1; viol = ('SPEC-005 (spec-writer): ROADMAP.md lists ' + ($miss -join ', ') + ' but there is no folder with a SPEC-NNN-slug.md stub note for it') }
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
    # Exit 3 is a deferred check (an external tool is missing): name the tool and the checks that did not run, so the gate, the
    # NeedsAttention item and the closing message can say exactly what to install.
    if ($rc -eq 3 -and -not $viol -and $null -ne $obj -and $obj.PSObject.Properties.Name -contains 'missing_tools') {
        $mt = (@($obj.missing_tools) | Where-Object { $_ }) -join ', '
        $dc = @(); if ($obj.PSObject.Properties.Name -contains 'checks') { foreach ($c in @($obj.checks)) { if ((Str $c.status) -eq 'deferred' -and (Str $c.id) -and $dc -notcontains (Str $c.id)) { $dc += (Str $c.id) } } }
        if ($mt) { $viol = ('QG-DEFERRED (human): ' + $tool + ' deferred' + $(if ($dc.Count -gt 0) { ' checks ' + ($dc -join ', ') } else { '' }) + ', not a pass. missing tools: ' + $mt + '. Install them through toolchain-preflight, then re-run ' + $tool) }
    }
    if ($tool -eq 'toolchain-preflight' -and $rc -ne 0 -and $tr.text -match 'MISSING TOOLS:\s*([^\r\n]+)') { $viol = ('TC-001 (human): toolchain preflight failed. missing tools: ' + (Flat $Matches[1]) + '. Install them or defer.') }
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
function Get-Route([string]$agent, $ctx, [int]$attempt, [bool]$caps = $false) {
    if (-not $agent) { return $null }
    $a = @('-Agent', $agent, '-Attempt', [string]$attempt, '-Harness', $script:HarnessName)
    if ($ctx.SPEC) { $a += @('-Spec', $ctx.SPEC) }
    if ($ctx.WAVE) { $a += @('-Wave', $ctx.WAVE) }
    if ($caps) { $a += @('-MaxTier', 'balanced', '-MaxEffort', 'high') }
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
    # REVIEW is a quick diff review and a scoped re-verification a re-check: neither runs above balanced tier at high effort (model-routing.md).
    $caps = ($st.name -eq 'REVIEW') -or ($st.name -eq 'TEST' -and $script:VmMode -eq 'scoped')
    $route = Get-Route $agent $ctx ($att + 1) $caps
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
    if ($R.silent -ne '1') { Show-Pause }
    return (Prompt-Gate)
}
function Prompt-Gate {
    # A silent run has no human and never stops for one: every gate is answered by policy with the safest continuing choice
    # (Policy-Gate), recorded in the gate file, the human-gate-decision event (answered_by policy) and coordination/NeedsAttention.md.
    # A spec that cannot continue is left as an open item and the run goes on with the rest. A deferred check is never a pass.
    if ($R.silent -eq '1') { return (Policy-Gate) }
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
    [void](Emit 'human-gate-decision' $R.gate_spec ([ordered]@{ gate = $gname; gate_id = $gid; answer = $ans; answered_by = $script:AnsweredBy; state = [int]$R.gate_state; wave = $R.gate_wave; trigger_event_id = $R.gate_event; note = (Str $Note); source = 'kcc-run' }) -Dashboard)
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
                    Register-Deferral $R.gate_spec $st 'toolchain' $script:AnsweredBy
                } else { $pa = 'recheck' }
            }
            'quality-deferred-on-exit-3' {
                if ($ans -eq 'install') { $pa = 'install' } else { $pa = 'done'; Register-Deferral $R.gate_spec $st 'quality-deferred-on-exit-3' $script:AnsweredBy }
            }
            'waiver' {
                # waive: the spec closes as WAIVER_NEEDED (recorded like a deferral, never a pass) and the run goes on; recheck: the human
                # changed the environment, so the verification runs again (scoped) and the review after it.
                if ($ans -eq 'waive') { $pa = 'done'; Register-Deferral $R.gate_spec $st 'waiver' $script:AnsweredBy }
                else { $pa = 'goto:' + (Get-TestStateId); Set-Att $key 0 }
            }
            'ruling' {
                # revise and escalate reopen the blocked bugs and re-run the fix with the ruling as the note; waive records them as wontfix
                if ($ans -eq 'waive') { $pa = 'recheck' } else {
                    $pa = 'rerun'; Set-Att $key 0
                    if ($script:AnsweredBy -eq 'policy') { $R.note = 'no human is available (silent run): ruling by policy (' + $ans + '): apply the recommended option of the Ruling needed section of each reopened Bug item, then set its Status to fixed' }
                    elseif (-not $Note) { $R.note = 'the human answered ' + $ans + ' without a note: apply the recommended option of the Ruling needed section of each reopened Bug item, then set its Status to fixed' }
                    else { $R.note = 'human ruling (' + $ans + '): ' + $Note + '. Follow it for the reopened Bug items, then set their Status to fixed' }
                }
                Set-RulingOnBugs $ans; $R.last_violations = ''
            }
            'loop' {
                Set-Att $key 0; $pa = 'rerun'
                # the pass-cap gate (a third full verifier pass): the human's revise or escalate grants exactly one more full pass
                if ($R.gate_spec -and (Get-Att ('cap:' + $R.gate_spec)) -ne 0) { Set-Att ('cap:' + $R.gate_spec) 0; Set-Att ('full:' + $R.gate_spec) ($VerifyFullMax - 1) }
            }
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
    if ([string]$st.name -eq 'SPECS' -or ((Has $st 'command') -and ([string]$st.command).StartsWith('/spec-create') -and ([string]$st.scope -eq 'run'))) { Load-Specs }
    $cpReason = ''
    if (Has $st 'checkpoint') { $cpReason = [string]$st.checkpoint } elseif ([string]$st.name -eq 'REVIEW') { $cpReason = 'spec-reviewed' }
    if ($cpReason) { Invoke-Checkpoint $cpReason ('kcc-run: ' + (Unit-Label $st $ctx) + ' completed; run kcc-run -Resume') }
    if ([string]$st.name -eq 'CLOSE') { Add-ClosedDeferred }
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
    $script:LastHarnessRc = -1; $script:DispatchNo = 0

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
    $script:VmMode = ''; $script:VmBase = ''
    # A bug the implementer cannot fix without a human ruling (Status blocked) opens the ruling gate at once: no dispatch, no attempt used.
    if ($hasCheck -and $chk.tool -eq 'internal:no-open-bugs' -and $ctx.ENTRY) {
        $bres = Run-Check $chk $ctx $key
        if ($bres.blocked -and -not $bres.open) { $R.last_violations = (Sanitize-Prompt (Str $bres.viol)); return (Open-RulingGate $st $ctx ([string]$bres.blocked)) }
        # Nothing for the implementer to do: no open bug, and the check or review that sent the spec back names no violation an
        # implementer owns (round 11: a FIX run of 86 s found "nothing in scope remains"). No agent runs; the unit completes as skipped.
        if (-not $bres.open -and -not $bres.blocked -and $hasCmd -and -not $skipDispatch -and $pa -ne 'rerun' -and (Test-Force ([int]$st.id)) -and $R.last_violations -and $R.last_violations -notmatch '\((implementer|infrastructure-implementer)\)') {
            Say ('kcc-run: skip   ' + $label + ': no open bug and no violation an implementer can fix (' + (Flat $R.last_violations) + ')')
            Complete-Unit $st $ctx $true
            return 'next'
        }
    }
    if ($st.name -eq 'TEST' -and $ctx.ENTRY -and $hasCmd -and -not $skipDispatch) {
        Set-VerifyMode $ctx.ENTRY
        if ($script:VmMode -eq 'scoped' -and (Test-NothingToVerify $ctx.ENTRY)) {
            Say ('kcc-run: skip   ' + $label + ': nothing changed since the last review (HEAD ' + $script:VmBase + ', no change under src/, no Bug awaiting verification); mechanical checks only')
            [void](Emit 'test-skipped' $ctx.SPEC ([ordered]@{ state = [int]$st.id; state_name = [string]$st.name; reason = 'unchanged since the last review'; commit = $script:VmBase; source = 'kcc-run' }))
            $skipDispatch = $true
        }
    }
    if (-not $skipDispatch -and ($hasCmd -or $needFix)) {
        $body = ''
        # TEST: the first verification of a spec is a full pass; later ones re-verify only what changed. At most VerifyFullMax full passes.
        if ($st.name -eq 'TEST' -and $ctx.ENTRY -and $hasCmd) {
            Set-VerifyMode $ctx.ENTRY
            if ($script:VmMode -eq 'full' -and $att -eq 0) {
                $fp = Get-Att ('full:' + $ctx.SPEC)
                if ($fp -ge $VerifyFullMax) {
                    Set-Att ('cap:' + $ctx.SPEC) 1
                    $ob = Get-OpenBugList $ctx.ENTRY
                    return (Open-Gate 'loop' 'loop' ('Verification of ' + $ctx.SPEC + ' would be its full pass number ' + ($fp + 1) + '; at most ' + $VerifyFullMax + ' full verifier passes are allowed per spec (CR-3), so no verifier is run. Still open: ' + $ob + '. Revise (one more full pass, with a -Note), escalate, or abort?') $st $ctx ('Open bug items: ' + $ob))
                }
                Set-Att ('full:' + $ctx.SPEC) ($fp + 1)
            }
        }
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
            if ($am.tier) { [void](Emit 'model-selected' $ctx.SPEC ([ordered]@{ agent = $am.agent; item = $(if ($ctx.WAVE) { 'wave ' + $ctx.WAVE } elseif ($ctx.SPEC) { 'spec' } else { 'run' }); tier = $am.tier; model = $am.model; effort = $am.effort; reasons = $am.why; mode = $am.mode; pass = $script:VmMode; source = 'kcc-route' })) }
        }
        $prompt = 'KCC run state ' + $st.id + ' ' + $st.name + $(if ($ctx.SPEC) { ' for ' + $ctx.SPEC } else { '' }) + $(if ($ctx.WAVE) { ' wave ' + $ctx.WAVE } else { '' }) + $lead + $body
        if ($script:VmMode -eq 'scoped') { $prompt += ' ' + (Get-ScopedPrompt $ctx) }
        if ($script:VmMode -eq 'full') { $prompt += ' FULL VERIFICATION PASS ' + (Get-Att ('full:' + $ctx.SPEC)) + ' of at most ' + $VerifyFullMax + ' for ' + $ctx.SPEC + ': run every check in this one pass (acceptance criteria, Test IDs, the compose or runtime smoke test, container image scans, every scan the quality gate lists) and file every finding now, because a later pass re-verifies only what changed. Record the HEAD commit you verified as ''commit: <sha>'' in review.md frontmatter. If an orchestrator session runs this state, put this paragraph verbatim in the verifier subagent''s handover packet.' }
        if ($st.name -eq 'TEST' -and $ctx.SPEC) {
            $lim = Get-EnvLimits $ctx.SPEC
            if ($lim) { $prompt += ' KNOWN ENVIRONMENT LIMITS (recorded by PREFLIGHT on this machine): ' + $lim + '. Do not attempt what they rule out (no docker build or compose up --build while the registry is unreachable): record each AC and Test ID that needs it as DEFERRED with that reason at once, and spend the time on the checks that can run.' }
        }
        if ($att -gt 0 -and $R.last_violations) { $prompt += ' RETRY ' + ($att + 1) + '/' + $cfgMax + ' - fix these exit-check violations: ' + $R.last_violations }
        elseif ((Test-Force $st.id) -and $R.last_violations) { $prompt += ' A later stage failed and sent this spec back. The open Bug items in the spec Backlog and these violations are the work of this pass; fix them test-first and write only the files they name: ' + $R.last_violations }
        if ($R.note) { $prompt += ' Human note: ' + $R.note; $R.note = '' }
        if ($st.scope -eq 'wave' -and $att -eq 0) { Invoke-Checkpoint 'manual' ('kcc-run: baseline before ' + $label) }
        # One log per dispatch: the first dispatch of a unit keeps the name state-<id>-<unit>-<attempt>.log; when that file exists (a second
        # TEST pass, FIX again after a review) the suffix counts up to the next free number, so no run overwrites an earlier log.
        $logTag = Safe-Name $(if ($ctx.SPEC) { $ctx.SPEC + $(if ($ctx.WAVE) { '-w' + $ctx.WAVE } else { '' }) } else { 'run' })
        $dispatchNo = $att + 1
        while (Test-Path -LiteralPath (Join-Path $LogDir ('state-' + $st.id + '-' + $logTag + '-' + $dispatchNo + '.log'))) { $dispatchNo++ }
        $script:DispatchNo = $dispatchNo
        $log = Join-Path $LogDir ('state-' + $st.id + '-' + $logTag + '-' + $dispatchNo + '.log')
        Say ('kcc-run: run    ' + $label + ' (attempt ' + ($att + 1) + '/' + $cfgMax + ') -> ' + ($log.Substring($RepoRoot.Length).TrimStart('\', '/') -replace '\\', '/'))
        Save-Run
        Refresh-Dashboard
        # Every dispatch records a start and an end with its spec and agent, so the dashboard can show runs that overlap (one agent per spec).
        $arAgent = 'orchestrator'; $arModel = ''; $arEffort = ''; $arTier = ''; $arWhy = ''
        if ($am) { if ($am.agent) { $arAgent = [string]$am.agent }; $arModel = [string]$am.model; $arEffort = [string]$am.effort; $arTier = [string]$am.tier; $arWhy = [string]$am.why }
        $arLog = ($log.Substring($RepoRoot.Length).TrimStart('\', '/') -replace '\\', '/')
        $arT0 = [DateTime]::UtcNow
        [void](Emit 'agent-run-started' $ctx.SPEC ([ordered]@{ state = [int]$st.id; state_name = [string]$st.name; agent = $arAgent; model = $arModel; effort = $arEffort; tier = $arTier; reasons = $arWhy; pass = [string]$script:VmMode; attempt = ($att + 1); dispatch = $dispatchNo; wave = [string]$ctx.WAVE; log = $arLog; started = $arT0.ToString('yyyy-MM-ddTHH:mm:ssZ'); source = 'kcc-run' }))
        $rc = Invoke-Harness $prompt $log
        $script:HarnessExtra = ''
        [void](Emit 'agent-run-ended' $ctx.SPEC ([ordered]@{ state = [int]$st.id; state_name = [string]$st.name; agent = $arAgent; attempt = ($att + 1); dispatch = $dispatchNo; wave = [string]$ctx.WAVE; log = $arLog; exit = [int]$rc; seconds = [int]([DateTime]::UtcNow - $arT0).TotalSeconds; ended = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ'); source = 'kcc-run' }))
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
    # The check output carries the same number as the dispatch log it belongs to (check-<state>_<spec>-<n>-<tool>.out next to state-<id>-<spec>-<n>.log).
    $ckNo = (Get-Att $key) + 1; if ($script:DispatchNo -gt 0) { $ckNo = $script:DispatchNo }
    if ($null -eq $res) { $res = Run-Check $chk $ctx ($key + '-' + $ckNo) }
    # A passing check proves nothing when the state's artifact was never written (a conformance scope with
    # nothing in it passes): precheck_requires is also the state's required output.
    if ($res.rc -eq 0 -and (Has $st 'precheck_requires') -and -not $R.idea) { Detect-Idea; $ctx = New-Ctx $ctx.ENTRY $ctx.WAVE }
    if ($res.rc -eq 0 -and -not (Test-PrecheckReady $st $ctx)) {
        $res = @{ rc = 1; viol = ('REQ-001: state ' + $st.id + ' ' + $st.name + ' finished but did not produce ' + (Render ([string]$st.precheck_requires) $ctx)) }
    }
    if ($res.rc -eq 0) { Complete-Unit $st $ctx $false; return 'next' }
    $R.last_violations = (Sanitize-Prompt (Str $res.viol))
    if ($R.last_violations.Length -gt 1500) { $R.last_violations = $R.last_violations.Substring(0, 1500) + ' ...' }
    if ($res.rc -eq 2) {
        # A silent run does not stop for a check that cannot run: the spec is left as an open item and the rest goes on.
        if ($R.silent -eq '1' -and $ctx.SPEC) { Block-Unit $st $ctx.SPEC 'check-error' ('the exit check returned a usage/environment error: ' + $R.last_violations) (Get-ResumeHint $ctx.SPEC $st) ($(if ($R.last_log) { $R.last_log } else { '' })); return 'goto' }
        Stop-Run 'stopped' ('exit check for ' + $label + ' returned a usage/environment error: ' + $R.last_violations) 6
    }
    # Only blocked bugs are left (the pass fixed the others): they need a human ruling, so no retry and no attempt is used.
    if ($res.blocked -and -not $res.open) { return (Open-RulingGate $st $ctx ([string]$res.blocked)) }
    if ($res.rc -eq 3) {
        # A deferral already accepted for this spec (at TEST, or at the toolchain gate) is not asked again: the spec closes as deferred-accepted.
        # A waiver (REVIEW-004) is a different outcome: it always opens the waiver gate (round 14: a TEST deferral hid SPEC-001's waiver).
        if ($ctx.SPEC -and (Get-Att ('defer:' + $ctx.SPEC)) -gt 0 -and ($R.last_violations -notlike 'REVIEW-004*')) {
            Say ('kcc-run: deferred check for ' + $ctx.SPEC + ' was accepted earlier (not a pass): ' + (Flat $R.last_violations))
            Complete-Unit $st $ctx $false
            return 'next'
        }
        $g = $gname; $q = 'Exit check for ' + $label + ' is DEFERRED (exit 3): a required external tool is missing. This is not a pass.'
        if (-not $g -or $gkind -eq 'approval') { $g = 'quality-deferred-on-exit-3' }
        if ($R.last_violations -like 'REVIEW-004*') {
            $g = 'waiver'
            $q = 'Review of ' + $ctx.SPEC + ': every bug is closed and what still keeps the gate red is outside the code (an environment limit, a stale artifact, a gate tool error, or a check the architecture excluded). This is not a pass. waive (close the spec as WAIVER_NEEDED and go on; record the waiver in review.md -> ## Waivers), recheck (you fixed the environment: run the verification again), or abort?'
        }
        return (Open-Gate $g 'failure' $q $st $ctx $R.last_violations)
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
        if ($waves.Count -eq 0) {
            if ($R.silent -eq '1') { $sid = Get-SpecId (($entry -split '/', 2)[1]); Block-Unit $st $sid 'no-waves' ('plan.md for ' + $entry + ' has no ## Waves table, so there is nothing to implement') (Get-ResumeHint $sid (@{ id = 11; name = 'PLAN' })) ''; return @{ skip = $true } }
            Stop-Run 'stopped' ('plan.md for ' + $entry + ' has no ## Waves table') 6
        }
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
$onlyIdx = -1
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
    # A new run starts a new NeedsAttention.md; the previous one is kept next to it.
    if (-not $DryRun -and (Test-Path -LiteralPath $AttentionFile)) { Move-Item -LiteralPath $AttentionFile -Destination (Join-Path $Coord ('NeedsAttention-' + [DateTime]::UtcNow.ToString('yyyyMMddHHmmss') + '.md')) -Force }
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
        Show-Deferred
        $na = Get-AttentionCounts
        if ($na.open -gt 0) { Show-Attention; Finish 'needs-attention' 7 }
        if ($na.items -gt 0) { Show-Attention }
        Finish 'done' 0
    }
    $u = Resolve-Unit
    if ($null -eq $u) { Stop-Run 'stopped' ('unknown state ' + $R.state) 6 }
    if ($u.skip) { Save-Run; continue }
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
                    Show-Deferred
                    if ((Get-AttentionCounts).items -gt 0) { Show-Attention }
                    Finish 'until-done' 0
                }
            }
        }
        Save-Run
        continue
    }
    Stop-Run 'stopped' ('unexpected unit outcome ' + $out) 6
}
