<#
KCC framework (c) 2026 Tarek Fawaz, https://tikasway.dev/kcc. Licensed under the terms in LICENSE.

.SYNOPSIS
    Implementation lock: may code be written into src/IDEA-{ID}-*/ yet?

.DESCRIPTION
    Writing into src/IDEA-{ID}-*/ is OPEN when, for at least one spec of that idea:
      1. plan.md exists and declares a ready status (frontmatter `status: ready`,
         `| Status | Ready |`, `**Status:** ready`, ...), AND
      2. an implement budget approval exists: a coordination/backchannel.jsonl
         line whose kind is estimate-approved | estimate-auto-approved |
         auto-policy-approved | auto-policy-approved-bounded |
         auto-policy-approved-unlimited and that mentions the SPEC-ID or the
         IDEA-ID, OR a Traces/Session-*/HumanDecisions.md line that mentions the
         SPEC-ID plus "implement" and "approv".
    Paths outside src/IDEA-*/ are always allowed.

    Modes:
      -Path <file>   check one path (absolute or relative to the workspace)
      -Staged        check every staged git path
      -Hook          Claude Code PreToolUse hook: reads the hook JSON on stdin,
                     takes tool_input.file_path (or notebook_path). Locked: reason
                     on stderr, exit 2 (Claude Code blocks the tool). Allowed:
                     exit 0, silent.
    Violation: LOCK-001 (fix_owner human).

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .KCC\tools\check-impl-lock.ps1 -Path src/IDEA-001-demo/app.py -Json
#>

[CmdletBinding()]
param(
    [string]$RepoRoot,
    [string]$Path,
    [switch]$Staged,
    [switch]$Hook,
    [string]$Scope = 'all',
    [switch]$Json,
    [Parameter(ValueFromRemainingArguments = $true)] [string[]]$Rest
)

$ErrorActionPreference = 'Stop'
$ToolVersion = '1.0.0'
if ($Rest -contains '--hook') { $Hook = $true }
function Fail-Usage([string]$msg) { [Console]::Error.WriteLine($msg); exit 2 }

if ($PSScriptRoot) { $ToolDir = $PSScriptRoot } else { $ToolDir = Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $RepoRoot) {
    $parent = Split-Path -Parent $ToolDir
    if ((Split-Path -Leaf $parent) -eq '.KCC') { $RepoRoot = Split-Path -Parent $parent } else { $RepoRoot = $parent }
}
if (-not (Test-Path -LiteralPath $RepoRoot)) {
    if ($Hook) { exit 0 }
    Fail-Usage "workspace not found: $RepoRoot"
}
$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path.TrimEnd('\', '/')

$violations = New-Object System.Collections.ArrayList
function Add-Violation([string]$Code, [string]$Severity, [string]$Owner, [string]$Message, [string]$File = '') {
    [void]$violations.Add([pscustomobject]@{ id = $Code; severity = $Severity; fix_owner = $Owner; file = $File; message = $Message })
}
function Read-Text([string]$p) { try { return [System.IO.File]::ReadAllText($p) } catch { return '' } }
function Read-Lines([string]$p) { try { return , ([string[]][System.IO.File]::ReadAllLines($p)) } catch { return , ([string[]]@()) } }

# Workspace-relative, forward-slash, dot-segment-free path; $null when outside the workspace.
function Get-WorkspaceRel([string]$p, [string]$baseDir) {
    if (-not $p) { return $null }
    $q = $p.Replace('/', [System.IO.Path]::DirectorySeparatorChar)
    $msys = [regex]::Match($p, '^/([A-Za-z])/(.*)$')
    if ($msys.Success -and $env:OS -eq 'Windows_NT') { $q = $msys.Groups[1].Value + ':\' + $msys.Groups[2].Value.Replace('/', '\') }
    if (-not [System.IO.Path]::IsPathRooted($q)) { $q = Join-Path $baseDir $q }
    $full = [System.IO.Path]::GetFullPath($q).Replace('\', '/')
    $root = $RepoRoot.Replace('\', '/').TrimEnd('/')
    if ($full.ToLower() -eq $root.ToLower()) { return '' }
    if (-not $full.ToLower().StartsWith($root.ToLower() + '/')) { return $null }
    return $full.Substring($root.Length + 1)
}

$script:LockCache = @{}
$ApprovalKinds = '"kind"\s*:\s*"(estimate-approved|estimate-auto-approved|auto-policy-approved|auto-policy-approved-bounded|auto-policy-approved-unlimited)"'

# Returns '' when open, otherwise the reason it is locked.
function Get-LockReason([string]$ideaId) {
    if ($script:LockCache.ContainsKey($ideaId)) { return $script:LockCache[$ideaId] }
    $specsRoot = Join-Path $RepoRoot 'specs'
    $readySpecs = New-Object System.Collections.ArrayList
    $anyPlan = $false
    if (Test-Path -LiteralPath $specsRoot) {
        foreach ($g in @(Get-ChildItem -LiteralPath $specsRoot -Directory -ErrorAction SilentlyContinue)) {
            if (-not [regex]::IsMatch($g.Name, ('^' + [regex]::Escape($ideaId) + '(?![0-9])'), 'IgnoreCase')) { continue }
            foreach ($d in @(Get-ChildItem -LiteralPath $g.FullName -Directory -Filter 'SPEC-*' -ErrorAction SilentlyContinue | Sort-Object Name)) {
                $plan = Join-Path $d.FullName 'plan.md'
                if (-not (Test-Path -LiteralPath $plan)) { continue }
                $anyPlan = $true
                if ((Read-Text $plan) -match '(?im)^[\s|>*-]*\**status\**\W{0,6}ready\b') {
                    [void]$readySpecs.Add([regex]::Match($d.Name, '^SPEC-\d+').Value)
                }
            }
        }
    }
    if ($readySpecs.Count -eq 0) {
        if ($anyPlan) { $r = "no plan.md of $ideaId declares status: ready" } else { $r = "no plan.md exists for any spec of $ideaId" }
        $script:LockCache[$ideaId] = $r
        return $r
    }
    $bc = Join-Path (Join-Path $RepoRoot 'coordination') 'backchannel.jsonl'
    $bcLines = @()
    if (Test-Path -LiteralPath $bc) { $bcLines = @(Read-Lines $bc | Where-Object { $_ -match $ApprovalKinds }) }
    $hdLines = @()
    $tr = Join-Path $RepoRoot 'Traces'
    if (Test-Path -LiteralPath $tr) {
        foreach ($s in @(Get-ChildItem -LiteralPath $tr -Directory -Filter 'Session-*' -ErrorAction SilentlyContinue)) {
            $hd = Join-Path $s.FullName 'HumanDecisions.md'
            if (Test-Path -LiteralPath $hd) { $hdLines += @(Read-Lines $hd | Where-Object { $_ -match '(?i)implement' -and $_ -match '(?i)approv' }) }
        }
    }
    $ideaRx = '(?<![A-Za-z0-9])' + [regex]::Escape($ideaId) + '(?![0-9])'
    foreach ($sid in $readySpecs) {
        $specRx = '(?<![A-Za-z0-9])' + [regex]::Escape($sid) + '(?![0-9])'
        foreach ($l in $bcLines) {
            if ([regex]::IsMatch($l, $specRx) -or [regex]::IsMatch($l, $ideaRx)) { $script:LockCache[$ideaId] = ''; return '' }
        }
        foreach ($l in $hdLines) {
            if ([regex]::IsMatch($l, $specRx)) { $script:LockCache[$ideaId] = ''; return '' }
        }
    }
    $r = "plan ready for {0} but no implement budget approval (backchannel estimate-approved / estimate-auto-approved / auto-policy-approved* event, or HumanDecisions.md implement approval) references it or {1}" -f ($readySpecs -join ', '), $ideaId
    $script:LockCache[$ideaId] = $r
    return $r
}

# Returns '' when allowed, else the lock message.
function Test-PathLock([string]$p, [string]$baseDir) {
    $rel = Get-WorkspaceRel $p $baseDir
    if ($null -eq $rel) { return '' }
    $m = [regex]::Match($rel, '^src/(IDEA-\d+)(-[^/]*)?/', 'IgnoreCase')
    if (-not $m.Success) { return '' }
    $ideaId = $m.Groups[1].Value.ToUpper()
    $reason = Get-LockReason $ideaId
    if (-not $reason) { return '' }
    Add-Violation 'LOCK-001' 'error' 'human' ("Implementation is locked for {0}: {1}. Finish /spec-plan (plan.md status: ready) and approve the implement budget first." -f $rel, $reason) $rel
    return $reason
}

$targets = New-Object System.Collections.ArrayList
$baseDir = $RepoRoot
if ($Hook) {
    $raw = ''
    try { $raw = [Console]::In.ReadToEnd() } catch { exit 0 }
    $obj = $null
    try { $obj = $raw | ConvertFrom-Json } catch { exit 0 }
    if ($null -eq $obj -or $null -eq $obj.tool_input) { exit 0 }
    $fp = $obj.tool_input.file_path
    if (-not $fp) { $fp = $obj.tool_input.notebook_path }
    if (-not $fp) { exit 0 }
    if ($obj.cwd) { $baseDir = [string]$obj.cwd }
    $reason = ''
    try { $reason = Test-PathLock ([string]$fp) $baseDir } catch { exit 0 }
    if ($reason) {
        [Console]::Error.WriteLine(("KCC implementation lock (LOCK-001): writing {0} is blocked - {1}. Run /spec-plan until plan.md has status: ready and get the implement budget approved (token-estimate), then retry." -f $fp, $reason))
        exit 2
    }
    exit 0
}
elseif ($Staged) {
    $old = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $out = @(& git -C $RepoRoot -c core.quotepath=off diff --cached --name-only --relative 2>$null)
    $code = $LASTEXITCODE
    $ErrorActionPreference = $old
    if ($code -ne 0) { Fail-Usage 'not a git repository (or git failed); -Staged needs git.' }
    foreach ($p in $out) { if ($p) { [void]$targets.Add([string]$p) } }
}
elseif ($Path) {
    [void]$targets.Add($Path)
}
else {
    Fail-Usage 'usage: check-impl-lock (-Path <file> | -Staged | -Hook) [-RepoRoot <path>] [-Json]'
}

$checked = 0
foreach ($t in $targets) { $checked++; $null = Test-PathLock $t $baseDir }

$errors = @($violations | Where-Object { $_.severity -eq 'error' })
$status = 'pass'
if ($errors.Count -gt 0) { $status = 'fail' }
if ($Json) {
    [pscustomobject]@{
        tool = 'check-impl-lock'; version = $ToolVersion; scope = $Scope; checked = $checked
        errors = $errors.Count; warnings = 0; status = $status; violations = $violations
    } | ConvertTo-Json -Depth 5
}
else {
    Write-Output ("KCC implementation lock: {0} path(s) checked" -f $checked)
    foreach ($v in $violations) {
        Write-Output ("[{0}] {1} ({2}) {3}: {4}" -f $v.severity.ToUpper(), $v.id, $v.fix_owner, $v.file, $v.message)
    }
    Write-Output ("Errors: {0}  Warnings: 0" -f $errors.Count)
}
if ($errors.Count -gt 0) { exit 1 } else { exit 0 }
