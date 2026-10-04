<#
KCC framework (c) 2026 Tarek Fawaz, https://tikasway.dev/kcc. Licensed under the terms in LICENSE.

.SYNOPSIS
    Claude Code PreToolUse hook enforcing the KCC usage-limit thresholds
    (PowerShell port of kcc-limit-guard.sh; same decisions and exit codes).

.DESCRIPTION
    Reads coordination/usage.json (written by kcc-statusline) and compares
    max(five_hour.pct, seven_day.pct) with .KCC/settings.json
    continuity.soft_pct / continuity.hard_pct (defaults 95 / 99).
      below soft : exit 0, no output.
      soft       : exit 0 + JSON hookSpecificOutput.additionalContext
                   ("KCC soft limit: finish current unit, spawn nothing new").
                   Once per window (marker file): CP limit-soft + limit-reached.
      hard       : once per window: CP limit-hard, limit-reached, arm
                   kcc-limit-watch (detached). Then exit 2 with the reason on
                   stderr (blocks the tool). Bash commands invoking
                   kcc-checkpoint / kcc-limit-watch / kcc-handover are allowed.
      usage.json missing, unreadable, older than 10 minutes, or its window
      already reset -> allow.
    Hook facts: https://code.claude.com/docs/en/hooks.md (PreToolUse stdin has
    session_id, tool_name, tool_input; exit 2 blocks and stderr becomes the
    reason; hookSpecificOutput.additionalContext adds context for Claude).
    PowerShell 5.1 compatible, ASCII-only source.
#>
[CmdletBinding()]
param(
    [string]$RepoRoot,
    [int]$MaxAgeSeconds = 600,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

function Get-Prop($obj, [string[]]$path) {
    $cur = $obj
    foreach ($p in $path) {
        if ($null -eq $cur) { return $null }
        if ($cur.PSObject.Properties.Name -contains $p) { $cur = $cur.$p } else { return $null }
    }
    return $cur
}
function Get-Num($v) {
    if ($null -eq $v) { return $null }
    $d = 0.0
    if ([double]::TryParse([string]$v, [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$d)) { return $d }
    return $null
}
function Fmt($v) {
    if ($v -eq [math]::Floor($v)) { return [string][int64]$v }
    return [string]::Format([System.Globalization.CultureInfo]::InvariantCulture, '{0}', $v)
}

if (-not $RepoRoot) {
    $toolDir = $PSScriptRoot
    if (-not $toolDir) { $toolDir = Split-Path -Parent $MyInvocation.MyCommand.Path }
    $RepoRoot = Split-Path -Parent (Split-Path -Parent $toolDir)
}

$hookRaw = ''
try { $hookRaw = [Console]::In.ReadToEnd() } catch { $hookRaw = '' }

$coord = Join-Path $RepoRoot 'coordination'
$usagePath = Join-Path $coord 'usage.json'
if (-not (Test-Path -LiteralPath $usagePath)) { exit 0 }

try {
    $usage = Get-Content -LiteralPath $usagePath -Raw | ConvertFrom-Json
    $soft = 95.0; $hard = 99.0
    $settingsPath = Join-Path $RepoRoot '.KCC\settings.json'
    if (Test-Path -LiteralPath $settingsPath) {
        $s = Get-Content -LiteralPath $settingsPath -Raw | ConvertFrom-Json
        $sv = Get-Num (Get-Prop $s @('continuity', 'soft_pct')); if ($null -ne $sv) { $soft = $sv }
        $hv = Get-Num (Get-Prop $s @('continuity', 'hard_pct')); if ($null -ne $hv) { $hard = $hv }
    }
} catch { exit 0 }

$now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
$updated = Get-Num (Get-Prop $usage @('updated_epoch'))
if ($null -eq $updated -or ($now - $updated) -gt $MaxAgeSeconds) { exit 0 }

$best = -1.0; $window = ''; $resets = $null
foreach ($w in @('five_hour', 'seven_day')) {
    $p = Get-Num (Get-Prop $usage @($w, 'pct'))
    $r = Get-Num (Get-Prop $usage @($w, 'resets_at'))
    if ($null -eq $p) { continue }
    if ($null -ne $r -and $r -le $now) { continue }
    if ($p -gt $best) { $best = $p; $window = $w; $resets = $r }
}
$level = 'allow'
if ($best -ge $hard) { $level = 'hard' } elseif ($best -ge $soft) { $level = 'soft' }
if ($level -eq 'allow') { exit 0 }

$hook = $null
try { if (-not [string]::IsNullOrWhiteSpace($hookRaw)) { $hook = $hookRaw | ConvertFrom-Json } } catch { $hook = $null }
$sid = [string](Get-Prop $hook @('session_id'))
if (-not $sid) { $sid = [string](Get-Prop $usage @('session_id')) }
$toolName = [string](Get-Prop $hook @('tool_name'))
$toolCmd = [string](Get-Prop $hook @('tool_input', 'command'))

$winLabel = '5h'; if ($window -eq 'seven_day') { $winLabel = '7d' }
$pctLabel = Fmt $best
$resetLabel = 'unknown'
$resetsInt = $null
if ($null -ne $resets) {
    $resetsInt = [int64]$resets
    $resetLabel = [DateTimeOffset]::FromUnixTimeSeconds($resetsInt).ToLocalTime().ToString('yyyy-MM-dd HH:mm zzz')
}
$cpDir = Join-Path $coord 'checkpoints'
$markName = '.limit-{0}-{1}-{2}' -f $level, $window, $(if ($null -ne $resetsInt) { $resetsInt } else { 'none' })
$mark = Join-Path $cpDir $markName
$first = $false
if (-not (Test-Path -LiteralPath $mark)) {
    $first = $true
    if (-not $DryRun) {
        if (-not (Test-Path -LiteralPath $cpDir)) { New-Item -ItemType Directory -Path $cpDir | Out-Null }
        [System.IO.File]::WriteAllText($mark, '')
    }
}

$ps = Join-Path $PSHOME 'powershell.exe'
if (-not (Test-Path -LiteralPath $ps)) { $ps = (Get-Process -Id $PID).Path }

function Invoke-Quiet([string[]]$argv) {
    # Child output (stdout + stderr) must not leak into the hook result.
    $old = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try { & $ps @argv *> $null } catch { } finally { $ErrorActionPreference = $old }
}
function Invoke-Emit([string]$lvl) {
    $bc = Join-Path $PSScriptRoot 'backchannel-append.ps1'
    if (-not (Test-Path -LiteralPath $bc)) { return }
    $payload = [ordered]@{ level = $lvl; window = $window; pct = $best; resets_at = $resetsInt; harness = 'claude' } | ConvertTo-Json -Compress
    try { & $bc -Kind limit-reached -From kcc-limit-guard -Session $sid -Payload $payload -RepoRoot $RepoRoot -NoDashboard | Out-Null } catch { }
}
function Invoke-Checkpoint([string]$reason) {
    $cp = Join-Path $PSScriptRoot 'kcc-checkpoint.ps1'
    $a = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $cp, '-Reason', $reason, '-Harness', 'claude', '-RepoRoot', $RepoRoot)
    if ($sid) { $a += @('-SessionId', $sid) }
    Invoke-Quiet $a
}

if ($level -eq 'soft') {
    $cpNote = ''
    if ($first -and -not $DryRun) {
        Invoke-Emit 'soft'
        Invoke-Checkpoint 'limit-soft'
        $cpNote = ' Restore point written to coordination/checkpoints/latest.md.'
    }
    $msg = "KCC soft limit: finish current unit, spawn nothing new. Usage $pctLabel% of the $winLabel window (soft $(Fmt $soft)%, hard $(Fmt $hard)%, resets $resetLabel).$cpNote Do not start new subagents, waves, or specs; wrap up the current unit and let the checkpoint carry next_action."
    $out = [ordered]@{
        hookSpecificOutput = [ordered]@{ hookEventName = 'PreToolUse'; additionalContext = $msg }
        systemMessage      = "KCC soft limit $pctLabel% ($winLabel): finishing current unit, nothing new will be spawned."
    }
    Write-Output ($out | ConvertTo-Json -Depth 4 -Compress)
    exit 0
}

# ---- hard -------------------------------------------------------------------
if ($toolName -eq 'Bash' -and $toolCmd -match 'kcc-(checkpoint|limit-watch|handover)') { exit 0 }

if ($first -and -not $DryRun) {
    Invoke-Emit 'hard'
    Invoke-Checkpoint 'limit-hard'
    $watch = Join-Path $PSScriptRoot 'kcc-limit-watch.ps1'
    $a = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $watch, '-Arm', '-Harness', 'claude', '-RepoRoot', $RepoRoot)
    if ($sid) { $a += @('-SessionId', $sid) }
    if ($null -ne $resetsInt) { $a += @('-ResetAt', [string]$resetsInt) }
    Invoke-Quiet $a
}

[Console]::Error.WriteLine("KCC hard limit: tool use stopped at $pctLabel% of the $winLabel usage window (hard $(Fmt $hard)%, resets $resetLabel). A limit-hard restore point is in coordination/checkpoints/latest.md and kcc-limit-watch is armed to resume this session unattended after the reset. Do not retry tools; end your turn now with a one-line status. (Allowed: Bash running kcc-checkpoint, kcc-limit-watch or kcc-handover.)")
exit 2
