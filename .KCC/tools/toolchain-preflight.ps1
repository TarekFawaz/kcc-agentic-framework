<#
KCC framework (c) 2026 Tarek Fawaz, https://tikasway.dev/kcc. Licensed under the terms in LICENSE.

.SYNOPSIS
    Detect whether a build/test toolchain is present, and suggest per-OS
    install commands for whatever is missing.

.DESCRIPTION
    Detection + suggestion only. For each tool in -Tools, this script checks
    presence via Get-Command and prints PRESENT (with version) or MISSING.
    For each missing tool it prints a suggested install command for the
    current OS (winget on Windows, brew on macOS, apt/dnf on Linux).

    This script NEVER installs anything. Toolchain install is a human-gated,
    system-mutating action (see .KCC/kernel/protocols/toolchain-preflight.md).
    The agent runs installs at runtime only after explicit human approval.

    Exit code: 0 if all tools are present, 1 if any tool is missing.

    PowerShell 5.1 compatible. No && operator.

.PARAMETER Tools
    Comma-separated list of tool executables to check, e.g. "node,pnpm,git".

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .KCC\tools\toolchain-preflight.ps1 -Tools node,pnpm,git
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Tools
)

$ErrorActionPreference = 'Stop'

# Detect the current OS family (PS 5.1 has no $IsWindows automatic variable).
function Get-OSFamily {
    if ($env:OS -eq 'Windows_NT') { return 'windows' }
    if (Test-Path '/System/Library/CoreServices') { return 'macos' }
    return 'linux'
}

# Pick a Linux package-manager hint (apt vs dnf).
function Get-LinuxInstaller {
    if (Get-Command apt-get -ErrorAction SilentlyContinue) { return 'apt-get install -y' }
    if (Get-Command dnf -ErrorAction SilentlyContinue) { return 'dnf install -y' }
    return 'apt-get install -y'   # default hint
}

# Suggest an install command for a missing tool on the current OS.
function Get-InstallSuggestion {
    param([string]$Tool, [string]$OS)

    # Tool-specific globals first.
    switch ($Tool) {
        'pnpm' { return 'corepack enable; corepack prepare pnpm@latest --activate   (or: npm i -g pnpm)' }
        'cargo' { return 'install rustup from https://rustup.rs (rustup-init), then: rustup default stable' }
        'flutter' { return 'install Flutter SDK from https://docs.flutter.dev/get-started/install' }
    }

    switch ($OS) {
        'windows' {
            $map = @{
                node = 'winget install OpenJS.NodeJS.LTS'
                npm  = 'winget install OpenJS.NodeJS.LTS'
                git  = 'winget install Git.Git'
                python = 'winget install Python.Python.3.12'
                go   = 'winget install GoLang.Go'
                dotnet = 'winget install Microsoft.DotNet.SDK.8'
                terraform = 'winget install HashiCorp.Terraform'
                kubectl = 'winget install Kubernetes.kubectl'
                helm = 'winget install Helm.Helm'
                dart = 'winget install Google.DartSDK'
            }
            if ($map.ContainsKey($Tool)) { return $map[$Tool] + '   (fallback: choco install / scoop install)' }
            return "winget install <package-for-$Tool>   (fallback: choco/scoop)"
        }
        'macos' {
            $map = @{ node = 'brew install node'; npm = 'brew install node'; git = 'brew install git';
                      python = 'brew install python'; go = 'brew install go'; dotnet = 'brew install --cask dotnet-sdk';
                      terraform = 'brew install terraform'; kubectl = 'brew install kubectl'; helm = 'brew install helm';
                      dart = 'brew install dart' }
            if ($map.ContainsKey($Tool)) { return $map[$Tool] }
            return "brew install $Tool"
        }
        default {
            $inst = Get-LinuxInstaller
            $map = @{ node = 'nodejs'; npm = 'npm'; git = 'git'; python = 'python3'; go = 'golang-go';
                      dotnet = 'dotnet-sdk-8.0'; terraform = 'terraform'; kubectl = 'kubectl'; helm = 'helm';
                      dart = 'dart' }
            $pkg = if ($map.ContainsKey($Tool)) { $map[$Tool] } else { $Tool }
            return "sudo $inst $pkg   (may require elevation)"
        }
    }
}

$os = Get-OSFamily
$toolList = $Tools.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' }
$missing = @()

Write-Output "Toolchain preflight (OS: $os)"
Write-Output "-----------------------------------"

# A tool may carry a major-version constraint from plan.md '## Toolchain': node@>=20, node@20, node@>=20<25.
function Test-VersionOk([string]$version, [string]$constraint) {
    if (-not $constraint) { return $true }
    $m = [regex]::Match($version, '(\d+)(\.\d+)*')
    if (-not $m.Success) { return $true }
    $major = [int]$m.Groups[1].Value
    if ($constraint -match '^\d+$') { return $major -eq [int]$constraint }
    foreach ($c in [regex]::Matches($constraint, '(>=|<=|>|<|=)(\d+)')) {
        $n = [int]$c.Groups[2].Value
        switch ($c.Groups[1].Value) { '>=' { if ($major -lt $n) { return $false } } '<=' { if ($major -gt $n) { return $false } } '>' { if ($major -le $n) { return $false } } '<' { if ($major -ge $n) { return $false } } '=' { if ($major -ne $n) { return $false } } }
    }
    return $true
}

foreach ($spec in $toolList) {
    $tool = $spec; $constraint = ''
    if ($spec -match '^([^@]+)@(.+)$') { $tool = $Matches[1]; $constraint = $Matches[2] }
    $cmd = Get-Command $tool -ErrorAction SilentlyContinue
    if ($cmd) {
        $version = ''
        try { $version = (& $tool --version 2>$null | Select-Object -First 1) } catch { $version = '' }
        if ([string]::IsNullOrWhiteSpace($version)) { $version = 'present' }
        if (Test-VersionOk $version $constraint) {
            Write-Output ("PRESENT  {0}  ({1})" -f $tool, $version.Trim())
        } else {
            $missing += ($tool + '@' + $constraint)
            Write-Output ("WRONG    {0}  ({1}; the plan needs {2})" -f $tool, $version.Trim(), $constraint)
            Write-Output ("         install: {0}" -f (Get-InstallSuggestion -Tool $tool -OS $os))
        }
    } else {
        $missing += $tool
        Write-Output ("MISSING  {0}" -f $tool)
        Write-Output ("         install: {0}" -f (Get-InstallSuggestion -Tool $tool -OS $os))
    }
}

# Environment limits a run should know before it spends time on them. A Docker daemon that cannot reach a registry (TLS interception by
# a proxy or antivirus, no network) fails every image pull and build; one tiny pull here tells the verifier to defer those checks at
# once instead of finding out after a 20-minute build attempt (round 12). Printed as `LIMIT <what>: <why>`; never a missing tool.
function Test-DockerRegistry {
    # The daemon first: `docker` on PATH with Docker Desktop (or the service) stopped is not a registry problem (round 14 named it one).
    $daemon = ''
    try { $daemon = [string](& docker info --format '{{.ServerVersion}}' 2>$null | Select-Object -First 1) } catch { $daemon = '' }
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($daemon)) {
        Write-Output 'LIMIT docker-daemon unreachable: docker is installed but its daemon is not running (start Docker Desktop or the docker service); image pulls, builds and compose up will fail until it is'
        return
    }
    $outFile = [IO.Path]::GetTempFileName(); $errFile = [IO.Path]::GetTempFileName()
    $rc = 1; $last = 'no output'
    try {
        $p = Start-Process -FilePath 'docker' -ArgumentList 'pull -q hello-world:latest' -NoNewWindow -PassThru -RedirectStandardOutput $outFile -RedirectStandardError $errFile
        if (-not $p.WaitForExit(90000)) { try { $p.Kill() } catch { }; $rc = 124; $last = 'timed out after 90 s' }
        else { $rc = $p.ExitCode }
        if ($rc -ne 124) {
            $lines = @()
            foreach ($f in @($outFile, $errFile)) { try { $lines += [IO.File]::ReadAllLines($f) } catch { } }
            $lines = @($lines | Where-Object { $_.Trim() })
            if ($lines.Count -gt 0) { $last = $lines[-1]; if ($last.Length -gt 200) { $last = $last.Substring(0, 200) } }
        }
    } catch { $rc = 127; $last = $_.Exception.Message }
    finally { Remove-Item -LiteralPath $outFile, $errFile -Force -ErrorAction SilentlyContinue }
    if ($rc -ne 0) {
        Write-Output ("LIMIT docker-registry unreachable: the Docker daemon cannot pull from the registry (exit {0}: {1}); image builds and compose up --build will fail on this machine" -f $rc, $last)
        return
    }
    Write-Output 'PROBE    docker-registry reachable (docker pull hello-world)'
    # The daemon may trust the proxy's certificate while the build containers do not (Docker Desktop behind an antivirus: npm ci inside
    # RUN fails with UNABLE_TO_VERIFY_LEAF_SIGNATURE, BuildKit cannot fetch its frontend). One RUN that opens a TLS connection shows it.
    $d = Join-Path ([IO.Path]::GetTempPath()) ('kcc-preflight-' + [Guid]::NewGuid().ToString('N'))
    [void](New-Item -ItemType Directory -Path $d -Force)
    [IO.File]::WriteAllText((Join-Path $d 'Dockerfile'), "FROM alpine:3.21`nRUN wget -q -O /dev/null https://registry.npmjs.org/-/ping`n")
    $outFile = [IO.Path]::GetTempFileName(); $errFile = [IO.Path]::GetTempFileName()
    $rc = 1; $last = 'no matching output'
    try {
        $p = Start-Process -FilePath 'docker' -ArgumentList ('build --no-cache -q -t kcc-preflight-probe "' + $d + '"') -NoNewWindow -PassThru -RedirectStandardOutput $outFile -RedirectStandardError $errFile
        if (-not $p.WaitForExit(120000)) { try { $p.Kill() } catch { }; $rc = 124; $last = 'timed out after 120 s' } else { $rc = $p.ExitCode }
        if ($rc -ne 124) {
            $lines = @()
            foreach ($f in @($outFile, $errFile)) { try { $lines += [IO.File]::ReadAllLines($f) } catch { } }
            $hit = @($lines | Where-Object { $_ -match '(?i)certificate|x509|tls|ssl|unable to|could not resolve|network' })
            if ($hit.Count -gt 0) { $last = $hit[-1]; if ($last.Length -gt 200) { $last = $last.Substring(0, 200) } }
        }
    } catch { $rc = 127; $last = $_.Exception.Message }
    finally {
        Remove-Item -LiteralPath $outFile, $errFile -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue
        try { & docker image rm -f kcc-preflight-probe 2>$null | Out-Null } catch { }
    }
    if ($rc -eq 0) { Write-Output 'PROBE    docker-build-network reachable (a RUN step reached registry.npmjs.org over TLS)'; return }
    Write-Output ("LIMIT docker-build-network unreachable: a RUN step inside a build cannot reach registries over TLS (exit {0}: {1}); npm ci / pip install / apk inside docker build and compose up --build will fail on this machine (a proxy or antivirus intercepts TLS; see KCC_CA_BUNDLE)" -f $rc, $last)
}
foreach ($spec in $toolList) {
    $t = $spec; if ($spec -match '^([^@]+)@') { $t = $Matches[1] }
    if ($t -eq 'docker' -and (Get-Command docker -ErrorAction SilentlyContinue)) { Test-DockerRegistry; break }
}

Write-Output "-----------------------------------"
if ($missing.Count -gt 0) {
    Write-Output ("MISSING TOOLS: {0}" -f ($missing -join ', '))
    Write-Output "Toolchain install is a HUMAN-GATED action. Do NOT install silently."
    Write-Output "See .KCC/kernel/protocols/toolchain-preflight.md (install / human-install / defer)."
    exit 1
}

Write-Output "All required tools are present."
exit 0
