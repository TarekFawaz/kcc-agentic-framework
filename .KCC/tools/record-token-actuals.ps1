<#
KCC framework (c) 2026 Tarek Fawaz, https://tikasway.dev/kcc. Licensed under the terms in LICENSE.

.SYNOPSIS
    Record ACTUAL token usage for a session - the missing producer for the
    token-actuals contract.

.DESCRIPTION
    Token Guard's Mode D ingests `actual_*` rows from
    `Traces/Session-*/TokenUsage.md`, but nothing wrote them - so actuals were
    never recorded. This tool is that producer. It writes one session-total
    actual row to the active session's `TokenUsage.md` and emits an
    `actual-recorded` backchannel event.

    Sources (per the token-actuals contract in trace-layout.md):
      harness-reported - parsed from a Claude Code transcript JSONL
                         (`message.usage`: input / output / cache tokens).
      manual-meter     - counts supplied by a human / billing export.
      unavailable      - honest "no accounting available" (null counts).

    The Claude Code SessionEnd hook calls this with `-FromHookStdin`, reading the
    hook JSON (with `transcript_path`) from stdin. Always exits 0 so it never
    disrupts session end.

    PowerShell 5.1 compatible. UTF-8 (no BOM). No && operator.

.PARAMETER FromHookStdin
    Read the SessionEnd hook JSON from stdin and use its `transcript_path`.

.PARAMETER TranscriptPath
    Path to a Claude Code transcript .jsonl (harness-reported mode).

.PARAMETER ManualTotal
    Total actual tokens from a trusted meter (manual-meter mode).

.PARAMETER ManualInput / .PARAMETER ManualOutput
    Optional input/output split for manual-meter mode.

.PARAMETER Unavailable
    Record an explicit `source: unavailable` row.

.PARAMETER Reason
    Reason string for unavailable mode.

.PARAMETER Spec
    Optional SPEC/IDEA id to tag the row and the backchannel event.

.PARAMETER RepoRoot
    Workspace root. Defaults to the parent of .KCC.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .KCC\tools\record-token-actuals.ps1 -FromHookStdin
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .KCC\tools\record-token-actuals.ps1 -TranscriptPath C:\...\session.jsonl
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .KCC\tools\record-token-actuals.ps1 -ManualTotal 145000 -ManualInput 110000 -ManualOutput 35000
#>

[CmdletBinding()]
param(
    [switch]$FromHookStdin,
    [string]$TranscriptPath,
    [Nullable[long]]$ManualTotal,
    [Nullable[long]]$ManualInput,
    [Nullable[long]]$ManualOutput,
    [switch]$Unavailable,
    [string]$Reason,
    [string]$Spec,
    [string]$RepoRoot
)

# Never let a hook failure disrupt session end.
$ErrorActionPreference = 'Continue'

function Resolve-RepoRootFromTool {
    if ($PSScriptRoot) { $toolDir = $PSScriptRoot }
    elseif ($MyInvocation.MyCommand.Path) { $toolDir = Split-Path -Parent $MyInvocation.MyCommand.Path }
    else { return (Get-Location).Path }
    $parent = Split-Path -Parent $toolDir
    if ((Split-Path -Leaf $parent) -eq '.KCC') { return (Split-Path -Parent $parent) }
    return $parent
}

function Write-Info($msg) { Write-Host "[record-token-actuals] $msg" }

try {
    if (-not $RepoRoot) { $RepoRoot = Resolve-RepoRootFromTool }
    if (Test-Path -LiteralPath $RepoRoot) { $RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path }

    # ----- Resolve transcript path from hook stdin if requested -----
    if ($FromHookStdin) {
        $raw = [Console]::In.ReadToEnd()
        if ($raw) {
            try {
                $hook = $raw | ConvertFrom-Json
                if ($hook.transcript_path) { $TranscriptPath = [string]$hook.transcript_path }
                if (-not $RepoRoot -and $hook.cwd) { $RepoRoot = [string]$hook.cwd }
            }
            catch { Write-Info "could not parse hook stdin JSON: $($_.Exception.Message)" }
        }
    }

    # ----- Resolve the active session folder -----
    $session = $null
    $orch = Join-Path $RepoRoot 'coordination/orchestrator.json'
    if (Test-Path -LiteralPath $orch) {
        try {
            $o = Get-Content -LiteralPath $orch -Raw | ConvertFrom-Json
            if ($o.active_session) {
                $candidate = Join-Path $RepoRoot ([string]$o.active_session)
                if (Test-Path -LiteralPath $candidate) { $session = (Resolve-Path -LiteralPath $candidate).Path }
            }
        }
        catch { }
    }
    if (-not $session) {
        $tracesDir = Join-Path $RepoRoot 'Traces'
        if (Test-Path -LiteralPath $tracesDir) {
            $latest = Get-ChildItem -LiteralPath $tracesDir -Directory -Filter 'Session-*' -ErrorAction SilentlyContinue |
                Sort-Object LastWriteTime -Descending | Select-Object -First 1
            if ($latest) { $session = $latest.FullName }
        }
    }
    if (-not $session) {
        Write-Info "no active Traces/Session-* folder found; nothing to record."
        exit 0
    }
    $tokenFile = Join-Path $session 'TokenUsage.md'

    # ----- Determine the actuals to write -----
    $source = $null
    $inTok = $null; $outTok = $null; $totTok = $null
    $cacheCreate = 0; $cacheRead = 0; $turns = 0
    $unavailReason = ''

    if ($Unavailable) {
        $source = 'unavailable'
        if (-not $Reason) { $Reason = 'harness did not expose usage metadata' }
        $unavailReason = $Reason
    }
    elseif ($null -ne $ManualTotal) {
        $source = 'manual-meter'
        $totTok = [long]$ManualTotal
        if ($null -ne $ManualInput) { $inTok = [long]$ManualInput }
        if ($null -ne $ManualOutput) { $outTok = [long]$ManualOutput }
    }
    elseif ($TranscriptPath -and (Test-Path -LiteralPath $TranscriptPath)) {
        $source = 'harness-reported'
        $i = 0; $c = 0; $r = 0; $out = 0; $t = 0
        foreach ($line in [System.IO.File]::ReadLines($TranscriptPath)) {
            if (-not $line) { continue }
            try { $obj = $line | ConvertFrom-Json } catch { continue }
            $u = $null
            if ($obj.message -and $obj.message.usage) { $u = $obj.message.usage }
            elseif ($obj.usage) { $u = $obj.usage }
            if ($null -eq $u) { continue }
            if ($u.input_tokens) { $i += [long]$u.input_tokens }
            if ($u.cache_creation_input_tokens) { $c += [long]$u.cache_creation_input_tokens }
            if ($u.cache_read_input_tokens) { $r += [long]$u.cache_read_input_tokens }
            if ($u.output_tokens) { $out += [long]$u.output_tokens }
            $t++
        }
        $cacheCreate = $c; $cacheRead = $r; $turns = $t
        # Fresh input only (non-cached + cache writes). cache_read is reused
        # context billed at a reduced rate and accumulates every turn, so it is
        # tracked separately - folding it into the total would inflate it far
        # beyond anything comparable to a Token Guard estimate.
        $inTok = $i + $c
        $outTok = $out
        $totTok = $inTok + $outTok
        if ($t -eq 0) {
            $source = 'unavailable'
            $unavailReason = "transcript had no usage metadata: $TranscriptPath"
        }
    }
    else {
        $source = 'unavailable'
        $unavailReason = 'no transcript path, manual counts, or usable hook input provided'
    }

    # ----- Append the row to TokenUsage.md -----
    $ts = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    $specLine = if ($Spec) { $Spec } else { 'session-total' }
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine("## $ts - actual token usage (session total)")
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('```yaml')
    [void]$sb.AppendLine("- ts: $ts")
    [void]$sb.AppendLine("  agent: session")
    [void]$sb.AppendLine("  stage: session-total")
    [void]$sb.AppendLine("  spec: $specLine")
    [void]$sb.AppendLine("  source: $source")
    if ($source -eq 'unavailable') {
        [void]$sb.AppendLine("  actual_input_tokens: null")
        [void]$sb.AppendLine("  actual_output_tokens: null")
        [void]$sb.AppendLine("  actual_total_tokens: null")
        [void]$sb.AppendLine("  unavailable_reason: $unavailReason")
    }
    else {
        [void]$sb.AppendLine("  actual_input_tokens: $inTok")
        [void]$sb.AppendLine("  actual_output_tokens: $outTok")
        [void]$sb.AppendLine("  actual_total_tokens: $totTok")
        if ($source -eq 'harness-reported') {
            [void]$sb.AppendLine("  actual_cache_read_tokens: $cacheRead")
        }
        [void]$sb.AppendLine("  unavailable_reason:")
        if ($source -eq 'harness-reported') {
            [void]$sb.AppendLine("  # input = fresh (input + cache_creation=$cacheCreate); cache_read=$cacheRead reused at reduced rate; $turns assistant turns")
        }
    }
    [void]$sb.AppendLine('```')

    if (-not (Test-Path -LiteralPath $tokenFile)) {
        $header = "# Token Usage`n"
        [System.IO.File]::WriteAllText($tokenFile, $header, (New-Object System.Text.UTF8Encoding($false)))
    }
    $existing = [System.IO.File]::ReadAllText($tokenFile)
    [System.IO.File]::WriteAllText($tokenFile, $existing + $sb.ToString(), (New-Object System.Text.UTF8Encoding($false)))

    if ($source -eq 'unavailable') {
        Write-Info "recorded source=unavailable in $tokenFile ($unavailReason)"
    }
    else {
        Write-Info "recorded $source actual: input=$inTok output=$outTok total=$totTok -> $tokenFile"
    }

    # ----- Emit actual-recorded backchannel event (best-effort) -----
    $append = Join-Path $RepoRoot '.KCC/tools/backchannel-append.ps1'
    if (Test-Path -LiteralPath $append) {
        if ($source -eq 'unavailable') {
            $payload = "source=unavailable;unavailable_reason=$unavailReason"
        }
        else {
            $payload = "source=$source;actual_input_tokens=$inTok;actual_output_tokens=$outTok;actual_total_tokens=$totTok"
            if ($source -eq 'harness-reported') { $payload += ";actual_cache_read_tokens=$cacheRead" }
        }
        try {
            $bcArgs = @('-ExecutionPolicy', 'Bypass', '-File', $append,
                '-Kind', 'actual-recorded', '-From', 'butler', '-Payload', $payload, '-NoDashboard')
            if ($Spec) { $bcArgs += @('-Spec', $Spec) }
            & powershell @bcArgs | Out-Null
        }
        catch { Write-Info "backchannel emit skipped: $($_.Exception.Message)" }
    }
}
catch {
    Write-Info "non-fatal error: $($_.Exception.Message)"
}

exit 0
