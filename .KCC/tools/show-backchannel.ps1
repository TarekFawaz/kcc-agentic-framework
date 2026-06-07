<#
KCC framework (c) 2026 Tarek Fawaz, https://tikasway.dev/kcc. Licensed under the terms in LICENSE.

.SYNOPSIS
    Show a human-readable view of coordination/backchannel.jsonl.

.DESCRIPTION
    Reads the framework backchannel JSONL log, filters common fields, and
    prints a compact table by default. This command is read-only and writes no
    output files; runtime exports should go under Traces/ when an agent session
    needs them.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .KCC\tools\show-backchannel.ps1 -Last 20

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .KCC\tools\show-backchannel.ps1 -Kind approval -Spec SPEC-003
#>

[CmdletBinding()]
param(
    [int]$Last = 20,

    [string]$From,

    [string]$Kind,

    [string]$Spec,

    [string]$RepoRoot,

    [switch]$Json
)

$ErrorActionPreference = 'Stop'

function Resolve-RepoRootFromTool {
    if ($PSScriptRoot) {
        $toolDir = $PSScriptRoot
    } elseif ($MyInvocation.MyCommand.Path) {
        $toolDir = Split-Path -Parent $MyInvocation.MyCommand.Path
    } else {
        return (Get-Location).Path
    }

    $parent = Split-Path -Parent $toolDir
    if ((Split-Path -Leaf $parent) -eq '.KCC') {
        return (Split-Path -Parent $parent)
    }
    return $parent
}

function Get-FieldValue {
    param(
        [Parameter(Mandatory)]$Object,
        [Parameter(Mandatory)][string[]]$Names
    )
    foreach ($name in $Names) {
        if ($Object.PSObject.Properties.Name -contains $name) {
            return $Object.$name
        }
    }
    return $null
}

if (-not $RepoRoot) {
    $RepoRoot = Resolve-RepoRootFromTool
}

$path = Join-Path $RepoRoot 'coordination/backchannel.jsonl'
if (-not (Test-Path -LiteralPath $path)) {
    Write-Host "No backchannel log found at $path"
    exit 0
}

$lines = Get-Content -LiteralPath $path -ErrorAction Stop | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
$events = New-Object System.Collections.ArrayList
foreach ($line in $lines) {
    try {
        [void]$events.Add(($line | ConvertFrom-Json))
    } catch {
        [void]$events.Add([pscustomobject]@{
            timestamp = ''
            kind = 'invalid-json'
            agent = ''
            summary = $line
        })
    }
}

if ($From) {
    $events = @($events | Where-Object {
        $value = Get-FieldValue -Object $_ -Names @('agent', 'from', 'source')
        "$value" -eq $From
    })
}
if ($Kind) {
    $events = @($events | Where-Object {
        $value = Get-FieldValue -Object $_ -Names @('kind', 'event_kind', 'event')
        "$value" -eq $Kind
    })
}
if ($Spec) {
    $events = @($events | Where-Object {
        $value = Get-FieldValue -Object $_ -Names @('spec', 'spec_id', 'target')
        "$value" -eq $Spec -or "$_" -match [regex]::Escape($Spec)
    })
}

$events = @($events | Select-Object -Last $Last)

if ($Json) {
    $events | ConvertTo-Json -Depth 8
    exit 0
}

$rows = foreach ($event in $events) {
    [pscustomobject]@{
        Time = Get-FieldValue -Object $event -Names @('timestamp', 'time', 'at', 'created_at')
        Kind = Get-FieldValue -Object $event -Names @('kind', 'event_kind', 'event')
        Agent = Get-FieldValue -Object $event -Names @('agent', 'from', 'source')
        Target = Get-FieldValue -Object $event -Names @('spec', 'spec_id', 'target', 'idea_id')
        Summary = Get-FieldValue -Object $event -Names @('summary', 'message', 'decision', 'note')
    }
}

if (-not $rows) {
    Write-Host 'No matching backchannel events.'
    exit 0
}

$rows | Format-Table -AutoSize
