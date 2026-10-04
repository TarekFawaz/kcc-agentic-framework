#!/usr/bin/env bash
# KCC framework (c) 2026 Tarek Fawaz, https://tikasway.dev/kcc. Licensed under the terms in LICENSE.
#
# kcc-checkpoint.sh - write a KCC restore point (session-continuity protocol).
#
# Builds coordination/checkpoints/CP-{NNN}.md from disk state only (no model
# input): coordination/orchestrator.json (active_session), the backchannel
# (auto policy, last lifecycle event, spec, wave, loop counters, open human
# gates, events since the previous CP) and the file tree. Copies it to
# coordination/checkpoints/latest.md.
#   git repo : lightweight tag kcc/cp-{NNN} on HEAD (never commits/pushes)
#   no git   : CP-{NNN}.manifest + latest.manifest (path<TAB>sha256 for
#              src/, specs/, ideation/, architecture/)
# Emits a `checkpoint-created` backchannel event.
#
# Usage:
#   kcc-checkpoint.sh [--reason limit-soft|limit-hard|spec-reviewed|manual|handover]
#                     [--harness claude|codex|opencode|generic] [--session-id ID]
#                     [--next-action "imperative line"] [--no-git]
#                     [--json] [--dry-run] [--repo-root PATH]
# PowerShell-style flags (-Reason, -Harness, -SessionId, -NextAction, -Json,
# -DryRun, -RepoRoot, -NoGit) are accepted too.
# Exit: 0 written (or dry-run ok), 2 usage/environment error.
set -euo pipefail

TOOL_VERSION="1.0.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
REASON="manual"
HARNESS=""
SESSION_ID=""
NEXT_ACTION=""
JSON=0
DRY=0
NO_GIT=0

usage() {
  echo "usage: kcc-checkpoint.sh [--reason R] [--harness H] [--session-id ID] [--next-action TEXT] [--no-git] [--json] [--dry-run] [--repo-root PATH]" >&2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --reason|-Reason) REASON="${2:-}"; shift 2 ;;
    --harness|-Harness) HARNESS="${2:-}"; shift 2 ;;
    --session-id|-SessionId) SESSION_ID="${2:-}"; shift 2 ;;
    --next-action|-NextAction) NEXT_ACTION="${2:-}"; shift 2 ;;
    --repo-root|-RepoRoot) REPO_ROOT="$(cd "$2" && pwd)"; shift 2 ;;
    --json|-Json) JSON=1; shift ;;
    --dry-run|-DryRun) DRY=1; shift ;;
    --no-git|-NoGit) NO_GIT=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "error: unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done

case "$REASON" in
  limit-soft|limit-hard|spec-reviewed|manual|handover) ;;
  *) echo "error: --reason must be limit-soft|limit-hard|spec-reviewed|manual|handover" >&2; exit 2 ;;
esac
if [[ -z "$HARNESS" ]]; then
  if [[ -n "${KCC_HARNESS:-}" ]]; then HARNESS="$KCC_HARNESS"
  elif [[ -n "${CLAUDECODE:-}" || -n "${CLAUDE_PROJECT_DIR:-}" ]]; then HARNESS="claude"
  else HARNESS="generic"; fi
fi
case "$HARNESS" in
  claude|codex|opencode|generic) ;;
  *) echo "error: --harness must be claude|codex|opencode|generic" >&2; exit 2 ;;
esac
if [[ ! -d "$REPO_ROOT/.KCC" ]]; then
  echo "error: no .KCC workspace at $REPO_ROOT" >&2; exit 2
fi

json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"; s="${s//\"/\\\"}"; s="${s//$'\n'/\\n}"; s="${s//$'\r'/}"; s="${s//$'\t'/ }"
  printf '%s' "$s"
}
jq_str() { if [[ -z "$1" ]]; then printf 'null'; else printf '"%s"' "$(json_escape "$1")"; fi; }
one_line() { local s="${1//$'\n'/ }"; s="${s//$'\r'/}"; printf '%s' "$s"; }

# Minimal JSON parser for awk (J[path]=scalar, JRAW[path]=raw object/array).
KCC_JSON_AWK='
function jparse(str){ delete J; delete JRAW; JS=str; JN=length(JS); JP=1; _jv("") }
function _jws(  c){ while(JP<=JN){ c=substr(JS,JP,1); if(c==" "||c=="\t"||c=="\n"||c=="\r") JP++; else break } }
function _jstr(   o,c,e){ JP++; o=""; while(JP<=JN){ c=substr(JS,JP,1); if(c=="\\"){ e=substr(JS,JP+1,1); if(e=="n"||e=="t") o=o " "; else if(e=="r") o=o ""; else if(e=="u"){ o=o "?"; JP+=4 } else o=o e; JP+=2; continue } if(c=="\""){ JP++; return o } o=o c; JP++ } return o }
function _jv(path,   c,k,idx,st,v){ _jws(); if(JP>JN) return; c=substr(JS,JP,1); st=JP
  if(c=="{"){ JP++; _jws(); if(substr(JS,JP,1)=="}"){ JP++ } else { while(JP<=JN){ _jws(); if(substr(JS,JP,1)!="\""){ JP=JN+1; break } k=_jstr(); _jws(); JP++; _jv((path=="") ? k : (path "." k)); _jws(); c=substr(JS,JP,1); JP++; if(c!=",") break } } JRAW[path]=substr(JS,st,JP-st); return }
  if(c=="["){ JP++; idx=0; _jws(); if(substr(JS,JP,1)=="]"){ JP++ } else { while(JP<=JN){ _jv(path "[" idx "]"); idx++; _jws(); c=substr(JS,JP,1); JP++; if(c!=",") break } } J[path "#"]=idx; JRAW[path]=substr(JS,st,JP-st); return }
  if(c=="\""){ J[path]=_jstr(); return }
  v=""; while(JP<=JN){ c=substr(JS,JP,1); if(index(",}] \t\r\n",c)) break; v=v c; JP++ } if(v=="null") v=""; J[path]=v }
function g(k){ return (k in J) ? J[k] : "" }
function slurp(f,   l,s){ s=""; while((getline l < f)>0) s=s l "\n"; close(f); return s }
'

COORD="$REPO_ROOT/coordination"
CPDIR="$COORD/checkpoints"
BC="$COORD/backchannel.jsonl"
ORCH="$COORD/orchestrator.json"
WARNINGS=()

TZ=UTC0 printf -v CREATED '%(%Y-%m-%dT%H:%M:%SZ)T' -1 2>/dev/null || CREATED=""
[[ "$CREATED" == *T*Z ]] || CREATED="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# --- lock + id allocation -----------------------------------------------------
LOCK="$CPDIR/.lock.d"
release_lock() { rmdir "$LOCK" 2>/dev/null || true; }
if [[ "$DRY" -eq 0 ]]; then
  mkdir -p "$CPDIR"
  tries=0
  until mkdir "$LOCK" 2>/dev/null; do
    tries=$((tries + 1))
    if [[ -n "$(find "$LOCK" -maxdepth 0 -mmin +1 2>/dev/null)" ]]; then rmdir "$LOCK" 2>/dev/null || true; continue; fi
    if [[ $tries -gt 100 ]]; then echo "error: checkpoint lock busy: $LOCK" >&2; exit 2; fi
    sleep 0.1
  done
  trap release_lock EXIT
fi

max=0
if [[ -d "$CPDIR" ]]; then
  for f in "$CPDIR"/CP-*.md; do
    [[ -e "$f" ]] || continue
    b="${f##*/CP-}"; b="${b%.md}"
    [[ "$b" =~ ^[0-9]+$ ]] || continue
    (( 10#$b > max )) && max=$((10#$b))
  done
fi
printf -v CP_ID 'CP-%03d' $((max + 1))
PREV_ID=""
[[ $max -gt 0 ]] && printf -v PREV_ID 'CP-%03d' "$max"
CP_REL="coordination/checkpoints/$CP_ID.md"

# --- previous restore point ---------------------------------------------------
fm_get() { # file key -> frontmatter scalar
  [[ -f "$1" ]] || return 0
  awk -v k="$2" 'NR==1 && $0=="---"{f=1; next} f && $0=="---"{exit} f { i=index($0,":"); if (i>0 && substr($0,1,i-1)==k) { v=substr($0,i+1); sub(/^[ \t]+/,"",v); gsub(/^"|"$/,"",v); print v; exit } }' "$1"
}
PREV_FILE=""
[[ -n "$PREV_ID" && -f "$CPDIR/$PREV_ID.md" ]] && PREV_FILE="$CPDIR/$PREV_ID.md"
PREV_LAST_EVENT="$(fm_get "$PREV_FILE" last_event_id)"
PREV_NEXT="$(fm_get "$PREV_FILE" next_action)"
PREV_NEXT_SRC="$(fm_get "$PREV_FILE" next_action_source)"
PREV_LAST_NUM=0
[[ "$PREV_LAST_EVENT" =~ ^BC-0*([0-9]+)$ ]] && PREV_LAST_NUM="${BASH_REMATCH[1]}"

# --- session id + trace session -----------------------------------------------
if [[ -z "$SESSION_ID" && -n "${KCC_SESSION_ID:-}" ]]; then SESSION_ID="$KCC_SESSION_ID"; fi
if [[ -z "$SESSION_ID" && "$HARNESS" == "claude" && -f "$COORD/usage.json" ]]; then
  SESSION_ID="$(sed -nE 's/.*"session_id"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/p' "$COORD/usage.json" | head -n 1)"
fi
TRACE_SESSION=""
TRACE_SESSION_ID=""
if [[ -f "$ORCH" ]]; then
  TRACE_SESSION="$(grep -oE '"active_session"[[:space:]]*:[[:space:]]*"[^"]*"' "$ORCH" | head -n 1 | sed -E 's/.*:[[:space:]]*"([^"]*)"/\1/' || true)"
  TRACE_SESSION_ID="$(grep -oE '"active_session_id"[[:space:]]*:[[:space:]]*"[^"]*"' "$ORCH" | head -n 1 | sed -E 's/.*:[[:space:]]*"([^"]*)"/\1/' || true)"
else
  WARNINGS+=("CP-W-ORCH: coordination/orchestrator.json not found")
fi
[[ -z "$TRACE_SESSION" ]] && WARNINGS+=("CP-W-TRACE: no active_session pointer in coordination/orchestrator.json")

# --- backchannel analysis -----------------------------------------------------
BC_OUT=""
if [[ -s "$BC" ]]; then
  BC_OUT="$(tail -n 500 "$BC" | awk -v prev="$PREV_LAST_NUM" "$KCC_JSON_AWK"'
BEGIN {
  split("checkpoint-created limit-reached resume-scheduled resume-started handover-issued handover-accepted brief-issued remember-stored calibration-update calibration-drift coordination-note trace-session-created actual-recorded human-gate-triggered human-gate-resolved human-gate-decision", sk, " ")
  for (i in sk) skip[sk[i]] = 1
  ng = 0; nd = 0; na = 0
}
{
  line = $0; sub(/\r$/, "", line); if (line !~ /^[ \t]*\{/) next
  jparse(line)
  id = g("id"); if (id !~ /^BC-[0-9]+$/) next
  n = substr(id, 4) + 0; kind = g("kind"); spec = g("spec")
  if (spec == "") spec = g("payload.spec_id")
  lastid = id
  if (n > prev && !(kind in skip)) newlife++
  if (n > prev) {
    nd++; done[nd] = id "  " kind ((spec != "") ? "  " spec : "")
    ap = g("payload.artifact_path"); if (ap != "" && !(ap in seenart)) { seenart[ap] = 1; na++; art[na] = ap }
    for (i = 0; i < g("payload.artifact_paths#") + 0; i++) { ap = g("payload.artifact_paths[" i "]"); if (ap != "" && !(ap in seenart)) { seenart[ap] = 1; na++; art[na] = ap } }
  }
  if (kind == "auto-policy-parsed") { scenario = g("payload.scenario"); policy = JRAW["payload"]; policy_id = id; delete cnt; wave = ""; state = "" }
  if (kind == "human-gate-triggered") { ng++; gid[ng] = id; ginfo[id] = g("payload.gate") "\037" g("payload.agent") "\037" g("payload.confidence_pct") "\037" g("payload.reason") "\037" g("payload.proposed_next_action") "\037" spec }
  if (kind == "human-gate-resolved" || kind == "human-gate-decision") {
    t = g("payload.trigger_event_id")
    if (t != "") resolved[t] = 1
    else if (kind == "human-gate-resolved" || g("payload.gate") == "confidence") { for (i = ng; i >= 1; i--) if (!(gid[i] in resolved)) { resolved[gid[i]] = 1; break } }
  }
  if (g("payload.wave") != "") wave = g("payload.wave")
  if (g("payload.state") != "") state = g("payload.state")
  cnt[kind]++
  if (!(kind in skip)) {
    lastkind = kind; lastkid = id; lastts = g("ts")
    if (spec != "") lastspec = spec
    if (kind ~ /^test-(completed|verdict)$/) verdict = tolower(g("payload.verdict") g("payload.status") g("payload.result"))
  }
}
END {
  print "last_event_id\t" lastid
  print "last_kind\t" lastkind
  print "last_kind_id\t" lastkid
  print "last_ts\t" lastts
  print "spec\t" lastspec
  print "scenario\t" scenario
  print "policy_id\t" policy_id
  print "policy\t" policy
  print "wave\t" wave
  print "state\t" state
  loops = ""
  split("implement-started implement-completed test-started test-completed review-produced human-gate-decision self-heal-attempt loop-iteration", lk, " ")
  for (i = 1; i in lk; i++) if (cnt[lk[i]] > 0) loops = loops ((loops == "") ? "" : ", ") lk[i] "=" cnt[lk[i]]
  print "loops\t" loops
  st = ""
  if (lastkind ~ /^idea-interrogation/) st = "interrogate"
  else if (lastkind ~ /brief|architecture-pass/) st = "create"
  else if (lastkind ~ /^estimate|^auto-policy/) st = "token-budget"
  else if (lastkind == "spec-created") st = "create"
  else if (lastkind ~ /^plan/) st = "plan"
  else if (lastkind ~ /^implement|^toolchain/) st = "implement"
  else if (lastkind ~ /^test/) st = "test"
  else if (lastkind ~ /^review|^session-closed/) st = "review"
  print "stage\t" st
  open = 0
  for (i = 1; i <= ng; i++) if (!(gid[i] in resolved)) { open++; print "gate\t" gid[i] "\037" ginfo[gid[i]]; firstopen = (firstopen == "") ? gid[i] : firstopen }
  sp = (lastspec != "") ? " for " lastspec : ""
  if (open > 0) { split(ginfo[firstopen], gf, "\037"); na_ = "Resolve open human gate " firstopen " (" ((gf[2] != "") ? gf[2] ": " : "") gf[4] ") via /critical-human-gate, then continue auto" sp }
  else if (lastkind == "") na_ = "No lifecycle events recorded; start or re-run auto from its first state"
  else if (lastkind == "auto-policy-parsed") na_ = "Continue auto at idea interrogation (policy " policy_id " parsed, scenario " scenario ")"
  else if (lastkind == "idea-interrogation-started") na_ = "Finish idea interrogation" sp
  else if (lastkind == "idea-interrogation-completed") na_ = "Run the specialist interrogations and architecture pass" sp
  else if (lastkind ~ /brief/) na_ = "Continue the specialist briefs, then run the architecture pass" sp
  else if (lastkind ~ /^architecture-pass/) na_ = "Run the token-budget estimate, then spec creation" sp
  else if (lastkind == "estimate-issued") na_ = "Resolve the token-budget decision (approve/abort or AutoPolicy)" sp
  else if (lastkind ~ /^estimate-|^auto-policy-approved/) na_ = "Continue auto after the approved token budget" sp
  else if (lastkind == "spec-created") na_ = "Run token-budget and /spec-plan" sp
  else if (lastkind == "plan-created") na_ = "Run toolchain preflight, then /spec-implement wave 1" sp
  else if (lastkind ~ /^toolchain/) na_ = "Continue /spec-implement after the toolchain preflight" sp
  else if (lastkind == "implement-started") na_ = "Finish /spec-implement" ((wave != "") ? " wave " wave : "") sp " (implement-started " lastkid " has no implement-completed)"
  else if (lastkind ~ /^implement-complete/) na_ = "Run the next implementation wave after" ((wave != "") ? " wave " wave : " the last one") sp ", or /spec-test when all waves are done"
  else if (lastkind == "test-started") na_ = "Re-run /spec-test" sp " (test-started " lastkid " has no test-completed)"
  else if (lastkind ~ /^test-(completed|verdict)$/) na_ = (verdict ~ /fail/) ? "Self-heal the failing tests" sp ", then re-run /spec-test" : "Run /spec-review" sp
  else if (lastkind == "review-produced") na_ = "Close the run (butler-remember, session-closed) or continue with the next spec"
  else if (lastkind == "session-closed") na_ = "Run is closed; nothing pending"
  else na_ = "Resume auto after " lastkind " (" lastkid ")" sp
  print "derived_next\t" na_
  for (i = 1; i <= nd; i++) print "done\t" done[i]
  for (i = 1; i <= na; i++) print "artifact\t" art[i]
  print "done_count\t" nd
}' 2>/dev/null || true)"
else
  WARNINGS+=("CP-W-BC: coordination/backchannel.jsonl is missing or empty")
fi

LAST_EVENT_ID=""; LAST_KIND=""; LAST_KIND_ID=""; SPEC=""; SCENARIO=""; POLICY=""; POLICY_ID=""
WAVE=""; STATE=""; LOOPS=""; STAGE=""; DERIVED_NEXT=""; DONE_COUNT=0; NEW_LIFE=0
GATES=""; DONE_LINES=""; ART_LINES=""; OPEN_GATES_COUNT=0; n_done=0; n_art=0
while IFS= read -r bl; do
  key="${bl%%$'\t'*}"; val="${bl#*$'\t'}"
  [[ "$bl" == *$'\t'* ]] || val=""
  case "$key" in
    last_event_id) LAST_EVENT_ID="$val" ;;
    last_kind) LAST_KIND="$val" ;;
    last_kind_id) LAST_KIND_ID="$val" ;;
    spec) SPEC="$val" ;;
    scenario) SCENARIO="$val" ;;
    policy) POLICY="$val" ;;
    policy_id) POLICY_ID="$val" ;;
    wave) WAVE="$val" ;;
    state) STATE="$val" ;;
    loops) LOOPS="$val" ;;
    stage) STAGE="$val" ;;
    derived_next) DERIVED_NEXT="$val" ;;
    done_count) DONE_COUNT="${val:-0}" ;;
    new_lifecycle) NEW_LIFE="${val:-0}" ;;
    gate)
      IFS=$'\037' read -r g_id g_gate g_agent g_conf g_reason g_prop g_spec <<< "$val" || true
      GATES="$GATES- $g_id  gate=${g_gate:-confidence} agent=${g_agent:-?} confidence=${g_conf:-?}  reason: ${g_reason:-?}  proposed: ${g_prop:-?}  spec: ${g_spec:-?}  | allowed answers: approve / revise / escalate / abort"$'\n'
      OPEN_GATES_COUNT=$((OPEN_GATES_COUNT + 1)) ;;
    done) DONE_LINES="$DONE_LINES- $val"$'\n'; n_done=$((n_done + 1)) ;;
    artifact) [[ $n_art -lt 40 ]] && ART_LINES="$ART_LINES- $val"$'\n'; n_art=$((n_art + 1)) ;;
  esac
done <<< "$BC_OUT"
GATES="${GATES%$'\n'}"; ART_LINES="${ART_LINES%$'\n'}"
if [[ $n_done -gt 40 ]]; then
  DONE_LINES="$(printf '%s' "$DONE_LINES" | tail -n 40)"
  DONE_LINES="- ... $((n_done - 40)) earlier events omitted"$'\n'"$DONE_LINES"
fi
DONE_LINES="${DONE_LINES%$'\n'}"

NEXT_SRC="argument"
if [[ -z "$NEXT_ACTION" ]]; then
  if [[ "$NEW_LIFE" == "0" && -n "$PREV_NEXT" ]]; then
    NEXT_ACTION="$PREV_NEXT"; NEXT_SRC="${PREV_NEXT_SRC:-previous}"
  elif [[ -n "$DERIVED_NEXT" ]]; then
    NEXT_ACTION="$DERIVED_NEXT"; NEXT_SRC="derived"
  else
    NEXT_ACTION="Inspect coordination/backchannel.jsonl and resume auto at the last incomplete step"; NEXT_SRC="derived"
  fi
fi
NEXT_ACTION="$(one_line "$NEXT_ACTION")"
RESUME_PROMPT="Read coordination/checkpoints/latest.md and continue the KCC run from next_action."

# --- git or manifest ------------------------------------------------------------
GIT_MODE="manifest"
GIT_HEAD=""
GIT_TAG=""
CHANGES=""
IS_GIT=0
if [[ "$NO_GIT" -eq 0 ]] && command -v git >/dev/null 2>&1 && git -C "$REPO_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  IS_GIT=1
fi
MANIFEST_TMP=""
if [[ "$IS_GIT" -eq 1 ]]; then
  GIT_MODE="git"
  GIT_HEAD="$(git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null || true)"
  GIT_TAG="kcc/cp-${CP_ID#CP-}"
  if [[ -n "$PREV_ID" ]] && git -C "$REPO_ROOT" rev-parse -q --verify "refs/tags/kcc/cp-${PREV_ID#CP-}" >/dev/null 2>&1; then
    CHANGES="$( { git -C "$REPO_ROOT" diff --name-status "kcc/cp-${PREV_ID#CP-}" -- 2>/dev/null | awk -F'\t' '{print $1 "\t" $NF}'; git -C "$REPO_ROOT" ls-files --others --exclude-standard 2>/dev/null | awk '{print "?\t" $0}'; } | awk -F'\t' '$2 !~ /^coordination\//' | head -n 200 || true)"
  else
    CHANGES="$(git -C "$REPO_ROOT" status --porcelain 2>/dev/null | awk '{s=$1; $1=""; sub(/^ /,""); print s "\t" $0}' | awk -F'\t' '$2 !~ /^coordination\//' | head -n 200 || true)"
  fi
  if [[ -z "$GIT_HEAD" ]]; then
    WARNINGS+=("CP-W-GIT: repository has no commits; tag skipped")
    GIT_TAG=""
  fi
else
  MANIFEST_TMP="$(mktemp 2>/dev/null || echo "$COORD/.cp-manifest.$$")"
  HASHER="sha256sum"
  command -v sha256sum >/dev/null 2>&1 || HASHER="shasum -a 256"
  dirs=()
  for d in src specs ideation architecture; do [[ -d "$REPO_ROOT/$d" ]] && dirs+=("$d"); done
  if [[ ${#dirs[@]} -gt 0 ]]; then
    ( cd "$REPO_ROOT" && find "${dirs[@]}" \( -name node_modules -o -name .git -o -name .venv -o -name venv -o -name __pycache__ -o -name bin -o -name obj -o -name dist -o -name .next -o -name target \) -prune -o -type f -print0 2>/dev/null \
      | xargs -0 $HASHER 2>/dev/null \
      | awk '{ h=$1; p=substr($0, length($1)+3); sub(/^\*/, "", p); print p "\t" h }' \
      | LC_ALL=C sort ) > "$MANIFEST_TMP" || true
  else
    : > "$MANIFEST_TMP"
  fi
  PREV_MAN="$CPDIR/latest.manifest"
  if [[ -f "$PREV_MAN" ]]; then
    CHANGES="$(awk -F'\t' 'NR==FNR { old[$1]=$2; next } { if (!($1 in old)) print "A\t" $1; else if (old[$1] != $2) print "M\t" $1; seen[$1]=1 } END { for (p in old) if (!(p in seen)) print "D\t" p }' "$PREV_MAN" "$MANIFEST_TMP" | LC_ALL=C sort -k2 | head -n 200 || true)"
  else
    CHANGES="$(awk -F'\t' '{ print "A\t" $1 }' "$MANIFEST_TMP" | head -n 200 || true)"
  fi
fi
CHANGE_COUNT=0
[[ -n "$CHANGES" ]] && CHANGE_COUNT="$(printf '%s\n' "$CHANGES" | grep -c . || true)"

# --- render ---------------------------------------------------------------------
yq() { local s="${1//\"/\'}"; printf '"%s"' "$s"; }
CHANGE_LINES="$(printf '%s\n' "$CHANGES" | awk -F'\t' 'NF>=2 { n++; if (n <= 60) print "- " $1 " " $2 } END { if (n > 60) print "- ... " (n - 60) " more" }')"

render() {
  cat <<EOF
---
id: $CP_ID
created: $CREATED
reason: $REASON
harness: $HARNESS
session_id: $(yq "$SESSION_ID")
trace_session: $(yq "$TRACE_SESSION")
spec: $(yq "$SPEC")
stage: $(yq "$STAGE")
previous: $(yq "$PREV_ID")
last_event_id: $(yq "$LAST_EVENT_ID")
open_gates: $OPEN_GATES_COUNT
git_mode: $GIT_MODE
git_head: $(yq "$GIT_HEAD")
git_tag: $(yq "$GIT_TAG")
next_action: $(yq "$NEXT_ACTION")
next_action_source: $NEXT_SRC
resume_prompt: $(yq "$RESUME_PROMPT")
tags:
  - kcc/checkpoint
---

# Restore point $CP_ID

## Envelope ID

$CP_ID ($REASON, $CREATED)

## Spec reference

${SPEC:-none recorded in the backchannel}

## From

- harness: $HARNESS
- session_id: ${SESSION_ID:-unknown}
- reason: $REASON

## To

Any KCC harness resuming this run (claude reads CLAUDE.md, codex/opencode/generic read AGENTS.md).

## Lifecycle stage

${STAGE:-unknown} (last lifecycle event: ${LAST_KIND:-none} ${LAST_KIND_ID})

## Input context

- coordination/orchestrator.json (agent profiles, active_session)
- coordination/backchannel.jsonl (events after ${PREV_LAST_EVENT:-the start})
- ${TRACE_SESSION:-Traces/ (no active session pointer)}
- .KCC/settings.json (continuity, auto policy defaults)
EOF
  [[ -n "$PREV_ID" ]] && echo "- coordination/checkpoints/$PREV_ID.md (previous restore point)"
  [[ "$GIT_MODE" == "manifest" ]] && echo "- coordination/checkpoints/$CP_ID.manifest"
  cat <<EOF

## Output / deliverable

### auto

- scenario: ${SCENARIO:-unknown}
- policy_event: ${POLICY_ID:-none}
- policy: \`$POLICY\`
- state: ${STATE:-${LAST_KIND:-unknown}}
- spec: ${SPEC:-none}
- wave: ${WAVE:-none}
- loop_counters: ${LOOPS:-none}

### trace_session

${TRACE_SESSION:-none} ${TRACE_SESSION_ID:+(id $TRACE_SESSION_ID)}

### open_gates

${GATES:-none}

### done_since_last

Events since ${PREV_ID:-the start of the log} ($DONE_COUNT):

${DONE_LINES:-- none}

Artifacts named by those events:

${ART_LINES:-- none}

Files changed since ${PREV_ID:-the first restore point} ($CHANGE_COUNT, A=added M=modified D=deleted ?=untracked):

${CHANGE_LINES:-- none}

### git

- mode: $GIT_MODE
- head: ${GIT_HEAD:-n/a}
- tag: ${GIT_TAG:-n/a}
EOF
  [[ "$GIT_MODE" == "manifest" ]] && echo "- manifest: coordination/checkpoints/$CP_ID.manifest (path<TAB>sha256 of src/, specs/, ideation/, architecture/)"
  cat <<EOF

## Ask

next_action: $NEXT_ACTION

## Constraints / non-goals

- Do not redo work listed under done_since_last; verify it on disk instead.
- Resolve every open gate with the human (or a covering AutoPolicy) before continuing.
- Never use a permission-bypass mode; unattended runs use continuity.permission_mode.
- Read the paths above; this file carries paths, not file contents.

## resume_prompt

$RESUME_PROMPT
EOF
}

[[ -z "$POLICY" ]] && POLICY="{}"
CONTENT="$(render)"

TAG_OK=""
if [[ "$DRY" -eq 0 ]]; then
  mkdir -p "$CPDIR"
  printf '%s\n' "$CONTENT" > "$CPDIR/$CP_ID.md"
  { printf '%s\n' "$CONTENT" | awk -v id="$CP_ID" 'NR==1 {print; print "points_to: " id; next} {print}'; } > "$CPDIR/latest.md.tmp"
  mv -f "$CPDIR/latest.md.tmp" "$CPDIR/latest.md"
  if [[ "$GIT_MODE" == "manifest" ]]; then
    cp -f "$MANIFEST_TMP" "$CPDIR/$CP_ID.manifest"
    cp -f "$MANIFEST_TMP" "$CPDIR/latest.manifest"
  elif [[ -n "$GIT_TAG" ]]; then
    if git -C "$REPO_ROOT" tag "$GIT_TAG" 2>/dev/null; then TAG_OK="yes"; else WARNINGS+=("CP-W-TAG: could not create tag $GIT_TAG"); fi
  fi
  PAYLOAD="{\"cp_id\":\"$CP_ID\",\"reason\":\"$REASON\",\"harness\":\"$HARNESS\",\"path\":\"$CP_REL\",\"git_mode\":\"$GIT_MODE\",\"open_gates\":$OPEN_GATES_COUNT,\"next_action\":\"$(json_escape "$NEXT_ACTION")\"}"
  if [[ -f "$SCRIPT_DIR/backchannel-append.sh" ]]; then
    bash "$SCRIPT_DIR/backchannel-append.sh" --kind checkpoint-created --from kcc-checkpoint --spec "$SPEC" --session "$SESSION_ID" --payload "$PAYLOAD" --repo-root "$REPO_ROOT" --no-dashboard >/dev/null 2>&1 || WARNINGS+=("CP-W-EMIT: backchannel-append failed")
  fi
fi
[[ -n "$MANIFEST_TMP" ]] && rm -f "$MANIFEST_TMP" 2>/dev/null || true

if [[ "$JSON" -eq 1 ]]; then
  V=""
  for w in "${WARNINGS[@]+"${WARNINGS[@]}"}"; do
    wid="${w%%:*}"; wmsg="${w#*: }"
    V="$V${V:+,}{\"id\":\"$wid\",\"severity\":\"warning\",\"fix_owner\":\"human\",\"file\":null,\"message\":\"$(json_escape "$wmsg")\"}"
  done
  printf '{"tool":"kcc-checkpoint","version":"%s","scope":"all","errors":0,"warnings":%d,"status":"pass","dry_run":%s,"violations":[%s],"checkpoint":{"id":"%s","path":"%s","latest":"coordination/checkpoints/latest.md","reason":"%s","harness":"%s","session_id":%s,"trace_session":%s,"spec":%s,"stage":%s,"open_gates":%d,"done_since_last":%d,"files_changed":%d,"git_mode":"%s","git_tag":%s,"next_action":%s,"resume_prompt":%s}}\n' \
    "$TOOL_VERSION" "${#WARNINGS[@]}" "$( [[ $DRY -eq 1 ]] && echo true || echo false )" "$V" "$CP_ID" "$CP_REL" "$REASON" "$HARNESS" \
    "$(jq_str "$SESSION_ID")" "$(jq_str "$TRACE_SESSION")" "$(jq_str "$SPEC")" "$(jq_str "$STAGE")" "$OPEN_GATES_COUNT" "$DONE_COUNT" "$CHANGE_COUNT" "$GIT_MODE" "$(jq_str "$GIT_TAG")" "$(jq_str "$NEXT_ACTION")" "$(jq_str "$RESUME_PROMPT")"
else
  if [[ "$DRY" -eq 1 ]]; then
    echo "[dry-run] would write $CP_REL (reason $REASON, harness $HARNESS, git_mode $GIT_MODE)"
  else
    echo "$CP_ID written: $CP_REL (reason $REASON, harness $HARNESS, git_mode $GIT_MODE${GIT_TAG:+, tag $GIT_TAG})"
  fi
  echo "next_action: $NEXT_ACTION"
  for w in "${WARNINGS[@]+"${WARNINGS[@]}"}"; do echo "warning: $w"; done
  echo "Errors: 0  Warnings: ${#WARNINGS[@]}"
fi
exit 0
