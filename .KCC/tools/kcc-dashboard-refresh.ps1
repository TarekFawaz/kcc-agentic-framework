<#
KCC framework (c) 2026 Tarek Fawaz, https://tikasway.dev/kcc. Licensed under the terms in LICENSE.

.SYNOPSIS
    Hook helper: rebuilds dashboard/index.html in the background, at most every 15 seconds.

.DESCRIPTION
    Mirror of kcc-dashboard-refresh.sh (the Claude Code hooks call the .sh). Keeps the dashboard live
    while a run works: a chat-driven `auto` run otherwise rewrote it only at stage ends. Only acts in a
    workspace that has coordination/backchannel.jsonl. Never fails: always exits 0.
#>
[CmdletBinding()]
param([string]$RepoRoot, [int]$MinSeconds = 15)
try {
    if (-not $RepoRoot) { $RepoRoot = $env:CLAUDE_PROJECT_DIR }
    if (-not $RepoRoot) { $RepoRoot = (Get-Location).Path }
    if ($env:KCC_DASHBOARD_REFRESH_SECONDS -match '^\d+$') { $MinSeconds = [int]$env:KCC_DASHBOARD_REFRESH_SECONDS }
    if (-not (Test-Path -LiteralPath (Join-Path $RepoRoot 'coordination/backchannel.jsonl'))) { exit 0 }
    $dir = Join-Path $RepoRoot 'dashboard'
    $stamp = Join-Path $dir '.refresh'
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $last = 0
    if (Test-Path -LiteralPath $stamp) { [void][int64]::TryParse(([IO.File]::ReadAllText($stamp)).Trim(), [ref]$last) }
    if ($now - $last -lt $MinSeconds) { exit 0 }
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    [IO.File]::WriteAllText($stamp, [string]$now)
    $tool = Join-Path $RepoRoot '.KCC/tools/build-dashboard.ps1'
    if (Test-Path -LiteralPath $tool) {
        Start-Process -FilePath 'powershell' -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $tool, '-RepoRoot', $RepoRoot) -WindowStyle Hidden | Out-Null
    }
} catch { }
exit 0
