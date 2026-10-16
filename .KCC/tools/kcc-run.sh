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
#       4 paused at a human gate, 5 suspended (usage limit), 6 stopped/aborted.
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

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
SELF="$SELF_DIR/$(basename "$0")"
if [[ -z "$REPO_ROOT" ]]; then REPO_ROOT="$(cd "$SELF_DIR/../.." && pwd)"; fi
[[ -d "$REPO_ROOT" ]] || fail_usage "workspace not found: $REPO_ROOT"
ROOT="$(cd "$REPO_ROOT" && pwd)"
TOOLS="$ROOT/.KCC/tools"
STATES_JSON="$ROOT/.KCC/kernel/auto-states.json"
[[ -f "$STATES_JSON" ]] || fail_usage "state table not found: $STATES_JSON"
COORD="$ROOT/coordination"; RUN_DIR="$COORD/run"; RUN_FILE="$RUN_DIR/run.json"; LOG_DIR="$RUN_DIR/logs"; GATE_DIR="$COORD/gates"
# --fasttrack has its own lifecycle table (a running app first, no ROI/CONFIRM/ARCH-GATE/BUDGET/WINDOWS states);
# a resumed fast-track run keeps it.
FT_TABLE=$FASTTRACK
if [[ $FT_TABLE -eq 0 && -f "$RUN_FILE" ]] && grep -qE '"fasttrack"[[:space:]]*:[[:space:]]*"1"' "$RUN_FILE"; then FT_TABLE=1; fi
if [[ $FT_TABLE -eq 1 && -f "$ROOT/.KCC/kernel/auto-states-fasttrack.json" ]]; then STATES_JSON="$ROOT/.KCC/kernel/auto-states-fasttrack.json"; fi

say() { if [[ "$JSON" -eq 1 ]]; then printf '%s\n' "$*" >&2; else printf '%s\n' "$*"; fi; }
iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }
jesc() { local s="$1"; s="${s//\\/\\\\}"; s="${s//\"/\\\"}"; s="${s//$'\t'/\\t}"; s="${s//$'\r'/}"; s="${s//$'\n'/\\n}"; printf '%s' "$s"; }
squote() { local s="$1"; printf "'%s'" "${s//\'/\'\\\'\'}"; }
rel() { local p="$1"; p="${p#"$ROOT"/}"; printf '%s' "$p"; }
safe_name() { printf '%s' "${1//[^A-Za-z0-9_.-]/_}"; }

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
flat_get() { awk -F'\t' -v k="$2" '$1==k{print $2; exit}' <<< "$1"; }

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
get_idx() { local i; for ((i = 0; i < S_COUNT; i++)); do if [[ "${S_ID[$i]}" == "$1" ]]; then echo "$i"; return 0; fi; done; echo -1; }
is_approval_gate() { case "$1" in confirm|budget|budget-cap|windows) return 0 ;; esac; return 1; }

SETTINGS_FLAT=""
if [[ -f "$ROOT/.KCC/settings.json" ]]; then SETTINGS_FLAT="$(json_flat "$ROOT/.KCC/settings.json" 2>/dev/null || true)"; fi
setting() { local v; v="$(flat_get "$SETTINGS_FLAT" "$1")"; if [[ -z "$v" || "$v" == "null" ]]; then v="$2"; fi; printf '%s' "$v"; }
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
  R_schema="kcc-run/1"; R_status="running"; R_created="$(iso)"; R_scenario="S1"; R_silent=0; R_assume=0
  R_accuracy=95; R_currency="USD"; R_parallel=0; R_fasttrack=0; R_depthlevel=5; R_sequential=0; R_state=0; R_spec_index=0
}
load_run() {
  new_run
  local flat; flat="$(json_flat "$RUN_FILE")" || fail_usage "cannot parse $RUN_FILE"
  eval "$(awk -F'\t' -v keys=" $RUN_KEYS " 'function q(v){ gsub(/\047/, "\047\\\047\047", v); return "\047" v "\047" } index(keys, " " $1 " ") > 0 { print "R_" $1 "=" q($2) }' <<< "$flat")"
}
save_run() {
  if [[ "$DRY" -eq 1 ]]; then return 0; fi
  R_updated="$(iso)"
  mkdir -p "$RUN_DIR"
  local k v first=1 tmp="$RUN_FILE.tmp"
  {
    echo "{"
    for k in $RUN_KEYS; do
      eval "v=\"\${R_$k}\""
      if [[ $first -eq 0 ]]; then printf ',\n'; fi
      first=0
      printf '  "%s": "%s"' "$k" "$(jesc "$v")"
    done
    printf '\n}\n'
  } > "$tmp"
  mv -f "$tmp" "$RUN_FILE"
}
get_att() { local p; local IFS=';'; for p in $R_attempts; do if [[ "${p%%=*}" == "$1" ]]; then echo "${p#*=}"; return 0; fi; done; echo 0; }
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
spec_id() { if [[ "$1" =~ ^(SPEC-[0-9]+) ]]; then printf '%s' "${BASH_REMATCH[1]}"; elif [[ "$1" =~ ^(SPEC-[0-9A-Za-z]+) ]]; then printf '%s' "${BASH_REMATCH[1]}"; else printf '%s' "$1"; fi; }
spec_dir() { printf '%s/specs/%s-Specs/%s' "$ROOT" "${1%%/*}" "${1#*/}"; }
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
  local d; d="$(spec_dir "$1")"
  local w=""
  if [[ -f "$d/plan.md" ]]; then w="$(awk 'BEGIN{IGNORECASE=1} /^##[ \t]/ { if (ins) exit; if (tolower($0) ~ /^##[ \t]+waves?([^a-z]|$)/) ins=1; next } ins' "$d/plan.md")"; fi
  if [[ -z "$w" && -f "$d/parallelization.md" ]]; then
    w="$(awk '/^##[ \t]/ { if (ins) exit; if (tolower($0) ~ /waves?/) ins=1; next } ins' "$d/parallelization.md")"
    if [[ -z "$w" ]]; then w="$(cat "$d/parallelization.md")"; fi
  fi
  printf '%s\n' "$w" | awk '/^[ \t]*\|/ { line=$0; sub(/^[ \t]*\|/, "", line); split(line, c, "|"); v=tolower(c[1]); gsub(/^[ \t]+|[ \t]+$/, "", v); sub(/^wave[ \t]*/, "", v); if (v ~ /^[0-9]+$/ && !(v+0 in s)) { s[v+0]=1; print v+0 } }'
}
spec_entries() { printf '%s' "$R_specs"; }
spec_count() { local n=0 e; for e in $R_specs; do n=$((n + 1)); done; echo "$n"; }
spec_entry_at() { local n=0 e; for e in $R_specs; do if [[ $n -eq $1 ]]; then echo "$e"; return 0; fi; n=$((n + 1)); done; echo ""; }
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
new_ctx() { C_ENTRY="$1"; C_WAVE="$2"; C_IDEA="$R_idea"; C_SPEC=""; if [[ -n "$1" ]]; then C_IDEA="${1%%/*}"; C_SPEC="$(spec_id "${1#*/}")"; fi; }
render() {
  local t="$1" sa="" par="" ft="" dl="" tools=""
  if [[ "$R_scenario" != "S1" ]]; then sa="--silent --assume"; fi
  if [[ "$R_parallel" == "1" ]]; then par="--parallel"; fi
  if [[ "$R_fasttrack" == "1" ]]; then ft="--fasttrack"; fi
  if [[ "$R_depthlevel" =~ ^[1-4]$ ]]; then dl="--depthlevel $R_depthlevel"; fi
  if [[ "$t" == *"{TOOLS}"* ]]; then if [[ -n "$C_ENTRY" ]]; then tools="$(derived_tools "$C_ENTRY")"; else tools=git; fi; fi
  t="${t//\{input\}/"$R_input"}"; t="${t//\{IDEA\}/"$C_IDEA"}"; t="${t//\{SPEC\}/"$C_SPEC"}"; t="${t//\{WAVE\}/"$C_WAVE"}"; t="${t//\{ITEM\}/}"
  t="${t//\{silent_assume\}/"$sa"}"; t="${t//\{parallel\}/"$par"}"; t="${t//\{fasttrack\}/"$ft"}"; t="${t//\{depthlevel\}/"$dl"}"; t="${t//\{flags\}/"$sa $par $ft $dl"}"; t="${t//\{TOOLS\}/"$tools"}"
  while [[ "$t" == *"  "* ]]; do t="${t//  / }"; done
  t="${t# }"; t="${t% }"
  printf '%s' "$t"
}
precheck_ready() { # $1 = idx; a state with precheck_requires counts as done only when that artifact exists
  [[ -n "${S_PR[$1]}" ]] || return 0
  [[ -e "$ROOT/$(render "${S_PR[$1]}")" ]]
}
state_cmd() { # $1 = idx -> command text (fasttrack variant when set)
  if [[ "$R_fasttrack" == "1" && -n "${S_CF[$1]}" ]]; then printf '%s' "${S_CF[$1]}"; else printf '%s' "${S_CMD[$1]}"; fi
}
skip_flag() { # $1 = idx -> the flag that skips this state, or empty
  local f; for f in ${S_SKIP[$1]}; do
    if [[ "$f" == "parallel" && "$R_parallel" == "1" ]]; then echo "--parallel"; return 0; fi
    if [[ "$f" == "fasttrack" && "$R_fasttrack" == "1" ]]; then echo "--fasttrack"; return 0; fi
  done
  return 0
}
gate_name() { # $1 = idx
  local n=""
  case "$R_scenario" in S1) n="${S_G1[$1]}" ;; S2) n="${S_G2[$1]}" ;; S3) n="${S_G3[$1]}" ;; esac
  if [[ -z "$n" ]]; then n="${S_GA[$1]}"; fi
  if [[ "$n" == "none" ]]; then n=""; fi
  printf '%s' "$n"
}
gate_answers() {
  local j
  if [[ "$1" == "interactive" ]]; then echo "done/abort"; return 0; fi
  for ((j = 0; j < G_COUNT; j++)); do if [[ "${GATE_N[$j]}" == "$1" ]]; then echo "${GATE_A[$j]}"; return 0; fi; done
  echo "proceed/abort"
}
unit_label() { local s="state ${S_ID[$1]} ${S_NAME[$1]}"; if [[ -n "$C_SPEC" ]]; then s="$s $C_SPEC"; fi; if [[ -n "$C_WAVE" ]]; then s="$s wave $C_WAVE"; fi; printf '%s' "$s"; }
unit_key() { local k="${S_ID[$1]}"; if [[ -n "$C_SPEC" ]]; then k="$k:$C_SPEC"; fi; if [[ -n "$C_WAVE" ]]; then k="$k:$C_WAVE"; fi; printf '%s' "$k"; }
in_list() { case " $2 " in *" $1 "*) return 0 ;; esac; return 1; }

# ---- tools ------------------------------------------------------------------------------------------
ps2kebab() { printf '%s' "$1" | sed -e 's/^-//' -e 's/\([a-z0-9]\)\([A-Z]\)/\1-\2/g' | tr 'A-Z' 'a-z' | sed 's/^/--/'; }
TOOL_RC=0
run_tool() { # $1 tool, $2 outfile ("" = none), rest = PowerShell-style args
  local tool="$1" out="$2"; shift 2
  local a=() x
  if [[ "$tool" == "toolchain-preflight" ]]; then
    while [[ $# -gt 0 ]]; do
      if [[ "$1" == "-Tools" ]]; then for x in $(printf '%s' "${2:-}" | tr ',' ' '); do a+=("$x"); done; shift 2; else shift; fi
    done
  else
    while [[ $# -gt 0 ]]; do if [[ "$1" == -[A-Z]* ]]; then a+=("$(ps2kebab "$1")"); else a+=("$1"); fi; shift; done
    a+=(--repo-root "$ROOT")
  fi
  if [[ ! -f "$TOOLS/$tool.sh" ]]; then TOOL_RC=2; if [[ -n "$out" ]]; then echo "tool not found: $tool" > "$out"; fi; return 0; fi
  if [[ -z "$out" ]]; then out=/dev/null; fi
  TOOL_RC=0
  (cd "$ROOT" && bash "$TOOLS/$tool.sh" "${a[@]+"${a[@]}"}") > "$out" 2>/dev/null < /dev/null || TOOL_RC=$?
}
EMIT_ID=""
emit() { # $1 kind, $2 spec, $3 payload json, $4 = "dash" to refresh the dashboard
  EMIT_ID=""
  if [[ "$DRY" -eq 1 || ! -f "$TOOLS/backchannel-append.sh" ]]; then return 0; fi
  local a=(--kind "$1" --from kcc-run --payload "$3" --repo-root "$ROOT") line
  if [[ -n "$2" ]]; then a+=(--spec "$2"); fi
  if [[ "${4:-}" != "dash" ]]; then a+=(--no-dashboard); fi
  line="$( (cd "$ROOT" && bash "$TOOLS/backchannel-append.sh" "${a[@]}") 2>/dev/null < /dev/null || true)"
  EMIT_ID="$(printf '%s\n' "$line" | sed -n 's/.*"id":"\(BC-[0-9]*\)".*/\1/p' | tail -1)"
}
pass_when() { # $1 expr, $2 flat json -> 0 when any clause matches
  local expr="$1" flat="$2" clause cond k op v actual ok
  local IFS='|'
  for clause in $expr; do
    ok=1
    local IFS='&'
    for cond in $clause; do
      cond="$(printf '%s' "$cond" | sed 's/^ *//; s/ *$//')"
      k="$(printf '%s' "$cond" | sed -n 's/^\([A-Za-z_]*\) *\([=<>]\).*/\1/p')"
      op="$(printf '%s' "$cond" | sed -n 's/^[A-Za-z_]* *\([=<>]\).*/\1/p')"
      v="$(printf '%s' "$cond" | sed -n 's/^[A-Za-z_]* *[=<>] *//p')"
      if [[ -z "$k" ]]; then ok=0; break; fi
      actual="$(flat_get "$flat" "$k")"
      if [[ "$actual" == "null" ]]; then actual=""; fi
      if [[ "$op" == "=" ]]; then if [[ "$actual" != "$v" ]]; then ok=0; break; fi
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
review_verdict_of() { # review.md -> APPROVED | CHANGES_NEEDED | TOOLCHAIN_DEFERRED | BLOCKED | empty
  local rv
  [[ -f "$1" ]] || return 0
  rv="$(tr -d '\r' < "$1" | sed -nE 's/^[Vv][Ee][Rr][Dd][Ii][Cc][Tt][[:space:]]*:[[:space:]]*"?([A-Za-z_-]+).*/\1/p' | head -n 1 | tr 'a-z' 'A-Z' | tr '-' '_')"
  if [[ -z "$rv" ]]; then rv="$(grep -oiwE 'APPROVED|CHANGES[_-]NEEDED|TOOLCHAIN[_-]DEFERRED|BLOCKED' "$1" | head -n 1 | tr 'a-z' 'A-Z' | tr '-' '_' || true)"; fi
  printf '%s' "$rv"
}
# Scoped re-verification (kernel/protocols/model-routing.md, agents/verifier.md -> Re-verification mode): the first TEST of a spec is a
# full pass; once a review.md with the verdict CHANGES_NEEDED exists, the next TEST re-verifies only what changed. At most
# VERIFY_FULL_MAX full passes per spec; the counter lives in run.json -> attempts under the key full:SPEC-ID.
VERIFY_FULL_MAX=2
VM_MODE=""; VM_BASE=""
verify_mode() { # spec entry -> sets VM_MODE (full|scoped) and VM_BASE (the commit the last review recorded, or empty)
  local rf; VM_MODE=full; VM_BASE=""
  rf="$(spec_dir "$1")/review.md"
  if [[ "$(review_verdict_of "$rf")" == "CHANGES_NEEDED" ]]; then
    VM_MODE=scoped
    VM_BASE="$(tr -d '\r' < "$rf" | sed -nE 's/^[[:space:]]*(reviewed[-_ ]?)?commit[[:space:]]*:[[:space:]]*"?([0-9a-fA-F]{7,40}).*/\2/p' | head -n 1)"
    if [[ -z "$VM_BASE" ]]; then VM_BASE="$(cd "$ROOT" && git log -1 --format=%H -- "$(rel "$rf")" 2>/dev/null || true)"; fi
  fi
}
scoped_prompt() { # -> the sentence added to the verifier's prompt in a scoped re-verification
  local base=""
  if [[ -n "$VM_BASE" ]]; then base="the diff since commit $VM_BASE (git diff $VM_BASE..HEAD, plus uncommitted changes)"; else base="the diff since the last review.md was written (no commit is recorded in it: use git log and git status, and the Bug files' Status)"; fi
  printf '%s' "RE-VERIFICATION MODE (agents/verifier.md -> Re-verification mode): this is not the first verification of $C_SPEC; a review.md with the verdict CHANGES_NEEDED exists. Do NOT run a full pass. Re-verify only (a) every Bug item whose Status changed since that review (fixed, wontfix, blocked), and (b) the acceptance criteria and Test IDs whose files changed in $base. Always run the mandatory mechanical checks: quality-gate and check-traceability. Copy every other verdict row from the previous review.md unchanged, and state in the new review.md that those rows were carried over from the previous review and not re-run. Verify a fix for real (run its regression test and the commands that exercise it); file a new Bug only for a failure in the re-verified scope or in a changed file. If an orchestrator session runs this state, put this paragraph verbatim in the verifier subagent's handover packet."
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
      rv="$(tr -d '\r' < "$rf" | sed -nE 's/^[Vv][Ee][Rr][Dd][Ii][Cc][Tt][[:space:]]*:[[:space:]]*"?([A-Za-z_-]+).*/\1/p' | head -n 1 | tr 'a-z' 'A-Z' | tr '-' '_')"
      if [[ -z "$rv" ]]; then rv="$(grep -oiwE 'APPROVED|CHANGES[_-]NEEDED|TOOLCHAIN[_-]DEFERRED|BLOCKED' "$rf" | head -n 1 | tr 'a-z' 'A-Z' | tr '-' '_' || true)"; fi
      if [[ "$rv" == "APPROVED" ]]; then CHK_RC=0
      elif [[ "$rv" == "TOOLCHAIN_DEFERRED" ]]; then CHK_RC=3; CHK_VIOL="REVIEW-003 (human): review verdict TOOLCHAIN_DEFERRED (a required scanner is missing); this is not a pass"
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
      done < <(printf '%s' "${S_CPS[$i]:-}" | tr '\037' '\n')
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
limit_re() { # $1 harness
  local f="$ROOT/.KCC/kernel/limit-patterns.json" d="" h=""
  if [[ -f "$f" ]]; then
    d="$(tr -d '\r' < "$f" | sed -n 's/^ *"limit_regex\.default": *"\(.*\)",\{0,1\} *$/\1/p' | head -n 1)"
    h="$(tr -d '\r' < "$f" | sed -n 's/^ *"limit_regex\.'"$1"'": *"\(.*\)",\{0,1\} *$/\1/p' | head -n 1)"
  fi
  if [[ -n "$d" && -n "$h" ]]; then printf '%s|%s' "$d" "$h"
  elif [[ -n "$d$h" ]]; then printf '%s' "$d$h"
  else printf '%s' "$LIMIT_RE_BUILTIN"; fi
}
limit_hit() { # $1 log, $2 rc
  local t h f
  if [[ "$2" != "0" ]]; then
    t="$(tail -n 60 "$1" 2>/dev/null | tr 'A-Z' 'a-z' || true)"
    if printf '%s' "$t" | grep -Eq "$(limit_re "$HARNESS")"; then return 0; fi
    if printf '%s' "$t" | grep -Eq '(^|[^0-9])429([^0-9]|$)'; then return 0; fi
    return 1
  fi
  # Exit 0: the session finished its turn, so prose such as "rate-limit values are assumptions" is not
  # a limit. Only the harness's own limit notice on the final lines counts.
  f="$ROOT/.KCC/kernel/limit-patterns.json"; h=""
  if [[ -f "$f" ]]; then h="$(tr -d '\r' < "$f" | sed -n 's/^ *"limit_regex\.'"$HARNESS"'": *"\(.*\)",\{0,1\} *$/\1/p' | head -n 1)"; fi
  [[ -n "$h" ]] || return 1
  t="$(grep -v '^[[:space:]]*$' "$1" 2>/dev/null | tail -n 3 | tr 'A-Z' 'a-z' || true)"
  printf '%s' "$t" | grep -Eq "$h"
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
test_bypass() { local l; l="$(printf '%s' "$1" | tr 'A-Z' 'a-z')"; case "$l" in *dangerously-skip*|*dangerously-bypass*|*bypasspermissions*|*--yolo*) return 0 ;; esac; if printf '%s' "$l" | grep -Eq 'permission-mode[[:space:]]+bypass'; then return 0; fi; return 1; }
sanitize_prompt() { printf '%s' "$1" | tr '\r\n\t' '   ' | sed -e "s/\"/'/g" -e "s/\`/'/g" -e 's/\$//g' -e 's/%/ pct/g' -e 's/!/./g' -e 's#\\#/#g' | tr -s ' ' | sed 's/^ //; s/ $//'; }
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
resolve_claude_model() { # bare aliases -> pinned 5.5 IDs (`haiku` can still mean Haiku 4.5, which has no auto mode)
  case "$(printf '%s' "$1" | tr 'A-Z' 'a-z')" in
    haiku) echo "claude-haiku-5-5" ;;
    sonnet) echo "claude-sonnet-5-5" ;;
    opus) echo "claude-opus-5-5" ;;
    *) echo "$1" ;;
  esac
}
# ---- harness profile and model registry: nothing below assumes a particular harness ---------------------
# kernel/harnesses.json says how each harness takes an agent, a model and an effort; kernel/models.json says which model each
# tier is on each harness (settings run.registry picks another column, e.g. 'ollama' behind the opencode harness).
hprofile() { # key -> settings harness_invoke.<harness>.<key>, else kernel/harnesses.json
  local v; v="$(setting "harness_invoke.$HARNESS.$1" "")"
  if [[ -z "$v" ]]; then v="$(flat_get "$HARNESSES_FLAT" "harnesses.$HARNESS.$1")"; fi
  if [[ "$v" == "null" ]]; then v=""; fi
  printf '%s' "$v"
}
heffort() { # neutral effort -> what the harness accepts (effort_map), unchanged when not mapped
  local m; m="$(flat_get "$HARNESSES_FLAT" "harnesses.$HARNESS.effort_map.$1")"
  if [[ -n "$m" && "$m" != "null" ]]; then printf '%s' "$m"; else printf '%s' "$1"; fi
}
tier_model() { # tier -> model id on the registry column of the active harness (with its prefix), or nothing
  local reg id prefix; reg="$(setting run.registry "")"; [[ -n "$reg" ]] || reg="$HARNESS"
  id="$(flat_get "$REGISTRY_FLAT" "harnesses.$reg.$1.id")"
  if [[ -z "$id" || "$id" == "null" ]]; then return 0; fi
  prefix="$(flat_get "$REGISTRY_FLAT" "harnesses.$reg._prefix")"; if [[ "$prefix" == "null" ]]; then prefix=""; fi
  printf '%s%s' "$prefix" "$id"
}
# The model for the orchestrator wrapper or the escalation: an explicit run.<kind>_model wins, except that a Claude id is
# never passed to another harness; otherwise the tier (run.<kind>_tier) on the active harness's registry column.
run_model() { # kind defaultTier
  local explicit tier; explicit="$(setting "run.$1_model" "" | tr -cd 'A-Za-z0-9._:/-')"
  if [[ -n "$explicit" ]] && { [[ "$HARNESS" == "claude" ]] || ! [[ "$explicit" =~ ^(claude-|opus$|sonnet$|haiku$) ]]; }; then
    if [[ "$HARNESS" == "claude" ]]; then resolve_claude_model "$explicit"; else printf '%s' "$explicit"; fi
    return 0
  fi
  tier="$(setting "run.$1_tier" "$2" | tr -cd 'a-z')"
  tier_model "$tier"
}
# Every dispatch, in every cycle, asks the router (`.KCC/tools/kcc-route`, the port of cli/src/run/router.ts) which tier,
# model and effort the state's agent gets: from the agent's profile, the plan's Complexity and files for this wave or spec,
# the idea's domain, CR-7 words and the attempt. One rulebook (kernel/protocols/model-routing.md), three identical copies.
# get_route AGENT ATTEMPT -> sets RT_TIER RT_MODEL RT_EFFORT RT_WHY (empty when the router gave nothing)
get_route() {
  RT_TIER=""; RT_MODEL=""; RT_EFFORT=""; RT_WHY=""
  [[ -n "${1:-}" && -f "$TOOLS/kcc-route.sh" ]] || return 0
  local a=(--repo-root "$ROOT" --agent "$1" --attempt "$2" --harness "$HARNESS") line tab
  tab="$(printf '\t')"
  [[ -n "$C_SPEC" ]] && a+=(--spec "$C_SPEC")
  [[ -n "$C_WAVE" ]] && a+=(--wave "$C_WAVE")
  [[ -n "${ROUTE_EXTRA:-}" ]] && a+=($ROUTE_EXTRA)
  line="$(bash "$TOOLS/kcc-route.sh" "${a[@]}" 2>/dev/null | grep "$tab" | tail -n 1 || true)"
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
  if [[ "$fast" -eq 1 ]]; then AM_WM="$(run_model orchestrator fast)"; AM_WE="$(setting run.orchestrator_effort low | tr -cd 'a-z')"; fi
  AM_MODE=wrapper
  # Direct needs fast track, a harness that selects an agent by flag, and an agent file in that harness's agent folder.
  local adir; adir="$(hprofile agent_dir)"
  if [[ "$fast" -eq 1 && "$(setting run.fasttrack_direct true | tr 'A-Z' 'a-z')" != "false" && -n "$AM_AGENT" && -n "$(hprofile agent)" && -n "$adir" && -f "$ROOT/$adir/$AM_AGENT.md" ]]; then AM_MODE=direct; fi
  if [[ -z "$AM_AGENT" && "$fast" -eq 0 ]]; then AM_MODE=""; fi
}
idea_domain() { # Research.md -> '## Domain' (common | specialised | novel)
  local f="$ROOT/ideation/${1:-}/Research.md" v=""
  [[ -n "${1:-}" && -f "$f" ]] || { printf ''; return 0; }
  v="$(tr -d '\r' < "$f" | awk 'BEGIN{IGNORECASE=1} /^##[[:space:]]+Domain/ { if (match($0, /:[[:space:]]*`?(common|specialised|specialized|novel)/)) { print tolower(substr($0, RSTART+1, RLENGTH-1)); exit } f=1; next } f && /[A-Za-z]/ { print tolower($0); exit }' | grep -oE 'common|specialised|specialized|novel' | head -n 1)"
  [[ "$v" == "specialized" ]] && v=specialised
  printf '%s' "$v"
}
hflag() { # template key value -> the flag with the value in it, or nothing
  local tpl="$1" key="$2" val="$3" ph
  if [[ -z "$tpl" || -z "$val" ]]; then return 0; fi
  ph="{$key}"
  printf '%s' "${tpl//"$ph"/$val}"
}
harness_extra() { # after agent_mode: the flags that pick the agent, model and effort, written the way the active harness takes them
  local m e out="" f
  if [[ "$AM_MODE" == "direct" ]]; then m="$AM_MODEL"; e="$AM_EFFORT"; out="$(hflag "$(hprofile agent)" agent "$AM_AGENT")"
  elif [[ "$AM_MODE" == "wrapper" ]]; then m="$AM_WM"; e="$AM_WE"
  else return 0; fi
  f="$(hflag "$(hprofile model)" model "$m")"; if [[ -n "$f" ]]; then out="${out:+$out }$f"; fi
  f="$(hflag "$(hprofile effort)" effort "$(heffort "$e")")"; if [[ -n "$f" ]]; then out="${out:+$out }$f"; fi
  printf '%s' "$out"
}
convert_agent_body() { # "/skill args" -> instruction that names the skill file
  if [[ "$1" =~ ^/([a-z][a-z0-9-]*)[[:space:]]*(.*)$ ]]; then
    local sp skill="${BASH_REMATCH[1]}" rest="${BASH_REMATCH[2]}"; sp="$(hprofile skill_path)"; if [[ -z "$sp" ]]; then sp=".claude/skills/{skill}/SKILL.md"; fi
    printf 'Do the work of the skill described in %s (read it first) with these arguments: %s' "${sp//"{skill}"/$skill}" "$rest"
  else printf '%s' "$1"; fi
}
harness_cmd() {
  local tpl perm p ins
  tpl="$(setting "continuity.start.$HARNESS" "")"
  if [[ -z "$tpl" ]]; then return 0; fi
  ins="$(hprofile insert_after)"
  if [[ -n "$HARNESS_EXTRA" && -n "$ins" ]]; then
    # put the flags after the first " <ins> " token of the start template, without sed so no character of the flags is special
    case "$tpl" in *" $ins "*) tpl="${tpl/" $ins "/" $ins $HARNESS_EXTRA "}" ;; esac
  fi
  perm="$(setting continuity.permission_mode auto | sed 's/[^A-Za-z]//g')"; [[ -n "$perm" ]] || perm=auto
  p="$(sanitize_prompt "$1")"
  tpl="${tpl//\{resume_prompt\}/"$p"}"; tpl="${tpl//\{permission_mode\}/"$perm"}"; tpl="${tpl//\{session_id\}/}"
  printf '%s' "$tpl"
}
invoke_harness() { # $1 prompt, $2 log -> LAST_HARNESS_RC
  local cmd rc=0
  cmd="$(harness_cmd "$1")"
  if [[ -z "$cmd" ]]; then stop_run env "no continuity.start template for harness $HARNESS in .KCC/settings.json" 2; fi
  if test_bypass "$cmd"; then stop_run env "refusing a harness template with a permission-bypass flag: $cmd" 2; fi
  mkdir -p "$(dirname "$2")"
  printf '# kcc-run %s harness %s\n# %s\n' "$(iso)" "$HARNESS" "$cmd" > "$2"
  if command -v timeout >/dev/null 2>&1; then
    (cd "$ROOT" && timeout "${CFG_TIMEOUT}m" sh -c "$cmd") >> "$2" 2>&1 < /dev/null || rc=$?
  else
    (cd "$ROOT" && sh -c "$cmd") >> "$2" 2>&1 < /dev/null || rc=$?
  fi
  if [[ $rc -eq 124 ]]; then printf '\n# kcc-run: harness timed out after %s minute(s)\n' "$CFG_TIMEOUT" >> "$2"; fi
  LAST_HARNESS_RC=$rc
  R_last_log="$(rel "$2")"
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
  show_pause
  prompt_gate
}
prompt_gate() { # sets OUTCOME paused|answered
  OUTCOME=paused
  # A silent run has no human. The one gate it answers itself is a deferred quality check (a scanner that is not
  # installed): accepting it is recorded in the gate file, the decision event and closed.md, and is never a pass.
  # Every other gate pauses the run, and a silent run never waits on a console that nobody answers.
  if [[ "$R_silent" == "1" ]]; then
    if [[ "$R_gate_name" == "quality-deferred-on-exit-3" ]]; then
      NOTE="silent run: deferred quality check accepted by policy (not a pass); install the missing tool and re-run the gate to close it"
      say "kcc-run: $NOTE"
      apply_answer "accept-deferred"; OUTCOME=answered
    fi
    return 0
  fi
  if [[ "$JSON" -eq 1 || "${KCC_RUN_NO_PROMPT:-}" == "1" ]]; then return 0; fi
  if [[ ! -t 0 || ! -t 1 ]]; then return 0; fi
  local a
  while true; do
    read -r -p "answer [$R_gate_answers]: " a || return 0
    case "/$R_gate_answers/" in *"/$a/"*) apply_answer "$a"; OUTCOME=answered; return 0 ;; esac
    say "  not an allowed answer: $a"
  done
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
  emit human-gate-decision "$R_gate_spec" "{\"gate\":\"$gname\",\"gate_id\":\"$gid\",\"answer\":\"$ans\",\"state\":${R_gate_state:-0},\"wave\":\"$R_gate_wave\",\"trigger_event_id\":\"$R_gate_event\",\"note\":\"$(jesc "$NOTE")\",\"source\":\"kcc-run\"}" dash
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
        elif [[ "$ans" == "defer" ]]; then emit toolchain-gate-decision "$R_gate_spec" '{"choice":"defer","verdict":"TOOLCHAIN_DEFERRED","source":"kcc-run"}'; pa=done
        else pa=recheck; fi ;;
      quality-deferred-on-exit-3) if [[ "$ans" == "install" ]]; then pa=install; else pa=done; fi ;;
      ruling)
        # revise and escalate reopen the blocked bugs and re-run the fix with the ruling as the note; waive records them as wontfix
        if [[ "$ans" == "waive" ]]; then pa=recheck; else
          pa=rerun; set_att "$key" 0
          if [[ -z "$NOTE" ]]; then R_note="the human answered $ans without a note: apply the recommended option of the Ruling needed section of each reopened Bug item, then set its Status to fixed"
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
  key="$(unit_key "$i")"; label="$(unit_label "$i")"
  kind="${S_EV[$i]:-run-state-completed}"
  sp="${C_SPEC:-$C_IDEA}"
  if [[ "$2" == "1" ]]; then skipped=true; fi
  emit "$kind" "$sp" "{\"state\":${S_ID[$i]},\"state_name\":\"${S_NAME[$i]}\",\"wave\":\"$C_WAVE\",\"attempt\":$(get_att "$key"),\"skipped\":$skipped,\"source\":\"kcc-run\"}"
  set_att "$key" 0
  R_last_violations=""
  if [[ "${S_ID[$i]}" == "1" || -z "$R_idea" ]]; then detect_idea; fi
  if [[ "${S_NAME[$i]}" == "SPECS" || ( "${S_CMD[$i]}" == /spec-create* && "${S_SCOPE[$i]}" == "run" ) ]]; then load_specs; fi
  cp="${S_CK[$i]}"; if [[ -z "$cp" && "${S_NAME[$i]}" == "REVIEW" ]]; then cp=spec-reviewed; fi
  if [[ -n "$cp" ]]; then invoke_checkpoint "$cp" "kcc-run: $label completed; run kcc-run -Resume"; fi
  if [[ "$2" == "1" ]]; then say "kcc-run: done   $label (exit check already passes)"; else say "kcc-run: done   $label"; fi
  refresh_dashboard
}
process_unit() { # $1 idx -> OUTCOME next|retry|goto|paused|answered
  local i="$1" key label pa gname gkind has_check interactive force skip_dispatch pre_done=0 pre_rc=0 pre_viol=""
  key="$(unit_key "$i")"; label="$(unit_label "$i")"
  pa="$R_pending_action"; R_pending_action=""
  OUTCOME=next
  if [[ -n "${S_ONLY[$i]}" ]] && ! in_list "$R_scenario" "${S_ONLY[$i]}"; then return 0; fi
  sf="$(skip_flag "$i")"
  if [[ -n "$sf" ]]; then say "kcc-run: skip   $label ($sf)"; return 0; fi
  if [[ "$pa" == "abort" ]]; then stop_run aborted "human chose abort" 6; fi
  if [[ "$pa" == "done" ]]; then complete_unit "$i" 0; return 0; fi
  if [[ "$pa" == goto:* ]]; then
    local target="${pa#goto:}" tidx; R_state="$target"; add_force "$target"; tidx="$(get_idx "$target")"
    if [[ "${S_SCOPE[$tidx]}" == "wave" ]]; then R_wave=""; fi
    OUTCOME=goto; return 0
  fi
  gname="$(gate_name "$i")"
  gkind=failure; if is_approval_gate "$gname"; then gkind=approval; fi
  has_check=0; if [[ -n "${S_CT[$i]}" ]]; then has_check=1; fi
  interactive=0; if [[ -n "${S_INT[$i]}" ]] && in_list "$R_scenario" "${S_INT[$i]}"; then interactive=1; fi
  force=0; if test_force "${S_ID[$i]}" || [[ "$pa" == "rerun" ]]; then force=1; fi
  if [[ "$pa" == "rerun" ]]; then set_att "$key" 0; fi
  skip_dispatch=0; case "$pa" in recheck|approved|gatecheck) skip_dispatch=1 ;; esac
  LAST_HARNESS_RC=-1

  if [[ "$pa" == "install" ]]; then
    local ilog="$LOG_DIR/state-${S_ID[$i]}-$(safe_name "$C_SPEC")-install.log"
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

  if [[ $skip_dispatch -eq 0 && $has_check -eq 1 && $force -eq 0 && "$(get_att "$key")" == "0" && "${S_SCOPE[$i]}" != "wave" && "${S_CT[$i]}" != "internal:agent-report" ]] \
     && [[ -n "$R_idea" || "${S_ID[$i]}" == "0" ]] && ! [[ "$gkind" == "approval" && -n "$gname" ]] && precheck_ready "$i"; then
    run_check "$i" "$key"
    if [[ $CHK_RC -eq 0 ]]; then complete_unit "$i" 1; return 0; fi
    pre_done=1; pre_rc=$CHK_RC; pre_viol="$CHK_VIOL"
  fi

  # ---- dispatch ----
  local has_cmd=0 att need_fix=0
  if [[ -n "${S_CMD[$i]}" ]]; then has_cmd=1; fi
  att="$(get_att "$key")"
  if [[ $has_cmd -eq 0 && $att -gt 0 && $has_check -eq 1 && -z "$gname" ]]; then need_fix=1; fi
  VM_MODE=""; VM_BASE=""
  # A bug the implementer cannot fix without a human ruling (Status blocked) opens the ruling gate at once: no dispatch, no attempt used.
  if [[ "${S_CT[$i]}" == "internal:no-open-bugs" && -n "$C_ENTRY" ]]; then
    run_check "$i" "$key"
    if [[ -n "$CHK_BLOCKED" && -z "$CHK_OPEN" ]]; then R_last_violations="$(sanitize_prompt "$CHK_VIOL")"; ruling_gate "$i"; return 0; fi
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
    if [[ $has_cmd -eq 1 ]]; then body="$(render "$(state_cmd "$i")")"; else body="The exit check \`$(check_desc "$i")\` failed. Route each violation to its fix_owner and fix it."; fi
    where=""; if [[ -n "$C_SPEC" ]]; then where=" for $C_SPEC"; fi; if [[ -n "$C_WAVE" ]]; then where="$where wave $C_WAVE"; fi
    # Full runs wrap each unit with the butler (CR-8: brief first, remember after); fasttrack keeps it to the run's
    # first and last states, which name it in their command. CLOSE already names it.
    local butler_line=""
    if [[ "$R_fasttrack" != "1" && "${S_NAME[$i]}" != "CLOSE" && "$(setting run.butler on | tr 'A-Z' 'a-z')" != "off" ]]; then butler_line="Wrap the work with the butler as the spawn protocol requires: spawn it to brief you first (butler-brief) and to remember afterwards (butler-remember). "; fi
    local lead=". Follow coordination/orchestrator.md Spawn protocol and the state's contract. ${butler_line}Do only this state, then stop. This is a non-interactive session that ends when you reply: run every subagent in the foreground (never run_in_background) and wait for all of them, including parallel ones, before you finish. "
    HARNESS_EXTRA=""
    agent_mode "$i" "$att"
    if [[ -n "$AM_MODE" ]]; then
      HARNESS_EXTRA="$(harness_extra)"
      if [[ "$AM_MODE" == "direct" ]]; then
        body="$(convert_agent_body "$body")"
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
    if [[ $att -gt 0 && -n "$R_last_violations" ]]; then prompt="$prompt RETRY $((att + 1))/$CFG_MAX - fix these exit-check violations: $R_last_violations"; fi
    if [[ $att -eq 0 && -n "$R_last_violations" ]] && test_force "${S_ID[$i]}"; then prompt="$prompt A later stage failed and sent this spec back. The open Bug items in the spec Backlog and these violations are the work of this pass; fix them test-first and write only the files they name: $R_last_violations"; fi
    if [[ -n "$R_note" ]]; then prompt="$prompt Human note: $R_note"; R_note=""; fi
    if [[ "${S_SCOPE[$i]}" == "wave" && $att -eq 0 ]]; then invoke_checkpoint manual "kcc-run: baseline before $label"; fi
    local tag="run"; if [[ -n "$C_SPEC" ]]; then tag="$C_SPEC"; if [[ -n "$C_WAVE" ]]; then tag="$tag-w$C_WAVE"; fi; fi
    log="$LOG_DIR/state-${S_ID[$i]}-$(safe_name "$tag")-$((att + 1)).log"
    say "kcc-run: run    $label (attempt $((att + 1))/$CFG_MAX) -> $(rel "$log")"
    save_run
    refresh_dashboard
    # Every dispatch records a start and an end with its spec and agent, so the dashboard can show runs that overlap (one agent per spec).
    local ar_agent="${AM_AGENT:-orchestrator}" ar_t0 ar_t1
    ar_t0="$(date +%s)"
    emit agent-run-started "$C_SPEC" "{\"state\":${S_ID[$i]},\"state_name\":\"${S_NAME[$i]}\",\"agent\":\"$ar_agent\",\"model\":\"${AM_MODEL:-}\",\"effort\":\"${AM_EFFORT:-}\",\"attempt\":$((att + 1)),\"wave\":\"$C_WAVE\",\"log\":\"$(rel "$log")\",\"started\":\"$(iso)\",\"source\":\"kcc-run\"}"
    invoke_harness "$prompt" "$log"
    HARNESS_EXTRA=""
    ar_t1="$(date +%s)"
    emit agent-run-ended "$C_SPEC" "{\"state\":${S_ID[$i]},\"state_name\":\"${S_NAME[$i]}\",\"agent\":\"$ar_agent\",\"attempt\":$((att + 1)),\"wave\":\"$C_WAVE\",\"log\":\"$(rel "$log")\",\"exit\":$LAST_HARNESS_RC,\"seconds\":$((ar_t1 - ar_t0)),\"ended\":\"$(iso)\",\"source\":\"kcc-run\"}"
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
  if [[ $pre_done -eq 1 ]]; then CHK_RC=$pre_rc; CHK_VIOL="$pre_viol"; else run_check "$i" "$key-$(( $(get_att "$key") + 1 ))"; fi
  # A passing check proves nothing when the state's artifact was never written (a conformance scope with
  # nothing in it passes): precheck_requires is also the state's required output.
  if [[ $CHK_RC -eq 0 && -n "${S_PR[$i]}" && -z "$R_idea" ]]; then detect_idea; new_ctx "$C_ENTRY" "$C_WAVE"; fi
  if [[ $CHK_RC -eq 0 ]] && ! precheck_ready "$i"; then
    CHK_RC=1; CHK_VIOL="REQ-001: state ${S_ID[$i]} ${S_NAME[$i]} finished but did not produce $(render "${S_PR[$i]}")"
  fi
  if [[ $CHK_RC -eq 0 ]]; then complete_unit "$i" 0; return 0; fi
  R_last_violations="$(sanitize_prompt "$CHK_VIOL")"
  if [[ ${#R_last_violations} -gt 1500 ]]; then R_last_violations="${R_last_violations:0:1500} ..."; fi
  if [[ $CHK_RC -eq 2 ]]; then stop_run stopped "exit check for $label returned a usage/environment error: $R_last_violations" 6; fi
  # Only blocked bugs are left (the pass fixed the others): they need a human ruling, so no retry and no attempt is used.
  if [[ -n "$CHK_BLOCKED" && -z "$CHK_OPEN" ]]; then ruling_gate "$i"; return 0; fi
  if [[ $CHK_RC -eq 3 ]]; then
    local g="$gname"; if [[ -z "$g" || "$gkind" == "approval" ]]; then g=quality-deferred-on-exit-3; fi
    open_gate "$g" failure "Exit check for $label is DEFERRED (exit 3): a required external tool is missing. This is not a pass." "$i" "$R_last_violations"
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
  att=$(( $(get_att "$key") + 1 ))
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
  idx="$(get_idx "$R_state")"
  if [[ "${S_SCOPE[$idx]}" == "wave" ]]; then
    nw="$(next_wave "$(spec_entry_at "$R_spec_index")" "$R_wave")"
    if [[ -n "$nw" ]]; then R_wave="$nw"; return 0; fi
  fi
  R_wave=""
  clear_force "${S_ID[$idx]}"
  if [[ $idx -ge $SPEC_FIRST && $idx -le $SPEC_LAST ]]; then
    if [[ $idx -lt $SPEC_LAST ]]; then R_state="${S_ID[$((idx + 1))]}"; return 0; fi
    R_spec_index=$((R_spec_index + 1))
    if [[ $R_spec_index -lt $(spec_count) ]]; then R_state="${S_ID[$SPEC_FIRST]}"; R_force=""; return 0; fi
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
  idx="$(get_idx "$R_state")"; U_IDX=$idx
  if [[ $idx -lt 0 ]]; then return 0; fi
  if [[ "${S_SCOPE[$idx]}" == "run" ]]; then new_ctx "" ""; return 0; fi
  if [[ -z "$R_specs" ]]; then load_specs; fi
  if [[ -z "$R_specs" ]]; then stop_run stopped "no specs found for $R_idea (ROADMAP.md) at state ${S_ID[$idx]}" 6; fi
  if [[ $R_spec_index -ge $(spec_count) ]]; then R_spec_index=0; fi
  entry="$(spec_entry_at "$R_spec_index")"
  if [[ "${S_SCOPE[$idx]}" == "wave" ]]; then
    waves="$(get_waves "$entry")"
    if [[ -z "$waves" ]]; then stop_run stopped "plan.md for $entry has no ## Waves table" 6; fi
    if [[ -z "$R_wave" ]] || ! printf '%s\n' "$waves" | grep -qx "$R_wave"; then R_wave="$(printf '%s\n' "$waves" | head -1)"; fi
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
    finish done 0
  fi
  resolve_unit
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
            say "kcc-run: --until $UNTIL reached; run stopped (resume with --resume)"; finish until-done 0
          fi
        fi
      fi
      save_run; continue ;;
    *) stop_run stopped "unexpected unit outcome $OUTCOME" 6 ;;
  esac
done
