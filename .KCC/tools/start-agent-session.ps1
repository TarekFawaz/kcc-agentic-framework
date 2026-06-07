<#
KCC framework (c) 2026 Tarek Fawaz, https://tikasway.dev/kcc. Licensed under the terms in LICENSE.

.SYNOPSIS
    Open a visible local or sandboxed harness session window for a framework
    agent role. Supports -Sandbox to launch inside a per-harness Docker
    container; auto-engages sandbox mode when the target agent's frontmatter
    contains `lethal-trifecta-match: true`.

.DESCRIPTION
    Helper for HOTL/auto mode. The orchestrator must ask for human permission
    before invoking this script. By default it opens a visible cmd.exe window
    in the repo root and starts the requested harness command.

    With -Sandbox (or when the target agent is trifecta-marked), the script
    resolves .KCC/sandbox/Dockerfile.{harness}, lazily builds the image
    `kcc-sandbox-{harness}:latest`, and runs the harness inside a container
    that bind-mounts the cell repo at /workspace (rw), re-mounts
    .KCC/kernel and .KCC/capabilities read-only, applies an outbound-only
    network policy with a known LLM-host allowlist, and prints a one-line
    summary on exit.

    See .KCC/kernel/protocols/sandbox-runtime.md and .KCC/sandbox/README.md.

    It is intentionally conservative: it does not inject secrets, does not run
    implementation commands itself, and supports -DryRun so the orchestrator can
    show the planned fan-out before opening windows or building containers.

.PARAMETER Sandbox
    Switch. When set (or when the target agent declares
    `lethal-trifecta-match: true` in its frontmatter), the harness is launched
    inside a Docker container instead of a host cmd.exe window. Requires
    `docker` on PATH.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .KCC\tools\start-agent-session.ps1 -Harness codex -Agent planner -Title "SPEC-003 planner" -PromptFile .\coordination\prompts\SPEC-003-planner.md

.EXAMPLE
    # Run a sandboxed Claude session for the idea-interrogator agent:
    powershell -ExecutionPolicy Bypass -File .KCC\tools\start-agent-session.ps1 -Harness claude -Agent idea-interrogator -Sandbox

.EXAMPLE
    # Dry-run a sandboxed Codex session to inspect the planned mounts and network:
    powershell -ExecutionPolicy Bypass -File .KCC\tools\start-agent-session.ps1 -Harness codex -Agent planner -Sandbox -DryRun
#>

[CmdletBinding()]
param(
    [ValidateSet('claude', 'codex', 'opencode', 'generic', 'cmd', 'powershell')]
    [string]$Harness = 'cmd',

    [Parameter(Mandatory)]
    [string]$Agent,

    [string]$RepoRoot,

    [string]$Title,

    [string]$Prompt,

    [string]$PromptFile,

    [switch]$Sandbox,

    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

# Recognised LLM-provider hosts. Keep in sync with sandbox-runtime.md.
$Script:LlmHostAllowlist = @(
    'api.anthropic.com',
    'api.openai.com',
    'api.openrouter.ai',
    'api.mistral.ai',
    'generativelanguage.googleapis.com',
    'api.deepseek.com'
)

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

function Test-AgentTrifectaMarker {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$AgentName
    )
    $candidate = Join-Path $Root (".KCC/capabilities/agents/{0}.md" -f $AgentName)
    if (-not (Test-Path -LiteralPath $candidate)) {
        return $false
    }
    $raw = [System.IO.File]::ReadAllText($candidate, [System.Text.Encoding]::UTF8)
    # Extract frontmatter (between first two `---` lines).
    $m = [regex]::Match($raw, '(?ms)\A---\s*\r?\n(.*?)\r?\n---\s*\r?\n')
    if (-not $m.Success) {
        return $false
    }
    $front = $m.Groups[1].Value
    return ($front -match '(?im)^\s*lethal-trifecta-match:\s*true\s*$')
}

function Resolve-SandboxDockerfile {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$HarnessName
    )
    # Cells convention: prefer local override, fall back to kernel image.
    $local = Join-Path $Root ("local/sandbox/Dockerfile.{0}" -f $HarnessName)
    if (Test-Path -LiteralPath $local) {
        return @{ Path = $local; Context = (Split-Path -Parent $local); Source = 'local' }
    }
    $kernel = Join-Path $Root (".KCC/sandbox/Dockerfile.{0}" -f $HarnessName)
    if (Test-Path -LiteralPath $kernel) {
        return @{ Path = $kernel; Context = (Split-Path -Parent $kernel); Source = 'kernel' }
    }
    throw "No sandbox Dockerfile for harness '$HarnessName'. Expected '$kernel' or '$local'."
}

function ConvertTo-DockerMountPath {
    param([Parameter(Mandatory)][string]$WindowsPath)
    # Docker Desktop on Windows accepts forward-slash drive paths
    # (C:/Work/...) directly. Convert backslashes to forward slashes.
    return ($WindowsPath -replace '\\', '/')
}

function Test-DockerImageExists {
    param([Parameter(Mandatory)][string]$Tag)
    $null = & docker image inspect $Tag 2>$null
    return ($LASTEXITCODE -eq 0)
}

function Invoke-SandboxBuild {
    param(
        [Parameter(Mandatory)][string]$Tag,
        [Parameter(Mandatory)][string]$DockerfilePath,
        [Parameter(Mandatory)][string]$ContextPath
    )
    Write-Host "Building sandbox image $Tag from $DockerfilePath ..."
    & docker build -t $Tag $ContextPath -f $DockerfilePath
    if ($LASTEXITCODE -ne 0) {
        throw "docker build failed for $Tag (exit $LASTEXITCODE)."
    }
}

function Build-SandboxRunArgs {
    param(
        [Parameter(Mandatory)][string]$Tag,
        [Parameter(Mandatory)][string]$RepoRootPath,
        [Parameter(Mandatory)][string]$WindowTitle,
        [Parameter(Mandatory)][string]$HarnessCommand
    )
    $mountRepo   = ConvertTo-DockerMountPath -WindowsPath $RepoRootPath
    $mountKernel = ConvertTo-DockerMountPath -WindowsPath (Join-Path $RepoRootPath '.KCC/kernel')
    $mountCaps   = ConvertTo-DockerMountPath -WindowsPath (Join-Path $RepoRootPath '.KCC/capabilities')

    $runArgs = New-Object System.Collections.ArrayList
    [void]$runArgs.AddRange(@('run', '--rm', '-it'))
    [void]$runArgs.AddRange(@('--name', "kcc-$WindowTitle-$([guid]::NewGuid().ToString('N').Substring(0,8))"))
    # Cell repo rw at /workspace
    [void]$runArgs.AddRange(@('-v', "${mountRepo}:/workspace"))
    # Kernel + capabilities ro on top
    [void]$runArgs.AddRange(@('-v', "${mountKernel}:/workspace/.KCC/kernel:ro"))
    [void]$runArgs.AddRange(@('-v', "${mountCaps}:/workspace/.KCC/capabilities:ro"))
    [void]$runArgs.AddRange(@('-w', '/workspace'))

    # Network policy: outbound only, no inbound ports. Default bridge network
    # already drops inbound; we do not publish any -p flags. The LLM host
    # allowlist is informational here -- a hardened deployment should layer
    # an egress proxy via HTTP_PROXY/HTTPS_PROXY env vars.
    if ($env:HTTP_PROXY)  { [void]$runArgs.AddRange(@('-e', "HTTP_PROXY=$($env:HTTP_PROXY)")) }
    if ($env:HTTPS_PROXY) { [void]$runArgs.AddRange(@('-e', "HTTPS_PROXY=$($env:HTTPS_PROXY)")) }
    if ($env:NO_PROXY)    { [void]$runArgs.AddRange(@('-e', "NO_PROXY=$($env:NO_PROXY)")) }

    [void]$runArgs.Add($Tag)
    # Run the harness command (default CMD of the image already does this,
    # but be explicit so -Harness powershell|cmd works too).
    [void]$runArgs.Add($HarnessCommand)

    return @($runArgs)
}

function Invoke-SandboxRun {
    param(
        [Parameter(Mandatory)][string]$Tag,
        [Parameter(Mandatory)][string]$RepoRootPath,
        [Parameter(Mandatory)][string]$WindowTitle,
        [Parameter(Mandatory)][string]$HarnessCommand,
        [Parameter(Mandatory)][string]$AgentName,
        [Parameter(Mandatory)][string]$HarnessName,
        [Parameter(Mandatory)][string]$DockerfileSource
    )
    $runArgs = Build-SandboxRunArgs `
        -Tag $Tag `
        -RepoRootPath $RepoRootPath `
        -WindowTitle $WindowTitle `
        -HarnessCommand $HarnessCommand

    Write-Host ''
    Write-Host "Sandbox session:"
    Write-Host "  Harness:    $HarnessName"
    Write-Host "  Agent:      $AgentName"
    Write-Host "  Image:      $Tag ($DockerfileSource Dockerfile)"
    Write-Host "  Mount (rw): $RepoRootPath -> /workspace"
    Write-Host "  Mount (ro): .KCC/kernel, .KCC/capabilities"
    Write-Host "  Network:    outbound-only; LLM allowlist: $($Script:LlmHostAllowlist -join ', ')"
    Write-Host ''

    & docker @runArgs
    $exitCode = $LASTEXITCODE

    Write-Host ''
    Write-Host "Sandbox exited (code $exitCode). Mounts: /workspace(rw), .KCC/kernel(ro), .KCC/capabilities(ro). Network: outbound-only."
    return $exitCode
}

# ============================================================
# Main
# ============================================================

if (-not $RepoRoot) {
    $RepoRoot = Resolve-RepoRootFromTool
}

$resolvedRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
$windowTitle = if ($Title) { $Title } else { "agent-$Agent-$Harness" }

switch ($Harness) {
    'claude'     { $harnessCommand = 'claude' }
    'codex'      { $harnessCommand = 'codex' }
    'opencode'   { $harnessCommand = 'opencode' }
    'generic'    { $harnessCommand = 'pwsh' }
    'powershell' { $harnessCommand = 'powershell' }
    default      { $harnessCommand = 'cmd' }
}

# Decide whether sandbox mode applies.
$trifectaMarked = Test-AgentTrifectaMarker -Root $resolvedRoot -AgentName $Agent
$useSandbox = ($Sandbox.IsPresent -or $trifectaMarked)
if ($trifectaMarked -and -not $Sandbox.IsPresent) {
    Write-Host "Agent '$Agent' is marked 'lethal-trifecta-match: true' -- auto-engaging sandbox mode."
}

if ($useSandbox) {
    # Sandbox only supports real harnesses + generic.
    if ($Harness -in @('cmd', 'powershell')) {
        throw "Sandbox mode requires -Harness claude|codex|opencode|generic (got '$Harness')."
    }

    $df = Resolve-SandboxDockerfile -Root $resolvedRoot -HarnessName $Harness
    $imageTag = "kcc-sandbox-${Harness}:latest"

    if ($DryRun) {
        Write-Host "Would launch sandboxed session:"
        Write-Host "  Harness:        $Harness"
        Write-Host "  Agent:          $Agent"
        Write-Host "  Root:           $resolvedRoot"
        Write-Host "  Dockerfile:     $($df.Path) ($($df.Source))"
        Write-Host "  Image tag:      $imageTag"
        Write-Host "  Cached:         $(if (Test-DockerImageExists -Tag $imageTag) { 'yes' } else { 'no (would build)' })"
        Write-Host "  Mounts:         /workspace(rw), .KCC/kernel(ro), .KCC/capabilities(ro)"
        Write-Host "  Network:        outbound-only; LLM allowlist: $($Script:LlmHostAllowlist -join ', ')"
        if ($PromptFile) {
            $promptPath = (Resolve-Path -LiteralPath $PromptFile).Path
            Write-Host "  Prompt file:    $promptPath"
        } elseif ($Prompt) {
            Write-Host "  Prompt:         $Prompt"
        }
        exit 0
    }

    $dockerCmd = Get-Command docker -ErrorAction SilentlyContinue
    if (-not $dockerCmd) {
        throw "docker not found on PATH. Install Docker Desktop (Windows/macOS) or Docker Engine (Linux)."
    }

    if (-not (Test-DockerImageExists -Tag $imageTag)) {
        Invoke-SandboxBuild -Tag $imageTag -DockerfilePath $df.Path -ContextPath $df.Context
    } else {
        Write-Host "Using cached sandbox image: $imageTag"
    }

    $exit = Invoke-SandboxRun `
        -Tag $imageTag `
        -RepoRootPath $resolvedRoot `
        -WindowTitle $windowTitle `
        -HarnessCommand $harnessCommand `
        -AgentName $Agent `
        -HarnessName $Harness `
        -DockerfileSource $df.Source

    exit $exit
}

# ----- Non-sandbox path (unchanged behaviour) -----

$promptHint = ''
if ($PromptFile) {
    $promptPath = (Resolve-Path -LiteralPath $PromptFile).Path
    $promptHint = " && echo Prompt file: $promptPath"
} elseif ($Prompt) {
    $promptHint = " && echo Prompt: $Prompt"
}

$cmdLine = "title $windowTitle && cd /d `"$resolvedRoot`" && echo Agent role: $Agent$promptHint && $harnessCommand"

if ($DryRun) {
    Write-Host "Would open session window:"
    Write-Host "  Harness: $Harness"
    Write-Host "  Agent:   $Agent"
    Write-Host "  Root:    $resolvedRoot"
    Write-Host "  Command: cmd.exe /k $cmdLine"
    exit 0
}

Start-Process -FilePath 'cmd.exe' -ArgumentList @('/k', $cmdLine) -WorkingDirectory $resolvedRoot
