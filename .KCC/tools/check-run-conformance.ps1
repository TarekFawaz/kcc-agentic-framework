<#
KCC framework (c) 2026 Tarek Fawaz, https://tikasway.dev/kcc. Licensed under the terms in LICENSE.

.SYNOPSIS
    Deterministic conformance linter over a KCC run's OUTPUT (not the framework).

.DESCRIPTION
    Checks that a generated cell's run artifacts conform to the agreed structure,
    so the `auto` orchestrator can gate on real facts instead of agent good faith.
    This is the mechanical half of the self-healing gates: agents drift under
    `--silent --assume --parallel`; this tool catches the drift.

    Checks (by scope):
      architecture - architecture/architecture.md exists, is non-trivial, and has
                     >=1 fenced ```mermaid``` block; zero *.mmd files under
                     architecture/; no architecture/README.md hub; every spec
                     arch.md has >=1 fenced ```mermaid``` block.
      linking      - idea file wikilinks its specs index; specs index wikilinks
                     the idea and each SPEC; SPEC note wikilinks its Backlog items
                     and architecture.md; specs contain no architecture/README
                     reference and no bare-relative architecture path.
      trace        - the most recent Traces/Session-*/ has the 7 canonical files.
      memory       - when substantive decisions were made (ADRs/specs/gate),
                     memory/decisions or memory/preferences is non-empty.
      token        - the most recent Traces/Session-*/ TokenUsage.md records at
                     least one actuals row (harness-reported|api-usage|
                     manual-meter|unavailable), never estimates only.
      harness      - when a .dsh surface exists it must be complete and in sync
                     with .KCC/capabilities/skills/ and every generated
                     .dsh/skills/{name}/SKILL.md must carry the full KCC worker
                     boundary text (native read-only allowlist direct, fail
                     closed, exact kcc_policy_exec/kcc_policy_write, KCC owns
                     controller/status/resume); root AGENTS.md must exist.
      autobuild    - adapter compatibility + bootstrap optional runtime: every
                     generated surface (.codex/.claude/.agents/.opencode/.dsh)
                     must carry the autobuild outputs (autobuild,
                     autobuild-task-execute) and keep the legacy auto skill;
                     once any surface advertises autobuild output the
                     .KCC/runtime package must exist (framework-init
                     -EnableAutobuild only PRINTS the Python 3.11+ check and
                     install command - never a silent install).
      secrets      - durable state (coordination/, Traces/, memory/) carries
                     secret references only; any plaintext secret finding
                     (sk-..., AKIA..., gh[pousr]_..., xox..., PEM private key)
                     is an error.

    Read-only. PowerShell 5.1 compatible. No && operator.

.PARAMETER RepoRoot
    Workspace root to check. Defaults to the parent of .KCC.

.PARAMETER Scope
    Which checks to run: all | architecture | linking | trace | memory | token | harness | autobuild | secrets.
    The architecture gate in `auto` calls `-Scope architecture`.

.PARAMETER Json
    Emit the violation list as JSON (for the orchestrator to parse).

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .KCC\tools\check-run-conformance.ps1
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .KCC\tools\check-run-conformance.ps1 -Scope architecture
#>

[CmdletBinding()]
param(
    [string]$RepoRoot,
    [ValidateSet('all', 'architecture', 'linking', 'trace', 'memory', 'token', 'harness', 'autobuild', 'secrets')]
    [string]$Scope = 'all',
    [switch]$Json
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
$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path

$violations = New-Object System.Collections.ArrayList

function Add-Violation {
    param(
        [string]$Code,
        [ValidateSet('error', 'warning')] [string]$Severity,
        [string]$Owner,
        [string]$Message
    )
    [void]$violations.Add([pscustomobject]@{
            code     = $Code
            severity = $Severity
            owner    = $Owner
            message  = $Message
        })
}

function Read-Text([string]$path) {
    try { return [System.IO.File]::ReadAllText($path) } catch { return '' }
}

function Test-HasMermaid([string]$text) {
    return ($text -match '(?m)^\s*```mermaid')
}

function Get-RelPath([string]$full) {
    return ($full.Substring($RepoRoot.Length)).TrimStart('\', '/')
}

$archDir = Join-Path $RepoRoot 'architecture'
$specsDir = Join-Path $RepoRoot 'specs'
$ideationDir = Join-Path $RepoRoot 'ideation'
$tracesDir = Join-Path $RepoRoot 'Traces'
$memoryDir = Join-Path $RepoRoot 'memory'
$dshSkillsDir = Join-Path $RepoRoot '.dsh/skills'
$capSkillsDir = Join-Path $RepoRoot '.KCC/capabilities/skills'

# Plan 07, Task 5 -- adapter compatibility + bootstrap optional runtime.
# Generated adapter surfaces (.codex, .claude, .agents, .opencode, .dsh)
# must carry the autobuild outputs (autobuild, autobuild-task-execute) and
# keep the legacy auto skill; once any surface advertises autobuild output,
# the autobuild runtime must exist. framework-init -EnableAutobuild only
# PRINTS the Python 3.11+ check and the install command - the runtime is
# opt-in and never installed silently, so plain KCC init still continues
# without it.
$AutobuildSurfaces = @('codex', 'claude', 'agents', 'opencode', 'dsh')
$AutobuildMarker = 'Run the approved autobuild discovery workflow'
$TaskExecuteMarker = 'Execute one bounded autobuild task'
$LegacyAutoMarker = 'Human-On-The-Loop'
$AutobuildRuntimePyproject = Join-Path $RepoRoot '.KCC/runtime/pyproject.toml'
$AutobuildRuntimePkg = Join-Path $RepoRoot '.KCC/runtime/src/kcc_autobuild'

# Durable-state secret scan surface (Plan 07, Task 5): plaintext secret
# material in coordination/, Traces/ or memory/ is a finding; secret
# REFERENCES (vault://, env://, keychain://) are the only allowed form.
$SecretDirs = @('coordination', 'Traces', 'memory')
$SecretRawPattern = 'sk-[A-Za-z0-9_-]{12,}|AKIA[0-9A-Z]{16}|gh[pousr]_[A-Za-z0-9]{20,}|xox[baprs]-[A-Za-z0-9-]{10,}|-----BEGIN [A-Z ]*PRIVATE KEY-----'

# ---------------------------------------------------------------------------
# ARCHITECTURE
# ---------------------------------------------------------------------------
function Invoke-ArchitectureChecks {
    if (-not (Test-Path -LiteralPath $archDir)) { return }

    # Only judge a "populated" architecture folder (real run output).
    $adrs = @(Get-ChildItem -LiteralPath $archDir -Recurse -File -Filter '*.md' -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -ne '.gitkeep' })
    $mmd = @(Get-ChildItem -LiteralPath $archDir -Recurse -File -Filter '*.mmd' -ErrorAction SilentlyContinue)
    $populated = ($adrs.Count -gt 0) -or ($mmd.Count -gt 0)
    if (-not $populated) { return }

    $archDoc = Join-Path $archDir 'architecture.md'
    if (-not (Test-Path -LiteralPath $archDoc)) {
        Add-Violation 'ARCH-001' 'error' 'architect' 'architecture/architecture.md is missing. The Architecture Document must exist (not a README hub).'
    }
    else {
        $text = Read-Text $archDoc
        if ($text.Length -lt 800) {
            Add-Violation 'ARCH-002a' 'error' 'architect' ("architecture/architecture.md is a stub ({0} bytes). It must be a narrative document with embedded diagrams." -f $text.Length)
        }
        if (-not (Test-HasMermaid $text)) {
            Add-Violation 'ARCH-002b' 'error' 'architect' 'architecture/architecture.md contains no embedded ```mermaid``` block. Diagrams must be embedded inline.'
        }
    }

    foreach ($f in $mmd) {
        Add-Violation 'ARCH-003' 'error' 'architect' ("Deprecated loose diagram file: {0}. Embed fenced ```mermaid``` in a .md instead." -f (Get-RelPath $f.FullName))
    }

    foreach ($name in @('README.md', 'readme.md')) {
        $readme = Join-Path $archDir $name
        if (Test-Path -LiteralPath $readme) {
            Add-Violation 'ARCH-004' 'error' 'architect' ("architecture/{0} must not exist - the Architecture Document is architecture.md, not a README hub." -f $name)
        }
    }

    if (Test-Path -LiteralPath $specsDir) {
        $specArchFiles = @(Get-ChildItem -LiteralPath $specsDir -Recurse -File -Filter 'arch.md' -ErrorAction SilentlyContinue)
        foreach ($sa in $specArchFiles) {
            $t = Read-Text $sa.FullName
            if (-not (Test-HasMermaid $t)) {
                Add-Violation 'ARCH-005' 'error' 'architect' ("{0} has no embedded ```mermaid``` block (content bar). Spec arch.md must embed its design slice." -f (Get-RelPath $sa.FullName))
            }
        }
    }
}

# ---------------------------------------------------------------------------
# LINKING (Obsidian graph)
# ---------------------------------------------------------------------------
function Invoke-LinkingChecks {
    if (-not (Test-Path -LiteralPath $ideationDir)) { return }

    $ideaFiles = @(Get-ChildItem -LiteralPath $ideationDir -Recurse -File -Filter 'idea-*.md' -ErrorAction SilentlyContinue)
    foreach ($idea in $ideaFiles) {
        $t = Read-Text $idea.FullName
        if ($t -notmatch '\[\[[^\]]*-Specs') {
            Add-Violation 'LINK-001' 'error' 'idea-interrogator' ("{0} does not wikilink its specs index ([[...-Specs...]]). Idea must connect to its specs in the graph." -f (Get-RelPath $idea.FullName))
        }
    }

    if (-not (Test-Path -LiteralPath $specsDir)) { return }

    # Spec index files: specs/IDEA-*-Specs/IDEA-*-Specs.md
    $indexFiles = @(Get-ChildItem -LiteralPath $specsDir -Recurse -File -Filter 'IDEA-*-Specs.md' -ErrorAction SilentlyContinue)
    foreach ($idx in $indexFiles) {
        $t = Read-Text $idx.FullName
        if ($t -notmatch '\[\[[^\]]*ideation') {
            Add-Violation 'LINK-002' 'error' 'spec-writer' ("{0} does not wikilink back to its idea ([[...ideation...]])." -f (Get-RelPath $idx.FullName))
        }
        if ($t -notmatch '\[\[[^\]]*SPEC-') {
            Add-Violation 'LINK-003' 'error' 'spec-writer' ("{0} does not wikilink any SPEC folder note." -f (Get-RelPath $idx.FullName))
        }
    }

    # SPEC folder notes: specs/.../SPEC-*/SPEC-*.md (folder note shares folder name)
    $specNotes = @(Get-ChildItem -LiteralPath $specsDir -Recurse -File -Filter 'SPEC-*.md' -ErrorAction SilentlyContinue |
            Where-Object { (Split-Path -Leaf (Split-Path -Parent $_.FullName)) -eq ($_.BaseName) })
    foreach ($note in $specNotes) {
        $t = Read-Text $note.FullName
        $rel = Get-RelPath $note.FullName
        # Strip wikilink spans so a correct [[../../../architecture/x]] is NOT
        # mistaken for a bare relative path.
        $stripped = [regex]::Replace($t, '\[\[[^\]]*\]\]', '')
        if ($t -match 'architecture[\\/](README|readme)') {
            Add-Violation 'LINK-004' 'error' 'spec-writer' ("{0} references architecture/README - link [[...architecture/architecture]] instead." -f $rel)
        }
        if ($stripped -match '(?m)\.\.[\\/].*architecture[\\/]') {
            Add-Violation 'LINK-005' 'error' 'spec-writer' ("{0} uses bare (non-wikilink) relative architecture paths - use [[wikilinks]] so the graph connects." -f $rel)
        }
        if ($t -notmatch '\[\[[^\]]*architecture') {
            Add-Violation 'LINK-006' 'error' 'spec-writer' ("{0} does not wikilink the Architecture Document ([[...architecture/architecture]])." -f $rel)
        }
        if ($t -notmatch '\[\[[^\]]*(Story|Enabler)-') {
            Add-Violation 'LINK-007' 'error' 'spec-writer' ("{0} does not wikilink its stories/enablers." -f $rel)
        }
    }
}

# ---------------------------------------------------------------------------
# TRACE
# ---------------------------------------------------------------------------
function Invoke-TraceChecks {
    if (-not (Test-Path -LiteralPath $tracesDir)) { return }
    $sessions = @(Get-ChildItem -LiteralPath $tracesDir -Directory -Filter 'Session-*' -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending)
    if ($sessions.Count -eq 0) {
        Add-Violation 'TRACE-000' 'error' 'butler' 'No Traces/Session-* folder exists. Butler must create a trace session at run start.'
        return
    }
    $latest = $sessions[0]
    $required = @('Decisions.md', 'Handovers.md', 'Actions.md', 'ToolsUsed.md', 'HumanActions.md', 'HumanDecisions.md', 'TokenUsage.md')
    foreach ($r in $required) {
        if (-not (Test-Path -LiteralPath (Join-Path $latest.FullName $r))) {
            Add-Violation 'TRACE-001' 'error' 'butler' ("Trace session {0} is missing canonical file {1}. Copy _session-template and use the 7 canonical files." -f $latest.Name, $r)
        }
    }
}

# ---------------------------------------------------------------------------
# MEMORY
# ---------------------------------------------------------------------------
function Invoke-MemoryChecks {
    if (-not (Test-Path -LiteralPath $memoryDir)) { return }

    # Substantive run? (ADRs present, or specs created)
    $hasArch = (Test-Path -LiteralPath $archDir) -and (@(Get-ChildItem -LiteralPath $archDir -Recurse -File -Filter '*.md' -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne '.gitkeep' }).Count -gt 0)
    $hasSpecs = (Test-Path -LiteralPath $specsDir) -and (@(Get-ChildItem -LiteralPath $specsDir -Recurse -File -Filter 'SPEC-*.md' -ErrorAction SilentlyContinue).Count -gt 0)
    if (-not ($hasArch -or $hasSpecs)) { return }

    $decDir = Join-Path $memoryDir 'decisions'
    $preDir = Join-Path $memoryDir 'preferences'
    $decCount = if (Test-Path -LiteralPath $decDir) { @(Get-ChildItem -LiteralPath $decDir -File -Filter '*.md' -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne '.gitkeep' }).Count } else { 0 }
    $preCount = if (Test-Path -LiteralPath $preDir) { @(Get-ChildItem -LiteralPath $preDir -File -Filter '*.md' -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne '.gitkeep' }).Count } else { 0 }
    if (($decCount + $preCount) -eq 0) {
        Add-Violation 'MEM-001' 'error' 'butler' 'A substantive run (ADRs/specs created) recorded no memory entries. Butler must write decisions/preferences via memory-append, or justify "none".'
    }
}

# ---------------------------------------------------------------------------
# TOKEN ACTUALS
# ---------------------------------------------------------------------------
function Invoke-TokenChecks {
    if (-not (Test-Path -LiteralPath $tracesDir)) { return }
    # Only judge substantive runs (ADRs or specs produced).
    $hasArch = (Test-Path -LiteralPath $archDir) -and (@(Get-ChildItem -LiteralPath $archDir -Recurse -File -Filter '*.md' -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne '.gitkeep' }).Count -gt 0)
    $hasSpecs = (Test-Path -LiteralPath $specsDir) -and (@(Get-ChildItem -LiteralPath $specsDir -Recurse -File -Filter 'SPEC-*.md' -ErrorAction SilentlyContinue).Count -gt 0)
    if (-not ($hasArch -or $hasSpecs)) { return }

    $sessions = @(Get-ChildItem -LiteralPath $tracesDir -Directory -Filter 'Session-*' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)
    if ($sessions.Count -eq 0) { return }
    $tokenFile = Join-Path $sessions[0].FullName 'TokenUsage.md'
    if (-not (Test-Path -LiteralPath $tokenFile)) {
        Add-Violation 'TOKEN-001' 'error' 'butler' ("Trace session {0} has no TokenUsage.md. Record actuals via record-token-actuals (SessionEnd hook / -ManualTotal / -Unavailable)." -f $sessions[0].Name)
        return
    }
    $t = Read-Text $tokenFile
    if ($t -notmatch '(?m)^\s*source:\s*(harness-reported|api-usage|manual-meter|unavailable)') {
        Add-Violation 'TOKEN-001' 'error' 'butler' ("TokenUsage.md in {0} has estimates only - no actual row (source: harness-reported|api-usage|manual-meter|unavailable). Run record-token-actuals at session end." -f $sessions[0].Name)
    }
}

# ---------------------------------------------------------------------------
# HARNESS (DSH generated surface)
# ---------------------------------------------------------------------------

# Required worker-boundary markers that every generated .dsh skill must carry.
# These encode the Plan 08 DSH worker boundary verbatim: post-lock native
# read-only allowlist direct; everything else fail-closed; governed actions go
# through exactly `kcc_policy_exec` / `kcc_policy_write`; KCC owns
# controller/status/resume. Skill generation alone is not Full Autopilot - the
# policy-guard profile/plugin proof is separate (Plan 08 Task 5 / Task 7).
$script:DshBoundaryMarkers = @(
    'native read-only allowlist',
    'fail closed',
    'kcc_policy_exec',
    'kcc_policy_write',
    'KCC owns controller, status, and resume',
    'code-runtime',
    'Cordis'
)

function Get-YamlScalar {
    # Extract the first `key: value` scalar from a YAML frontmatter block.
    param([Parameter(Mandatory)][string]$Text, [Parameter(Mandatory)][string]$Key)
    $m = [regex]::Match($Text, "(?m)^[ \t]*${Key}:[ \t]*([^#\r\n]+)")
    if ($m.Success) { return $m.Groups[1].Value.Trim() }
    return ''
}

function Invoke-HarnessChecks {
    # Generated harness surface conformance. Judges only what exists (the same
    # skip-if-absent rule as the other scopes): when a .dsh surface has been
    # generated, it must be complete, in sync with the neutral skills, and carry
    # the full worker-boundary text.
    if (-not (Test-Path -LiteralPath $dshSkillsDir)) { return }

    if (Test-Path -LiteralPath $capSkillsDir) {
        foreach ($src in @(Get-ChildItem -LiteralPath $capSkillsDir -File -Filter '*.md' -ErrorAction SilentlyContinue)) {
            $name = $src.BaseName
            if (-not (Test-Path -LiteralPath (Join-Path $dshSkillsDir "$name/SKILL.md"))) {
                Add-Violation 'DSH-001' 'error' 'sync-adapters' ("Neutral skill {0} has no generated .dsh/skills/{0}/SKILL.md - rerun sync-adapters dsh." -f $name)
            }
        }
    }

    foreach ($genDir in @(Get-ChildItem -LiteralPath $dshSkillsDir -Directory -ErrorAction SilentlyContinue)) {
        $name = $genDir.Name
        if ((Test-Path -LiteralPath $capSkillsDir) -and -not (Test-Path -LiteralPath (Join-Path $capSkillsDir "$name.md"))) {
            Add-Violation 'DSH-002' 'error' 'sync-adapters' ("Generated .dsh/skills/{0}/SKILL.md has no neutral source (.KCC/capabilities/skills/{0}.md) - stale surface, rerun sync-adapters dsh after removing the capability or delete the orphan." -f $name)
        }
    }

    foreach ($skillFile in @(Get-ChildItem -LiteralPath $dshSkillsDir -Recurse -File -Filter 'SKILL.md' -ErrorAction SilentlyContinue)) {
        $dirName = $skillFile.Directory.Name
        $text = Read-Text $skillFile.FullName
        $fmName = Get-YamlScalar -Text $text -Key 'name'
        if ($fmName -ne $dirName) {
            Add-Violation 'DSH-003' 'error' 'sync-adapters' ("{0} frontmatter name '{1}' does not match its skill directory - regenerate via sync-adapters dsh." -f (Get-RelPath $skillFile.FullName), $fmName)
        }
        $missing = @($script:DshBoundaryMarkers | Where-Object { $text.IndexOf($_) -lt 0 })
        if ($missing.Count -gt 0) {
            Add-Violation 'DSH-004' 'error' 'sync-adapters' ("{0} is missing worker-boundary markers: {1}" -f (Get-RelPath $skillFile.FullName), ($missing -join ' '))
        }
    }

    if (-not (Test-Path -LiteralPath (Join-Path $RepoRoot 'AGENTS.md'))) {
        Add-Violation 'DSH-005' 'error' 'framework-init' 'The .dsh surface exists but root AGENTS.md is missing. DSH reads root AGENTS.md as its entrypoint; it is created once from .KCC/kernel/templates/ when missing and then preserved (never overwritten by sync).'
    }
}

function Invoke-AutobuildChecks {
    # Plan 07, Task 5 -- autobuild adapter compatibility + optional runtime.
    # Judges only what exists (the same skip-if-absent rule as the other
    # scopes): a generated surface must carry the autobuild outputs
    # (autobuild, autobuild-task-execute) and keep the legacy auto skill;
    # once any surface advertises autobuild output the runtime must exist.
    $anySurface = $false
    foreach ($surface in $AutobuildSurfaces) {
        $surfaceDir = Join-Path $RepoRoot (".$surface")
        if (-not (Test-Path -LiteralPath $surfaceDir)) { continue }
        $anySurface = $true
        foreach ($req in @(
                @('autobuild', 'AUTOBUILD-002', 'AUTOBUILD-006', $AutobuildMarker, 'autobuild output'),
                @('autobuild-task-execute', 'AUTOBUILD-003', 'AUTOBUILD-007', $TaskExecuteMarker, 'autobuild-task-execute output'),
                @('auto', 'AUTOBUILD-004', 'AUTOBUILD-005', $LegacyAutoMarker, 'legacy auto output')
            )) {
            $skill = $req[0]
            $spath = Join-Path $surfaceDir ("skills/$skill/SKILL.md")
            if (-not (Test-Path -LiteralPath $spath)) {
                Add-Violation $req[1] 'error' 'sync-adapters' ("Generated .{0} surface is missing the {1} - rerun sync-adapters (the surface must carry autobuild outputs and keep legacy auto)." -f $surface, $req[4])
            }
            else {
                $text = Read-Text $spath
                if ($text.IndexOf($req[3]) -lt 0) {
                    Add-Violation $req[2] 'error' 'sync-adapters' ("{0} lost its {1} text - regenerate via sync-adapters." -f (Get-RelPath $spath), $req[4])
                }
            }
        }
    }

    if ($anySurface) {
        if (-not (Test-Path -LiteralPath $AutobuildRuntimePyproject) -or (-not (Test-Path -LiteralPath (Join-Path $AutobuildRuntimePkg '__init__.py')))) {
            Add-Violation 'AUTOBUILD-001' 'error' 'framework-init' 'Autobuild outputs exist but the autobuild runtime is missing (.KCC/runtime) - run framework-init -EnableAutobuild (checks Python 3.11+ and prints the install command only) or remove the generated autobuild outputs.'
        }
    }
}

function Invoke-SecretChecks {
    # Durable-state secret scan: coordination/, Traces/, memory/ must carry
    # secret REFERENCES only, never raw material (fail closed, like the
    # handoff-pack rule the runtime enforces).
    foreach ($dirName in $SecretDirs) {
        $dir = Join-Path $RepoRoot $dirName
        if (-not (Test-Path -LiteralPath $dir)) { continue }
        foreach ($file in @(Get-ChildItem -LiteralPath $dir -Recurse -File -ErrorAction SilentlyContinue)) {
            $text = Read-Text $file.FullName
            foreach ($m in [regex]::Matches($text, $SecretRawPattern)) {
                Add-Violation 'SECRET-001' 'error' 'framework-init' ("{0} contains a plaintext secret finding '{1}' - durable state must carry references only (vault://, env://, keychain://)." -f (Get-RelPath $file.FullName), $m.Value)
            }
        }
    }
}

if ($Scope -eq 'all' -or $Scope -eq 'architecture') { Invoke-ArchitectureChecks }
if ($Scope -eq 'all' -or $Scope -eq 'linking') { Invoke-LinkingChecks }
if ($Scope -eq 'all' -or $Scope -eq 'trace') { Invoke-TraceChecks }
if ($Scope -eq 'all' -or $Scope -eq 'memory') { Invoke-MemoryChecks }
if ($Scope -eq 'all' -or $Scope -eq 'token') { Invoke-TokenChecks }
if ($Scope -eq 'all' -or $Scope -eq 'harness') { Invoke-HarnessChecks }
if ($Scope -eq 'all' -or $Scope -eq 'autobuild') { Invoke-AutobuildChecks }
if ($Scope -eq 'all' -or $Scope -eq 'secrets') { Invoke-SecretChecks }

$errors = @($violations | Where-Object { $_.severity -eq 'error' })
$warnings = @($violations | Where-Object { $_.severity -eq 'warning' })

if ($Json) {
    [pscustomobject]@{
        repo_root   = $RepoRoot
        scope       = $Scope
        error_count = $errors.Count
        warn_count  = $warnings.Count
        violations  = $violations
    } | ConvertTo-Json -Depth 5
}
else {
    Write-Output ("KCC run conformance: {0}  (scope: {1})" -f $RepoRoot, $Scope)
    Write-Output ''
    if ($violations.Count -eq 0) {
        Write-Output 'Conformant. No violations.'
    }
    else {
        foreach ($v in $violations) {
            Write-Output ("  [{0}] {1}  (fix owner: {2})" -f $v.severity.ToUpper(), $v.code, $v.owner)
            Write-Output ("      {0}" -f $v.message)
        }
    }
    Write-Output ''
    Write-Output ("Errors: {0}" -f $errors.Count)
    Write-Output ("Warnings: {0}" -f $warnings.Count)
    if ($errors.Count -eq 0) { Write-Output 'Conformance check passed.' } else { Write-Output 'Conformance check FAILED.' }
}

if ($errors.Count -gt 0) { exit 1 } else { exit 0 }
