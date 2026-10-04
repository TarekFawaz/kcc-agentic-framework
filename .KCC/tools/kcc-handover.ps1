<#
KCC framework (c) 2026 Tarek Fawaz, https://tikasway.dev/kcc. Licensed under the terms in LICENSE.

.SYNOPSIS
    Hand a running KCC session to another harness (PowerShell port of
    kcc-handover.sh; same envelope, ids, events, and exit codes).

.DESCRIPTION
    1. writes a fresh restore point (kcc-checkpoint -Reason handover)
    2. writes coordination/handover/HO-{NNN}.md: handover envelope with the
       target entrypoint (CLAUDE.md / AGENTS.md) and the paths to read (never
       file contents), plus next_action
    3. makes sure the target harness adapter outputs exist (runs
       sync-adapters -Harness <target> only when they are missing)
    4. prints the launch command, or runs it with -Launch:
         -Unattended : continuity.resume[target] (with -SessionId) or
                       continuity.start[target] from .KCC/settings.json
         interactive : the harness binary with the prompt
       prompt = "Read coordination/handover/HO-{NNN}.md and continue"
    5. emits handover-issued
    Never adds a permission-bypass flag. PowerShell 5.1 compatible, ASCII-only.
    Exit: 0 ok (a missing launch command is a warning), 1 -Launch with no
    launch command for the target, 2 usage/environment error.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .KCC\tools\kcc-handover.ps1 -To codex -DryRun
#>
[CmdletBinding()]
param(
    [string]$To,
    [string]$From,
    [string]$SessionId,
    [switch]$Launch,
    [switch]$Unattended,
    [switch]$Json,
    [switch]$DryRun,
    [string]$RepoRoot
)

$ErrorActionPreference = 'Stop'
$ToolVersion = '1.0.0'
$Utf8 = New-Object System.Text.UTF8Encoding($false)
$harnesses = @('claude', 'codex', 'opencode', 'generic')

function Fail([string]$msg) { [Console]::Error.WriteLine('error: ' + $msg); exit 2 }
if ($harnesses -notcontains $To) { Fail '-To must be claude|codex|opencode|generic' }
if (-not $From) {
    if ($env:KCC_HARNESS) { $From = $env:KCC_HARNESS }
    elseif ($env:CLAUDECODE -or $env:CLAUDE_PROJECT_DIR) { $From = 'claude' }
    else { $From = 'generic' }
}
if ($harnesses -notcontains $From) { Fail '-From must be claude|codex|opencode|generic' }
if (-not $RepoRoot) {
    $toolDir = $PSScriptRoot
    if (-not $toolDir) { $toolDir = Split-Path -Parent $MyInvocation.MyCommand.Path }
    $RepoRoot = Split-Path -Parent (Split-Path -Parent $toolDir)
}
$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
if (-not (Test-Path -LiteralPath (Join-Path $RepoRoot '.KCC'))) { Fail ('no .KCC workspace at ' + $RepoRoot) }

$coord = Join-Path $RepoRoot 'coordination'
$hoDir = Join-Path $coord 'handover'
$warnings = New-Object System.Collections.ArrayList
$created = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
$today = $created.Substring(0, 10)
$psExe = (Get-Process -Id $PID).Path
$onWindows = $true
if ($null -ne (Get-Variable -Name IsWindows -ErrorAction SilentlyContinue)) { $onWindows = [bool]$IsWindows }

# ---- 1. restore point ---------------------------------------------------------------
$cpArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $PSScriptRoot 'kcc-checkpoint.ps1'), '-Reason', 'handover', '-Harness', $From, '-Json', '-RepoRoot', $RepoRoot)
if ($DryRun) { $cpArgs += '-DryRun' }
$cpOut = (& $psExe @cpArgs | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -or -not $cpOut) { Fail 'kcc-checkpoint failed' }
$cp = ($cpOut | ConvertFrom-Json).checkpoint
function S($v) { if ($null -eq $v) { return '' } return [string]$v }
$cpId = S $cp.id; $cpPath = S $cp.path; $nextAction = S $cp.next_action; $spec = S $cp.spec; $stage = S $cp.stage
$trace = S $cp.trace_session; $openGates = S $cp.open_gates; $fromSid = S $cp.session_id

# ---- 2. envelope id ------------------------------------------------------------------------
$max = 0
if (Test-Path -LiteralPath $hoDir) {
    foreach ($f in Get-ChildItem -LiteralPath $hoDir -Filter 'HO-*.md' -File) { if ($f.Name -match '^HO-(\d+)\.md$') { $n = [int]$Matches[1]; if ($n -gt $max) { $max = $n } } }
}
$hoId = 'HO-{0:D3}' -f ($max + 1)
$hoRel = "coordination/handover/$hoId.md"
$prompt = "Read $hoRel and continue"
$entry = 'AGENTS.md'; if ($To -eq 'claude') { $entry = 'CLAUDE.md' }

# ---- 3. adapter outputs ------------------------------------------------------------------------
$needed = @{
    claude   = @('.claude/agents', '.claude/skills', 'CLAUDE.md')
    codex    = @('.codex/agents', '.codex/skills', 'AGENTS.md')
    opencode = @('.opencode/agents', '.opencode/commands', 'AGENTS.md')
    generic  = @('.agents/agents', '.agents/skills', '.agents/manifest.json')
}[$To]
function Get-Missing { return @($needed | Where-Object { -not (Test-Path -LiteralPath (Join-Path $RepoRoot $_)) }) }
$missing = Get-Missing
$adapters = 'present'
if ($missing.Count -gt 0) {
    if ($DryRun) { $adapters = 'would-sync' }
    else {
        $syncRc = 0
        try {
            $old = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
            & $psExe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'sync-adapters.ps1') -Harness $To -RepoRoot $RepoRoot *> $null
            $syncRc = $LASTEXITCODE
        } catch { $syncRc = 1 } finally { $ErrorActionPreference = $old }
        $still = Get-Missing
        if ($still.Count -eq 0) {
            $adapters = 'synced'
            if ($syncRc -ne 0) { [void]$warnings.Add("HO-W-SYNC-RC: sync-adapters -Harness $To exited $syncRc but the adapter outputs now exist") }
        } else {
            $adapters = 'sync-failed'
            [void]$warnings.Add("HO-W-SYNC: sync-adapters -Harness $To did not create: $($still -join ' '); run it manually")
        }
    }
}
if (-not (Test-Path -LiteralPath (Join-Path $RepoRoot $entry))) { [void]$warnings.Add("HO-W-ENTRY: target entrypoint $entry does not exist yet (framework-init/sync-adapters creates it)") }

# ---- 4. command ----------------------------------------------------------------------------------
$perm = 'acceptEdits'; $tplResume = ''; $tplStart = ''
$settingsPath = Join-Path $RepoRoot '.KCC\settings.json'
if (Test-Path -LiteralPath $settingsPath) {
    try {
        $c = (Get-Content -LiteralPath $settingsPath -Raw | ConvertFrom-Json).continuity
        if ($c.permission_mode) { $perm = [string]$c.permission_mode }
        if ($c.resume -and $c.resume.$To) { $tplResume = [string]$c.resume.$To }
        if ($c.start -and $c.start.$To) { $tplStart = [string]$c.start.$To }
    } catch { }
}
$perm = $perm -replace '[^A-Za-z]', ''
if (-not $perm -or $perm -eq 'bypassPermissions') { $perm = 'acceptEdits' }
$sid = $SessionId -replace '[^A-Za-z0-9._:-]', ''
$command = ''
if ($Unattended) {
    $tpl = $tplStart; if ($sid -and $tplResume) { $tpl = $tplResume }
    if ($tpl) { $command = $tpl.Replace('{session_id}', $sid).Replace('{permission_mode}', $perm).Replace('{resume_prompt}', $prompt) }
} else {
    switch ($To) {
        'claude' { $command = "claude `"$prompt`"" }
        'codex' { $command = "codex `"$prompt`"" }
        'opencode' { $command = "opencode --prompt `"$prompt`"" }
        default { $command = '' }
    }
}
$lc = $command.ToLowerInvariant()
if ($lc.Contains('dangerously-skip-permissions') -or $lc.Contains('bypasspermissions') -or $lc.Contains('dangerously-bypass-approvals') -or $lc.Contains('--yolo')) { Fail "refusing a launch command with a permission-bypass flag: $command" }
if (-not $command) { [void]$warnings.Add("HO-W-CMD: no launch command for $To (configure continuity.start.$To in .KCC/settings.json); open the harness and paste: $prompt") }

# ---- envelope -------------------------------------------------------------------------------------
function Or([string]$v, [string]$d) { if ($v) { return $v } return $d }
$L = New-Object System.Collections.Generic.List[string]
$L.Add('---'); $L.Add("id: $hoId"); $L.Add("created: $created"); $L.Add("from: $From"); $L.Add("to: $To"); $L.Add("entrypoint: $entry")
$L.Add("checkpoint: $cpPath"); $L.Add('next_action: "' + ($nextAction -replace '"', "'") + '"'); $L.Add('prompt: "' + $prompt + '"'); $L.Add('tags:'); $L.Add('  - kcc/handover'); $L.Add('---'); $L.Add('')
$L.Add("# Handover $hoId ($From -> $To)"); $L.Add('')
$L.Add('## Envelope ID'); $L.Add(''); $L.Add("HANDOVER-$today-$($hoId.Substring(3)) ($hoId)"); $L.Add('')
$L.Add('## Spec reference'); $L.Add(''); $L.Add((Or $spec 'none recorded')); $L.Add('')
$L.Add('## From'); $L.Add(''); $L.Add('- role: orchestrator (auto)'); $L.Add("- harness: $From"); $L.Add('- session_id: ' + (Or $fromSid 'unknown')); $L.Add('')
$L.Add('## To'); $L.Add(''); $L.Add('- role: orchestrator (auto)'); $L.Add("- harness: $To"); $L.Add("- entrypoint: $entry"); $L.Add("- agent profiles: resolved from coordination/orchestrator.json for $To (model + effort)"); $L.Add('')
$L.Add('## Lifecycle stage'); $L.Add(''); $L.Add((Or $stage 'unknown')); $L.Add('')
$L.Add('## Input context'); $L.Add(''); $L.Add('Read these paths (contents are intentionally not copied here):'); $L.Add('')
$L.Add("- $entry"); $L.Add("- $cpPath (restore point; also coordination/checkpoints/latest.md)"); $L.Add('- coordination/orchestrator.json'); $L.Add('- coordination/backchannel.jsonl')
$L.Add('- ' + (Or $trace 'Traces/ (no active session pointer)')); $L.Add('- .KCC/settings.json'); $L.Add('')
$L.Add('## Output / deliverable'); $L.Add(''); $L.Add("Restore point $cpId (reason handover). Open gates: " + (Or $openGates '0') + '.'); $L.Add('')
$L.Add('## Ask'); $L.Add(''); $L.Add("Resume the KCC auto run at next_action: $nextAction"); $L.Add('Emit handover-accepted (backchannel-append) once you have read this envelope.'); $L.Add('')
$L.Add('## Constraints / non-goals'); $L.Add('')
$L.Add("- Do not redo work recorded in the restore point's done_since_last."); $L.Add('- Resolve open human gates before continuing.')
$L.Add('- Continue the same trace session and backchannel; do not start new ones.'); $L.Add('- Never use a permission-bypass mode.'); $L.Add('')
$L.Add('## Human notes'); $L.Add(''); $L.Add('Launch: ' + (Or $command "none configured; open $To and paste the prompt"))
$content = ($L -join "`n") + "`n"

if (-not $DryRun) {
    if (-not (Test-Path -LiteralPath $hoDir)) { New-Item -ItemType Directory -Path $hoDir | Out-Null }
    [System.IO.File]::WriteAllText((Join-Path $hoDir "$hoId.md"), $content, $Utf8)
    $bc = Join-Path $PSScriptRoot 'backchannel-append.ps1'
    if (Test-Path -LiteralPath $bc) {
        $payload = [ordered]@{ ho_id = $hoId; cp_id = $cpId; from = $From; to = $To; path = $hoRel; entrypoint = $entry; unattended = [bool]$Unattended } | ConvertTo-Json -Compress
        try { & $bc -Kind handover-issued -From kcc-handover -Spec $spec -Session $fromSid -Payload $payload -RepoRoot $RepoRoot -NoDashboard | Out-Null } catch { [void]$warnings.Add('HO-W-EMIT: backchannel-append failed') }
    }
}

if ($Json) {
    $viol = @()
    foreach ($w in $warnings) { $p = $w -split ': ', 2; $viol += [ordered]@{ id = $p[0]; severity = 'warning'; fix_owner = 'human'; file = $null; message = $p[1] } }
    $cmdVal = $null; if ($command) { $cmdVal = $command }
    $out = [ordered]@{
        tool = 'kcc-handover'; version = $ToolVersion; scope = 'all'; errors = 0; warnings = $warnings.Count; status = 'pass'; dry_run = [bool]$DryRun; violations = $viol
        handover = [ordered]@{ id = $hoId; path = $hoRel; from = $From; to = $To; entrypoint = $entry; checkpoint = $cpPath; next_action = $nextAction; adapters = $adapters; missing_adapters = @($missing); unattended = [bool]$Unattended; prompt = $prompt; command = $cmdVal; launch = ([bool]$Launch -and -not $DryRun) }
    }
    Write-Output ($out | ConvertTo-Json -Depth 6 -Compress)
} else {
    if ($DryRun) { Write-Output "[dry-run] would write $hoRel and restore point $cpId (nothing written)" } else { Write-Output "$hoId written: $hoRel (restore point $cpId)" }
    $missNote = ''; if ($missing.Count -gt 0) { $missNote = ' (missing: ' + ($missing -join ' ') + ')' }
    Write-Output "from $From -> to $To, entrypoint $entry, adapters: $adapters$missNote"
    Write-Output "next_action: $nextAction"
    Write-Output ('command: ' + (Or $command '<none>'))
    foreach ($w in $warnings) { Write-Output "warning: $w" }
    Write-Output ('Errors: 0  Warnings: {0}' -f $warnings.Count)
}

if ($Launch -and -not $DryRun) {
    if (-not $command) { [Console]::Error.WriteLine("error: nothing to launch for $To"); exit 1 }
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    if ($onWindows) { $psi.FileName = $env:ComSpec; if (-not $psi.FileName) { $psi.FileName = 'cmd.exe' }; $psi.Arguments = '/d /s /c "' + $command + '"' }
    else { $psi.FileName = '/bin/sh'; $psi.ArgumentList.Add('-c'); $psi.ArgumentList.Add($command) }
    $psi.WorkingDirectory = $RepoRoot
    $psi.UseShellExecute = $false
    $proc = [System.Diagnostics.Process]::Start($psi)
    $proc.WaitForExit()
    exit $proc.ExitCode
}
exit 0
