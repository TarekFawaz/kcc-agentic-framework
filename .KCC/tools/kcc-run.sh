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
#              [--harness claude|codex|opencode|generic] [--resume]
#              [--answer <choice>] [--from <stateId>] [--only <stateId>]
#              [--dry-run] [--json] [--max-attempts N] [--repo-root PATH]
#              [--remote-url URL] [--note "text"]
#
# Exit: 0 done / dry-run / --only finished, 2 usage or environment error,
#       4 paused at a human gate, 5 suspended (usage limit), 6 stopped/aborted.
# Requires bash 3.2+, awk, sed, grep. No python/jq.
set -euo pipefail

VERSION="1.0.0"
IN_TEXT=""; SILENT=0; ASSUME=0; ACC=""; BUDGET=""; CURRENCY=""; PARALLEL=0; HARNESS_ARG=""
RESUME=0; ANSWER=""; FROM=""; ONLY=""; DRY=0; JSON=0; MAXATT=0; REPO_ROOT=""; REMOTE_URL=""; NOTE=""

usage() { sed -n '14,23p' "$0" | sed 's/^# \{0,1\}//'; }
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
    --harness|-Harness) HARNESS_ARG="${2:-}"; shift 2 ;;
    --resume|-Resume) RESUME=1; shift ;;
    --answer|-Answer) ANSWER="${2:-}"; shift 2 ;;
    --from|-From) FROM="${2:-}"; shift 2 ;;
    --only|-Only) ONLY="${2:-}"; shift 2 ;;
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
if [[ -n "$FROM" && ! "$FROM" =~ ^[0-9]+$ ]]; then fail_usage "--from must be a state id"; fi
if [[ -n "$ONLY" && ! "$ONLY" =~ ^[0-9]+$ ]]; then fail_usage "--only must be a state id"; fi
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
  else if(r=="check.pass_when") PW[i]=v; else if(r=="check.min_pct") MN[i]=v; else if(r=="check.expect") EX[i]=v
  else if(r=="check.then.tool") TT[i]=v; else if(r ~ /^check\.then\.args\./) app(TA,i,v,"\037")
  else if(r ~ /^gate\./){ g=r; sub(/^gate\./,"",g); if(g=="S1") G1[i]=v; else if(g=="S2") G2[i]=v; else if(g=="S3") G3[i]=v; else if(g=="all") GA[i]=v }
  else if(r ~ /^interactive_in\./) app(IN,i,v," "); else if(r ~ /^only_in\./) app(ON,i,v," ")
  else if(r=="skip_if_flag") SK[i]=v; else if(r=="event") EV[i]=v; else if(r=="on_fail_goto") GO[i]=v; else if(r=="checkpoint") CK[i]=v
  next }
$1 ~ /^gates\.[^.]+\.[0-9]+$/ { g=$1; sub(/^gates\./,"",g); sub(/\.[0-9]+$/,"",g); if(!(g in GI)){ GI[g]=ng; GN[ng]=g; ng++ }; app(GV,GI[g],$2,"/"); next }
BEGIN { ng=0; mx=-1 }
$1=="max_attempts" { print "SM_MAX=" q($2) }
END{
  print "S_COUNT=" (mx+1); print "G_COUNT=" ng+0
  for(i=0;i<=mx;i++){
    printf "S_ID[%d]=%s; S_NAME[%d]=%s; S_SCOPE[%d]=%s; S_CMD[%d]=%s; S_CT[%d]=%s; S_CA[%d]=%s; S_CP[%d]=%s; S_PW[%d]=%s; S_MIN[%d]=%s; S_EXP[%d]=%s\n", i,q(ID[i]),i,q(NM[i]),i,q(SC[i]),i,q(CM[i]),i,q(CT[i]),i,q(CA[i]),i,q(CP[i]),i,q(PW[i]),i,q(MN[i]),i,q(EX[i])
    printf "S_TT[%d]=%s; S_TA[%d]=%s; S_G1[%d]=%s; S_G2[%d]=%s; S_G3[%d]=%s; S_GA[%d]=%s; S_INT[%d]=%s; S_ONLY[%d]=%s; S_SKIP[%d]=%s; S_EV[%d]=%s; S_GOTO[%d]=%s; S_CK[%d]=%s\n", i,q(TT[i]),i,q(TA[i]),i,q(G1[i]),i,q(G2[i]),i,q(G3[i]),i,q(GA[i]),i,q(IN[i]),i,q(ON[i]),i,q(SK[i]),i,q(EV[i]),i,q(GO[i]),i,q(CK[i])
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
CFG_MAX="$(setting run.max_attempts "$SM_MAX")"; [[ "$CFG_MAX" =~ ^[0-9]+$ && "$CFG_MAX" -ge 1 ]] || CFG_MAX=3
if [[ "$MAXATT" -gt 0 ]]; then CFG_MAX="$MAXATT"; fi
CFG_TIMEOUT="$(setting run.state_timeout_minutes 60)"; [[ "$CFG_TIMEOUT" =~ ^[0-9]+$ && "$CFG_TIMEOUT" -ge 1 ]] || CFG_TIMEOUT=60

# ---- run.json -------------------------------------------------------------------------------
RUN_KEYS="schema status reason created updated harness input input_class scenario silent assume accuracy budget currency parallel sequential idea ideas_before specs state spec_index wave attempts force pending_action gate_id gate_name gate_kind gate_answers gate_state gate_spec gate_wave gate_event last_log last_violations note"
new_run() {
  local k; for k in $RUN_KEYS; do eval "R_$k=''"; done
  R_schema="kcc-run/1"; R_status="running"; R_created="$(iso)"; R_scenario="S1"; R_silent=0; R_assume=0
  R_accuracy=95; R_currency="USD"; R_parallel=0; R_sequential=0; R_state=0; R_spec_index=0
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
  if printf '%s' "$txt" | grep -q 'devops-cloud'; then addt terraform; fi
  if printf '%s' "$txt" | grep -q 'devops-k8s-onprem-agnostic'; then addt terraform,kubectl,helm; fi
  if printf '%s' "$txt" | grep -Eq '(^|[^a-z])pnpm([^a-z]|$)'; then addt pnpm; fi
  addt git
  printf '%s' "$out"
}

# ---- context + rendering -------------------------------------------------------------------------
C_IDEA=""; C_SPEC=""; C_ENTRY=""; C_WAVE=""
new_ctx() { C_ENTRY="$1"; C_WAVE="$2"; C_IDEA="$R_idea"; C_SPEC=""; if [[ -n "$1" ]]; then C_IDEA="${1%%/*}"; C_SPEC="$(spec_id "${1#*/}")"; fi; }
render() {
  local t="$1" sa="" par="" tools=""
  if [[ "$R_scenario" != "S1" ]]; then sa="--silent --assume"; fi
  if [[ "$R_parallel" == "1" ]]; then par="--parallel"; fi
  if [[ "$t" == *"{TOOLS}"* ]]; then if [[ -n "$C_ENTRY" ]]; then tools="$(derived_tools "$C_ENTRY")"; else tools=git; fi; fi
  t="${t//\{input\}/"$R_input"}"; t="${t//\{IDEA\}/"$C_IDEA"}"; t="${t//\{SPEC\}/"$C_SPEC"}"; t="${t//\{WAVE\}/"$C_WAVE"}"; t="${t//\{ITEM\}/}"
  t="${t//\{silent_assume\}/"$sa"}"; t="${t//\{parallel\}/"$par"}"; t="${t//\{flags\}/"$sa $par"}"; t="${t//\{TOOLS\}/"$tools"}"
  while [[ "$t" == *"  "* ]]; do t="${t//  / }"; done
  t="${t# }"; t="${t% }"
  printf '%s' "$t"
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
check_desc() { # $1 idx, $2 = "then" for the then-check
  local i="$1" tool args s
  if [[ "${2:-}" == "then" ]]; then tool="${S_TT[$i]}"; args="${S_TA[$i]}"; else tool="${S_CT[$i]}"; args="${S_CA[$i]}"; fi
  s="$tool"
  if [[ -n "$args" ]]; then s="$s $(render "$(printf '%s' "$args" | tr '\037' ' ')")"; fi
  if [[ "${2:-}" != "then" && -n "${S_CP[$i]}" ]]; then s="$s $(render "${S_CP[$i]}")"; fi
  if [[ "${2:-}" != "then" && -n "${S_PW[$i]}" ]]; then s="$s [pass_when ${S_PW[$i]}]"; fi
  if [[ "${2:-}" != "then" && -n "${S_TT[$i]}" ]]; then s="$s THEN $(check_desc "$i" then)"; fi
  printf '%s' "$s"
}
LAST_HARNESS_RC=-1
CHK_RC=0; CHK_VIOL=""
run_check() { # $1 idx, $2 label, $3 = "then"
  local i="$1" label="$2" tool args
  if [[ "${3:-}" == "then" ]]; then tool="${S_TT[$i]}"; args="${S_TA[$i]}"; else tool="${S_CT[$i]}"; args="${S_CA[$i]}"; fi
  CHK_VIOL=""
  case "$tool" in
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
    internal:file-exists)
      local p; p="$(render "${S_CP[$i]}")"
      if [[ -e "$ROOT/$p" ]]; then CHK_RC=0; else CHK_RC=1; CHK_VIOL="FILE-001 (agent): missing $p"; fi
      return 0 ;;
    internal:agent-report)
      if [[ "$LAST_HARNESS_RC" == "0" ]]; then CHK_RC=0; else CHK_RC=1; CHK_VIOL="AGENT-001 (agent): harness exited $LAST_HARNESS_RC; expected: ${S_EXP[$i]}"; fi
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
  if [[ -n "${S_PW[$i]}" && "${3:-}" != "then" && $CHK_RC -ne 2 ]]; then
    if pass_when "${S_PW[$i]}" "$flat"; then CHK_RC=0; elif [[ $CHK_RC -eq 0 ]]; then CHK_RC=1; fi
  fi
  CHK_VIOL="$(format_violations "$flat")"
  if [[ $CHK_RC -ne 0 && -z "$CHK_VIOL" ]]; then
    CHK_VIOL="$tool exited $CHK_RC (output: $(rel "$out"))"
    if [[ "$tool" == "repo-bootstrap" && -n "$flat" ]]; then CHK_VIOL="RB-GATE (human): git $(flat_get "$flat" git), commits $(flat_get "$flat" commits), decision $(flat_get "$flat" decision)"; fi
  fi
  if [[ $CHK_RC -eq 0 && "${3:-}" != "then" && -n "${S_TT[$i]}" ]]; then run_check "$i" "$label" then; fi
  return 0
}

# ---- harness ------------------------------------------------------------------------------------------
LIMIT_RE='usage limit|rate limit|rate-limit|ratelimit|limit reached|quota exceeded|exceeded your (current )?quota|too many requests|resource_exhausted|limit exceeded'
limit_hit() { # $1 log, $2 rc
  local t; t="$(tail -n 60 "$1" 2>/dev/null | tr 'A-Z' 'a-z' || true)"
  if printf '%s' "$t" | grep -Eq "$LIMIT_RE"; then return 0; fi
  if [[ "$2" != "0" ]] && printf '%s' "$t" | grep -Eq '(^|[^0-9])429([^0-9]|$)'; then return 0; fi
  return 1
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
harness_cmd() {
  local tpl perm p
  tpl="$(setting "continuity.start.$HARNESS" "")"
  if [[ -z "$tpl" ]]; then return 0; fi
  perm="$(setting continuity.permission_mode acceptEdits | sed 's/[^A-Za-z]//g')"; [[ -n "$perm" ]] || perm=acceptEdits
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
  if [[ "$JSON" -eq 1 || "${KCC_RUN_NO_PROMPT:-}" == "1" ]]; then return 0; fi
  if [[ ! -t 0 || ! -t 1 ]]; then return 0; fi
  local a
  while true; do
    read -r -p "answer [$R_gate_answers]: " a || return 0
    case "/$R_gate_answers/" in *"/$a/"*) apply_answer "$a"; OUTCOME=answered; return 0 ;; esac
    say "  not an allowed answer: $a"
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
      loop) set_att "$key" 0; pa=rerun ;;
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
  armout="$( (cd "$ROOT" && bash "$TOOLS/kcc-limit-watch.sh" "${a[@]}") 2>/dev/null < /dev/null | tr '\n' ' ' || true)"
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
  if [[ "${S_NAME[$i]}" == "SPECS" || "${S_CMD[$i]}" == /spec-create* ]]; then load_specs; fi
  cp="${S_CK[$i]}"; if [[ -z "$cp" && "${S_NAME[$i]}" == "REVIEW" ]]; then cp=spec-reviewed; fi
  if [[ -n "$cp" ]]; then invoke_checkpoint "$cp" "kcc-run: $label completed; run kcc-run -Resume"; fi
  if [[ "$2" == "1" ]]; then say "kcc-run: done   $label (exit check already passes)"; else say "kcc-run: done   $label"; fi
}
process_unit() { # $1 idx -> OUTCOME next|retry|goto|paused|answered
  local i="$1" key label pa gname gkind has_check interactive force skip_dispatch pre_done=0 pre_rc=0 pre_viol=""
  key="$(unit_key "$i")"; label="$(unit_label "$i")"
  pa="$R_pending_action"; R_pending_action=""
  OUTCOME=next
  if [[ -n "${S_ONLY[$i]}" ]] && ! in_list "$R_scenario" "${S_ONLY[$i]}"; then return 0; fi
  if [[ "${S_SKIP[$i]}" == "parallel" && "$R_parallel" == "1" ]]; then say "kcc-run: skip   $label (--parallel pre-approves)"; return 0; fi
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
    cmdtext="$(render "${S_CMD[$i]}")"
    q="Scenario S1: state ${S_ID[$i]} ${S_NAME[$i]} is an interactive interrogation. Run it yourself in your harness: \`$cmdtext\`. When it has finished, answer \`done\` (the exit check then runs) or \`abort\`."
    say "kcc-run: interactive $label - run in your harness: $cmdtext"
    ex="Command: \`$cmdtext\`"
    if [[ -n "$R_last_violations" ]]; then ex="$ex"$'\n\n'"Last exit-check violations: $R_last_violations"; fi
    open_gate interactive interactive "$q" "$i" "$ex"
    return 0
  fi
  if [[ $interactive -eq 1 && "$pa" == "recheck" && "${S_CT[$i]}" == "internal:agent-report" ]]; then complete_unit "$i" 0; return 0; fi

  if [[ $skip_dispatch -eq 0 && $has_check -eq 1 && $force -eq 0 && "$(get_att "$key")" == "0" && "${S_SCOPE[$i]}" != "wave" && "${S_CT[$i]}" != "internal:agent-report" ]] \
     && [[ -n "$R_idea" || "${S_ID[$i]}" == "0" ]] && ! [[ "$gkind" == "approval" && -n "$gname" ]]; then
    run_check "$i" "$key"
    if [[ $CHK_RC -eq 0 ]]; then complete_unit "$i" 1; return 0; fi
    pre_done=1; pre_rc=$CHK_RC; pre_viol="$CHK_VIOL"
  fi

  # ---- dispatch ----
  local has_cmd=0 att need_fix=0
  if [[ -n "${S_CMD[$i]}" ]]; then has_cmd=1; fi
  att="$(get_att "$key")"
  if [[ $has_cmd -eq 0 && $att -gt 0 && $has_check -eq 1 && -z "$gname" ]]; then need_fix=1; fi
  if [[ $skip_dispatch -eq 0 && ( $has_cmd -eq 1 || $need_fix -eq 1 ) ]]; then
    local body prompt log where
    if [[ $has_cmd -eq 1 ]]; then body="$(render "${S_CMD[$i]}")"; else body="The exit check \`$(check_desc "$i")\` failed. Route each violation to its fix_owner and fix it."; fi
    where=""; if [[ -n "$C_SPEC" ]]; then where=" for $C_SPEC"; fi; if [[ -n "$C_WAVE" ]]; then where="$where wave $C_WAVE"; fi
    prompt="KCC run state ${S_ID[$i]} ${S_NAME[$i]}$where. Follow coordination/orchestrator.md Spawn protocol and the state's contract. Do only this state, then stop. $body"
    if [[ $att -gt 0 && -n "$R_last_violations" ]]; then prompt="$prompt RETRY $((att + 1))/$CFG_MAX - fix these exit-check violations: $R_last_violations"; fi
    if [[ -n "$R_note" ]]; then prompt="$prompt Human note: $R_note"; R_note=""; fi
    if [[ "${S_SCOPE[$i]}" == "wave" && $att -eq 0 ]]; then invoke_checkpoint manual "kcc-run: baseline before $label"; fi
    local tag="run"; if [[ -n "$C_SPEC" ]]; then tag="$C_SPEC"; if [[ -n "$C_WAVE" ]]; then tag="$tag-w$C_WAVE"; fi; fi
    log="$LOG_DIR/state-${S_ID[$i]}-$(safe_name "$tag")-$((att + 1)).log"
    say "kcc-run: run    $label (attempt $((att + 1))/$CFG_MAX) -> $(rel "$log")"
    save_run
    invoke_harness "$prompt" "$log"
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
  if [[ $pre_done -eq 1 ]]; then CHK_RC=$pre_rc; CHK_VIOL="$pre_viol"; else run_check "$i" "$key-$(( $(get_att "$key") + 1 ))"; fi
  if [[ $CHK_RC -eq 0 ]]; then complete_unit "$i" 0; return 0; fi
  R_last_violations="$(sanitize_prompt "$CHK_VIOL")"
  if [[ ${#R_last_violations} -gt 1500 ]]; then R_last_violations="${R_last_violations:0:1500} ..."; fi
  if [[ $CHK_RC -eq 2 ]]; then stop_run stopped "exit check for $label returned a usage/environment error: $R_last_violations" 6; fi
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
  if [[ -n "${S_SKIP[$i]}" && "$R_parallel" == "1" ]]; then echo "[skip] $lbl (--parallel)"; return 0; fi
  echo "[${S_ID[$i]}] $lbl"
  if [[ -n "${S_CMD[$i]}" ]]; then
    c="$(render "${S_CMD[$i]}")"
    if [[ -n "${S_INT[$i]}" ]] && in_list "$R_scenario" "${S_INT[$i]}"; then echo "  interactive (human runs): $c"
    else echo "  harness: $(harness_cmd "KCC run state ${S_ID[$i]} ${S_NAME[$i]}. ... $c")"; fi
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
if [[ -n "$ONLY" ]]; then
  if [[ "$(get_idx "$ONLY")" -lt 0 ]]; then fail_usage "unknown state $ONLY"; fi
  if [[ -n "$R_gate_id" && -z "$ANSWER" ]]; then fail_usage "gate $R_gate_id is pending; answer it first"; fi
fi

if [[ $DRY -eq 1 ]]; then show_plan; fi

mkdir -p "$LOG_DIR"
if [[ $START_NEW -eq 1 ]]; then
  save_run
  bj="null"; if [[ -n "$R_budget" ]]; then bj="$R_budget"; fi
  emit auto-policy-parsed "" "{\"scenario\":\"$R_scenario\",\"silent\":$([[ $R_silent == 1 ]] && echo true || echo false),\"assume\":$([[ $R_assume == 1 ]] && echo true || echo false),\"accuracy_threshold_pct\":$R_accuracy,\"budget_cap_amount\":$bj,\"budget_cap_currency\":\"$R_currency\",\"parallel\":$([[ $R_parallel == 1 ]] && echo true || echo false),\"input_class\":\"$R_input_class\",\"harness\":\"$HARNESS\",\"source\":\"kcc-run\"}"
  say "kcc-run: new run - scenario $R_scenario, input class $R_input_class, starting at state $R_state"
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
      else advance; fi
      save_run; continue ;;
    *) stop_run stopped "unexpected unit outcome $OUTCOME" 6 ;;
  esac
done
