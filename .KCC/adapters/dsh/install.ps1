<#
KCC framework (c) 2026 Tarek Fawaz, https://tikasway.dev/kcc. Licensed under the terms in LICENSE.

.SYNOPSIS
    KCC hardened DSH profile installer (Plan 08, Task 5).

.DESCRIPTION
    EXPLICIT ONLY: copies the hardened kcc-autobuild profile package into
    $DSH_HOME\profiles and installs the repo adapter via

        dsh plugin --profile kcc-autobuild add .KCC\adapters\dsh\plugin

    Nothing DSH_HOME-related happens implicitly: framework-init only PRINTS
    this command by default (it never silently mutates DSH_HOME).

    The profile pins sandbox workspace-write + approval never + the
    kcc-policy-gate guard and applies ONLY to fresh sessions; the live
    proof runs only against disposable copies (doctor/smoke).

.PARAMETER DshHome
    DSH home (default: $env:DSH_HOME or ~/.dsh).

.PARAMETER Profile
    Profile name (default: kcc-autobuild).

.PARAMETER GateCommand
    Local kcc-autobuild CLI (default: $env:KCC_AUTOBUILD_GATE_COMMAND or kcc-autobuild).

.PARAMETER Python
    Python with kcc_autobuild installed (default: $env:KCC_AUTOBUILD_PYTHON or python3).

.PARAMETER CredentialsFile
    Credentials document of the host dsh home.

.PARAMETER RulesFile
    JSON array of exact-match policy rules (default: empty = fail closed).

.PARAMETER Force
    Replace an already installed profile.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .KCC\adapters\dsh\install.ps1
#>

[CmdletBinding()]
param(
    [string]$DshHome = $(if ($env:DSH_HOME) { $env:DSH_HOME } else { Join-Path $HOME '.dsh' }),
    [string]$Profile = 'kcc-autobuild',
    [string]$GateCommand = $(if ($env:KCC_AUTOBUILD_GATE_COMMAND) { $env:KCC_AUTOBUILD_GATE_COMMAND } else { 'kcc-autobuild' }),
    [string]$Python = $(if ($env:KCC_AUTOBUILD_PYTHON) { $env:KCC_AUTOBUILD_PYTHON } else { 'python3' }),
    [string]$CredentialsFile = '',
    [string]$RulesFile = '',
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

try { $toolDir = Split-Path -Parent $PSCommandPath } catch { $toolDir = (Get-Location).Path }
$adapterDir = $toolDir
$repoRoot = Split-Path -Parent (Split-Path -Parent $toolDir)

if (-not $CredentialsFile) { $CredentialsFile = Join-Path $DshHome '.credentials.yaml' }

Write-Host ''
Write-Host "KCC hardened $Profile profile installer"
Write-Host "  DSH_HOME:     $DshHome"
Write-Host "  profile:      $Profile"
Write-Host "  gate command: $GateCommand"
Write-Host "  credentials:  $CredentialsFile"
Write-Host ''

if (-not (Get-Command dsh -ErrorAction SilentlyContinue)) { throw 'dsh CLI not found on PATH' }
if (-not (Get-Command pnpm -ErrorAction SilentlyContinue)) { throw 'pnpm not found (dsh plugin forwards to pnpm)' }
if (-not (Test-Path -LiteralPath (Join-Path $adapterDir 'plugin'))) { throw "repo adapter missing: $(Join-Path $adapterDir 'plugin')" }

$profileDir = Join-Path $DshHome "profiles\$Profile"
$gateDir = Join-Path $profileDir 'gate'
$gateBundleFile = Join-Path $gateDir 'policy-bundle.json'
$gateSecretFile = Join-Path $gateDir '.gate-secret'

if ((Test-Path -LiteralPath (Join-Path $profileDir 'package.json')) -and -not $Force) {
    throw "profile $Profile already installed at $profileDir (use -Force to replace)"
}

New-Item -ItemType Directory -Force -Path $profileDir, $gateDir | Out-Null

# 1. Profile manifest + root composition seed (base + headless bundles).
Copy-Item -LiteralPath (Join-Path $adapterDir 'profile\package.json') -Destination (Join-Path $profileDir 'package.json')
Copy-Item -LiteralPath (Join-Path $adapterDir 'profile\cordis.yml') -Destination (Join-Path $profileDir 'cordis.yml')
Copy-Item -LiteralPath (Join-Path $adapterDir 'profile\pnpm-workspace.yaml') -Destination (Join-Path $profileDir 'pnpm-workspace.yaml')

# 2. Hardened patch layer (machine-local substitutions).
$patch = (Get-Content -Raw -LiteralPath (Join-Path $adapterDir 'profile\cordis.patch.yml'))
$patch = $patch.Replace('{{KCC_PROFILE_GATE_COMMAND}}', $GateCommand)
$patch = $patch.Replace('{{KCC_PROFILE_GATE_BUNDLE_FILE}}', $gateBundleFile)
$patch = $patch.Replace('{{KCC_PROFILE_GATE_SECRET_FILE}}', $gateSecretFile)
$patch = $patch.Replace('{{KCC_PROFILE_CREDENTIALS_FILE}}', $CredentialsFile)
Set-Content -LiteralPath (Join-Path $profileDir 'cordis.patch.yml') -Value $patch -Encoding UTF8
Write-Host "[install   ] hardened patch: $(Join-Path $profileDir 'cordis.patch.yml')"

# 3. Plugin peer scope (module resolution from the linked realpath).
$dshResolved = Get-Command dsh | Select-Object -ExpandProperty Source
if (Test-Path -LiteralPath $dshResolved) {
    $item = Get-Item -LiteralPath $dshResolved
    if (-not $item.PSIsContainer -and $item.LinkType) { $dshResolved = $item.LinkTarget }
}
$dshHomeResolved = Split-Path -Parent (Split-Path -Parent $dshResolved)
$scopeDir = Join-Path $dshHomeResolved 'node_modules\@deepseek-ai'
if (-not (Test-Path -LiteralPath $scopeDir)) {
    throw "cannot resolve the dsh @deepseek-ai scope: $scopeDir"
}
$pluginModules = Join-Path $adapterDir 'plugin\node_modules'
New-Item -ItemType Directory -Force -Path $pluginModules | Out-Null
$scopeLink = Join-Path $pluginModules '@deepseek-ai'
if (-not (Test-Path -LiteralPath $scopeLink)) {
    New-Item -ItemType SymbolicLink -Path $scopeLink -Target $scopeDir | Out-Null
}
Write-Host "[install   ] plugin peer scope: $scopeLink -> $scopeDir"

# 4. Signed policy bundle + owner-only secret (default: empty = fail closed).
$signArgs = @('--out-dir', $gateDir)
if ($RulesFile) { $signArgs += @('--rules-file', $RulesFile) }
& $Python (Join-Path $adapterDir 'gate\sign-policy.py') $signArgs | ForEach-Object { Write-Host "[install   ] $_" }

# 5. Install the repo adapter into the profile (explicit, contract step).
Push-Location $repoRoot
try {
    $env:DSH_HOME = $DshHome
    & dsh plugin --profile $Profile add (Join-Path $adapterDir 'plugin')
    Write-Host "[install   ] repo adapter installed: dsh plugin --profile $Profile add $adapterDir\plugin"
    # 6. Post-install boot proof (composition only).
    & dsh --profile $Profile --dump-config | Set-Content -LiteralPath (Join-Path $profileDir '.boot-config.txt')
    if (-not (Select-String -LiteralPath (Join-Path $profileDir '.boot-config.txt') -Pattern 'kcc-policy-gate' -Quiet)) {
        throw "$Profile profile boot does not compose the kcc-policy-gate row"
    }
    Write-Host "[install   ] boot proof: $Profile profile composes the kcc-policy-gate row"
} finally {
    Pop-Location
}

Write-Host ''
Write-Host "Hardened $Profile profile installed."
Write-Host '  Live proof:  kcc-autobuild harness doctor dsh --live --template kcc-autobuild'
Write-Host '  Worker run:  dsh --profile kcc-autobuild "<bounded task prompt>"'
Write-Host '  framework-init prints this command by default (add -InstallDshProfile to run it).'
