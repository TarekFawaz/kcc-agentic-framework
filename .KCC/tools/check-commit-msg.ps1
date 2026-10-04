<#
KCC framework (c) 2026 Tarek Fawaz, https://tikasway.dev/kcc. Licensed under the terms in LICENSE.

.SYNOPSIS
    Validate a commit message against the KCC convention.

.DESCRIPTION
    Mirror of check-commit-msg.sh. Read-only.
    Protocol: .KCC/kernel/protocols/git-workflow.md
    Contract: .KCC/kernel/contracts/tool-contract.md

    Accepted subject lines (first non-empty, non-comment line):
      SPEC-NNN (Story|Enabler|Bug)-NNN[ T-NNN]: subject
      SPEC-NNN: subject
      (chore|docs|ci|build|test|refactor|fix|feat)[(scope)][!]: subject
      Merge ... | Revert ... | fixup! ... | squash! ... | amend! ...   (pass)
    settings.json git.commit_pattern (POSIX ERE), when set, replaces the three
    built-in formats. When a SPEC / item id is given and specs/ exists, the
    spec folder and the Backlog item must exist.

    Violations: COMMIT-MSG-001 empty | 002 format | 003 unknown spec |
                004 unknown backlog item | 005 specs/ absent (warning) |
                006 subject longer than 72 characters (warning)
    Exit: 0 pass | 1 violations | 2 usage/environment.
    PowerShell 5.1 compatible. ASCII-only. No && operator, no ternary.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .KCC\tools\check-commit-msg.ps1 -Message "SPEC-003 Story-001: add CSV parser" -Json
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .KCC\tools\check-commit-msg.ps1 -File .git\COMMIT_EDITMSG
#>

[CmdletBinding()]
param(
    [string]$RepoRoot,
    [string]$File,
    [string]$Message,
    [string]$Scope = 'message',
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

$haveMessage = $PSBoundParameters.ContainsKey('Message')
if ($File -and $haveMessage) { Fail-Usage 'use -File or -Message, not both' }
if ((-not $File) -and (-not $haveMessage)) {
    Fail-Usage 'usage: check-commit-msg (-File <path> | -Message <text>) [-RepoRoot <path>] [-Json]'
}
if ($File) {
    if (-not (Test-Path -LiteralPath $File -PathType Leaf)) { Fail-Usage "message file not found: $File" }
    $Message = [System.IO.File]::ReadAllText((Resolve-Path -LiteralPath $File).ProviderPath)
}
if ($null -eq $Message) { $Message = '' }

$violations = New-Object System.Collections.ArrayList
function Add-Violation([string]$Code, [string]$Severity, [string]$Owner, [string]$Text, [string]$Path = '') {
    [void]$violations.Add([pscustomobject]@{ id = $Code; severity = $Severity; fix_owner = $Owner; file = $Path; message = $Text })
}

# ------------------------------------------------------------------ settings
$customPattern = $null
$settingsFile = Join-Path (Join-Path $RepoRoot '.KCC') 'settings.json'
if (Test-Path -LiteralPath $settingsFile) {
    try {
        $cfg = [System.IO.File]::ReadAllText($settingsFile) | ConvertFrom-Json
        if ($cfg -and $cfg.git -and $cfg.git.commit_pattern) { $customPattern = [string]$cfg.git.commit_pattern }
    } catch { $customPattern = $null }
}

# ------------------------------------------------------------------ subject
$subject = ''
foreach ($line in ($Message -split "`r?`n")) {
    if ($line -match '^[ \t]*$') { continue }
    if ($line.StartsWith('#')) { continue }
    $subject = $line
    break
}

$reItem = '^SPEC-[0-9]+ (Story|Enabler|Bug)-[0-9]+( T-[0-9]+)?: [^\s]'
$reSpec = '^SPEC-[0-9]+: [^\s]'
$reMaint = '^(chore|docs|ci|build|test|refactor|fix|feat)(\([A-Za-z0-9._/-]+\))?!?: [^\s]'
$rePass = '^(Merge |Revert |fixup! |squash! |amend! )'
$reIds = '^(SPEC-[0-9]+)( (Story|Enabler|Bug)-([0-9]+))?'
$convention = "'SPEC-NNN (Story|Enabler|Bug)-NNN: subject', 'SPEC-NNN: subject', or '(chore|docs|ci|build|test|refactor|fix|feat)(scope)?: subject'"
$cs = [System.Text.RegularExpressions.RegexOptions]::None

function Find-SpecDir([string]$Id) {
    $specs = Join-Path $RepoRoot 'specs'
    $parents = @(Get-ChildItem -LiteralPath $specs -Directory -ErrorAction SilentlyContinue | Sort-Object Name)
    foreach ($p in $parents) {
        foreach ($d in @(Get-ChildItem -LiteralPath $p.FullName -Directory -ErrorAction SilentlyContinue | Sort-Object Name)) {
            if (($d.Name -ceq $Id) -or $d.Name.StartsWith($Id + '-', [System.StringComparison]::Ordinal)) { return $d.FullName }
        }
    }
    foreach ($p in $parents) {
        if (($p.Name -ceq $Id) -or $p.Name.StartsWith($Id + '-', [System.StringComparison]::Ordinal)) { return $p.FullName }
    }
    return $null
}
function Test-Item([string]$SpecDir, [string]$Kind, [string]$Num) {
    $backlog = Join-Path $SpecDir 'Backlog'
    if (-not (Test-Path -LiteralPath $backlog -PathType Container)) { return $false }
    foreach ($f in @(Get-ChildItem -LiteralPath $backlog -File -Filter '*.md' -ErrorAction SilentlyContinue)) {
        if (($f.Name -ceq ($Kind + '-' + $Num + '.md')) -or $f.Name.StartsWith($Kind + '-' + $Num + '-', [System.StringComparison]::Ordinal)) { return $true }
    }
    return $false
}
function Test-Ids {
    $m = [regex]::Match($subject, $reIds, $cs)
    if (-not $m.Success) { return }
    $spec = $m.Groups[1].Value
    $kind = $m.Groups[3].Value
    $num = $m.Groups[4].Value
    if (-not (Test-Path -LiteralPath (Join-Path $RepoRoot 'specs') -PathType Container)) {
        Add-Violation 'COMMIT-MSG-005' 'warning' 'human' ("specs/ folder not found; {0} could not be verified" -f $spec) ''
        return
    }
    $dir = Find-SpecDir $spec
    if (-not $dir) {
        Add-Violation 'COMMIT-MSG-003' 'error' 'implementer' ("{0} has no spec folder under specs/ (expected specs/IDEA-*-Specs/{0}-*/)" -f $spec) 'specs/'
        return
    }
    if ($kind -and (-not (Test-Item $dir $kind $num))) {
        $rel = $dir.Substring($RepoRoot.Length + 1).Replace('\', '/')
        Add-Violation 'COMMIT-MSG-004' 'error' 'implementer' ("{0}-{1} is not a backlog item of {2} (expected {3}/Backlog/{0}-{1}-*.md)" -f $kind, $num, $spec, $rel) ($rel + '/Backlog')
    }
}

if (-not $subject) {
    Add-Violation 'COMMIT-MSG-001' 'error' 'implementer' 'commit message is empty' ''
}
elseif ([regex]::IsMatch($subject, $rePass, $cs)) {
    # merge / revert / fixup / squash / amend commits pass as they are
}
else {
    $formatOk = $false
    if ($customPattern) {
        try { $formatOk = [regex]::IsMatch($subject, $customPattern, $cs) }
        catch { Fail-Usage ("settings.json git.commit_pattern is not a valid POSIX ERE: {0}" -f $customPattern) }
        if (-not $formatOk) {
            Add-Violation 'COMMIT-MSG-002' 'error' 'implementer' ("subject '{0}' does not match settings.json git.commit_pattern: {1}" -f $subject, $customPattern) ''
        }
    }
    else {
        if ([regex]::IsMatch($subject, $reItem, $cs) -or [regex]::IsMatch($subject, $reSpec, $cs) -or [regex]::IsMatch($subject, $reMaint, $cs)) { $formatOk = $true }
        if (-not $formatOk) {
            Add-Violation 'COMMIT-MSG-002' 'error' 'implementer' ("subject '{0}' does not follow the convention: {1}" -f $subject, $convention) ''
        }
    }
    if ($formatOk) {
        Test-Ids
        if ($subject.Length -gt 72) {
            Add-Violation 'COMMIT-MSG-006' 'warning' 'implementer' ("subject is {0} characters; keep it at 72 or fewer" -f $subject.Length) ''
        }
    }
}

$errors = @($violations | Where-Object { $_.severity -eq 'error' })
$warnings = @($violations | Where-Object { $_.severity -eq 'warning' })
$status = 'pass'
if ($errors.Count -gt 0) { $status = 'fail' }
if ($Json) {
    [pscustomobject]@{
        tool = 'check-commit-msg'; version = $ToolVersion; scope = $Scope; subject = $subject
        errors = $errors.Count; warnings = $warnings.Count; status = $status; violations = $violations
    } | ConvertTo-Json -Depth 5
}
else {
    Write-Output ("KCC commit message: {0}" -f $subject)
    foreach ($v in $violations) {
        Write-Output ("[{0}] {1} ({2}) {3}: {4}" -f $v.severity.ToUpper(), $v.id, $v.fix_owner, $v.file, $v.message)
    }
    Write-Output ("Errors: {0}  Warnings: {1}" -f $errors.Count, $warnings.Count)
}
if ($errors.Count -gt 0) { exit 1 } else { exit 0 }
