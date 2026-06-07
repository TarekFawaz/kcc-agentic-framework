<#
KCC framework (c) 2026 Tarek Fawaz, https://tikasway.dev/kcc. Licensed under the terms in LICENSE.

.SYNOPSIS
    Basic Inspector Pipeline - Detect + Propose stages over real KCC signals.

.DESCRIPTION
    A first, honest, BASIC implementation of the Inspector Pipeline's
    Detect->Propose stages (Observe reads traces + backchannel; Review and
    Promote remain human). It reads coordination/backchannel.jsonl,
    Traces/Session-*/, and TestResults/, mines a few simple and REAL patterns,
    and writes one proposal stub per detected pattern under
    .KCC/inspector/proposals/.

    It does NOT fabricate patterns. If there is not enough signal (too few
    backchannel events), it prints an honest "insufficient signal" message and
    writes nothing.

    Patterns detected (basic):
      - Repeated estimate-aborted / budget overruns.
      - Recurring confidence-gate trips for the same agent.
      - Recurring bug categories across TestResults/*/Bug-*.md.
      - Agents whose claimed confidence repeatedly diverged from outcomes
        (only when calibration signal is present).

    PowerShell 5.1 compatible. UTF-8 (no BOM) output. No && operator.

.PARAMETER RepoRoot
    Path to the repo root. Defaults to the parent of .KCC.

.PARAMETER MinEvents
    Minimum backchannel events required before detection runs (honesty floor).

.PARAMETER MinOccurrences
    How many times a pattern must repeat before a proposal is written.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .KCC\tools\kcc-inspect.ps1
#>

[CmdletBinding()]
param(
    [string]$RepoRoot,
    [int]$MinEvents = 8,
    [int]$MinOccurrences = 2
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

function Slugify { param([string]$s)
    $x = ($s -replace '[^A-Za-z0-9]+','-').Trim('-').ToLower()
    if ([string]::IsNullOrWhiteSpace($x)) { 'pattern' } else { $x }
}

# --- Observe: load signals ----------------------------------------------

$events = @()
$bcPath = Join-Path $RepoRoot 'coordination/backchannel.jsonl'
if (Test-Path -LiteralPath $bcPath) {
    foreach ($line in (Get-Content -LiteralPath $bcPath -ErrorAction SilentlyContinue)) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try { $events += ($line | ConvertFrom-Json) } catch {}
    }
}

$bugFiles = @()
$trDir = Join-Path $RepoRoot 'TestResults'
if (Test-Path -LiteralPath $trDir) {
    $bugFiles = Get-ChildItem -LiteralPath $trDir -Recurse -Filter '*Bug-*.md' -File -ErrorAction SilentlyContinue
}

# Honesty floor: too little signal -> say so and write nothing.
if ($events.Count -lt $MinEvents -and $bugFiles.Count -lt $MinOccurrences) {
    Write-Host ("insufficient signal - {0} backchannel events, {1} bug files; need at least {2} events (or {3} bugs). Run more sessions before inspecting." -f $events.Count, $bugFiles.Count, $MinEvents, $MinOccurrences)
    exit 0
}

# --- Detect: mine simple, real patterns ---------------------------------

$findings = @()   # each: @{ slug; title; observed; area; action }

# 1) Repeated estimate-aborted / budget overruns.
$aborts = @($events | Where-Object { "$($_.kind)" -in @('estimate-aborted','auto-policy-cap-exceeded') })
if ($aborts.Count -ge $MinOccurrences) {
    $bySpec = $aborts | Group-Object { "$($_.spec)" } | Sort-Object Count -Descending
    $detail = ($bySpec | ForEach-Object { "$($_.Name) x$($_.Count)" }) -join ', '
    $findings += @{
        slug='budget-aborts'; area='kernel/protocols/token-budget.md + capabilities/agents/token-guard.md'
        title="Repeated budget aborts / cap exceedances ($($aborts.Count) events)"
        observed="$($aborts.Count) estimate-aborted/cap-exceeded events across: $detail. Estimates may be too optimistic or scopes too large at first cut."
        action='Investigate'
    }
}

# 2) Recurring confidence-gate trips for the same agent.
$gateTrips = @($events | Where-Object { "$($_.kind)" -match 'confidence|gate|calibration-drift' })
if ($gateTrips.Count -ge $MinOccurrences) {
    $byAgent = $gateTrips | Group-Object { "$($_.from)" } | Where-Object { $_.Count -ge $MinOccurrences } | Sort-Object Count -Descending
    foreach ($g in $byAgent) {
        $findings += @{
            slug=("confidence-trips-" + (Slugify $g.Name)); area="capabilities/agents/$($g.Name).md"
            title="Agent '$($g.Name)' tripped confidence/calibration gates $($g.Count) times"
            observed="$($g.Name) repeatedly reported below-threshold confidence or drifted (events: $($g.Count)). Its instructions or required inputs may be under-specified."
            action='Investigate'
        }
    }
}

# 3) Recurring bug categories across TestResults bug files (by severity tag).
if ($bugFiles.Count -ge $MinOccurrences) {
    $sevCounts = @{}
    foreach ($bf in $bugFiles) {
        $txt = Get-Content -LiteralPath $bf.FullName -Raw -ErrorAction SilentlyContinue
        $m = [regex]::Match($txt, "(?im)severity[/:|\s]+(low|medium|high|critical)")
        $sev = if ($m.Success) { $m.Groups[1].Value.ToLower() } else { 'unclassified' }
        if (-not $sevCounts.ContainsKey($sev)) { $sevCounts[$sev] = 0 }
        $sevCounts[$sev]++
    }
    foreach ($sev in ($sevCounts.Keys | Where-Object { $sevCounts[$_] -ge $MinOccurrences })) {
        $findings += @{
            slug=("recurring-bugs-" + (Slugify $sev)); area='capabilities/dialects/testing-* + capabilities/agents/verifier.md'
            title="Recurring '$sev'-severity bugs ($($sevCounts[$sev]) across runs)"
            observed="$($sevCounts[$sev]) bug files tagged severity '$sev' found under TestResults/. A recurring category suggests a missing test dialect rule or verifier check."
            action='Investigate'
        }
    }
}

# 4) Calibration divergence (only if calibration-update events exist).
$calib = @($events | Where-Object { "$($_.kind)" -eq 'calibration-update' })
if ($calib.Count -ge $MinOccurrences) {
    $byAgent = $calib | Group-Object { "$($_.from)" } | Where-Object { $_.Count -ge $MinOccurrences }
    foreach ($g in $byAgent) {
        $findings += @{
            slug=("calibration-divergence-" + (Slugify $g.Name)); area="capabilities/agents/$($g.Name).md + kernel/protocols/accuracy-calibration.md"
            title="Agent '$($g.Name)' shows repeated claimed-vs-actual divergence"
            observed="$($g.Name) emitted $($g.Count) calibration-update events; persistent divergence means its self-reported confidence is mis-calibrated."
            action='Investigate'
        }
    }
}

if (-not $findings.Count) {
    Write-Host ("no recurring patterns detected at threshold {0} (events={1}, bugs={2}). Nothing proposed." -f $MinOccurrences, $events.Count, $bugFiles.Count)
    exit 0
}

# --- Propose: write one stub per finding --------------------------------

$propDir = Join-Path (Join-Path $RepoRoot '.KCC/inspector') 'proposals'
if (-not (Test-Path -LiteralPath $propDir)) { New-Item -ItemType Directory -Path $propDir -Force | Out-Null }
$today = (Get-Date).ToString('yyyy-MM-dd')
$enc = New-Object System.Text.UTF8Encoding($false)
$written = @()

foreach ($f in $findings) {
    $file = Join-Path $propDir ("{0}-{1}.md" -f $today, $f.slug)
    $seq = 1
    while (Test-Path -LiteralPath $file) {
        $seq++; $file = Join-Path $propDir ("{0}-{1}-{2}.md" -f $today, $f.slug, $seq)
    }
    # Pre-build the inline-code area string; a literal backtick directly before
    # $ would be parsed as an escape inside the here-string, so assemble it here.
    $tick = [char]96
    $areaCode = "$tick$($f.area)$tick"
    $body = @"
---
title: "Inspector proposal - $($f.title)"
tags:
  - inspector
  - inspector/proposal
created: $today
updated: $today
version: 0.1.0
status: draft
inspector_stage: propose
recommended_action: $($f.action)
---

# Inspector Proposal - $($f.title)

> Auto-generated by the BASIC inspector (`kcc-inspect.ps1`). Detect+Propose
> are automated; **Review and Promote remain human**. Do not promote without
> review.

## What was observed

$($f.observed)

## Suggested area to change

$areaCode

## Recommended action

**$($f.action)** - one of Adopt / Investigate / Defer.

- **Adopt**: the pattern is clear and the fix is low-risk; promote a change.
- **Investigate**: confirm the pattern is real and root-cause it first.
- **Defer**: acknowledge but wait for more signal.

## Evidence pointers

- `coordination/backchannel.jsonl`
- `Traces/Session-*/`
- `TestResults/`

## Review (human)

- [ ] Confirmed pattern is real (not noise)
- [ ] Decision: Adopt / Investigate / Defer
- [ ] Promoted to: _(path)_ or rejected with reason
"@
    [System.IO.File]::WriteAllText($file, $body, $enc)
    $written += $file
}

Write-Host ("Inspector wrote {0} proposal(s) to {1}:" -f $written.Count, $propDir)
$written | ForEach-Object { Write-Host "  $_" }
