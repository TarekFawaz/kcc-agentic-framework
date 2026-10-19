#!/usr/bin/env bash
# KCC framework (c) 2026 Tarek Fawaz, https://tikasway.dev/kcc. Licensed under the terms in LICENSE.
#
# kcc-run.sh - deterministic, harness-neutral driver for the KCC `auto` lifecycle
# (bash port of kcc-run.ps1; same run.json, gates, logs, events, exit codes).
#
# Executes .KCC/kernel/auto-states.json (source of truth) one state at a time:
# each state's command runs through the configured harness NON-interactively
# (settings.json continuity.start[harness]); NEXT / PAUSE / STOP is decided by
# the state's exit-check script, never by the agent's own word.
# Protocol: .KCC/kernel/protocols/kcc-run.md
#
# Usage:
#   kcc-run.sh --input "<idea|path|IDEA-ID|SPEC-ID|all>" [--silent --assume]
#              [--accuracy NN] [--budget NN --currency USD] [--parallel]
#              [--fasttrack] [--depthlevel 1-5] [--open-dashboard | --no-open-dashboard]
#              [--harness claude|codex|opencode|generic] [--resume]
#              [--answer <choice>] [--from <stateId>] [--only <stateId>] [--until <stateId>]
#              [--dry-run] [--json] [--max-attempts N] [--repo-root PATH]
#              [--remote-url URL] [--note "text"]
#
# --until <id> stops after that state has finished for every spec and wave (status stopped,
# reason "until <id>"; --resume continues). Used to hand the per-spec states to `kcc lanes`.
# Exit: 0 done / dry-run / --only / --until finished, 2 usage or environment error,
#       4 paused at a human gate, 5 suspended (usage limit), 6 stopped/aborted,
#       7 finished or stopped with items that need a human (only under --silent --assume, which never
#         pauses: every gate is answered by policy; the open items are in coordination/NeedsAttention.md).
# Requires bash 3.2+, awk, sed, grep. No python/jq.
set -euo pipefail

VERSION="1.0.0"
IN_TEXT=""; SILENT=0; ASSUME=0; ACC=""; BUDGET=""; CURRENCY=""; PARALLEL=0; FASTTRACK=0; OPEN_DASH=0; NO_OPEN_DASH=0; DEPTH=""; HARNESS_ARG=""
RESUME=0; ANSWER=""; FROM=""; ONLY=""; UNTIL=""; DRY=0; JSON=0; MAXATT=0; REPO_ROOT=""; REMOTE_URL=""; NOTE=""

usage() { sed -n '14,25p' "$0" | sed 's/^# \{0,1\}//'; }
fail_usage() { echo "kcc-run: $1" >&2; exit 2; }
while [[ $# -gt 0 ]]; do
  case "$1" in
    --input|-Input) IN_TEXT="${2:-}"; shift 2 ;;
    --silent|--slient|-Silent) SILENT=1; shift ;;
    --assume|-Assume) ASSUME=1; shift ;;
    --accuracy|--acuuracy|-Accuracy) ACC="${2:-}"; shift 2 ;;
    --budget|-Budget) BUDGET="${2:-}"; shift 2 ;;
    --currency|-Currency) CURRENCY="${2:-}"; shift 2 ;;
    --parallel|--parralel|-Parallel) PARALLEL=1; shift ;;
    --fasttrack|--fasttarck|-Fasttrack) FASTTRACK=1; shift ;;
    --open-dashboard|-OpenDashboard) OPEN_DASH=1; shift ;;
    --no-open-dashboard|-NoOpenDashboard) NO_OPEN_DASH=1; shift ;;
    --depthlevel|-DepthLevel) DEPTH="${2:-}"; shift 2 ;;
    --harness|-Harness) HARNESS_ARG="${2:-}"; shift 2 ;;
    --resume|-Resume) RESUME=1; shift ;;
    --answer|-Answer) ANSWER="${2:-}"; shift 2 ;;
    --from|-From) FROM="${2:-}"; shift 2 ;;
    --only|-Only) ONLY="${2:-}"; shift 2 ;;
    --until|-Until) UNTIL="${2:-}"; shift 2 ;;
    --dry-run|-DryRun) DRY=1; shift ;;
    --json|-Json) JSON=1; shift ;;
    --max-attempts|-MaxAttempts) MAXATT="${2:-}"; shift 2 ;;
    --repo-root|-RepoRoot) REPO_ROOT="${2:-}"; shift 2 ;;
    --remote-url|-RemoteUrl) REMOTE_URL="${2:-}"; shift 2 ;;
    --note|-Note) NOTE="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "kcc-run: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

if [[ "$SILENT" != "$ASSUME" ]]; then fail_usage "--silent and --assume must be used together"; fi
ACC="${ACC%\%}"
if [[ -n "$ACC" && ! "$ACC" =~ ^[0-9]{1,3}$ ]]; then fail_usage "--accuracy must be a percentage (e.g. 95)"; fi
if [[ -n "$BUDGET" && ! "$BUDGET" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then fail_usage "--budget must be a number"; fi
case "$HARNESS_ARG" in ""|claude|codex|opencode|generic) ;; *) fail_usage "--harness must be claude|codex|opencode|generic" ;; esac
if [[ -n "$DEPTH" && ! "$DEPTH" =~ ^[1-5]$ ]]; then fail_usage "--depthlevel must be 1-5"; fi
if [[ -n "$FROM" && ! "$FROM" =~ ^[0-9]+$ ]]; then fail_usage "--from must be a state id"; fi
if [[ -n "$ONLY" && ! "$ONLY" =~ ^[0-9]+$ ]]; then fail_usage "--only must be a state id"; fi
if [[ -n "$UNTIL" && ! "$UNTIL" =~ ^[0-9]+$ ]]; then fail_usage "--until must be a state id"; fi
if [[ ! "$MAXATT" =~ ^[0-9]+$ ]]; then fail_usage "--max-attempts must be >= 1"; fi

# Spawn budget: under Git Bash on Windows every fork and every exec costs 0.3-0.4 s, so this driver keeps string and path work in bash
# (parameter expansion, [[ =~ ]], printf -v) and hands helper results back in variables where a call sits on the per-state path.
# abs_dir DIR -> ABS: what `cd DIR && pwd` prints; no fork for an absolute path without dot segments (a missing folder still fails in cd).
abs_dir() {
  [[ -d "$1" ]] || cd "$1"
  case "$1" in
    /*) case "$1/" in */./*|*/../*|*//*) ABS="$(cd "$1" && pwd)" ;; *) ABS="${1%/}"; [[ -n "$ABS" ]] || ABS=/ ;; esac ;;
    *) ABS="$(cd "$1" && pwd)" ;;
  esac
}
case "$0" in */*) SELF_DIR="${0%/*}"; SELF_BASE="${0##*/}" ;; *) SELF_DIR="."; SELF_BASE="$0" ;; esac
abs_dir "$SELF_DIR"; SELF_DIR="$ABS"
SELF="$SELF_DIR/$SELF_BASE"
if [[ -z "$REPO_ROOT" ]]; then abs_dir "$SELF_DIR/../.."; REPO_ROOT="$ABS"; fi
[[ -d "$REPO_ROOT" ]] || fail_usage "workspace not found: $REPO_ROOT"
abs_dir "$REPO_ROOT"; ROOT="$ABS"
TOOLS="$ROOT/.KCC/tools"
STATES_JSON="$ROOT/.KCC/kernel/auto-states.json"
[[ -f "$STATES_JSON" ]] || fail_usage "state table not found: $STATES_JSON"
COORD="$ROOT/coordination"; RUN_DIR="$COORD/run"; RUN_FILE="$RUN_DIR/run.json"; LOG_DIR="$RUN_DIR/logs"; GATE_DIR="$COORD/gates"
# --fasttrack has its own lifecycle table (a running app first, no ROI/CONFIRM/ARCH-GATE/BUDGET/WINDOWS states);
# a resumed fast-track run keeps it.
FT_TABLE=$FASTTRACK
if [[ $FT_TABLE -eq 0 && -f "$RUN_FILE" ]]; then
  re_ft='"fasttrack"[[:blank:]]*:[[:blank:]]*"1"'; ft_txt="$(<"$RUN_FILE")"
  if [[ "$ft_txt" =~ $re_ft ]]; then FT_TABLE=1; fi
fi
if [[ $FT_TABLE -eq 1 && -f "$ROOT/.KCC/kernel/auto-states-fasttrack.json" ]]; then STATES_JSON="$ROOT/.KCC/kernel/auto-states-fasttrack.json"; fi

say() { if [[ "$JSON" -eq 1 ]]; then printf '%s\n' "$*" >&2; else printf '%s\n' "$*"; fi; }
# isov -> ISO (the UTC time as 2026-01-02T03:04:05Z) with the printf builtin where bash has it (4.2+), date otherwise; iso prints it.
if printf '%(%s)T' -1 >/dev/null 2>&1; then isov() { TZ=UTC printf -v ISO '%(%Y-%m-%dT%H:%M:%SZ)T' -1; }
else isov() { ISO="$(date -u +%Y-%m-%dT%H:%M:%SZ)"; }; fi
if printf '%(%s)T' -1 >/dev/null 2>&1; then epoch_v() { printf -v EPV '%(%s)T' -1; }
else epoch_v() { EPV="$(date +%s)"; }; fi
iso() { isov; printf '%s' "$ISO"; }
# jescv VALUE -> JE (the JSON-escaped text, no quotes); jesc prints it. Neither forks unless it is called inside $( ).
jescv() { local s="$1"; s="${s//\\/\\\\}"; s="${s//\"/\\\"}"; s="${s//$'\t'/\\t}"; s="${s//$'\r'/}"; JE="${s//$'\n'/\\n}"; }
jesc() { jescv "$1"; printf '%s' "$JE"; }
squote() { local s="$1"; printf "'%s'" "${s//\'/\'\\\'\'}"; }
rel_v() { local p="$1"; RV="${p#"$ROOT"/}"; }
rel() { rel_v "$1"; printf '%s' "$RV"; }
safe_name_v() { RV="${1//[^A-Za-z0-9_.-]/_}"; }
safe_name() { safe_name_v "$1"; printf '%s' "$RV"; }

# ---- JSON (no jq): flatten to "path<TAB>value" lines; arrays also get "path.#<TAB>count" ----
JSON_FLAT_AWK='
function hexv(h,  v,q){ h=tolower(h); v=0; for(q=1;q<=length(h);q++){ v=v*16+index("0123456789abcdef",substr(h,q,1))-1 }; return v }
function path(  p,x){ p=""; for(x=1;x<=d;x++){ p=p (x>1?".":"") k[x] }; return p }
function emit(v){ print path() "\t" v }
function adv(){ if(d>0 && t[d]=="a"){ k[d]=cnt[d]; cnt[d]++ } }
{ s = s $0 "\n" }
END{
  n=length(s); i=1; d=0
  while(i<=n){
    c=substr(s,i,1)
    if(c=="{"){ adv(); d++; t[d]="o"; k[d]=""; ek[d]=1; i++; continue }
    if(c=="["){ adv(); d++; t[d]="a"; k[d]=0; cnt[d]=0; i++; continue }
    if(c=="}"||c=="]"){ if(t[d]=="a"){ k[d]="#"; emit(cnt[d]) }; d--; i++; continue }
    if(c==","){ if(t[d]=="o") ek[d]=1; i++; continue }
    if(c==":"){ ek[d]=0; i++; continue }
    if(c=="\""){
      j=i+1; out=""
      while(j<=n){
        ch=substr(s,j,1)
        if(ch=="\\"){ nx=substr(s,j+1,1)
          if(nx=="n"||nx=="t"||nx=="r"){ out=out " "; j+=2 }
          else if(nx=="u"){ cv=hexv(substr(s,j+2,4)); if(cv>=32 && cv<127){ out=out sprintf("%c",cv) } else { out=out "?" }; j+=6 }
          else { out=out nx; j+=2 }
          continue }
        if(ch=="\"") break
        out=out ch; j++
      }
      i=j+1
      if(d>0 && t[d]=="o" && ek[d]){ k[d]=out } else { adv(); emit(out) }
      continue
    }
    if(c ~ /[ \t\r\n]/){ i++; continue }
    lit=""; while(i<=n){ ch=substr(s,i,1); if(ch ~ /[,}\] \t\r\n]/) break; lit=lit ch; i++ }
    adv(); emit(lit)
  }
}'
json_flat() { awk "$JSON_FLAT_AWK" "$@"; }
# fget_v FLAT KEY -> FGV: the value of the first "KEY<TAB>value" line of a flattened document ("" when absent). A bash pattern match
# on the text instead of the `awk '$1==k{print $2; exit}'` this used to be (a fork and an exec for every lookup).
fget_v() {
  local t=$'\n'"$1" k=$'\n'"$2"$'\t'
  if [[ "$t" == *"$k"* ]]; then t="${t#*"$k"}"; t="${t%%$'\n'*}"; FGV="${t%%$'\t'*}"; else FGV=""; fi
}
flat_get() { fget_v "$1" "$2"; printf '%s\n' "$FGV"; }

# ---- state table ------------------------------------------------------------------------
STATES_FLAT="$(json_flat "$STATES_JSON")" || fail_usage "cannot parse $STATES_JSON"
eval "$(awk -F'\t' '
function q(v){ gsub(/\047/, "\047\\\047\047", v); return "\047" v "\047" }
function app(a,i,v,sep){ a[i] = (i in a) ? a[i] sep v : v }
$1 ~ /^states\.[0-9]+\./ {
  split($1, p, "."); i=p[2]; if(i+0>mx) mx=i+0; seen[i]=1
  r=$1; sub(/^states\.[0-9]+\./, "", r); v=$2
  if(r ~ /\.#$/) next
  if(r=="id") ID[i]=v; else if(r=="name") NM[i]=v; else if(r=="scope") SC[i]=v; else if(r=="command") CM[i]=v
  else if(r=="check.tool") CT[i]=v; else if(r ~ /^check\.args\./) app(CA,i,v,"\037"); else if(r=="check.path") CP[i]=v
  else if(r ~ /^check\.paths\./) app(CPS,i,v,"\037"); else if(r=="check.any") CANY[i]=v
  else if(r=="check.pass_when") PW[i]=v; else if(r=="check.min_pct") MN[i]=v; else if(r=="check.expect") EX[i]=v
  else if(r=="agent_fasttrack") AGF[i]=v; else if(r=="check.then.tool") TT[i]=v; else if(r=="check.then.then.tool") TU[i]=v; else if(r ~ /^check\.then\.args\./) app(TA,i,v,"\037")
  else if(r ~ /^gate\./){ g=r; sub(/^gate\./,"",g); if(g=="S1") G1[i]=v; else if(g=="S2") G2[i]=v; else if(g=="S3") G3[i]=v; else if(g=="all") GA[i]=v }
  else if(r ~ /^interactive_in\./) app(IN,i,v," "); else if(r ~ /^only_in\./) app(ON,i,v," ")
  else if(r=="skip_if_flag" || r ~ /^skip_if_flag\./) app(SK,i,v," "); else if(r=="command_fasttrack") CF[i]=v; else if(r=="precheck_requires") PR[i]=v; else if(r=="event") EV[i]=v; else if(r=="on_fail_goto") GO[i]=v; else if(r=="checkpoint") CK[i]=v
  next }
$1 ~ /^gates\.[^.]+\.[0-9]+$/ { g=$1; sub(/^gates\./,"",g); sub(/\.[0-9]+$/,"",g); if(!(g in GI)){ GI[g]=ng; GN[ng]=g; ng++ }; app(GV,GI[g],$2,"/"); next }
BEGIN { ng=0; mx=-1 }
$1=="max_attempts" { print "SM_MAX=" q($2) }
END{
  print "S_COUNT=" (mx+1); print "G_COUNT=" ng+0
  for(i=0;i<=mx;i++){
    printf "S_ID[%d]=%s; S_NAME[%d]=%s; S_SCOPE[%d]=%s; S_CMD[%d]=%s; S_CT[%d]=%s; S_CA[%d]=%s; S_CP[%d]=%s; S_PW[%d]=%s; S_MIN[%d]=%s; S_EXP[%d]=%s; S_CPS[%d]=%s; S_CANY[%d]=%s\n", i,q(ID[i]),i,q(NM[i]),i,q(SC[i]),i,q(CM[i]),i,q(CT[i]),i,q(CA[i]),i,q(CP[i]),i,q(PW[i]),i,q(MN[i]),i,q(EX[i]),i,q(CPS[i]),i,q(CANY[i])
    printf "S_TT[%d]=%s; S_TA[%d]=%s; S_G1[%d]=%s; S_G2[%d]=%s; S_G3[%d]=%s; S_GA[%d]=%s; S_INT[%d]=%s; S_ONLY[%d]=%s; S_SKIP[%d]=%s; S_EV[%d]=%s; S_GOTO[%d]=%s; S_CK[%d]=%s; S_CF[%d]=%s; S_PR[%d]=%s; S_TU[%d]=%s; S_AGF[%d]=%s\n", i,q(TT[i]),i,q(TA[i]),i,q(G1[i]),i,q(G2[i]),i,q(G3[i]),i,q(GA[i]),i,q(IN[i]),i,q(ON[i]),i,q(SK[i]),i,q(EV[i]),i,q(GO[i]),i,q(CK[i]),i,q(CF[i]),i,q(PR[i]),i,q(TU[i]),i,q(AGF[i])
  }
  for(j=0;j<ng;j++) printf "GATE_N[%d]=%s; GATE_A[%d]=%s\n", j, q(GN[j]), j, q(GV[j])
}' <<< "$STATES_FLAT")"
SM_MAX="${SM_MAX:-3}"
SPEC_FIRST=-1; SPEC_LAST=-1
for ((i = 0; i < S_COUNT; i++)); do
  if [[ "${S_SCOPE[$i]}" != "run" ]]; then
    if [[ $SPEC_FIRST -lt 0 ]]; then SPEC_FIRST=$i; fi
    SPEC_LAST=$i
  fi
done
# The small lookups below come in two forms: NAME_v sets RV (use it where a call sits on the per-state path: a $(...) is a fork, ~0.3 s
# under Git Bash on Windows) and NAME prints it, for the callers that need a pipeline or a $(...) anyway.
get_idx_v() { local i; for ((i = 0; i < S_COUNT; i++)); do if [[ "${S_ID[$i]}" == "$1" ]]; then RV="$i"; return 0; fi; done; RV=-1; }
get_idx() { get_idx_v "$1"; printf '%s\n' "$RV"; }
is_approval_gate() { case "$1" in confirm|budget|budget-cap|windows) return 0 ;; esac; return 1; }

SETTINGS_FLAT=""
if [[ -f "$ROOT/.KCC/settings.json" ]]; then SETTINGS_FLAT="$(json_flat "$ROOT/.KCC/settings.json" 2>/dev/null || true)"; fi
setting_v() { fget_v "$SETTINGS_FLAT" "$1"; if [[ -z "$FGV" || "$FGV" == "null" ]]; then FGV="$2"; fi; }
setting() { setting_v "$1" "$2"; printf '%s' "$FGV"; }
HARNESSES_FLAT=""; REGISTRY_FLAT=""
if [[ -f "$ROOT/.KCC/kernel/harnesses.json" ]]; then HARNESSES_FLAT="$(json_flat "$ROOT/.KCC/kernel/harnesses.json" 2>/dev/null || true)"; fi
if [[ -f "$ROOT/.KCC/kernel/models.json" ]]; then REGISTRY_FLAT="$(json_flat "$ROOT/.KCC/kernel/models.json" 2>/dev/null || true)"; fi
CFG_MAX="$(setting run.max_attempts "$SM_MAX")"; [[ "$CFG_MAX" =~ ^[0-9]+$ && "$CFG_MAX" -ge 1 ]] || CFG_MAX=3
if [[ "$MAXATT" -gt 0 ]]; then CFG_MAX="$MAXATT"; fi
CFG_TIMEOUT="$(setting run.state_timeout_minutes 60)"; [[ "$CFG_TIMEOUT" =~ ^[0-9]+$ && "$CFG_TIMEOUT" -ge 1 ]] || CFG_TIMEOUT=60

# ---- run.json -------------------------------------------------------------------------------
RUN_KEYS="schema status reason created updated harness input input_class scenario silent assume accuracy budget currency parallel fasttrack depthlevel dashboard_opened sequential idea ideas_before specs state spec_index wave attempts force pending_action gate_id gate_name gate_kind gate_answers gate_state gate_spec gate_wave gate_event last_log last_violations note until"
new_run() {
  local k; for k in $RUN_KEYS; do eval "R_$k=''"; done
  isov; R_schema="kcc-run/1"; R_status="running"; R_created="$ISO"; R_scenario="S1"; R_silent=0; R_assume=0
  R_accuracy=95; R_currency="USD"; R_parallel=0; R_fasttrack=0; R_depthlevel=5; R_sequential=0; R_state=0; R_spec_index=0
}
load_run() {
  new_run
  local flat; flat="$(json_flat "$RUN_FILE")" || fail_usage "cannot parse $RUN_FILE"
  eval "$(awk -F'\t' -v keys=" $RUN_KEYS " 'function q(v){ gsub(/\047/, "\047\\\047\047", v); return "\047" v "\047" } index(keys, " " $1 " ") > 0 { print "R_" $1 "=" q($2) }' <<< "$flat")"
}
save_run() {
  if [[ "$DRY" -eq 1 ]]; then return 0; fi
  isov; R_updated="$ISO"
  [[ -d "$RUN_DIR" ]] || mkdir -p "$RUN_DIR"
  local k v first=1 tmp="$RUN_FILE.tmp" out="{"$'\n'
  for k in $RUN_KEYS; do
    eval "v=\"\${R_$k}\""
    if [[ $first -eq 0 ]]; then out+=$',\n'; fi
    first=0
    jescv "$v"; out+="  \"$k\": \"$JE\""
  done
  out+=$'\n}\n'
  printf '%s' "$out" > "$tmp"
  mv -f "$tmp" "$RUN_FILE"
}
get_att_v() { local p; local IFS=';'; for p in $R_attempts; do if [[ "${p%%=*}" == "$1" ]]; then RV="${p#*=}"; return 0; fi; done; RV=0; }
get_att() { get_att_v "$1"; printf '%s\n' "$RV"; }
set_att() {
  local p out="" IFS=';'
  for p in $R_attempts; do if [[ -n "$p" && "${p%%=*}" != "$1" ]]; then out="${out:+$out;}$p"; fi; done
  if [[ "$2" -gt 0 ]]; then out="${out:+$out;}$1=$2"; fi
  R_attempts="$out"
}
test_force() { case " $R_force " in *" $1 "*) return 0 ;; esac; return 1; }
add_force() { if ! test_force "$1"; then R_force="${R_force:+$R_force }$1"; fi; }
clear_force() { local x out=""; for x in $R_force; do if [[ "$x" != "$1" ]]; then out="${out:+$out }$x"; fi; done; R_force="$out"; }

# ---- workspace discovery ------------------------------------------------------------------------
idea_folders() { if [[ -d "$ROOT/ideation" ]]; then (cd "$ROOT/ideation" && ls -d IDEA-[0-9]* 2>/dev/null | sed 's#/$##' | LC_ALL=C sort) || true; fi; }
idea_num() { printf '%s' "$1" | sed -n 's/^IDEA-0*\([0-9][0-9]*\).*/\1/p'; }
spec_id_v() { if [[ "$1" =~ ^(SPEC-[0-9]+) ]]; then RV="${BASH_REMATCH[1]}"; elif [[ "$1" =~ ^(SPEC-[0-9A-Za-z]+) ]]; then RV="${BASH_REMATCH[1]}"; else RV="$1"; fi; }
spec_id() { spec_id_v "$1"; printf '%s' "$RV"; }
spec_dir_v() { RV="$ROOT/specs/${1%%/*}-Specs/${1#*/}"; }
spec_dir() { spec_dir_v "$1"; printf '%s' "$RV"; }
specs_from_roadmap() { # $1 = IDEA folder -> "IDEA/SPEC-folder" lines in ROADMAP Order
  local idea="$1" sdir="$ROOT/specs/$1-Specs" folders line sid f out=""
  [[ -d "$sdir" ]] || return 0
  folders="$( (cd "$sdir" && ls -d SPEC-* 2>/dev/null | sed 's#/$##' | LC_ALL=C sort) || true)"
  if [[ -f "$sdir/ROADMAP.md" ]]; then
    while IFS=$'\t' read -r _ord _n sid; do
      [[ -n "$sid" ]] || continue
      f="$(printf '%s\n' "$folders" | awk -v s="$sid" '$0==s || index($0, s "-")==1 {print; exit}')"
      if [[ -n "$f" ]]; then case " $out " in *" $f "*) ;; *) out="${out:+$out }$f" ;; esac; fi
    done < <(awk '
      /^[ \t]*\|/ {
        line=$0; if (line ~ /^[ \t]*\|[ \t:|-]+\|?[ \t]*$/) next
        sub(/^[ \t]*\|/, "", line); sub(/\|[ \t]*$/, "", line); nc=split(line, c, "|")
        if (oc < 0 || oc == "") { oc=-1; for (x=1; x<=nc; x++) { v=c[x]; gsub(/^[ \t]+|[ \t]+$/, "", v); if (tolower(v)=="order") oc=x }; if (oc > 0) next }
        if (!match(line, /SPEC-[0-9A-Za-z]+/)) next
        id=substr(line, RSTART, RLENGTH); if (match(id, /^SPEC-[0-9]+/)) id=substr(id, RSTART, RLENGTH)
        ord=1000+n; if (oc > 0) { v=c[oc]; if (match(v, /[0-9]+/)) ord=substr(v, RSTART, RLENGTH)+0 }
        printf "%d\t%d\t%s\n", ord, n, id; n++ }' "$sdir/ROADMAP.md" | sort -t "$(printf '\t')" -k1,1n -k2,2n)
  fi
  if [[ -z "$out" ]]; then out="$(printf '%s\n' "$folders" | tr '\n' ' ' | sed 's/ *$//')"; fi
  for f in $out; do printf '%s/%s\n' "$idea" "$f"; done
}
spec_status() {
  local d; d="$(spec_dir "$1")"
  awk '/^[ \t]*\|/ { line=$0; if (line ~ /^[ \t]*\|[ \t:|-]+\|?[ \t]*$/) next; sub(/^[ \t]*\|/, "", line); sub(/\|[ \t]*$/, "", line); nc=split(line, c, "|")
       if (!h) { for (x=1; x<=nc; x++) { v=c[x]; gsub(/^[ \t]+|[ \t]+$/, "", v); if (tolower(v)=="status") col=x }; h=1; next }
       if (col) { v=c[col]; gsub(/^[ \t]+|[ \t]+$/, "", v); print v }; exit }' "$d/${1#*/}.md" 2>/dev/null || true
}
get_waves() { # $1 = entry -> wave numbers, one per line
  local d; spec_dir_v "$1"; d="$RV"
  local w=""
  if [[ -f "$d/plan.md" ]]; then w="$(awk 'BEGIN{IGNORECASE=1} /^##[ \t]/ { if (ins) exit; if (tolower($0) ~ /^##[ \t]+waves?([^a-z]|$)/) ins=1; next } ins' "$d/plan.md")"; fi
  if [[ -z "$w" && -f "$d/parallelization.md" ]]; then
    w="$(awk '/^##[ \t]/ { if (ins) exit; if (tolower($0) ~ /waves?/) ins=1; next } ins' "$d/parallelization.md")"
    if [[ -z "$w" ]]; then w="$(cat "$d/parallelization.md")"; fi
  fi
  printf '%s\n' "$w" | awk '/^[ \t]*\|/ { line=$0; sub(/^[ \t]*\|/, "", line); split(line, c, "|"); v=tolower(c[1]); gsub(/^[ \t]+|[ \t]+$/, "", v); sub(/^wave[ \t]*/, "", v); if (v ~ /^[0-9]+$/ && !(v+0 in s)) { s[v+0]=1; print v+0 } }'
}
spec_entries() { printf '%s' "$R_specs"; }
spec_count_v() { local n=0 e; for e in $R_specs; do n=$((n + 1)); done; RV="$n"; }
spec_count() { spec_count_v; printf '%s\n' "$RV"; }
spec_entry_at_v() { local n=0 e; for e in $R_specs; do if [[ $n -eq $1 ]]; then RV="$e"; return 0; fi; n=$((n + 1)); done; RV=""; }
spec_entry_at() { spec_entry_at_v "$1"; printf '%s\n' "$RV"; }
derived_tools() {
  local e="$1" txt="" f out="" x
  for f in "$(spec_dir "$e")/${e#*/}.md" "$(spec_dir "$e")/plan.md" "$ROOT/ideation/${e%%/*}/TechnicalDecisionBrief.md"; do
    if [[ -f "$f" ]]; then txt="$txt$(cat "$f")"$'\n'; fi
  done
  txt="$(printf '%s' "$txt" | tr 'A-Z' 'a-z')"
  addt() { for x in $(printf '%s' "$1" | tr ',' ' '); do case ",$out," in *",$x,"*) ;; *) out="${out:+$out,}$x" ;; esac; done; }
  if printf '%s' "$txt" | grep -Eq 'fullstack-nextjs|frontend-react|backend-nodejs'; then addt node,npm; fi
  if printf '%s' "$txt" | grep -Eq 'fullstack-python|backend-python'; then addt python; fi
  if printf '%s' "$txt" | grep -q 'backend-go'; then addt go; fi
  if printf '%s' "$txt" | grep -q 'backend-rust'; then addt cargo; fi
  if printf '%s' "$txt" | grep -q 'backend-java'; then addt java; fi
  if printf '%s' "$txt" | grep -Eq 'backend-dotnet|fullstack-dotnet'; then addt dotnet; fi
  if printf '%s' "$txt" | grep -q 'flutter'; then addt dart,flutter; fi
  if printf '%s' "$txt" | grep -q 'mobile-kotlin'; then addt java; fi
  if printf '%s' "$txt" | grep -Eq 'docker|compose\.ya?ml|containerfile'; then addt docker; fi
  if printf '%s' "$txt" | grep -q 'mobile-swift'; then addt swift; fi
  if printf '%s' "$txt" | grep -q 'backend-ruby'; then addt ruby; fi
  if printf '%s' "$txt" | grep -q 'scripting-lua'; then addt lua; fi
  if printf '%s' "$txt" | grep -q 'devops-cloud'; then addt terraform; fi
  if printf '%s' "$txt" | grep -q 'devops-k8s-onprem-agnostic'; then addt terraform,kubectl,helm; fi
  if printf '%s' "$txt" | grep -Eq '(^|[^a-z])pnpm([^a-z]|$)'; then addt pnpm; fi
  addt git
  # plan.md '## Toolchain' rows '| node | >=20 |' pin a major version: the preflight checks node@>=20.
  local pf tool cons spec
  pf="$(spec_dir "$e")/plan.md"
  if [[ -f "$pf" ]]; then
    while IFS=$'\t' read -r tool cons; do
      [[ -n "$tool" ]] || continue
      spec="$tool@$cons"
      # Only tools the stack already needs get a version ('| typescript | ^5.5 |' is a package, not a command).
      case ",$out," in
        *",$tool,"*) out="$(printf ',%s,' "$out" | sed "s|,$tool,|,$spec,|; s|^,||; s|,\$||")" ;;
      esac
    done < <(awk '/^##[ \t]/{ins = tolower($0) ~ /^##[ \t]+toolchain/; next} ins && /^\|/ {
        n = split($0, c, "|"); t = c[2]; v = c[3]; gsub(/[ \t`]/, "", t); gsub(/[ \t`]/, "", v)
        t = tolower(t); if (t !~ /^[a-z][a-z0-9._-]*$/) next
        if (match(v, /^(>=|<=|>|<|=)?[0-9]+((>=|<=|>|<)[0-9]+)?/)) print t "\t" substr(v, RSTART, RLENGTH) }' "$pf" | tr -d '\r')
  fi
  printf '%s' "$out"
}

# ---- context + rendering -------------------------------------------------------------------------
C_IDEA=""; C_SPEC=""; C_ENTRY=""; C_WAVE=""
new_ctx() { C_ENTRY="$1"; C_WAVE="$2"; C_IDEA="$R_idea"; C_SPEC=""; if [[ -n "$1" ]]; then C_IDEA="${1%%/*}"; spec_id_v "${1#*/}"; C_SPEC="$RV"; fi; }
render() { render_v "$1"; printf '%s' "$RV"; }
render_v() {
  local t="$1" sa="" par="" ft="" dl="" tools=""
  if [[ "$R_scenario" != "S1" ]]; then sa="--silent --assume"; fi
  if [[ "$R_parallel" == "1" ]]; then par="--parallel"; fi
  if [[ "$R_fasttrack" == "1" ]]; then ft="--fasttrack"; fi
  if [[ "$R_depthlevel" =~ ^[1-4]$ ]]; then dl="--depthlevel $R_depthlevel"; fi
  if [[ "$t" == *"{TOOLS}"* ]]; then if [[ -n "$C_ENTRY" ]]; then tools="$(derived_tools "$C_ENTRY")"; else tools=git; fi; fi
  t="${t//\{input\}/"$R_input"}"; t="${t//\{IDEA\}/"$C_IDEA"}"; t="${t//\{SPEC\}/"$C_SPEC"}"; t="${t//\{WAVE\}/"$C_WAVE"}"; t="${t//\{ITEM\}/}"
  t="${t//\{silent_assume\}/"$sa"}"; t="${t//\{parallel\}/"$par"}"; t="${t//\{fasttrack\}/"$ft"}"; t="${t//\{depthlevel\}/"$dl"}"; t="${t//\{flags\}/"$sa $par $ft $dl"}"; t="${t//\{TOOLS\}/"$tools"}"
  while [[ "$t" == *"  "* ]]; do t="${t//  / }"; done
  t="${t# }"; RV="${t% }"
}
precheck_ready() { # $1 = idx; a state with precheck_requires counts as done only when that artifact exists
  [[ -n "${S_PR[$1]}" ]] || return 0
  render_v "${S_PR[$1]}"
  [[ -e "$ROOT/$RV" ]]
}
state_cmd_v() { # $1 = idx -> RV: command text (fasttrack variant when set)
  if [[ "$R_fasttrack" == "1" && -n "${S_CF[$1]}" ]]; then RV="${S_CF[$1]}"; else RV="${S_CMD[$1]}"; fi
}
state_cmd() { state_cmd_v "$1"; printf '%s' "$RV"; }
skip_flag_v() { # $1 = idx -> RV: the flag that skips this state, or empty
  local f; RV=""
  for f in ${S_SKIP[$1]}; do
    if [[ "$f" == "parallel" && "$R_parallel" == "1" ]]; then RV="--parallel"; return 0; fi
    if [[ "$f" == "fasttrack" && "$R_fasttrack" == "1" ]]; then RV="--fasttrack"; return 0; fi
  done
  return 0
}
skip_flag() { skip_flag_v "$1"; if [[ -n "$RV" ]]; then printf '%s\n' "$RV"; fi; }
gate_name_v() { # $1 = idx -> RV
  local n=""
  case "$R_scenario" in S1) n="${S_G1[$1]}" ;; S2) n="${S_G2[$1]}" ;; S3) n="${S_G3[$1]}" ;; esac
  if [[ -z "$n" ]]; then n="${S_GA[$1]}"; fi
  if [[ "$n" == "none" ]]; then n=""; fi
  RV="$n"
}
gate_name() { gate_name_v "$1"; printf '%s' "$RV"; }
gate_answers() {
  local j
  if [[ "$1" == "interactive" ]]; then echo "done/abort"; return 0; fi
  for ((j = 0; j < G_COUNT; j++)); do if [[ "${GATE_N[$j]}" == "$1" ]]; then echo "${GATE_A[$j]}"; return 0; fi; done
  echo "proceed/abort"
}
unit_label_v() { local s="state ${S_ID[$1]} ${S_NAME[$1]}"; if [[ -n "$C_SPEC" ]]; then s="$s $C_SPEC"; fi; if [[ -n "$C_WAVE" ]]; then s="$s wave $C_WAVE"; fi; RV="$s"; }
unit_label() { unit_label_v "$1"; printf '%s' "$RV"; }
unit_key_v() { local k="${S_ID[$1]}"; if [[ -n "$C_SPEC" ]]; then k="$k:$C_SPEC"; fi; if [[ -n "$C_WAVE" ]]; then k="$k:$C_WAVE"; fi; RV="$k"; }
unit_key() { unit_key_v "$1"; printf '%s' "$RV"; }
in_list() { case " $2 " in *" $1 "*) return 0 ;; esac; return 1; }

# ---- tools ------------------------------------------------------------------------------------------
# ps2kebab_v -RepoRoot -> KB (--repo-root): a hyphen goes between a lower-case letter or digit and the capital after it
ps2kebab_v() {
  local s="${1#-}" out="" prev="" c i up=ABCDEFGHIJKLMNOPQRSTUVWXYZ lo=abcdefghijklmnopqrstuvwxyz0123456789
  for ((i = 0; i < ${#s}; i++)); do
    c="${s:i:1}"
    if [[ "$up" == *"$c"* && -n "$prev" && "$lo" == *"$prev"* ]]; then out+="-"; fi
    out+="$c"; prev="$c"
  done
  lc_v "$out"; KB="--$LCV"
}
ps2kebab() { ps2kebab_v "$1"; printf '%s' "$KB"; }
if [[ "${BASH_VERSINFO[0]}" -ge 4 ]]; then eval 'lc_v() { LCV="${1,,}"; }'
else lc_v() { LCV="$(printf '%s' "$1" | tr 'A-Z' 'a-z')"; }; fi
TOOL_RC=0
run_tool() { # $1 tool, $2 outfile ("" = none), rest = PowerShell-style args
  local tool="$1" out="$2"; shift 2
  local a=() x
  if [[ "$tool" == "toolchain-preflight" ]]; then
    while [[ $# -gt 0 ]]; do
      if [[ "$1" == "-Tools" ]]; then for x in ${2//,/ }; do a+=("$x"); done; shift 2; else shift; fi
    done
  else
    while [[ $# -gt 0 ]]; do if [[ "$1" == -[A-Z]* ]]; then ps2kebab_v "$1"; a+=("$KB"); else a+=("$1"); fi; shift; done
    a+=(--repo-root "$ROOT")
  fi
  if [[ ! -f "$TOOLS/$tool.sh" ]]; then TOOL_RC=2; if [[ -n "$out" ]]; then echo "tool not found: $tool" > "$out"; fi; return 0; fi
  if [[ -z "$out" ]]; then out=/dev/null; fi
  TOOL_RC=0
  # no subshell for the cd: a fork costs ~0.3 s on Git Bash for Windows
  local was="$PWD"; cd "$ROOT"
  bash "$TOOLS/$tool.sh" "${a[@]+"${a[@]}"}" > "$out" 2>/dev/null < /dev/null || TOOL_RC=$?
  cd "$was" 2>/dev/null || true
}
# The backchannel appender is sourced once: emit then appends in-process (the same line format, ids and dashboard rule as running
# backchannel-append.sh, which costs about a dozen forks and execs per event under Git Bash on Windows).
if [[ -f "$TOOLS/backchannel-append.sh" ]]; then source "$TOOLS/backchannel-append.sh"; fi
EMIT_ID=""
emit() { # $1 kind, $2 spec, $3 payload json, $4 = "dash" to refresh the dashboard
  EMIT_ID=""
  if [[ "$DRY" -eq 1 || ! -f "$TOOLS/backchannel-append.sh" ]]; then return 0; fi
  local nodash=1; if [[ "${4:-}" == "dash" ]]; then nodash=0; fi
  BC_LINE=""
  bc_append "$1" kcc-run broadcast "$2" "" "$3" "$ROOT" "$nodash" 2>/dev/null < /dev/null || true
  local re_id='^.*"id":"(BC-[0-9]*)"'
  if [[ "$BC_LINE" =~ $re_id ]]; then EMIT_ID="${BASH_REMATCH[1]}"; fi
}
pass_when() { # $1 expr, $2 flat json -> 0 when any clause matches
  local expr="$1" flat="$2" clause cond k op v actual ok re_cond='^([A-Za-z_]*) *([=<>]) *(.*)$' re_int='^-?(0|[1-9][0-9]*)$'
  local IFS='|'
  for clause in $expr; do
    ok=1
    local IFS='&'
    for cond in $clause; do
      cond="${cond#"${cond%%[! ]*}"}"; cond="${cond%"${cond##*[! ]}"}"
      k=""; op=""; v=""
      if [[ "$cond" =~ $re_cond ]]; then k="${BASH_REMATCH[1]}"; op="${BASH_REMATCH[2]}"; v="${BASH_REMATCH[3]}"; fi
      if [[ -z "$k" ]]; then ok=0; break; fi
      fget_v "$flat" "$k"; actual="$FGV"
      if [[ "$actual" == "null" ]]; then actual=""; fi
      if [[ "$op" == "=" ]]; then if [[ "$actual" != "$v" ]]; then ok=0; break; fi
      elif [[ "$actual" =~ $re_int && "$v" =~ $re_int ]]; then
        # whole numbers compare in bash; anything else (decimals, junk) takes the awk comparison below
        if [[ "$op" == ">" ]]; then if ! (( actual > v )); then ok=0; break; fi; else if ! (( actual < v )); then ok=0; break; fi; fi
      else
        if ! awk -v a="$actual" -v b="$v" -v o="$op" 'BEGIN { if (a !~ /^-?[0-9.]+$/) exit 1; if (o == ">") exit !(a + 0 > b + 0); exit !(a + 0 < b + 0) }'; then ok=0; break; fi
      fi
    done
    IFS='|'
    if [[ $ok -eq 1 ]]; then return 0; fi
  done
  return 1
}
format_violations() { # flat json -> "ID (owner): message; ..." (errors only)
  awk -F'\t' '$1 ~ /^violations\.[0-9]+\./ { split($1, p, "."); i=p[2]; f=p[3]; if (i+0 > mx) mx=i+0; seen[i]=1; V[i, f]=$2 }
    END { out=""; for (i=0; i<=mx; i++) { if (!(i in seen)) continue; if (V[i, "severity"]=="warning") continue
      s=V[i, "id"] " (" V[i, "fix_owner"] "): " V[i, "message"]; out = out (out=="" ? "" : "; ") s }; print out }' <<< "$1"
}
# ---- Bug items: status, the ruling a blocked one waits for, scoped re-verification ------------------------------
bug_field_of() { # bug file, column name (lower case) -> that cell of the bug table row, lower case
  tr -d '\r' < "$1" | awk -F'|' -v want="$2" '/^\| *Type *\|/ { for (i = 1; i <= NF; i++) { c = tolower($i); gsub(/^ +| +$/, "", c); if (c == want) col = i } getline; getline; if (col) { v = tolower($col); gsub(/^ +| +$/, "", v); print v } exit }'
}
bug_status_of() { bug_field_of "$1" status; } # open|fixing|fixed|verified|blocked|wontfix
bug_key_of() { basename "$1" .md | sed -E 's/^(Bug-[0-9]+).*/\1/'; }
set_bug_status() { # bug file, new status: rewrites the Status cell of the bug table row, nothing else
  local f="$1" new="$2" tmp="$1.tmp"
  awk -v new="$new" '
    { cr = ($0 ~ /\r$/); line = $0; if (cr) sub(/\r$/, "", line) }
    hdr == 0 && line ~ /^\|[ \t]*Type[ \t]*\|/ { n = split(line, c, "|"); for (i = 1; i <= n; i++) { v = tolower(c[i]); gsub(/^[ \t]+|[ \t]+$/, "", v); if (v == "status") col = i } hdr = NR; print $0; next }
    hdr > 0 && NR == hdr + 2 && col > 0 && !done { n = split(line, c, "|"); c[col] = " " new " "; o = c[1]; for (i = 2; i <= n; i++) o = o "|" c[i]; print o (cr ? "\r" : ""); done = 1; next }
    { print $0 }' "$f" > "$tmp" && mv -f "$tmp" "$f"
}
ruling_text() { # bug file -> the text of its '## Ruling needed' section on one line (at most 600 characters)
  local t
  t="$(tr -d '\r' < "$1" | awk '/^##[ \t]/ { if (f) exit; if (tolower($0) ~ /^##[ \t]+ruling needed/) f = 1; next } f && NF { printf "%s ", $0 }' | sed -e 's/  */ /g' -e 's/ $//')"
  if [[ ${#t} -gt 600 ]]; then t="${t:0:600} ..."; fi
  printf '%s' "$t"
}
open_bug_list() { # spec entry -> "Bug-003 (major, blocked); Bug-004 (major, open)" for every bug that is not fixed, verified or wontfix
  local bf st out="" d; d="$(spec_dir "$1")/Backlog"
  [[ -d "$d" ]] || return 0
  for bf in "$d"/Bug-*.md; do
    [[ -f "$bf" ]] || continue
    st="$(bug_status_of "$bf")"
    case "$st" in fixed|verified|wontfix) continue ;; esac
    out="${out:+$out; }$(bug_key_of "$bf") ($(bug_field_of "$bf" severity), ${st:-no status})"
  done
  printf '%s' "$out"
}
review_verdict_of() { # review.md -> APPROVED | CHANGES_NEEDED | QUALITY_DEFERRED | TOOLCHAIN_DEFERRED | WAIVER_NEEDED | BLOCKED | empty
  local rv
  [[ -f "$1" ]] || return 0
  rv="$(tr -d '\r' < "$1" | sed -nE 's/^[Vv][Ee][Rr][Dd][Ii][Cc][Tt][[:space:]]*:[[:space:]]*"?([A-Za-z_-]+).*/\1/p' | head -n 1 | tr 'a-z' 'A-Z' | tr '-' '_')"
  if [[ -z "$rv" ]]; then rv="$(grep -oiwE 'APPROVED|CHANGES[_-]NEEDED|QUALITY[_-]DEFERRED|TOOLCHAIN[_-]DEFERRED|WAIVER[_-]NEEDED|BLOCKED' "$1" | head -n 1 | tr 'a-z' 'A-Z' | tr '-' '_' || true)"; fi
  printf '%s' "$rv"
}
# ---- what keeps a gate red, and who owns it ---------------------------------------------------------------------------
# gate_owner_summary SPEC -> GATE_IMPL_FAILS (failing checks an implementer owns) and GATE_ITEMS (every failing or deferred check with
# its owner and message) from the newest quality-gate output of the spec. Round 12: a gate red for a tool error and a stale image
# sent the implementer back three times for nothing; the owner column says whether a FIX pass can change anything.
GATE_IMPL_FAILS=0; GATE_ITEMS=""
gate_owner_summary() {
  local f flat res; GATE_IMPL_FAILS=0; GATE_ITEMS=""
  f="$(ls -t "$LOG_DIR"/check-*"$(safe_name "$1")"*-quality-gate.out 2>/dev/null | head -n 1 || true)"
  [[ -n "$f" ]] || return 0
  flat="$(sed -n '/{/,$p' "$f" | json_flat 2>/dev/null || true)"
  [[ -n "$flat" ]] || return 0
  res="$(awk -F'\t' '
    $1 ~ /^checks\.[0-9]+\.(id|status|fix_owner|message)$/ { split($1, p, "."); n = p[2] + 0; v[n, p[3]] = $2; if (n > mx) mx = n }
    END { impl = 0; items = ""
      for (n = 0; n <= mx; n++) { st = v[n, "status"]; if (st != "fail" && st != "deferred") continue
        o = v[n, "fix_owner"]; if (st == "fail" && (o == "implementer" || o == "infrastructure-implementer")) impl++
        m = v[n, "message"]; if (length(m) > 110) m = substr(m, 1, 110) "..."
        items = items (items == "" ? "" : "; ") v[n, "id"] " (" st ", " o "): " m }
      printf "%d\t%s", impl, items }' <<< "$flat")"
  GATE_IMPL_FAILS="${res%%$'\t'*}"; GATE_ITEMS="${res#*$'\t'}"
}
traceability_errors() { # spec -> the error count of the newest check-traceability output, or empty
  local f; f="$(ls -t "$LOG_DIR"/check-*"$(safe_name "$1")"*-check-traceability.out 2>/dev/null | head -n 1 || true)"
  [[ -n "$f" ]] || return 0
  tr -d '\r\n' < "$f" | sed -nE 's/.*"errors"[[:space:]]*:[[:space:]]*([0-9]+).*/\1/p'
}
# review_waiver_only ENTRY SPEC -> 0 when a CHANGES_NEEDED review leaves the implementer nothing: no open Bug, no failing gate check an
# implementer owns, no traceability error. What is left needs a human (environment, waiver), so the spec is not sent back to FIX.
review_waiver_only() {
  [[ -z "$(open_bug_list "$1")" ]] || return 1
  gate_owner_summary "$2"
  [[ "$GATE_IMPL_FAILS" -eq 0 ]] || return 1
  local te; te="$(traceability_errors "$2")"
  [[ -z "$te" || "$te" -eq 0 ]]
}
test_state_id() { local j; for ((j = 0; j < S_COUNT; j++)); do if [[ "${S_NAME[$j]}" == "TEST" ]]; then printf '%s' "${S_ID[$j]}"; return 0; fi; done; printf '16'; }
# nothing_to_verify ENTRY -> 0 when HEAD is the reviewed commit, nothing changed under src/ and no Bug is open or fixed-but-unverified:
# a scoped TEST would re-read an unchanged tree (round 12: a third verifier pass for nothing), so only the mechanical checks run.
nothing_to_verify() {
  local head bf
  head="$(cd "$ROOT" && git rev-parse HEAD 2>/dev/null || true)"
  [[ -n "$VM_BASE" && -n "$head" && "$head" == "$VM_BASE"* ]] || return 1
  [[ -z "$(cd "$ROOT" && git status --porcelain -- src 2>/dev/null)" ]] || return 1
  [[ -z "$(open_bug_list "$1")" ]] || return 1
  for bf in "$(spec_dir "$1")"/Backlog/Bug-*.md; do [[ -f "$bf" ]] || continue; if [[ "$(bug_status_of "$bf")" == "fixed" ]]; then return 1; fi; done
  return 0
}
# env_limits SPEC -> the LIMIT lines of the newest toolchain-preflight output (a Docker daemon that cannot reach a registry, ...), joined
env_limits() {
  local f; f="$(ls -t "$LOG_DIR"/check-*"$(safe_name "$1")"*-toolchain-preflight.out 2>/dev/null | head -n 1 || true)"
  [[ -n "$f" ]] || return 0
  { grep -E '^LIMIT ' "$f" 2>/dev/null || true; } | sed 's/^LIMIT //' | tr -d '\r' | tr '\n' ';' | sed 's/;$//; s/;/; /g'
}
# Scoped re-verification (kernel/protocols/model-routing.md, agents/verifier.md -> Re-verification mode): the first TEST of a spec is a
# full pass; once a review.md with the verdict CHANGES_NEEDED exists, the next TEST re-verifies only what changed. At most
# VERIFY_FULL_MAX full passes per spec; the counter lives in run.json -> attempts under the key full:SPEC-ID.
VERIFY_FULL_MAX=2
VM_MODE=""; VM_BASE=""; VM_VERDICT=""
verify_mode() { # spec entry -> sets VM_MODE (full|scoped) and VM_BASE (the commit the last review recorded, or empty)
  local rf pv; VM_MODE=full; VM_BASE=""; VM_VERDICT=""
  rf="$(spec_dir "$1")/review.md"
  pv="$(review_verdict_of "$rf")"
  # A QUALITY_DEFERRED review (everything verified, only a scanner missing) is re-verified like CHANGES_NEEDED: scoped, so a deferred-only outcome never uses a full pass.
  if [[ "$pv" == "CHANGES_NEEDED" || "$pv" == "QUALITY_DEFERRED" || "$pv" == "WAIVER_NEEDED" ]]; then
    VM_MODE=scoped; VM_VERDICT="$pv"
    VM_BASE="$(tr -d '\r' < "$rf" | sed -nE 's/^[[:space:]]*(reviewed[-_ ]?)?commit[[:space:]]*:[[:space:]]*"?([0-9a-fA-F]{7,40}).*/\2/p' | head -n 1)"
    if [[ -z "$VM_BASE" ]]; then VM_BASE="$(cd "$ROOT" && git log -1 --format=%H -- "$(rel "$rf")" 2>/dev/null || true)"; fi
  fi
}
scoped_prompt() { # -> the sentence added to the verifier's prompt in a scoped re-verification
  local base=""
  if [[ -n "$VM_BASE" ]]; then base="the diff since commit $VM_BASE (git diff $VM_BASE..HEAD, plus uncommitted changes)"; else base="the diff since the last review.md was written (no commit is recorded in it: use git log and git status, and the Bug files' Status)"; fi
  printf '%s' "RE-VERIFICATION MODE (agents/verifier.md -> Re-verification mode): this is not the first verification of $C_SPEC; a review.md with the verdict $VM_VERDICT exists. Do NOT run a full pass. Re-verify only (a) every Bug item whose Status changed since that review (fixed, wontfix, blocked), and (b) the acceptance criteria and Test IDs whose files changed in $base. Always run the mandatory mechanical checks: quality-gate and check-traceability. Copy every other verdict row from the previous review.md unchanged, and state in the new review.md that those rows were carried over from the previous review and not re-run. Verify a fix for real (run its regression test and the commands that exercise it); file a new Bug only for a failure in the re-verified scope or in a changed file. If an orchestrator session runs this state, put this paragraph verbatim in the verifier subagent's handover packet."
}
check_desc() { # $1 idx, $2 = "then" for the then-check
  local i="$1" tool args s
  if [[ "${2:-}" == "then" ]]; then tool="${S_TT[$i]}"; args="${S_TA[$i]}"; else tool="${S_CT[$i]}"; args="${S_CA[$i]}"; fi
  s="$tool"
  if [[ -n "$args" ]]; then s="$s $(render "$(printf '%s' "$args" | tr '\037' ' ')")"; fi
  if [[ "${2:-}" != "then" && -n "${S_CP[$i]}" ]]; then s="$s $(render "${S_CP[$i]}")"; fi
  if [[ "${2:-}" != "then" && -n "${S_CPS[$i]:-}" ]]; then s="$s $(render "$(printf '%s' "${S_CPS[$i]}" | tr '\037' ',')")"; [[ "${S_CANY[$i]:-}" == "true" ]] && s="$s [any]"; fi
  if [[ "${2:-}" != "then" && -n "${S_PW[$i]}" ]]; then s="$s [pass_when ${S_PW[$i]}]"; fi
  if [[ "${2:-}" != "then" && -n "${S_TT[$i]}" ]]; then s="$s THEN $(check_desc "$i" then)"; fi
  if [[ "${2:-}" == "then" && -n "${S_TU[$i]:-}" ]]; then s="$s THEN ${S_TU[$i]}"; fi
  printf '%s' "$s"
}
LAST_HARNESS_RC=-1
CHK_RC=0; CHK_VIOL=""; CHK_BLOCKED=""; CHK_OPEN=""
run_check() { # $1 idx, $2 label, $3 = "then"
  local i="$1" label="$2" tool args
  if [[ "${3:-}" == "then2" ]]; then tool="${S_TU[$i]}"; args=""
  elif [[ "${3:-}" == "then" ]]; then tool="${S_TT[$i]}"; args="${S_TA[$i]}"; else tool="${S_CT[$i]}"; args="${S_CA[$i]}"; fi
  CHK_VIOL=""; CHK_BLOCKED=""; CHK_OPEN=""
  case "$tool" in
    internal:review-verdict)
      local rf rv=""
      rf="$(spec_dir "$C_ENTRY")/review.md"
      if [[ -z "$C_ENTRY" || ! -f "$rf" ]]; then CHK_RC=1; CHK_VIOL="REVIEW-001 (verifier): review.md not found for $C_SPEC"; return 0; fi
      rv="$(review_verdict_of "$rf")"
      if [[ "$rv" == "APPROVED" ]]; then CHK_RC=0
      elif [[ "$rv" == "WAIVER_NEEDED" ]] || { [[ "$rv" == "CHANGES_NEEDED" ]] && review_waiver_only "$C_ENTRY" "$C_SPEC"; }; then
        # The code is done: no open Bug, no failing check an implementer owns. What keeps the gate red (an environment limit, a stale
        # artifact, a gate tool error, a check the architecture excluded) needs a human: exit 3 opens the waiver gate, never FIX.
        local ob how; ob="$(open_bug_list "$C_ENTRY")"
        if [[ -n "$ob" ]]; then CHK_RC=1; CHK_VIOL="REVIEW-002 (implementer): $C_SPEC review verdict is $rv but these bug items are not closed: $ob; fix them, then re-test"
        else
          gate_owner_summary "$C_SPEC"
          how="review verdict $rv"; if [[ "$rv" == "CHANGES_NEEDED" ]]; then how="review verdict CHANGES_NEEDED with no open bug and no failing check an implementer owns (read as WAIVER_NEEDED)"; fi
          CHK_RC=3; CHK_VIOL="REVIEW-004 (human): $how; the code is done and what keeps the gate red needs an environment fix or a recorded waiver, not another fix pass: ${GATE_ITEMS:-see review.md -> Verdict}. not a pass"
        fi
      elif [[ "$rv" == "QUALITY_DEFERRED" || "$rv" == "TOOLCHAIN_DEFERRED" ]]; then
        # Deferred = every check that could run has run and the only blocker is an external tool that is missing (quality-gate exit 3).
        # With every bug fixed, verified or waived that is exit 3 (closed as deferred-accepted, never a pass, no FIX and no second full pass);
        # with a bug still open the implementer has work, so it is a failure like CHANGES_NEEDED.
        local ob mt; ob="$(open_bug_list "$C_ENTRY")"
        if [[ -n "$ob" ]]; then CHK_RC=1; CHK_VIOL="REVIEW-002 (implementer): $C_SPEC review verdict is $rv but these bug items are not closed: $ob; fix them, then re-test"
        else
          mt="$(last_missing_tools "$C_SPEC")"
          CHK_RC=3; CHK_VIOL="REVIEW-003 (human): review verdict $rv; every bug is closed and the only blocker is a deferred external tool, so this is not a pass${mt:+. missing tools: $mt}"
        fi
      else CHK_RC=1; CHK_VIOL="REVIEW-002 (implementer): $C_SPEC review verdict is ${rv:-missing}; fix the open bugs and failing acceptance criteria listed in review.md, then re-review"; fi
      return 0 ;;
    internal:roi-confidence)
      local f="$ROOT/ideation/$C_IDEA/ROI.md" min="${S_MIN[$i]:-60}" pct=""
      if [[ -n "$C_IDEA" && -f "$f" ]]; then
        pct="$(grep -io 'roi confidence[^0-9]*[0-9]\{1,3\} *%' "$f" | head -1 | sed 's/.*[^0-9]\([0-9]\{1,3\}\) *%$/\1/; s/^[^0-9]*\([0-9]\{1,3\}\) *%$/\1/' || true)"
        if [[ -z "$pct" ]]; then pct="$(grep -io 'confidence[^0-9]*[0-9]\{1,3\} *%' "$f" | head -1 | sed 's/.*[^0-9]\([0-9]\{1,3\}\) *%$/\1/; s/^[^0-9]*\([0-9]\{1,3\}\) *%$/\1/' || true)"; fi
      fi
      if [[ -z "$pct" ]]; then CHK_RC=1; CHK_VIOL="ROI-001 (idea-interrogator): ROI confidence % not recorded in ideation/$C_IDEA/ROI.md"
      elif [[ "$pct" -ge "$min" ]]; then CHK_RC=0
      else CHK_RC=1; CHK_VIOL="ROI-002 (human): ROI confidence $pct% is below $min%"; fi
      return 0 ;;
    internal:no-open-bugs)
      # Bug items of the spec (Backlog/Bug-*.md) by Status cell. open or fixing: the FIX state is done when none is left.
      # blocked: the fix needs a human ruling (a '## Ruling needed' section); it is its own finding (BUG-006, owner human), is never
      # retried, and opens the ruling gate (CHK_BLOCKED lists the bugs, CHK_OPEN the ones an implementer can still fix).
      local bf bsv bopen="" bblk="" bq=""
      CHK_BLOCKED=""; CHK_OPEN=""
      if [[ -n "$C_ENTRY" && -d "$(spec_dir "$C_ENTRY")/Backlog" ]]; then
        for bf in "$(spec_dir "$C_ENTRY")"/Backlog/Bug-*.md; do
          [[ -f "$bf" ]] || continue
          bsv="$(bug_status_of "$bf")"
          if [[ "$bsv" == "open" || "$bsv" == "fixing" ]]; then bopen="$bopen $(bug_key_of "$bf")"; fi
          if [[ "$bsv" == "blocked" ]]; then bblk="$bblk $(bug_key_of "$bf")"; bq="$bq $(bug_key_of "$bf") needs a ruling: $(ruling_text "$bf");"; fi
        done
      fi
      CHK_BLOCKED="${bblk# }"; CHK_OPEN="${bopen# }"
      if [[ -n "$bblk" && -z "$bopen" ]]; then CHK_RC=1; CHK_VIOL="BUG-006 (human): $C_SPEC has blocked bug item(s)${bblk// /, }; no fix can proceed without a human ruling.${bq%;}"
      elif [[ -n "$bopen" ]]; then CHK_RC=1; CHK_VIOL="BUG-OPEN (implementer): $C_SPEC still has open bug item(s)${bopen// /, }; fix each test-first and set its Status to fixed"
      else CHK_RC=0; fi
      return 0 ;;
    internal:file-exists)
      local p; p="$(render "${S_CP[$i]}")"
      if [[ -e "$ROOT/$p" ]]; then CHK_RC=0; else CHK_RC=1; CHK_VIOL="FILE-001 (agent): missing $p"; fi
      return 0 ;;
    internal:roadmap-specs)
      # SPECS (fast track) writes only the split: ROADMAP.md plus a folder with a stub note for every spec it lists.
      local rsd="$ROOT/specs/$C_IDEA-Specs" rsid rsmiss="" rsids=""
      if [[ -z "$C_IDEA" || ! -f "$rsd/ROADMAP.md" ]]; then CHK_RC=1; CHK_VIOL="SPEC-005 (spec-writer): missing specs/${C_IDEA:-IDEA}-Specs/ROADMAP.md"; return 0; fi
      rsids="$(tr -d '\r' < "$rsd/ROADMAP.md" | awk '/^[ \t]*\|/ && !/^[ \t]*\|[ \t:|-]+\|?[ \t]*$/ { if (match($0, /SPEC-[0-9]+/)) { id = substr($0, RSTART, RLENGTH); if (!seen[id]++) print id } }')"
      if [[ -z "$rsids" ]]; then CHK_RC=1; CHK_VIOL="SPEC-005 (spec-writer): ROADMAP.md lists no SPEC-NNN in its Execution Plan"; return 0; fi
      for rsid in $rsids; do
        if ! compgen -G "$rsd/$rsid-*/$rsid*.md" >/dev/null && ! compgen -G "$rsd/$rsid/$rsid*.md" >/dev/null; then rsmiss="${rsmiss:+$rsmiss, }$rsid"; fi
      done
      # The split also writes the per-idea index (IDEA-NNN-slug-Specs.md): the planners and the LINK-002/003 checks read it.
      if [[ -z "$rsmiss" && ! -f "$rsd/$C_IDEA-Specs.md" ]]; then CHK_RC=1; CHK_VIOL="SPEC-006 (spec-writer): missing the per-idea index specs/$C_IDEA-Specs/$C_IDEA-Specs.md (a table of the SPEC notes that wikilinks the idea note)"; return 0; fi
      if [[ -z "$rsmiss" ]]; then CHK_RC=0; else CHK_RC=1; CHK_VIOL="SPEC-005 (spec-writer): ROADMAP.md lists $rsmiss but there is no folder with a SPEC-NNN-slug.md stub note for it"; fi
      return 0 ;;
    internal:agent-report)
      if [[ "$LAST_HARNESS_RC" == "0" ]]; then CHK_RC=0; else CHK_RC=1; CHK_VIOL="AGENT-001 (agent): harness exited $LAST_HARNESS_RC; expected: ${S_EXP[$i]}"; fi
      return 0 ;;
    internal:files-exist)
      local fp fpp fcnt=0 fok=0 fmiss="" fall=""
      while IFS= read -r fp; do
        [[ -n "$fp" ]] || continue
        fcnt=$((fcnt + 1)); fpp="$(render "$fp")"; fall="${fall:+$fall, }$fpp"
        if [[ -e "$ROOT/$fpp" ]]; then fok=$((fok + 1)); else fmiss="${fmiss:+$fmiss, }$fpp"; fi
      done < <(printf '%s\n' "${S_CPS[$i]:-}" | tr '\037' '\n') # the trailing newline matters: read drops an unterminated last line, so ASK's second path was never checked
      if [[ $fcnt -eq 0 ]]; then CHK_RC=2; CHK_VIOL="FILE-000: internal:files-exist needs a paths list"
      elif [[ "${S_CANY[$i]:-}" == "true" ]]; then if [[ $fok -gt 0 ]]; then CHK_RC=0; else CHK_RC=1; CHK_VIOL="FILE-002 (agent): none of $fall exists"; fi
      elif [[ -z "$fmiss" ]]; then CHK_RC=0; else CHK_RC=1; CHK_VIOL="FILE-001 (agent): missing $fmiss"; fi
      return 0 ;;
  esac
  local targs=() x has_json=0
  if [[ -n "$args" ]]; then
    local IFS=$'\037'
    for x in $args; do targs+=("$(render "$x")"); if [[ "$x" == "-Json" ]]; then has_json=1; fi; done
    unset IFS
  fi
  if [[ "$tool" != "toolchain-preflight" && $has_json -eq 0 ]]; then targs+=(-Json); fi
  local out; out="$LOG_DIR/check-$(safe_name "$label")-$tool.out"
  run_tool "$tool" "$out" "${targs[@]+"${targs[@]}"}"
  CHK_RC=$TOOL_RC
  local flat=""
  if grep -q '{' "$out" 2>/dev/null; then flat="$(sed -n '/{/,$p' "$out" | json_flat 2>/dev/null || true)"; fi
  if [[ -n "${S_PW[$i]}" && -z "${3:-}" && $CHK_RC -ne 2 ]]; then
    if pass_when "${S_PW[$i]}" "$flat"; then CHK_RC=0; elif [[ $CHK_RC -eq 0 ]]; then CHK_RC=1; fi
  fi
  CHK_VIOL="$(format_violations "$flat")"
  # Exit 3 is a deferred check (an external tool is missing): name the tool and the checks that did not run, so the gate, the
  # NeedsAttention item and the closing message can say exactly what to install.
  if [[ $CHK_RC -eq 3 && -z "$CHK_VIOL" && -n "$flat" ]]; then
    local dmt ddc
    dmt="$(awk -F'\t' '$1 ~ /^missing_tools\.[0-9]+$/ { print $2 }' <<< "$flat" | tr '\n' ',' | sed 's/,$//; s/,/, /g')"
    ddc="$(awk -F'\t' '$1 ~ /^checks\.[0-9]+\.(id|status)$/ { split($1, p, "."); n = p[2] + 0; if (p[3] == "id") id[n] = $2; else st[n] = $2 } END { for (n in id) if (st[n] == "deferred") print n "\t" id[n] }' <<< "$flat" | sort -n | cut -f2 | awk '!s[$0]++' | tr '\n' ',' | sed 's/,$//; s/,/, /g')"
    if [[ -n "$dmt" ]]; then CHK_VIOL="QG-DEFERRED (human): $tool deferred${ddc:+ checks $ddc}, not a pass. missing tools: $dmt. Install them through toolchain-preflight, then re-run $tool"; fi
  fi
  if [[ "$tool" == "toolchain-preflight" && $CHK_RC -ne 0 ]]; then
    local mtl; mtl="$(sed -n 's/.*MISSING TOOLS:[[:space:]]*\(.*\)$/\1/p' "$out" | head -n 1 | tr -d '\r')"
    if [[ -n "$mtl" ]]; then CHK_VIOL="TC-001 (human): toolchain preflight failed. missing tools: $(flat "$mtl"). Install them or defer."; fi
  fi
  if [[ $CHK_RC -ne 0 && -z "$CHK_VIOL" ]]; then
    CHK_VIOL="$tool exited $CHK_RC (output: $(rel "$out"))"
    if [[ "$tool" == "repo-bootstrap" && -n "$flat" ]]; then CHK_VIOL="RB-GATE (human): git $(flat_get "$flat" git), commits $(flat_get "$flat" commits), decision $(flat_get "$flat" decision)"; fi
  fi
  if [[ $CHK_RC -eq 0 ]]; then
    if [[ -z "${3:-}" && -n "${S_TT[$i]}" ]]; then run_check "$i" "$label" then
    elif [[ "${3:-}" == "then" && -n "${S_TU[$i]}" ]]; then run_check "$i" "$label" then2; fi
  fi
  return 0
}

# ---- harness ------------------------------------------------------------------------------------------
LIMIT_RE_BUILTIN='usage limit|rate limit|rate-limit|ratelimit|limit reached|quota exceeded|exceeded your (current )?quota|too many requests|resource_exhausted|limit exceeded'
# kernel/limit-patterns.json is the shared table (kcc-run, kcc-limit-watch, and the kcc CLI); the built-in is the fallback.
# limit_key_v KEY -> RV: the value of the first `"limit_regex.KEY": "..."` line of kernel/limit-patterns.json (one key per line, no
# backslashes: the file is read line by line, CRs dropped, as the sed it replaces did), or empty
LIMIT_LINES=(); LIMIT_LOADED=0
limit_key_v() {
  RV=""
  if [[ $LIMIT_LOADED -eq 0 ]]; then
    LIMIT_LOADED=1
    local f="$ROOT/.KCC/kernel/limit-patterns.json" l
    if [[ -f "$f" ]]; then while IFS= read -r l || [[ -n "$l" ]]; do LIMIT_LINES[${#LIMIT_LINES[@]}]="${l//$'\r'/}"; done < "$f"; fi
  fi
  local l re='^ *"limit_regex\.'"$1"'": *"(.*)",? *$'
  local i
  for ((i = 0; i < ${#LIMIT_LINES[@]}; i++)); do
    if [[ "${LIMIT_LINES[i]}" =~ $re ]]; then RV="${BASH_REMATCH[1]}"; return 0; fi
  done
}
limit_re() { # $1 harness
  local d h
  limit_key_v default; d="$RV"; limit_key_v "$1"; h="$RV"
  if [[ -n "$d" && -n "$h" ]]; then printf '%s|%s' "$d" "$h"
  elif [[ -n "$d$h" ]]; then printf '%s' "$d$h"
  else printf '%s' "$LIMIT_RE_BUILTIN"; fi
}
limit_hit() { # $1 log, $2 rc
  local t h l re429='(^|[^0-9])429([^0-9]|$)' re n=0 k
  local -a tail60
  if [[ "$2" != "0" ]]; then
    # the last 60 lines, lower-cased: a limit notice from the harness, or an HTTP 429 (a ring of 60, then in order)
    tail60=()
    if [[ -f "$1" ]]; then while IFS= read -r l || [[ -n "$l" ]]; do tail60[n % 60]="$l"; n=$((n + 1)); done < "$1"; fi
    t=""
    for ((k = (n > 60 ? n - 60 : 0); k < n; k++)); do t+="${tail60[k % 60]}"$'\n'; done
    lc_v "$t"; t="$LCV"
    limit_key_v default; h="$RV"; limit_key_v "$HARNESS"
    if [[ -n "$h" && -n "$RV" ]]; then re="$h|$RV"; elif [[ -n "$h$RV" ]]; then re="$h$RV"; else re="$LIMIT_RE_BUILTIN"; fi
    if [[ "$t" =~ $re ]]; then return 0; fi
    if [[ "$t" =~ $re429 ]]; then return 0; fi
    return 1
  fi
  # Exit 0: the session finished its turn, so prose such as "rate-limit values are assumptions" is not
  # a limit. Only the harness's own limit notice on the final lines counts.
  limit_key_v "$HARNESS"; h="$RV"
  [[ -n "$h" ]] || return 1
  # the last 3 lines that are not blank, lower-cased
  local -a last3=(); t=""
  if [[ -f "$1" ]]; then
    while IFS= read -r l || [[ -n "$l" ]]; do
      [[ "$l" == *[![:space:]]* ]] || continue
      last3[${#last3[@]}]="$l"; if [[ ${#last3[@]} -gt 3 ]]; then last3=("${last3[@]:1}"); fi
    done < "$1"
  fi
  for l in ${last3[@]+"${last3[@]}"}; do t+="$l"$'\n'; done
  lc_v "$t"; t="$LCV"
  [[ "$t" =~ $h ]]
}
reset_epoch() { # $1 log -> epoch or empty
  local r
  r="$(tail -n 80 "$1" 2>/dev/null | awk -v now="$(date +%s)" '
    { L[NR]=tolower($0); O[NR]=$0 }
    END { for (i=NR; i>0; i--) { t=L[i]
      if (match(t, /\|[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]/)) { print substr(t, RSTART+1, 10); exit }
      if (match(t, /resets?_?at"?[: =]+[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]/)) { v=substr(t, RSTART, RLENGTH); print substr(v, length(v)-9); exit }
      if (match(t, /retry-after:? *[0-9]+/)) { v=substr(t, RSTART, RLENGTH); gsub(/[^0-9]/, "", v); print now+v; exit }
      if (match(t, /(again|retry|resets?|available|wait)[a-z ]* in [0-9][0-9a-z .,]*/)) {
        seg=substr(t, RSTART, RLENGTH); sub(/.* in /, "", seg); tot=0
        while (match(seg, /^[ ,]*[0-9]+(\.[0-9]+)?[ ]*[a-z]+/)) {
          tok=substr(seg, RSTART, RLENGTH); seg=substr(seg, RSTART+RLENGTH); num=tok; gsub(/[^0-9.]/, "", num); u=tok; gsub(/[^a-z]/, "", u)
          if (u ~ /^(h|hr|hrs|hour|hours)$/) tot+=num*3600; else if (u ~ /^(m|min|mins|minute|minutes)$/) tot+=num*60
          else if (u ~ /^(s|sec|secs|second|seconds)$/) tot+=num; else if (u != "and") break }
        if (tot > 0) { printf "%d\n", now+tot; exit } }
      if (match(O[i], /[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9][T ][0-9][0-9]:[0-9][0-9](:[0-9][0-9])?(Z|[+-][0-9][0-9]:?[0-9][0-9])?/)) { print "iso " substr(O[i], RSTART, RLENGTH); exit }
    } }' || true)"
  if [[ "$r" == iso\ * ]]; then r="$(date -d "${r#iso }" +%s 2>/dev/null || true)"; fi
  printf '%s' "$r"
}
test_bypass() { local l re_pm='permission-mode[[:space:]]+bypass'; lc_v "$1"; l="$LCV"; case "$l" in *dangerously-skip*|*dangerously-bypass*|*bypasspermissions*|*--yolo*) return 0 ;; esac; if [[ "$l" =~ $re_pm ]]; then return 0; fi; return 1; }
# sanitize_prompt_v TEXT -> RV: whitespace to spaces; " and ` to '; $ dropped; % to " pct"; ! to .; \ to /; runs of spaces squeezed; ends trimmed
sanitize_prompt_v() {
  local s="$1" sq="'" dq='"' bt='`' ds='$' pc='%' ex='!' bs='\'
  s="${s//$'\r'/ }"; s="${s//$'\n'/ }"; s="${s//$'\t'/ }"
  s="${s//"$dq"/$sq}"; s="${s//"$bt"/$sq}"; s="${s//"$ds"/}"; s="${s//"$pc"/ pct}"; s="${s//"$ex"/.}"; s="${s//"$bs"//}"
  while [[ "$s" == *"  "* ]]; do s="${s//  / }"; done
  s="${s# }"; RV="${s% }"
}
sanitize_prompt() { sanitize_prompt_v "$1"; printf '%s' "$RV"; }
# ---- fasttrack worker states run AS the agent (`claude --agent`): no orchestrator session above them ----
HARNESS_EXTRA=""
wave_complexity() { # entry wave -> low|medium|high|extra-high or empty (highest in the wave)
  local pf; pf="$(spec_dir "$1")/plan.md"
  [[ -f "$pf" ]] || return 0
  tr -d '\r' < "$pf" | awk -v wave="$2" '
    function rank(c) { return c == "extra-high" ? 4 : c == "high" ? 3 : c == "medium" ? 2 : c == "low" ? 1 : 0 }
    /^[ \t]*\|/ {
      line = $0; sub(/^[ \t]*\|/, "", line); sub(/\|[ \t]*$/, "", line); m = split(line, C, "|")
      if (!hdr) { for (i = 1; i <= m; i++) { h = tolower(C[i]); gsub(/^[ \t]+|[ \t]+$/, "", h); if (h == "wave") wi = i; if (h == "complexity") ci = i } if (wi && ci) hdr = 1; else { wi = 0; ci = 0 } next }
      if (line ~ /^[ \t:|-]+$/) next
      w = C[wi]; gsub(/^[ \t]+|[ \t]+$/, "", w); c = tolower(C[ci]); gsub(/^[ \t]+|[ \t]+$/, "", c)
      if (w == wave && rank(c) > rank(best)) best = c
      next }
    { if (hdr) exit }
    END { print best }'
}
resolve_claude_model_v() { # bare aliases -> pinned 5.5 IDs (`haiku` can still mean Haiku 4.5, which has no auto mode) -> RV
  lc_v "$1"
  case "$LCV" in
    haiku) RV="claude-haiku-5-5" ;;
    sonnet) RV="claude-sonnet-5-5" ;;
    opus) RV="claude-opus-5-5" ;;
    *) RV="$1" ;;
  esac
}
resolve_claude_model() { resolve_claude_model_v "$1"; printf '%s\n' "$RV"; }
# ---- harness profile and model registry: nothing below assumes a particular harness ---------------------
# kernel/harnesses.json says how each harness takes an agent, a model and an effort; kernel/models.json says which model each
# tier is on each harness (settings run.registry picks another column, e.g. 'ollama' behind the opencode harness).
hprofile_v() { # key -> RV: settings harness_invoke.<harness>.<key>, else kernel/harnesses.json
  local v
  setting_v "harness_invoke.$HARNESS.$1" ""; v="$FGV"
  if [[ -z "$v" ]]; then fget_v "$HARNESSES_FLAT" "harnesses.$HARNESS.$1"; v="$FGV"; fi
  if [[ "$v" == "null" ]]; then v=""; fi
  RV="$v"
}
hprofile() { hprofile_v "$1"; printf '%s' "$RV"; }
heffort_v() { # neutral effort -> RV: what the harness accepts (effort_map), unchanged when not mapped
  fget_v "$HARNESSES_FLAT" "harnesses.$HARNESS.effort_map.$1"
  if [[ -n "$FGV" && "$FGV" != "null" ]]; then RV="$FGV"; else RV="$1"; fi
}
heffort() { heffort_v "$1"; printf '%s' "$RV"; }
tier_model_v() { # tier -> RV: model id on the registry column of the active harness (with its prefix), or nothing
  local reg id prefix
  setting_v run.registry ""; reg="$FGV"; [[ -n "$reg" ]] || reg="$HARNESS"
  fget_v "$REGISTRY_FLAT" "harnesses.$reg.$1.id"; id="$FGV"
  RV=""
  if [[ -z "$id" || "$id" == "null" ]]; then return 0; fi
  fget_v "$REGISTRY_FLAT" "harnesses.$reg._prefix"; prefix="$FGV"; if [[ "$prefix" == "null" ]]; then prefix=""; fi
  RV="$prefix$id"
}
tier_model() { tier_model_v "$1"; printf '%s' "$RV"; }
# The model for the orchestrator wrapper or the escalation: an explicit run.<kind>_model wins, except that a Claude id is
# never passed to another harness; otherwise the tier (run.<kind>_tier) on the active harness's registry column.
run_model_v() { # kind defaultTier -> RV
  local explicit tier keep='[^A-Za-z0-9._:/-]'
  setting_v "run.$1_model" ""; explicit="${FGV//$keep/}"
  if [[ -n "$explicit" ]] && { [[ "$HARNESS" == "claude" ]] || ! [[ "$explicit" =~ ^(claude-|opus$|sonnet$|haiku$) ]]; }; then
    if [[ "$HARNESS" == "claude" ]]; then resolve_claude_model_v "$explicit"; else RV="$explicit"; fi
    return 0
  fi
  setting_v "run.$1_tier" "$2"; tier="${FGV//[^a-z]/}"
  tier_model_v "$tier"
}
run_model() { run_model_v "$1" "$2"; printf '%s' "$RV"; }
# Every dispatch, in every cycle, asks the router (`.KCC/tools/kcc-route`, the port of cli/src/run/router.ts) which tier,
# model and effort the state's agent gets: from the agent's profile, the plan's Complexity and files for this wave or spec,
# the idea's domain, CR-7 words and the attempt. One rulebook (kernel/protocols/model-routing.md), three identical copies.
# get_route AGENT ATTEMPT -> sets RT_TIER RT_MODEL RT_EFFORT RT_WHY (empty when the router gave nothing)
get_route() {
  RT_TIER=""; RT_MODEL=""; RT_EFFORT=""; RT_WHY=""
  [[ -n "${1:-}" && -f "$TOOLS/kcc-route.sh" ]] || return 0
  local a=(--repo-root "$ROOT" --agent "$1" --attempt "$2" --harness "$HARNESS") line="" out l tab=$'\t'
  [[ -n "$C_SPEC" ]] && a+=(--spec "$C_SPEC")
  [[ -n "$C_WAVE" ]] && a+=(--wave "$C_WAVE")
  [[ -n "${ROUTE_EXTRA:-}" ]] && a+=($ROUTE_EXTRA)
  out="$(bash "$TOOLS/kcc-route.sh" "${a[@]}" 2>/dev/null || true)"
  # the last output line that holds a tab (grep "$tab" | tail -n 1)
  while IFS= read -r l || [[ -n "$l" ]]; do if [[ "$l" == *"$tab"* ]]; then line="$l"; fi; done <<< "$out"
  [[ -n "$line" ]] || return 0
  # split on single tabs by hand: `read` with a tab IFS merges the empty model of a harness with no registry column into its neighbours
  local rest="$line"
  RT_TIER="${rest%%"$tab"*}"; rest="${rest#*"$tab"}"
  RT_MODEL="${rest%%"$tab"*}"; rest="${rest#*"$tab"}"
  RT_EFFORT="${rest%%"$tab"*}"; rest="${rest#*"$tab"}"
  RT_WHY="${rest%%"$tab"*}"
}
agent_mode() { # idx att -> sets AM_MODE (wrapper|direct|empty) AM_AGENT AM_MODEL AM_EFFORT AM_WHY AM_TIER AM_SOURCE AM_WM AM_WE
  # The state's agent (the table's agent_fasttrack) is routed in every cycle. Under --fasttrack, when the harness can select an
  # agent and run.fasttrack_direct is not false, the state runs AS that agent with the routed model and effort; otherwise an
  # orchestrator session runs the state (on the fast tier, low effort under fast track; the harness default in a full run) and is
  # told which tier, model and effort to spawn the agent on.
  AM_MODE=""; AM_AGENT=""; AM_MODEL=""; AM_EFFORT=""; AM_WHY=""; AM_WM=""; AM_WE=""; AM_SOURCE=""; AM_TIER=""
  AM_AGENT="${S_AGF[$1]:-}"
  # REVIEW is a quick diff review and a scoped re-verification a re-check: neither runs above balanced tier at high effort (model-routing.md).
  ROUTE_EXTRA=""
  if [[ "${S_NAME[$1]}" == "REVIEW" || ( "${S_NAME[$1]}" == "TEST" && "${VM_MODE:-}" == "scoped" ) ]]; then ROUTE_EXTRA="--max-tier balanced --max-effort high"; fi
  local fast=0; [[ "$R_fasttrack" == "1" ]] && fast=1
  get_route "$AM_AGENT" "$(( $2 + 1 ))"
  if [[ -n "$RT_TIER" ]]; then AM_TIER="$RT_TIER"; AM_MODEL="$RT_MODEL"; AM_EFFORT="$RT_EFFORT"; AM_WHY="$RT_WHY"; AM_SOURCE=kcc-route; fi
  if [[ "$fast" -eq 1 ]]; then run_model_v orchestrator fast; AM_WM="$RV"; setting_v run.orchestrator_effort low; AM_WE="${FGV//[^a-z]/}"; fi
  AM_MODE=wrapper
  # Direct needs fast track, a harness that selects an agent by flag, and an agent file in that harness's agent folder.
  local adir hpa fdirect
  hprofile_v agent_dir; adir="$RV"
  hprofile_v agent; hpa="$RV"
  setting_v run.fasttrack_direct true; lc_v "$FGV"; fdirect="$LCV"
  if [[ "$fast" -eq 1 && "$fdirect" != "false" && -n "$AM_AGENT" && -n "$hpa" && -n "$adir" && -f "$ROOT/$adir/$AM_AGENT.md" ]]; then AM_MODE=direct; fi
  if [[ -z "$AM_AGENT" && "$fast" -eq 0 ]]; then AM_MODE=""; fi
}
idea_domain() { # Research.md -> '## Domain' (common | specialised | novel)
  local f="$ROOT/ideation/${1:-}/Research.md" v=""
  [[ -n "${1:-}" && -f "$f" ]] || { printf ''; return 0; }
  v="$(tr -d '\r' < "$f" | awk 'BEGIN{IGNORECASE=1} /^##[[:space:]]+Domain/ { if (match($0, /:[[:space:]]*`?(common|specialised|specialized|novel)/)) { print tolower(substr($0, RSTART+1, RLENGTH-1)); exit } f=1; next } f && /[A-Za-z]/ { print tolower($0); exit }' | grep -oE 'common|specialised|specialized|novel' | head -n 1)"
  [[ "$v" == "specialized" ]] && v=specialised
  printf '%s' "$v"
}
hflag_v() { # template key value -> RV: the flag with the value in it, or nothing
  local tpl="$1" key="$2" val="$3" ph
  RV=""
  if [[ -z "$tpl" || -z "$val" ]]; then return 0; fi
  ph="{$key}"
  RV="${tpl//"$ph"/$val}"
}
harness_extra_v() { # after agent_mode: the flags that pick the agent, model and effort, written the way the active harness takes them
  local m e out="" f
  if [[ "$AM_MODE" == "direct" ]]; then m="$AM_MODEL"; e="$AM_EFFORT"; hprofile_v agent; hflag_v "$RV" agent "$AM_AGENT"; out="$RV"
  elif [[ "$AM_MODE" == "wrapper" ]]; then m="$AM_WM"; e="$AM_WE"
  else RV=""; return 0; fi
  hprofile_v model; hflag_v "$RV" model "$m"; f="$RV"; if [[ -n "$f" ]]; then out="${out:+$out }$f"; fi
  heffort_v "$e"; local he="$RV"; hprofile_v effort; hflag_v "$RV" effort "$he"; f="$RV"; if [[ -n "$f" ]]; then out="${out:+$out }$f"; fi
  RV="$out"
}
harness_extra() { harness_extra_v; printf '%s' "$RV"; }
convert_agent_body_v() { # "/skill args" -> RV: instruction that names the skill file
  if [[ "$1" =~ ^/([a-z][a-z0-9-]*)[[:space:]]*(.*)$ ]]; then
    local sp skill="${BASH_REMATCH[1]}" rest="${BASH_REMATCH[2]}"; hprofile_v skill_path; sp="$RV"; if [[ -z "$sp" ]]; then sp=".claude/skills/{skill}/SKILL.md"; fi
    printf -v RV 'Do the work of the skill described in %s (read it first) with these arguments: %s' "${sp//"{skill}"/$skill}" "$rest"
  else RV="$1"; fi
}
convert_agent_body() { convert_agent_body_v "$1"; printf '%s' "$RV"; }
harness_cmd_v() { # prompt -> RV: the start command of the active harness for it (empty when the settings have no template)
  local tpl perm p ins
  RV=""
  setting_v "continuity.start.$HARNESS" ""; tpl="$FGV"
  if [[ -z "$tpl" ]]; then return 0; fi
  hprofile_v insert_after; ins="$RV"
  if [[ -n "$HARNESS_EXTRA" && -n "$ins" ]]; then
    # put the flags after the first " <ins> " token of the start template, without sed so no character of the flags is special
    case "$tpl" in *" $ins "*) tpl="${tpl/" $ins "/" $ins $HARNESS_EXTRA "}" ;; esac
  fi
  setting_v continuity.permission_mode auto; perm="${FGV//[^A-Za-z]/}"; [[ -n "$perm" ]] || perm=auto
  sanitize_prompt_v "$1"; p="$RV"
  tpl="${tpl//\{resume_prompt\}/"$p"}"; tpl="${tpl//\{permission_mode\}/"$perm"}"; tpl="${tpl//\{session_id\}/}"
  RV="$tpl"
}
harness_cmd() { harness_cmd_v "$1"; printf '%s' "$RV"; }
invoke_harness() { # $1 prompt, $2 log -> LAST_HARNESS_RC
  local cmd rc=0 was
  harness_cmd_v "$1"; cmd="$RV"
  if [[ -z "$cmd" ]]; then stop_run env "no continuity.start template for harness $HARNESS in .KCC/settings.json" 2; fi
  if test_bypass "$cmd"; then stop_run env "refusing a harness template with a permission-bypass flag: $cmd" 2; fi
  if [[ "$2" == */* ]]; then if [[ ! -d "${2%/*}" ]]; then mkdir -p "${2%/*}"; fi; fi
  isov; printf '# kcc-run %s harness %s\n# %s\n' "$ISO" "$HARNESS" "$cmd" > "$2"
  was="$PWD"; cd "$ROOT"
  if command -v timeout >/dev/null 2>&1; then
    timeout "${CFG_TIMEOUT}m" sh -c "$cmd" >> "$2" 2>&1 < /dev/null || rc=$?
  else
    sh -c "$cmd" >> "$2" 2>&1 < /dev/null || rc=$?
  fi
  cd "$was" 2>/dev/null || true
  if [[ $rc -eq 124 ]]; then printf '\n# kcc-run: harness timed out after %s minute(s)\n' "$CFG_TIMEOUT" >> "$2"; fi
  LAST_HARNESS_RC=$rc
  rel_v "$2"; R_last_log="$RV"
}
# ---- terminal / status output -----------------------------------------------------------------------------
status_json() { # $1 status
  local idx name="" spec="" gate="null" e
  idx="$(get_idx "$R_state")"
  if [[ "$idx" -ge 0 ]]; then name="${S_NAME[$idx]}"; if [[ "${S_SCOPE[$idx]}" != "run" ]]; then e="$(spec_entry_at "$R_spec_index")"; if [[ -n "$e" ]]; then spec="$(spec_id "${e#*/}")"; fi; fi; fi
  if [[ -n "$R_gate_id" ]]; then gate="{\"id\":\"$R_gate_id\",\"name\":\"$(jesc "$R_gate_name")\",\"answers\":[\"$(printf '%s' "$R_gate_answers" | sed 's#/#","#g')\"],\"file\":\"coordination/gates/$R_gate_id.md\"}"; fi
  printf '{"tool":"kcc-run","version":"%s","status":"%s","scenario":"%s","state":%s,"state_name":"%s","spec":"%s","wave":"%s","gate":%s,"log":"%s","reason":"%s","run_file":"coordination/run/run.json"}' \
    "$VERSION" "$1" "$R_scenario" "${R_state:-0}" "$name" "$spec" "$R_wave" "$gate" "$(jesc "$R_last_log")" "$(jesc "$R_reason")"
}
finish() { if [[ "$JSON" -eq 1 ]]; then status_json "$1"; echo; fi; exit "$2"; }
stop_run() { # $1 kind (aborted|stopped|env), $2 reason, $3 code
  R_reason="$2"
  if [[ "$1" == "aborted" ]]; then R_status=aborted; else R_status=stopped; fi
  save_run
  echo "kcc-run: $(printf '%s' "$R_status" | tr 'a-z' 'A-Z') - $2" >&2
  if [[ "$3" != "2" ]]; then emit session-closed "$R_idea" "{\"terminal\":\"$(printf '%s' "$R_status" | tr 'a-z' 'A-Z')\",\"reason\":\"$(jesc "$2")\",\"state\":${R_state:-0},\"source\":\"kcc-run\"}"; fi
  finish "$R_status" "$3"
}

# ---- gates --------------------------------------------------------------------------------------------------
next_gate_id() {
  local max=0 f n
  if [[ -d "$GATE_DIR" ]]; then
    for f in "$GATE_DIR"/GATE-*.md; do
      [[ -e "$f" ]] || continue
      n="$(basename "$f" .md | sed -n 's/^GATE-0*\([0-9][0-9]*\)$/\1/p')"
      if [[ -n "$n" && "$n" -gt "$max" ]]; then max="$n"; fi
    done
  fi
  printf 'GATE-%03d' $((max + 1))
}
show_pause() {
  local b="none" p="no" loc=""
  if [[ -n "$R_budget" ]]; then b="$R_budget $R_currency"; fi
  if [[ "$R_parallel" == "1" ]]; then p="yes"; fi
  if [[ -n "$R_gate_spec" ]]; then loc=" $R_gate_spec"; fi
  if [[ -n "$R_gate_wave" ]]; then loc="$loc wave $R_gate_wave"; fi
  say "kcc-run: PAUSED at state $R_gate_state$loc - gate $R_gate_name ($R_gate_id)"
  say "  scenario: $R_scenario  policy: accuracy $R_accuracy%, budget $b, parallel $p"
  say "  gate file: coordination/gates/$R_gate_id.md"
  if [[ -n "$R_last_log" ]]; then say "  last log: $R_last_log"; fi
  if [[ -n "$R_attempts" ]]; then say "  loop counters: $R_attempts"; fi
  say "  allowed answers: $(printf '%s' "$R_gate_answers" | sed 's#/# | #g')"
  say "  answer with: kcc-run.sh --answer <choice>   (PowerShell: kcc-run -Answer <choice>)"
}
OUTCOME=""
open_gate() { # $1 name, $2 kind, $3 question, $4 idx, $5 extra
  local name="$1" kind="$2" q="$3" i="$4" extra="${5:-}" answers gid a f ans_json
  answers="$(gate_answers "$name")"
  gid="$(next_gate_id)"
  mkdir -p "$GATE_DIR"
  f="$GATE_DIR/$gid.md"
  {
    printf -- '---\nid: %s\ngate: %s\nkind: %s\nstate: %s\nstate_name: %s\nspec: %s\nwave: %s\nscenario: %s\nstatus: open\nallowed_answers: %s\ncreated: %s\ntags:\n  - kcc/gate\n---\n\n' \
      "$gid" "$name" "$kind" "${S_ID[$i]}" "${S_NAME[$i]}" "$C_SPEC" "$C_WAVE" "$R_scenario" "$(printf '%s' "$answers" | sed 's#/# / #g')" "$(iso)"
    printf '# %s - %s\n\n## Question\n\n%s\n\n## Allowed answers\n\n' "$gid" "$name" "$q"
    local IFS='/'; for a in $answers; do printf -- '- `%s`\n' "$a"; done; unset IFS
    printf '\n## Context\n\n- coordination/run/run.json\n'
    if [[ -n "$R_last_log" ]]; then printf -- '- %s\n' "$R_last_log"; fi
    if [[ -n "$C_IDEA" ]]; then printf -- '- ideation/%s/\n' "$C_IDEA"; fi
    if [[ -n "$C_ENTRY" ]]; then printf -- '- %s/\n' "$(rel "$(spec_dir "$C_ENTRY")")"; fi
    if [[ -n "$extra" ]]; then printf '\n## Details\n\n%s\n' "$extra"; fi
    printf '\n## Answer\n\nRun `kcc-run -Answer <choice>` (bash: `kcc-run.sh --answer <choice>`).\n'
  } > "$f"
  ans_json="[\"$(printf '%s' "$answers" | sed 's#/#","#g')\"]"
  emit human-gate-triggered "$C_SPEC" "{\"gate\":\"$name\",\"gate_id\":\"$gid\",\"kind\":\"$kind\",\"state\":${S_ID[$i]},\"state_name\":\"${S_NAME[$i]}\",\"wave\":\"$C_WAVE\",\"reason\":\"$(jesc "$q")\",\"allowed_answers\":$ans_json,\"gate_file\":\"coordination/gates/$gid.md\",\"source\":\"kcc-run\"}" dash
  R_gate_id="$gid"; R_gate_name="$name"; R_gate_kind="$kind"; R_gate_answers="$answers"; R_gate_state="${S_ID[$i]}"
  R_gate_spec="$C_SPEC"; R_gate_wave="$C_WAVE"; R_gate_event="$EMIT_ID"; R_status=paused
  save_run
  if [[ "$R_silent" != "1" ]]; then show_pause; fi
  prompt_gate
}
prompt_gate() { # sets OUTCOME paused|answered
  OUTCOME=paused
  # A silent run has no human and never stops for one: every gate is answered by policy with the safest continuing choice
  # (policy_gate), recorded in the gate file, the human-gate-decision event (answered_by policy) and coordination/NeedsAttention.md.
  # A spec that cannot continue is left as an open item and the run goes on with the rest. A deferred check is never a pass.
  if [[ "$R_silent" == "1" ]]; then policy_gate; return 0; fi
  if [[ "$JSON" -eq 1 || "${KCC_RUN_NO_PROMPT:-}" == "1" ]]; then return 0; fi
  if [[ ! -t 0 || ! -t 1 ]]; then return 0; fi
  local a
  while true; do
    read -r -p "answer [$R_gate_answers]: " a || return 0
    case "/$R_gate_answers/" in *"/$a/"*) apply_answer "$a"; OUTCOME=answered; return 0 ;; esac
    say "  not an allowed answer: $a"
  done
}
# ---- needs attention: a silent run never stops for a human -----------------------------------------------------
# Under --silent --assume every gate is answered by policy (policy_gate) and the decision is recorded in
# coordination/NeedsAttention.md (one section per item). status 'decided' = the run went on, check the decision;
# status 'open' = the spec had to be left and a human must act. Exit code 7 = the run ended with open items.
ATTN_FILE="$COORD/NeedsAttention.md"
ANSWERED_BY=human
ONLY_ON=0
DISPATCH_NO=0
flat_v() { local s="${1:-}"; s="${s//$'\r'/ }"; s="${s//$'\n'/ }"; s="${s//$'\t'/ }"; while [[ "$s" == *"  "* ]]; do s="${s//  / }"; done; s="${s# }"; RV="${s% }"; }
flat() { flat_v "${1:-}"; printf '%s' "$RV"; }
lane_name() { case "$ROOT" in */.kcc-lanes/*) printf '%s' "${ROOT##*/}" ;; esac; }
ATTN_ITEMS=0; ATTN_OPEN=0
attention_counts() {
  ATTN_ITEMS=0; ATTN_OPEN=0
  if [[ -f "$ATTN_FILE" ]]; then
    local l
    while IFS= read -r l || [[ -n "$l" ]]; do
      case "$l" in "## [open]"*) ATTN_ITEMS=$((ATTN_ITEMS + 1)); ATTN_OPEN=$((ATTN_OPEN + 1)) ;; "## [decided]"*) ATTN_ITEMS=$((ATTN_ITEMS + 1)) ;; esac
    done < "$ATTN_FILE"
  fi
}
show_attention() { attention_counts; if [[ "$ATTN_ITEMS" -gt 0 ]]; then say "kcc-run: needs attention: $(rel "$ATTN_FILE") - $ATTN_ITEMS item(s), $ATTN_OPEN open"; fi; }
add_attention() { # spec idx gate status decided why todo links
  local spec="$1" i="$2" gate="$3" status="$4" decided="$5" why="$6" todo="$7" links="$8" when stl="" who
  if [[ "$DRY" -eq 1 ]]; then return 0; fi
  isov; when="$ISO"; if [[ "$i" -ge 0 ]]; then stl="${S_ID[$i]} ${S_NAME[$i]}"; fi
  who="${spec:-run}"
  [[ -d "$COORD" ]] || mkdir -p "$COORD"
  local f_dec f_why f_todo f_links
  flat_v "$decided"; f_dec="$RV"; flat_v "$why"; f_why="$RV"; flat_v "$todo"; f_todo="$RV"; flat_v "$links"; f_links="$RV"
  if [[ ! -f "$ATTN_FILE" ]]; then
    printf '# Needs attention\n\nWritten by kcc-run under --silent --assume, which never stops for a human: every gate is answered by policy and recorded here.\n\n- status: decided = the run went on with the safest continuing choice; check the decision.\n- status: open = the spec could not continue and was left; a human must act (the run finished everything else, exit code 7).\n\n' > "$ATTN_FILE"
  fi
  printf '## [%s] %s | %s | state %s | %s\n\n- when: %s\n- spec: %s\n- state: %s\n- gate: %s\n- status: %s\n- decided: %s\n- why: %s\n- todo: %s\n- links: %s\n\n' \
    "$status" "$who" "$gate" "$stl" "$when" "$when" "$who" "$stl" "$gate" "$status" "$f_dec" "$f_why" "$f_todo" "$f_links" >> "$ATTN_FILE"
  local sid=0 sname="" j_gate j_dec j_why j_todo a_rel; if [[ "$i" -ge 0 ]]; then sid="${S_ID[$i]}"; sname="${S_NAME[$i]}"; fi
  jescv "$gate"; j_gate="$JE"; jescv "$f_dec"; j_dec="$JE"; jescv "$f_why"; j_why="$JE"; jescv "$f_todo"; j_todo="$JE"; rel_v "$ATTN_FILE"; a_rel="$RV"
  emit needs-attention "$spec" "{\"state\":$sid,\"state_name\":\"$sname\",\"gate\":\"$j_gate\",\"status\":\"$status\",\"decided\":\"$j_dec\",\"reason\":\"$j_why\",\"todo\":\"$j_todo\",\"file\":\"$a_rel\",\"source\":\"kcc-run\"}"
}
resume_hint() { # spec stateId
  local from="" lane; if [[ -n "${2:-}" ]]; then from=" --from $2"; fi
  lane="$(lane_name)"
  if [[ -n "$lane" ]]; then printf 'fix the cause, then: kcc run --lane %s%s ; kcc run --resume' "$lane" "$from"
  else printf 'fix the cause, then: kcc-run%s (kcc-run --resume continues)' "$from"; fi
}
# The unit cannot go on and a silent run does not wait: record it as open, then move to the next spec (a bare multi-spec run),
# stop here with exit 7 (a lane, --until or --only run), or on to the states after the per-spec ones (last spec of a bare run).
block_unit() { # idx spec gate why todo links
  local i="$1" spec="$2" gate="$3" why="$4" todo="$5" links="$6" key is_spec=0
  key="${S_ID[$i]}"; if [[ -n "$spec" ]]; then key="$key:$spec"; fi
  set_att "$key" 0; if [[ -n "$R_wave" ]]; then set_att "$key:$R_wave" 0; fi
  if [[ -n "$spec" ]]; then set_att "cap:$spec" 0; fi
  add_attention "$spec" "$i" "$gate" open "the spec was left (needs attention); the run goes on with whatever else can run" "$why" "$todo" "$links"
  R_last_violations=""; R_pending_action=""
  if [[ -n "$spec" && "${S_SCOPE[$i]}" != "run" ]]; then is_spec=1; fi
  if [[ $is_spec -eq 1 && $((R_spec_index + 1)) -lt $(spec_count) && $ONLY_ON -eq 0 ]]; then
    R_spec_index=$((R_spec_index + 1)); R_state="${S_ID[$SPEC_FIRST]}"; R_wave=""; R_force=""
    say "kcc-run: NEEDS ATTENTION $spec ($gate): $(flat "$why") - continuing with the next spec"
    save_run
    return 0
  fi
  if [[ $is_spec -eq 0 || -n "$UNTIL" || $ONLY_ON -eq 1 ]]; then
    R_status=stopped; R_reason="needs attention: ${spec:+$spec }$gate at state ${S_ID[$i]} ${S_NAME[$i]}"
    save_run
    say "kcc-run: NEEDS ATTENTION $spec ($gate): $(flat "$why")"
    show_attention
    finish needs-attention 7
  fi
  R_wave=""; R_force=""
  if [[ $((SPEC_LAST + 1)) -lt $S_COUNT ]]; then R_state="${S_ID[$((SPEC_LAST + 1))]}"; else R_state=-1; fi
  say "kcc-run: NEEDS ATTENTION $spec ($gate): $(flat "$why") - moving on"
  save_run
}
close_gate_by_policy() { # answer note
  local gid="$R_gate_id" gname="$R_gate_name" gf="$GATE_DIR/$R_gate_id.md"
  if [[ -f "$gf" ]]; then
    sed -i.bak "s/^status: open\$/status: answered\\
answer: $1\\
answered: $(iso)/" "$gf" && rm -f "$gf.bak"
    printf '\n## Decision\n\n- %s: `%s` (kcc-run, policy: silent run) - %s\n' "$(iso)" "$1" "$2" >> "$gf"
  fi
  emit human-gate-decision "$R_gate_spec" "{\"gate\":\"$gname\",\"gate_id\":\"$gid\",\"answer\":\"$1\",\"answered_by\":\"policy\",\"state\":${R_gate_state:-0},\"wave\":\"$R_gate_wave\",\"trigger_event_id\":\"$R_gate_event\",\"note\":\"$(jesc "$2")\",\"source\":\"kcc-run\"}" dash
  R_gate_id=""; R_gate_name=""; R_gate_kind=""; R_gate_answers=""; R_gate_event=""
  R_status=running; R_pending_action=""
  save_run
}
policy_gate() { # sets OUTCOME answered
  local g="$R_gate_name" gid="$R_gate_id" gspec="$R_gate_spec" sidx why ans="" note="" decided="" todo="" links reason n tools prev_note
  sidx="$(get_idx "$R_gate_state")"
  why="$(flat "$R_last_violations")"
  links="coordination/gates/$gid.md"; if [[ -n "$R_last_log" ]]; then links="$links, $R_last_log"; fi
  case "$g" in
    quality-deferred-on-exit-3)
      ans=accept-deferred
      note="silent run: deferred quality check accepted by policy (not a pass); install the missing tool and re-run the gate to close it"
      decided="accepted the deferred check by policy (not a pass)"
      tools="$(viol_tools "$why")"
      todo="install the missing tool${tools:+ ($tools)} and re-run the quality gate: .KCC/tools/quality-gate --spec ${gspec:-SPEC-ID}" ;;
    waiver)
      ans=waive
      note="silent run: the code is done and what keeps the gate red needs an environment fix or a human waiver; closed as WAIVER_NEEDED by policy (not a pass)"
      decided="closed the spec as WAIVER_NEEDED by policy (not a pass): the code is done, the remaining gate items need an environment fix or your waiver"
      todo="fix the environment (or record a waiver in review.md -> ## Waivers), then run the verification again: $(resume_hint "$gspec" "$(test_state_id)")" ;;
    toolchain)
      ans=defer
      note="silent run: toolchain missing -> defer (the declared-stack code is written, build and test are marked TOOLCHAIN_DEFERRED, never a pass)"
      decided="deferred the missing toolchain by policy (TOOLCHAIN_DEFERRED, not a pass)"
      todo="install the missing toolchain ($(viol_tools "$why")) and re-run the TEST state for $gspec" ;;
    roi-gate)
      ans=proceed
      note="silent run: ROI confidence is below the minimum or not recorded; proceeding on the recorded assumption"
      decided="proceeded despite low or missing ROI confidence"
      todo="review ideation/$R_idea/ROI.md and decide whether the idea is worth building" ;;
    repo-bootstrap)
      ans=skip
      note="silent run: no usable git repository; skipped the bootstrap (no repository was created or changed)"
      decided="skipped repo-bootstrap"
      todo="run .KCC/tools/repo-bootstrap to create the repository and the protected-main workflow" ;;
    confirm) ans=confirm; note="silent run: interrogation answers confirmed as assumed"; decided="confirmed the assumed answers"; todo="review the assumptions recorded in ideation/$R_idea/Assumptions.md" ;;
    budget) ans=approve; note="silent run: estimate approved by policy"; decided="approved the estimate"; todo="compare the estimate with the actual cost" ;;
    windows) ans=sequential; note="silent run: parallel windows not approved, running sequentially"; decided="ran sequentially"; todo="none unless parallel windows are wanted" ;;
    ruling)
      n="$(get_att "ruled:$gspec")"
      if [[ "$n" -lt 2 ]]; then
        set_att "ruled:$gspec" $((n + 1))
        ans=revise
        note="silent run: no human ruling; apply the recommended option of the Ruling needed section of each reopened Bug item"
        decided="applied the recommended option of the ruling (as revise, ruling $((n + 1)) of 2 allowed by policy)"
        todo="check that the Bug file(s) under Backlog/ and the Ruling section show the recommended option, and that it is acceptable (an architect-owned change such as a Decisions-table edit needs your approval)"
      fi ;;
  esac
  if [[ -n "$ans" ]]; then
    prev_note="$NOTE"; NOTE="$note"; ANSWERED_BY=policy
    say "kcc-run: silent run, gate $g answered by policy: $ans"
    apply_answer "$ans"
    ANSWERED_BY=human; NOTE="$prev_note"
    add_attention "$gspec" "$sidx" "$g" decided "$decided" "${why:-$note}" "$todo" "$links"
    OUTCOME=answered; return 0
  fi
  # No safe continuing answer: the spec (or the run) is left and recorded as open.
  reason="$why"
  case "$g" in
    loop) reason="retry limit reached (CR-3): ${reason:-the exit check kept failing}" ;;
    budget-cap) reason="the estimate exceeds the budget cap and a silent run does not raise it: $reason" ;;
    ruling) reason="the automatic rulings allowed per spec (2) are used up and the bug is blocked again: $reason" ;;
  esac
  todo="$(resume_hint "$gspec" "${S_ID[$sidx]}")"
  if [[ "$g" == "budget-cap" ]]; then todo="raise the cap or cut the scope, then: kcc-run --answer increase --budget NN, or re-run with a larger --budget"; fi
  close_gate_by_policy needs-attention "silent run: stopped retrying. $reason"
  block_unit "$sidx" "$gspec" "$g" "$reason" "$todo" "$links"
  OUTCOME=answered
}
# ---- deferred checks: accepted, never a pass ------------------------------------------------------------------
viol_tools() { printf '%s' "${1:-}" | sed -nE 's/.*missing tools?:[[:space:]]*(.*)$/\1/p' | sed -E 's/(\. |;).*$//' | head -n 1; }
last_missing_tools() { # spec -> tools named in the newest quality-gate output for it
  local f; f="$(ls -t "$LOG_DIR"/check-*"$(safe_name "$1")"*-quality-gate.out 2>/dev/null | head -n 1 || true)"
  [[ -n "$f" ]] || return 0
  tr -d '\r\n' < "$f" | sed -nE 's/.*"missing_tools"[[:space:]]*:[[:space:]]*\[([^]]*)\].*/\1/p' | tr -d '"' | sed -E 's/[[:space:]]*,[[:space:]]*/, /g'
}
# Records that the human (or the silent policy) accepted a deferred external tool for this spec: REVIEW then closes the spec as
# deferred-accepted instead of looping through FIX and another full test pass.
register_deferral() { # spec idx gate by
  local spec="$1" i="$2" gate="$3" by="$4" tools checks="" verdict=QUALITY_DEFERRED
  [[ -n "$spec" ]] || return 0
  tools="$(viol_tools "$R_last_violations")"
  if [[ -z "$tools" ]]; then tools="$(last_missing_tools "$spec")"; fi
  if printf '%s' "$R_last_violations" | grep -q 'TOOLCHAIN_DEFERRED' || [[ "$gate" == "toolchain" ]]; then verdict=TOOLCHAIN_DEFERRED; fi
  checks="$(printf '%s' "$R_last_violations" | sed -nE 's/.*deferred checks?[[:space:]]+([A-Z0-9, -]+)(,[[:space:]]*not a pass|\.|;).*/\1/p' | head -n 1)"
  if [[ "$gate" == "waiver" ]]; then verdict=WAIVER_NEEDED; tools=""; gate_owner_summary "$spec"; checks="$GATE_ITEMS"; fi
  set_att "defer:$spec" 1
  emit deferral-accepted "$spec" "{\"state\":${S_ID[$i]},\"state_name\":\"${S_NAME[$i]}\",\"gate\":\"$gate\",\"verdict\":\"$verdict\",\"by\":\"$by\",\"tools\":\"$(jesc "$tools")\",\"checks\":\"$(jesc "$(flat "$checks")")\",\"source\":\"kcc-run\"}"
}
deferred_items() { # one line per accepted deferral of this run's specs: spec<TAB>tools<TAB>checks<TAB>verdict
  local bc="$COORD/backchannel.jsonl" mine="" e line sp tl ck vd
  [[ -f "$bc" ]] || return 0
  for e in $R_specs; do mine="$mine $(spec_id "${e#*/}")"; done
  { grep '"kind"[[:space:]]*:[[:space:]]*"deferral-accepted"' "$bc" 2>/dev/null || true; } | while IFS= read -r line; do
    sp="$(printf '%s' "$line" | sed -nE 's/.*"spec"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/p')"
    if [[ -n "$mine" ]]; then case "$mine " in *" $sp "*) ;; *) continue ;; esac; fi
    tl="$(printf '%s' "$line" | sed -nE 's/.*"tools"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/p')"
    ck="$(printf '%s' "$line" | sed -nE 's/.*"checks"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/p')"
    vd="$(printf '%s' "$line" | sed -nE 's/.*"verdict"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/p')"
    printf '%s\t%s\t%s\t%s\n' "$sp" "${tl:--}" "${ck:--}" "${vd:--}"
  done | awk -F'\t' '!seen[$1 "|" $2 "|" $4]++'
}
unmark() { if [[ "$1" == "-" ]]; then printf ''; else printf '%s' "$1"; fi; }
deferral_lines() { # spec tools checks verdict
  local sp="${1:-SPEC-ID}" t="$2" c="" tl
  if [[ "${4:-}" == "WAIVER_NEEDED" ]]; then
    printf 'WAIVER NEEDED, NOT A PASS - %s: the code is done; these gate items need an environment fix or your waiver: %s\n' "$sp" "${3:-see review.md -> Verdict}"
    printf '  fix the environment or record the waiver in review.md -> ## Waivers, then run the verification again: kcc-run --from %s   |   kcc run --lane %s\n' "$(test_state_id)" "$sp"
    return 0
  fi
  if [[ -z "$t" ]]; then
    printf 'DEFERRED, NOT A PASS - %s%s: a check could not run on this machine (a tool or service the tests need is unusable here; see review.md -> Test Status and Quality Gate Check).\n' "$sp" "${3:+ ($3 not run)}"
    printf '  fix the environment, then re-run the verification: kcc-run --from %s   |   kcc run --lane %s\n' "$(test_state_id)" "$sp"
    return 0
  fi
  if [[ -n "$3" ]]; then c=" ($3 not run)"; fi
  tl="$(printf '%s' "$2" | sed -E 's/,[[:space:]]*/,/g')"; if [[ -z "$tl" ]]; then tl='<tool>'; fi
  printf 'DEFERRED, NOT A PASS - %s%s: missing tool(s) %s.\n' "$sp" "$c" "$t"
  printf '  install (human-gated): powershell -ExecutionPolicy Bypass -File .KCC\\tools\\toolchain-preflight.ps1 -Tools %s   |   bash .KCC/tools/toolchain-preflight.sh %s\n' "$tl" "$(printf '%s' "$tl" | tr ',' ' ')"
  printf '  then re-run the gate : powershell -ExecutionPolicy Bypass -File .KCC\\tools\\quality-gate.ps1 -Spec %s   |   bash .KCC/tools/quality-gate.sh --spec %s\n' "$sp" "$sp"
}
show_deferred() {
  local sp tl ck vd ln
  while IFS=$'\t' read -r sp tl ck vd; do
    tl="$(unmark "$tl")"; ck="$(unmark "$ck")"; vd="$(unmark "$vd")"
    [[ -n "$sp$tl" ]] || continue
    while IFS= read -r ln; do say "kcc-run: $ln"; done < <(deferral_lines "$sp" "$tl" "$ck" "$vd")
  done < <(deferred_items)
}
add_closed_deferred() {
  local f="$RUN_DIR/closed.md" sp tl ck vd ln n=0 out=""
  [[ -f "$f" ]] || return 0
  if grep -q '<!-- kcc-run:deferred -->' "$f"; then return 0; fi
  attention_counts
  while IFS=$'\t' read -r sp tl ck vd; do
    tl="$(unmark "$tl")"; ck="$(unmark "$ck")"; vd="$(unmark "$vd")"
    [[ -n "$sp$tl" ]] || continue
    n=$((n + 1))
    while IFS= read -r ln; do out="$out- $(printf '%s' "$ln" | sed 's/^ *//')"$'\n'; done < <(deferral_lines "$sp" "$tl" "$ck" "$vd")
  done < <(deferred_items)
  if [[ $n -eq 0 && "$ATTN_ITEMS" -eq 0 ]]; then return 0; fi
  { printf '\n<!-- kcc-run:deferred -->\n'
    if [[ $n -gt 0 ]]; then printf '## Deferred checks (NOT a pass)\n\n%s' "$out"; fi
    if [[ "$ATTN_ITEMS" -gt 0 ]]; then printf '\n## Needs attention\n\n- %s: %s item(s), %s open\n' "$(rel "$ATTN_FILE")" "$ATTN_ITEMS" "$ATTN_OPEN"; fi
  } >> "$f"
}
ruling_gate() { # $1 idx: opens the ruling gate for the blocked Bug items of the last run_check (CHK_BLOCKED); no attempt is used
  local i="$1" d="" k bf q sd; sd="$(spec_dir "$C_ENTRY")/Backlog"
  for k in $CHK_BLOCKED; do
    bf="$(ls "$sd"/$k-*.md "$sd"/$k.md 2>/dev/null | head -n 1 || true)"
    d="${d}${d:+$'\n\n'}- $k ($(rel "$bf")): $(ruling_text "$bf")"
  done
  q="Bug item(s) ${CHK_BLOCKED// /, } of $C_SPEC are blocked: the fix cannot proceed without a human ruling, so the implementer is not run again and no attempt is used. Read each '## Ruling needed' section (the options and the recommended one), then answer: revise (retry the fix with your ruling; give it with --note, without a note the recommended option applies), waive (record the bug as wontfix, a human decision), escalate (reopen it and retry, recorded as an escalation), or abort. A silent run never answers this gate itself."
  open_gate ruling ruling "$q" "$i" "$d"
}
rule_bugs() { # $1 answer: applies the human's ruling to every blocked Bug item of the gate's spec (revise|escalate -> open, waive -> wontfix) and records it in the bug file
  local ans="$1" ent bf st new d
  ent="$(spec_entry_at "$R_spec_index")"; [[ -n "$ent" ]] || return 0
  d="$(spec_dir "$ent")/Backlog"; [[ -d "$d" ]] || return 0
  if [[ "$ans" == "waive" ]]; then new=wontfix; else new=open; fi
  for bf in "$d"/Bug-*.md; do
    [[ -f "$bf" ]] || continue
    st="$(bug_status_of "$bf")"; [[ "$st" == "blocked" ]] || continue
    set_bug_status "$bf" "$new"
    printf '\n## Ruling\n\n- %s human: `%s` -> Status %s%s\n' "$(iso)" "$ans" "$new" "${NOTE:+ - $NOTE}" >> "$bf"
  done
}
prev_cmd_state() { local j; for ((j = $1 - 1; j >= 0; j--)); do if [[ -n "${S_CMD[$j]}" ]]; then echo "$j"; return 0; fi; done; echo "$1"; }
apply_answer() {
  local ans gname gid idx pa key gf sp orch sess hd
  if [[ -z "$R_gate_id" ]]; then fail_usage "no pending gate to answer"; fi
  ans="$(printf '%s' "$1" | tr 'A-Z' 'a-z')"
  case "/$R_gate_answers/" in *"/$ans/"*) ;; *) fail_usage "'$1' is not an allowed answer for gate $R_gate_name ($(printf '%s' "$R_gate_answers" | sed 's#/# | #g'))" ;; esac
  gname="$R_gate_name"; gid="$R_gate_id"; idx="$(get_idx "$R_gate_state")"
  gf="$GATE_DIR/$gid.md"
  if [[ -f "$gf" ]]; then
    sed -i.bak "s/^status: open\$/status: answered\\
answer: $ans\\
answered: $(iso)/" "$gf" && rm -f "$gf.bak"
    printf '\n## Decision\n\n- %s: `%s` (kcc-run)%s\n' "$(iso)" "$ans" "${NOTE:+ - $NOTE}" >> "$gf"
  fi
  emit human-gate-decision "$R_gate_spec" "{\"gate\":\"$gname\",\"gate_id\":\"$gid\",\"answer\":\"$ans\",\"answered_by\":\"$ANSWERED_BY\",\"state\":${R_gate_state:-0},\"wave\":\"$R_gate_wave\",\"trigger_event_id\":\"$R_gate_event\",\"note\":\"$(jesc "$NOTE")\",\"source\":\"kcc-run\"}" dash
  orch="$COORD/orchestrator.json"
  if [[ -f "$orch" ]]; then
    sess="$(sed -n 's/.*"active_session"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$orch" | head -1 || true)"
    hd="$ROOT/$sess/HumanDecisions.md"
    if [[ -n "$sess" && -f "$hd" ]]; then printf '\n- %s kcc-run %s gate `%s` state %s %s: **%s**%s\n' "$(iso)" "$gid" "$gname" "$R_gate_state" "$R_gate_spec" "$ans" "${NOTE:+ - $NOTE}" >> "$hd"; fi
  fi
  if [[ -n "$NOTE" ]]; then R_note="$NOTE"; fi
  key="$R_gate_state"; if [[ -n "$R_gate_spec" ]]; then key="$key:$R_gate_spec"; fi; if [[ -n "$R_gate_wave" ]]; then key="$key:$R_gate_wave"; fi
  pa=recheck
  if [[ "$ans" == "abort" ]]; then pa=abort
  else
    case "$gname" in
      repo-bootstrap)
        local ra=(-Apply "$ans" -Emit)
        if [[ "$ans" == "connect-remote" ]]; then if [[ -z "$REMOTE_URL" ]]; then fail_usage "connect-remote needs --remote-url <url>"; fi; ra+=(-RemoteUrl "$REMOTE_URL"); fi
        run_tool repo-bootstrap "$LOG_DIR/repo-bootstrap-apply.out" "${ra[@]}"
        say "kcc-run: repo-bootstrap --apply $ans exited $TOOL_RC"; pa=recheck ;;
      roi-gate) if [[ "$ans" == "proceed" ]]; then pa=done; else pa="goto:${S_ID[$(prev_cmd_state "$idx")]}"; fi ;;
      confirm) if [[ "$ans" == "confirm" ]]; then pa=done; else pa="goto:${S_ID[$(prev_cmd_state "$idx")]}"; fi ;;
      budget)
        if [[ "$ans" == "approve" ]]; then
          sp="$R_gate_spec"; local scope=implement; if [[ -z "$sp" ]]; then sp="$R_idea"; scope=idea; fi
          emit estimate-approved "$sp" "{\"state\":${R_gate_state:-0},\"gate_id\":\"$gid\",\"scope\":\"$scope\",\"approved_by\":\"human\",\"source\":\"kcc-run\"}"
          pa=approved
        else pa=rerun; fi ;;
      budget-cap)
        if [[ "$ans" == "increase" ]]; then if [[ -z "$BUDGET" ]]; then fail_usage "increase needs --budget <amount>"; fi; R_budget="$BUDGET"; R_scenario=S3; pa=gatecheck; else pa=rerun; fi ;;
      windows) if [[ "$ans" == "sequential" ]]; then R_sequential=1; fi; pa=done ;;
      toolchain)
        if [[ "$ans" == "install" ]]; then pa=install
        elif [[ "$ans" == "defer" ]]; then emit toolchain-gate-decision "$R_gate_spec" '{"choice":"defer","verdict":"TOOLCHAIN_DEFERRED","source":"kcc-run"}'; pa=done; register_deferral "$R_gate_spec" "$idx" toolchain "$ANSWERED_BY"
        else pa=recheck; fi ;;
      quality-deferred-on-exit-3) if [[ "$ans" == "install" ]]; then pa=install; else pa=done; register_deferral "$R_gate_spec" "$idx" quality-deferred-on-exit-3 "$ANSWERED_BY"; fi ;;
      waiver)
        # waive: the spec closes as WAIVER_NEEDED (recorded like a deferral, never a pass) and the run goes on; recheck: the human
        # changed the environment, so the verification runs again (scoped) and the review after it.
        if [[ "$ans" == "waive" ]]; then pa=done; register_deferral "$R_gate_spec" "$idx" waiver "$ANSWERED_BY"
        else pa="goto:$(test_state_id)"; set_att "$key" 0; fi ;;
      ruling)
        # revise and escalate reopen the blocked bugs and re-run the fix with the ruling as the note; waive records them as wontfix
        if [[ "$ans" == "waive" ]]; then pa=recheck; else
          pa=rerun; set_att "$key" 0
          if [[ "$ANSWERED_BY" == "policy" ]]; then R_note="no human is available (silent run): ruling by policy ($ans): apply the recommended option of the Ruling needed section of each reopened Bug item, then set its Status to fixed"
          elif [[ -z "$NOTE" ]]; then R_note="the human answered $ans without a note: apply the recommended option of the Ruling needed section of each reopened Bug item, then set its Status to fixed"
          else R_note="human ruling ($ans): $NOTE. Follow it for the reopened Bug items, then set their Status to fixed"; fi
        fi
        rule_bugs "$ans"; R_last_violations="" ;;
      loop)
        set_att "$key" 0; pa=rerun
        # the pass-cap gate (a third full verifier pass): the human's revise or escalate grants exactly one more full pass
        if [[ -n "$R_gate_spec" && "$(get_att "cap:$R_gate_spec")" != "0" ]]; then set_att "cap:$R_gate_spec" 0; set_att "full:$R_gate_spec" $((VERIFY_FULL_MAX - 1)); fi ;;
      *) pa=recheck ;;
    esac
  fi
  R_pending_action="$pa"
  R_gate_id=""; R_gate_name=""; R_gate_kind=""; R_gate_answers=""; R_gate_event=""
  R_status=running
  save_run
  say "kcc-run: $gid answered $ans -> $pa"
  if [[ "$pa" == "abort" ]]; then stop_run aborted "human chose abort at $gid ($gname)" 6; fi
}

# ---- budget -------------------------------------------------------------------------------------------------
latest_estimate() {
  local f="$COORD/backchannel.jsonl" line
  [[ -f "$f" ]] || return 0
  line="$(tail -n 400 "$f" | grep '"kind"[[:space:]]*:[[:space:]]*"estimate-issued"' | grep -v '"from"[[:space:]]*:[[:space:]]*"kcc-run"' | tail -n 1 || true)"
  printf '%s' "$line" | sed -nE 's/.*"(cost_total_usd|total_cost_usd|estimate_usd|cost_usd|total_usd|amount|cost)"[[:space:]]*:[[:space:]]*"?([0-9]+(\.[0-9]+)?).*/\2/p' | head -1
}

# ---- checkpoints / limit ------------------------------------------------------------------------------------
invoke_checkpoint() { # $1 reason, $2 next action
  if [[ "$DRY" -eq 1 ]]; then return 0; fi
  run_tool kcc-checkpoint "$LOG_DIR/checkpoint-$1.out" -Reason "$1" -Harness "$HARNESS" -NextAction "$2"
  if [[ "$TOOL_RC" -ne 0 ]]; then say "kcc-run: warning: kcc-checkpoint --reason $1 exited $TOOL_RC"; fi
}
suspend_run() { # $1 idx, $2 log
  local i="$1" reset label resume_cmd armout a
  reset="$(reset_epoch "$2")"
  label="$(unit_label "$i")"
  invoke_checkpoint limit-hard "Run kcc-run --resume ($label)"
  resume_cmd="bash $(squote "$SELF") --resume --repo-root $(squote "$ROOT")"
  a=(--arm --harness "$HARNESS" --repo-root "$ROOT" --command "$resume_cmd")
  if [[ -n "$reset" ]]; then a+=(--reset-at "$reset"); fi
  printf '{"harness":"%s","source":"kcc-run","at":%s,"resets_at":%s,"resume_at":null,"resumes":0,"status":"waiting"}\n' "$HARNESS" "$(date +%s)" "${reset:-null}" > "$RUN_DIR/limit.json"
  # KCC_SUPERVISED=1: 'kcc run' owns the wait and the resume, so no detached watcher is armed.
  if [[ "${KCC_SUPERVISED:-}" == "1" ]]; then armout="supervised by kcc run; watcher not armed"
  else armout="$( (cd "$ROOT" && bash "$TOOLS/kcc-limit-watch.sh" "${a[@]}") 2>/dev/null < /dev/null | tr '\n' ' ' || true)"; fi
  printf '%s\n' "$armout" > "$LOG_DIR/limit-watch-arm.out"
  emit limit-reached "$C_SPEC" "{\"level\":\"hard\",\"harness\":\"$HARNESS\",\"source\":\"kcc-run\",\"state\":${S_ID[$i]},\"wave\":\"$C_WAVE\",\"resets_at\":${reset:-null},\"log\":\"$(jesc "$R_last_log")\"}"
  R_status=suspended; R_reason="usage limit reached during $label"
  save_run
  say "kcc-run: SUSPENDED - usage limit reached during $label; restore point written, kcc-limit-watch armed ($armout)"
  finish suspended 5
}

# ---- unit processing ---------------------------------------------------------------------------------------------
detect_idea() {
  if [[ -n "$R_idea" ]]; then return 0; fi
  local f pick="" best=-1 n
  for f in $(idea_folders); do
    if in_list "$f" "$R_ideas_before"; then continue; fi
    n="$(idea_num "$f")"; n="${n:-0}"
    if [[ "$n" -gt "$best" ]]; then best="$n"; pick="$f"; fi
  done
  if [[ -n "$pick" ]]; then R_idea="$pick"; say "kcc-run: idea detected: $pick"; fi
}
load_specs() {
  if [[ -z "$R_idea" ]]; then return 0; fi
  local list; list="$(specs_from_roadmap "$R_idea" | tr '\n' ' ' | sed 's/ *$//')"
  if [[ -n "$list" ]]; then R_specs="$list"; fi
}
# ---- dashboard: opened once per run, only with the human's permission -----------------------
# Permission: --open-dashboard / --no-open-dashboard, else settings dashboard.auto_open (yes | no | ask).
# `ask` prompts on a terminal and records always/never; with no terminal nothing is opened and a hint is printed.
save_dashboard_mode() { # yes|no -> settings.json
  local sp="$ROOT/.KCC/settings.json" t
  [[ -f "$sp" ]] || return 0
  t="$(cat "$sp")"
  if printf '%s' "$t" | grep -q '"auto_open"[[:space:]]*:'; then
    printf '%s\n' "$t" | sed -E "s/(\"auto_open\"[[:space:]]*:[[:space:]]*\")[^\"]*(\")/\1$1\2/" > "$sp.tmp" && mv -f "$sp.tmp" "$sp"
  elif printf '%s' "$t" | grep -q '"dashboard"[[:space:]]*:[[:space:]]*{'; then
    printf '%s\n' "$t" | sed -E "s/(\"dashboard\"[[:space:]]*:[[:space:]]*\{)/\1 \"auto_open\": \"$1\",/" > "$sp.tmp" && mv -f "$sp.tmp" "$sp"
  else
    printf '%s\n' "$t" | awk -v m="$1" '{ lines[NR] = $0 } END { for (i = NR; i > 0; i--) if (lines[i] ~ /\}[[:space:]]*$/) { last = i; break }; for (i = 1; i <= NR; i++) { if (i == last) { sub(/\}[[:space:]]*$/, "", lines[i]); print lines[i] ","; print "  \"dashboard\": { \"auto_open\": \"" m "\" }"; print "}" } else print lines[i] } }' > "$sp.tmp" && mv -f "$sp.tmp" "$sp"
  fi
}
resolve_dashboard_open() { # prints yes | no | ask
  local mode ans="${KCC_DASHBOARD_ANSWER:-}"
  if [[ $NO_OPEN_DASH -eq 1 ]]; then echo no; return 0; fi
  if [[ $OPEN_DASH -eq 1 ]]; then echo yes; return 0; fi
  mode="$(setting dashboard.auto_open ask | tr 'A-Z' 'a-z')"
  if [[ "$mode" == "yes" || "$mode" == "no" ]]; then echo "$mode"; return 0; fi
  # --silent means nobody answers prompts: a silent run never asks, even on a terminal.
  if [[ -z "$ans" && -t 0 && -t 1 && $JSON -eq 0 && $SILENT -eq 0 ]]; then
    echo "kcc-run: open the live dashboard in your browser? It follows this run and reads only local files." >&2
    read -r -p "  [y]es now / [n]o / [a]lways / ne[v]er (saved in .KCC/settings.json -> dashboard.auto_open) " ans || ans=""
  fi
  [[ -n "$ans" ]] || { echo ask; return 0; }
  case "$(printf '%s' "$ans" | tr 'A-Z' 'a-z')" in
    y|yes|open) echo yes ;;
    a|always) save_dashboard_mode yes; echo yes ;;
    v|never) save_dashboard_mode no; echo no ;;
    *) echo no ;;
  esac
}
offer_dashboard() { # $1 = 1 for a new run
  local d
  if [[ "$DRY" -eq 1 || -n "$R_dashboard_opened" ]]; then return 0; fi
  d="$(resolve_dashboard_open)"
  if [[ "$d" == "no" ]]; then R_dashboard_opened=declined; return 0; fi
  if [[ "$d" == "ask" ]]; then
    if [[ "$1" == "1" ]]; then say 'kcc-run: dashboard not opened (no permission recorded). Open it with: kcc run --open-dashboard, or set .KCC/settings.json -> dashboard.auto_open to "yes".'; fi
    return 0
  fi
  [[ -f "$TOOLS/build-dashboard.sh" ]] || return 0
  if bash "$TOOLS/build-dashboard.sh" --repo-root "$ROOT" --open >/dev/null 2>&1; then R_dashboard_opened=1; say 'kcc-run: dashboard opened (dashboard/index.html); it refreshes as the run progresses'; else say 'kcc-run: could not open the dashboard'; fi
}
refresh_dashboard() { # best-effort, never stops the run
  [[ "$DRY" -eq 1 || "${KCC_SKIP_DASHBOARD:-}" == "1" || ! -f "$TOOLS/build-dashboard.sh" ]] && return 0
  bash "$TOOLS/build-dashboard.sh" --repo-root "$ROOT" >/dev/null 2>&1 || true
}
complete_unit() { # $1 idx, $2 skipped (1/0)
  local i="$1" key kind sp cp label skipped=false
  unit_key_v "$i"; key="$RV"; unit_label_v "$i"; label="$RV"
  kind="${S_EV[$i]:-run-state-completed}"
  sp="${C_SPEC:-$C_IDEA}"
  if [[ "$2" == "1" ]]; then skipped=true; fi
  get_att_v "$key"
  emit "$kind" "$sp" "{\"state\":${S_ID[$i]},\"state_name\":\"${S_NAME[$i]}\",\"wave\":\"$C_WAVE\",\"attempt\":$RV,\"skipped\":$skipped,\"source\":\"kcc-run\"}"
  set_att "$key" 0
  R_last_violations=""
  if [[ "${S_ID[$i]}" == "1" || -z "$R_idea" ]]; then detect_idea; fi
  if [[ "${S_NAME[$i]}" == "SPECS" || ( "${S_CMD[$i]}" == /spec-create* && "${S_SCOPE[$i]}" == "run" ) ]]; then load_specs; fi
  cp="${S_CK[$i]}"; if [[ -z "$cp" && "${S_NAME[$i]}" == "REVIEW" ]]; then cp=spec-reviewed; fi
  if [[ -n "$cp" ]]; then invoke_checkpoint "$cp" "kcc-run: $label completed; run kcc-run -Resume"; fi
  if [[ "${S_NAME[$i]}" == "CLOSE" ]]; then add_closed_deferred; fi
  if [[ "$2" == "1" ]]; then say "kcc-run: done   $label (exit check already passes)"; else say "kcc-run: done   $label"; fi
  refresh_dashboard
}
process_unit() { # $1 idx -> OUTCOME next|retry|goto|paused|answered
  local i="$1" key label pa gname gkind has_check interactive force skip_dispatch pre_done=0 pre_rc=0 pre_viol="" sf
  unit_key_v "$i"; key="$RV"; unit_label_v "$i"; label="$RV"
  pa="$R_pending_action"; R_pending_action=""
  OUTCOME=next
  if [[ -n "${S_ONLY[$i]}" ]] && ! in_list "$R_scenario" "${S_ONLY[$i]}"; then return 0; fi
  skip_flag_v "$i"; sf="$RV"
  if [[ -n "$sf" ]]; then say "kcc-run: skip   $label ($sf)"; return 0; fi
  if [[ "$pa" == "abort" ]]; then stop_run aborted "human chose abort" 6; fi
  if [[ "$pa" == "done" ]]; then complete_unit "$i" 0; return 0; fi
  if [[ "$pa" == goto:* ]]; then
    local target="${pa#goto:}" tidx; R_state="$target"; add_force "$target"; get_idx_v "$target"; tidx="$RV"
    if [[ "${S_SCOPE[$tidx]}" == "wave" ]]; then R_wave=""; fi
    OUTCOME=goto; return 0
  fi
  gate_name_v "$i"; gname="$RV"
  gkind=failure; if is_approval_gate "$gname"; then gkind=approval; fi
  has_check=0; if [[ -n "${S_CT[$i]}" ]]; then has_check=1; fi
  interactive=0; if [[ -n "${S_INT[$i]}" ]] && in_list "$R_scenario" "${S_INT[$i]}"; then interactive=1; fi
  force=0; if test_force "${S_ID[$i]}" || [[ "$pa" == "rerun" ]]; then force=1; fi
  if [[ "$pa" == "rerun" ]]; then set_att "$key" 0; fi
  skip_dispatch=0; case "$pa" in recheck|approved|gatecheck) skip_dispatch=1 ;; esac
  LAST_HARNESS_RC=-1; DISPATCH_NO=0

  if [[ "$pa" == "install" ]]; then
    safe_name_v "$C_SPEC"; local ilog="$LOG_DIR/state-${S_ID[$i]}-$RV-install.log"
    invoke_harness "KCC run state ${S_ID[$i]} ${S_NAME[$i]}. Follow coordination/orchestrator.md Spawn protocol. The human approved INSTALL of the missing toolchain for $C_SPEC (.KCC/kernel/protocols/toolchain-preflight.md): install the declared stack tools, re-detect, then stop. Do only this, then stop." "$ilog"
    if limit_hit "$ilog" "$LAST_HARNESS_RC"; then suspend_run "$i" "$ilog"; fi
    if [[ "${S_NAME[$i]}" == "PREFLIGHT" ]]; then skip_dispatch=1; else force=1; fi
  fi

  if [[ $interactive -eq 1 && "$pa" != "recheck" ]]; then
    if [[ $has_check -eq 1 && "${S_CT[$i]}" != "internal:agent-report" && $force -eq 0 && -n "$R_idea" ]]; then
      run_check "$i" "$key"
      if [[ $CHK_RC -eq 0 ]]; then complete_unit "$i" 1; return 0; fi
    fi
    local cmdtext q ex
    cmdtext="$(render "$(state_cmd "$i")")"
    q="Scenario S1: state ${S_ID[$i]} ${S_NAME[$i]} is an interactive interrogation. Run it yourself in your harness: \`$cmdtext\`. When it has finished, answer \`done\` (the exit check then runs) or \`abort\`."
    say "kcc-run: interactive $label - run in your harness: $cmdtext"
    ex="Command: \`$cmdtext\`"
    if [[ -n "$R_last_violations" ]]; then ex="$ex"$'\n\n'"Last exit-check violations: $R_last_violations"; fi
    open_gate interactive interactive "$q" "$i" "$ex"
    return 0
  fi
  if [[ $interactive -eq 1 && "$pa" == "recheck" && "${S_CT[$i]}" == "internal:agent-report" ]]; then complete_unit "$i" 0; return 0; fi

  get_att_v "$key"
  if [[ $skip_dispatch -eq 0 && $has_check -eq 1 && $force -eq 0 && "$RV" == "0" && "${S_SCOPE[$i]}" != "wave" && "${S_CT[$i]}" != "internal:agent-report" ]] \
     && [[ -n "$R_idea" || "${S_ID[$i]}" == "0" ]] && ! [[ "$gkind" == "approval" && -n "$gname" ]] && precheck_ready "$i"; then
    run_check "$i" "$key"
    if [[ $CHK_RC -eq 0 ]]; then complete_unit "$i" 1; return 0; fi
    pre_done=1; pre_rc=$CHK_RC; pre_viol="$CHK_VIOL"
  fi

  # ---- dispatch ----
  local has_cmd=0 att need_fix=0
  if [[ -n "${S_CMD[$i]}" ]]; then has_cmd=1; fi
  get_att_v "$key"; att="$RV"
  if [[ $has_cmd -eq 0 && $att -gt 0 && $has_check -eq 1 && -z "$gname" ]]; then need_fix=1; fi
  VM_MODE=""; VM_BASE=""
  # A bug the implementer cannot fix without a human ruling (Status blocked) opens the ruling gate at once: no dispatch, no attempt used.
  if [[ "${S_CT[$i]}" == "internal:no-open-bugs" && -n "$C_ENTRY" ]]; then
    run_check "$i" "$key"
    if [[ -n "$CHK_BLOCKED" && -z "$CHK_OPEN" ]]; then R_last_violations="$(sanitize_prompt "$CHK_VIOL")"; ruling_gate "$i"; return 0; fi
    # Nothing for the implementer to do: no open bug, and the check or review that sent the spec back names no violation an
    # implementer owns (round 11: a FIX run of 86 s found "nothing in scope remains"). No agent runs; the unit completes as skipped.
    if [[ -z "$CHK_OPEN" && -z "$CHK_BLOCKED" && $has_cmd -eq 1 && $skip_dispatch -eq 0 && "$pa" != "rerun" && -n "$R_last_violations" ]] && test_force "${S_ID[$i]}" \
       && ! printf '%s' "$R_last_violations" | grep -Eq '[(](implementer|infrastructure-implementer)[)]'; then
      say "kcc-run: skip   $label: no open bug and no violation an implementer can fix ($(flat "$R_last_violations"))"
      complete_unit "$i" 1; return 0
    fi
  fi
  if [[ "${S_NAME[$i]}" == "TEST" && -n "$C_ENTRY" && $has_cmd -eq 1 && $skip_dispatch -eq 0 ]]; then
    verify_mode "$C_ENTRY"
    if [[ "$VM_MODE" == "scoped" ]] && nothing_to_verify "$C_ENTRY"; then
      say "kcc-run: skip   $label: nothing changed since the last review (HEAD $VM_BASE, no change under src/, no Bug awaiting verification); mechanical checks only"
      emit test-skipped "$C_SPEC" "{\"state\":${S_ID[$i]},\"state_name\":\"${S_NAME[$i]}\",\"reason\":\"unchanged since the last review\",\"commit\":\"$VM_BASE\",\"source\":\"kcc-run\"}"
      skip_dispatch=1
    fi
  fi
  if [[ $skip_dispatch -eq 0 && ( $has_cmd -eq 1 || $need_fix -eq 1 ) ]]; then
    local body prompt log where
    # TEST: the first verification of a spec is a full pass; later ones re-verify only what changed. At most VERIFY_FULL_MAX full passes.
    if [[ "${S_NAME[$i]}" == "TEST" && -n "$C_ENTRY" && $has_cmd -eq 1 ]]; then
      verify_mode "$C_ENTRY"
      if [[ "$VM_MODE" == "full" && $att -eq 0 ]]; then
        local fp; fp="$(get_att "full:$C_SPEC")"
        if [[ $fp -ge $VERIFY_FULL_MAX ]]; then
          set_att "cap:$C_SPEC" 1
          open_gate loop loop "Verification of $C_SPEC would be its full pass number $((fp + 1)); at most $VERIFY_FULL_MAX full verifier passes are allowed per spec (CR-3), so no verifier is run. Still open: $(open_bug_list "$C_ENTRY"). Revise (one more full pass, with a --note), escalate, or abort?" "$i" "Open bug items: $(open_bug_list "$C_ENTRY")"
          return 0
        fi
        set_att "full:$C_SPEC" $((fp + 1))
      fi
    fi
    if [[ $has_cmd -eq 1 ]]; then state_cmd_v "$i"; render_v "$RV"; body="$RV"; else body="The exit check \`$(check_desc "$i")\` failed. Route each violation to its fix_owner and fix it."; fi
    where=""; if [[ -n "$C_SPEC" ]]; then where=" for $C_SPEC"; fi; if [[ -n "$C_WAVE" ]]; then where="$where wave $C_WAVE"; fi
    # Full runs wrap each unit with the butler (CR-8: brief first, remember after); fasttrack keeps it to the run's
    # first and last states, which name it in their command. CLOSE already names it.
    local butler_line=""
    setting_v run.butler on; lc_v "$FGV"
    if [[ "$R_fasttrack" != "1" && "${S_NAME[$i]}" != "CLOSE" && "$LCV" != "off" ]]; then butler_line="Wrap the work with the butler as the spawn protocol requires: spawn it to brief you first (butler-brief) and to remember afterwards (butler-remember). "; fi
    local lead=". Follow coordination/orchestrator.md Spawn protocol and the state's contract. ${butler_line}Do only this state, then stop. This is a non-interactive session that ends when you reply: run every subagent in the foreground (never run_in_background) and wait for all of them, including parallel ones, before you finish. "
    HARNESS_EXTRA=""
    agent_mode "$i" "$att"
    if [[ -n "$AM_MODE" ]]; then
      harness_extra_v; HARNESS_EXTRA="$RV"
      if [[ "$AM_MODE" == "direct" ]]; then
        convert_agent_body_v "$body"; body="$RV"
        lead=". You are the $AM_AGENT agent running this state directly, with no orchestrator above you: do the work yourself and spawn no other agent. Do only this state, then stop. "
      else
        if [[ "$R_fasttrack" == "1" ]]; then lead="${lead% } Put the skill's arguments (\`--fasttrack\`, \`--depthlevel N\`, and the rest) verbatim in each subagent's handover packet and tell it to follow its \"Fast track and depth\" section; do not paraphrase them. "; fi
        if [[ -n "$AM_TIER" ]]; then lead="${lead% } Routing (kcc-route): spawn the $AM_AGENT subagent on tier $AM_TIER${AM_MODEL:+, model $AM_MODEL}, effort $AM_EFFORT ($AM_WHY). Before any other spawn run \`.KCC/tools/kcc-route --agent <name> [--spec ${C_SPEC:-SPEC-ID}]\` and use its tier, model and effort. "; fi
      fi
      AM_ITEM="run"; if [[ -n "$C_SPEC" ]]; then AM_ITEM="spec"; fi; if [[ -n "$C_WAVE" ]]; then AM_ITEM="wave $C_WAVE"; fi
      if [[ -n "$AM_TIER" ]]; then emit model-selected "$C_SPEC" "{\"agent\":\"$AM_AGENT\",\"item\":\"$AM_ITEM\",\"tier\":\"$AM_TIER\",\"model\":\"$AM_MODEL\",\"effort\":\"$AM_EFFORT\",\"reasons\":\"$AM_WHY\",\"mode\":\"$AM_MODE\",\"pass\":\"$VM_MODE\",\"source\":\"kcc-route\"}"
      elif false; then emit model-escalated "$C_SPEC" "{\"agent\":\"$AM_AGENT\",\"item\":\"wave $C_WAVE\",\"from\":\"executor\",\"to\":\"$AM_MODEL\",\"reason\":\"$AM_WHY\",\"source\":\"kcc-run\"}"; fi
    fi
    prompt="KCC run state ${S_ID[$i]} ${S_NAME[$i]}$where$lead$body"
    if [[ "$VM_MODE" == "scoped" ]]; then prompt="$prompt $(scoped_prompt)"; fi
    if [[ "$VM_MODE" == "full" ]]; then prompt="$prompt FULL VERIFICATION PASS $(get_att "full:$C_SPEC") of at most $VERIFY_FULL_MAX for $C_SPEC: run every check in this one pass (acceptance criteria, Test IDs, the compose or runtime smoke test, container image scans, every scan the quality gate lists) and file every finding now, because a later pass re-verifies only what changed. Record the HEAD commit you verified as 'commit: <sha>' in review.md frontmatter. If an orchestrator session runs this state, put this paragraph verbatim in the verifier subagent's handover packet."; fi
    if [[ "${S_NAME[$i]}" == "TEST" && -n "$C_SPEC" ]]; then
      local lim; lim="$(env_limits "$C_SPEC")"
      if [[ -n "$lim" ]]; then prompt="$prompt KNOWN ENVIRONMENT LIMITS (recorded by PREFLIGHT on this machine): $lim. Do not attempt what they rule out (no docker build or compose up --build while the registry is unreachable): record each AC and Test ID that needs it as DEFERRED with that reason at once, and spend the time on the checks that can run."; fi
    fi
    if [[ $att -gt 0 && -n "$R_last_violations" ]]; then prompt="$prompt RETRY $((att + 1))/$CFG_MAX - fix these exit-check violations: $R_last_violations"; fi
    if [[ $att -eq 0 && -n "$R_last_violations" ]] && test_force "${S_ID[$i]}"; then prompt="$prompt A later stage failed and sent this spec back. The open Bug items in the spec Backlog and these violations are the work of this pass; fix them test-first and write only the files they name: $R_last_violations"; fi
    if [[ -n "$R_note" ]]; then prompt="$prompt Human note: $R_note"; R_note=""; fi
    if [[ "${S_SCOPE[$i]}" == "wave" && $att -eq 0 ]]; then invoke_checkpoint manual "kcc-run: baseline before $label"; fi
    local tag="run"; if [[ -n "$C_SPEC" ]]; then tag="$C_SPEC"; if [[ -n "$C_WAVE" ]]; then tag="$tag-w$C_WAVE"; fi; fi
    # One log per dispatch: the first dispatch of a unit keeps the name state-<id>-<unit>-<attempt>.log; when that file exists (a second
    # TEST pass, FIX again after a review) the suffix counts up to the next free number, so no run overwrites an earlier log.
    local dno=$((att + 1))
    safe_name_v "$tag"; local stag="$RV"
    while [[ -e "$LOG_DIR/state-${S_ID[$i]}-$stag-$dno.log" ]]; do dno=$((dno + 1)); done
    DISPATCH_NO=$dno
    log="$LOG_DIR/state-${S_ID[$i]}-$stag-$dno.log"
    rel_v "$log"; say "kcc-run: run    $label (attempt $((att + 1))/$CFG_MAX) -> $RV"
    save_run
    refresh_dashboard
    # Every dispatch records a start and an end with its spec and agent, so the dashboard can show runs that overlap (one agent per spec).
    local ar_agent="${AM_AGENT:-orchestrator}" ar_t0 ar_t1
    epoch_v; ar_t0="$EPV"
    jescv "${AM_WHY:-}"; local ar_why="$JE"; rel_v "$log"; local ar_log="$RV"; isov
    emit agent-run-started "$C_SPEC" "{\"state\":${S_ID[$i]},\"state_name\":\"${S_NAME[$i]}\",\"agent\":\"$ar_agent\",\"model\":\"${AM_MODEL:-}\",\"effort\":\"${AM_EFFORT:-}\",\"tier\":\"${AM_TIER:-}\",\"reasons\":\"$ar_why\",\"pass\":\"${VM_MODE:-}\",\"attempt\":$((att + 1)),\"dispatch\":$dno,\"wave\":\"$C_WAVE\",\"log\":\"$ar_log\",\"started\":\"$ISO\",\"source\":\"kcc-run\"}"
    invoke_harness "$prompt" "$log"
    HARNESS_EXTRA=""
    epoch_v; ar_t1="$EPV"; isov
    emit agent-run-ended "$C_SPEC" "{\"state\":${S_ID[$i]},\"state_name\":\"${S_NAME[$i]}\",\"agent\":\"$ar_agent\",\"attempt\":$((att + 1)),\"dispatch\":$dno,\"wave\":\"$C_WAVE\",\"log\":\"$ar_log\",\"exit\":$LAST_HARNESS_RC,\"seconds\":$((ar_t1 - ar_t0)),\"ended\":\"$ISO\",\"source\":\"kcc-run\"}"
    if limit_hit "$log" "$LAST_HARNESS_RC"; then suspend_run "$i" "$log"; fi
    if [[ "$LAST_HARNESS_RC" == "124" ]]; then say "kcc-run: harness timed out for $label"; fi
    pre_done=0
  fi

  # ---- approval gate ----
  local sp="${C_SPEC:-$C_IDEA}"
  if [[ "$pa" != "approved" ]]; then
    if [[ "$gkind" == "approval" && -n "$gname" ]]; then
      if [[ "$gname" == "budget-cap" ]]; then
        local amt; amt="$(latest_estimate)"
        if [[ -n "$amt" && -n "$R_budget" ]] && awk -v a="$amt" -v b="$R_budget" 'BEGIN { exit !(a + 0 <= b + 0) }'; then
          emit auto-policy-approved-bounded "$sp" "{\"estimate\":$amt,\"cap\":$R_budget,\"currency\":\"$R_currency\",\"state\":${S_ID[$i]},\"source\":\"kcc-run\"}"
        else
          local why="no parseable estimate-issued amount in coordination/backchannel.jsonl"
          if [[ -n "$amt" ]]; then why="estimate $amt exceeds the cap $R_budget $R_currency"; emit auto-policy-cap-exceeded "$sp" "{\"estimate\":$amt,\"cap\":\"$R_budget\",\"currency\":\"$R_currency\",\"source\":\"kcc-run\"}"; fi
          open_gate "$gname" approval "Budget cap check for $label: $why. Revise the scope, increase the cap (--answer increase --budget NN), or abort." "$i" ""
          return 0
        fi
      else
        local q
        case "$gname" in
          budget) q="Approve the token estimate for $label (see the latest estimate-issued event and ROADMAP Token Plan)?" ;;
          confirm) q="Confirm every captured interrogation answer (recap in ideation/$C_IDEA/HumanAnswers.md)?" ;;
          windows) q="Approve the parallel session windows for $C_SPEC (plan.md -> ## Waves), or run sequentially?" ;;
          *) q="Approve $label?" ;;
        esac
        open_gate "$gname" approval "$q" "$i" ""
        return 0
      fi
    elif [[ -z "$gname" && "${S_EV[$i]}" == "estimate-issued" && "$R_scenario" == "S2" ]]; then
      emit auto-policy-approved-unlimited "$sp" "{\"state\":${S_ID[$i]},\"scenario\":\"S2\",\"source\":\"kcc-run\"}"
    fi
  fi

  # ---- exit check ----
  if [[ $has_check -eq 0 ]]; then complete_unit "$i" 0; return 0; fi
  # A check that names {IDEA} (files-exist, -Spec paths) needs the idea the dispatch just created.
  if [[ $pre_done -eq 0 && -z "$R_idea" ]]; then detect_idea; new_ctx "$C_ENTRY" "$C_WAVE"; fi
  if [[ $pre_done -eq 1 ]]; then CHK_RC=$pre_rc; CHK_VIOL="$pre_viol"; else get_att_v "$key"; run_check "$i" "$key-$(( DISPATCH_NO > 0 ? DISPATCH_NO : RV + 1 ))"; fi
  # A passing check proves nothing when the state's artifact was never written (a conformance scope with
  # nothing in it passes): precheck_requires is also the state's required output.
  if [[ $CHK_RC -eq 0 && -n "${S_PR[$i]}" && -z "$R_idea" ]]; then detect_idea; new_ctx "$C_ENTRY" "$C_WAVE"; fi
  if [[ $CHK_RC -eq 0 ]] && ! precheck_ready "$i"; then
    CHK_RC=1; CHK_VIOL="REQ-001: state ${S_ID[$i]} ${S_NAME[$i]} finished but did not produce $(render "${S_PR[$i]}")"
  fi
  if [[ $CHK_RC -eq 0 ]]; then complete_unit "$i" 0; return 0; fi
  sanitize_prompt_v "$CHK_VIOL"; R_last_violations="$RV"
  if [[ ${#R_last_violations} -gt 1500 ]]; then R_last_violations="${R_last_violations:0:1500} ..."; fi
  if [[ $CHK_RC -eq 2 ]]; then
    # A silent run does not stop for a check that cannot run: the spec is left as an open item and the rest goes on.
    if [[ "$R_silent" == "1" && -n "$C_SPEC" ]]; then block_unit "$i" "$C_SPEC" check-error "the exit check returned a usage/environment error: $R_last_violations" "$(resume_hint "$C_SPEC" "${S_ID[$i]}")" "$R_last_log"; OUTCOME=goto; return 0; fi
    stop_run stopped "exit check for $label returned a usage/environment error: $R_last_violations" 6
  fi
  # Only blocked bugs are left (the pass fixed the others): they need a human ruling, so no retry and no attempt is used.
  if [[ -n "$CHK_BLOCKED" && -z "$CHK_OPEN" ]]; then ruling_gate "$i"; return 0; fi
  if [[ $CHK_RC -eq 3 ]]; then
    # A deferral already accepted for this spec (at TEST, or at the toolchain gate) is not asked again: the spec closes as deferred-accepted.
    if [[ -n "$C_SPEC" && "$(get_att "defer:$C_SPEC")" != "0" ]]; then
      say "kcc-run: deferred check for $C_SPEC was accepted earlier (not a pass): $(flat "$R_last_violations")"
      complete_unit "$i" 0; return 0
    fi
    local g="$gname" q="Exit check for $label is DEFERRED (exit 3): a required external tool is missing. This is not a pass."
    if [[ -z "$g" || "$gkind" == "approval" ]]; then g=quality-deferred-on-exit-3; fi
    if [[ "$R_last_violations" == REVIEW-004* ]]; then
      g=waiver
      q="Review of $C_SPEC: every bug is closed and what still keeps the gate red is outside the code (an environment limit, a stale artifact, a gate tool error, or a check the architecture excluded). This is not a pass. waive (close the spec as WAIVER_NEEDED and go on; record the waiver in review.md -> ## Waivers), recheck (you fixed the environment: run the verification again), or abort?"
    fi
    open_gate "$g" failure "$q" "$i" "$R_last_violations"
    return 0
  fi
  if [[ -n "$gname" && "$gkind" == "failure" && "$gname" != "quality-deferred-on-exit-3" ]]; then
    local q
    case "$gname" in
      repo-bootstrap) q="No usable git repository (or no recorded decision). Choose how to bootstrap the workspace repository." ;;
      roi-gate) q="ROI confidence is below the minimum or not recorded. Proceed anyway, revise the idea, or abort?" ;;
      toolchain) q="Required toolchain missing for $C_SPEC. Install (AI installs after this approval), human-install, or defer (verdict TOOLCHAIN_DEFERRED)?" ;;
      *) q="Exit check failed for $label." ;;
    esac
    open_gate "$gname" failure "$q" "$i" "$R_last_violations"
    return 0
  fi
  get_att_v "$key"; att=$(( RV + 1 ))
  set_att "$key" "$att"
  say "kcc-run: FAIL   $label exit check (attempt $att/$CFG_MAX): $R_last_violations"
  if [[ $att -ge $CFG_MAX ]]; then
    open_gate loop loop "Exit check for $label failed $att consecutive times (CR-3). Revise (retry with a --note), escalate, or abort?" "$i" "$R_last_violations"
    return 0
  fi
  if [[ -n "${S_GOTO[$i]}" ]]; then
    say "kcc-run: goto   state ${S_GOTO[$i]} for $C_SPEC (on_fail_goto)"
    R_state="${S_GOTO[$i]}"; R_wave=""; add_force "${S_GOTO[$i]}"
    OUTCOME=goto; return 0
  fi
  OUTCOME=retry
}

# ---- navigation -------------------------------------------------------------------------------------------------------
next_wave() { # $1 entry, $2 current wave -> next wave or empty
  get_waves "$1" | awk -v w="$2" 'f { print; exit } $0 == w { f=1 }'
}
advance() {
  local idx nw
  get_idx_v "$R_state"; idx="$RV"
  if [[ "${S_SCOPE[$idx]}" == "wave" ]]; then
    spec_entry_at_v "$R_spec_index"
    nw="$(next_wave "$RV" "$R_wave")"
    if [[ -n "$nw" ]]; then R_wave="$nw"; return 0; fi
  fi
  R_wave=""
  clear_force "${S_ID[$idx]}"
  if [[ $idx -ge $SPEC_FIRST && $idx -le $SPEC_LAST ]]; then
    if [[ $idx -lt $SPEC_LAST ]]; then R_state="${S_ID[$((idx + 1))]}"; return 0; fi
    R_spec_index=$((R_spec_index + 1))
    spec_count_v
    if [[ $R_spec_index -lt $RV ]]; then R_state="${S_ID[$SPEC_FIRST]}"; R_force=""; return 0; fi
    if [[ $((idx + 1)) -lt $S_COUNT ]]; then R_state="${S_ID[$((idx + 1))]}"; else R_state=-1; fi
    return 0
  fi
  if [[ $((idx + 1)) -lt $S_COUNT ]]; then
    R_state="${S_ID[$((idx + 1))]}"
    if [[ $((idx + 1)) -eq $SPEC_FIRST ]]; then R_spec_index=0; fi
  else R_state=-1; fi
}
U_IDX=-1
resolve_unit() {
  local idx entry waves
  get_idx_v "$R_state"; idx="$RV"; U_IDX=$idx
  if [[ $idx -lt 0 ]]; then return 0; fi
  if [[ "${S_SCOPE[$idx]}" == "run" ]]; then new_ctx "" ""; return 0; fi
  if [[ -z "$R_specs" ]]; then load_specs; fi
  if [[ -z "$R_specs" ]]; then stop_run stopped "no specs found for $R_idea (ROADMAP.md) at state ${S_ID[$idx]}" 6; fi
  spec_count_v
  if [[ $R_spec_index -ge $RV ]]; then R_spec_index=0; fi
  spec_entry_at_v "$R_spec_index"; entry="$RV"
  if [[ "${S_SCOPE[$idx]}" == "wave" ]]; then
    waves="$(get_waves "$entry")"
    if [[ -z "$waves" ]]; then
      if [[ "$R_silent" == "1" ]]; then
        local nwid; spec_id_v "${entry#*/}"; nwid="$RV"; new_ctx "$entry" ""
        block_unit "$idx" "$nwid" no-waves "plan.md for $entry has no ## Waves table, so there is nothing to implement" "$(resume_hint "$nwid" 11)" ""; U_IDX=-2; return 0
      fi
      stop_run stopped "plan.md for $entry has no ## Waves table" 6
    fi
    # keep the current wave when the plan still lists it, else start at the first one (grep -qx / head -1, in bash)
    local wl wfound=0 wfirst=""
    while IFS= read -r wl; do
      if [[ -z "$wfirst" ]]; then wfirst="$wl"; fi
      if [[ -n "$R_wave" && "$wl" == "$R_wave" ]]; then wfound=1; fi
    done <<< "$waves"
    if [[ -z "$R_wave" || $wfound -eq 0 ]]; then R_wave="$wfirst"; fi
    new_ctx "$entry" "$R_wave"
  else new_ctx "$entry" ""; fi
}

# ---- dry run ------------------------------------------------------------------------------------------------------------
plan_line() { # $1 idx
  local i="$1" lbl c g
  lbl="$(unit_label "$i")"
  if [[ -n "${S_ONLY[$i]}" ]] && ! in_list "$R_scenario" "${S_ONLY[$i]}"; then echo "[skip] $lbl (only_in ${S_ONLY[$i]})"; return 0; fi
  sf="$(skip_flag "$i")"
  if [[ -n "$sf" ]]; then echo "[skip] $lbl ($sf)"; return 0; fi
  echo "[${S_ID[$i]}] $lbl"
  if [[ -n "${S_CMD[$i]}" ]]; then
    c="$(render "$(state_cmd "$i")")"
    if [[ -n "${S_INT[$i]}" ]] && in_list "$R_scenario" "${S_INT[$i]}"; then echo "  interactive (human runs): $c"
    else
      agent_mode "$i" 0
      HARNESS_EXTRA="$(harness_extra)"
      echo "  harness: $(harness_cmd "KCC run state ${S_ID[$i]} ${S_NAME[$i]}. ... $c")"
      HARNESS_EXTRA=""
    fi
  fi
  if [[ -n "${S_CT[$i]}" ]]; then echo "  check: $(check_desc "$i")"; fi
  g="$(gate_name "$i")"; if [[ -n "$g" ]]; then echo "  gate: $g ($(gate_answers "$g"))"; fi
  if [[ -n "${S_GOTO[$i]}" ]]; then echo "  on_fail_goto: ${S_GOTO[$i]}"; fi
}
show_plan() {
  local entries i j e w wl plan="" start
  entries="$R_specs"
  if [[ -z "$entries" && -n "$R_idea" ]]; then entries="$(specs_from_roadmap "$R_idea" | tr '\n' ' ')"; fi
  if [[ -z "$entries" ]]; then entries="{IDEA}/{SPEC}"; fi
  start="$(get_idx "$R_state")"; if [[ $start -lt 0 ]]; then start=0; fi
  for ((i = start; i < S_COUNT; i++)); do
    if [[ $i -eq $SPEC_FIRST ]]; then
      for e in $entries; do
        for ((j = SPEC_FIRST; j <= SPEC_LAST; j++)); do
          wl=""
          if [[ "${S_SCOPE[$j]}" == "wave" ]]; then if [[ "$e" != "{IDEA}/{SPEC}" ]]; then wl="$(get_waves "$e" | tr '\n' ' ')"; fi; if [[ -z "$wl" ]]; then wl="{WAVE}"; fi; else wl="-"; fi
          for w in $wl; do
            if [[ "$w" == "-" ]]; then w=""; fi
            new_ctx "$e" "$w"
            if [[ "$e" == "{IDEA}/{SPEC}" ]]; then C_SPEC="{SPEC}"; C_IDEA="${R_idea:-{IDEA\}}"; C_ENTRY=""; fi
            plan="$plan$(plan_line "$j")"$'\n'
          done
        done
      done
      i=$SPEC_LAST; continue
    fi
    new_ctx "" ""; if [[ -z "$C_IDEA" ]]; then C_IDEA="{IDEA}"; fi
    plan="$plan$(plan_line "$i")"$'\n'
  done
  if [[ "$JSON" -eq 1 ]]; then
    local arr="" line first=1
    while IFS= read -r line; do
      [[ -n "$line" ]] || continue
      if [[ $first -eq 0 ]]; then arr="$arr,"; fi; first=0
      arr="$arr\"$(jesc "$line")\""
    done <<< "$plan"
    status_json dry-run | sed 's/}$//'; printf ',"plan":[%s]}\n' "$arr"
  else
    say "kcc-run DRY RUN - scenario $R_scenario, harness $HARNESS, input \"$R_input\", max_attempts $CFG_MAX, timeout ${CFG_TIMEOUT}m"
    printf '%s' "$plan"
    say "Nothing was changed."
  fi
  exit 0
}

# ---- main ----------------------------------------------------------------------------------------------------------------
HARNESS=claude
RUN_EXISTS=0; if [[ -f "$RUN_FILE" ]]; then RUN_EXISTS=1; load_run; fi
TERMINAL=0; if [[ $RUN_EXISTS -eq 1 ]] && [[ "$R_status" == "done" || "$R_status" == "aborted" ]]; then TERMINAL=1; fi
START_NEW=0
if [[ -n "$IN_TEXT" && $RESUME -eq 0 ]]; then
  if [[ $RUN_EXISTS -eq 1 && $TERMINAL -eq 0 ]]; then fail_usage "a run is in progress ($R_status at state $R_state); use --resume / --answer, or delete coordination/run/run.json"; fi
  START_NEW=1
elif [[ $RUN_EXISTS -eq 0 ]]; then
  if [[ $RESUME -eq 1 ]]; then fail_usage "nothing to resume: coordination/run/run.json not found"; fi
  usage >&2; exit 2
fi

if [[ $START_NEW -eq 1 ]]; then
  if [[ $RUN_EXISTS -eq 1 && $DRY -eq 0 ]]; then mv -f "$RUN_FILE" "$RUN_DIR/run-$(date -u +%Y%m%d%H%M%S).json"; fi
  # A new run starts a new NeedsAttention.md; the previous one is kept next to it.
  if [[ $DRY -eq 0 && -f "$ATTN_FILE" ]]; then mv -f "$ATTN_FILE" "$COORD/NeedsAttention-$(date -u +%Y%m%d%H%M%S).md"; fi
  new_run
  txt="$(printf '%s' "$IN_TEXT" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
  if [[ "$txt" == \<*\> ]]; then txt="${txt#<}"; txt="${txt%>}"; fi
  R_input="$txt"
  R_ideas_before="$(idea_folders | tr '\n' ' ' | sed 's/ *$//')"
  if [[ "$txt" == "all" ]]; then
    R_input_class=all; list=""
    if [[ -d "$ROOT/specs" ]]; then
      for g in "$ROOT"/specs/IDEA-*-Specs; do
        [[ -d "$g" ]] || continue
        iname="$(basename "$g")"; iname="${iname%-Specs}"
        for e in $(specs_from_roadmap "$iname"); do
          st="$(spec_status "$e" | tr 'A-Z' 'a-z')"
          if [[ "$st" != "done" ]]; then list="${list:+$list }$e"; fi
        done
      done
    fi
    if [[ -z "$list" ]]; then say "kcc-run: all specs are Done; nothing to run"; if [[ "$JSON" -eq 1 ]]; then echo '{"tool":"kcc-run","status":"done","reason":"no open specs"}'; fi; exit 0; fi
    R_specs="$list"; R_idea="${list%%/*}"; R_state="${S_ID[$SPEC_FIRST]}"
  elif [[ "$txt" =~ ^(IDEA-[0-9]+)(-.*)?$ ]]; then
    R_input_class=idea; base="${BASH_REMATCH[1]}"; cands=""
    for f in $(idea_folders); do if [[ "$f" == "$txt" || "$f" == "$base" || "$f" == "$base"-* ]]; then cands="${cands:+$cands }$f"; fi; done
    if [[ "$txt" != "$base" ]] && in_list "$txt" "$cands"; then cands="$txt"; fi
    n=0; for f in $cands; do n=$((n + 1)); done
    if [[ $n -eq 0 ]]; then echo "auto: idea $txt not found under ideation/" >&2; exit 6; fi
    if [[ $n -gt 1 ]]; then echo "auto: ambiguous idea $txt: $cands" >&2; exit 6; fi
    R_idea="$cands"; R_state=0
    load_specs
  elif [[ "$txt" =~ ^(SPEC-[0-9A-Za-z]+) ]]; then
    R_input_class=spec; sid="$(spec_id "$txt")"; found=""
    for g in "$ROOT"/specs/IDEA-*-Specs; do
      [[ -d "$g" ]] || continue
      for s in "$g"/SPEC-*; do
        [[ -d "$s" ]] || continue
        b="$(basename "$s")"
        if [[ "$b" == "$txt" || "$b" == "$sid" || "$b" == "$sid"-* ]]; then gi="$(basename "$g")"; found="${found:+$found }${gi%-Specs}/$b"; fi
      done
    done
    n=0; for f in $found; do n=$((n + 1)); done
    if [[ $n -ne 1 ]]; then if [[ $n -eq 0 ]]; then echo "auto: spec $txt not found under specs/" >&2; else echo "auto: spec $txt is ambiguous: $found" >&2; fi; exit 6; fi
    R_specs="$found"; R_idea="${found%%/*}"; R_state="${S_ID[$SPEC_FIRST]}"
  elif [[ -d "$ROOT/$txt" || -d "$txt" ]]; then R_input_class=existing-solution-plus-idea
  elif [[ -e "$ROOT/$txt" || -e "$txt" ]]; then R_input_class=file-path
  else R_input_class=text; fi
fi

if [[ $SILENT -eq 1 && $ASSUME -eq 1 ]]; then R_silent=1; R_assume=1; if [[ -n "$BUDGET" || -n "$R_budget" ]]; then R_scenario=S3; else R_scenario=S2; fi; fi
if [[ -n "$BUDGET" ]]; then R_budget="$BUDGET"; if [[ "$R_scenario" == "S2" ]]; then R_scenario=S3; fi; fi
if [[ -n "$CURRENCY" ]]; then R_currency="$(printf '%s' "$CURRENCY" | tr 'a-z' 'A-Z')"; fi
if [[ -n "$ACC" ]]; then R_accuracy="$ACC"; fi
if [[ $PARALLEL -eq 1 ]]; then R_parallel=1; fi
if [[ $FASTTRACK -eq 1 ]]; then R_fasttrack=1; fi
# --until is kept in run.json so a resume (by a human or by kcc-limit-watch after a usage limit) still stops there.
if [[ -n "$UNTIL" ]]; then R_until="$UNTIL"; elif [[ "${R_until:-}" =~ ^[0-9]+$ ]]; then UNTIL="$R_until"; fi
if [[ -n "$DEPTH" ]]; then R_depthlevel="$DEPTH"
elif [[ $START_NEW -eq 1 ]]; then
  dl0="$(setting defaults.depthlevel 5)"; [[ "$dl0" =~ ^[1-5]$ ]] || dl0=5
  if [[ "$R_fasttrack" == "1" && "$dl0" == "5" ]]; then dl0=2; fi
  R_depthlevel="$dl0"
fi
if [[ -n "$HARNESS_ARG" ]]; then R_harness="$HARNESS_ARG"; fi
if [[ -z "$R_harness" ]]; then R_harness="$(setting run.harness claude)"; fi
HARNESS="$R_harness"
case "$HARNESS" in claude|codex|opencode|generic) ;; *) fail_usage "unknown harness in settings/run.json: $HARNESS" ;; esac
if [[ -n "$FROM" ]]; then
  fidx="$(get_idx "$FROM")"; if [[ $fidx -lt 0 ]]; then fail_usage "unknown state $FROM"; fi
  R_state="$FROM"; R_wave=""; R_pending_action=""; R_gate_id=""; R_attempts=""; R_force="$FROM"
  if [[ $fidx -ge $SPEC_FIRST && $fidx -le $SPEC_LAST ]]; then R_spec_index=0; fi
  if [[ "$R_status" != "done" ]]; then R_status=running; fi
fi
if [[ -n "$UNTIL" && "$(get_idx "$UNTIL")" -lt 0 ]]; then fail_usage "unknown state $UNTIL"; fi
if [[ -n "$ONLY" ]]; then
  if [[ "$(get_idx "$ONLY")" -lt 0 ]]; then fail_usage "unknown state $ONLY"; fi
  if [[ -n "$R_gate_id" && -z "$ANSWER" ]]; then fail_usage "gate $R_gate_id is pending; answer it first"; fi
fi

if [[ $DRY -eq 1 ]]; then show_plan; fi

mkdir -p "$LOG_DIR"
if [[ $START_NEW -eq 1 ]]; then
  save_run
  bj="null"; if [[ -n "$R_budget" ]]; then bj="$R_budget"; fi
  emit auto-policy-parsed "" "{\"scenario\":\"$R_scenario\",\"silent\":$([[ $R_silent == 1 ]] && echo true || echo false),\"assume\":$([[ $R_assume == 1 ]] && echo true || echo false),\"accuracy_threshold_pct\":$R_accuracy,\"budget_cap_amount\":$bj,\"budget_cap_currency\":\"$R_currency\",\"parallel\":$([[ $R_parallel == 1 ]] && echo true || echo false),\"fasttrack\":$([[ $R_fasttrack == 1 ]] && echo true || echo false),\"depthlevel\":$R_depthlevel,\"input_class\":\"$R_input_class\",\"harness\":\"$HARNESS\",\"source\":\"kcc-run\"}"
  if [[ "$R_fasttrack" == "1" ]]; then emit fasttrack-approved "" "{\"depthlevel\":$R_depthlevel,\"scope\":\"budget-gates-skipped\",\"source\":\"kcc-run\"}"; fi
  say "kcc-run: new run - scenario $R_scenario, input class $R_input_class, starting at state $R_state"
  offer_dashboard 1
  save_run
else
  if [[ "$R_status" == "done" && -z "$FROM" && -z "$ONLY" ]]; then say "kcc-run: run is DONE; nothing to resume"; finish done 0; fi
  if [[ "$R_status" == "aborted" && -z "$FROM" ]]; then say "kcc-run: run was ABORTED ($R_reason); start a new run with --input"; finish aborted 6; fi
  if [[ "$R_status" == "suspended" || "$R_status" == "stopped" ]]; then R_status=running; R_reason=""; fi
fi

if [[ -n "$ANSWER" ]]; then
  if [[ -z "$R_gate_id" ]]; then fail_usage "no pending gate to answer"; fi
  apply_answer "$ANSWER"
elif [[ -n "$R_gate_id" ]]; then
  show_pause
  prompt_gate
  if [[ "$OUTCOME" == "paused" ]]; then save_run; finish paused 4; fi
fi

PREV_STATUS="$R_status"
R_status=running
save_run
ONLY_ON=0; SAVED_STATE=""; SAVED_SPEC=""; SAVED_WAVE=""
if [[ -n "$ONLY" ]]; then
  ONLY_ON=1; SAVED_STATE="$R_state"; SAVED_SPEC="$R_spec_index"; SAVED_WAVE="$R_wave"
  R_state="$ONLY"; R_wave=""; R_spec_index=0; add_force "$ONLY"
fi
guard=0
while true; do
  guard=$((guard + 1)); if [[ $guard -gt 5000 ]]; then stop_run stopped "internal loop guard tripped" 6; fi
  if [[ $ONLY_ON -eq 1 && "$R_state" != "$ONLY" ]]; then
    clear_force "$ONLY"; R_state="$SAVED_STATE"; R_spec_index="$SAVED_SPEC"; R_wave="$SAVED_WAVE"; if [[ "$PREV_STATUS" == "done" ]]; then R_status=done; fi
    save_run; say "kcc-run: --only $ONLY finished"; finish only-done 0
  fi
  if [[ "$R_state" -lt 0 ]]; then
    R_status=done; R_reason=""; save_run
    if [[ "${S_EV[$((S_COUNT - 1))]}" != "session-closed" ]]; then emit session-closed "$R_idea" '{"terminal":"DONE","source":"kcc-run"}'; fi
    say "kcc-run: DONE"
    show_deferred
    attention_counts
    if [[ "$ATTN_OPEN" -gt 0 ]]; then show_attention; finish needs-attention 7; fi
    if [[ "$ATTN_ITEMS" -gt 0 ]]; then show_attention; fi
    finish done 0
  fi
  resolve_unit
  if [[ $U_IDX -eq -2 ]]; then save_run; continue; fi
  if [[ $U_IDX -lt 0 ]]; then stop_run stopped "unknown state $R_state" 6; fi
  uidx=$U_IDX
  process_unit "$uidx"
  case "$OUTCOME" in
    paused) save_run; finish paused 4 ;;
    answered|retry|goto) save_run; continue ;;
    next)
      if [[ $ONLY_ON -eq 1 ]]; then
        moved=0
        if [[ "${S_SCOPE[$uidx]}" == "wave" ]]; then nw="$(next_wave "$C_ENTRY" "$R_wave")"; if [[ -n "$nw" ]]; then R_wave="$nw"; moved=1; fi; fi
        if [[ $moved -eq 0 && "${S_SCOPE[$uidx]}" != "run" && $((R_spec_index + 1)) -lt $(spec_count) ]]; then R_spec_index=$((R_spec_index + 1)); R_wave=""; moved=1; fi
        if [[ $moved -eq 0 ]]; then R_state=-99; fi
      else
        advance
        if [[ -n "$UNTIL" && "${S_ID[$uidx]}" -eq "$UNTIL" ]]; then
          ui="$(get_idx "$UNTIL")"; ni="$(get_idx "$R_state")"
          if [[ "$R_state" -lt 0 || "$ni" -gt "$ui" ]]; then
            R_status=stopped; R_reason="until $UNTIL"; R_until=""; save_run
            say "kcc-run: --until $UNTIL reached; run stopped (resume with --resume)"
            show_deferred; attention_counts; if [[ "$ATTN_ITEMS" -gt 0 ]]; then show_attention; fi
            finish until-done 0
          fi
        fi
      fi
      save_run; continue ;;
    *) stop_run stopped "unexpected unit outcome $OUTCOME" 6 ;;
  esac
done
