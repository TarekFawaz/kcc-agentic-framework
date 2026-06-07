<#
KCC framework (c) 2026 Tarek Fawaz, https://tikasway.dev/kcc. Licensed under the terms in LICENSE.

.SYNOPSIS
    Generate a self-contained, offline KCC progress + activity dashboard.

.DESCRIPTION
    Reads the framework's progress and telemetry surfaces (ideas, specs,
    stories/enablers, backchannel events, trace sessions, test verdicts, and
    memory index) at generation time, then writes a single self-contained
    HTML file to dashboard/index.html. The HTML embeds all parsed data as a
    JSON blob and renders two tabs entirely with inline CSS + vanilla JS:

      - Progress  : idea -> spec -> story/enabler tree with status badges,
                    counts, and test verdicts.
      - Activity  : chronological backchannel timeline + per-session trace
                    summaries, filterable by spec and event kind.

    There are NO external CDNs or network calls, so the page opens offline in
    any browser and is re-openable without re-running this script.

    PowerShell 5.1 compatible. UTF-8 (no BOM) output. No && operator.

.PARAMETER RepoRoot
    Path to the repo root. Defaults to the parent of .KCC when this script
    lives in {repo}/.KCC/tools/.

.PARAMETER Open
    Launch the generated dashboard in the default browser when set.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .KCC\tools\build-dashboard.ps1

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .KCC\tools\build-dashboard.ps1 -Open
#>

[CmdletBinding()]
param(
    [string]$RepoRoot,
    [switch]$Open
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

# --- small helpers -------------------------------------------------------

# Pull a single value out of YAML frontmatter (first '---' delimited block).
function Get-Frontmatter {
    param([string]$Text, [string]$Key)
    if (-not $Text) { return $null }
    $m = [regex]::Match($Text, "(?ms)^---\s*\r?\n(.*?)\r?\n---\s*")
    if (-not $m.Success) { return $null }
    $block = $m.Groups[1].Value
    $km = [regex]::Match($block, "(?m)^\s*$([regex]::Escape($Key))\s*:\s*(.+?)\s*$")
    if (-not $km.Success) { return $null }
    return ($km.Groups[1].Value.Trim().Trim('"').Trim("'"))
}

# Read a file as raw text, tolerating missing files.
function Read-TextOrNull {
    param([string]$Path)
    if ($Path -and (Test-Path -LiteralPath $Path)) {
        return (Get-Content -LiteralPath $Path -Raw -ErrorAction SilentlyContinue)
    }
    return $null
}

# Derive a human status from a story/enabler/spec body when frontmatter lacks it.
function Get-StatusFromText {
    param([string]$Text)
    if (-not $Text) { return 'Unknown' }
    $fm = Get-Frontmatter -Text $Text -Key 'status'
    if ($fm) { return $fm }
    $m = [regex]::Match($Text, "(?im)^\s*\|?\s*status\s*\|?\s*:?\s*\|?\s*([A-Za-z ]+)")
    if ($m.Success) { return $m.Groups[1].Value.Trim() }
    return 'Unknown'
}

# --- collectors ----------------------------------------------------------

$data = [ordered]@{
    generatedAt = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    repoRoot    = $RepoRoot
    ideas       = @()
    specs       = @()
    events      = @()
    sessions    = @()
    memory      = [ordered]@{ total = 0; byType = @{} }
    notes       = @()
}

# Ideas: one folder per idea under ideation/IDEA-*/
$ideationDir = Join-Path $RepoRoot 'ideation'
if (Test-Path -LiteralPath $ideationDir) {
    foreach ($folder in (Get-ChildItem -LiteralPath $ideationDir -Directory -Filter 'IDEA-*' -ErrorAction SilentlyContinue)) {
        $ideaFile = Get-ChildItem -LiteralPath $folder.FullName -Filter 'idea-*.md' -File -ErrorAction SilentlyContinue | Select-Object -First 1
        $text = if ($ideaFile) { Read-TextOrNull $ideaFile.FullName } else { $null }
        $data.ideas += [ordered]@{
            id     = (Get-Frontmatter -Text $text -Key 'idea_id')
            slug   = (Get-Frontmatter -Text $text -Key 'slug')
            title  = (Get-Frontmatter -Text $text -Key 'title')
            status = (Get-Frontmatter -Text $text -Key 'status')
            folder = $folder.Name
        }
    }
} else {
    $data.notes += 'No ideation/ folder yet - no ideas to show.'
}

# Specs: specs/IDEA-*-Specs/SPEC-*/SPEC-*.md plus their Backlog/ items.
$specsDir = Join-Path $RepoRoot 'specs'
if (Test-Path -LiteralPath $specsDir) {
    foreach ($ideaSpecs in (Get-ChildItem -LiteralPath $specsDir -Directory -Filter 'IDEA-*-Specs' -ErrorAction SilentlyContinue)) {
        foreach ($specFolder in (Get-ChildItem -LiteralPath $ideaSpecs.FullName -Directory -Filter 'SPEC-*' -ErrorAction SilentlyContinue)) {
            $specNote = Get-ChildItem -LiteralPath $specFolder.FullName -Filter 'SPEC-*.md' -File -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -notmatch 'backlog' } | Select-Object -First 1
            $sText = if ($specNote) { Read-TextOrNull $specNote.FullName } else { $null }
            $items = @()
            $backlogDir = Join-Path $specFolder.FullName 'Backlog'
            if (Test-Path -LiteralPath $backlogDir) {
                foreach ($bi in (Get-ChildItem -LiteralPath $backlogDir -Filter '*.md' -File -ErrorAction SilentlyContinue)) {
                    $biText = Read-TextOrNull $bi.FullName
                    $items += [ordered]@{
                        key    = ($bi.BaseName)
                        type   = if ($bi.Name -match '^(?i)Enabler') { 'Enabler' } else { 'Story' }
                        title  = (Get-Frontmatter -Text $biText -Key 'title')
                        status = (Get-StatusFromText -Text $biText)
                    }
                }
            }
            # Test verdicts: TestResults/IDEA-*/SPEC-*/test-run-summary.md
            $verdict = $null
            $specIdShort = ($specFolder.Name -split '-')[0..1] -join '-'   # SPEC-001
            $ideaIdShort = ($ideaSpecs.Name -split '-')[0..1] -join '-'    # IDEA-001
            $trFile = Join-Path (Join-Path (Join-Path $RepoRoot 'TestResults') $ideaIdShort) (Join-Path $specIdShort 'test-run-summary.md')
            $trText = Read-TextOrNull $trFile
            if ($trText) {
                $pass = ([regex]::Matches($trText, '(?i)\bPASS\b')).Count
                $fail = ([regex]::Matches($trText, '(?i)\bFAIL\b')).Count
                $verdict = [ordered]@{ pass = $pass; fail = $fail }
            }
            $data.specs += [ordered]@{
                id       = $specIdShort
                ideaId   = $ideaIdShort
                slug     = $specFolder.Name
                title    = (Get-Frontmatter -Text $sText -Key 'title')
                status   = (Get-StatusFromText -Text $sText)
                items    = $items
                verdict  = $verdict
            }
        }
    }
} else {
    $data.notes += 'No specs/ folder yet - no specs to show.'
}

# Backchannel events.
$bcPath = Join-Path $RepoRoot 'coordination/backchannel.jsonl'
if (Test-Path -LiteralPath $bcPath) {
    foreach ($line in (Get-Content -LiteralPath $bcPath -ErrorAction SilentlyContinue)) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try {
            $ev = $line | ConvertFrom-Json
            $ts = if ($ev.PSObject.Properties.Name -contains 'ts') { $ev.ts } elseif ($ev.PSObject.Properties.Name -contains 'timestamp') { $ev.timestamp } else { '' }
            $data.events += [ordered]@{
                ts      = $ts
                kind    = $ev.kind
                from    = $ev.from
                to      = $ev.to
                spec    = $ev.spec
                payload = (($ev.payload | ConvertTo-Json -Compress -Depth 6) -replace '^"|"$','')
            }
        } catch {
            $data.events += [ordered]@{ ts=''; kind='invalid-json'; from=''; to=''; spec=''; payload=$line }
        }
    }
} else {
    $data.notes += 'No coordination/backchannel.jsonl yet - timeline is empty.'
}

# Trace sessions: Traces/Session-*/ with the seven artifact files.
$tracesDir = Join-Path $RepoRoot 'Traces'
$artifactNames = @('Decisions','Handovers','Actions','ToolsUsed','HumanActions','HumanDecisions','TokenUsage')
if (Test-Path -LiteralPath $tracesDir) {
    foreach ($sess in (Get-ChildItem -LiteralPath $tracesDir -Directory -Filter 'Session-*' -ErrorAction SilentlyContinue)) {
        $artifacts = @()
        foreach ($name in $artifactNames) {
            $f = Join-Path $sess.FullName "$name.md"
            $present = Test-Path -LiteralPath $f
            $lines = 0
            if ($present) { $lines = (Get-Content -LiteralPath $f -ErrorAction SilentlyContinue | Measure-Object -Line).Lines }
            $artifacts += [ordered]@{ name = $name; present = $present; lines = $lines }
        }
        $data.sessions += [ordered]@{ name = $sess.Name; artifacts = $artifacts }
    }
} else {
    $data.notes += 'No Traces/ folder yet - no sessions to show.'
}

# Memory index counts.
$memIdx = Join-Path $RepoRoot 'memory/index.json'
$memText = Read-TextOrNull $memIdx
if ($memText) {
    try {
        $mem = $memText | ConvertFrom-Json
        $entries = if ($mem.PSObject.Properties.Name -contains 'entries') { $mem.entries } else { $mem }
        $data.memory.total = @($entries).Count
        $byType = @{}
        foreach ($e in @($entries)) {
            $t = if ($e.PSObject.Properties.Name -contains 'type') { "$($e.type)" } else { 'unknown' }
            if (-not $byType.ContainsKey($t)) { $byType[$t] = 0 }
            $byType[$t] = $byType[$t] + 1
        }
        $data.memory.byType = $byType
    } catch { $data.notes += 'memory/index.json present but not parseable.' }
}

# --- render HTML ---------------------------------------------------------

# Embed the parsed model as a JSON blob; escape "</" so it cannot break the
# enclosing <script> tag.
$json = ($data | ConvertTo-Json -Depth 12) -replace '</','<\/'

$html = @"
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>KCC Dashboard</title>
<style>
  :root{--bg:#0f1117;--card:#171a23;--mut:#8a92a6;--fg:#e6e9ef;--acc:#4f8cff;--line:#262b38}
  *{box-sizing:border-box}
  body{margin:0;font:14px/1.5 -apple-system,Segoe UI,Roboto,Arial,sans-serif;background:var(--bg);color:var(--fg)}
  header{padding:16px 24px;border-bottom:1px solid var(--line);display:flex;align-items:baseline;gap:16px}
  h1{font-size:18px;margin:0}
  .sub{color:var(--mut);font-size:12px}
  .tabs{display:flex;gap:8px;padding:12px 24px 0}
  .tab{padding:8px 14px;border:1px solid var(--line);border-bottom:none;border-radius:8px 8px 0 0;cursor:pointer;background:var(--card);color:var(--mut)}
  .tab.active{color:var(--fg);border-color:var(--acc)}
  main{padding:20px 24px}
  .view{display:none}.view.active{display:block}
  .card{background:var(--card);border:1px solid var(--line);border-radius:10px;padding:14px 16px;margin:0 0 14px}
  .idea-title{font-weight:600;font-size:15px}
  .spec{margin:10px 0 4px 8px;border-left:2px solid var(--line);padding-left:12px}
  .item{margin:2px 0 2px 20px;color:var(--mut)}
  .badge{display:inline-block;padding:1px 8px;border-radius:10px;font-size:11px;border:1px solid var(--line);margin-left:6px}
  .b-Done{background:#16361f;color:#7ee2a0;border-color:#2c6b41}
  .b-Inprogress,.b-Indelivery{background:#2a2410;color:#e6c873;border-color:#6b5a23}
  .b-Inreview{background:#241a36;color:#c39fff;border-color:#4f3b6b}
  .b-Blocked,.b-Abandoned{background:#361616;color:#ff9b9b;border-color:#6b2c2c}
  .b-Ready,.b-Readyforspec,.b-Handedoff{background:#10262e;color:#7fd6e6;border-color:#23596b}
  .b-Drafting,.b-Unknown{background:#22262f;color:#a7b0c2}
  .pass{color:#7ee2a0}.fail{color:#ff9b9b}
  .controls{display:flex;gap:10px;margin-bottom:12px;flex-wrap:wrap}
  select,input{background:var(--card);color:var(--fg);border:1px solid var(--line);border-radius:6px;padding:6px 8px}
  .ev{border-bottom:1px solid var(--line);padding:8px 0;display:grid;grid-template-columns:160px 150px 1fr;gap:10px}
  .ev .k{color:var(--acc)}.ev .t{color:var(--mut);font-variant-numeric:tabular-nums}
  .pay{color:var(--mut);font-family:Consolas,monospace;font-size:12px;word-break:break-word}
  .sess{margin-bottom:8px}.chip{display:inline-block;font-size:11px;padding:1px 7px;border:1px solid var(--line);border-radius:8px;margin:2px}
  .chip.on{color:#7ee2a0;border-color:#2c6b41}.chip.off{color:var(--mut)}
  .empty{color:var(--mut);font-style:italic}
</style>
</head>
<body>
<header>
  <h1>KCC Dashboard</h1>
  <span class="sub" id="meta"></span>
</header>
<div class="tabs">
  <div class="tab active" data-view="progress">Progress</div>
  <div class="tab" data-view="activity">Activity / Replay</div>
</div>
<main>
  <section id="progress" class="view active"></section>
  <section id="activity" class="view"></section>
</main>
<script id="kcc-data" type="application/json">
$json
</script>
<script>
// Self-contained renderer. No network, no external libs.
var DATA = JSON.parse(document.getElementById('kcc-data').textContent);
function esc(s){return (s==null?'':String(s)).replace(/[&<>"]/g,function(c){return {'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c];});}
function badge(s){var k=(s||'Unknown').replace(/[^A-Za-z]/g,'');return '<span class="badge b-'+esc(k)+'">'+esc(s||'Unknown')+'</span>';}

document.getElementById('meta').textContent='generated '+DATA.generatedAt+' UTC  -  '+DATA.ideas.length+' ideas, '+DATA.specs.length+' specs, '+DATA.events.length+' events, '+DATA.sessions.length+' sessions, '+DATA.memory.total+' memory entries';

// ---- Progress tab ----
function renderProgress(){
  var el=document.getElementById('progress'); var h='';
  if(!DATA.ideas.length && !DATA.specs.length){ el.innerHTML='<p class="empty">No ideas or specs yet.</p>'; return; }
  var specsByIdea={}; DATA.specs.forEach(function(s){ (specsByIdea[s.ideaId]=specsByIdea[s.ideaId]||[]).push(s); });
  DATA.ideas.forEach(function(idea){
    h+='<div class="card"><div class="idea-title">'+esc(idea.id||idea.folder)+' - '+esc(idea.title||idea.slug||'')+badge(idea.status)+'</div>';
    var specs=specsByIdea[idea.id]||[];
    if(!specs.length){ h+='<div class="item empty">no specs yet</div>'; }
    specs.forEach(function(sp){ h+=renderSpec(sp); delete specsByIdea[idea.id]; });
    h+='</div>';
  });
  // Specs whose idea folder was not found still get shown.
  Object.keys(specsByIdea).forEach(function(iid){
    h+='<div class="card"><div class="idea-title">'+esc(iid)+' (idea file not found)</div>';
    specsByIdea[iid].forEach(function(sp){ h+=renderSpec(sp); });
    h+='</div>';
  });
  el.innerHTML=h;
}
function renderSpec(sp){
  var h='<div class="spec"><strong>'+esc(sp.id)+'</strong> '+esc(sp.title||sp.slug||'')+badge(sp.status);
  if(sp.verdict){ h+=' <span class="pass">'+sp.verdict.pass+' PASS</span> / <span class="fail">'+sp.verdict.fail+' FAIL</span>'; }
  if(sp.items && sp.items.length){
    sp.items.forEach(function(it){ h+='<div class="item">'+esc(it.type)+' '+esc(it.key)+badge(it.status)+'</div>'; });
  } else { h+='<div class="item empty">no stories/enablers</div>'; }
  return h+'</div>';
}

// ---- Activity / Replay tab ----
function renderActivity(){
  var el=document.getElementById('activity');
  var specs=[...new Set(DATA.events.map(function(e){return e.spec;}).filter(Boolean))].sort();
  var kinds=[...new Set(DATA.events.map(function(e){return e.kind;}).filter(Boolean))].sort();
  var h='<div class="controls">';
  h+='<select id="fSpec"><option value="">all specs</option>'+specs.map(function(s){return '<option>'+esc(s)+'</option>';}).join('')+'</select>';
  h+='<select id="fKind"><option value="">all kinds</option>'+kinds.map(function(k){return '<option>'+esc(k)+'</option>';}).join('')+'</select>';
  h+='</div><div id="timeline"></div>';
  h+='<div class="card"><strong>Trace sessions</strong>';
  if(!DATA.sessions.length){ h+='<div class="empty">no sessions</div>'; }
  DATA.sessions.forEach(function(s){
    h+='<div class="sess">'+esc(s.name)+'<br>'+s.artifacts.map(function(a){
      return '<span class="chip '+(a.present?'on':'off')+'">'+esc(a.name)+(a.present?(' ('+a.lines+')'):'')+'</span>';}).join('')+'</div>';
  });
  h+='</div>';
  el.innerHTML=h;
  function draw(){
    var fs=document.getElementById('fSpec').value, fk=document.getElementById('fKind').value;
    var rows=DATA.events.filter(function(e){return (!fs||e.spec===fs)&&(!fk||e.kind===fk);});
    var t=document.getElementById('timeline');
    if(!rows.length){ t.innerHTML='<p class="empty">no events match.</p>'; return; }
    t.innerHTML=rows.map(function(e){
      var route=esc(e.from||'?')+(e.to?(' &rarr; '+esc(e.to)):'')+(e.spec?(' ['+esc(e.spec)+']'):'');
      return '<div class="ev"><span class="t">'+esc(e.ts)+'</span><span class="k">'+esc(e.kind)+'</span>'+
             '<span>'+route+'<div class="pay">'+esc(e.payload)+'</div></span></div>';
    }).join('');
  }
  document.getElementById('fSpec').onchange=draw; document.getElementById('fKind').onchange=draw; draw();
}

renderProgress(); renderActivity();
document.querySelectorAll('.tab').forEach(function(t){t.onclick=function(){
  document.querySelectorAll('.tab').forEach(function(x){x.classList.remove('active');});
  document.querySelectorAll('.view').forEach(function(x){x.classList.remove('active');});
  t.classList.add('active'); document.getElementById(t.dataset.view).classList.add('active');
};});
</script>
</body>
</html>
"@

$outDir = Join-Path $RepoRoot 'dashboard'
if (-not (Test-Path -LiteralPath $outDir)) { New-Item -ItemType Directory -Path $outDir | Out-Null }
$outFile = Join-Path $outDir 'index.html'

# UTF-8 without BOM so browsers and editors read it cleanly.
$enc = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($outFile, $html, $enc)

Write-Host "Dashboard written to $outFile"
Write-Host ("  ideas={0} specs={1} events={2} sessions={3} memory={4}" -f $data.ideas.Count, $data.specs.Count, $data.events.Count, $data.sessions.Count, $data.memory.total)
if ($Open) { Start-Process $outFile }
