<#
KCC framework (c) 2026 Tarek Fawaz, https://tikasway.dev/kcc. Licensed under the terms in LICENSE.

.SYNOPSIS
    Validate a branch name, or a push target, against the KCC git workflow.

.DESCRIPTION
    Mirror of check-branch.sh. Read-only.
    Protocol: .KCC/kernel/protocols/git-workflow.md
    Contract: .KCC/kernel/contracts/tool-contract.md

    Settings (.KCC/settings.json -> git; built-in defaults when absent):
      model              trunk | off            (off = no branch / push checks)
      protected_branches ["main"]               (* is a wildcard; [] = none)
      branch_patterns    spec/SPEC-{ID}, lane/SPEC-{ID}-w{N},
                         bug/SPEC-{ID}-Bug-{NNN}, chore/{slug}

    Default mode checks the current branch (or -Branch) name.
    -Push checks a push target: -RemoteRef <ref>, or the git pre-push lines on
    stdin (<local ref> <local sha> <remote ref> <remote sha>); with a console
    on stdin it checks a push of the current branch.

    Violations: BRANCH-001 name matches no allowed pattern | BRANCH-002 on a
      protected branch (warning) | BRANCH-003 push targets a protected branch |
      BRANCH-004 push creates the protected branch on the remote (warning) |
      BRANCH-005 detached HEAD (warning)
    Exit: 0 pass | 1 violations | 2 usage/environment.
    PowerShell 5.1 compatible. ASCII-only. No && operator, no ternary.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .KCC\tools\check-branch.ps1 -Branch spec/SPEC-003 -Json
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .KCC\tools\check-branch.ps1 -Push -RemoteRef refs/heads/main
#>

[CmdletBinding()]
param(
    [string]$RepoRoot,
    [string]$Branch,
    [switch]$Push,
    [string]$RemoteRef,
    [string]$Scope,
    [switch]$Json
)

$ErrorActionPreference = 'Stop'
$ToolVersion = '1.0.0'
function Fail-Usage([string]$msg) { [Console]::Error.WriteLine($msg); exit 2 }

if ($PSScriptRoot) { $ToolDir = $PSScriptRoot } else { $ToolDir = Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $RepoRoot) {
    $parent = Split-Path -Parent $ToolDir
    if ((Split-Path -Leaf $parent) -eq '.KCC') { $RepoRoot = Split-Path -Parent $parent } else { $RepoRoot = $parent }
}
if (-not (Test-Path -LiteralPath $RepoRoot -PathType Container)) { Fail-Usage "workspace not found: $RepoRoot" }
$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).ProviderPath.TrimEnd('\', '/')
if ($RemoteRef -and (-not $Push)) { Fail-Usage '-RemoteRef is only valid with -Push' }
if (-not $Scope) { if ($Push) { $Scope = 'push' } else { $Scope = 'name' } }

$violations = New-Object System.Collections.ArrayList
$script:Checked = 0
function Add-Violation([string]$Code, [string]$Severity, [string]$Owner, [string]$Text, [string]$Path = '') {
    [void]$violations.Add([pscustomobject]@{ id = $Code; severity = $Severity; fix_owner = $Owner; file = $Path; message = $Text })
}

# ------------------------------------------------------------------ settings
$model = 'trunk'
$patterns = @('spec/SPEC-{ID}', 'lane/SPEC-{ID}-w{N}', 'bug/SPEC-{ID}-Bug-{NNN}', 'chore/{slug}')
$protected = @('main')
$settingsFile = Join-Path (Join-Path $RepoRoot '.KCC') 'settings.json'
if (Test-Path -LiteralPath $settingsFile) {
    $cfg = $null
    try { $cfg = [System.IO.File]::ReadAllText($settingsFile) | ConvertFrom-Json } catch { $cfg = $null }
    if ($cfg -and $cfg.git) {
        $g = $cfg.git
        if ($g.model) { $model = ([string]$g.model).ToLower() }
        if ($g.branch_patterns) {
            $custom = @()
            foreach ($p in $g.branch_patterns.PSObject.Properties) { if ($p.Value) { $custom += [string]$p.Value } }
            if ($custom.Count -gt 0) { $patterns = $custom }
        }
        $pp = $g.PSObject.Properties['protected_branches']
        if ($pp -and ($null -ne $pp.Value)) {
            # An explicit empty array means "no protected branches".
            $protected = @($pp.Value | Where-Object { $_ } | ForEach-Object { [string]$_ })
        }
    }
}
if (@('trunk', 'off') -notcontains $model) { Fail-Usage ("settings.json git.model must be trunk or off (found '{0}')" -f $model) }

$cs = [System.Text.RegularExpressions.RegexOptions]::None
# Template -> anchored regex. {ID} {N} {NNN} = digits, {slug} = name, * = anything.
function ConvertTo-BranchRegex([string]$Template) {
    $t = $Template.Replace('{ID}', '%%D%%').Replace('{NNN}', '%%D%%').Replace('{N}', '%%D%%').Replace('{slug}', '%%S%%').Replace('*', '%%A%%')
    $t = [regex]::Escape($t)
    $t = $t.Replace('%%D%%', '[0-9]+').Replace('%%S%%', '[A-Za-z0-9][A-Za-z0-9._/-]*').Replace('%%A%%', '.*')
    return '^(' + $t + ')$'
}
function Test-MatchesAny([string]$Name, [string[]]$Templates) {
    foreach ($t in $Templates) {
        if (-not $t) { continue }
        if ([regex]::IsMatch($Name, (ConvertTo-BranchRegex $t), $cs)) { return $true }
    }
    return $false
}
function Test-Protected([string]$Name) {
    if ($protected.Count -eq 0) { return $false }
    return (Test-MatchesAny $Name $protected)
}
function Test-ZeroSha([string]$Sha) { return [regex]::IsMatch($Sha, '^0+$') }
$allowedList = ($patterns -join ', ')

function Test-Name([string]$B) {
    $script:Checked++
    if (Test-Protected $B) {
        Add-Violation 'BRANCH-002' 'warning' 'repo-steward' ("'{0}' is a protected branch; commit on a work branch and merge by pull request" -f $B) $B
        return
    }
    if (-not (Test-MatchesAny $B $patterns)) {
        Add-Violation 'BRANCH-001' 'error' 'repo-steward' ("branch '{0}' matches no allowed pattern ({1})" -f $B, $allowedList) $B
    }
}

function Test-PushRef([string]$LocalSha, [string]$Ref, [string]$RemoteSha) {
    $b = $Ref
    if ($Ref.StartsWith('refs/heads/', [System.StringComparison]::Ordinal)) { $b = $Ref.Substring(11) }
    elseif ($Ref.StartsWith('refs/', [System.StringComparison]::Ordinal)) { return }
    $script:Checked++
    if (Test-Protected $b) {
        if (Test-ZeroSha $LocalSha) {
            Add-Violation 'BRANCH-003' 'error' 'human' ("push deletes protected branch '{0}'; this is never done from a KCC workspace" -f $b) $b
        }
        elseif (Test-ZeroSha $RemoteSha) {
            Add-Violation 'BRANCH-004' 'warning' 'human' ("push creates protected branch '{0}' on the remote (initial publish); later changes reach it by pull request only" -f $b) $b
        }
        else {
            Add-Violation 'BRANCH-003' 'error' 'human' ("push targets protected branch '{0}' directly; push a work branch and open a pull request" -f $b) $b
        }
        return
    }
    if (Test-ZeroSha $LocalSha) { return }
    if (-not (Test-MatchesAny $b $patterns)) {
        Add-Violation 'BRANCH-001' 'error' 'repo-steward' ("branch '{0}' matches no allowed pattern ({1})" -f $b, $allowedList) $b
    }
}

function Invoke-Git([string[]]$ArgList) {
    $old = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $out = @()
    $code = 1
    try { $out = @(& git -C $RepoRoot @ArgList 2>$null); $code = $LASTEXITCODE } catch { $code = 1 } finally { $ErrorActionPreference = $old }
    return @{ Out = $out; Code = $code }
}
function Get-CurrentBranch {
    $r = Invoke-Git @('symbolic-ref', '--short', '-q', 'HEAD')
    if (($r.Code -eq 0) -and ($r.Out.Count -gt 0)) { return ([string]$r.Out[0]).Trim() }
    return ''
}

if ($model -eq 'off') {
    # branch and push checks are disabled by settings
}
elseif ($Push) {
    $redirected = $true
    try { $redirected = [Console]::IsInputRedirected } catch { $redirected = $true }
    if ($RemoteRef) {
        Test-PushRef '1' $RemoteRef '1'
    }
    elseif (-not $redirected) {
        if (-not $Branch) { $Branch = Get-CurrentBranch }
        if ($Branch) { Test-PushRef '1' ('refs/heads/' + $Branch) '1' }
        else { Add-Violation 'BRANCH-005' 'warning' 'human' 'detached HEAD; no branch to check' '' }
    }
    else {
        $raw = ''
        try { $raw = [Console]::In.ReadToEnd() } catch { $raw = '' }
        foreach ($line in ($raw -split "`r?`n")) {
            $parts = @($line.Trim() -split '\s+' | Where-Object { $_ })
            if ($parts.Count -lt 3) { continue }
            $rsha = ''
            if ($parts.Count -ge 4) { $rsha = $parts[3] }
            Test-PushRef $parts[1] $parts[2] $rsha
        }
    }
}
else {
    if (-not $Branch) {
        if ($null -eq (Get-Command git -CommandType Application -ErrorAction SilentlyContinue)) { Fail-Usage 'git not found; pass -Branch <name>' }
        if ((Invoke-Git @('rev-parse', '--is-inside-work-tree')).Code -ne 0) { Fail-Usage 'not a git repository; pass -Branch <name>' }
        $Branch = Get-CurrentBranch
    }
    if ($Branch) { Test-Name $Branch }
    else { Add-Violation 'BRANCH-005' 'warning' 'human' 'detached HEAD; no branch to check' '' }
}

$errors = @($violations | Where-Object { $_.severity -eq 'error' })
$warnings = @($violations | Where-Object { $_.severity -eq 'warning' })
$status = 'pass'
if ($errors.Count -gt 0) { $status = 'fail' }
$branchOut = ''
if ($Branch) { $branchOut = $Branch }
if ($Json) {
    [pscustomobject]@{
        tool = 'check-branch'; version = $ToolVersion; scope = $Scope; model = $model; branch = $branchOut
        checked = $script:Checked; errors = $errors.Count; warnings = $warnings.Count; status = $status; violations = $violations
    } | ConvertTo-Json -Depth 5
}
else {
    Write-Output ("KCC branch check ({0}, model {1}): {2} ref(s) checked" -f $Scope, $model, $script:Checked)
    foreach ($v in $violations) {
        Write-Output ("[{0}] {1} ({2}) {3}: {4}" -f $v.severity.ToUpper(), $v.id, $v.fix_owner, $v.file, $v.message)
    }
    Write-Output ("Errors: {0}  Warnings: {1}" -f $errors.Count, $warnings.Count)
}
if ($errors.Count -gt 0) { exit 1 } else { exit 0 }
