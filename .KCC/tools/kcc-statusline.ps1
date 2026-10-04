<#
KCC framework (c) 2026 Tarek Fawaz, https://tikasway.dev/kcc. Licensed under the terms in LICENSE.

.SYNOPSIS
    Claude Code status-line command for KCC session continuity (PowerShell port
    of kcc-statusline.sh).

.DESCRIPTION
    Reads the Claude Code status-line JSON from stdin (documented fields:
    rate_limits.five_hour/seven_day.used_percentage + resets_at (Unix epoch
    seconds), context_window.used_percentage, session_id), atomically writes
    coordination/usage.json and prints one compact line:
        KCC 5h 42% . 7d 18% . ctx 31%     (middle dot U+00B7 as separator)
    A " SOFT" / " HARD" suffix appears once continuity.soft_pct / hard_pct is
    reached. If $env:KCC_STATUSLINE_CHAIN is set, the same stdin is piped to
    that command and its output is printed instead (usage.json still written).
    Never fails the status bar: errors print "KCC" and exit 0.

    The bash variant is the recommended statusLine command (faster start-up);
    this port exists for PowerShell-only hosts.
    PowerShell 5.1 compatible, ASCII-only source.

.EXAMPLE
    Get-Content sample.json | powershell -NoProfile -ExecutionPolicy Bypass -File .KCC\tools\kcc-statusline.ps1
#>
[CmdletBinding()]
param(
    [string]$RepoRoot,
    [switch]$Json
)

$ErrorActionPreference = 'Stop'
$dot = [string][char]0x00B7

function Resolve-KccRoot {
    $toolDir = $PSScriptRoot
    if (-not $toolDir) { $toolDir = Split-Path -Parent $MyInvocation.MyCommand.Path }
    return (Split-Path -Parent (Split-Path -Parent $toolDir))
}

function Get-Num($v) {
    if ($null -eq $v) { return $null }
    $d = 0.0
    if ([double]::TryParse([string]$v, [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$d)) { return $d }
    return $null
}

function Format-Pct($v) {
    if ($null -eq $v) { return '--' }
    if ($v -eq [math]::Floor($v)) { return ('{0}%' -f [int64]$v) }
    return ([string]::Format([System.Globalization.CultureInfo]::InvariantCulture, '{0:0.0}%', $v))
}

function Get-Prop($obj, [string[]]$path) {
    $cur = $obj
    foreach ($p in $path) {
        if ($null -eq $cur) { return $null }
        if ($cur.PSObject.Properties.Name -contains $p) { $cur = $cur.$p } else { return $null }
    }
    return $cur
}

$raw = ''
try {
    try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false) } catch { }
    if (-not $RepoRoot) { $RepoRoot = Resolve-KccRoot }
    $raw = [Console]::In.ReadToEnd()
    $data = $null
    if (-not [string]::IsNullOrWhiteSpace($raw)) { $data = $raw | ConvertFrom-Json }

    $soft = 95.0; $hard = 99.0
    $settingsPath = Join-Path $RepoRoot '.KCC\settings.json'
    if (Test-Path -LiteralPath $settingsPath) {
        $s = Get-Content -LiteralPath $settingsPath -Raw | ConvertFrom-Json
        $sv = Get-Num (Get-Prop $s @('continuity', 'soft_pct')); if ($null -ne $sv) { $soft = $sv }
        $hv = Get-Num (Get-Prop $s @('continuity', 'hard_pct')); if ($null -ne $hv) { $hard = $hv }
    }

    $f5 = Get-Num (Get-Prop $data @('rate_limits', 'five_hour', 'used_percentage'))
    $r5 = Get-Num (Get-Prop $data @('rate_limits', 'five_hour', 'resets_at'))
    $f7 = Get-Num (Get-Prop $data @('rate_limits', 'seven_day', 'used_percentage'))
    $r7 = Get-Num (Get-Prop $data @('rate_limits', 'seven_day', 'resets_at'))
    $cx = Get-Num (Get-Prop $data @('context_window', 'used_percentage'))
    $sid = Get-Prop $data @('session_id')

    $now = [DateTimeOffset]::UtcNow
    $usage = [ordered]@{
        harness       = 'claude'
        session_id    = $sid
        five_hour     = [ordered]@{ pct = $f5; resets_at = $(if ($null -ne $r5) { [int64]$r5 } else { $null }) }
        seven_day     = [ordered]@{ pct = $f7; resets_at = $(if ($null -ne $r7) { [int64]$r7 } else { $null }) }
        context_pct   = $cx
        updated       = $now.ToString('yyyy-MM-ddTHH:mm:ssZ')
        updated_epoch = $now.ToUnixTimeSeconds()
    }
    $body = $usage | ConvertTo-Json -Depth 5 -Compress

    $coord = Join-Path $RepoRoot 'coordination'
    if (-not (Test-Path -LiteralPath $coord)) { New-Item -ItemType Directory -Path $coord | Out-Null }
    $dest = Join-Path $coord 'usage.json'
    $tmp = Join-Path $coord ('.usage.json.' + $PID + '.tmp')
    [System.IO.File]::WriteAllText($tmp, $body + "`n", (New-Object System.Text.UTF8Encoding($false)))
    if (Test-Path -LiteralPath $dest) { [System.IO.File]::Replace($tmp, $dest, [NullString]::Value) } else { [System.IO.File]::Move($tmp, $dest) }

    if ($Json) { Write-Output $body; exit 0 }

    if ($env:KCC_STATUSLINE_CHAIN) {
        $chainOut = ''
        try { $chainOut = ($raw | & bash -c $env:KCC_STATUSLINE_CHAIN 2>$null | Out-String).TrimEnd() } catch { $chainOut = '' }
        if ($chainOut) { Write-Output $chainOut; exit 0 }
    }

    $m = -1.0
    if ($null -ne $f5 -and $f5 -gt $m) { $m = $f5 }
    if ($null -ne $f7 -and $f7 -gt $m) { $m = $f7 }
    $flag = ''
    if ($m -ge $hard) { $flag = ' HARD' } elseif ($m -ge $soft) { $flag = ' SOFT' }
    Write-Output ('KCC 5h {0} {3} 7d {1} {3} ctx {2}{4}' -f (Format-Pct $f5), (Format-Pct $f7), (Format-Pct $cx), $dot, $flag)
    exit 0
} catch {
    try { [Console]::Error.WriteLine('kcc-statusline: ' + $_.ToString()) } catch { }
    Write-Output 'KCC'
    exit 0
}
