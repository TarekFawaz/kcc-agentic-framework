<#
KCC framework (c) 2026 Tarek Fawaz, https://tikasway.dev/kcc. Licensed under the terms in LICENSE.

.SYNOPSIS
    Detect and settle the workspace repo state before the first lifecycle write.

.DESCRIPTION
    Mirror of repo-bootstrap.sh. Protocol: .KCC/kernel/protocols/repo-bootstrap.md
    Contract: .KCC/kernel/contracts/tool-contract.md

    Detect (default): git presence, commits, remote (credentials redacted), auth
    kind (credential helper configured, `gh auth status` exit code, ssh-agent
    reachable - detected, never read), KCC pre-commit hook, dirty count.

    -Apply init-local      git init, KCC .gitignore if missing, pre-commit hook,
                           record decision, commit 'chore: KCC workspace bootstrap'.
    -Apply connect-remote  as init-local, then add origin -RemoteUrl (URLs carrying
                           credentials or tokens are rejected). Never pushes.
    -Apply skip            record the decision; git features degrade to snapshots.
    -InstallHook           install/refresh only the KCC hooks (pre-commit,
                           commit-msg, pre-push; see git-workflow.md).

    Exit: 0 ok | 1 violation/failed action | 2 usage/environment.
    PowerShell 5.1 compatible. ASCII-only. No && operator, no ternary.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .KCC\tools\repo-bootstrap.ps1 -Json
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .KCC\tools\repo-bootstrap.ps1 -Apply init-local -DryRun
#>

[CmdletBinding()]
param(
    [string]$RepoRoot,
    [switch]$Json,
    [string]$Apply,
    [string]$RemoteUrl,
    [switch]$DryRun,
    [switch]$InstallHook,
    [switch]$Emit
)

$ErrorActionPreference = 'Stop'
$Version = '1.0.0'
$HookMarker = 'KCC-PRE-COMMIT'
$HookNames = @('pre-commit', 'commit-msg', 'pre-push')
$HookMarkers = @{ 'pre-commit' = 'KCC-PRE-COMMIT'; 'commit-msg' = 'KCC-COMMIT-MSG'; 'pre-push' = 'KCC-PRE-PUSH' }

function Exit-Usage([string]$Message) {
    [Console]::Error.WriteLine('error: ' + $Message)
    exit 2
}

if ($Apply -and (@('init-local', 'connect-remote', 'skip') -notcontains $Apply)) { Exit-Usage '-Apply must be init-local, connect-remote, or skip' }
if ($RemoteUrl -and ($Apply -ne 'connect-remote')) { Exit-Usage '-RemoteUrl is only valid with -Apply connect-remote' }

function Resolve-RepoRootFromTool {
    if ($PSScriptRoot) { $toolDir = $PSScriptRoot }
    elseif ($MyInvocation.MyCommand.Path) { $toolDir = Split-Path -Parent $MyInvocation.MyCommand.Path }
    else { return (Get-Location).Path }
    $parent = Split-Path -Parent $toolDir
    if ((Split-Path -Leaf $parent) -eq '.KCC') { return (Split-Path -Parent $parent) }
    return $parent
}
if (-not $RepoRoot) { $RepoRoot = Resolve-RepoRootFromTool }
if (-not (Test-Path -LiteralPath $RepoRoot -PathType Container)) { Exit-Usage "repo root not found: $RepoRoot" }
$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).ProviderPath.TrimEnd('\', '/')
$SettingsFile = Join-Path (Join-Path $RepoRoot '.KCC') 'settings.json'
$HookSrcDir = Join-Path $PSScriptRoot 'hooks'
$utf8 = New-Object System.Text.UTF8Encoding($false)

$Violations = New-Object System.Collections.ArrayList
$Actions = New-Object System.Collections.ArrayList
function Add-V([string]$Id, [string]$Sev, [string]$Owner, [string]$File, [string]$Msg) {
    [void]$Violations.Add([ordered]@{ id = $Id; severity = $Sev; fix_owner = $Owner; file = $File; message = $Msg })
}
function Add-Action([string]$Text) { [void]$Actions.Add($Text) }

function Invoke-Git([string[]]$ArgList) {
    $old = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $out = @()
    $code = 1
    try { $out = @(& git -C $RepoRoot @ArgList 2>$null); $code = $LASTEXITCODE } catch { $code = 1 } finally { $ErrorActionPreference = $old }
    return @{ Out = $out; Code = $code }
}
function Test-Tool([string]$Name) { return ($null -ne (Get-Command $Name -CommandType Application -ErrorAction SilentlyContinue)) }

# ------------------------------------------------------------------ URL safety
function Get-RedactedUrl([string]$U) {
    if (-not $U) { return $U }
    $q = $null
    $base = $U
    $qi = $U.IndexOf('?')
    if ($qi -ge 0) {
        $base = $U.Substring(0, $qi)
        $q = $U.Substring($qi + 1)
        # A query string carrying anything secret-looking is dropped wholesale.
        if ($q -match '(token|key|secret|password|pass|auth|sig)') { $q = '***' }
    }
    $r = [regex]::Replace($base, '^(https?://)[^/@]+@', '$1***@')
    $r = [regex]::Replace($r, '^([a-zA-Z][a-zA-Z0-9+.-]*://)[^/@:]+:[^/@]*@', '$1***@')
    if ($null -ne $q) { $r = $r + '?' + $q }
    return $r
}
function Test-UrlHasCredentials([string]$U) {
    if ($U -match '^https?://[^/@]+@') { return $true }
    if ($U -match '^[a-zA-Z][a-zA-Z0-9+.-]*://[^/@:]+:[^/@]*@') { return $true }
    if ($U -match '[?&][^=&]*(token|key|secret|password|pass|auth|sig)[^=&]*=') { return $true }
    if ($U -cmatch '(gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|glpat-[A-Za-z0-9_-]{20,}|xox[baprs]-)') { return $true }
    return $false
}
function Test-UrlPlausible([string]$U) {
    if ($U -match '^(https?|ssh|git)://\S+$') { return $true }
    if ($U -match '^[A-Za-z0-9._-]+@[A-Za-z0-9._-]+:\S+$') { return $true }
    if ($U -match '^(/|[A-Za-z]:[/\\]|file://)\S*$') { return $true }
    return $false
}

# ------------------------------------------------------------------ detect
$S = @{}
function Get-SettingsDecision {
    if (-not (Test-Path -LiteralPath $SettingsFile)) { return $null }
    try {
        $j = Get-Content -LiteralPath $SettingsFile -Raw | ConvertFrom-Json
        if ($j.repo -and $j.repo.decision) { return [string]$j.repo.decision }
    } catch { }
    return $null
}
function Invoke-Detect {
    $script:S = @{ git_cli = 'missing'; git = 'absent'; toplevel = $null; commits = 0; branch = $null; remote = 'none'
                   remote_name = $null; remote_raw = $null; auth = 'none'; auth_list = @(); hooks = 'missing'; dirty = 0
                   hooks_dir = $null; decision = (Get-SettingsDecision); hooks_installed = @(); hooks_missing = @() }
    if (-not (Test-Tool 'git')) { return }
    $script:S.git_cli = 'present'
    $r = Invoke-Git @('rev-parse', '--is-inside-work-tree')
    if (($r.Code -eq 0) -and ($r.Out -contains 'true')) {
        $script:S.git = 'repo'
        $t = Invoke-Git @('rev-parse', '--show-toplevel')
        if ($t.Code -eq 0) {
            $top = ([IO.Path]::GetFullPath([string]$t.Out[0])).TrimEnd('\', '/')
            if ($top -ieq $RepoRoot) { $script:S.toplevel = '.' } else { $script:S.toplevel = ($top -replace '\\', '/') }
        }
        if ((Invoke-Git @('rev-parse', '--verify', '-q', 'HEAD')).Code -eq 0) {
            $c = Invoke-Git @('rev-list', '--count', 'HEAD')
            if ($c.Code -eq 0) { $script:S.commits = [int]$c.Out[0] }
        }
        $b = Invoke-Git @('symbolic-ref', '--short', '-q', 'HEAD')
        if (($b.Code -eq 0) -and ($b.Out.Count -gt 0)) { $script:S.branch = [string]$b.Out[0] }
        $rem = @((Invoke-Git @('remote')).Out | Where-Object { $_ })
        $name = $null
        if ($rem -contains 'origin') { $name = 'origin' } elseif ($rem.Count -gt 0) { $name = [string]$rem[0] }
        if ($name) {
            $u = Invoke-Git @('remote', 'get-url', $name)
            if (($u.Code -eq 0) -and ($u.Out.Count -gt 0)) {
                $script:S.remote_name = $name
                $script:S.remote_raw = [string]$u.Out[0]
                $script:S.remote = Get-RedactedUrl ([string]$u.Out[0])
            }
        }
        $script:S.dirty = @((Invoke-Git @('status', '--porcelain')).Out | Where-Object { $_ }).Count
        $hp = Invoke-Git @('rev-parse', '--git-path', 'hooks')
        if (($hp.Code -eq 0) -and ($hp.Out.Count -gt 0)) {
            $h = [string]$hp.Out[0]
            if (-not [IO.Path]::IsPathRooted($h)) { $h = Join-Path $RepoRoot $h }
            $script:S.hooks_dir = [IO.Path]::GetFullPath($h)
            $pc = Join-Path $script:S.hooks_dir 'pre-commit'
            if ((Test-Path -LiteralPath $pc) -and (Select-String -LiteralPath $pc -Pattern $HookMarker -SimpleMatch -Quiet)) { $script:S.hooks = 'kcc-pre-commit' }
        }
        $inst = @(); $miss = @()
        foreach ($hn in $HookNames) {
            $hf = $null
            if ($script:S.hooks_dir) { $hf = Join-Path $script:S.hooks_dir $hn }
            if ($hf -and (Test-Path -LiteralPath $hf) -and (Select-String -LiteralPath $hf -Pattern $HookMarkers[$hn] -SimpleMatch -Quiet)) { $inst += $hn } else { $miss += $hn }
        }
        $script:S.hooks_installed = $inst
        $script:S.hooks_missing = $miss
    }
    # Auth kinds (detected, never read).
    $list = @()
    $ch = Invoke-Git @('config', '--get', 'credential.helper')
    if (($ch.Code -eq 0) -and ((($ch.Out -join '')).Trim())) { $list += 'credential-helper' }
    if (Test-Tool 'gh') {
        $old = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
        try { & gh auth status *> $null; if ($LASTEXITCODE -eq 0) { $list += 'gh' } } catch { } finally { $ErrorActionPreference = $old }
    }
    $agent = $false
    if ($env:SSH_AUTH_SOCK -and (Test-Tool 'ssh-add')) {
        $old = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
        try { & ssh-add -l *> $null; if (($LASTEXITCODE -eq 0) -or ($LASTEXITCODE -eq 1)) { $agent = $true } } catch { } finally { $ErrorActionPreference = $old }
    }
    if ((-not $agent) -and ($env:OS -eq 'Windows_NT')) {
        $svc = Get-Service -Name 'ssh-agent' -ErrorAction SilentlyContinue
        if ($svc -and ($svc.Status -eq 'Running')) { $agent = $true }
    }
    if ($agent) { $list += 'ssh-agent' }
    $script:S.auth_list = $list
    if ($list.Count -gt 0) { $script:S.auth = $list[0] }
}
function Test-GateRequired {
    if ($S.decision) {
        return (($S.decision -ne 'skip') -and ($S.git -eq 'absent'))
    }
    return (($S.git -eq 'absent') -or ($S.commits -eq 0))
}

# ------------------------------------------------------------------ settings writer
function ConvertTo-JsonStr([string]$V) {
    if (-not $V) { return 'null' }
    return '"' + ($V -replace '\\', '\\' -replace '"', '\"') + '"'
}
function Save-Decision([string]$Decision, [string]$Remote) {
    if (-not (Test-Path -LiteralPath $SettingsFile)) {
        Add-V 'RB-SETTINGS' 'warning' 'human' '.KCC/settings.json' ("settings.json not found; decision '" + $Decision + "' not recorded")
        return
    }
    $remShown = 'null'
    if ($Remote) { $remShown = $Remote }
    if ($DryRun) { Add-Action ('would record repo.decision=' + $Decision + ' repo.remote=' + $remShown + ' in .KCC/settings.json'); return }
    $raw = [IO.File]::ReadAllText($SettingsFile)
    $nl = "`n"
    if ($raw.Contains("`r`n")) { $nl = "`r`n" }
    $lines = New-Object System.Collections.ArrayList
    foreach ($l in ($raw -split "`r?`n")) { [void]$lines.Add($l) }
    if (($lines.Count -gt 0) -and ($lines[$lines.Count - 1] -eq '')) { $lines.RemoveAt($lines.Count - 1); $trail = $true } else { $trail = $false }
    $dj = ConvertTo-JsonStr $Decision
    $rj = ConvertTo-JsonStr $Remote
    $rs = -1
    for ($i = 0; $i -lt $lines.Count; $i++) { if ($lines[$i] -match '"repo"\s*:\s*\{') { $rs = $i; break } }
    if ($rs -ge 0) {
        if ($lines[$rs] -match '\}') {
            $ind = [regex]::Match($lines[$rs], '^\s*').Value
            $tail = [regex]::Match($lines[$rs], '\}([^}]*)$').Groups[1].Value
            $boot = '"ask"'
            $bm = [regex]::Match($lines[$rs], '"bootstrap"\s*:\s*("[^"]*")')
            if ($bm.Success) { $boot = $bm.Groups[1].Value }
            $lines[$rs] = $ind + '"repo": { "bootstrap": ' + $boot + ', "decision": ' + $dj + ', "remote": ' + $rj + ' }' + $tail
        } else {
            $re = -1
            for ($i = $rs + 1; $i -lt $lines.Count; $i++) { if ($lines[$i] -match '^\s*\}') { $re = $i; break } }
            $fd = $false; $fr = $false
            for ($i = $rs + 1; $i -lt $re; $i++) {
                $m = [regex]::Match($lines[$i], '"decision"\s*:\s*("[^"]*"|null)')
                if ($m.Success) { $lines[$i] = $lines[$i].Substring(0, $m.Index) + '"decision": ' + $dj + $lines[$i].Substring($m.Index + $m.Length); $fd = $true; continue }
                $m = [regex]::Match($lines[$i], '"remote"\s*:\s*("[^"]*"|null)')
                if ($m.Success) { $lines[$i] = $lines[$i].Substring(0, $m.Index) + '"remote": ' + $rj + $lines[$i].Substring($m.Index + $m.Length); $fr = $true }
            }
            $ins = @()
            if (-not $fd) { $ins += ('    "decision": ' + $dj + ',') }
            if (-not $fr) { $ins += ('    "remote": ' + $rj + ',') }
            if ($ins.Count -gt 0) {
                if ($re -eq ($rs + 1)) { $ins[$ins.Count - 1] = $ins[$ins.Count - 1].TrimEnd(',') }
                $lines.InsertRange($rs + 1, [object[]]$ins)
            }
        }
    } else {
        for ($i = 0; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -match '^\s*\{\s*$') {
                $lines.InsertRange($i + 1, [object[]]@('  "repo": {', '    "bootstrap": "ask",', ('    "decision": ' + $dj + ','), ('    "remote": ' + $rj), '  },'))
                break
            }
        }
    }
    $text = ($lines -join $nl)
    if ($trail) { $text += $nl }
    [IO.File]::WriteAllText($SettingsFile, $text, $utf8)
    Add-Action ('recorded repo.decision=' + $Decision + ' repo.remote=' + $remShown + ' in .KCC/settings.json')
}

# ------------------------------------------------------------------ actions
$GitIgnoreContent = @'
# KCC generated cell outputs and local runtime artifacts.
.claude/
.codex/
.opencode/
.agents/
ollama/

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

function Write-GitIgnore {
    $f = Join-Path $RepoRoot '.gitignore'
    if (Test-Path -LiteralPath $f) { Add-Action 'kept existing .gitignore'; return }
    if ($DryRun) { Add-Action 'would write KCC .gitignore'; return }
    [IO.File]::WriteAllText($f, (($GitIgnoreContent -replace "`r`n", "`n") + "`n"), $utf8)
    Add-Action 'wrote KCC .gitignore'
}

function Install-OneHook([string]$Name) {
    $marker = $HookMarkers[$Name]
    $src = Join-Path $HookSrcDir $Name
    if (-not (Test-Path -LiteralPath $src)) { Add-V 'RB-HOOK-SRC' 'error' 'human' ('.KCC/tools/hooks/' + $Name) ('hook source .KCC/tools/hooks/' + $Name + ' not found'); return $false }
    $dir = $S.hooks_dir
    if (-not $dir) { $dir = Join-Path (Join-Path $RepoRoot '.git') 'hooks' }
    $dst = Join-Path $dir $Name
    if ((Test-Path -LiteralPath $dst) -and (Select-String -LiteralPath $dst -Pattern $marker -SimpleMatch -Quiet)) {
        $same = ([IO.File]::ReadAllText($src) -ceq [IO.File]::ReadAllText($dst))
        if ($same) { Add-Action ('KCC ' + $Name + ' hook already installed'); return $true }
        if ($DryRun) { Add-Action ('would update KCC ' + $Name + ' hook'); return $true }
        [IO.File]::Copy($src, $dst, $true)
        Add-Action ('updated KCC ' + $Name + ' hook')
        return $true
    }
    if (Test-Path -LiteralPath $dst) {
        $local = Join-Path $dir ($Name + '.local')
        if (Test-Path -LiteralPath $local) { Add-V 'RB-HOOK-CONFLICT' 'error' 'human' $dst ('a foreign ' + $Name + ' hook and ' + $Name + '.local both exist; merge them by hand'); return $false }
        if ($DryRun) { Add-Action ('would preserve existing ' + $Name + ' hook as ' + $Name + '.local (chained)') }
        else { Move-Item -LiteralPath $dst -Destination $local; Add-Action ('preserved existing ' + $Name + ' hook as ' + $Name + '.local (chained)') }
    }
    if ($DryRun) { Add-Action ('would install KCC ' + $Name + ' hook'); return $true }
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    [IO.File]::Copy($src, $dst, $true)
    if ($env:OS -ne 'Windows_NT') {
        $old = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
        try { & chmod +x $dst 2>$null } catch { } finally { $ErrorActionPreference = $old }
    }
    if ($Name -eq 'pre-commit') { $script:S.hooks = 'kcc-pre-commit' }
    Add-Action ('installed KCC ' + $Name + ' hook')
    return $true
}

# Installs every KCC hook; $false when any failed.
function Install-Hook {
    if (($S.git -ne 'repo') -and (-not $DryRun)) { Add-V 'RB-HOOK-NOREPO' 'error' 'human' '.' 'not a git repository; run -Apply init-local first'; return $false }
    $ok = $true
    foreach ($hn in $HookNames) { if (-not (Install-OneHook $hn)) { $ok = $false } }
    return $ok
}

function Invoke-InitialCommit {
    if ($S.commits -gt 0) { Add-Action ('repository already has ' + $S.commits + ' commit(s); no bootstrap commit'); return }
    $name = ((Invoke-Git @('config', 'user.name')).Out -join '').Trim()
    $email = ((Invoke-Git @('config', 'user.email')).Out -join '').Trim()
    $idMsg = 'git identity not configured (not set by KCC). Run: git config --global user.name "Your Name"; git config --global user.email you@example.com'
    if ($DryRun) {
        Add-Action "would commit 'chore: KCC workspace bootstrap' (git add -A)"
        if ((-not $name) -or (-not $email)) { Add-V 'RB-IDENTITY' 'warning' 'human' '.' ($idMsg + '; the commit would fail') }
        return
    }
    if ((-not $name) -or (-not $email)) { Add-V 'RB-IDENTITY' 'error' 'human' '.' ($idMsg + '; then re-run'); return }
    [void](Invoke-Git @('add', '-A'))
    # Run the commit with inherited console so the pre-commit hook output is visible.
    $old = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    $rc = 1
    try { & git -C $RepoRoot commit -q -m 'chore: KCC workspace bootstrap' 2>&1 | ForEach-Object { [Console]::Error.WriteLine([string]$_) }; $rc = $LASTEXITCODE } catch { $rc = 1 } finally { $ErrorActionPreference = $old }
    if ($rc -ne 0) { Add-V 'RB-COMMIT' 'error' 'human' '.' ('bootstrap commit failed (exit ' + $rc + '); if the KCC pre-commit hook blocked it, fix the reported findings'); return }
    Add-Action "committed 'chore: KCC workspace bootstrap'"
}

function Invoke-InitLocal([string]$Decision, [string]$Remote) {
    if ($S.git_cli -ne 'present') {
        [Console]::Error.WriteLine('error: git is not installed. Approve it via: powershell -ExecutionPolicy Bypass -File .KCC\tools\toolchain-preflight.ps1 -Tools git')
        exit 2
    }
    if ($S.git -eq 'absent') {
        if ($DryRun) { Add-Action 'would run git init' }
        else {
            [void](Invoke-Git @('init', '-q'))
            # Older git names the first branch 'master', which the git-workflow defaults do not allow.
            $headRef = ''
            try { $headRef = [string](& git -C $RepoRoot symbolic-ref --short HEAD 2>$null) } catch { $headRef = '' }
            if ($headRef.Trim() -eq 'master') { [void](Invoke-Git @('symbolic-ref', 'HEAD', 'refs/heads/main')) }
            Add-Action 'git init'; Invoke-Detect
        }
    } else { Add-Action 'git repository already present' }
    Write-GitIgnore
    [void](Install-Hook)
    # Record before committing so the bootstrap commit carries the decision.
    Save-Decision $Decision $Remote
    Invoke-InitialCommit
}

function Invoke-ConnectRemote {
    if (-not $RemoteUrl) {
        [Console]::Error.WriteLine('error: -RemoteUrl is required for connect-remote (ask the human for the URL; never a token)')
        exit 2
    }
    if (Test-UrlHasCredentials $RemoteUrl) {
        [Console]::Error.WriteLine("error: remote URL rejected: it embeds credentials or a token. Use a plain URL and authenticate with a credential helper, 'gh auth login', or an SSH agent.")
        exit 2
    }
    if (-not (Test-UrlPlausible $RemoteUrl)) { Exit-Usage 'remote URL is not a recognised git URL' }
    $red = Get-RedactedUrl $RemoteUrl
    Invoke-InitLocal 'connect-remote' $red
    if ($S.git -eq 'repo') {
        $cur = Invoke-Git @('remote', 'get-url', 'origin')
        $curUrl = $null
        if (($cur.Code -eq 0) -and ($cur.Out.Count -gt 0)) { $curUrl = [string]$cur.Out[0] }
        if ($curUrl -and ($curUrl -ne $RemoteUrl)) { Add-V 'RB-REMOTE-EXISTS' 'error' 'human' '.' ('origin already points to ' + (Get-RedactedUrl $curUrl) + '; change it by hand (git remote set-url origin <url>) if intended') }
        elseif ($curUrl) { Add-Action ('origin already set to ' + $red) }
        elseif ($DryRun) { Add-Action ('would add remote origin ' + $red) }
        else { [void](Invoke-Git @('remote', 'add', 'origin', $RemoteUrl)); Add-Action ('added remote origin ' + $red) }
    } else { Add-Action ('would add remote origin ' + $red) }
    if ($S.auth -eq 'none') {
        Add-V 'RB-AUTH-NONE' 'warning' 'human' '.' "no git authentication detected. Human runs ONE of: 'gh auth login' | 'git config --global credential.helper manager' (Windows) / 'osxkeychain' (macOS) / 'libsecret' (Linux) | 'ssh-add ~/.ssh/id_ed25519' - then re-run detect"
    }
    $br = 'main'
    if ($S.branch) { $br = $S.branch }
    Add-Action ('push not performed (KCC never pushes; human runs: git push -u origin ' + $br + ')')
}

function Send-Decision([string]$Decision, [string]$Remote) {
    if ((-not $Emit) -or $DryRun) { return }
    $payload = [ordered]@{ decision = $Decision; remote = $null; git = $S.git; commits = $S.commits; hooks = $S.hooks; auth = $S.auth }
    if ($Remote) { $payload.remote = $Remote }
    try {
        & (Join-Path $PSScriptRoot 'backchannel-append.ps1') -Kind 'repo-bootstrap-decision' -From 'repo-bootstrap' -Payload (ConvertTo-Json -InputObject $payload -Compress) -RepoRoot $RepoRoot | Out-Null
    } catch { [Console]::Error.WriteLine('warning: backchannel emit failed: ' + $_.Exception.Message) }
}

# ------------------------------------------------------------------ main
Invoke-Detect
$mode = 'detect'
if ($Apply) {
    $mode = 'apply:' + $Apply
    $pendingRemote = $null
    if (($Apply -eq 'init-local') -and ($S.remote -ne 'none')) { $pendingRemote = $S.remote }
    if ($Apply -eq 'connect-remote') { if ($RemoteUrl) { $pendingRemote = Get-RedactedUrl $RemoteUrl } }
    switch ($Apply) {
        'init-local' { Invoke-InitLocal 'init-local' $pendingRemote }
        'connect-remote' { Invoke-ConnectRemote }
        'skip' {
            Add-Action 'git-dependent features degrade: restore points -> coordination/checkpoints/ file snapshots; wave-scope -> file hashes'
            Save-Decision 'skip' $null
        }
    }
    if (-not $DryRun) { Invoke-Detect }
    Send-Decision $Apply $pendingRemote
} elseif ($InstallHook) {
    $mode = 'install-hook'
    [void](Install-Hook)
    if (-not $DryRun) { Invoke-Detect }
}

if ($S.remote_raw -and (Test-UrlHasCredentials $S.remote_raw)) {
    Add-V 'RB-REMOTE-CRED' 'error' 'human' '.git/config' ("remote '" + $S.remote_name + "' URL embeds credentials (" + $S.remote + '); remove them: git remote set-url ' + $S.remote_name + ' <plain-url>, then use a credential helper / gh / ssh-agent')
}
if (($S.git -eq 'repo') -and (@($S.hooks_missing).Count -gt 0) -and ($mode -eq 'detect')) {
    Add-V 'RB-HOOK-MISSING' 'warning' 'human' '.git/hooks' ('KCC hook(s) not installed: ' + (@($S.hooks_missing) -join ', ') + ' (run: repo-bootstrap -InstallHook)')
}
$gate = Test-GateRequired

$errors = 0; $warnings = 0
foreach ($v in $Violations) { if ($v.severity -eq 'error') { $errors++ } elseif ($v.severity -eq 'warning') { $warnings++ } }
$status = 'pass'; $exitCode = 0
if ($errors -gt 0) { $status = 'fail'; $exitCode = 1 }

if ($Json) {
    $doc = [ordered]@{
        tool = 'repo-bootstrap'; version = $Version; scope = $mode; dry_run = [bool]$DryRun
        git_cli = $S.git_cli; git = $S.git; toplevel = $S.toplevel; commits = $S.commits; branch = $S.branch; remote = $S.remote
        auth = $S.auth; auth_detected = @($S.auth_list); hooks = $S.hooks; hooks_installed = @($S.hooks_installed); dirty = $S.dirty; decision = $S.decision
        gate_required = [bool]$gate; choices = @('init-local', 'connect-remote', 'skip'); actions = @($Actions)
        errors = $errors; warnings = $warnings; status = $status; violations = @($Violations)
    }
    [Console]::Out.WriteLine((ConvertTo-Json -InputObject $doc -Depth 6 -Compress))
} else {
    $br = '-'
    if ($S.branch) { $br = $S.branch }
    Write-Output ('git: ' + $S.git + ' (cli ' + $S.git_cli + ')  commits: ' + $S.commits + '  branch: ' + $br)
    Write-Output ('remote: ' + $S.remote)
    $al = ''
    if ($S.auth_list.Count -gt 0) { $al = ' (detected: ' + ($S.auth_list -join ',') + ')' }
    Write-Output ('auth: ' + $S.auth + $al)
    $dec = 'none'
    if ($S.decision) { $dec = $S.decision }
    $hi = 'none'
    if (@($S.hooks_installed).Count -gt 0) { $hi = (@($S.hooks_installed) -join ',') }
    Write-Output ('hooks: ' + $S.hooks + ' (installed: ' + $hi + ')  dirty: ' + $S.dirty + '  decision: ' + $dec)
    foreach ($a in $Actions) { Write-Output ('action: ' + $a) }
    foreach ($v in $Violations) { Write-Output ($v.severity + ': ' + $v.id + ' ' + $v.message) }
    if ($gate) { Write-Output 'Gate: required -> ask the human once: init-local | connect-remote | skip' }
    Write-Output ('Errors: ' + $errors + '  Warnings: ' + $warnings)
}
exit $exitCode
