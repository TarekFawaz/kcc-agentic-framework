<#
KCC framework (c) 2026 Tarek Fawaz, https://tikasway.dev/kcc. Licensed under the terms in LICENSE.

.SYNOPSIS
    Wait for a usage-limit reset, then resume the KCC run UNATTENDED
    (PowerShell port of kcc-limit-watch.sh; same modes, log, events, exit codes).

.DESCRIPTION
    Modes:
      -Arm   spawn a detached, hidden copy of this script in -Run mode and
             return immediately (no-op when a live watcher holds the lock)
      -Run   foreground loop: wait until -ResetAt (+ continuity.resume_grace_seconds)
             or continuity.default_wait_minutes, run the resume command, repeat
             if the resumed session hits the limit again (max continuity.max_resumes)
      -Wrap  -- <command...>  run a harness command, stream its output, detect
             rate-limit messages ("usage limit", "rate limit", "429",
             "try again in/at ...") and on a hit: kcc-checkpoint limit-hard,
             wait for the parsed reset, resume.
    Resume command = continuity.resume[harness] when a session id is known,
    else continuity.start[harness], with {session_id}, {permission_mode},
    {resume_prompt} (and {command} = wrapped argv[0] for generic) substituted.
    resume_prompt = "Read coordination/checkpoints/latest.md and continue the KCC run from next_action."
    NEVER adds a permission-bypass flag; refuses templates containing one.
    Log: coordination/limit-watch.log. Events: limit-reached, resume-scheduled,
    resume-started. Single instance: coordination/limit-watch.lock.d.
    Exit: 0 finished / armed / dry-run, 1 gave up or resumed run failed, 2 usage error.
    PowerShell 5.1 compatible, ASCII-only source.

.EXAMPLE
    powershell -File .KCC\tools\kcc-limit-watch.ps1 -Run -Harness claude -SessionId abc -ResetAt 1790020000

.EXAMPLE
    powershell -File .KCC\tools\kcc-limit-watch.ps1 -Wrap -Harness codex -- codex exec "continue the KCC run"
#>
# No param() block on purpose: PowerShell parameter binding rejects the wrapped
# command's own tokens ("--", "--flag") under -File, so arguments are parsed
# by hand from the raw $args. Flags are case-insensitive; --kebab-case aliases
# (--arm, --harness, --session-id, ...) are accepted like the bash tool.

$ErrorActionPreference = 'Stop'
$Utf8 = New-Object System.Text.UTF8Encoding($false)

function Fail([string]$msg) { [Console]::Error.WriteLine('error: ' + $msg); exit 2 }

$Arm = $false; $Run = $false; $Wrap = $false; $DryRun = $false
$Harness = 'claude'; $SessionId = ''; $ResetAt = ''; $Command = ''; $RepoRoot = ''
$WaitMinutes = -1; $GraceSeconds = -1; $MaxResumes = -1
$rest = @()
$raw = @($args | ForEach-Object { [string]$_ })
$i = 0
while ($i -lt $raw.Count) {
    $tok = $raw[$i]
    $key = $tok.ToLowerInvariant().TrimStart('-').Replace('-', '')
    if ($tok -eq '--') { if ($i + 1 -lt $raw.Count) { $rest = @($raw[($i + 1)..($raw.Count - 1)]) }; break }
    if (-not $tok.StartsWith('-')) { $rest = @($raw[$i..($raw.Count - 1)]); break }
    $val = $null; if ($i + 1 -lt $raw.Count) { $val = $raw[$i + 1] }
    switch ($key) {
        'arm' { $Arm = $true; $i++; continue }
        'run' { $Run = $true; $i++; continue }
        'wrap' { $Wrap = $true; $i++; continue }
        'dryrun' { $DryRun = $true; $i++; continue }
        'harness' { $Harness = [string]$val; $i += 2; continue }
        'sessionid' { $SessionId = [string]$val; $i += 2; continue }
        'resetat' { $ResetAt = [string]$val; $i += 2; continue }
        'command' { $Command = [string]$val; $i += 2; continue }
        'reporoot' { $RepoRoot = [string]$val; $i += 2; continue }
        'waitminutes' { $WaitMinutes = [int]$val; $i += 2; continue }
        'graceseconds' { $GraceSeconds = [int]$val; $i += 2; continue }
        'maxresumes' { $MaxResumes = [int]$val; $i += 2; continue }
        default { Fail ('unknown argument: ' + $tok) }
    }
}
if (-not $RepoRoot) {
    $toolDir = $PSScriptRoot
    if (-not $toolDir) { $toolDir = Split-Path -Parent $MyInvocation.MyCommand.Path }
    $RepoRoot = Split-Path -Parent (Split-Path -Parent $toolDir)
}
$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
$mode = ''
if ($Arm) { $mode = 'arm' } elseif ($Run) { $mode = 'run' } elseif ($Wrap) { $mode = 'wrap' }
if (-not $mode) { Fail 'one of -Arm, -Run, -Wrap is required' }
if (@('claude', 'codex', 'opencode', 'generic') -notcontains $Harness) { Fail '-Harness must be claude|codex|opencode|generic' }
if (-not (Test-Path -LiteralPath (Join-Path $RepoRoot '.KCC'))) { Fail ('no .KCC workspace at ' + $RepoRoot) }
$wrapArgs = @($rest)
if ($mode -eq 'wrap' -and $wrapArgs.Count -eq 0) { Fail '-Wrap needs -- <command...>' }
if ($mode -ne 'wrap' -and $wrapArgs.Count -gt 0) { Fail ('unexpected arguments: ' + ($wrapArgs -join ' ')) }

$coord = Join-Path $RepoRoot 'coordination'
if (-not (Test-Path -LiteralPath $coord)) { New-Item -ItemType Directory -Path $coord | Out-Null }
$logPath = Join-Path $coord 'limit-watch.log'
$statePath = Join-Path $coord 'limit-watch.state'
$lock = Join-Path $coord 'limit-watch.lock.d'
$resumePrompt = 'Read coordination/checkpoints/latest.md and continue the KCC run from next_action.'
$onWindows = $true
if ($null -ne (Get-Variable -Name IsWindows -ErrorAction SilentlyContinue)) { $onWindows = [bool]$IsWindows }
$psExe = (Get-Process -Id $PID).Path

function NowEpoch { return [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() }
function IsoNow { return [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ') }
function FmtEpoch([int64]$e) { return [DateTimeOffset]::FromUnixTimeSeconds($e).ToLocalTime().ToString('yyyy-MM-dd HH:mm:ss zzz') }
function Write-Log([string]$msg) {
    $line = '{0} [{1}/{2} pid {3}] {4}' -f (IsoNow), $mode, $Harness, $PID, $msg
    [System.IO.File]::AppendAllText($logPath, $line + "`n", $Utf8)
    [Console]::Error.WriteLine($line)
}
function Invoke-Emit([string]$kind, $payload) {
    if ($DryRun) { return }
    $bc = Join-Path $PSScriptRoot 'backchannel-append.ps1'
    if (-not (Test-Path -LiteralPath $bc)) { return }
    try { & $bc -Kind $kind -From kcc-limit-watch -Session $SessionId -Payload ($payload | ConvertTo-Json -Compress) -RepoRoot $RepoRoot -NoDashboard | Out-Null } catch { Write-Log "warning: could not emit $kind" }
}
function Invoke-Checkpoint {
    $cp = Join-Path $PSScriptRoot 'kcc-checkpoint.ps1'
    $a = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $cp, '-Reason', 'limit-hard', '-Harness', $Harness, '-RepoRoot', $RepoRoot)
    if ($SessionId) { $a += @('-SessionId', $SessionId) }
    $old = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try { & $psExe @a *> $null } catch { Write-Log 'warning: kcc-checkpoint failed' } finally { $ErrorActionPreference = $old }
}

# ---- settings -------------------------------------------------------------------
$sGrace = $null; $sWait = $null; $sMax = $null; $perm = 'acceptEdits'; $tplResume = ''; $tplStart = ''
$settingsPath = Join-Path $RepoRoot '.KCC\settings.json'
if (Test-Path -LiteralPath $settingsPath) {
    try {
        $c = (Get-Content -LiteralPath $settingsPath -Raw | ConvertFrom-Json).continuity
        if ($c) {
            $sGrace = $c.resume_grace_seconds; $sWait = $c.default_wait_minutes; $sMax = $c.max_resumes
            if ($c.permission_mode) { $perm = [string]$c.permission_mode }
            if ($c.resume -and $c.resume.$Harness) { $tplResume = [string]$c.resume.$Harness }
            if ($c.start -and $c.start.$Harness) { $tplStart = [string]$c.start.$Harness }
        }
    } catch { }
}
if ($GraceSeconds -lt 0) { if ($null -ne $sGrace) { $GraceSeconds = [int]$sGrace } else { $GraceSeconds = 120 } }
if ($WaitMinutes -lt 0) { if ($null -ne $sWait) { $WaitMinutes = [int]$sWait } else { $WaitMinutes = 300 } }
if ($MaxResumes -lt 0) { if ($null -ne $sMax) { $MaxResumes = [int]$sMax } else { $MaxResumes = 5 } }
$perm = $perm -replace '[^A-Za-z]', ''
if (-not $perm -or $perm -eq 'bypassPermissions') { $perm = 'acceptEdits' }

# ---- helpers --------------------------------------------------------------------
function ConvertTo-Epoch([string]$v) {
    if (-not $v) { return $null }
    if ($v -match '^\d+$') { return [int64]$v }
    $d = [DateTimeOffset]::MinValue
    if ([DateTimeOffset]::TryParse($v, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AssumeUniversal, [ref]$d)) { return $d.ToUnixTimeSeconds() }
    return $null
}

function Get-ResetEpoch([string[]]$lines) {
    $now = NowEpoch
    $tail = @($lines | Select-Object -Last 80)
    for ($i = $tail.Count - 1; $i -ge 0; $i--) {
        $orig = [string]$tail[$i]; $t = $orig.ToLowerInvariant()
        if ($t -match '\|(\d{10})') { return [int64]$Matches[1] }
        if ($t -match '"?resets?_?at"?[: =]+(\d{10})') { return [int64]$Matches[1] }
        if ($t -match 'retry-after:? *(\d+)') { return $now + [int64]$Matches[1] }
        if ($t -match '(again|retry|resets?|available|wait)[a-z ]* in ([0-9][0-9a-z .,]*)') {
            $s = $Matches[2]; $tot = 0.0
            foreach ($m in [regex]::Matches($s, '(\d+(?:\.\d+)?)\s*([a-z]+)')) {
                $num = [double]::Parse($m.Groups[1].Value, [System.Globalization.CultureInfo]::InvariantCulture); $u = $m.Groups[2].Value
                if ($u -match '^(h|hr|hrs|hour|hours)$') { $tot += $num * 3600 }
                elseif ($u -match '^(m|min|mins|minute|minutes)$') { $tot += $num * 60 }
                elseif ($u -match '^(s|sec|secs|second|seconds)$') { $tot += $num }
                elseif ($u -ne 'and') { break }
            }
            if ($tot -gt 0) { return $now + [int64]$tot }
        }
        if ($orig -match '\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}(:\d{2})?(Z|[+-]\d{2}:?\d{2})?') { $e = ConvertTo-Epoch $Matches[0]; if ($null -ne $e) { return $e } }
        $cm = [regex]::Match($t, '(again|resets?|reset|available)[a-z ]* at (\d{1,2})(:(\d{2}))? *(am|pm)?')
        if (-not $cm.Success) { $cm = [regex]::Match($t, '(resets?) ()(\d{1,2})(:(\d{2}))? *(am|pm)') }
        if ($cm.Success) {
            $mm = [regex]::Match($cm.Value, '(\d{1,2})(?::(\d{2}))? *(am|pm)?$')
            $h = [int]$mm.Groups[1].Value; $mi = 0; if ($mm.Groups[2].Success) { $mi = [int]$mm.Groups[2].Value }
            if ($mm.Groups[3].Value -eq 'pm' -and $h -lt 12) { $h += 12 }
            if ($mm.Groups[3].Value -eq 'am' -and $h -eq 12) { $h = 0 }
            $target = [DateTime]::Today.AddHours($h).AddMinutes($mi)
            if ($target -le [DateTime]::Now) { $target = $target.AddDays(1) }
            return ([DateTimeOffset]$target).ToUnixTimeSeconds()
        }
    }
    return $null
}

$limitReBuiltin = 'usage limit|rate limit|rate-limit|ratelimit|limit reached|quota exceeded|exceeded your (current )?quota|too many requests|resource_exhausted|limit exceeded'
# kernel/limit-patterns.json is the shared table (kcc-run, kcc-limit-watch, and the kcc CLI); the built-in is the fallback.
function Get-LimitRe([string]$harness) {
    $f = Join-Path $RepoRoot '.KCC/kernel/limit-patterns.json'
    if (-not (Test-Path -LiteralPath $f)) { return $limitReBuiltin }
    try {
        $j = Get-Content -LiteralPath $f -Raw | ConvertFrom-Json
        $parts = @()
        foreach ($k in @('limit_regex.default', ('limit_regex.' + $harness))) { $p = $j.PSObject.Properties[$k]; if ($p -and $p.Value) { $parts += [string]$p.Value } }
        if ($parts.Count -gt 0) { return ($parts -join '|') }
    } catch { }
    return $limitReBuiltin
}
function Test-LimitHit([string[]]$lines, [int]$rc) {
    $t = (@($lines | Select-Object -Last 60) -join "`n").ToLowerInvariant()
    if ($t -match (Get-LimitRe $Harness)) { return $true }
    if ($rc -ne 0 -and $t -match '(^|[^0-9])429([^0-9]|$)') { return $true }
    return $false
}
function Get-SessionFromOutput([string[]]$lines) {
    $found = ''
    foreach ($l in $lines) { $m = [regex]::Match([string]$l, '(?i)session[ _-]?id["'']?\s*[:=]\s*["'']?([A-Za-z0-9_.:-]{6,})'); if ($m.Success) { $found = $m.Groups[1].Value } }
    return $found
}
function Get-LatestCp {
    $f = Join-Path $coord 'checkpoints\latest.md'
    if (-not (Test-Path -LiteralPath $f)) { return ' ' }
    $id = ''; $r = ''
    foreach ($l in (Get-Content -LiteralPath $f -TotalCount 30)) { if ($l -match '^id:\s*(\S+)') { $id = $Matches[1] }; if ($l -match '^reason:\s*(\S+)') { $r = $Matches[1] } }
    return "$id $r"
}
function Quote-Arg([string]$a) { if ($a -match '[\s"]') { return '"' + ($a -replace '"', '\"') + '"' } return $a }
function Build-Command {
    $sid = ($SessionId -replace '[^A-Za-z0-9._:-]', '')
    $tpl = ''
    if ($Command) { $tpl = $Command }
    elseif ($sid -and $tplResume) { $tpl = $tplResume }
    elseif ($tplStart) { $tpl = $tplStart }
    elseif ($wrapArgs.Count -gt 0) { $tpl = '{command} "{resume_prompt}"' }
    else { return $null }
    $cmd0 = ''; if ($wrapArgs.Count -gt 0) { $cmd0 = Quote-Arg $wrapArgs[0] }
    return $tpl.Replace('{session_id}', $sid).Replace('{permission_mode}', $perm).Replace('{resume_prompt}', $resumePrompt).Replace('{command}', $cmd0)
}
function Test-Bypass([string]$c) {
    $l = $c.ToLowerInvariant()
    return ($l.Contains('dangerously-skip-permissions') -or $l.Contains('bypasspermissions') -or $l.Contains('dangerously-bypass-approvals') -or $l.Contains('--yolo'))
}

# Runs a shell command line, streams merged output to console + log, returns @{rc; lines}.
function Invoke-Streamed([string]$cmdLine, [bool]$toLog) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    if ($onWindows) { $psi.FileName = $env:ComSpec; if (-not $psi.FileName) { $psi.FileName = 'cmd.exe' }; $psi.Arguments = '/d /s /c "' + $cmdLine + ' 2>&1"' }
    else { $psi.FileName = '/bin/sh'; $psi.ArgumentList.Add('-c'); $psi.ArgumentList.Add($cmdLine + ' 2>&1') }
    $psi.WorkingDirectory = $RepoRoot
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $proc = [System.Diagnostics.Process]::Start($psi)
    $lines = New-Object System.Collections.Generic.List[string]
    while ($true) {
        $l = $proc.StandardOutput.ReadLine()
        if ($null -eq $l) { break }
        $lines.Add($l)
        [Console]::Out.WriteLine($l)
        if ($toLog) { [System.IO.File]::AppendAllText($logPath, $l + "`n", $Utf8) }
    }
    $proc.WaitForExit()
    return @{ rc = $proc.ExitCode; lines = $lines.ToArray() }
}

# ---- lock -------------------------------------------------------------------------
function Test-LockLive {
    if (-not (Test-Path -LiteralPath $lock)) { return $false }
    $hb = Join-Path $lock 'heartbeat'
    if (Test-Path -LiteralPath $hb) { return ((Get-Item -LiteralPath $hb).LastWriteTimeUtc -gt [DateTime]::UtcNow.AddMinutes(-10)) }
    return ((Get-Item -LiteralPath $lock).LastWriteTimeUtc -gt [DateTime]::UtcNow.AddMinutes(-2))
}
$script:haveLock = $false
function Get-Lock {
    try { New-Item -ItemType Directory -Path $lock -ErrorAction Stop | Out-Null } catch {
        if (Test-LockLive) { return $false }
        Remove-Item -LiteralPath $lock -Recurse -Force -ErrorAction SilentlyContinue
        try { New-Item -ItemType Directory -Path $lock -ErrorAction Stop | Out-Null } catch { return $false }
    }
    [System.IO.File]::WriteAllText((Join-Path $lock 'owner'), ("pid=$PID`nmode=$mode`nharness=$Harness`nstarted=" + (IsoNow) + "`n"), $Utf8)
    [System.IO.File]::WriteAllText((Join-Path $lock 'heartbeat'), '')
    $script:haveLock = $true
    return $true
}
function Update-Heartbeat { try { (Get-Item -LiteralPath (Join-Path $lock 'heartbeat')).LastWriteTimeUtc = [DateTime]::UtcNow } catch { } }
function Read-Attempts {
    if (-not (Test-Path -LiteralPath $statePath)) { return 0 }
    foreach ($l in Get-Content -LiteralPath $statePath) { if ($l -match '^attempts=(\d+)') { return [int]$Matches[1] } }
    return 0
}
function Write-Attempts([int]$n) {
    if ($DryRun) { return }
    [System.IO.File]::WriteAllText($statePath, ("attempts=$n`nupdated=" + (IsoNow) + "`nharness=$Harness`nsession_id=$SessionId`n"), $Utf8)
}

# ---- arm ------------------------------------------------------------------------------
if ($mode -eq 'arm') {
    if (Test-LockLive) { Write-Log "watcher already running (lock $lock); not arming another"; Write-Output 'already-armed'; exit 0 }
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Quote-Arg $PSCommandPath), '-Run', '-Harness', $Harness, '-RepoRoot', (Quote-Arg $RepoRoot))
    if ($SessionId) { $argList += @('-SessionId', (Quote-Arg $SessionId)) }
    if ($ResetAt) { $argList += @('-ResetAt', (Quote-Arg $ResetAt)) }
    if ($WaitMinutes -ge 0) { $argList += @('-WaitMinutes', $WaitMinutes) }
    if ($GraceSeconds -ge 0) { $argList += @('-GraceSeconds', $GraceSeconds) }
    if ($MaxResumes -ge 0) { $argList += @('-MaxResumes', $MaxResumes) }
    if ($Command) { $argList += @('-Command', (Quote-Arg $Command)) }
    if ($DryRun) { Write-Output ("[dry-run] would spawn: $psExe " + ($argList -join ' ')); exit 0 }
    $sp = @{ FilePath = $psExe; ArgumentList = ($argList -join ' '); PassThru = $true }
    if ($onWindows) { $sp['WindowStyle'] = 'Hidden' }
    $p = Start-Process @sp
    Write-Log "armed detached watcher pid $($p.Id)"
    Write-Output "armed pid $($p.Id)"
    exit 0
}

# ---- wait + resume loop -----------------------------------------------------------------
function Invoke-WaitAndResume($reset) {
    while ($true) {
        $attempts = (Read-Attempts) + 1
        if ($attempts -gt $MaxResumes) {
            Write-Log "giving up: $($attempts - 1) resume attempts already made (max_resumes=$MaxResumes). Resume manually from coordination/checkpoints/latest.md."
            Write-Attempts 0
            return 1
        }
        $now = NowEpoch
        if ($null -ne $reset) { $target = [int64]$reset + $GraceSeconds } else { $target = $now + [int64]$WaitMinutes * 60 }
        if ($target -lt $now) { $target = $now }
        $cmd = Build-Command
        if (-not $cmd) { Write-Log "error: no resume/start template for harness $Harness in .KCC/settings.json continuity (pass -Command)"; return 2 }
        if (Test-Bypass $cmd) { Write-Log "error: refusing to run a command containing a permission-bypass flag: $cmd"; return 2 }
        Write-Attempts $attempts
        $resetText = 'unknown'; if ($null -ne $reset) { $resetText = [string]$reset }
        Write-Log "resume scheduled: attempt $attempts/$MaxResumes at $(FmtEpoch $target) (reset $resetText, grace ${GraceSeconds}s): $cmd"
        Invoke-Emit 'resume-scheduled' ([ordered]@{ harness = $Harness; attempt = $attempts; max_resumes = $MaxResumes; resume_at = $target; reset_at = $reset; command = $cmd })
        if ($DryRun) { [Console]::Out.WriteLine("[dry-run] would wait until $target ($(FmtEpoch $target)) then run: $cmd"); return 0 }
        while ((NowEpoch) -lt $target) {
            Update-Heartbeat
            $left = $target - (NowEpoch); if ($left -gt 30) { $left = 30 }; if ($left -lt 1) { $left = 1 }
            Start-Sleep -Seconds $left
        }
        Update-Heartbeat
        $before = Get-LatestCp
        Write-Log "resume started: $cmd"
        Invoke-Emit 'resume-started' ([ordered]@{ harness = $Harness; attempt = $attempts; command = $cmd })
        $res = Invoke-Streamed $cmd $true
        $after = Get-LatestCp
        Write-Log "resumed command exited rc=$($res.rc)"
        $hit = Test-LimitHit $res.lines $res.rc
        $newHardCp = ($after -ne $before -and $after.EndsWith(' limit-hard'))
        if ($hit -or $newHardCp) {
            $reset = Get-ResetEpoch $res.lines
            $rt = 'unknown'; if ($null -ne $reset) { $rt = [string]$reset }
            Write-Log "resumed session hit the limit again (reset $rt)"
            Invoke-Emit 'limit-reached' ([ordered]@{ level = 'hard'; harness = $Harness; source = 'limit-watch'; resets_at = $reset })
            if (-not $newHardCp) { Invoke-Checkpoint }
            continue
        }
        Write-Attempts 0
        return [int]$res.rc
    }
}

$rcOut = 0
try {
    if ($mode -eq 'run') {
        if (-not $DryRun -and -not (Get-Lock)) { Write-Log "another watcher holds $lock; exiting"; exit 0 }
        $resetEpoch = ConvertTo-Epoch $ResetAt
        if ($ResetAt -and $null -eq $resetEpoch) { Write-Log "warning: could not parse -ResetAt '$ResetAt'; using default_wait_minutes=$WaitMinutes" }
        $sidText = 'none'; if ($SessionId) { $sidText = $SessionId }
        $rsText = 'unknown'; if ($null -ne $resetEpoch) { $rsText = [string]$resetEpoch }
        Write-Log "watching: harness $Harness session $sidText reset $rsText"
        $rcOut = Invoke-WaitAndResume $resetEpoch
    } else {
        $cmdLine = (@($wrapArgs | ForEach-Object { Quote-Arg $_ }) -join ' ')
        Write-Log "wrap: $cmdLine"
        $res = Invoke-Streamed $cmdLine $false
        if (-not (Test-LimitHit $res.lines $res.rc)) { exit $res.rc }
        if (-not $SessionId) { $SessionId = Get-SessionFromOutput $res.lines }
        $resetEpoch = ConvertTo-Epoch $ResetAt
        if ($null -eq $resetEpoch) { $resetEpoch = Get-ResetEpoch $res.lines }
        $sidText = 'unknown'; if ($SessionId) { $sidText = $SessionId }
        $rsText = 'unknown -> default_wait_minutes'; if ($null -ne $resetEpoch) { $rsText = [string]$resetEpoch }
        Write-Log "rate limit detected in $Harness output (rc=$($res.rc), session $sidText, reset $rsText)"
        Invoke-Emit 'limit-reached' ([ordered]@{ level = 'hard'; harness = $Harness; source = 'wrap'; exit_code = $res.rc; resets_at = $resetEpoch })
        if (-not $DryRun) {
            Invoke-Checkpoint
            if (-not (Get-Lock)) { Write-Log "another watcher holds $lock; it will resume the run"; exit 0 }
        }
        Write-Attempts 0
        $rcOut = Invoke-WaitAndResume $resetEpoch
    }
} finally {
    if ($script:haveLock) { Remove-Item -LiteralPath $lock -Recurse -Force -ErrorAction SilentlyContinue }
}
exit $rcOut
