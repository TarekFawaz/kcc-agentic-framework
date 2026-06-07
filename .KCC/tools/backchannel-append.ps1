<#
KCC framework (c) 2026 Tarek Fawaz, https://tikasway.dev/kcc. Licensed under the terms in LICENSE.

.SYNOPSIS
    Deterministically append one event line to coordination/backchannel.jsonl.

.DESCRIPTION
    The backchannel is an append-only JSONL log shared by the meta-agents
    (butler, token-guard). This helper turns "emit a backchannel event" into a
    single deterministic command instead of freeform JSON authoring, so the
    write can never be silently skipped.

    It allocates the next monotonic id (BC-NNNNN) by reading the last readable
    line, builds one compact JSON object with a UTC ISO-8601 timestamp, and
    appends exactly one line (UTF-8, no BOM, LF). The written line is printed.

    PowerShell 5.1 compatible. UTF-8 (no BOM) output. No && operator.

.PARAMETER Kind
    The event kind (e.g. brief-issued, remember-stored, estimate-issued).

.PARAMETER From
    The emitting agent name (e.g. butler, token-guard).

.PARAMETER To
    The recipient: an agent name or "broadcast" (default).

.PARAMETER Spec
    SPEC-ID, IDEA-ID, or empty (-> null in the event).

.PARAMETER Session
    Harness session id, or empty (-> null in the event).

.PARAMETER Payload
    Either a JSON object string ('{"entries":0}') or a key=val;key=val list
    ('entries=0;reason=routine'). Empty -> {}.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .KCC\tools\backchannel-append.ps1 -Kind brief-issued -From butler -Spec SPEC-007 -Payload 'topic=SPEC-007;pack_tokens_est=420'

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .KCC\tools\backchannel-append.ps1 -Kind estimate-issued -From token-guard -Spec SPEC-007 -Payload '{"cost_total_usd":4.85,"confidence_band_pct":30}'
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Kind,
    [Parameter(Mandatory)][string]$From,
    [string]$To = 'broadcast',
    [string]$Spec,
    [string]$Session,
    [string]$Payload,
    [string]$RepoRoot,
    [switch]$NoDashboard
)

$ErrorActionPreference = 'Stop'

function Resolve-RepoRootFromTool {
    if ($PSScriptRoot) { $toolDir = $PSScriptRoot }
    elseif ($MyInvocation.MyCommand.Path) { $toolDir = Split-Path -Parent $MyInvocation.MyCommand.Path }
    else { return (Get-Location).Path }
    $parent = Split-Path -Parent $toolDir
    if ((Split-Path -Leaf $parent) -eq '.KCC') { return (Split-Path -Parent $parent) }
    return $parent
}

if (-not $RepoRoot) { $RepoRoot = Resolve-RepoRootFromTool }

$dir = Join-Path $RepoRoot 'coordination'
if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
$path = Join-Path $dir 'backchannel.jsonl'
if (-not (Test-Path -LiteralPath $path)) { New-Item -ItemType File -Path $path | Out-Null }

# Allocate next id: scan from the end for the highest valid BC-NNNNN.
$nextNum = 1
$existing = @(Get-Content -LiteralPath $path -ErrorAction SilentlyContinue | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
if ($existing.Count -gt 0) {
    $scan = @($existing | Select-Object -Last 50)
    for ($i = $scan.Count - 1; $i -ge 0; $i--) {
        try {
            $obj = $scan[$i] | ConvertFrom-Json
            if ($obj.id -match '^BC-(\d+)$') {
                $nextNum = [int]$Matches[1] + 1
                break
            }
        } catch { continue }
    }
}
$id = 'BC-{0:D5}' -f $nextNum

# Build payload object.
$payloadObj = @{}
if (-not [string]::IsNullOrWhiteSpace($Payload)) {
    $trimmed = $Payload.Trim()
    if ($trimmed.StartsWith('{')) {
        $payloadObj = $trimmed | ConvertFrom-Json
    } else {
        $payloadObj = [ordered]@{}
        foreach ($pair in ($trimmed -split ';')) {
            if ([string]::IsNullOrWhiteSpace($pair)) { continue }
            $kv = $pair -split '=', 2
            $key = $kv[0].Trim()
            $val = if ($kv.Count -gt 1) { $kv[1].Trim() } else { '' }
            $num = 0.0
            if ([double]::TryParse($val, [ref]$num)) { $payloadObj[$key] = $num }
            else { $payloadObj[$key] = $val }
        }
    }
}

$specVal = if ([string]::IsNullOrWhiteSpace($Spec)) { $null } else { $Spec }
$sessionVal = if ([string]::IsNullOrWhiteSpace($Session)) { $null } else { $Session }

$event = [ordered]@{
    ts      = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    id      = $id
    from    = $From
    to      = $To
    kind    = $Kind
    spec    = $specVal
    session = $sessionVal
    payload = $payloadObj
}

$line = $event | ConvertTo-Json -Depth 12 -Compress

# Append exactly one line, UTF-8 no BOM, LF terminator.
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::AppendAllText($path, $line + "`n", $utf8NoBom)

# Keep the human-facing dashboard close to live without requiring a separate
# command after every agent event. The event write is authoritative; dashboard
# refresh is best-effort and must never block the append.
$skipDashboard = $NoDashboard -or ($env:KCC_SKIP_DASHBOARD -eq '1') -or ($env:KCC_SKIP_DASHBOARD -eq 'true')
if (-not $skipDashboard) {
    $dashboardScript = Join-Path $PSScriptRoot 'build-dashboard.ps1'
    if (Test-Path -LiteralPath $dashboardScript) {
        try {
            & $dashboardScript -RepoRoot $RepoRoot *> $null
        } catch {
            Write-Warning "Backchannel event appended, but dashboard refresh failed: $($_.Exception.Message)"
        }
    }
}

Write-Output $line
