# KCC framework (c) 2026 Tarek Fawaz, https://tikasway.dev/kcc. Licensed under the terms in LICENSE.
<#
.SYNOPSIS
  Give a running KCC session a hint about behaviour or expectations (PowerShell port of kcc-hint.sh).
.DESCRIPTION
  A hint is one short note from the human, stored in coordination/hints/hints.tsv and delivered to
  the main agent and to running subagents on their next tool call, prompt, or start (Claude Code
  hooks call kcc-hint.sh inject). Hints never waive a gate or a safety rule.
  Protocol: .KCC/kernel/protocols/hints.md
.EXAMPLE
  kcc-hint.ps1 add "Prefer small PRs" -To all
  kcc-hint.ps1 list
  kcc-hint.ps1 clear H-001
  kcc-hint.ps1 pending -For planner
#>
[CmdletBinding()]
param(
  [Parameter(Position = 0)][string]$Command = '',
  [Parameter(Position = 1, ValueFromRemainingArguments = $true)][string[]]$Rest = @(),
  [string]$To = 'all',
  [int]$ExpiresMinutes = 0,
  [string]$By = 'human',
  [string]$Spec = '',
  [switch]$Json,
  [string]$For = 'main',
  [switch]$All,
  [string]$RepoRoot = ''
)
$ErrorActionPreference = 'Stop'
if (-not $RepoRoot) { $RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path }
$Dir = Join-Path $RepoRoot 'coordination\hints'
$Hints = Join-Path $Dir 'hints.tsv'
$Archive = Join-Path $Dir 'archive.tsv'
$Seen = Join-Path $Dir 'seen'
$Utf8 = New-Object System.Text.UTF8Encoding($false)

function Die([string]$m) { [Console]::Error.WriteLine("kcc-hint: $m"); exit 2 }
function NowEpoch { [int][double]::Parse((Get-Date -UFormat %s)) }
function Append([string]$path, [string]$line) { [IO.File]::AppendAllText($path, $line + "`n", $Utf8) }
function Unescape([string]$s) { ($s.Replace('\\', "`0").Replace('\n', "`n").Replace('\"', '"')).Replace("`0", '\') }
function Emit([string]$kind, [string]$payload) {
  $tool = Join-Path $PSScriptRoot 'backchannel-append.ps1'
  if (-not (Test-Path $tool)) { return }
  try {
    $a = @('-Kind', $kind, '-From', 'kcc-hint', '-To', 'broadcast', '-Payload', $payload, '-RepoRoot', $RepoRoot, '-NoDashboard')
    if ($Spec) { $a += @('-Spec', $Spec) }
    & $tool @a *> $null
  } catch { }
}
function Applies([string]$to, [string]$kind, [string]$type) {
  switch ($to) {
    'all' { return $true }
    'main' { return $kind -eq 'main' }
    'subagents' { return $kind -eq 'sub' }
    default { return ($kind -eq 'sub' -and $to -ieq $type) }
  }
}
function ReadHints {
  if (-not (Test-Path $Hints) -or (Get-Item $Hints).Length -eq 0) { return @() }
  $t = NowEpoch
  foreach ($line in [IO.File]::ReadAllLines($Hints, $Utf8)) {
    if (-not $line) { continue }
    $f = $line -split "`t", 6
    if ($f.Count -lt 6) { continue }
    $exp = [long]$f[2]
    if ($exp -gt 0 -and $exp -le $t) { continue }
    [pscustomobject]@{ Id = $f[0]; To = $f[1]; Expires = $exp; Created = [long]$f[3]; By = $f[4]; Text = $f[5]; Line = $line }
  }
}

switch ($Command) {
  'add' {
    $text = ($Rest -join ' ').Trim()
    if (-not $text) { Die 'usage: kcc-hint add "<text>" [-To all|main|subagents|<agent-type>]' }
    if ($To -notmatch '^[A-Za-z][A-Za-z0-9_-]*$') { Die "-To expects all, main, subagents, or an agent name (got '$To')" }
    if ($text.Length -gt 1200) { Die 'a hint is at most 1200 characters; put long guidance in a file and hint its path' }
    $esc = ($text -replace "[\t\r]", ' ').Replace('\', '\\').Replace('"', '\"') -replace "`n", '\n'
    $by = $By -replace "[\t\r\n]", ''
    New-Item -ItemType Directory -Force -Path $Dir, $Seen | Out-Null
    $seq = Join-Path $Dir '.seq'
    $n = 0; if (Test-Path $seq) { $n = [int](([IO.File]::ReadAllText($seq)) -replace '\D', '0') }
    $n++; [IO.File]::WriteAllText($seq, "$n", $Utf8)
    $id = 'H-{0:000}' -f $n
    $created = NowEpoch; $exp = 0; if ($ExpiresMinutes -gt 0) { $exp = $created + $ExpiresMinutes * 60 }
    Append $Hints ("{0}`t{1}`t{2}`t{3}`t{4}`t{5}" -f $id, $To.ToLower(), $exp, $created, $by, $esc)
    Emit 'hint-issued' ('{{"hint":"{0}","to":"{1}","by":"{2}","expires_at":{3}}}' -f $id, $To.ToLower(), $by, $exp)
    Write-Host "kcc-hint: $id recorded for $($To.ToLower()). The main agent and running subagents get it on their next tool call, prompt, or start."
  }
  'list' {
    $rows = @(ReadHints)
    if ($Json) {
      $items = $rows | ForEach-Object { [ordered]@{ id = $_.Id; to = $_.To; expires_at = $_.Expires; created = $_.Created; by = $_.By; text = (Unescape $_.Text) } }
      ConvertTo-Json -InputObject @($items) -Depth 4
    } elseif ($rows.Count -eq 0) { Write-Host 'No active hints.' }
    else { foreach ($r in $rows) { Write-Host ("{0}  [{1}]  {2}" -f $r.Id, $r.To, (Unescape $r.Text)) } }
  }
  'clear' {
    $target = ($Rest | Select-Object -First 1)
    if (-not $target) { Die 'usage: kcc-hint clear <H-NNN|all>' }
    if (-not (Test-Path $Hints) -or (Get-Item $Hints).Length -eq 0) { Write-Host 'kcc-hint: nothing to clear.'; exit 0 }
    $target = $target.ToUpper(); if ($target -eq 'ALL') { $target = 'all' }
    $keep = New-Object System.Collections.Generic.List[string]; $cleared = 0
    foreach ($line in [IO.File]::ReadAllLines($Hints, $Utf8)) {
      if (-not $line) { continue }
      $id = ($line -split "`t", 2)[0]
      if ($target -eq 'all' -or $id -eq $target) { Append $Archive ("$line`t$(NowEpoch)"); $cleared++; Emit 'hint-cleared' ('{{"hint":"{0}"}}' -f $id) }
      else { $keep.Add($line) }
    }
    [IO.File]::WriteAllText($Hints, $(if ($keep.Count) { ($keep -join "`n") + "`n" } else { '' }), $Utf8)
    if ($cleared -eq 0) { [Console]::Error.WriteLine("kcc-hint: no active hint '$target'."); exit 1 }
    Write-Host "kcc-hint: cleared $cleared hint(s)."
  }
  'pending' {
    $kind = if ($For -ieq 'main') { 'main' } else { 'sub' }
    New-Item -ItemType Directory -Force -Path $Seen | Out-Null
    $seenFile = Join-Path $Seen ('cli-' + ($For -replace '[^A-Za-z0-9_-]', '_'))
    $have = @(); if (Test-Path $seenFile) { $have = [IO.File]::ReadAllLines($seenFile, $Utf8) }
    $rows = @(ReadHints | Where-Object { (Applies $_.To $kind $For) -and ($All -or $have -notcontains $_.Id) })
    if ($rows.Count -eq 0) { exit 0 }
    Write-Host 'Human hints (follow them as refinements of behaviour and expectations; they never waive a gate or a safety rule):'
    foreach ($r in $rows) {
      Write-Host ("- {0} [to: {1}]: {2}" -f $r.Id, $r.To, (Unescape $r.Text))
      if (-not $All) { Append $seenFile $r.Id }
    }
  }
  'inject' { Die 'inject is the Claude Code hook mode and runs from kcc-hint.sh (bash)' }
  default {
    if (-not $Command) { Get-Help $PSCommandPath -Examples | Out-String | Write-Host; exit 2 }
    Die "unknown command '$Command' (add, list, clear, pending)"
  }
}
