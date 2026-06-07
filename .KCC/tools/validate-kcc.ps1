<#
KCC framework (c) 2026 Tarek Fawaz, https://tikasway.dev/kcc. Licensed under the terms in LICENSE.

.SYNOPSIS
    Validate the local KCC v0.4 framework structure.

.DESCRIPTION
    Checks the expected .KCC/kernel, .KCC/capabilities, and .KCC/tools layout,
    required dialect files, key entrypoints, generated/runtime boundary rules,
    stale retired-path references, and PowerShell parser health.

.PARAMETER RepoRoot
    Optional repository root. Defaults to the parent of .KCC.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .KCC\tools\validate-kcc.ps1
#>

[CmdletBinding()]
param(
    [string]$RepoRoot,
    [ValidateSet('cell', 'repo')]
    [string]$Mode = 'cell'
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

$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
$errors = New-Object System.Collections.Generic.List[string]
$warnings = New-Object System.Collections.Generic.List[string]

function Add-Error([string]$Message) {
    [void]$errors.Add($Message)
}

function Add-Warning([string]$Message) {
    [void]$warnings.Add($Message)
}

function Test-RequiredPath([string]$RelativePath) {
    $path = Join-Path $RepoRoot $RelativePath
    if (-not (Test-Path -LiteralPath $path)) {
        Add-Error "Missing required path: $RelativePath"
    }
}

Write-Host ''
Write-Host "Validating KCC v0.4 at $RepoRoot"
Write-Host "Mode: $Mode"
Write-Host ''

$cellRequiredPaths = @(
    '.KCC/README.md',
    '.KCC/kernel/README.md',
    '.KCC/kernel/adapters',
    '.KCC/kernel/contracts',
    '.KCC/kernel/protocols',
    '.KCC/kernel/protocols/dialects',
    '.KCC/kernel/templates',
    '.KCC/capabilities/agents',
    '.KCC/capabilities/skills',
    '.KCC/tools/framework-init.ps1',
    '.KCC/tools/framework-init.sh',
    '.KCC/tools/sync-adapters.ps1',
    '.KCC/tools/sync-adapters.sh',
    '.KCC/tools/adapt-workflow.ps1',
    '.KCC/tools/adapt-workflow.sh',
    '.KCC/tools/show-backchannel.ps1',
    '.KCC/tools/show-backchannel.sh',
    '.KCC/tools/backchannel-append.ps1',
    '.KCC/tools/backchannel-append.sh',
    '.KCC/tools/build-dashboard.ps1',
    '.KCC/tools/build-dashboard.sh',
    '.KCC/tools/start-agent-session.ps1',
    '.KCC/tools/start-agent-session.sh',
    '.KCC/tools/validate-kcc.ps1',
    '.KCC/tools/validate-kcc.sh'
)

$repoRequiredPaths = @(
    'README.md',
    'QUICKSTART.md',
    'PLAN.md',
    'docs/alignment-matrix.md',
    'output/README.md',
    'AGENTS.md',
    'CLAUDE.md'
)

$requiredPaths = @($cellRequiredPaths)
if ($Mode -eq 'repo') {
    $requiredPaths += $repoRequiredPaths
} else {
    foreach ($relativePath in @('AGENTS.md', 'CLAUDE.md', 'README.md', 'QUICKSTART.md', 'PLAN.md')) {
        if (-not (Test-Path -LiteralPath (Join-Path $RepoRoot $relativePath))) {
            Add-Warning "Optional repo/cell entrypoint is absent in cell mode: $relativePath"
        }
    }
}

foreach ($relativePath in $requiredPaths) {
    Test-RequiredPath $relativePath
}

$dialects = @(
    'dialect-registry.md',
    'backend-csharp.md',
    'backend-go.md',
    'backend-python.md',
    'backend-rust.md',
    'backend-php.md',
    'backend-java.md',
    'backend-cpp.md',
    'backend-nodejs.md',
    'fullstack-dotnet.md',
    'fullstack-mern.md',
    'fullstack-nestjs.md',
    'fullstack-python.md',
    'fullstack-go.md',
    'embedded-c.md',
    'embedded-cpp.md',
    'embedded-rust.md',
    'frontend-angular.md',
    'frontend-react.md',
    'frontend-vanilla-js.md',
    'frontend-general.md',
    'devops-cloud.md',
    'devops-k8s-onprem-agnostic.md'
)

foreach ($dialect in $dialects) {
    Test-RequiredPath (Join-Path '.KCC/kernel/protocols/dialects' $dialect)
}

$expectedAgents = @(
    'architect.md',
    'architecture-critic.md',
    'butler.md',
    'idea-interrogator.md',
    'implementer.md',
    'infrastructure-implementer.md',
    'infrastructure-planner.md',
    'migrator.md',
    'planner.md',
    'security-analyst.md',
    'solution-cartographer.md',
    'solution-inspector.md',
    'spec-writer.md',
    'technical-interrogator.md',
    'token-guard.md',
    'ux-ui-designer.md',
    'verifier.md'
)

foreach ($agent in $expectedAgents) {
    Test-RequiredPath (Join-Path '.KCC/capabilities/agents' $agent)
}

$expectedSkills = @(
    'adapt-workflow.md',
    'architecture-review.md',
    'auto.md',
    'butler-brief.md',
    'butler-remember.md',
    'critical-human-gate.md',
    'dashboard.md',
    'idea-interrogator.md',
    'infrastructure-interrogator.md',
    'inspect.md',
    'security-interrogator.md',
    'solution-onboard.md',
    'spec-create.md',
    'spec-deploy.md',
    'spec-implement.md',
    'spec-plan.md',
    'spec-review.md',
    'spec-status.md',
    'spec-test.md',
    'technical-interrogator.md',
    'token-estimate.md',
    'ux-ui-interrogator.md'
)

foreach ($skill in $expectedSkills) {
    Test-RequiredPath (Join-Path '.KCC/capabilities/skills' $skill)
}

# Reconciliation: warn on any capability file present on disk but NOT in the
# expected list above. This stops the expected lists from silently
# under-covering when a new capability is added without updating this script.
$agentsDir = Join-Path $RepoRoot '.KCC/capabilities/agents'
if (Test-Path -LiteralPath $agentsDir) {
    foreach ($file in (Get-ChildItem -LiteralPath $agentsDir -Filter '*.md' -File)) {
        if ($expectedAgents -notcontains $file.Name) {
            Add-Warning "Agent '$($file.Name)' exists on disk but is not in validate-kcc.ps1 `$expectedAgents — add it so the required-file check covers it."
        }
    }
}
$skillsDir = Join-Path $RepoRoot '.KCC/capabilities/skills'
if (Test-Path -LiteralPath $skillsDir) {
    foreach ($file in (Get-ChildItem -LiteralPath $skillsDir -Filter '*.md' -File)) {
        if ($expectedSkills -notcontains $file.Name) {
            Add-Warning "Skill '$($file.Name)' exists on disk but is not in validate-kcc.ps1 `$expectedSkills — add it so the required-file check covers it."
        }
    }
}

# Generated harness outputs are intentionally not required in the shipped
# source package. They are local adapter surfaces produced by framework-init
# or sync-adapters when a cell is initialized.

$runtimePathsInsideKcc = @(
    '.KCC/ideation',
    '.KCC/specs',
    '.KCC/architecture',
    '.KCC/coordination',
    '.KCC/memory',
    '.KCC/Traces',
    '.KCC/solution',
    '.KCC/src',
    '.KCC/docs'
)

foreach ($runtimePath in $runtimePathsInsideKcc) {
    if (Test-Path -LiteralPath (Join-Path $RepoRoot $runtimePath)) {
        Add-Error "Runtime output must stay outside .KCC: $runtimePath"
    }
}

$textRoots = @('.KCC', 'AGENTS.md', 'CLAUDE.md', 'QUICKSTART.md', 'README.md', 'PLAN.md', 'docs', 'output', 'architecture', 'coordination', 'ollama')
$stalePattern = '\.KCC/framework|framework/agents|framework/skills|framework/protocols|framework/templates|framework/adapters'
$staleMatches = New-Object System.Collections.Generic.List[string]
$corruptionMatches = New-Object System.Collections.Generic.List[string]

function Get-RelativeDisplayPath([string]$Path) {
    try { return (Resolve-Path -LiteralPath $Path -Relative) }
    catch { return $Path }
}

function Get-LineNumberForIndex([string]$Text, [int]$Index) {
    if ($Index -le 0) { return 1 }
    return ([regex]::Matches($Text.Substring(0, $Index), "`r`n|`n|`r").Count + 1)
}

foreach ($root in $textRoots) {
    $fullRoot = Join-Path $RepoRoot $root
    if (-not (Test-Path -LiteralPath $fullRoot)) { continue }

    $items = if ((Get-Item -LiteralPath $fullRoot).PSIsContainer) {
        Get-ChildItem -LiteralPath $fullRoot -Recurse -File |
            Where-Object { @('.md', '.ps1', '.sh', '.json', '.jsonl', '.toml', '.mmd').Contains($_.Extension.ToLowerInvariant()) }
    } else {
        Get-Item -LiteralPath $fullRoot
    }

    foreach ($item in $items) {
        if ($item.FullName -like '*\.KCC\tools\sync-adapters.ps1') {
            continue
        }
        if ($item.FullName -like '*\.KCC\tools\validate-kcc.ps1') {
            continue
        }
        if ($item.FullName -like '*\.KCC\tools\validate-kcc.sh') {
            continue
        }

        $text = $null
        try {
            $text = [System.IO.File]::ReadAllText($item.FullName, [System.Text.Encoding]::UTF8)
        } catch {
            Add-Warning "Could not read text file for corruption scan: $(Get-RelativeDisplayPath $item.FullName)"
        }
        if ($null -ne $text) {
            $controlMatch = [regex]::Match($text, '[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]')
            if ($controlMatch.Success) {
                $relative = Get-RelativeDisplayPath $item.FullName
                $lineNumber = Get-LineNumberForIndex -Text $text -Index $controlMatch.Index
                $code = [int][char]$controlMatch.Value
                [void]$corruptionMatches.Add("${relative}:${lineNumber} control-character U+$('{0:X4}' -f $code)")
            }

            # Corrupted-word heuristic (light): a control char directly adjacent
            # to a letter is the signature of the "ackchannel"/"rchitecture"
            # backspace/bell corruption. Reported as a precise marker.
            $adjacentMatch = [regex]::Match($text, '(?:[A-Za-z][\x00-\x08\x0B\x0C\x0E-\x1F\x7F]|[\x00-\x08\x0B\x0C\x0E-\x1F\x7F][A-Za-z])')
            if ($adjacentMatch.Success) {
                $relative = Get-RelativeDisplayPath $item.FullName
                $lineNumber = Get-LineNumberForIndex -Text $text -Index $adjacentMatch.Index
                [void]$corruptionMatches.Add("${relative}:${lineNumber} corrupted-word (control char adjacent to letters)")
            }

            # Common UTF-8-as-Windows-1252 mojibake sequences seen in docs.
            # Multi-char markers first (more specific), then single bytes.
            $mojibakeMarkers = @(
                "$([char]0x00C3)$([char]0x00A2)$([char]0x00E2)$([char]0x201A)",  # Ã¢â‚¬
                "$([char]0x00E2)$([char]0x20AC)$([char]0x201D)",                  # â€"
                "$([char]0x00E2)$([char]0x20AC)$([char]0x2122)",                  # â€™
                "$([char]0x00E2)$([char]0x20AC)$([char]0x0153)",                  # â€œ
                "$([char]0x00C3)$([char]0x00A9)",                                 # Ã©
                "$([char]0x00C3)$([char]0x00A8)",                                 # Ã¨
                "$([char]0x00C2)$([char]0x00A0)",                                 # Â (stray)
                "$([char]0x00C3)$([char]0xB0)$([char]0x0178)"                     # ðŸ broken emoji
            )
            foreach ($marker in $mojibakeMarkers) {
                $idx = $text.IndexOf($marker)
                if ($idx -ge 0) {
                    $relative = Get-RelativeDisplayPath $item.FullName
                    $lineNumber = Get-LineNumberForIndex -Text $text -Index $idx
                    [void]$corruptionMatches.Add("${relative}:${lineNumber} mojibake-marker `"$marker`"")
                    break
                }
            }

            # BOM (U+FEFF / ï»¿) appearing mid-file rather than at the very start.
            $bomIdx = if ($text.Length -gt 1) { $text.IndexOf([char]0xFEFF, 1) } else { -1 }
            if ($bomIdx -ge 1) {
                $relative = Get-RelativeDisplayPath $item.FullName
                $lineNumber = Get-LineNumberForIndex -Text $text -Index $bomIdx
                [void]$corruptionMatches.Add("${relative}:${lineNumber} BOM (U+FEFF) not at file start")
            }

            # Replacement character is a hard sign of decode loss.
            $replIdx = $text.IndexOf([char]0xFFFD)
            if ($replIdx -ge 0) {
                $relative = Get-RelativeDisplayPath $item.FullName
                $lineNumber = Get-LineNumberForIndex -Text $text -Index $replIdx
                [void]$corruptionMatches.Add("${relative}:${lineNumber} mojibake-marker U+FFFD (replacement char)")
            }
        }

        $matches = Select-String -LiteralPath $item.FullName -Pattern $stalePattern -AllMatches -ErrorAction SilentlyContinue
        foreach ($match in $matches) {
            $relative = Get-RelativeDisplayPath $item.FullName
            [void]$staleMatches.Add("${relative}:$($match.LineNumber)")
        }
    }
}

if ($corruptionMatches.Count -gt 0) {
    Add-Error ("Text/control-character corruption markers found: " + (($corruptionMatches | Select-Object -First 25) -join ', '))
    if ($corruptionMatches.Count -gt 25) {
        Add-Warning "Additional corruption markers omitted from output: $($corruptionMatches.Count - 25)"
    }
}

if ($staleMatches.Count -gt 0) {
    Add-Error ("Stale retired .KCC/framework references found: " + ($staleMatches -join ', '))
}

$parserFiles = @(
    '.KCC/tools/framework-init.ps1',
    '.KCC/tools/sync-adapters.ps1',
    '.KCC/tools/adapt-workflow.ps1',
    '.KCC/tools/backchannel-append.ps1',
    '.KCC/tools/build-dashboard.ps1',
    '.KCC/tools/memory-append.ps1',
    '.KCC/tools/show-backchannel.ps1',
    '.KCC/tools/start-agent-session.ps1',
    '.KCC/tools/toolchain-preflight.ps1',
    '.KCC/tools/validate-kcc.ps1'
)

foreach ($relativePath in $parserFiles) {
    $path = Join-Path $RepoRoot $relativePath
    if (-not (Test-Path -LiteralPath $path)) { continue }
    $tokens = $null
    $parseErrors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$parseErrors) | Out-Null
    if ($parseErrors.Count -gt 0) {
        Add-Error "PowerShell parse error in ${relativePath}: $($parseErrors[0].Message)"
    }
}

# -----------------------------------------------------------------------------
# Lethal Trifecta check
# -----------------------------------------------------------------------------
# See .KCC/kernel/protocols/lethal-trifecta.md for the protocol.
# For every agent under .KCC/capabilities/agents/, compute:
#   has-untrusted-input  : `inputs:` mentions human / user / external / prompt
#   has-private-data     : `tools-required` contains `read` AND the agent body
#                          or role references memory/ or coordination/
#   has-external-comms   : `tools-required` contains `web` OR `exec` is present
# If all three are true AND `confidence-gate: required` is NOT in frontmatter,
# emit a WARNING with the agent name, the three evidence snippets, and a fix.

function Get-FrontmatterAndBody([string]$Path) {
    $raw = Get-Content -LiteralPath $Path -Raw -ErrorAction SilentlyContinue
    if (-not $raw) { return $null }
    $lines = $raw -split "(`r`n|`n|`r)"
    $front = New-Object System.Collections.Generic.List[string]
    $body = New-Object System.Collections.Generic.List[string]
    $state = 'pre'
    $sawOpening = $false
    foreach ($line in $lines) {
        if ($line -match '^(`r`n|`n|`r)$') { continue }
        if ($state -eq 'pre' -and $line -match '^---\s*$') {
            $state = 'front'
            $sawOpening = $true
            continue
        }
        if ($state -eq 'front' -and $line -match '^---\s*$') {
            $state = 'body'
            continue
        }
        if ($state -eq 'front') {
            [void]$front.Add($line)
        } elseif ($state -eq 'body') {
            [void]$body.Add($line)
        }
    }
    if (-not $sawOpening) { return $null }
    return @{
        Frontmatter = ($front -join "`n")
        Body        = ($body -join "`n")
    }
}

function Test-TrifectaUntrustedInput([string]$Frontmatter) {
    # Pull the `inputs:` value (single-line or folded `>` block). Grab
    # everything from `inputs:` until the next top-level key or end of
    # frontmatter.
    $match = [regex]::Match(
        $Frontmatter,
        '(?ms)^inputs:\s*(.*?)(?=^\S|\z)'
    )
    if (-not $match.Success) { return @{ Hit = $false; Evidence = '' } }
    $value = $match.Groups[1].Value
    if ($value -match '(?i)\b(human|user|external|prompt)\b') {
        $snippet = ($value -replace '\s+', ' ').Trim()
        if ($snippet.Length -gt 80) { $snippet = $snippet.Substring(0, 77) + '...' }
        return @{ Hit = $true; Evidence = "inputs mentions human/user/external/prompt: `"$snippet`"" }
    }
    return @{ Hit = $false; Evidence = '' }
}

function Test-TrifectaPrivateData([string]$Frontmatter, [string]$Body) {
    $toolsBlock = [regex]::Match(
        $Frontmatter,
        '(?ms)^tools-required:\s*(.*?)(?=^\S|\z)'
    )
    if (-not $toolsBlock.Success) { return @{ Hit = $false; Evidence = '' } }
    $tools = $toolsBlock.Groups[1].Value
    if ($tools -notmatch '(?im)^\s*-\s*read\b') { return @{ Hit = $false; Evidence = '' } }

    $combined = "$Frontmatter`n$Body"
    if ($combined -match '(?i)memory/|coordination/') {
        return @{ Hit = $true; Evidence = "tools-required includes `read` and the agent references memory/ or coordination/" }
    }
    return @{ Hit = $false; Evidence = '' }
}

function Test-TrifectaExternalComms([string]$Frontmatter) {
    $toolsBlock = [regex]::Match(
        $Frontmatter,
        '(?ms)^tools-required:\s*(.*?)(?=^\S|\z)'
    )
    if (-not $toolsBlock.Success) { return @{ Hit = $false; Evidence = '' } }
    $tools = $toolsBlock.Groups[1].Value
    if ($tools -match '(?im)^\s*-\s*web\b') {
        return @{ Hit = $true; Evidence = "tools-required includes `web` (network egress)" }
    }
    if ($tools -match '(?im)^\s*-\s*exec\b') {
        return @{ Hit = $true; Evidence = "tools-required includes `exec` (shell; potentially network-capable)" }
    }
    return @{ Hit = $false; Evidence = '' }
}

function Test-TrifectaGateDeclared([string]$Frontmatter) {
    return ($Frontmatter -match '(?im)^confidence-gate:\s*required\b')
}

$agentsDir = Join-Path $RepoRoot '.KCC/capabilities/agents'
if (Test-Path -LiteralPath $agentsDir) {
    $agentFiles = Get-ChildItem -LiteralPath $agentsDir -Filter '*.md' -File -ErrorAction SilentlyContinue
    foreach ($agentFile in $agentFiles) {
        $parsed = Get-FrontmatterAndBody -Path $agentFile.FullName
        if ($null -eq $parsed) { continue }
        $front = $parsed.Frontmatter
        $body = $parsed.Body

        $untrusted = Test-TrifectaUntrustedInput -Frontmatter $front
        $private   = Test-TrifectaPrivateData   -Frontmatter $front -Body $body
        $external  = Test-TrifectaExternalComms -Frontmatter $front

        if ($untrusted.Hit -and $private.Hit -and $external.Hit) {
            if (-not (Test-TrifectaGateDeclared -Frontmatter $front)) {
                $agentName = [System.IO.Path]::GetFileNameWithoutExtension($agentFile.Name)
                $msg = "Lethal Trifecta: $agentName matches all three legs " +
                       "[untrusted-input: $($untrusted.Evidence)] " +
                       "[private-data: $($private.Evidence)] " +
                       "[external-comms: $($external.Evidence)]. " +
                       "Fix: add 'confidence-gate: required' to its frontmatter and route the delegating skill through critical-human-gate (see .KCC/kernel/protocols/lethal-trifecta.md)."
                Add-Warning $msg
            }
        }
    }
} else {
    Add-Warning "Lethal Trifecta check skipped: $agentsDir not found."
}

# -----------------------------------------------------------------------------
# Maturity + maintainer presence check (KCC v0.4 alignment)
# -----------------------------------------------------------------------------
# Every capability (agent or skill) should declare:
#   maturity: L1|L2|L3
#   maintainer: <name or email>
# Missing values are warnings (not errors) so the check can roll out gradually.

$validMaturities = @('L1', 'L2', 'L3')
$capabilityDirs = @(
    @{ Path = (Join-Path $RepoRoot '.KCC\capabilities\agents'); Kind = 'agent' }
    @{ Path = (Join-Path $RepoRoot '.KCC\capabilities\skills'); Kind = 'skill' }
)

foreach ($dir in $capabilityDirs) {
    if (-not (Test-Path -LiteralPath $dir.Path)) {
        Add-Warning "Maturity check skipped: $($dir.Path) not found."
        continue
    }
    foreach ($file in (Get-ChildItem -LiteralPath $dir.Path -Filter '*.md' -File)) {
        $name = [System.IO.Path]::GetFileNameWithoutExtension($file.Name)
        $text = [System.IO.File]::ReadAllText($file.FullName, [System.Text.Encoding]::UTF8)

        $maturityMatch  = [regex]::Match($text, '(?m)^maturity:\s*(\S+)\s*$')
        $maintainerMatch = [regex]::Match($text, '(?m)^maintainer:\s*(\S+.*?)\s*$')

        if (-not $maturityMatch.Success) {
            Add-Warning "$($dir.Kind) '$name' is missing 'maturity:' frontmatter field (expected L1, L2, or L3)."
        } elseif ($validMaturities -notcontains $maturityMatch.Groups[1].Value) {
            Add-Warning "$($dir.Kind) '$name' has invalid maturity '$($maturityMatch.Groups[1].Value)' (expected L1, L2, or L3)."
        }

        if (-not $maintainerMatch.Success) {
            Add-Warning "$($dir.Kind) '$name' is missing 'maintainer:' frontmatter field."
        }
    }
}

# -----------------------------------------------------------------------------
# Architecture-format structural check (both modes, when architecture/ exists)
# -----------------------------------------------------------------------------
# Authority: .KCC/kernel/protocols/architecture-documentation.md
# The convention is named `.md` diagram files with embedded inline mermaid.
# `.mmd` files and an `architecture/diagrams/` folder are the deprecated format.
$archDir = Join-Path $RepoRoot 'architecture'
if (Test-Path -LiteralPath $archDir) {
    $mmdFiles = Get-ChildItem -LiteralPath $archDir -Recurse -File -Filter '*.mmd' -ErrorAction SilentlyContinue
    if ($mmdFiles -and $mmdFiles.Count -gt 0) {
        $listing = ($mmdFiles | Select-Object -First 10 | ForEach-Object { Get-RelativeDisplayPath $_.FullName }) -join ', '
        Add-Error "Deprecated architecture format: .mmd file(s) found under architecture/ ($listing). Use named .md diagram files with embedded inline mermaid (see .KCC/kernel/protocols/architecture-documentation.md)."
    }
    $diagramsDir = Join-Path $archDir 'diagrams'
    if (Test-Path -LiteralPath $diagramsDir) {
        Add-Error "Deprecated architecture format: architecture/diagrams/ folder exists. Use named .md diagram files with embedded inline mermaid (see .KCC/kernel/protocols/architecture-documentation.md)."
    }

    $archDoc = Join-Path $archDir 'architecture.md'
    if (Test-Path -LiteralPath $archDoc) {
        $archDocLen = (Get-Item -LiteralPath $archDoc).Length
        if ($archDocLen -lt 2048) {
            Add-Warning "architecture/architecture.md is suspiciously thin ($archDocLen bytes < 2 KB); it should be a mature Architecture Document, not a stub."
        }
    }

    $adrsDir = Join-Path $archDir 'adrs'
    $hasAdrs = $false
    if (Test-Path -LiteralPath $adrsDir) {
        $adrFiles = Get-ChildItem -LiteralPath $adrsDir -File -Filter '*.md' -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -notin @('adrs.md', 'template.md', '.gitkeep') }
        if ($adrFiles -and $adrFiles.Count -gt 0) { $hasAdrs = $true }
    }
    if ($hasAdrs) {
        $expectedSupporting = @(
            'fitness-functions.md',
            'nfrs.md',
            'technical-budgets.md',
            'adrs/adrs.md'
        )
        foreach ($supporting in $expectedSupporting) {
            if (-not (Test-Path -LiteralPath (Join-Path $archDir $supporting))) {
                Add-Warning "architecture/ has ADRs but is missing expected supporting file: architecture/$supporting"
            }
        }
    }
}

# -----------------------------------------------------------------------------
# Generated-cell hygiene (WARN only, never fail)
# -----------------------------------------------------------------------------
# Runtime/build artifacts present and NOT gitignored are a warning. Reads the
# repo-root .gitignore to decide whether each offending pattern is covered.
$gitignorePath = Join-Path $RepoRoot '.gitignore'
$gitignoreText = ''
if (Test-Path -LiteralPath $gitignorePath) {
    $gitignoreText = [System.IO.File]::ReadAllText($gitignorePath, [System.Text.Encoding]::UTF8)
}
$hygienePatterns = @('.tmp-*', '**/__pycache__/', '*.pyc', '*.db', '*.db-journal', '.test-tmp/', 'node_modules/', '.next/')
foreach ($pattern in $hygienePatterns) {
    $present = $false
    switch -Wildcard ($pattern) {
        '.tmp-*'           { $present = ((Get-ChildItem -LiteralPath $RepoRoot -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -like '.tmp-*' }).Count -gt 0) }
        '**/__pycache__/'  { $present = ($null -ne (Get-ChildItem -LiteralPath $RepoRoot -Recurse -Force -Directory -Filter '__pycache__' -ErrorAction SilentlyContinue | Select-Object -First 1)) }
        '*.pyc'            { $present = ($null -ne (Get-ChildItem -LiteralPath $RepoRoot -Recurse -Force -File -Filter '*.pyc' -ErrorAction SilentlyContinue | Select-Object -First 1)) }
        '*.db'             { $present = ($null -ne (Get-ChildItem -LiteralPath $RepoRoot -Recurse -Force -File -Filter '*.db' -ErrorAction SilentlyContinue | Select-Object -First 1)) }
        '*.db-journal'     { $present = ($null -ne (Get-ChildItem -LiteralPath $RepoRoot -Recurse -Force -File -Filter '*.db-journal' -ErrorAction SilentlyContinue | Select-Object -First 1)) }
        '.test-tmp/'       { $present = (Test-Path -LiteralPath (Join-Path $RepoRoot '.test-tmp')) }
        'node_modules/'    { $present = ($null -ne (Get-ChildItem -LiteralPath $RepoRoot -Recurse -Force -Directory -Filter 'node_modules' -ErrorAction SilentlyContinue | Select-Object -First 1)) }
        '.next/'           { $present = ($null -ne (Get-ChildItem -LiteralPath $RepoRoot -Recurse -Force -Directory -Filter '.next' -ErrorAction SilentlyContinue | Select-Object -First 1)) }
    }
    if ($present) {
        $ignored = $gitignoreText -split "(`r`n|`n|`r)" | Where-Object { $_.Trim() -eq $pattern }
        if (-not $ignored) {
            Add-Warning "Generated-cell hygiene: runtime/build artifact matching '$pattern' is present but not listed in .gitignore."
        }
    }
}

Write-Host "Checks complete."
Write-Host "Errors: $($errors.Count)"
Write-Host "Warnings: $($warnings.Count)"

if ($warnings.Count -gt 0) {
    Write-Host ''
    Write-Host 'Warnings:'
    foreach ($warning in $warnings) {
        Write-Host "  - $warning"
    }
}

if ($errors.Count -gt 0) {
    Write-Host ''
    Write-Host 'Errors:'
    foreach ($errorMessage in $errors) {
        Write-Host "  - $errorMessage"
    }
    exit 1
}

Write-Host ''
Write-Host 'KCC validation passed.'
