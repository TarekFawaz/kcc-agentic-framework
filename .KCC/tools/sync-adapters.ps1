<#
KCC framework (c) 2026 Tarek Fawaz, https://tikasway.dev/kcc. Licensed under the terms in LICENSE.

.SYNOPSIS
    Initialize workflow infrastructure and regenerate per-harness files from .KCC/kernel and .KCC/capabilities.

.DESCRIPTION
    Ensures a clean repo has the root orchestrator files and state folders
    needed for the spec-driven workflow, then reads .KCC/capabilities/agents/*.md
    and .KCC/capabilities/skills/*.md, while using .KCC/kernel/ for protocols,
    templates, adapters, and governance contracts. It writes per-harness files for one or all of:

      claude    -> .claude/agents/{name}.md, .claude/skills/{name}/SKILL.md
      codex     -> .codex/agents/{name}.md, .codex/skills/{name}/SKILL.md, .codex/config.toml
      opencode  -> .opencode/agents/{name}.md, .opencode/commands/{name}.md,
                   .opencode/skills/{name}/SKILL.md, opencode.json
      generic   -> .agents/agents/{name}.md, .agents/skills/{name}/SKILL.md,
                   .agents/config.json, .agents/manifest.json, .agents/tools/README.md
      ollama    -> ollama/agents.json, ollama/README.md
      dsh       -> .dsh/skills/{name}/SKILL.md

    "all" runs every adapter (default).

    The neutral .KCC/kernel/ and .KCC/capabilities/ trees are the source of truth. Edit them,
    then rerun this script to regenerate the per-harness wire-up files. Root
    AGENTS.md and CLAUDE.md are created from defaults only when missing.
    Generated files under .claude/, .codex/, .opencode/, .agents/, .dsh/, and ollama/
    may be overwritten on the next sync.

    PowerShell 5.1 compatible. UTF-8 (no BOM) output. No && operator.

.PARAMETER Harness
    Which harness to generate for. One of: claude, codex, opencode, generic, ollama, dsh, all.
    Defaults to "all". Accepts positional argument:

        .KCC\tools\sync-adapters.ps1 codex

    is equivalent to

        .KCC\tools\sync-adapters.ps1 -Harness codex

.PARAMETER RepoRoot
    Path to the repo root. Optional. Defaults to the parent of .KCC when this
    script lives in {repo}/.KCC/tools/.

.EXAMPLE
    # First-time project initialization (recommended wrapper):
    powershell -ExecutionPolicy Bypass -File .KCC\tools\framework-init.ps1 -Harness codex

.EXAMPLE
    # Generate every harness (default; most common):
    powershell -ExecutionPolicy Bypass -File .KCC\tools\sync-adapters.ps1

.EXAMPLE
    # Generate Claude only:
    powershell -ExecutionPolicy Bypass -File .KCC\tools\sync-adapters.ps1 -Harness claude

.EXAMPLE
    # Generate Codex only (positional):
    powershell -ExecutionPolicy Bypass -File .KCC\tools\sync-adapters.ps1 codex

.EXAMPLE
    # Generate OpenCode only:
    powershell -ExecutionPolicy Bypass -File .KCC\tools\sync-adapters.ps1 -Harness opencode

.EXAMPLE
    # Generate generic .agents bindings only:
    powershell -ExecutionPolicy Bypass -File .KCC\tools\sync-adapters.ps1 -Harness generic

.EXAMPLE
    # Generate Ollama bindings only:
    powershell -ExecutionPolicy Bypass -File .KCC\tools\sync-adapters.ps1 -Harness ollama

.EXAMPLE
    # Generate native project-local DeepSeek harness skills:
    powershell -ExecutionPolicy Bypass -File .KCC\tools\sync-adapters.ps1 -Harness dsh

.EXAMPLE
    # Generate native project-local Codex skills:
    powershell -ExecutionPolicy Bypass -File .KCC\tools\sync-adapters.ps1 codex -InstallCodexSkills
#>

[CmdletBinding()]
param(
    [Parameter(Position=0)]
    [ValidateSet('claude', 'codex', 'opencode', 'generic', 'ollama', 'dsh', 'all')]
    [string]$Harness = 'all',

    [string]$RepoRoot,

    # Native Codex skills are project-local by default and are always written
    # to .codex/skills/{name}/SKILL.md. This flag is accepted as an explicit
    # initializer intent; it does not write anything under $HOME.
    [switch]$InstallCodexSkills,

    # Deprecated/no-op: kept so older commands fail softly. Global prompt
    # installation belongs in a separate pipeline/tool, not this initializer.
    [switch]$InstallCodexPrompts
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

if (-not $RepoRoot) {
    $RepoRoot = Resolve-RepoRootFromTool
}

function Get-KernelRoot {
    param([Parameter(Mandatory)][string]$Root)
    $kccKernel = Join-Path $Root '.KCC/kernel'
    if (Test-Path -LiteralPath $kccKernel) { return $kccKernel }

    $kccFramework = Join-Path $Root '.KCC/framework'
    if (Test-Path -LiteralPath $kccFramework) { return $kccFramework }

    $legacyFramework = Join-Path $Root 'framework'
    if (Test-Path -LiteralPath $legacyFramework) { return $legacyFramework }

    return $kccKernel
}

function Get-CapabilitiesRoot {
    param([Parameter(Mandatory)][string]$Root)
    $kccCapabilities = Join-Path $Root '.KCC/capabilities'
    if (Test-Path -LiteralPath $kccCapabilities) { return $kccCapabilities }

    $kccFramework = Join-Path $Root '.KCC/framework'
    if (Test-Path -LiteralPath $kccFramework) { return $kccFramework }

    $legacyFramework = Join-Path $Root 'framework'
    if (Test-Path -LiteralPath $legacyFramework) { return $legacyFramework }

    return $kccCapabilities
}

if ($InstallCodexPrompts) {
    Write-Warning '-InstallCodexPrompts is deprecated and now a no-op. Use -InstallCodexSkills for project-local Codex skill initialization.'
}

# ============================================================
# Helpers
# ============================================================

function Remove-ControlChars {
    # Strip disallowed C0/C1 control characters from generated text so a stray
    # control char (e.g. a backtick-escape like `b -> backspace 0x08 that
    # slipped into a double-quoted here-string) can never corrupt output.
    # Allowed whitespace controls are preserved: tab (0x09), LF (0x0A), CR (0x0D).
    param(
        [Parameter(Mandatory=$false)]
        [AllowEmptyString()]
        [AllowNull()]
        [string]$Text = ''
    )
    if (-not $Text) { return $Text }
    # Remove 0x00-0x08, 0x0B, 0x0C, 0x0E-0x1F, and DEL/C1 range 0x7F-0x9F.
    $controlPattern = ('[{0}-{1}{2}{3}{4}-{5}{6}-{7}]' -f ([char]0x00), ([char]0x08), ([char]0x0B), ([char]0x0C), ([char]0x0E), ([char]0x1F), ([char]0x7F), ([char]0x9F))
    return [regex]::Replace($Text, $controlPattern, '')
}

function Write-Utf8File {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory=$false)]
        [AllowEmptyString()]
        [string]$Content = ''
    )
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
    }
    # Write-time guard: never let disallowed control characters reach disk.
    $Content = Remove-ControlChars -Text $Content
    # UTF-8 without BOM (5.1's Out-File -Encoding utf8 writes a BOM; use .NET directly)
    $utf8NoBom = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllText($Path, $Content, $utf8NoBom)
}

function Split-Frontmatter {
    param([Parameter(Mandatory)][string]$Text)
    $normalized = $Text -replace "`r`n", "`n"
    if (-not $normalized.StartsWith("---`n")) {
        throw "File does not start with YAML frontmatter delimiter."
    }
    $rest = $normalized.Substring(4)
    $endIdx = $rest.IndexOf("`n---`n")
    if ($endIdx -lt 0) {
        $endIdx = $rest.IndexOf("`n---")
        if ($endIdx -lt 0) { throw "No closing frontmatter delimiter found." }
    }
    $yaml = $rest.Substring(0, $endIdx)
    $body = $rest.Substring($endIdx).TrimStart("`n", '-').TrimStart("`n")
    return @{ Yaml = $yaml; Body = $body }
}

function ConvertFrom-MiniYaml {
    param([Parameter(Mandatory)][string]$Yaml)
    $lines = $Yaml -split "`n"
    $result = [ordered]@{}
    $i = 0
    while ($i -lt $lines.Count) {
        $line = $lines[$i]
        if ([string]::IsNullOrWhiteSpace($line)) { $i++; continue }
        if ($line -match '^\s*#') { $i++; continue }

        $m = [regex]::Match($line, '^([A-Za-z0-9_\-]+)\s*:\s*(.*)$')
        if (-not $m.Success) { $i++; continue }

        $key = $m.Groups[1].Value
        $val = $m.Groups[2].Value.Trim()

        if ($val -eq '>' -or $val -eq '|') {
            $i++
            $sb = New-Object System.Text.StringBuilder
            while ($i -lt $lines.Count -and ($lines[$i] -match '^\s+\S' -or [string]::IsNullOrWhiteSpace($lines[$i]))) {
                if ([string]::IsNullOrWhiteSpace($lines[$i])) {
                    if ($val -eq '|') { [void]$sb.AppendLine() }
                    else { [void]$sb.Append(' ') }
                } else {
                    $stripped = $lines[$i] -replace '^\s+', ''
                    if ($val -eq '>') {
                        if ($sb.Length -gt 0) { [void]$sb.Append(' ') }
                        [void]$sb.Append($stripped)
                    } else {
                        [void]$sb.AppendLine($stripped)
                    }
                }
                $i++
            }
            $result[$key] = $sb.ToString().Trim()
            continue
        }

        if ($val -eq '' -or $val -eq '[]') {
            if ($val -eq '[]') {
                $result[$key] = @()
                $i++
                continue
            }
            $i++
            $items = New-Object System.Collections.ArrayList
            while ($i -lt $lines.Count -and $lines[$i] -match '^\s+-\s*(.*)$') {
                $itemMatch = [regex]::Match($lines[$i], '^\s+-\s*(.*)$')
                $itemVal = $itemMatch.Groups[1].Value.Trim()
                $itemVal = ($itemVal -replace '\s+#.*$', '').Trim()
                if ($itemVal -ne '') { [void]$items.Add($itemVal) }
                $i++
            }
            $result[$key] = @($items)
            continue
        }

        if ($val.StartsWith('"') -and $val.EndsWith('"')) {
            $val = $val.Substring(1, $val.Length - 2)
        } elseif ($val.StartsWith("'") -and $val.EndsWith("'")) {
            $val = $val.Substring(1, $val.Length - 2)
        }
        $result[$key] = $val
        $i++
    }
    return $result
}

function Normalize-OneLine {
    param([string]$Text)
    if (-not $Text) { return '' }
    return (($Text -replace "`r?`n", ' ') -replace '\s+', ' ').Trim()
}

function Format-FoldedYamlValue {
    param(
        [string]$Text,
        [string]$Indent = '  '
    )
    $line = Normalize-OneLine -Text $Text
    if (-not $line) { return $Indent }
    return $Indent + $line
}

function ConvertTo-DisplayName {
    param([Parameter(Mandatory)][string]$Name)
    $words = $Name -split '-'
    $displayWords = foreach ($w in $words) {
        if ($w.Length -le 1) { $w.ToUpperInvariant() }
        else { $w.Substring(0,1).ToUpperInvariant() + $w.Substring(1) }
    }
    return ($displayWords -join ' ')
}

function ConvertTo-ShortDescription {
    param([string]$Description)
    $line = Normalize-OneLine -Text $Description
    $line = ($line -replace '\s+Usage:\s*/.*$', '').Trim()
    if ($line.Length -gt 120) {
        return $line.Substring(0, 117).TrimEnd() + '...'
    }
    return $line
}

function Format-SimpleYamlString {
    param([string]$Text)
    $safe = (Normalize-OneLine -Text $Text) -replace '"', '\"'
    return '"' + $safe + '"'
}

function New-SkillPackageContent {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)]$Meta,
        [Parameter(Mandatory)][string]$Body,
        [Parameter(Mandatory)][string]$ArgumentToken,
        [Parameter(Mandatory)][string]$Compatibility
    )
    $desc = $Meta['description']
    $descLine = Format-FoldedYamlValue -Text $desc
    $obsidian = Format-ObsidianBlock -Meta $Meta
    $obsidianBlock = if ($obsidian) { "`n$obsidian" } else { '' }
    $placeholder = if ($Meta['argument-placeholder']) { $Meta['argument-placeholder'] } else { '<ARGS>' }
    $rewrittenBody = ($Body -replace [regex]::Escape($placeholder), $ArgumentToken)

    $fm = @"
---
name: $Name
description: >
$descLine
compatibility: $Compatibility
$obsidianBlock
---
"@
    $final = $fm + "`n`n" + $rewrittenBody.TrimStart("`n")
    if (-not $final.EndsWith("`n")) { $final += "`n" }
    return $final
}

function New-SkillOpenAiYamlContent {
    param(
        [Parameter(Mandatory)][string]$Name,
        [string]$Description
    )
    $display = Format-SimpleYamlString -Text (ConvertTo-DisplayName -Name $Name)
    $short = Format-SimpleYamlString -Text (ConvertTo-ShortDescription -Description $Description)
    $defaultPrompt = Format-SimpleYamlString -Text ("/$Name ")
    return @"
interface:
  display_name: $display
  short_description: $short
  default_prompt: $defaultPrompt
"@
}

# ============================================================
# Mapping tables
# ============================================================

# model-class -> harness-specific model id
$ModelClassToClaude = @{
    'strong-reasoning'    = 'claude-opus-4-6'
    'balanced'            = 'claude-sonnet-4-6'
    'fast-implementation' = 'claude-haiku-4-5'
    'local-strong'        = 'claude-opus-4-6'
    'local-fast'          = 'claude-haiku-4-5'
}

$ModelClassToCodex = @{
    'strong-reasoning'    = 'gpt-5'
    'balanced'            = 'gpt-5-mini'
    'fast-implementation' = 'gpt-5-nano'
    'local-strong'        = 'gpt-5'
    'local-fast'          = 'gpt-5-nano'
}

$ModelClassToOpenCode = @{
    'strong-reasoning'    = 'anthropic/claude-opus-4-6'
    'balanced'            = 'anthropic/claude-sonnet-4-6'
    'fast-implementation' = 'anthropic/claude-haiku-4-5'
    'local-strong'        = 'ollama/qwen2.5:72b'
    'local-fast'          = 'ollama/qwen2.5:7b'
}

$ModelClassToOllama = @{
    'strong-reasoning'    = 'qwen2.5:72b'
    'balanced'            = 'qwen2.5:32b'
    'fast-implementation' = 'qwen2.5:14b'
    'local-strong'        = 'qwen2.5:72b'
    'local-fast'          = 'qwen2.5:7b'
}

# neutral tool -> Claude tool names
$NeutralToolToClaude = @{
    'read'   = @('Read')
    'search' = @('Glob', 'Grep')
    'edit'   = @('Write', 'Edit')
    'web'    = @('WebSearch', 'WebFetch')
}

# Per-agent exec-scope overrides for Claude (narrow Bash scopes).
$ExecOverrides = @{
    'idea-interrogator' = @('Bash(git log*)')
    'spec-writer'       = @('Bash(git log*)', 'Bash(git diff*)')
    'architect'         = @('Bash(git log*)', 'Bash(git diff*)')
    'planner'           = @('Bash(git log*)', 'Bash(git diff*)')
    'implementer'       = @('Bash')
    'verifier'          = @('Bash(git diff*)', 'Bash(git log*)')
}

function Format-ObsidianBlock {
    # Render the Obsidian-standard metadata fields from $Meta as a YAML
    # snippet suitable for embedding inside an existing frontmatter block.
    # Returns an empty string if no Obsidian fields are present.
    param([Parameter(Mandatory)]$Meta)
    $fields = @('title', 'aliases', 'tags', 'created', 'updated', 'version', 'status', 'copyright', 'homepage', 'license')
    $present = $fields | Where-Object { $Meta.Contains($_) }
    if (-not $present) { return '' }

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append("# Obsidian metadata (Obsidian vault + framework provenance)`n")
    foreach ($key in $present) {
        $val = $Meta[$key]
        if ($val -is [array] -or $val -is [System.Collections.IEnumerable] -and -not ($val -is [string])) {
            [void]$sb.Append("${key}:`n")
            foreach ($item in $val) {
                $clean = "$item".Trim()
                if ($clean -ne '') { [void]$sb.Append("  - $clean`n") }
            }
        } else {
            [void]$sb.Append("${key}: $val`n")
        }
    }
    return $sb.ToString().TrimEnd("`n")
}

function Resolve-ClaudeTools {
    param(
        [Parameter(Mandatory)][string]$AgentName,
        [Parameter(Mandatory)]$NeutralTools
    )
    $out = New-Object System.Collections.ArrayList
    foreach ($t in $NeutralTools) {
        $clean = ($t -replace '\s+#.*$', '').Trim()
        if ($clean -eq 'exec') {
            if ($ExecOverrides.ContainsKey($AgentName)) {
                foreach ($scope in $ExecOverrides[$AgentName]) { [void]$out.Add($scope) }
            } else {
                [void]$out.Add('Bash')
            }
        } elseif ($NeutralToolToClaude.ContainsKey($clean)) {
            foreach ($mapped in $NeutralToolToClaude[$clean]) { [void]$out.Add($mapped) }
        }
    }
    return @($out)
}

# neutral tool -> OpenCode permission map
function Resolve-OpenCodePermissions {
    param([Parameter(Mandatory)]$NeutralTools)
    $hasRead = $false
    $hasSearch = $false
    $hasEdit = $false
    $hasExec = $false
    $hasWeb = $false
    foreach ($t in $NeutralTools) {
        $clean = ($t -replace '\s+#.*$', '').Trim()
        switch ($clean) {
            'read'   { $hasRead = $true }
            'search' { $hasSearch = $true }
            'edit'   { $hasEdit = $true }
            'exec'   { $hasExec = $true }
            'web'    { $hasWeb = $true }
        }
    }
    $map = [ordered]@{}
    if ($hasRead -or $hasSearch) { $map['read'] = 'allow' }
    if ($hasSearch) {
        $map['glob'] = 'allow'
        $map['grep'] = 'allow'
        $map['list'] = 'allow'
    }
    $map['edit'] = if ($hasEdit) { 'allow' } else { 'deny' }
    $map['bash'] = if ($hasExec) { 'allow' } else { 'deny' }
    if ($hasWeb) {
        $map['webfetch'] = 'allow'
        $map['websearch'] = 'allow'
    }
    $map['skill'] = 'allow'
    return $map
}

# ============================================================
# Read the neutral framework
# ============================================================

function Read-NeutralAgents {
    param([Parameter(Mandatory)][string]$Root)
    $dir = Join-Path (Get-CapabilitiesRoot -Root $Root) 'agents'
    if (-not (Test-Path -LiteralPath $dir)) {
        throw "Neutral agents directory not found: $dir"
    }
    $out = New-Object System.Collections.ArrayList
    foreach ($file in (Get-ChildItem -LiteralPath $dir -Filter '*.md' -File)) {
        $raw = [System.IO.File]::ReadAllText($file.FullName, [System.Text.Encoding]::UTF8)
        $parts = Split-Frontmatter -Text $raw
        $meta  = ConvertFrom-MiniYaml -Yaml $parts.Yaml
        $name  = if ($meta['name']) { $meta['name'] } else { [IO.Path]::GetFileNameWithoutExtension($file.Name) }
        [void]$out.Add([pscustomobject]@{
            Name = $name
            Meta = $meta
            Body = $parts.Body
        })
    }
    return @($out)
}

function Read-NeutralSkills {
    param([Parameter(Mandatory)][string]$Root)
    $dir = Join-Path (Get-CapabilitiesRoot -Root $Root) 'skills'
    if (-not (Test-Path -LiteralPath $dir)) {
        throw "Neutral skills directory not found: $dir"
    }
    $out = New-Object System.Collections.ArrayList
    foreach ($file in (Get-ChildItem -LiteralPath $dir -Filter '*.md' -File)) {
        $raw = [System.IO.File]::ReadAllText($file.FullName, [System.Text.Encoding]::UTF8)
        $parts = Split-Frontmatter -Text $raw
        $meta  = ConvertFrom-MiniYaml -Yaml $parts.Yaml
        $name  = if ($meta['name']) { $meta['name'] } else { [IO.Path]::GetFileNameWithoutExtension($file.Name) }
        [void]$out.Add([pscustomobject]@{
            Name = $name
            Meta = $meta
            Body = $parts.Body
        })
    }
    return @($out)
}

# ============================================================
# Framework initialization
# ============================================================

function Get-SkillUsage {
    param(
        [Parameter(Mandatory)][string]$Name,
        [string]$Description
    )
    $line = Normalize-OneLine -Text $Description
    $m = [regex]::Match($line, 'Usage:\s*(.+)$')
    if ($m.Success) { return $m.Groups[1].Value.Trim() }
    return "/$Name"
}

function Get-DelegateList {
    param($Meta)
    if (-not $Meta.Contains('delegates-to')) { return @() }
    $value = $Meta['delegates-to']
    if ($value -is [array]) { return @($value | Where-Object { "$_".Trim() -ne '' }) }
    if ($value -is [System.Collections.IEnumerable] -and -not ($value -is [string])) {
        return @($value | Where-Object { "$_".Trim() -ne '' })
    }
    $text = "$value".Trim()
    if (-not $text -or $text -eq '[]') { return @() }
    return @($text)
}

function New-AgentTable {
    param([Parameter(Mandatory)]$Agents)
    $lines = New-Object System.Collections.ArrayList
    [void]$lines.Add('| Agent | Role | Model class | Description |')
    [void]$lines.Add('|-------|------|-------------|-------------|')
    foreach ($a in $Agents) {
        $role = Normalize-OneLine -Text $a.Meta['role']
        $modelClass = Normalize-OneLine -Text $a.Meta['model-class']
        $desc = Normalize-OneLine -Text $a.Meta['description']
        [void]$lines.Add(('| `{0}` | {1} | `{2}` | {3} |' -f $a.Name, $role, $modelClass, $desc))
    }
    return ($lines -join "`n")
}

function New-SkillTable {
    param([Parameter(Mandatory)]$Skills)
    $lines = New-Object System.Collections.ArrayList
    [void]$lines.Add('| Skill | Usage | Delegates to |')
    [void]$lines.Add('|-------|-------|--------------|')
    foreach ($s in $Skills) {
        $usage = Get-SkillUsage -Name $s.Name -Description $s.Meta['description']
        $delegates = Get-DelegateList -Meta $s.Meta
        $delegateText = if ($delegates.Count) { ($delegates | ForEach-Object { ('`{0}`' -f $_) }) -join ', ' } else { '(direct file read)' }
        [void]$lines.Add(('| `{0}` | `{1}` | {2} |' -f $s.Name, $usage, $delegateText))
    }
    return ($lines -join "`n")
}

function New-RouteTable {
    param([Parameter(Mandatory)]$Skills)
    $lines = New-Object System.Collections.ArrayList
    [void]$lines.Add('| Trigger | Skill | Agent invoked |')
    [void]$lines.Add('|---------|-------|---------------|')
    foreach ($s in $Skills) {
        $usage = Get-SkillUsage -Name $s.Name -Description $s.Meta['description']
        $delegates = Get-DelegateList -Meta $s.Meta
        $delegateText = if ($delegates.Count) { ($delegates | ForEach-Object { ('`{0}`' -f $_) }) -join ', ' } else { '(none)' }
        [void]$lines.Add(('| `{0}` | `{1}` | {2} |' -f $usage, $s.Name, $delegateText))
    }
    return ($lines -join "`n")
}

function New-HarnessOutputTable {
    $lines = @(
        '| Harness | Generated paths |',
        '|---------|-----------------|',
        '| `claude` | `.claude/agents/`, `.claude/skills/`, `CLAUDE.md` if missing |',
        '| `codex` | `.codex/agents/`, `.codex/skills/*/SKILL.md`, `.codex/tools/`, `.codex/config.toml`, `AGENTS.md` if missing |',
        '| `opencode` | `.opencode/agents/`, `.opencode/commands/`, `.opencode/skills/`, `opencode.json`, `AGENTS.md` if missing |',
        '| `generic` | `.agents/agents/`, `.agents/skills/`, `.agents/tools/`, `.agents/config.json`, `.agents/manifest.json` |',
        '| `ollama` | `ollama/agents.json`, `ollama/README.md` |',
        '| `dsh` | `.dsh/skills/*/SKILL.md`, `AGENTS.md` if missing |'
    )
    return ($lines -join "`n")
}

function New-ModelClassTable {
    return @'
| Class | Intended use |
|-------|--------------|
| `strong-reasoning` | Deep analysis, interrogation, architecture, planning, implementation |
| `balanced` | Verification, migration, moderate-complexity analysis |
| `fast-implementation` | Butler and token-budget meta-agent work |
| `local-strong` | Local-model strong reasoning through an Ollama-compatible harness |
| `local-fast` | Local-model low-cost support work through an Ollama-compatible harness |
'@
}

function Expand-OrchestratorTemplate {
    param(
        [Parameter(Mandatory)][string]$TemplatePath,
        [Parameter(Mandatory)]$Agents,
        [Parameter(Mandatory)]$Skills
    )
    if (-not (Test-Path -LiteralPath $TemplatePath)) {
        throw "Orchestrator template not found: $TemplatePath"
    }
    $text = [System.IO.File]::ReadAllText($TemplatePath, [System.Text.Encoding]::UTF8)
    $text = $text.Replace('{{DATE}}', (Get-Date).ToString('yyyy-MM-dd'))
    $text = $text.Replace('{{AGENT_TABLE}}', (New-AgentTable -Agents $Agents))
    $text = $text.Replace('{{SKILL_TABLE}}', (New-SkillTable -Skills $Skills))
    $text = $text.Replace('{{ROUTE_TABLE}}', (New-RouteTable -Skills $Skills))
    $text = $text.Replace('{{HARNESS_OUTPUT_TABLE}}', (New-HarnessOutputTable))
    $text = $text.Replace('{{MODEL_CLASS_TABLE}}', (New-ModelClassTable))
    return $text
}

function New-OrchestratorJson {
    param(
        [Parameter(Mandatory)]$Agents,
        [Parameter(Mandatory)]$Skills
    )
    $agentItems = New-Object System.Collections.ArrayList
    foreach ($a in $Agents) {
        [void]$agentItems.Add([ordered]@{
            name = $a.Name
            role = Normalize-OneLine -Text $a.Meta['role']
            model_class = Normalize-OneLine -Text $a.Meta['model-class']
            description = Normalize-OneLine -Text $a.Meta['description']
        })
    }
    $skillItems = New-Object System.Collections.ArrayList
    foreach ($s in $Skills) {
        [void]$skillItems.Add([ordered]@{
            name = $s.Name
            usage = Get-SkillUsage -Name $s.Name -Description $s.Meta['description']
            delegates_to = @(Get-DelegateList -Meta $s.Meta)
            description = Normalize-OneLine -Text $s.Meta['description']
        })
    }
    $payload = [ordered]@{
        schema_version = '1.0'
        generated = (Get-Date).ToUniversalTime().ToString('o')
        agents = $agentItems
        skills = $skillItems
    }
    return ($payload | ConvertTo-Json -Depth 8)
}

function Ensure-FileIfMissing {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory=$false)]
        [AllowEmptyString()]
        [string]$Content = '',
        [Parameter(Mandatory)]$Report
    )
    if (Test-Path -LiteralPath $Path) {
        [void]$Report.Skipped.Add($Path)
        return
    }
    Write-Utf8File -Path $Path -Content $Content
    [void]$Report.Created.Add($Path)
}

function Initialize-FrameworkInfrastructure {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$Harness,
        [Parameter(Mandatory)]$Agents,
        [Parameter(Mandatory)]$Skills
    )
    $report = [ordered]@{
        Created = (New-Object System.Collections.ArrayList)
        Updated = (New-Object System.Collections.ArrayList)
        Skipped = (New-Object System.Collections.ArrayList)
    }

    # ------------------------------------------------------------------
    # Lazy folder generation (test6 fix).
    # Only framework scaffolding is created at init/sync time. Runtime/state
    # folders are created on demand by the workflow that owns them, so a
    # greenfield init never leaves empty `solution/`, `migrations/`, etc.
    #
    #   Folder                      Created by                  When
    #   --------------------------  --------------------------  ---------------------------
    #   ideation/                   idea-interrogator           first idea
    #   specs/                      spec-writer                 first spec
    #   src/IDEA-*                  implementer                 first implementation
    #   architecture/               architect                   first architect pass
    #   Traces/Session-*            butler                      first run (session)
    #   coordination/backchannel.jsonl  backchannel-append.ps1  first event
    #   memory/{type}/              memory-append.ps1           first entry
    #   solution/                   solution-onboard            onboarding existing code
    #   migrations/                 adapt-workflow              importing a workflow
    #
    # Kept here (framework scaffolding, not runtime output):
    #   coordination/ (MOC + orchestrator maps), memory/ (MOC + index/schema),
    #   Traces/ + Traces/_session-template/ + Traces/traces.md MOC.
    # ------------------------------------------------------------------
    foreach ($dir in @('memory', 'coordination', 'Traces', 'Traces/_session-template')) {
        $path = Join-Path $Root $dir
        if (-not (Test-Path -LiteralPath $path)) {
            New-Item -ItemType Directory -Force -Path $path | Out-Null
            [void]$report.Created.Add($path)
        }
    }

    $gitignoreContent = @'
# KCC generated cell outputs and local runtime artifacts.
.claude/
.codex/
.opencode/
.agents/
ollama/
.dsh/

Traces/Session-*/
ideation/IDEA-*/
specs/IDEA-*-Specs/
solution/*/
migrations/IMPORT-*/
src/
dashboard/

coordination/backchannel.jsonl
coordination/backchannel-*.jsonl

.tmp/
.tmp-*
.test-tmp/
.test-tmp
*.tmp-edge-profile-*
.tmp-edge-profile-*/
.tmp-chromium-profile-*/
*.playwright-profile-*/
__pycache__/
*.py[cod]

*.db
*.db-journal
*.sqlite
*.sqlite3

.DS_Store
Thumbs.db
desktop.ini
'@
    Ensure-FileIfMissing -Path (Join-Path $Root '.gitignore') -Content $gitignoreContent -Report $report

    $templateDir = Join-Path (Get-KernelRoot -Root $Root) 'templates'
    $agentsTemplate = Join-Path $templateDir 'AGENTS.md'
    $claudeTemplate = Join-Path $templateDir 'CLAUDE.md'

    $agentsContent = Expand-OrchestratorTemplate -TemplatePath $agentsTemplate -Agents $Agents -Skills $Skills
    Ensure-FileIfMissing -Path (Join-Path $Root 'AGENTS.md') -Content $agentsContent -Report $report

    if ($Harness -eq 'all' -or $Harness -eq 'claude') {
        $claudeContent = Expand-OrchestratorTemplate -TemplatePath $claudeTemplate -Agents $Agents -Skills $Skills
        Ensure-FileIfMissing -Path (Join-Path $Root 'CLAUDE.md') -Content $claudeContent -Report $report
    }

    # ideation/ideas.md, specs/specs.md, solution/solution.md, and the
    # architecture/* MOCs are NOT pre-created here. Their owning workflows
    # (idea-interrogator, spec-writer, solution-onboard, architect) create
    # the folder and its MOC on first use. See the lazy-folder table above.

    $memoryIndex = @"
{
  "entries": [],
  "last_updated": null,
  "schema_version": "1.0"
}
"@
    Ensure-FileIfMissing -Path (Join-Path $Root 'memory/index.json') -Content $memoryIndex -Report $report

    $memoryMoc = @"
---
title: Memory MOC
tags:
  - memory
  - entrypoint
created: $((Get-Date).ToString('yyyy-MM-dd'))
updated: $((Get-Date).ToString('yyyy-MM-dd'))
version: 1.0.0
status: active
---

# Memory

Butler-owned institutional memory. Do not edit generated index rows directly.
"@
    Ensure-FileIfMissing -Path (Join-Path $Root 'memory/memory.md') -Content $memoryMoc -Report $report

    $memorySchema = @"
---
title: Memory Schema
tags:
  - memory
  - protocol
created: $((Get-Date).ToString('yyyy-MM-dd'))
updated: $((Get-Date).ToString('yyyy-MM-dd'))
version: 1.0.0
status: active
---

# Memory Schema

Entry types: `decision`, `pattern`, `incident`, `preference`, `glossary`.

Each entry should include an ID, title, type, date, summary, evidence, and applicability notes.
"@
    Ensure-FileIfMissing -Path (Join-Path $Root 'memory/schema.md') -Content $memorySchema -Report $report

    # coordination/backchannel.jsonl is NOT pre-created; backchannel-append.ps1
    # creates it (and coordination/ if absent) on the first emitted event.

    # Single-quoted here-string: backticks in the markdown (e.g. `backchannel`)
    # are literal and are NOT interpreted as PowerShell escapes. A double-quoted
    # here-string would turn `b -> backspace, `a -> bell, etc., corrupting output.
    $coordinationMoc = @'
---
title: Coordination MOC
tags:
  - coordination
  - entrypoint
created: {{DATE}}
updated: {{DATE}}
version: 1.0.0
status: active
---

# Coordination

- `backchannel.jsonl` - append-only meta-agent event log.
- `orchestrator.md` - generated skill-to-agent route map.
- `orchestrator.json` - generated machine-readable route map.
- `.KCC/tools/backchannel-append.ps1` / `.sh` - deterministic event append helpers that refresh `dashboard/index.html`.
- `.KCC/tools/show-backchannel.ps1` / `.sh` - read-only human-readable backchannel viewers.
'@
    $coordinationMoc = $coordinationMoc.Replace('{{DATE}}', (Get-Date).ToString('yyyy-MM-dd'))
    Ensure-FileIfMissing -Path (Join-Path $Root 'coordination/coordination.md') -Content $coordinationMoc -Report $report

    $today = (Get-Date).ToString('yyyy-MM-dd')
    $orchestratorMd = @(
        '---',
        'title: Orchestrator Map',
        'tags:',
        '  - coordination',
        '  - generated',
        ("created: {0}" -f $today),
        ("updated: {0}" -f $today),
        'version: 1.0.0',
        'status: active',
        '---',
        '',
        '# Orchestrator Map',
        '',
        'Generated from `.KCC/capabilities/agents/` and `.KCC/capabilities/skills/`. Edit `.KCC/kernel/` or `.KCC/capabilities/`, then rerun `.KCC/tools/sync-adapters.ps1` or `.KCC/tools/framework-init.ps1`.',
        '',
        '## Skill Routes',
        '',
        (New-RouteTable -Skills $Skills),
        '',
        '## Agents',
        '',
        (New-AgentTable -Agents $Agents),
        ''
    ) -join "`n"
    $orchestratorMdPath = Join-Path $Root 'coordination/orchestrator.md'
    Write-Utf8File -Path $orchestratorMdPath -Content $orchestratorMd
    [void]$report.Updated.Add($orchestratorMdPath)

    $orchestratorJsonPath = Join-Path $Root 'coordination/orchestrator.json'
    Write-Utf8File -Path $orchestratorJsonPath -Content (New-OrchestratorJson -Agents $Agents -Skills $Skills)
    [void]$report.Updated.Add($orchestratorJsonPath)

    $tracesMoc = @"
---
title: Traces MOC
tags:
  - trace
  - entrypoint
created: $((Get-Date).ToString('yyyy-MM-dd'))
updated: $((Get-Date).ToString('yyyy-MM-dd'))
version: 1.0.0
status: active
---

# Traces

Per-session trace folders live here as `Session-{slug}-{datetime}/`.
"@
    Ensure-FileIfMissing -Path (Join-Path $Root 'Traces/traces.md') -Content $tracesMoc -Report $report

    $sessionFiles = @{
        'session-template.md' = @'
---
title: "Session: <chat title>"
session-id: Session-<slug>-<datetime>
date: <YYYY-MM-DD>
agent: <primary agent name>
spec: SPEC-XXX | none
status: active
tags:
  - trace
  - session
  - lifecycle/<stage>
created: <YYYY-MM-DD>
updated: <YYYY-MM-DD>
version: 0.1.0
---

# Session: <chat title>

Copy this file to `session-{slug}-{datetime}.md` inside a
`Traces/Session-{slug}-{datetime}/` folder.

## Summary

_One paragraph, filled in at session end._

## Artifacts

- [[Decisions]]
- [[Handovers]]
- [[Actions]]
- [[ToolsUsed]]
- [[HumanActions]]
- [[HumanDecisions]]
- [[TokenUsage]]

## Key decisions

1. _decision title_ - see [[Decisions#1]]
2. _decision title_ - see [[Decisions#2]]
3. _decision title_ - see [[Decisions#3]]

## Outcomes

- Shipped:
- Deferred:
- Follow-up specs created:

## Related

- Spec under work: SPEC-XXX | none
- All traces: [[../traces|Traces MOC]]
- Trace layout protocol: [[../.KCC/kernel/protocols/trace-layout]]
'@
        'Actions.md' = "# Actions`n"
        'ToolsUsed.md' = "# Tools Used`n"
        'Decisions.md' = "# Decisions`n"
        'Handovers.md' = "# Handovers`n"
        'HumanActions.md' = "# Human Actions`n"
        'HumanDecisions.md' = "# Human Decisions`n"
        'TokenUsage.md' = "# Token Usage`n"
    }
    foreach ($name in $sessionFiles.Keys) {
        Ensure-FileIfMissing -Path (Join-Path $Root "Traces/_session-template/$name") -Content $sessionFiles[$name] -Report $report
    }

    return $report
}

# ============================================================
# Per-harness sync functions
# ============================================================

function New-SyncReport {
    return [ordered]@{
        AgentsWritten  = 0
        SkillsWritten  = 0
        ConfigsCreated = 0
        ConfigsSkipped = 0
        Notes          = (New-Object System.Collections.ArrayList)
        Files          = (New-Object System.Collections.ArrayList)
    }
}

# ----- Claude -----

function Invoke-ClaudeSync {
    param(
        [Parameter(Mandatory)]$Agents,
        [Parameter(Mandatory)]$Skills,
        [Parameter(Mandatory)][string]$Root
    )
    $report = New-SyncReport

    $agentsDir = Join-Path $Root '.claude/agents'
    $skillsDir = Join-Path $Root '.claude/skills'

    foreach ($a in $Agents) {
        $name     = $a.Name
        $meta     = $a.Meta
        $modelCls = $meta['model-class']
        $desc     = $meta['description']
        $tools    = if ($meta.Contains('tools-required')) { $meta['tools-required'] } else { @() }

        if (-not $ModelClassToClaude.ContainsKey($modelCls)) {
            Write-Warning "[claude] agent '$name' has unknown model-class '$modelCls' - defaulting to claude-sonnet-4-6"
            $model = 'claude-sonnet-4-6'
        } else {
            $model = $ModelClassToClaude[$modelCls]
        }
        $claudeTools = Resolve-ClaudeTools -AgentName $name -NeutralTools $tools

        $descLine   = '  ' + ($desc -replace "`r?`n", ' ')
        $toolsBlock = ($claudeTools | ForEach-Object { "  - $_" }) -join "`n"
        $obsidian   = Format-ObsidianBlock -Meta $meta
        $obsidianBlock = if ($obsidian) { "`n$obsidian" } else { '' }

        $fm = @"
---
model: $model
description: >
$descLine
allowed-tools:
$toolsBlock
$obsidianBlock
---
"@
        $outPath = Join-Path $agentsDir ("{0}.md" -f $name)
        $body = $a.Body.TrimStart("`n")
        $final = $fm + "`n`n" + $body
        if (-not $final.EndsWith("`n")) { $final += "`n" }
        Write-Utf8File -Path $outPath -Content $final
        Write-Host "[claude   ] [agent ] $outPath"
        $report.AgentsWritten++
        [void]$report.Files.Add($outPath)
    }

    foreach ($s in $Skills) {
        $name        = $s.Name
        $meta        = $s.Meta
        $desc        = $meta['description']
        $placeholder = if ($meta['argument-placeholder']) { $meta['argument-placeholder'] } else { '<ARGS>' }
        $body        = ($s.Body -replace [regex]::Escape($placeholder), '$ARGUMENTS')
        $obsidian    = Format-ObsidianBlock -Meta $meta
        $obsidianBlock = if ($obsidian) { "`n$obsidian" } else { '' }

        $fm = @"
---
description: $desc
$obsidianBlock
---
"@
        $outPath = Join-Path $skillsDir ("{0}/SKILL.md" -f $name)
        $final = $fm + "`n`n" + $body.TrimStart("`n")
        if (-not $final.EndsWith("`n")) { $final += "`n" }
        Write-Utf8File -Path $outPath -Content $final
        Write-Host "[claude   ] [skill ] $outPath"
        $report.SkillsWritten++
        [void]$report.Files.Add($outPath)
    }

    # Seed .claude/settings.json from the kernel template ONLY when absent
    # (so new cells get the token-actuals SessionEnd hook + base hooks/perms).
    # Never overwrite an existing, hand-edited settings.json.
    $claudeSettings = Join-Path $Root '.claude/settings.json'
    if (-not (Test-Path -LiteralPath $claudeSettings)) {
        $settingsTemplate = Join-Path $Root '.KCC/kernel/templates/claude-settings.json'
        if (Test-Path -LiteralPath $settingsTemplate) {
            $tplContent = Get-Content -LiteralPath $settingsTemplate -Raw
            Write-Utf8File -Path $claudeSettings -Content $tplContent
            Write-Host "[claude   ] [config] $claudeSettings (seeded from template)"
            [void]$report.Files.Add($claudeSettings)
            [void]$report.Notes.Add('.claude/settings.json was absent and seeded from kernel template (includes the token-actuals SessionEnd hook).')
        }
        else {
            [void]$report.Notes.Add('.claude/settings.json is absent and no template was found to seed it.')
        }
    }
    else {
        [void]$report.Notes.Add('.claude/settings.json is hand-edited and was not touched.')
    }
    return $report
}

# ----- Codex -----

function Invoke-CodexSync {
    param(
        [Parameter(Mandatory)]$Agents,
        [Parameter(Mandatory)]$Skills,
        [Parameter(Mandatory)][string]$Root
    )
    $report = New-SyncReport

    $agentsDir = Join-Path $Root '.codex/agents'
    $skillsDir = Join-Path $Root '.codex/skills'
    $toolsDir  = Join-Path $Root '.codex/tools'

    foreach ($a in $Agents) {
        $name     = $a.Name
        $meta     = $a.Meta
        $modelCls = $meta['model-class']
        $desc     = $meta['description']
        $role     = $meta['role']
        $tools    = if ($meta.Contains('tools-required')) { $meta['tools-required'] } else { @() }

        $model = if ($ModelClassToCodex.ContainsKey($modelCls)) { $ModelClassToCodex[$modelCls] } else { 'gpt-5-mini' }
        $toolsList = ($tools | ForEach-Object { '  - ' + (($_ -replace '\s+#.*$', '').Trim()) }) -join "`n"

        $descLine = '  ' + ($desc -replace "`r?`n", ' ')
        $obsidian = Format-ObsidianBlock -Meta $meta
        $obsidianBlock = if ($obsidian) { "`n$obsidian" } else { '' }

        $fm = @"
---
name: $name
role: $role
model: $model
model-class: $modelCls
description: >
$descLine
tools:
$toolsList
$obsidianBlock
---
"@
        $outPath = Join-Path $agentsDir ("{0}.md" -f $name)
        $body = $a.Body.TrimStart("`n")
        $final = $fm + "`n`n" + $body
        if (-not $final.EndsWith("`n")) { $final += "`n" }
        Write-Utf8File -Path $outPath -Content $final
        Write-Host "[codex    ] [agent ] $outPath"
        $report.AgentsWritten++
        [void]$report.Files.Add($outPath)
    }

    foreach ($s in $Skills) {
        $name = $s.Name
        $meta = $s.Meta
        $desc = $meta['description']
        # Codex skills are package directories. Keep arguments compatible with
        # slash-command prompt usage by rewriting the neutral placeholder to $1.
        $final = New-SkillPackageContent -Name $name -Meta $meta -Body $s.Body -ArgumentToken '$1' -Compatibility 'codex'
        $outPath = Join-Path $skillsDir ("{0}/SKILL.md" -f $name)
        Write-Utf8File -Path $outPath -Content $final
        Write-Host "[codex    ] [skill ] $outPath"
        $report.SkillsWritten++
        [void]$report.Files.Add($outPath)

        $openAiPath = Join-Path $skillsDir ("{0}/agents/openai.yaml" -f $name)
        $openAiYaml = New-SkillOpenAiYamlContent -Name $name -Description $desc
        Write-Utf8File -Path $openAiPath -Content $openAiYaml
        Write-Host "[codex    ] [skill-ui] $openAiPath"
        [void]$report.Files.Add($openAiPath)
    }

    $toolsReadme = @"
# Codex tools

Codex exposes tools through the active CLI sandbox, approval policy, installed
MCP servers, and enabled plugins. This framework's neutral ``tools-required``
metadata is mirrored into each generated agent file for routing context; the
initializer does not grant tools globally or mutate user-level Codex config.

Keep tool wiring local-first. Add global MCP servers, plugins, or meta-agent
tooling through a separate bootstrap pipeline when the project proves it needs
them.
"@
    $toolsPath = Join-Path $toolsDir 'README.md'
    Write-Utf8File -Path $toolsPath -Content $toolsReadme
    Write-Host "[codex    ] [tools ] $toolsPath"
    [void]$report.Files.Add($toolsPath)

    # .codex/config.toml - basic project pointer; do not overwrite if present.
    $cfgPath = Join-Path $Root '.codex/config.toml'
    if (Test-Path -LiteralPath $cfgPath) {
        $report.ConfigsSkipped++
        [void]$report.Notes.Add('.codex/config.toml exists - left untouched.')
    } else {
        $cfg = @"
# Project-scoped Codex CLI hints. Generated by .KCC/tools/sync-adapters.ps1.
# Edit freely; this file will NOT be overwritten on subsequent syncs.

[project]
name = "spec-driven-framework"
entrypoint = "AGENTS.md"

[notes]
# Codex CLI reads AGENTS.md at the repo root automatically.
# Per-agent .md files live in .codex/agents/ for human navigation;
# Codex does not auto-load them today but they mirror .claude/agents/.
# Native project-local skill packages live in .codex/skills/{name}/SKILL.md.
# This initializer does not write to ~/.codex/skills or ~/.codex/prompts.
"@
        Write-Utf8File -Path $cfgPath -Content $cfg
        Write-Host "[codex    ] [config] $cfgPath"
        $report.ConfigsCreated++
        [void]$report.Files.Add($cfgPath)
    }

    [void]$report.Notes.Add('AGENTS.md at the repo root is the primary Codex entrypoint.')
    [void]$report.Notes.Add('Native Codex skills written project-locally under .codex/skills/{name}/SKILL.md.')
    if ($InstallCodexSkills) {
        [void]$report.Notes.Add('-InstallCodexSkills confirmed project-local skill initialization; no global files were written.')
    }
    return $report
}

# ----- OpenCode -----

function Invoke-OpenCodeSync {
    param(
        [Parameter(Mandatory)]$Agents,
        [Parameter(Mandatory)]$Skills,
        [Parameter(Mandatory)][string]$Root
    )
    $report = New-SyncReport

    $agentDir   = Join-Path $Root '.opencode/agents'
    $commandDir = Join-Path $Root '.opencode/commands'
    $skillsDir  = Join-Path $Root '.opencode/skills'

    foreach ($a in $Agents) {
        $name     = $a.Name
        $meta     = $a.Meta
        $modelCls = $meta['model-class']
        $desc     = $meta['description']
        $tools    = if ($meta.Contains('tools-required')) { $meta['tools-required'] } else { @() }
        $isMeta   = ($meta['meta-agent'] -eq 'true')
        $mode     = if ($isMeta) { 'subagent' } else { 'subagent' }   # all are subagents under our orchestrator

        $model = if ($ModelClassToOpenCode.ContainsKey($modelCls)) { $ModelClassToOpenCode[$modelCls] } else { 'anthropic/claude-sonnet-4-6' }
        $permissionMap = Resolve-OpenCodePermissions -NeutralTools $tools

        $permissionBlock = ''
        foreach ($k in $permissionMap.Keys) {
            $permissionBlock += "  ${k}: $($permissionMap[$k])`n"
        }
        $permissionBlock = $permissionBlock.TrimEnd("`n")

        $descLine = '  ' + ($desc -replace "`r?`n", ' ')
        $obsidian = Format-ObsidianBlock -Meta $meta
        $obsidianBlock = if ($obsidian) { "`n$obsidian" } else { '' }

        $fm = @"
---
description: >
$descLine
mode: $mode
model: $model
permission:
$permissionBlock
$obsidianBlock
---
"@
        $outPath = Join-Path $agentDir ("{0}.md" -f $name)
        $body = $a.Body.TrimStart("`n")
        $final = $fm + "`n`n" + $body
        if (-not $final.EndsWith("`n")) { $final += "`n" }
        Write-Utf8File -Path $outPath -Content $final
        Write-Host "[opencode ] [agent ] $outPath"
        $report.AgentsWritten++
        [void]$report.Files.Add($outPath)
    }

    foreach ($s in $Skills) {
        $name        = $s.Name
        $meta        = $s.Meta
        $desc        = $meta['description']
        $placeholder = if ($meta['argument-placeholder']) { $meta['argument-placeholder'] } else { '<ARGS>' }
        # OpenCode commands use $ARGUMENTS (same as Claude) for positional args.
        # Commands are slash prompts; skills are on-demand SKILL.md packages.
        $body = ($s.Body -replace [regex]::Escape($placeholder), '$ARGUMENTS')
        $obsidian = Format-ObsidianBlock -Meta $meta
        $obsidianBlock = if ($obsidian) { "`n$obsidian" } else { '' }

        $fm = @"
---
description: >
$(Format-FoldedYamlValue -Text $desc)
$obsidianBlock
---
"@
        $outPath = Join-Path $commandDir ("{0}.md" -f $name)
        $final = $fm + "`n`n" + $body.TrimStart("`n")
        if (-not $final.EndsWith("`n")) { $final += "`n" }
        Write-Utf8File -Path $outPath -Content $final
        Write-Host "[opencode ] [skill ] $outPath"
        $report.SkillsWritten++
        [void]$report.Files.Add($outPath)

        $skillPath = Join-Path $skillsDir ("{0}/SKILL.md" -f $name)
        $skillContent = New-SkillPackageContent -Name $name -Meta $meta -Body $s.Body -ArgumentToken '$ARGUMENTS' -Compatibility 'opencode'
        Write-Utf8File -Path $skillPath -Content $skillContent
        Write-Host "[opencode ] [skillpkg] $skillPath"
        [void]$report.Files.Add($skillPath)
    }

    # opencode.json - do not overwrite if present.
    $cfgPath = Join-Path $Root 'opencode.json'
    if (Test-Path -LiteralPath $cfgPath) {
        $report.ConfigsSkipped++
        [void]$report.Notes.Add('opencode.json exists - left untouched.')
    } else {
        $cfg = @"
{
  "`$schema": "https://opencode.ai/config.json",
  "theme": "system",
  "model": "anthropic/claude-sonnet-4-6",
  "autoshare": false,
  "autoupdate": false,
  "permission": {
    "skill": {
      "*": "allow"
    }
  }
}
"@
        Write-Utf8File -Path $cfgPath -Content $cfg
        Write-Host "[opencode ] [config] $cfgPath"
        $report.ConfigsCreated++
        [void]$report.Files.Add($cfgPath)
    }

    [void]$report.Notes.Add('AGENTS.md at the repo root is the primary OpenCode entrypoint.')
    [void]$report.Notes.Add('Generated documented OpenCode paths: .opencode/agents, .opencode/commands, and .opencode/skills.')
    return $report
}

# ----- Generic .agents -----

function Invoke-GenericSync {
    param(
        [Parameter(Mandatory)]$Agents,
        [Parameter(Mandatory)]$Skills,
        [Parameter(Mandatory)][string]$Root
    )
    $report = New-SyncReport

    $baseDir   = Join-Path $Root '.agents'
    $agentsDir = Join-Path $baseDir 'agents'
    $skillsDir = Join-Path $baseDir 'skills'
    $toolsDir  = Join-Path $baseDir 'tools'

    $manifestAgents = New-Object System.Collections.ArrayList
    foreach ($a in $Agents) {
        $name     = $a.Name
        $meta     = $a.Meta
        $modelCls = $meta['model-class']
        $desc     = $meta['description']
        $role     = $meta['role']
        $tools    = if ($meta.Contains('tools-required')) { $meta['tools-required'] } else { @() }
        $toolsList = ($tools | ForEach-Object { '  - ' + (($_ -replace '\s+#.*$', '').Trim()) }) -join "`n"
        if (-not $toolsList) { $toolsList = '  - read' }

        $descLine = Format-FoldedYamlValue -Text $desc
        $obsidian = Format-ObsidianBlock -Meta $meta
        $obsidianBlock = if ($obsidian) { "`n$obsidian" } else { '' }

        $fm = @"
---
name: $name
role: $role
model-class: $modelCls
description: >
$descLine
tools-required:
$toolsList
$obsidianBlock
---
"@
        $outPath = Join-Path $agentsDir ("{0}.md" -f $name)
        $final = $fm + "`n`n" + $a.Body.TrimStart("`n")
        if (-not $final.EndsWith("`n")) { $final += "`n" }
        Write-Utf8File -Path $outPath -Content $final
        Write-Host "[generic  ] [agent ] $outPath"
        $report.AgentsWritten++
        [void]$report.Files.Add($outPath)

        [void]$manifestAgents.Add([ordered]@{
            name = $name
            role = $role
            model_class = $modelCls
            description = Normalize-OneLine -Text $desc
            tools_required = @($tools | ForEach-Object { (($_ -replace '\s+#.*$', '').Trim()) })
            path = "agents/$name.md"
        })
    }

    $manifestSkills = New-Object System.Collections.ArrayList
    foreach ($s in $Skills) {
        $name = $s.Name
        $meta = $s.Meta
        $desc = $meta['description']
        $skillPath = Join-Path $skillsDir ("{0}/SKILL.md" -f $name)
        $skillContent = New-SkillPackageContent -Name $name -Meta $meta -Body $s.Body -ArgumentToken '<ARGS>' -Compatibility 'generic'
        Write-Utf8File -Path $skillPath -Content $skillContent
        Write-Host "[generic  ] [skill ] $skillPath"
        $report.SkillsWritten++
        [void]$report.Files.Add($skillPath)

        [void]$manifestSkills.Add([ordered]@{
            name = $name
            description = Normalize-OneLine -Text $desc
            path = "skills/$name/SKILL.md"
        })
    }

    $toolsReadme = @"
# Generic tool contract

Generic harnesses should map each agent's ``tools-required`` values to their
own permission system:

| Neutral tool | Expected capability |
|--------------|---------------------|
| ``read``     | Read project files |
| ``search``   | Glob, grep, or semantic search over project files |
| ``edit``     | Create and modify files in the workspace |
| ``exec``     | Run shell commands subject to the harness approval policy |
| ``web``      | Fetch or search web documentation when enabled |

This directory is descriptive only. It does not grant permissions by itself.
"@
    $toolsPath = Join-Path $toolsDir 'README.md'
    Write-Utf8File -Path $toolsPath -Content $toolsReadme
    Write-Host "[generic  ] [tools ] $toolsPath"
    [void]$report.Files.Add($toolsPath)

    $config = [ordered]@{
        schema = 'spec-driven-framework.generic-agents.v1'
        schema_version = '1.0'
        entrypoint = '../AGENTS.md'
        agents_path = 'agents'
        skills_path = 'skills'
        tools_path = 'tools'
        local_only = $true
    }
    $configPath = Join-Path $baseDir 'config.json'
    Write-Utf8File -Path $configPath -Content ($config | ConvertTo-Json -Depth 6)
    Write-Host "[generic  ] [config] $configPath"
    $report.ConfigsCreated++
    [void]$report.Files.Add($configPath)

    $manifest = [ordered]@{
        schema_version = '1.0'
        generated = (Get-Date).ToUniversalTime().ToString('o')
        entrypoint = '../AGENTS.md'
        agents = $manifestAgents
        skills = $manifestSkills
    }
    $manifestPath = Join-Path $baseDir 'manifest.json'
    Write-Utf8File -Path $manifestPath -Content ($manifest | ConvertTo-Json -Depth 8)
    Write-Host "[generic  ] [manifest] $manifestPath"
    [void]$report.Files.Add($manifestPath)

    $catalogLines = New-Object System.Collections.ArrayList
    [void]$catalogLines.Add('# Generic Agent Bundle')
    [void]$catalogLines.Add('')
    [void]$catalogLines.Add('This folder is generated from `.KCC/kernel/` and `.KCC/capabilities/` for harnesses that understand the common `.agents` convention.')
    [void]$catalogLines.Add('')
    [void]$catalogLines.Add('## Agents')
    [void]$catalogLines.Add('')
    foreach ($a in $manifestAgents) {
        [void]$catalogLines.Add(("- ``{0}`` - {1}" -f $a['name'], $a['description']))
    }
    [void]$catalogLines.Add('')
    [void]$catalogLines.Add('## Skills')
    [void]$catalogLines.Add('')
    foreach ($s in $manifestSkills) {
        [void]$catalogLines.Add(("- ``/{0}`` - {1}" -f $s['name'], $s['description']))
    }
    $catalogPath = Join-Path $baseDir 'AGENTS.md'
    Write-Utf8File -Path $catalogPath -Content (($catalogLines -join "`n") + "`n")
    Write-Host "[generic  ] [catalog] $catalogPath"
    [void]$report.Files.Add($catalogPath)

    [void]$report.Notes.Add('Generated .agents/ as a local, harness-neutral bundle with SKILL.md packages and a JSON manifest.')
    return $report
}

# ----- Ollama -----

function Invoke-OllamaSync {
    param(
        [Parameter(Mandatory)]$Agents,
        [Parameter(Mandatory)]$Skills,
        [Parameter(Mandatory)][string]$Root
    )
    $report = New-SyncReport

    $ollamaDir = Join-Path $Root 'ollama'
    if (-not (Test-Path -LiteralPath $ollamaDir)) {
        New-Item -ItemType Directory -Force -Path $ollamaDir | Out-Null
    }

    # agents.json - manifest of agent -> model-class -> recommended Ollama model
    $manifest = [ordered]@{
        schema_version  = '1.0'
        generated       = (Get-Date).ToUniversalTime().ToString('o')
        model_class_map = [ordered]@{}
        agents          = (New-Object System.Collections.ArrayList)
    }
    foreach ($k in $ModelClassToOllama.Keys) {
        $manifest.model_class_map[$k] = $ModelClassToOllama[$k]
    }
    foreach ($a in $Agents) {
        $modelCls = $a.Meta['model-class']
        $model    = if ($ModelClassToOllama.ContainsKey($modelCls)) { $ModelClassToOllama[$modelCls] } else { 'qwen2.5:32b' }
        [void]$manifest.agents.Add([ordered]@{
            name        = $a.Name
            model_class = $modelCls
            ollama_model = $model
            description = $a.Meta['description']
        })
    }
    $manifestJson = $manifest | ConvertTo-Json -Depth 6
    $manifestPath = Join-Path $ollamaDir 'agents.json'
    Write-Utf8File -Path $manifestPath -Content $manifestJson
    Write-Host "[ollama   ] [manifest] $manifestPath"
    $report.AgentsWritten = $Agents.Count
    [void]$report.Files.Add($manifestPath)

    # README - explain Ollama is a runner, not a harness
    $readme = @"
---
title: Ollama Bindings
tags:
  - framework/adapter
  - harness/ollama
created: $((Get-Date).ToString('yyyy-MM-dd'))
updated: $((Get-Date).ToString('yyyy-MM-dd'))
version: 1.0.0
status: active
---

# Ollama bindings

Ollama is a model runner, not an agent harness. This directory holds the
mapping from each neutral agent to a recommended Ollama model, so a harness
that talks to Ollama via an OpenAI-compatible bridge (OpenCode, Continue,
LiteLLM, etc.) can pick sensible defaults per agent.

## Files

- ``agents.json`` - per-agent and per-model-class recommendations. Regenerate
  with ``powershell .KCC/tools/sync-adapters.ps1 -Harness ollama``.

## Wire-up (OpenCode example)

OpenCode's per-agent ``model:`` field can reference an Ollama bridge. Set
your OpenCode provider to point at ``http://localhost:11434/v1`` and use
the model ids from this manifest.

## Default mapping

| Model class           | Ollama model    |
|-----------------------|-----------------|
| strong-reasoning      | qwen2.5:72b     |
| balanced              | qwen2.5:32b     |
| fast-implementation   | qwen2.5:14b     |
| local-strong          | qwen2.5:72b     |
| local-fast            | qwen2.5:7b      |

Override per-agent by editing ``agents.json`` after sync.
"@
    $readmePath = Join-Path $ollamaDir 'README.md'
    Write-Utf8File -Path $readmePath -Content $readme
    Write-Host "[ollama   ] [readme  ] $readmePath"
    [void]$report.Files.Add($readmePath)

    [void]$report.Notes.Add('Ollama is consumed by an OpenAI-compatible harness; pair with OpenCode or similar.')
    return $report
}

# ----- DeepSeek harness (dsh) -----

function New-DshWorkerBoundary {
    # Post-lock worker boundary text appended to every generated .dsh skill.
    # Plan 08: native read-only allowlist direct; everything else fail-closed;
    # governed actions through the exact KCC policy wrappers; KCC owns
    # controller/status/resume. Conformance (check-run-conformance -Scope
    # harness) requires every marker line below to appear in each SKILL.md.
    # Single-quoted here-string: backticks stay literal.
    return @'

---

## KCC worker boundary (generated)

- Post-lock workers use the DSH native read-only allowlist directly (read, read_image, glob, grep, todo_write) and never escalate it.
- process, write, network, subagent, workflow, code-runtime, MCP, Cordis, and unknown operations fail closed (denied without prompt).
- Governed actions use exactly `kcc_policy_exec` / `kcc_policy_write`.
- KCC owns controller, status, and resume.
'@
}

function Invoke-DshSync {
    param(
        [Parameter(Mandatory)]$Agents,
        [Parameter(Mandatory)]$Skills,
        [Parameter(Mandatory)][string]$Root
    )
    $report = New-SyncReport

    $skillsDir = Join-Path $Root '.dsh/skills'

    foreach ($s in $Skills) {
        $name = $s.Name
        $meta = $s.Meta
        # dsh skills are native skill-package directories. Keep arguments
        # slash-command compatible by rewriting the neutral placeholder to
        # $ARGUMENTS, then append the generated KCC worker boundary.
        $final = New-SkillPackageContent -Name $name -Meta $meta -Body $s.Body -ArgumentToken '$ARGUMENTS' -Compatibility 'dsh'
        $boundary = New-DshWorkerBoundary
        $final = $final.TrimEnd() + "`n`n" + $boundary
        if (-not $final.EndsWith("`n")) { $final += "`n" }
        $outPath = Join-Path $skillsDir ("{0}/SKILL.md" -f $name)
        Write-Utf8File -Path $outPath -Content $final
        Write-Host "[dsh      ] [skill ] $outPath"
        $report.SkillsWritten++
        [void]$report.Files.Add($outPath)
    }

    [void]$report.Notes.Add('Root AGENTS.md is the dsh entrypoint; created only if missing and never overwritten.')
    [void]$report.Notes.Add('dsh skills are project-local under .dsh/skills/{name}/SKILL.md; no user DSH_HOME files are written.')
    return $report
}

# ============================================================
# Main
# ============================================================

Write-Host ''
Write-Host "Reading KCC kernel/capabilities from: $RepoRoot"

$agents = Read-NeutralAgents -Root $RepoRoot
$skills = Read-NeutralSkills -Root $RepoRoot

Write-Host ("  parsed: {0} agents, {1} skills" -f $agents.Count, $skills.Count)
Write-Host ''
Write-Host 'Initializing framework infrastructure'
Write-Host ''

$initReport = Initialize-FrameworkInfrastructure -Root $RepoRoot -Harness $Harness -Agents $agents -Skills $skills
Write-Host ("  created: {0}   updated: {1}   preserved: {2}" -f $initReport.Created.Count, $initReport.Updated.Count, $initReport.Skipped.Count)
foreach ($createdPath in $initReport.Created) {
    Write-Host ("  [init     ] [create] $createdPath")
}
foreach ($updatedPath in $initReport.Updated) {
    Write-Host ("  [init     ] [update] $updatedPath")
}
if ($initReport.Skipped.Count -gt 0) {
    Write-Host ("  [init     ] preserved existing files: {0}" -f $initReport.Skipped.Count)
}
Write-Host ''
Write-Host "Generating for harness: $Harness"
Write-Host ''

$report = [ordered]@{}

if ($Harness -eq 'all' -or $Harness -eq 'claude') {
    $report['claude'] = Invoke-ClaudeSync -Agents $agents -Skills $skills -Root $RepoRoot
}
if ($Harness -eq 'all' -or $Harness -eq 'codex') {
    $report['codex'] = Invoke-CodexSync -Agents $agents -Skills $skills -Root $RepoRoot
}
if ($Harness -eq 'all' -or $Harness -eq 'opencode') {
    $report['opencode'] = Invoke-OpenCodeSync -Agents $agents -Skills $skills -Root $RepoRoot
}
if ($Harness -eq 'all' -or $Harness -eq 'generic') {
    $report['generic'] = Invoke-GenericSync -Agents $agents -Skills $skills -Root $RepoRoot
}
if ($Harness -eq 'all' -or $Harness -eq 'ollama') {
    $report['ollama'] = Invoke-OllamaSync -Agents $agents -Skills $skills -Root $RepoRoot
}
if ($Harness -eq 'all' -or $Harness -eq 'dsh') {
    $report['dsh'] = Invoke-DshSync -Agents $agents -Skills $skills -Root $RepoRoot
}

# ============================================================
# Summary report
# ============================================================

Write-Host ''
Write-Host '============================================================'
Write-Host ' Sync Summary Report'
Write-Host '============================================================'

$totalFiles = 0
foreach ($key in $report.Keys) {
    $r = $report[$key]
    $files = $r.Files.Count
    $totalFiles += $files
    Write-Host ''
    Write-Host (" [{0,-8}]  agents: {1,2}   skills: {2,2}   configs: {3,1} created, {4,1} skipped   files: {5,2}" -f $key, $r.AgentsWritten, $r.SkillsWritten, $r.ConfigsCreated, $r.ConfigsSkipped, $files)
    foreach ($note in $r.Notes) {
        Write-Host ("            note: $note")
    }
}

Write-Host ''
Write-Host ("Total files written: $totalFiles")
Write-Host ''
Write-Host '------------------------------------------------------------'
Write-Host ' Next steps'
Write-Host '------------------------------------------------------------'
Write-Host '.KCC/kernel/ and .KCC/capabilities/ are the source of truth. Generated outputs:'
if ($report.Contains('claude'))   { Write-Host '  - .claude/agents/, .claude/skills/' }
if ($report.Contains('codex'))    {
    Write-Host '  - .codex/agents/, .codex/skills/*/SKILL.md, .codex/tools/, .codex/config.toml'
    Write-Host '    (local only; global Codex skills should be installed by a separate pipeline)'
}
if ($report.Contains('opencode')) { Write-Host '  - .opencode/agents/, .opencode/commands/, .opencode/skills/, opencode.json' }
if ($report.Contains('generic'))  { Write-Host '  - .agents/agents/, .agents/skills/, .agents/tools/, .agents/config.json, .agents/manifest.json' }
if ($report.Contains('ollama'))   { Write-Host '  - ollama/agents.json, ollama/README.md' }
if ($report.Contains('dsh'))      {
    Write-Host '  - .dsh/skills/*/SKILL.md'
    Write-Host '    (local only; skill generation alone is not Full Autopilot - the policy-guard profile/plugin is a separate install)'
}
Write-Host ''
Write-Host 'Do NOT edit generated files by hand. Edit .KCC/kernel/ or .KCC/capabilities/ and rerun.'
Write-Host 'Root orchestrator entrypoints are created from .KCC/kernel/templates/'
Write-Host 'when missing, then preserved for local edits.'
Write-Host ''
Write-Host '------------------------------------------------------------'
Write-Host ' Lazy folders (created on demand by the owning workflow)'
Write-Host '------------------------------------------------------------'
Write-Host 'These are NOT pre-created at init/sync; the workflow that needs them'
Write-Host 'creates each one on first use:'
Write-Host '  ideation/                      <- idea-interrogator (first idea)'
Write-Host '  specs/                         <- spec-writer (first spec)'
Write-Host '  src/IDEA-*                     <- implementer (first implementation)'
Write-Host '  architecture/                  <- architect (first architect pass)'
Write-Host '  Traces/Session-*               <- butler (first run/session)'
Write-Host '  coordination/backchannel.jsonl <- backchannel-append.ps1 (first event)'
Write-Host '  memory/{type}/                 <- memory-append.ps1 (first entry)'
Write-Host '  solution/                      <- solution-onboard (existing codebase)'
Write-Host '  migrations/                    <- adapt-workflow (importing a workflow)'
