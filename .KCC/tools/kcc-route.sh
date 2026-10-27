#!/usr/bin/env bash
# KCC framework (c) 2026 Tarek Fawaz, https://tikasway.dev/kcc. Licensed under the terms in LICENSE.
#
# The model router: which model tier and reasoning effort an agent run gets, from what the plan and the idea say.
# Mirror of kcc-route.ps1 (same rules, same output). The reference implementation is cli/src/run/router.ts; a parity test runs
# the same cases through all three. Rules: kernel/protocols/model-routing.md. Every flow asks this before it spawns an agent:
# kcc-run for each dispatch, the orchestrator and the skills a developer runs by hand before each spawn.
#
# Usage: bash .KCC/tools/kcc-route.sh --agent NAME [--task T] [--spec SPEC-ID [--wave N | --item KEY]] [--attempt N]
#        [--harness H] [--default-tier T --default-effort E --domain D --risk --complexity C --items N --files N
#        --budget-left PCT --max-tier T --max-effort E] [--scan-text TEXT] [--batch] [--json] [--repo-root PATH]
# Output: tier<TAB>model<TAB>effort<TAB>reasons<TAB>items (or --json). The reasons start with the agent default and name each move.
# --batch prints "tier effort reasons" per row and reads signal rows from stdin (parity tests):
#   defaultTier defaultEffort task domain risk complexity items files attempt budget maxTier maxEffort   ('-' = none)

set -euo pipefail

REPO_ROOT=""; AGENT=""; TASK=""; SPEC=""; WAVE=""; ITEM=""; ATTEMPT=1; HARNESS=""
DEFAULT_TIER=""; DEFAULT_EFFORT=""; DOMAIN=""; RISK=0; COMPLEXITY=""; ITEMS=0; FILES=0; BUDGET=-1; MAXTIER=""; MAXEFFORT=""
SCAN_TEXT=""; BATCH=0; JSON=0
while [ $# -gt 0 ]; do
  case "$1" in
    --repo-root) REPO_ROOT="${2:-}"; shift 2 ;;
    --agent) AGENT="${2:-}"; shift 2 ;;
    --task) TASK="${2:-}"; shift 2 ;;
    --spec) SPEC="${2:-}"; shift 2 ;;
    --wave) WAVE="${2:-}"; shift 2 ;;
    --item) ITEM="${2:-}"; shift 2 ;;
    --attempt) ATTEMPT="${2:-1}"; shift 2 ;;
    --harness) HARNESS="${2:-}"; shift 2 ;;
    --default-tier) DEFAULT_TIER="${2:-}"; shift 2 ;;
    --default-effort) DEFAULT_EFFORT="${2:-}"; shift 2 ;;
    --domain) DOMAIN="${2:-}"; shift 2 ;;
    --risk) RISK=1; shift ;;
    --complexity) COMPLEXITY="${2:-}"; shift 2 ;;
    --items) ITEMS="${2:-0}"; shift 2 ;;
    --files) FILES="${2:-0}"; shift 2 ;;
    --budget-left) BUDGET="${2:--1}"; shift 2 ;;
    --max-tier) MAXTIER="${2:-}"; shift 2 ;;
    --max-effort) MAXEFFORT="${2:-}"; shift 2 ;;
    --scan-text) SCAN_TEXT="${2:-}"; shift 2 ;;
    --batch) BATCH=1; shift ;;
    --json) JSON=1; shift ;;
    -h|--help) sed -n '2,14p' "$0"; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

if [ -z "$REPO_ROOT" ]; then
  TOOL_DIR="$(cd "$(dirname "$0")" && pwd)"
  PARENT="$(dirname "$TOOL_DIR")"
  if [ "$(basename "$PARENT")" = ".KCC" ]; then REPO_ROOT="$(dirname "$PARENT")"; else REPO_ROOT="$PARENT"; fi
fi
KCC_DIR="$REPO_ROOT/.KCC"

# Spawn budget (Git Bash on Windows pays ~0.3-0.4 s per fork or exec): everything below is bash builtins, and the three JSON files are
# read by one awk. The text helpers need bash 3.2 (macOS), so lower-casing uses ${x,,} only where bash has it and tr elsewhere.
if [ "${BASH_VERSINFO[0]}" -ge 4 ]; then
  eval 'lc() { LC="${1,,}"; }'
else
  lc() { LC="$(printf '%s' "$1" | tr 'A-Z' 'a-z')"; }
fi
# nl_trim VAR: strips trailing newlines, the way $(...) does
nl_trim() { local _v="${!1}"; while [[ "$_v" == *$'\n' ]]; do _v="${_v%$'\n'}"; done; printf -v "$1" '%s' "$_v"; }

TIERN=(fast balanced strong); EFFN=(low medium high xhigh max)
# index helpers set a global instead of printing, so the router forks nothing (a fork per step made 400 rows take minutes on Windows)
tier_to_i() { case "$1" in fast) TI=0 ;; balanced) TI=1 ;; strong) TI=2 ;; *) TI=1 ;; esac; }
eff_to_i() { case "$1" in low) EI=0 ;; medium) EI=1 ;; high) EI=2 ;; xhigh) EI=3 ;; max) EI=4 ;; *) EI=1 ;; esac; }

# Security words that make an item security-sensitive (CR-7). Tokens are lower-cased; a plural s is ignored.
sec_word() { case "$1" in auth|authentication|authorization|authn|authz|password|credential|crypto|secret|token|csrf|jwt|oauth|session|pii|payment) return 0 ;; esac; return 1; }
# sets SH to the first security word of the text (or nothing); same scan as the awk it replaces (tokens in order: the word, its plural, encrypt*)
security_hit() {
  local all t w
  SH=""
  lc "$1"; all="${LC//$'\n'/ }"
  case "$all" in *"personal data"*) SH="personal data"; return 0 ;; esac
  all="${all//[^abcdefghijklmnopqrstuvwxyz0123456789]/ }"
  set -f
  for t in $all; do
    if sec_word "$t"; then SH="$t"; break; fi
    if [ "${#t}" -gt 3 ] && [ "${t%s}" != "$t" ]; then w="${t%s}"; if sec_word "$w"; then SH="$w"; break; fi; fi
    case "$t" in encrypt*) SH="$t"; break ;; esac
  done
  set +f
  return 0
}

# The router: default tier and effort moved by the signals, never more than one tier from the default.
# route defTier defEffort task domain risk complexity items files attempt budget capTier -> sets R_TIER R_EFFORT R_REASONS
route() {
  local deft="$1" defe="$2" task="$3" domain="$4" risk="$5" cx="$6" items="$7" files="$8" attempt="$9" budget="${10}" cap="${11}" capeff="${12:-}" cause="${13:-}"
  local dt t mint maxt e capi is_risk=0 reasons="" t0 e0 tw ew
  tier_to_i "$deft"; dt=$TI; t=$dt
  mint=$((dt - 1)); if [ "$mint" -lt 0 ]; then mint=0; fi
  maxt=$((dt + 1)); if [ "$maxt" -gt 2 ]; then maxt=2; fi
  eff_to_i "$defe"; e=$EI; if [ "$e" -eq 4 ]; then e=3; fi
  # every pick states its starting point first (mirror of router.ts)
  reasons="agent default: ${TIERN[$t]} / ${EFFN[$e]}"
  if [ "$risk" = "1" ] || [ "$cx" = "high" ] || [ "$cx" = "extra-high" ]; then is_risk=1; fi
  # BALANCED_FLOOR_TASKS: research architecture security spec plan never run below balanced
  case "$task" in research|architecture|security|spec|plan) if [ "$t" -lt 1 ]; then t=1; reasons="$reasons; $task never runs below balanced: tier raised"; fi ;; esac
  if [ "$domain" = "novel" ]; then
    t=$((t + 1)); if [ "$t" -gt "$maxt" ]; then t=$maxt; fi
    if [ "$e" -lt 2 ]; then e=2; fi
    reasons="$reasons; novel domain: tier up, effort high"
  elif [ "$domain" = "common" ]; then
    # COMMON_DOMAIN_STEP_DOWN_TASKS: docs scaffold (spec and plan are not here on purpose)
    case "$task" in docs|scaffold) t=$((t - 1)); if [ "$t" -lt "$mint" ]; then t=$mint; fi; reasons="$reasons; common domain, $task: tier down" ;; esac
  fi
  if [ "$is_risk" = "1" ]; then
    tw=""; if [ "$t" -lt 1 ]; then t=1; tw=", tier raised to balanced"; fi
    if [ "$e" -lt 2 ]; then e=2; fi
    if [ "$risk" = "1" ]; then reasons="$reasons; ${cause:-CR-7 risk}: effort ${EFFN[$e]}$tw"; else reasons="$reasons; complexity $cx: effort ${EFFN[$e]}$tw"; fi
  fi
  if [ "$cx" = "extra-high" ]; then if [ "$e" -lt 3 ]; then e=3; fi; reasons="$reasons; extra-high complexity: effort xhigh"; fi
  if [ "$items" -gt 3 ] || [ "$files" -gt 5 ]; then e=$((e + 1)); if [ "$e" -gt 3 ]; then e=3; fi; reasons="$reasons; large unit: effort up"; fi
  # review (a verifier or critic) stays at high unless the item is extra-high (router.ts)
  if [ "$task" = "review" ] && [ "$cx" != "extra-high" ] && [ "$e" -gt 2 ]; then e=2; reasons="$reasons; review: effort capped at high (xhigh only for extra-high complexity)"; fi
  # RETRY_RULES (router.ts): a retry escalates the agent that fixes something (tier and effort up one step); a planning retry
  # (spec, plan) keeps the tier and raises the effort to at most high; a verifier or critic (task review) is never escalated.
  if [ "$attempt" -ge 2 ]; then
    case "$task" in
      review) ;;
      spec|plan)
        e0=$e; if [ "$e" -lt 2 ]; then e=$((e + 1)); fi
        if [ "$e" -ne "$e0" ]; then reasons="$reasons; attempt $attempt: effort raised to ${EFFN[$e]}, tier unchanged for planning"; else reasons="$reasons; attempt $attempt: effort stays ${EFFN[$e]}, tier unchanged for planning"; fi ;;
      *)
        t0=$t; e0=$e
        t=$((t + 1)); if [ "$t" -gt "$maxt" ]; then t=$maxt; fi
        e=$((e + 1)); if [ "$e" -gt 3 ]; then e=3; fi
        tw=unchanged; ew=unchanged; if [ "$t" -ne "$t0" ]; then tw=up; fi; if [ "$e" -ne "$e0" ]; then ew=up; fi
        reasons="$reasons; attempt $attempt: tier $tw, effort $ew" ;;
    esac
  fi
  if [ "$budget" -ge 0 ] && [ "$budget" -lt 20 ] && [ "$is_risk" = "0" ]; then if [ "$t" -gt 1 ]; then t=1; fi; reasons="$reasons; budget under 20%: tier capped at balanced"; fi
  if [ "$t" -lt "$mint" ]; then t=$mint; fi
  if [ "$t" -gt "$maxt" ]; then t=$maxt; fi
  if [ -n "$cap" ]; then tier_to_i "$cap"; capi=$TI; if [ "$t" -gt "$capi" ]; then t=$capi; reasons="${reasons:+$reasons; }capped at $cap for $task"; fi; fi
  if [ -n "$capeff" ]; then eff_to_i "$capeff"; if [ "$e" -gt "$EI" ]; then e=$EI; reasons="${reasons:+$reasons; }effort capped at $capeff for $task"; fi; fi
  R_TIER="${TIERN[$t]}"; R_EFFORT="${EFFN[$e]}"; R_REASONS="$reasons"
}

if [ -n "$SCAN_TEXT" ]; then security_hit "$SCAN_TEXT"; if [ -n "$SH" ]; then printf '%s\n' "$SH"; fi; echo; exit 0; fi

if [ "$BATCH" -eq 1 ]; then
  while read -r a b c d e f g h i j k l; do
    [ -n "${a:-}" ] || continue
    for v in a b c d e f g h i j k l; do [ "${!v:-}" = "-" ] && printf -v "$v" '%s' ""; done
    route "$a" "$b" "$c" "$d" "${e:-0}" "$f" "${g:-0}" "${h:-0}" "${i:-1}" "${j:--1}" "$k" "${l:-}" ""
    echo "$R_TIER $R_EFFORT $R_REASONS"
  done
  exit 0
fi

[ -n "$AGENT" ] || { echo "usage: kcc-route --agent NAME [--task T] [--spec SPEC-ID [--wave N | --item KEY]] [--attempt N] [--harness H] [--json]" >&2; exit 2; }

SETTINGS_JSON="$KCC_DIR/settings.json"; REGISTRY_JSON="$KCC_DIR/kernel/models.json"; PROFILES_JSON="$KCC_DIR/kernel/harnesses.json"
# flat path<TAB>value of a json file: the same awk the drivers use
JSON_FLAT_AWK='
function hexv(h,  v,q){ h=tolower(h); v=0; for(q=1;q<=length(h);q++){ v=v*16+index("0123456789abcdef",substr(h,q,1))-1 }; return v }
function path(  p,x){ p=""; for(x=1;x<=d;x++){ p=p (x>1?".":"") k[x] }; return p }
function emit(v){ print tg ":" path() "\t" v }
function adv(){ if(d>0 && t[d]=="a"){ k[d]=cnt[d]; cnt[d]++ } }
FNR==1 { nf++; fn[nf]=FILENAME }
{ buf[nf] = buf[nf] $0 "\n" }
END{
 for(ff=1; ff<=nf; ff++){
  s=buf[ff]; tg=substr(tags, ff, 1); split("",k); split("",t); split("",ek); split("",cnt)
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
 }
}'

# One awk reads the three files (keys come out as S:path, R:path, P:path for settings, registry, profiles); lookups are bash pattern
# matches on the output, first occurrence wins (what `awk '$1==k{print $2; exit}'` did, without a process per lookup).
FLAT_FILES=(); FLAT_TAGS=""
for _p in "S:$SETTINGS_JSON" "R:$REGISTRY_JSON" "P:$PROFILES_JSON"; do _f="${_p#?:}"; if [ -f "$_f" ]; then FLAT_FILES+=("$_f"); FLAT_TAGS="$FLAT_TAGS${_p%%:*}"; fi; done
FLAT=""
if [ "${#FLAT_FILES[@]}" -gt 0 ]; then FLAT="$(awk -v tags="$FLAT_TAGS" "$JSON_FLAT_AWK" "${FLAT_FILES[@]}" 2>/dev/null || true)"; fi
FLAT=$'\n'"$FLAT"$'\n'
fget() { # tag (S|R|P) key -> FV
  local k=$'\n'"$1:$2"$'\t' r
  case "$FLAT" in *"$k"*) r="${FLAT#*"$k"}"; r="${r%%$'\n'*}"; FV="${r%%$'\t'*}" ;; *) FV="" ;; esac
}

if [ -z "$HARNESS" ]; then fget S run.harness; HARNESS="$FV"; fi; [ -n "$HARNESS" ] || HARNESS="claude"

# --- the agent's default class and effort (frontmatter, then the user's .KCC/model-overrides) ---
CLASS=""; DEFEFF=""
AF="$KCC_DIR/capabilities/agents/$AGENT.md"
if [ -f "$AF" ]; then
  # the first 25 lines, the first line that carries each key (read loop: no head/tr/sed process)
  _n=0
  while [ "$_n" -lt 25 ] && { IFS= read -r l || [ -n "$l" ]; }; do
    _n=$((_n + 1)); l="${l//$'\r'/}"
    if [ -z "$CLASS" ] && [[ "$l" =~ ^model-class:[[:space:]]*([^[:space:]]+) ]]; then CLASS="${BASH_REMATCH[1]}"; fi
    if [ -z "$DEFEFF" ] && [[ "$l" =~ ^effort:[[:space:]]*([^[:space:]]+) ]]; then DEFEFF="${BASH_REMATCH[1]}"; fi
  done < "$AF"
fi
OVF="$KCC_DIR/model-overrides"
if [ -f "$OVF" ]; then
  while IFS= read -r l; do
    l="${l%%#*}"; l="${l//$'\r'/}"
    case "$l" in *"="*) ;; *) continue ;; esac
    name="${l%%=*}"; name="${name//[[:space:]]/}"; [ "$name" = "$AGENT" ] || continue
    set -- ${l#*=}
    if [ -n "${1:-}" ]; then CLASS="$1"; fi
    if [ -n "${2:-}" ]; then DEFEFF="$2"; fi
  done < "$OVF"
fi
if [ -z "$DEFAULT_TIER" ]; then fget R "class_to_tier.$CLASS"; DEFAULT_TIER="$FV"; [ -n "$DEFAULT_TIER" ] || DEFAULT_TIER="balanced"; fi
if [ -z "$DEFAULT_EFFORT" ]; then DEFAULT_EFFORT="${DEFEFF:-medium}"; fi
case "$DEFAULT_TIER" in fast|balanced|strong) ;; *) echo "unknown tier: $DEFAULT_TIER" >&2; exit 2 ;; esac
case "$DEFAULT_EFFORT" in low|medium|high|xhigh|max) ;; *) echo "unknown effort: $DEFAULT_EFFORT" >&2; exit 2 ;; esac

if [ -z "$TASK" ]; then
  case "$AGENT" in
    idea-interrogator|technical-interrogator|ux-ui-designer) TASK=research ;;
    infrastructure-planner|architect) TASK=architecture ;;
    security-analyst) TASK=security ;;
    spec-writer) TASK=spec ;;
    planner) TASK=plan ;;
    implementer|infrastructure-implementer) TASK=implement ;;
    verifier|architecture-critic) TASK=review ;;
    butler|token-guard) TASK=close ;;
    repo-steward) TASK=docs ;;
    *) TASK=other ;;
  esac
fi

# --- signals from the idea and the plan ---
SPEC_DIR=""; IDEA_FOLDER=""
if [ -n "$SPEC" ] && [ -d "$REPO_ROOT/specs" ]; then
  for g in "$REPO_ROOT"/specs/*/; do
    [ -d "$g" ] || continue
    for d in "${g%/}"/*/; do
      [ -d "$d" ] || continue
      n="${d%/}"; n="${n##*/}"
      case "$n" in "$SPEC"|"$SPEC"-*) SPEC_DIR="${d%/}"; IDEA_FOLDER="${g%/}"; IDEA_FOLDER="${IDEA_FOLDER##*/}"; IDEA_FOLDER="${IDEA_FOLDER%-Specs}" ;; esac
    done
  done
fi
if [ -z "$DOMAIN" ] && [ -n "$IDEA_FOLDER" ] && [ -f "$REPO_ROOT/ideation/$IDEA_FOLDER/Research.md" ]; then
  # the idea's '## Domain' (case-insensitive, as the awk it replaces ran under gawk's IGNORECASE): the word on the heading line after a colon, else the
  # first line below it that names one. A read loop and regex matches: no tr/awk/sed/head processes.
  _re_dom_a='^##[[:space:]]+Domain'; _re_dom_b=':[[:space:]]*`?(common|specialised|specialized|novel)'; _re_dom_c='(common|specialised|specialized|novel)'
  _want=0; _dom=""
  shopt -s nocasematch
  while IFS= read -r l || [ -n "$l" ]; do
    l="${l//$'\r'/}"
    if [[ "$l" =~ $_re_dom_a ]]; then
      if [[ "$l" =~ $_re_dom_b ]]; then _dom="${BASH_REMATCH[1]}"; break; fi
      _want=1; continue
    fi
    if [ "$_want" -eq 1 ] && [[ "$l" =~ $_re_dom_c ]]; then _dom="${BASH_REMATCH[1]}"; break; fi
  done < "$REPO_ROOT/ideation/$IDEA_FOLDER/Research.md"
  shopt -u nocasematch
  lc "$_dom"; DOMAIN="${LC//specialized/specialised}"
fi

ITEM_KEYS=""; REASON_EXTRA=""
if [ -n "$SPEC_DIR" ] && [ -f "$SPEC_DIR/plan.md" ]; then
  ROWS="$(awk -F'|' -v wave="$WAVE" -v item="$ITEM" '
    function trim(s) { gsub(/^[[:space:]]+|[[:space:]]+$/, "", s); return s }
    { gsub(/\r/, "") }
    /^[[:space:]]*\|/ {
      if (!hdr) { for (i = 1; i <= NF; i++) { c = tolower(trim($i)); if (c == "item") ci = i; else if (c == "wave") cw = i; else if (c == "complexity") cc = i; else if (c == "notes") cn = i } if (ci && cw && cc) hdr = 1; else { ci = cw = cc = cn = 0 } next }
      if ($0 ~ /^[[:space:]]*\|[[:space:]:|-]+\|?[[:space:]]*$/) next
      k = trim($ci); w = trim($cw)
      if (item != "") { if (k != item) next } else if (wave != "" && w != wave) next
      printf "%s\t%s\t%s\n", k, tolower(trim($cc)), (cn ? trim($cn) : "")
      next }
    { if (hdr) exit }' "$SPEC_DIR/plan.md")"
  # Per item: complexity rank, the backlog file (first 40 lines for the security scan, bullets under '## Impacted Files'): builtins only.
  _re_imp='^##[[:space:]]+Impacted Files'; _re_h2='^##[[:space:]]'; _re_bul='^[[:space:]]*[-*][[:space:]]+`'
  cx_rank() { case "$1" in low) RK=1 ;; medium) RK=2 ;; high) RK=3 ;; *) RK=4 ;; esac; }
  read_backlog() { # file -> BL_TEXT (first 40 lines, CR removed, trailing newlines removed), BL_N (bullets under '## Impacted Files')
    local line c=0 inimp=0 fin=0 out=""
    BL_N=0
    while IFS= read -r line || [ -n "$line" ]; do
      line="${line//$'\r'/}"
      if [ "$c" -lt 40 ]; then out+="$line"$'\n'; c=$((c + 1)); fi
      if [ "$fin" -eq 0 ]; then
        if [[ "$line" =~ $_re_imp ]]; then inimp=1
        elif [ "$inimp" -eq 1 ]; then
          if [[ "$line" =~ $_re_h2 ]]; then fin=1
          elif [[ "$line" =~ $_re_bul ]]; then BL_N=$((BL_N + 1)); fi
        fi
      fi
      if [ "$c" -ge 40 ] && [ "$fin" -eq 1 ]; then break; fi
    done < "$1"
    nl_trim out; BL_TEXT="$out"
  }
  BEST_C=""; BEST_FILES=0; HIT=""; COUNT=0
  while IFS=$'\t' read -r key cx notes; do
    [ -n "$key" ] || continue
    COUNT=$((COUNT + 1)); ITEM_KEYS="${ITEM_KEYS:+$ITEM_KEYS, }$key"
    case "$cx" in low|medium|high|extra-high)
      if [ -z "$BEST_C" ]; then BEST_C="$cx"; else cx_rank "$cx"; _r1=$RK; cx_rank "$BEST_C"; if [ "$_r1" -gt "$RK" ]; then BEST_C="$cx"; fi; fi ;;
    esac
    text="$notes"; nfiles=0
    bf=""
    if [ -d "$SPEC_DIR/Backlog" ]; then
      lc "$key"; lk="$LC"
      for f in "$SPEC_DIR"/Backlog/*.md; do
        [ -f "$f" ] || continue
        lc "${f##*/}"; b="$LC"
        case "$b" in "$lk"-*|"$lk.md") bf="$f"; break ;; esac
      done
    fi
    if [ -n "$bf" ]; then
      read_backlog "$bf"
      text="$text
$BL_TEXT"
      nfiles="$BL_N"
    fi
    if [ "$nfiles" -gt "$BEST_FILES" ]; then BEST_FILES="$nfiles"; fi
    if [ -z "$HIT" ]; then security_hit "$text"; HIT="$SH"; fi
  done <<EOF
$ROWS
EOF
  if [ -z "$COMPLEXITY" ] && [ -n "$BEST_C" ]; then COMPLEXITY="$BEST_C"; fi
  if [ "$FILES" -eq 0 ]; then FILES="$BEST_FILES"; fi
  if [ "$ITEMS" -eq 0 ] && [ -z "$ITEM" ]; then ITEMS="$COUNT"; fi
  if [ "$RISK" -eq 0 ] && [ -n "$HIT" ]; then RISK=1; REASON_EXTRA="security-sensitive ($HIT)"; fi
fi

CAP="$MAXTIER"
if [ -z "$CAP" ] && [ "$TASK" = "implement" ]; then fget S routing.implement_max_tier; CAP="$FV"; [ -n "$CAP" ] || CAP="balanced"; fi
route "$DEFAULT_TIER" "$DEFAULT_EFFORT" "$TASK" "$DOMAIN" "$RISK" "$COMPLEXITY" "$ITEMS" "$FILES" "$ATTEMPT" "$BUDGET" "$CAP" "$MAXEFFORT" "$REASON_EXTRA"
WHY="$R_REASONS"; [ -n "$WHY" ] || WHY="default"

# --- resolve to this harness ---
fget S run.registry; REG_COL="$FV"; [ -n "$REG_COL" ] || REG_COL="$HARNESS"
fget R "harnesses.$REG_COL.$R_TIER.id"; MODEL="$FV"
if [ -n "$MODEL" ]; then fget R "harnesses.$REG_COL._prefix"; MODEL="$FV$MODEL"; fi
EFF="$R_EFFORT"; fget P "harnesses.$HARNESS.effort_map.$EFF"; MAPPED="$FV"; if [ -n "$MAPPED" ]; then EFF="$MAPPED"; fi

if [ "$JSON" -eq 1 ]; then
  esc() { local s="$1" bs='\'; s="${s//"$bs"/"$bs$bs"}"; ESC="${s//\"/"$bs\""}"; }
  esc "$AGENT"; E_AGENT="$ESC"; esc "$MODEL"; E_MODEL="$ESC"; esc "$WHY"; E_WHY="$ESC"; esc "$ITEM_KEYS"; E_ITEMS="$ESC"
  printf '{"agent":"%s","task":"%s","harness":"%s","tier":"%s","model":"%s","effort":"%s","neutral_effort":"%s","reasons":"%s","items":"%s"}\n' "$E_AGENT" "$TASK" "$HARNESS" "$R_TIER" "$E_MODEL" "$EFF" "$R_EFFORT" "$E_WHY" "$E_ITEMS"
else
  printf '%s\t%s\t%s\t%s\t%s\n' "$R_TIER" "$MODEL" "$EFF" "$WHY" "$ITEM_KEYS"
fi
