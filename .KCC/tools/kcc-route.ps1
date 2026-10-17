<#
KCC framework (c) 2026 Tarek Fawaz, https://tikasway.dev/kcc. Licensed under the terms in LICENSE.

.SYNOPSIS
    The model router: which model tier and reasoning effort an agent run gets, from what the plan and the idea say.

.DESCRIPTION
    Mirror of kcc-route.sh (same rules, same output). The reference implementation is cli/src/run/router.ts; a parity test runs
    the same cases through all three. Rules: kernel/protocols/model-routing.md. Every flow asks this before it spawns an agent:
    kcc-run for each dispatch, the orchestrator and the skills a developer runs by hand before each spawn.

    Signals (each can also be given explicitly, which wins):
      agent        its model-class and effort from .KCC/capabilities/agents/<agent>.md, with .KCC/model-overrides applied
      task         from the agent (idea-interrogator -> research, architect -> architecture, planner -> plan, implementer -> implement ...)
      spec/wave    the plan's Backlog Coverage table: Complexity, Notes; the Backlog item's Impacted Files and title; items in the wave
      domain       ideation/IDEA-*/Research.md -> ## Domain (common | specialised | novel)
      attempt      1 first run, 2 or more a retry (a verifier or critic, task review, is never escalated for a retry)
      -MaxTier / -MaxEffort  ceilings the caller sets (kcc-run: REVIEW and a scoped re-verification are capped at balanced / high)
    Result: tier (fast | balanced | strong), the model of that tier on the active harness (kernel/models.json; settings
    run.registry picks another column), the effort folded onto what the harness accepts (kernel/harnesses.json), and the reasons.
    Implementation is capped at settings routing.implement_max_tier (default balanced). The deep tier is never chosen here.

    Output: one line  tier<TAB>model<TAB>effort<TAB>reasons<TAB>items   (or -Json). `kcc route` also writes the plan table `## Routing`.
    The reasons start with the agent default and name each move, separated by '; '.
    -Batch prints "tier effort reasons" per row and reads signal rows from stdin (parity tests). Exit 0, or 2 on a usage or environment error.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .KCC\tools\kcc-route.ps1 -Agent implementer -Spec SPEC-001 -Wave 2
#>

[CmdletBinding()]
param(
    [string]$RepoRoot,
    [string]$Agent,
    [string]$Task,
    [string]$Spec,
    [string]$Wave,
    [string]$Item,
    [int]$Attempt = 1,
    [string]$Harness,
    [string]$DefaultTier,
    [string]$DefaultEffort,
    [string]$Domain,
    [switch]$Risk,
    [string]$Complexity,
    [int]$Items = 0,
    [int]$Files = 0,
    [int]$BudgetLeft = -1,
    [string]$MaxTier,
    [string]$MaxEffort,
    [string]$ScanText,
    [switch]$Batch,
    [switch]$Json
)

$ErrorActionPreference = 'Stop'

if (-not $RepoRoot) {
    $toolDir = $PSScriptRoot
    if (-not $toolDir) { $toolDir = Split-Path -Parent $MyInvocation.MyCommand.Path }
    $parent = Split-Path -Parent $toolDir
    if ((Split-Path -Leaf $parent) -eq '.KCC') { $RepoRoot = Split-Path -Parent $parent } else { $RepoRoot = $parent }
}
$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).ProviderPath.TrimEnd('\', '/')
$KccDir = Join-Path $RepoRoot '.KCC'

$Tiers = @('fast', 'balanced', 'strong')
$Efforts = @('low', 'medium', 'high', 'xhigh', 'max')

function Read-Json([string]$path) { if (Test-Path -LiteralPath $path) { try { return ([System.IO.File]::ReadAllText($path) | ConvertFrom-Json) } catch { } } return $null }
function Idx([string[]]$list, [string]$v) { return [array]::IndexOf($list, $v) }
function TierUp([string]$t, [string]$cap) { return $Tiers[[Math]::Min((Idx $Tiers $t) + 1, (Idx $Tiers $cap))] }
function TierDown([string]$t, [string]$floor) { return $Tiers[[Math]::Max((Idx $Tiers $t) - 1, (Idx $Tiers $floor))] }
function TierAtLeast([string]$t, [string]$f) { if ((Idx $Tiers $t) -lt (Idx $Tiers $f)) { return $f } return $t }
function TierAtMost([string]$t, [string]$c) { if ((Idx $Tiers $t) -gt (Idx $Tiers $c)) { return $c } return $t }
function EffUp([string]$e) { return $Efforts[[Math]::Min((Idx $Efforts $e) + 1, (Idx $Efforts 'xhigh'))] }
function EffAtLeast([string]$e, [string]$f) { if ((Idx $Efforts $e) -lt (Idx $Efforts $f)) { return $f } return $e }

# Security words that make an item security-sensitive (CR-7). Tokens are lower-cased; a plural s is ignored.
function Get-SecurityHit([string]$text) {
    if (-not $text) { return '' }
    $low = $text.ToLowerInvariant()
    if ($low.Contains('personal data')) { return 'personal data' }
    $set = @('auth', 'authentication', 'authorization', 'authn', 'authz', 'password', 'credential', 'crypto', 'secret', 'token', 'csrf', 'jwt', 'oauth', 'session', 'pii', 'payment')
    foreach ($tok in ($low -split '[^a-z0-9]+')) {
        if (-not $tok) { continue }
        if ($set -contains $tok) { return $tok }
        if ($tok.Length -gt 3 -and $tok.EndsWith('s') -and ($set -contains $tok.Substring(0, $tok.Length - 1))) { return $tok.Substring(0, $tok.Length - 1) }
        if ($tok.StartsWith('encrypt')) { return $tok }
    }
    return ''
}

# The router: default tier and effort moved by the signals, never more than one tier from the default.
function Invoke-Route([string]$defTier, [string]$defEffort, [string]$task, [string]$domain, [bool]$risk, [string]$complexity, [int]$items, [int]$files, [int]$attempt, [int]$budget, [string]$capTier, [string]$capEffort = '', [string]$riskCause = '') {
    $minT = TierDown $defTier 'fast'; $maxT = TierUp $defTier 'strong'
    $tier = $defTier; $effort = $defEffort; if ($effort -eq 'max') { $effort = 'xhigh' }
    # every pick states its starting point first (mirror of router.ts)
    $reasons = @("agent default: $tier / $effort")
    $isRisk = $risk -or $complexity -eq 'high' -or $complexity -eq 'extra-high'
    # BALANCED_FLOOR_TASKS: research architecture security spec plan never run below balanced
    if (@('research', 'architecture', 'security', 'spec', 'plan') -contains $task -and (Idx $Tiers $tier) -lt 1) { $tier = 'balanced'; $reasons += ($task + ' never runs below balanced: tier raised') }
    if ($domain -eq 'novel') { $tier = TierUp $tier $maxT; $effort = EffAtLeast $effort 'high'; $reasons += 'novel domain: tier up, effort high' }
    # COMMON_DOMAIN_STEP_DOWN_TASKS: docs scaffold (spec and plan are not here on purpose)
    elseif ($domain -eq 'common' -and @('docs', 'scaffold') -contains $task) { $tier = TierDown $tier $minT; $reasons += ('common domain, ' + $task + ': tier down') }
    if ($isRisk) {
        $lifted = ''; if ((Idx $Tiers $tier) -lt 1) { $lifted = ', tier raised to balanced' }
        $tier = TierAtLeast $tier 'balanced'; $effort = EffAtLeast $effort 'high'
        if ($risk) { $cause = 'CR-7 risk'; if ($riskCause) { $cause = $riskCause }; $reasons += ($cause + ': effort ' + $effort + $lifted) } else { $reasons += ('complexity ' + $complexity + ': effort ' + $effort + $lifted) }
    }
    if ($complexity -eq 'extra-high') { $effort = EffAtLeast $effort 'xhigh'; $reasons += 'extra-high complexity: effort xhigh' }
    if ($items -gt 3 -or $files -gt 5) { $effort = EffUp $effort; $reasons += 'large unit: effort up' }
    # RETRY_RULES (router.ts): a retry escalates the agent that fixes something (tier and effort up one step); a planning retry
    # (spec, plan) keeps the tier and raises the effort to at most high; a verifier or critic (task review) is never escalated.
    if ($attempt -ge 2 -and $task -ne 'review') {
        if ($task -eq 'spec' -or $task -eq 'plan') {
            $before = $effort
            if ((Idx $Efforts $effort) -lt (Idx $Efforts 'high')) { $effort = $Efforts[(Idx $Efforts $effort) + 1] }
            if ($effort -ne $before) { $reasons += ('attempt ' + $attempt + ': effort raised to ' + $effort + ', tier unchanged for planning') } else { $reasons += ('attempt ' + $attempt + ': effort stays ' + $effort + ', tier unchanged for planning') }
        } else {
            $t0 = $tier; $e0 = $effort
            $tier = TierUp $tier $maxT; $effort = EffUp $effort
            $tw = 'unchanged'; if ($tier -ne $t0) { $tw = 'up' }
            $ew = 'unchanged'; if ($effort -ne $e0) { $ew = 'up' }
            $reasons += ('attempt ' + $attempt + ': tier ' + $tw + ', effort ' + $ew)
        }
    }
    if ($budget -ge 0 -and $budget -lt 20 -and -not $isRisk) { $tier = TierAtMost $tier 'balanced'; $reasons += 'budget under 20%: tier capped at balanced' }
    if ((Idx $Tiers $tier) -lt (Idx $Tiers $minT)) { $tier = $minT }
    if ((Idx $Tiers $tier) -gt (Idx $Tiers $maxT)) { $tier = $maxT }
    if ($capTier -and (Idx $Tiers $tier) -gt (Idx $Tiers $capTier)) { $tier = $capTier; $reasons += ('capped at ' + $capTier + ' for ' + $task) }
    if ($capEffort -and (Idx $Efforts $capEffort) -ge 0 -and (Idx $Efforts $effort) -gt (Idx $Efforts $capEffort)) { $effort = $capEffort; $reasons += ('effort capped at ' + $capEffort + ' for ' + $task) }
    return @{ tier = $tier; effort = $effort; reasons = $reasons }
}

if ($ScanText) { Write-Output (Get-SecurityHit $ScanText); exit 0 }

if ($Batch) {
    # one row per line: defaultTier defaultEffort task domain risk complexity items files attempt budget maxTier maxEffort ('-' = none)
    $line = $null
    while ($null -ne ($line = [Console]::In.ReadLine())) {
        if (-not $line.Trim()) { continue }
        $f = @($line.Trim() -split '\s+') | ForEach-Object { if ($_ -eq '-') { '' } else { $_ } }
        $bud = -1; if ($f[9]) { $bud = [int]$f[9] }
        $r = Invoke-Route $f[0] $f[1] $f[2] $f[3] ($f[4] -eq '1') $f[5] ([int]('0' + $f[6])) ([int]('0' + $f[7])) ([int]('0' + $f[8])) $bud $f[10] $f[11]
        Write-Output ($r.tier + ' ' + $r.effort + ' ' + (@($r.reasons) -join '; '))
    }
    exit 0
}

if (-not $Agent) { [Console]::Error.WriteLine('usage: kcc-route -Agent <name> [-Task t] [-Spec SPEC-ID [-Wave N | -Item key]] [-Attempt n] [-Harness h] [-Json]'); exit 2 }

$settings = Read-Json (Join-Path $KccDir 'settings.json')
$registry = Read-Json (Join-Path (Join-Path $KccDir 'kernel') 'models.json')
$profiles = Read-Json (Join-Path (Join-Path $KccDir 'kernel') 'harnesses.json')
function Get-Setting2([string[]]$path, $default) {
    $o = $settings
    foreach ($p in $path) { if ($null -eq $o) { return $default }; if ($o.PSObject.Properties.Name -contains $p) { $o = $o.$p } else { return $default } }
    if ($null -eq $o) { return $default }
    return $o
}
if (-not $Harness) { $Harness = [string](Get-Setting2 @('run', 'harness') 'claude') }

# --- the agent's default class and effort (frontmatter, then the user's .KCC/model-overrides) ---
$class = ''; $defEff = ''
$af = Join-Path (Join-Path (Join-Path $KccDir 'capabilities') 'agents') ($Agent + '.md')
if (Test-Path -LiteralPath $af) {
    foreach ($l in (Get-Content -LiteralPath $af -TotalCount 25)) {
        if ($l -match '^model-class:\s*(\S+)') { $class = $Matches[1] }
        elseif ($l -match '^effort:\s*(\S+)') { $defEff = $Matches[1] }
    }
}
$ovf = Join-Path $KccDir 'model-overrides'
if (Test-Path -LiteralPath $ovf) {
    foreach ($l in (Get-Content -LiteralPath $ovf)) {
        if ($l -match ('^\s*' + [regex]::Escape($Agent) + '\s*=\s*(\S+)(?:\s+(\S+))?')) { $class = $Matches[1]; if ($Matches[2]) { $defEff = $Matches[2] } }
    }
}
if (-not $DefaultTier) {
    $t = ''; if ($registry -and $registry.class_to_tier -and $class -and $registry.class_to_tier.PSObject.Properties[$class]) { $t = [string]$registry.class_to_tier.$class }
    if (-not $t) { $t = 'balanced' }
    $DefaultTier = $t
}
if (-not $DefaultEffort) { if ($defEff) { $DefaultEffort = $defEff } else { $DefaultEffort = 'medium' } }
if ($Tiers -notcontains $DefaultTier -or $Efforts -notcontains $DefaultEffort) { [Console]::Error.WriteLine("unknown tier or effort: $DefaultTier / $DefaultEffort"); exit 2 }

if (-not $Task) {
    $map = @{ 'idea-interrogator' = 'research'; 'technical-interrogator' = 'research'; 'ux-ui-designer' = 'research'; 'infrastructure-planner' = 'architecture'; 'architect' = 'architecture'; 'security-analyst' = 'security'; 'spec-writer' = 'spec'; 'planner' = 'plan'; 'implementer' = 'implement'; 'verifier' = 'review'; 'architecture-critic' = 'review'; 'butler' = 'close'; 'token-guard' = 'close'; 'repo-steward' = 'docs'; 'infrastructure-implementer' = 'implement' }
    if ($map.ContainsKey($Agent)) { $Task = $map[$Agent] } else { $Task = 'other' }
}

# --- signals from the idea and the plan ---
$specDir = ''; $ideaFolder = ''
if ($Spec) {
    $sroot = Join-Path $RepoRoot 'specs'
    if (Test-Path -LiteralPath $sroot) {
        foreach ($g in @(Get-ChildItem -LiteralPath $sroot -Directory -ErrorAction SilentlyContinue)) {
            foreach ($d in @(Get-ChildItem -LiteralPath $g.FullName -Directory -ErrorAction SilentlyContinue)) {
                if ($d.Name -eq $Spec -or $d.Name.StartsWith($Spec + '-')) { $specDir = $d.FullName; $ideaFolder = ($g.Name -replace '-Specs$', '') }
            }
        }
    }
}
if (-not $Domain -and $ideaFolder) {
    $rf = Join-Path (Join-Path (Join-Path $RepoRoot 'ideation') $ideaFolder) 'Research.md'
    if (Test-Path -LiteralPath $rf) {
        $txt = [System.IO.File]::ReadAllText($rf)
        $m = [regex]::Match($txt, '(?is)##\s+Domain[^\n]*\n+\s*[-*]?\s*`?(common|specialised|specialized|novel)')
        if (-not $m.Success) { $m = [regex]::Match($txt, '(?i)##\s+Domain\s*:\s*`?(common|specialised|specialized|novel)') }
        if ($m.Success) { $Domain = $m.Groups[1].Value.ToLowerInvariant(); if ($Domain -eq 'specialized') { $Domain = 'specialised' } }
    }
}

$rank = @{ 'low' = 1; 'medium' = 2; 'high' = 3; 'extra-high' = 4 }
$reasonsExtra = @(); $itemKeys = @()
if ($specDir -and (Test-Path -LiteralPath (Join-Path $specDir 'plan.md'))) {
    $hdr = $null; $rows = @()
    foreach ($l in [System.IO.File]::ReadAllLines((Join-Path $specDir 'plan.md'))) {
        if ($l -notmatch '^\s*\|') { if ($hdr) { break } else { continue } }
        $c = @(($l.Trim().Trim('|') -split '\|') | ForEach-Object { $_.Trim() })
        if (-not $hdr) { $low = @($c | ForEach-Object { $_.ToLowerInvariant() }); if (($low -contains 'item') -and ($low -contains 'complexity') -and ($low -contains 'wave')) { $hdr = $low }; continue }
        if ($l -match '^\s*\|[\s:|\-]+\|?\s*$') { continue }
        $get = { param($n) $i = [array]::IndexOf($hdr, $n); if ($i -ge 0 -and $i -lt $c.Count) { $c[$i] } else { '' } }
        $rows += , @((& $get 'item'), (& $get 'wave'), (& $get 'complexity').ToLowerInvariant(), (& $get 'notes'))
    }
    $sel = @($rows | Where-Object { ($Item -and $_[0] -eq $Item) -or (-not $Item -and (-not $Wave -or $_[1] -eq $Wave)) })
    $bestC = ''; $bestFiles = 0; $hit = ''
    foreach ($r in $sel) {
        $itemKeys += $r[0]
        if ($rank.ContainsKey($r[2]) -and ($bestC -eq '' -or $rank[$r[2]] -gt $rank[$bestC])) { $bestC = $r[2] }
        $text = $r[3]; $nfiles = 0
        $bd = Join-Path $specDir 'Backlog'
        if (Test-Path -LiteralPath $bd) {
            $bf = @(Get-ChildItem -LiteralPath $bd -Filter '*.md' -File -ErrorAction SilentlyContinue | Where-Object { $_.Name.ToLowerInvariant().StartsWith($r[0].ToLowerInvariant() + '-') -or $_.Name.ToLowerInvariant() -eq ($r[0].ToLowerInvariant() + '.md') }) | Select-Object -First 1
            if ($bf) {
                $lines = [System.IO.File]::ReadAllLines($bf.FullName)
                $text += "`n" + (($lines | Select-Object -First 40) -join "`n")
                $in = $false
                foreach ($ln in $lines) { if ($ln -match '^##\s+Impacted Files') { $in = $true; continue }; if ($in -and $ln -match '^##\s') { break }; if ($in -and $ln -match '^\s*[-*]\s+`') { $nfiles++ } }
            }
        }
        if ($nfiles -gt $bestFiles) { $bestFiles = $nfiles }
        if (-not $hit) { $h = Get-SecurityHit $text; if ($h) { $hit = $h } }
    }
    if (-not $Complexity -and $bestC) { $Complexity = $bestC }
    if ($Files -eq 0) { $Files = $bestFiles }
    if ($Items -eq 0 -and -not $Item) { $Items = $sel.Count }
    if (-not $Risk -and $hit) { $Risk = [switch]$true; $reasonsExtra += ('security-sensitive (' + $hit + ')') }
}

$cap = $MaxTier
if (-not $cap -and $Task -eq 'implement') { $cap = [string](Get-Setting2 @('routing', 'implement_max_tier') 'balanced') }
$riskCause = ''; if ($reasonsExtra.Count -gt 0) { $riskCause = [string]$reasonsExtra[0] }
$r = Invoke-Route $DefaultTier $DefaultEffort $Task $Domain ([bool]$Risk) $Complexity $Items $Files $Attempt $BudgetLeft $cap $MaxEffort $riskCause
$why = @($r.reasons)
$whyText = 'default'; if ($why.Count -gt 0) { $whyText = ($why -join '; ') }

# --- resolve to this harness ---
$regCol = [string](Get-Setting2 @('run', 'registry') ''); if (-not $regCol) { $regCol = $Harness }
$model = ''
if ($registry -and $registry.harnesses -and $registry.harnesses.PSObject.Properties[$regCol]) {
    $col = $registry.harnesses.$regCol
    if ($col.PSObject.Properties[$r.tier] -and $col.($r.tier).PSObject.Properties['id']) {
        $prefix = ''; if ($col.PSObject.Properties['_prefix']) { $prefix = [string]$col._prefix }
        $model = $prefix + [string]$col.($r.tier).id
    }
}
$eff = $r.effort
if ($profiles -and $profiles.harnesses -and $profiles.harnesses.PSObject.Properties[$Harness]) {
    $hp = $profiles.harnesses.$Harness
    if ($hp.PSObject.Properties['effort_map'] -and $hp.effort_map.PSObject.Properties[$eff]) { $eff = [string]$hp.effort_map.$eff }
}

if ($Json) {
    [pscustomobject]@{ agent = $Agent; task = $Task; harness = $Harness; tier = $r.tier; model = $model; effort = $eff; neutral_effort = $r.effort; reasons = $whyText; items = ($itemKeys -join ', ') } | ConvertTo-Json -Compress
} else {
    Write-Output ($r.tier + "`t" + $model + "`t" + $eff + "`t" + $whyText + "`t" + ($itemKeys -join ', '))
}
exit 0
