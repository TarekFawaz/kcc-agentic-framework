<#
KCC framework (c) 2026 Tarek Fawaz, https://tikasway.dev/kcc. Licensed under the terms in LICENSE.

.SYNOPSIS
    Write a KCC restore point (session-continuity protocol). PowerShell port of
    kcc-checkpoint.sh; same fields, ids, and exit codes.

.DESCRIPTION
    Builds coordination/checkpoints/CP-{NNN}.md from disk state only (no model
    input): coordination/orchestrator.json (active_session), the backchannel
    (auto policy, last lifecycle event, spec, wave, loop counters, open human
    gates, events since the previous CP) and the file tree, then copies it to
    coordination/checkpoints/latest.md.
      git repo : lightweight tag kcc/cp-{NNN} on HEAD (never commits/pushes)
      no git   : CP-{NNN}.manifest + latest.manifest (path<TAB>sha256 for
                 src/, specs/, ideation/, architecture/)
    Emits a checkpoint-created backchannel event.
    PowerShell 5.1 compatible, ASCII-only source, UTF-8 (no BOM) LF output.

.PARAMETER Reason
    limit-soft | limit-hard | spec-reviewed | manual (default) | handover

.PARAMETER Harness
    claude | codex | opencode | generic (default: $env:KCC_HARNESS, claude when
    running under Claude Code, else generic)

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .KCC\tools\kcc-checkpoint.ps1 -Reason manual -NextAction "Run state 15 wave 2 for SPEC-003"
#>
[CmdletBinding()]
param(
    [string]$Reason = 'manual',
    [string]$Harness,
    [string]$SessionId,
    [string]$NextAction,
    [switch]$Json,
    [switch]$DryRun,
    [switch]$NoGit,
    [string]$RepoRoot
)

$ErrorActionPreference = 'Stop'
$ToolVersion = '1.0.0'
$Utf8 = New-Object System.Text.UTF8Encoding($false)

function Fail([string]$msg) { [Console]::Error.WriteLine('error: ' + $msg); exit 2 }
function Get-Prop($obj, [string]$name) {
    if ($null -eq $obj) { return $null }
    if ($obj.PSObject.Properties.Name -contains $name) { return $obj.$name }
    return $null
}
function Str($v) { if ($null -eq $v) { return '' } return [string]$v }
function Invoke-KccGit {
    # PS 5.1 turns native stderr into terminating errors under Stop; relax it here.
    $old = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { & git -C $RepoRoot @args 2>$null } finally { $ErrorActionPreference = $old }
}
function Yq([string]$s) { return '"' + ($s -replace '"', "'") + '"' }
function Write-Lf([string]$path, [string]$text) { [System.IO.File]::WriteAllText($path, ($text -replace "`r`n", "`n"), $Utf8) }

if (-not $RepoRoot) {
    $toolDir = $PSScriptRoot
    if (-not $toolDir) { $toolDir = Split-Path -Parent $MyInvocation.MyCommand.Path }
    $RepoRoot = Split-Path -Parent (Split-Path -Parent $toolDir)
}
$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
$validReasons = @('limit-soft', 'limit-hard', 'spec-reviewed', 'manual', 'handover')
if ($validReasons -notcontains $Reason) { Fail '-Reason must be limit-soft|limit-hard|spec-reviewed|manual|handover' }
if (-not $Harness) {
    if ($env:KCC_HARNESS) { $Harness = $env:KCC_HARNESS }
    elseif ($env:CLAUDECODE -or $env:CLAUDE_PROJECT_DIR) { $Harness = 'claude' }
    else { $Harness = 'generic' }
}
if (@('claude', 'codex', 'opencode', 'generic') -notcontains $Harness) { Fail '-Harness must be claude|codex|opencode|generic' }
if (-not (Test-Path -LiteralPath (Join-Path $RepoRoot '.KCC'))) { Fail ('no .KCC workspace at ' + $RepoRoot) }

$coord = Join-Path $RepoRoot 'coordination'
$cpDir = Join-Path $coord 'checkpoints'
$bcPath = Join-Path $coord 'backchannel.jsonl'
$orchPath = Join-Path $coord 'orchestrator.json'
$warnings = New-Object System.Collections.ArrayList
$created = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')

# --- lock + id allocation ------------------------------------------------------
$lock = Join-Path $cpDir '.lock.d'
$haveLock = $false
if (-not $DryRun) {
    if (-not (Test-Path -LiteralPath $cpDir)) { New-Item -ItemType Directory -Path $cpDir | Out-Null }
    for ($t = 0; $t -le 100; $t++) {
        try { New-Item -ItemType Directory -Path $lock -ErrorAction Stop | Out-Null; $haveLock = $true; break } catch {
            $li = Get-Item -LiteralPath $lock -ErrorAction SilentlyContinue
            if ($li -and $li.LastWriteTimeUtc -lt [DateTime]::UtcNow.AddMinutes(-1)) { Remove-Item -LiteralPath $lock -Recurse -Force -ErrorAction SilentlyContinue; continue }
            Start-Sleep -Milliseconds 100
        }
    }
    if (-not $haveLock) { Fail ('checkpoint lock busy: ' + $lock) }
}

try {
$max = 0
if (Test-Path -LiteralPath $cpDir) {
    foreach ($f in Get-ChildItem -LiteralPath $cpDir -Filter 'CP-*.md' -File) {
        if ($f.Name -match '^CP-(\d+)\.md$') { $n = [int]$Matches[1]; if ($n -gt $max) { $max = $n } }
    }
}
$cpId = 'CP-{0:D3}' -f ($max + 1)
$prevId = ''
if ($max -gt 0) { $prevId = 'CP-{0:D3}' -f $max }
$cpRel = "coordination/checkpoints/$cpId.md"

# --- previous restore point ----------------------------------------------------
function Get-FrontMatter([string]$path) {
    $fm = @{}
    if (-not $path -or -not (Test-Path -LiteralPath $path)) { return $fm }
    $lines = Get-Content -LiteralPath $path -Encoding UTF8
    if ($lines.Count -eq 0 -or $lines[0] -ne '---') { return $fm }
    for ($i = 1; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -eq '---') { break }
        if ($lines[$i] -match '^([A-Za-z_]+):\s*(.*)$') { $fm[$Matches[1]] = ($Matches[2] -replace '^"', '' -replace '"$', '') }
    }
    return $fm
}
$prevFile = ''
if ($prevId) { $prevFile = Join-Path $cpDir "$prevId.md" }
$prevFm = Get-FrontMatter $prevFile
$prevLastEvent = Str $prevFm['last_event_id']
$prevNext = Str $prevFm['next_action']
$prevNextSrc = Str $prevFm['next_action_source']
$prevLastNum = 0
if ($prevLastEvent -match '^BC-(\d+)$') { $prevLastNum = [int]$Matches[1] }

# --- session id + trace session ------------------------------------------------
if (-not $SessionId -and $env:KCC_SESSION_ID) { $SessionId = $env:KCC_SESSION_ID }
$usagePath = Join-Path $coord 'usage.json'
if (-not $SessionId -and $Harness -eq 'claude' -and (Test-Path -LiteralPath $usagePath)) {
    try { $SessionId = Str (Get-Prop (Get-Content -LiteralPath $usagePath -Raw | ConvertFrom-Json) 'session_id') } catch { }
}
$traceSession = ''; $traceSessionId = ''
if (Test-Path -LiteralPath $orchPath) {
    $orchText = Get-Content -LiteralPath $orchPath -Raw
    if ($orchText -match '"active_session"\s*:\s*"([^"]*)"') { $traceSession = $Matches[1] }
    if ($orchText -match '"active_session_id"\s*:\s*"([^"]*)"') { $traceSessionId = $Matches[1] }
} else { [void]$warnings.Add('CP-W-ORCH: coordination/orchestrator.json not found') }
if (-not $traceSession) { [void]$warnings.Add('CP-W-TRACE: no active_session pointer in coordination/orchestrator.json') }

# --- backchannel analysis ------------------------------------------------------
$skip = @('checkpoint-created', 'limit-reached', 'resume-scheduled', 'resume-started', 'handover-issued', 'handover-accepted', 'brief-issued', 'remember-stored', 'calibration-update', 'calibration-drift', 'coordination-note', 'trace-session-created', 'actual-recorded', 'human-gate-triggered', 'human-gate-resolved', 'human-gate-decision')
$lastId = ''; $lastKind = ''; $lastKindId = ''; $lastSpec = ''; $scenario = ''; $policy = ''; $policyId = ''
$wave = ''; $state = ''; $verdict = ''; $newLife = 0
$cnt = @{}
$gates = New-Object System.Collections.ArrayList
$resolved = @{}
$done = New-Object System.Collections.ArrayList
$arts = New-Object System.Collections.ArrayList
if ((Test-Path -LiteralPath $bcPath) -and (Get-Item -LiteralPath $bcPath).Length -gt 0) {
    foreach ($line in (Get-Content -LiteralPath $bcPath -Tail 500 -Encoding UTF8)) {
        if ($line -notmatch '^\s*\{') { continue }
        try { $ev = $line | ConvertFrom-Json } catch { continue }
        $id = Str (Get-Prop $ev 'id'); if ($id -notmatch '^BC-(\d+)$') { continue }
        $n = [int]$Matches[1]; $kind = Str (Get-Prop $ev 'kind'); $pl = Get-Prop $ev 'payload'
        $spec = Str (Get-Prop $ev 'spec'); if (-not $spec) { $spec = Str (Get-Prop $pl 'spec_id') }
        $lastId = $id
        if ($n -gt $prevLastNum -and ($skip -notcontains $kind)) { $newLife++ }
        if ($n -gt $prevLastNum) {
            $d = "$id  $kind"; if ($spec) { $d += "  $spec" }
            [void]$done.Add($d)
            $ap = Str (Get-Prop $pl 'artifact_path'); if ($ap -and ($arts -notcontains $ap)) { [void]$arts.Add($ap) }
            foreach ($a in @(Get-Prop $pl 'artifact_paths')) { if ($a -and ($arts -notcontains [string]$a)) { [void]$arts.Add([string]$a) } }
        }
        if ($kind -eq 'auto-policy-parsed') { $scenario = Str (Get-Prop $pl 'scenario'); $policy = ($pl | ConvertTo-Json -Depth 10 -Compress); $policyId = $id; $cnt = @{}; $wave = ''; $state = '' }
        if ($kind -eq 'human-gate-triggered') {
            [void]$gates.Add([pscustomobject]@{ id = $id; gate = Str (Get-Prop $pl 'gate'); agent = Str (Get-Prop $pl 'agent'); conf = Str (Get-Prop $pl 'confidence_pct'); reason = Str (Get-Prop $pl 'reason'); prop = Str (Get-Prop $pl 'proposed_next_action'); spec = $spec })
        }
        if ($kind -eq 'human-gate-resolved' -or $kind -eq 'human-gate-decision') {
            $t = Str (Get-Prop $pl 'trigger_event_id')
            if ($t) { $resolved[$t] = $true }
            elseif ($kind -eq 'human-gate-resolved' -or (Str (Get-Prop $pl 'gate')) -eq 'confidence') {
                for ($i = $gates.Count - 1; $i -ge 0; $i--) { if (-not $resolved.ContainsKey($gates[$i].id)) { $resolved[$gates[$i].id] = $true; break } }
            }
        }
        $w = Str (Get-Prop $pl 'wave'); if ($w) { $wave = $w }
        $s = Str (Get-Prop $pl 'state'); if ($s) { $state = $s }
        if ($cnt.ContainsKey($kind)) { $cnt[$kind]++ } else { $cnt[$kind] = 1 }
        if ($skip -notcontains $kind) {
            $lastKind = $kind; $lastKindId = $id
            if ($spec) { $lastSpec = $spec }
            if ($kind -match '^test-(completed|verdict)$') { $verdict = ((Str (Get-Prop $pl 'verdict')) + (Str (Get-Prop $pl 'status')) + (Str (Get-Prop $pl 'result'))).ToLowerInvariant() }
        }
    }
} else { [void]$warnings.Add('CP-W-BC: coordination/backchannel.jsonl is missing or empty') }

$loops = @()
foreach ($k in @('implement-started', 'implement-completed', 'test-started', 'test-completed', 'review-produced', 'human-gate-decision', 'self-heal-attempt', 'loop-iteration')) {
    if ($cnt.ContainsKey($k) -and $cnt[$k] -gt 0) { $loops += ('{0}={1}' -f $k, $cnt[$k]) }
}
$loopsText = $loops -join ', '
$stage = ''
if ($lastKind -match '^idea-interrogation') { $stage = 'interrogate' }
elseif ($lastKind -match 'brief|architecture-pass') { $stage = 'create' }
elseif ($lastKind -match '^estimate|^auto-policy') { $stage = 'token-budget' }
elseif ($lastKind -eq 'spec-created') { $stage = 'create' }
elseif ($lastKind -match '^plan') { $stage = 'plan' }
elseif ($lastKind -match '^implement|^toolchain') { $stage = 'implement' }
elseif ($lastKind -match '^test') { $stage = 'test' }
elseif ($lastKind -match '^review|^session-closed') { $stage = 'review' }

$openGates = @($gates | Where-Object { -not $resolved.ContainsKey($_.id) })
$sp = ''; if ($lastSpec) { $sp = " for $lastSpec" }
$waveText = ''; if ($wave) { $waveText = " wave $wave" }
if ($openGates.Count -gt 0) {
    $g0 = $openGates[0]; $who = ''; if ($g0.agent) { $who = $g0.agent + ': ' }
    $derived = "Resolve open human gate $($g0.id) ($who$($g0.reason)) via /critical-human-gate, then continue auto$sp"
}
elseif (-not $lastKind) { $derived = 'No lifecycle events recorded; start or re-run auto from its first state' }
elseif ($lastKind -eq 'auto-policy-parsed') { $derived = "Continue auto at idea interrogation (policy $policyId parsed, scenario $scenario)" }
elseif ($lastKind -eq 'idea-interrogation-started') { $derived = "Finish idea interrogation$sp" }
elseif ($lastKind -eq 'idea-interrogation-completed') { $derived = "Run the specialist interrogations and architecture pass$sp" }
elseif ($lastKind -match 'brief') { $derived = "Continue the specialist briefs, then run the architecture pass$sp" }
elseif ($lastKind -match '^architecture-pass') { $derived = "Run the token-budget estimate, then spec creation$sp" }
elseif ($lastKind -eq 'estimate-issued') { $derived = "Resolve the token-budget decision (approve/abort or AutoPolicy)$sp" }
elseif ($lastKind -match '^estimate-|^auto-policy-approved') { $derived = "Continue auto after the approved token budget$sp" }
elseif ($lastKind -eq 'spec-created') { $derived = "Run token-budget and /spec-plan$sp" }
elseif ($lastKind -eq 'plan-created') { $derived = "Run toolchain preflight, then /spec-implement wave 1$sp" }
elseif ($lastKind -match '^toolchain') { $derived = "Continue /spec-implement after the toolchain preflight$sp" }
elseif ($lastKind -eq 'implement-started') { $derived = "Finish /spec-implement$waveText$sp (implement-started $lastKindId has no implement-completed)" }
elseif ($lastKind -match '^implement-complete') { $wt = ' the last one'; if ($wave) { $wt = " wave $wave" }; $derived = "Run the next implementation wave after$wt$sp, or /spec-test when all waves are done" }
elseif ($lastKind -eq 'test-started') { $derived = "Re-run /spec-test$sp (test-started $lastKindId has no test-completed)" }
elseif ($lastKind -match '^test-(completed|verdict)$') { if ($verdict -match 'fail') { $derived = "Self-heal the failing tests$sp, then re-run /spec-test" } else { $derived = "Run /spec-review$sp" } }
elseif ($lastKind -eq 'review-produced') { $derived = 'Close the run (butler-remember, session-closed) or continue with the next spec' }
elseif ($lastKind -eq 'session-closed') { $derived = 'Run is closed; nothing pending' }
else { $derived = "Resume auto after $lastKind ($lastKindId)$sp" }

$nextSrc = 'argument'
if (-not $NextAction) {
    if ($newLife -eq 0 -and $prevNext) { $NextAction = $prevNext; $nextSrc = $prevNextSrc; if (-not $nextSrc) { $nextSrc = 'previous' } }
    else { $NextAction = $derived; $nextSrc = 'derived' }
}
$NextAction = ($NextAction -replace "[`r`n]+", ' ')
$resumePrompt = 'Read coordination/checkpoints/latest.md and continue the KCC run from next_action.'

# --- git or manifest -------------------------------------------------------------
$gitMode = 'manifest'; $gitHead = ''; $gitTag = ''; $changes = New-Object System.Collections.ArrayList
$isGit = $false
if (-not $NoGit -and (Get-Command git -ErrorAction SilentlyContinue)) {
    $null = Invoke-KccGit rev-parse --is-inside-work-tree 2>$null
    if ($LASTEXITCODE -eq 0) { $isGit = $true }
}
$manifestText = ''
if ($isGit) {
    $gitMode = 'git'
    $gitHead = Str (Invoke-KccGit rev-parse HEAD 2>$null)
    if ($LASTEXITCODE -ne 0) { $gitHead = '' }
    $gitTag = 'kcc/cp-' + $cpId.Substring(3)
    $prevTag = ''
    if ($prevId) { $prevTag = 'kcc/cp-' + $prevId.Substring(3); $null = Invoke-KccGit rev-parse -q --verify "refs/tags/$prevTag" 2>$null; if ($LASTEXITCODE -ne 0) { $prevTag = '' } }
    if ($prevTag) {
        foreach ($l in @(Invoke-KccGit diff --name-status $prevTag -- 2>$null)) { $p = $l -split "`t"; [void]$changes.Add(@($p[0], $p[-1])) }
        foreach ($l in @(Invoke-KccGit ls-files --others --exclude-standard 2>$null)) { [void]$changes.Add(@('?', $l)) }
    } else {
        foreach ($l in @(Invoke-KccGit status --porcelain 2>$null)) { if ($l.Length -gt 3) { [void]$changes.Add(@($l.Substring(0, 2).Trim(), $l.Substring(3))) } }
    }
    $changes = [System.Collections.ArrayList]@($changes | Where-Object { $_[1] -notmatch '^coordination/' })
    if (-not $gitHead) { [void]$warnings.Add('CP-W-GIT: repository has no commits; tag skipped'); $gitTag = '' }
} else {
    $excluded = @('node_modules', '.git', '.venv', 'venv', '__pycache__', 'bin', 'obj', 'dist', '.next', 'target')
    $entries = New-Object System.Collections.Generic.List[string]
    foreach ($d in @('src', 'specs', 'ideation', 'architecture')) {
        $full = Join-Path $RepoRoot $d
        if (-not (Test-Path -LiteralPath $full)) { continue }
        foreach ($file in Get-ChildItem -LiteralPath $full -Recurse -File -Force -ErrorAction SilentlyContinue) {
            $rel = $file.FullName.Substring($RepoRoot.Length).TrimStart('\', '/') -replace '\\', '/'
            $segs = $rel -split '/'
            $skipIt = $false
            for ($i = 0; $i -lt $segs.Count - 1; $i++) { if ($excluded -contains $segs[$i]) { $skipIt = $true; break } }
            if ($skipIt) { continue }
            $h = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
            $entries.Add($rel + "`t" + $h)
        }
    }
    $arr = $entries.ToArray()
    [Array]::Sort($arr, [System.StringComparer]::Ordinal)
    $manifestText = ''
    if ($arr.Count -gt 0) { $manifestText = ($arr -join "`n") + "`n" }
    $prevMan = Join-Path $cpDir 'latest.manifest'
    $old = @{}
    if (Test-Path -LiteralPath $prevMan) {
        foreach ($l in Get-Content -LiteralPath $prevMan -Encoding UTF8) { $p = $l -split "`t"; if ($p.Count -ge 2) { $old[$p[0]] = $p[1] } }
    }
    $seen = @{}
    foreach ($e in $arr) {
        $p = $e -split "`t"; $seen[$p[0]] = $true
        if (-not $old.ContainsKey($p[0])) { [void]$changes.Add(@('A', $p[0])) } elseif ($old[$p[0]] -ne $p[1]) { [void]$changes.Add(@('M', $p[0])) }
    }
    foreach ($k in $old.Keys) { if (-not $seen.ContainsKey($k)) { [void]$changes.Add(@('D', $k)) } }
    $changes = [System.Collections.ArrayList]@($changes | Sort-Object { $_[1] })
}
$changeCount = [Math]::Min($changes.Count, 200)

# --- render ------------------------------------------------------------------------
$gateLines = @()
foreach ($g in $openGates) {
    $gn = $g.gate; if (-not $gn) { $gn = 'confidence' }
    $gateLines += ('- {0}  gate={1} agent={2} confidence={3}  reason: {4}  proposed: {5}  spec: {6}  | allowed answers: approve / revise / escalate / abort' -f $g.id, $gn, $(if ($g.agent) { $g.agent } else { '?' }), $(if ($g.conf) { $g.conf } else { '?' }), $(if ($g.reason) { $g.reason } else { '?' }), $(if ($g.prop) { $g.prop } else { '?' }), $(if ($g.spec) { $g.spec } else { '?' }))
}
$doneLines = @($done | ForEach-Object { '- ' + $_ })
if ($doneLines.Count -gt 40) { $omit = $doneLines.Count - 40; $doneLines = @("- ... $omit earlier events omitted") + $doneLines[($doneLines.Count - 40)..($doneLines.Count - 1)] }
$artLines = @($arts | Select-Object -First 40 | ForEach-Object { '- ' + $_ })
$chLines = @($changes | Select-Object -First 60 | ForEach-Object { '- ' + $_[0] + ' ' + $_[1] })
if ($changes.Count -gt 60) { $chLines += ('- ... {0} more' -f ($changes.Count - 60)) }
if (-not $policy) { $policy = '{}' }

function Or([string]$v, [string]$d) { if ($v) { return $v } return $d }
$L = New-Object System.Collections.Generic.List[string]
$L.Add('---'); $L.Add("id: $cpId"); $L.Add("created: $created"); $L.Add("reason: $Reason"); $L.Add("harness: $Harness")
$L.Add('session_id: ' + (Yq $SessionId)); $L.Add('trace_session: ' + (Yq $traceSession)); $L.Add('spec: ' + (Yq $lastSpec)); $L.Add('stage: ' + (Yq $stage))
$L.Add('previous: ' + (Yq $prevId)); $L.Add('last_event_id: ' + (Yq $lastId)); $L.Add("open_gates: $($openGates.Count)"); $L.Add("git_mode: $gitMode")
$L.Add('git_head: ' + (Yq $gitHead)); $L.Add('git_tag: ' + (Yq $gitTag)); $L.Add('next_action: ' + (Yq $NextAction)); $L.Add("next_action_source: $nextSrc")
$L.Add('resume_prompt: ' + (Yq $resumePrompt)); $L.Add('tags:'); $L.Add('  - kcc/checkpoint'); $L.Add('---'); $L.Add('')
$L.Add("# Restore point $cpId"); $L.Add(''); $L.Add('## Envelope ID'); $L.Add(''); $L.Add("$cpId ($Reason, $created)"); $L.Add('')
$L.Add('## Spec reference'); $L.Add(''); $L.Add((Or $lastSpec 'none recorded in the backchannel')); $L.Add('')
$L.Add('## From'); $L.Add(''); $L.Add("- harness: $Harness"); $L.Add('- session_id: ' + (Or $SessionId 'unknown')); $L.Add("- reason: $Reason"); $L.Add('')
$L.Add('## To'); $L.Add(''); $L.Add('Any KCC harness resuming this run (claude reads CLAUDE.md, codex/opencode/generic read AGENTS.md).'); $L.Add('')
$L.Add('## Lifecycle stage'); $L.Add(''); $L.Add((Or $stage 'unknown') + ' (last lifecycle event: ' + (Or $lastKind 'none') + ' ' + $lastKindId + ')'); $L.Add('')
$L.Add('## Input context'); $L.Add(''); $L.Add('- coordination/orchestrator.json (agent profiles, active_session)')
$L.Add('- coordination/backchannel.jsonl (events after ' + (Or $prevLastEvent 'the start') + ')')
$L.Add('- ' + (Or $traceSession 'Traces/ (no active session pointer)')); $L.Add('- .KCC/settings.json (continuity, auto policy defaults)')
if ($prevId) { $L.Add("- coordination/checkpoints/$prevId.md (previous restore point)") }
if ($gitMode -eq 'manifest') { $L.Add("- coordination/checkpoints/$cpId.manifest") }
$L.Add(''); $L.Add('## Output / deliverable'); $L.Add(''); $L.Add('### auto'); $L.Add('')
$L.Add('- scenario: ' + (Or $scenario 'unknown')); $L.Add('- policy_event: ' + (Or $policyId 'none')); $L.Add('- policy: `' + $policy + '`')
$L.Add('- state: ' + (Or $state (Or $lastKind 'unknown'))); $L.Add('- spec: ' + (Or $lastSpec 'none')); $L.Add('- wave: ' + (Or $wave 'none')); $L.Add('- loop_counters: ' + (Or $loopsText 'none')); $L.Add('')
$tsText = Or $traceSession 'none'; if ($traceSessionId) { $tsText += " (id $traceSessionId)" }
$L.Add('### trace_session'); $L.Add(''); $L.Add($tsText); $L.Add('')
$L.Add('### open_gates'); $L.Add(''); if ($gateLines.Count -gt 0) { foreach ($x in $gateLines) { $L.Add($x) } } else { $L.Add('none') }; $L.Add('')
$L.Add('### done_since_last'); $L.Add(''); $L.Add('Events since ' + (Or $prevId 'the start of the log') + " ($($done.Count)):"); $L.Add('')
if ($doneLines.Count -gt 0) { foreach ($x in $doneLines) { $L.Add($x) } } else { $L.Add('- none') }; $L.Add('')
$L.Add('Artifacts named by those events:'); $L.Add(''); if ($artLines.Count -gt 0) { foreach ($x in $artLines) { $L.Add($x) } } else { $L.Add('- none') }; $L.Add('')
$L.Add('Files changed since ' + (Or $prevId 'the first restore point') + " ($changeCount, A=added M=modified D=deleted ?=untracked):"); $L.Add('')
if ($chLines.Count -gt 0) { foreach ($x in $chLines) { $L.Add($x) } } else { $L.Add('- none') }; $L.Add('')
$L.Add('### git'); $L.Add(''); $L.Add("- mode: $gitMode"); $L.Add('- head: ' + (Or $gitHead 'n/a')); $L.Add('- tag: ' + (Or $gitTag 'n/a'))
if ($gitMode -eq 'manifest') { $L.Add("- manifest: coordination/checkpoints/$cpId.manifest (path<TAB>sha256 of src/, specs/, ideation/, architecture/)") }
$L.Add(''); $L.Add('## Ask'); $L.Add(''); $L.Add("next_action: $NextAction"); $L.Add('')
$L.Add('## Constraints / non-goals'); $L.Add('')
$L.Add('- Do not redo work listed under done_since_last; verify it on disk instead.')
$L.Add('- Resolve every open gate with the human (or a covering AutoPolicy) before continuing.')
$L.Add('- Never use a permission-bypass mode; unattended runs use continuity.permission_mode.')
$L.Add('- Read the paths above; this file carries paths, not file contents.'); $L.Add('')
$L.Add('## resume_prompt'); $L.Add(''); $L.Add($resumePrompt)
$content = ($L -join "`n") + "`n"

$tagOk = $false
if (-not $DryRun) {
    Write-Lf (Join-Path $cpDir "$cpId.md") $content
    $latest = $content -replace '^---\n', ("---`npoints_to: $cpId`n")
    $latestTmp = Join-Path $cpDir 'latest.md.tmp'
    Write-Lf $latestTmp $latest
    Move-Item -LiteralPath $latestTmp -Destination (Join-Path $cpDir 'latest.md') -Force
    if ($gitMode -eq 'manifest') {
        Write-Lf (Join-Path $cpDir "$cpId.manifest") $manifestText
        Write-Lf (Join-Path $cpDir 'latest.manifest') $manifestText
    } elseif ($gitTag) {
        $null = Invoke-KccGit tag $gitTag 2>$null
        if ($LASTEXITCODE -eq 0) { $tagOk = $true } else { [void]$warnings.Add("CP-W-TAG: could not create tag $gitTag") }
    }
    $payload = [ordered]@{ cp_id = $cpId; reason = $Reason; harness = $Harness; path = $cpRel; git_mode = $gitMode; open_gates = $openGates.Count; next_action = $NextAction } | ConvertTo-Json -Compress
    $bcTool = Join-Path $PSScriptRoot 'backchannel-append.ps1'
    if (Test-Path -LiteralPath $bcTool) {
        try { & $bcTool -Kind checkpoint-created -From kcc-checkpoint -Spec $lastSpec -Session $SessionId -Payload $payload -RepoRoot $RepoRoot -NoDashboard | Out-Null }
        catch { [void]$warnings.Add('CP-W-EMIT: backchannel-append failed') }
    }
}
} finally {
    if ($haveLock) { Remove-Item -LiteralPath $lock -Recurse -Force -ErrorAction SilentlyContinue }
}

if ($Json) {
    $viol = @()
    foreach ($w in $warnings) {
        $parts = $w -split ': ', 2
        $viol += [ordered]@{ id = $parts[0]; severity = 'warning'; fix_owner = 'human'; file = $null; message = $parts[1] }
    }
    function NullIf([string]$v) { if ($v) { return $v } return $null }
    $out = [ordered]@{
        tool = 'kcc-checkpoint'; version = $ToolVersion; scope = 'all'; errors = 0; warnings = $warnings.Count; status = 'pass'
        dry_run = [bool]$DryRun; violations = $viol
        checkpoint = [ordered]@{
            id = $cpId; path = $cpRel; latest = 'coordination/checkpoints/latest.md'; reason = $Reason; harness = $Harness
            session_id = (NullIf $SessionId); trace_session = (NullIf $traceSession); spec = (NullIf $lastSpec); stage = (NullIf $stage)
            open_gates = $openGates.Count; done_since_last = $done.Count; files_changed = $changeCount; git_mode = $gitMode
            git_tag = (NullIf $gitTag); next_action = $NextAction; resume_prompt = $resumePrompt
        }
    }
    Write-Output ($out | ConvertTo-Json -Depth 6 -Compress)
} else {
    if ($DryRun) { Write-Output "[dry-run] would write $cpRel (reason $Reason, harness $Harness, git_mode $gitMode)" }
    else {
        $tagNote = ''; if ($gitTag) { $tagNote = ", tag $gitTag" }
        Write-Output "$cpId written: $cpRel (reason $Reason, harness $Harness, git_mode $gitMode$tagNote)"
    }
    Write-Output "next_action: $NextAction"
    foreach ($w in $warnings) { Write-Output "warning: $w" }
    Write-Output ('Errors: 0  Warnings: {0}' -f $warnings.Count)
}
exit 0
