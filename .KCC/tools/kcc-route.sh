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
# Output: tier<TAB>model<TAB>effort<TAB>reasons<TAB>items (or --json). --batch reads signal rows from stdin (parity tests):
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

TOOL_DIR="$(cd "$(dirname "$0")" && pwd)"
if [ -z "$REPO_ROOT" ]; then
  PARENT="$(dirname "$TOOL_DIR")"
  if [ "$(basename "$PARENT")" = ".KCC" ]; then REPO_ROOT="$(dirname "$PARENT")"; else REPO_ROOT="$PARENT"; fi
fi
KCC_DIR="$REPO_ROOT/.KCC"

TIERN=(fast balanced strong); EFFN=(low medium high xhigh max)
# index helpers set a global instead of printing, so the router forks nothing (a fork per step made 400 rows take minutes on Windows)
tier_to_i() { case "$1" in fast) TI=0 ;; balanced) TI=1 ;; strong) TI=2 ;; *) TI=1 ;; esac; }
eff_to_i() { case "$1" in low) EI=0 ;; medium) EI=1 ;; high) EI=2 ;; xhigh) EI=3 ;; max) EI=4 ;; *) EI=1 ;; esac; }

# Security words that make an item security-sensitive (CR-7). Tokens are lower-cased; a plural s is ignored.
security_hit() {
  printf '%s' "$1" | tr 'A-Z' 'a-z' | awk '
    BEGIN { n = split("auth authentication authorization authn authz password credential crypto secret token csrf jwt oauth session pii payment", a, " "); for (i = 1; i <= n; i++) set[a[i]] = 1 }
    { all = all " " $0 }
    END {
      if (index(all, "personal data") > 0) { print "personal data"; exit }
      m = split(all, w, /[^a-z0-9]+/)
      for (i = 1; i <= m; i++) {
        t = w[i]; if (t == "") continue
        if (t in set) { print t; exit }
        if (length(t) > 3 && substr(t, length(t)) == "s" && (substr(t, 1, length(t) - 1) in set)) { print substr(t, 1, length(t) - 1); exit }
        if (substr(t, 1, 7) == "encrypt") { print t; exit }
      }
    }'
}

# The router: default tier and effort moved by the signals, never more than one tier from the default.
# route defTier defEffort task domain risk complexity items files attempt budget capTier -> sets R_TIER R_EFFORT R_REASONS
route() {
  local deft="$1" defe="$2" task="$3" domain="$4" risk="$5" cx="$6" items="$7" files="$8" attempt="$9" budget="${10}" cap="${11}" capeff="${12:-}"
  local dt t mint maxt e capi is_risk=0 reasons=""
  tier_to_i "$deft"; dt=$TI; t=$dt
  mint=$((dt - 1)); if [ "$mint" -lt 0 ]; then mint=0; fi
  maxt=$((dt + 1)); if [ "$maxt" -gt 2 ]; then maxt=2; fi
  eff_to_i "$defe"; e=$EI; if [ "$e" -eq 4 ]; then e=3; fi
  if [ "$risk" = "1" ] || [ "$cx" = "high" ] || [ "$cx" = "extra-high" ]; then is_risk=1; fi
  case "$task" in research|architecture|security) if [ "$t" -lt 1 ]; then t=1; reasons="${reasons:+$reasons; }$task never runs below balanced"; fi ;; esac
  if [ "$domain" = "novel" ]; then
    t=$((t + 1)); if [ "$t" -gt "$maxt" ]; then t=$maxt; fi
    if [ "$e" -lt 2 ]; then e=2; fi
    reasons="${reasons:+$reasons; }novel domain"
  elif [ "$domain" = "common" ]; then
    case "$task" in spec|plan|docs|scaffold) t=$((t - 1)); if [ "$t" -lt "$mint" ]; then t=$mint; fi; reasons="${reasons:+$reasons; }common domain, $task" ;; esac
  fi
  if [ "$is_risk" = "1" ]; then
    if [ "$t" -lt 1 ]; then t=1; fi
    if [ "$e" -lt 2 ]; then e=2; fi
    if [ "$risk" = "1" ]; then reasons="${reasons:+$reasons; }CR-7 risk"; else reasons="${reasons:+$reasons; }complexity $cx"; fi
  fi
  if [ "$cx" = "extra-high" ]; then if [ "$e" -lt 3 ]; then e=3; fi; reasons="${reasons:+$reasons; }extra-high complexity: xhigh effort"; fi
  if [ "$items" -gt 3 ] || [ "$files" -gt 5 ]; then e=$((e + 1)); if [ "$e" -gt 3 ]; then e=3; fi; reasons="${reasons:+$reasons; }large unit"; fi
  # A retry escalates the agent that fixes something; a verifier or critic (task review) is never escalated for a retry.
  if [ "$attempt" -ge 2 ] && [ "$task" != "review" ]; then
    t=$((t + 1)); if [ "$t" -gt "$maxt" ]; then t=$maxt; fi
    e=$((e + 1)); if [ "$e" -gt 3 ]; then e=3; fi
    reasons="${reasons:+$reasons; }attempt $attempt"
  fi
  if [ "$budget" -ge 0 ] && [ "$budget" -lt 20 ] && [ "$is_risk" = "0" ]; then if [ "$t" -gt 1 ]; then t=1; fi; reasons="${reasons:+$reasons; }budget under 20%"; fi
  if [ "$t" -lt "$mint" ]; then t=$mint; fi
  if [ "$t" -gt "$maxt" ]; then t=$maxt; fi
  if [ -n "$cap" ]; then tier_to_i "$cap"; capi=$TI; if [ "$t" -gt "$capi" ]; then t=$capi; reasons="${reasons:+$reasons; }capped at $cap for $task"; fi; fi
  if [ -n "$capeff" ]; then eff_to_i "$capeff"; if [ "$e" -gt "$EI" ]; then e=$EI; reasons="${reasons:+$reasons; }effort capped at $capeff for $task"; fi; fi
  R_TIER="${TIERN[$t]}"; R_EFFORT="${EFFN[$e]}"; R_REASONS="$reasons"
}

if [ -n "$SCAN_TEXT" ]; then security_hit "$SCAN_TEXT"; echo; exit 0; fi

if [ "$BATCH" -eq 1 ]; then
  while read -r a b c d e f g h i j k l; do
    [ -n "${a:-}" ] || continue
    for v in a b c d e f g h i j k l; do [ "${!v:-}" = "-" ] && printf -v "$v" '%s' ""; done
    route "$a" "$b" "$c" "$d" "${e:-0}" "$f" "${g:-0}" "${h:-0}" "${i:-1}" "${j:--1}" "$k" "${l:-}"
    echo "$R_TIER $R_EFFORT"
  done
  exit 0
fi

[ -n "$AGENT" ] || { echo "usage: kcc-route --agent NAME [--task T] [--spec SPEC-ID [--wave N | --item KEY]] [--attempt N] [--harness H] [--json]" >&2; exit 2; }

SETTINGS_JSON="$KCC_DIR/settings.json"; REGISTRY_JSON="$KCC_DIR/kernel/models.json"; PROFILES_JSON="$KCC_DIR/kernel/harnesses.json"
# flat path<TAB>value of a json file: the same awk the drivers use
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

flat() { [ -f "$1" ] && awk "$JSON_FLAT_AWK" "$1" 2>/dev/null || true; }
SETTINGS_FLAT="$(flat "$SETTINGS_JSON")"; REGISTRY_FLAT="$(flat "$REGISTRY_JSON")"; PROFILES_FLAT="$(flat "$PROFILES_JSON")"
fget() { awk -F'\t' -v k="$2" '$1==k{print $2; exit}' <<< "$1"; }

[ -n "$HARNESS" ] || HARNESS="$(fget "$SETTINGS_FLAT" run.harness)"; [ -n "$HARNESS" ] || HARNESS="claude"

# --- the agent's default class and effort (frontmatter, then the user's .KCC/model-overrides) ---
CLASS=""; DEFEFF=""
AF="$KCC_DIR/capabilities/agents/$AGENT.md"
if [ -f "$AF" ]; then
  CLASS="$(head -n 25 "$AF" | tr -d '\r' | sed -nE 's/^model-class:[[:space:]]*([^[:space:]]+).*/\1/p' | head -n 1)"
  DEFEFF="$(head -n 25 "$AF" | tr -d '\r' | sed -nE 's/^effort:[[:space:]]*([^[:space:]]+).*/\1/p' | head -n 1)"
fi
OVF="$KCC_DIR/model-overrides"
if [ -f "$OVF" ]; then
  while IFS= read -r l; do
    l="${l%%#*}"; l="$(printf '%s' "$l" | tr -d '\r')"
    case "$l" in *"="*) ;; *) continue ;; esac
    name="$(printf '%s' "${l%%=*}" | tr -d '[:space:]')"; [ "$name" = "$AGENT" ] || continue
    set -- ${l#*=}
    if [ -n "${1:-}" ]; then CLASS="$1"; fi
    if [ -n "${2:-}" ]; then DEFEFF="$2"; fi
  done < "$OVF"
fi
if [ -z "$DEFAULT_TIER" ]; then DEFAULT_TIER="$(fget "$REGISTRY_FLAT" "class_to_tier.$CLASS")"; [ -n "$DEFAULT_TIER" ] || DEFAULT_TIER="balanced"; fi
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
      n="$(basename "$d")"
      case "$n" in "$SPEC"|"$SPEC"-*) SPEC_DIR="${d%/}"; IDEA_FOLDER="$(basename "${g%/}")"; IDEA_FOLDER="${IDEA_FOLDER%-Specs}" ;; esac
    done
  done
fi
if [ -z "$DOMAIN" ] && [ -n "$IDEA_FOLDER" ] && [ -f "$REPO_ROOT/ideation/$IDEA_FOLDER/Research.md" ]; then
  DOMAIN="$(tr -d '\r' < "$REPO_ROOT/ideation/$IDEA_FOLDER/Research.md" | awk 'BEGIN{IGNORECASE=1} /^##[[:space:]]+Domain/ { if (match($0, /:[[:space:]]*`?(common|specialised|specialized|novel)/)) { print tolower(substr($0, RSTART+1, RLENGTH-1)); exit } want = 1; next } want && /(common|specialised|specialized|novel)/ { if (match(tolower($0), /(common|specialised|specialized|novel)/)) { print substr(tolower($0), RSTART, RLENGTH); exit } }' | sed -E 's/^[: `]+//; s/specialized/specialised/' | head -n 1)"
fi

ITEM_KEYS=""; REASON_EXTRA=""
if [ -n "$SPEC_DIR" ] && [ -f "$SPEC_DIR/plan.md" ]; then
  ROWS="$(tr -d '\r' < "$SPEC_DIR/plan.md" | awk -F'|' -v wave="$WAVE" -v item="$ITEM" '
    function trim(s) { gsub(/^[[:space:]]+|[[:space:]]+$/, "", s); return s }
    /^[[:space:]]*\|/ {
      if (!hdr) { for (i = 1; i <= NF; i++) { c = tolower(trim($i)); if (c == "item") ci = i; else if (c == "wave") cw = i; else if (c == "complexity") cc = i; else if (c == "notes") cn = i } if (ci && cw && cc) hdr = 1; else { ci = cw = cc = cn = 0 } next }
      if ($0 ~ /^[[:space:]]*\|[[:space:]:|-]+\|?[[:space:]]*$/) next
      k = trim($ci); w = trim($cw)
      if (item != "") { if (k != item) next } else if (wave != "" && w != wave) next
      printf "%s\t%s\t%s\n", k, tolower(trim($cc)), (cn ? trim($cn) : "")
      next }
    { if (hdr) exit }')"
  BEST_C=""; BEST_FILES=0; HIT=""; COUNT=0
  while IFS="$(printf '\t')" read -r key cx notes; do
    [ -n "$key" ] || continue
    COUNT=$((COUNT + 1)); ITEM_KEYS="${ITEM_KEYS:+$ITEM_KEYS, }$key"
    case "$cx" in low|medium|high|extra-high) if [ "$(printf '%s' "$BEST_C" | wc -c)" -eq 0 ] || [ "$(case $cx in low) echo 1;; medium) echo 2;; high) echo 3;; *) echo 4;; esac)" -gt "$(case $BEST_C in low) echo 1;; medium) echo 2;; high) echo 3;; *) echo 4;; esac)" ]; then BEST_C="$cx"; fi ;; esac
    text="$notes"; nfiles=0
    bf=""
    if [ -d "$SPEC_DIR/Backlog" ]; then
      lk="$(printf '%s' "$key" | tr 'A-Z' 'a-z')"
      for f in "$SPEC_DIR"/Backlog/*.md; do
        [ -f "$f" ] || continue
        b="$(basename "$f" | tr 'A-Z' 'a-z')"
        case "$b" in "$lk"-*|"$lk.md") bf="$f"; break ;; esac
      done
    fi
    if [ -n "$bf" ]; then
      text="$text
$(head -n 40 "$bf" | tr -d '\r')"
      nfiles="$(tr -d '\r' < "$bf" | awk '/^##[[:space:]]+Impacted Files/ { in_ = 1; next } in_ && /^##[[:space:]]/ { exit } in_ && /^[[:space:]]*[-*][[:space:]]+`/ { n++ } END { print n + 0 }')"
    fi
    if [ "$nfiles" -gt "$BEST_FILES" ]; then BEST_FILES="$nfiles"; fi
    if [ -z "$HIT" ]; then HIT="$(security_hit "$text")"; fi
  done <<EOF
$ROWS
EOF
  if [ -z "$COMPLEXITY" ] && [ -n "$BEST_C" ]; then COMPLEXITY="$BEST_C"; fi
  if [ "$FILES" -eq 0 ]; then FILES="$BEST_FILES"; fi
  if [ "$ITEMS" -eq 0 ] && [ -z "$ITEM" ]; then ITEMS="$COUNT"; fi
  if [ "$RISK" -eq 0 ] && [ -n "$HIT" ]; then RISK=1; REASON_EXTRA="security-sensitive ($HIT)"; fi
fi

CAP="$MAXTIER"
if [ -z "$CAP" ] && [ "$TASK" = "implement" ]; then CAP="$(fget "$SETTINGS_FLAT" routing.implement_max_tier)"; [ -n "$CAP" ] || CAP="balanced"; fi
route "$DEFAULT_TIER" "$DEFAULT_EFFORT" "$TASK" "$DOMAIN" "$RISK" "$COMPLEXITY" "$ITEMS" "$FILES" "$ATTEMPT" "$BUDGET" "$CAP" "$MAXEFFORT"
WHY="$R_REASONS"; if [ -n "$REASON_EXTRA" ]; then WHY="${WHY:+$WHY; }$REASON_EXTRA"; fi; [ -n "$WHY" ] || WHY="default"

# --- resolve to this harness ---
REG_COL="$(fget "$SETTINGS_FLAT" run.registry)"; [ -n "$REG_COL" ] || REG_COL="$HARNESS"
MODEL="$(fget "$REGISTRY_FLAT" "harnesses.$REG_COL.$R_TIER.id")"
if [ -n "$MODEL" ]; then PREFIX="$(fget "$REGISTRY_FLAT" "harnesses.$REG_COL._prefix")"; MODEL="$PREFIX$MODEL"; fi
EFF="$R_EFFORT"; MAPPED="$(fget "$PROFILES_FLAT" "harnesses.$HARNESS.effort_map.$EFF")"; if [ -n "$MAPPED" ]; then EFF="$MAPPED"; fi

if [ "$JSON" -eq 1 ]; then
  esc() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'; }
  printf '{"agent":"%s","task":"%s","harness":"%s","tier":"%s","model":"%s","effort":"%s","neutral_effort":"%s","reasons":"%s","items":"%s"}\n' "$(esc "$AGENT")" "$TASK" "$HARNESS" "$R_TIER" "$(esc "$MODEL")" "$EFF" "$R_EFFORT" "$(esc "$WHY")" "$(esc "$ITEM_KEYS")"
else
  printf '%s\t%s\t%s\t%s\t%s\n' "$R_TIER" "$MODEL" "$EFF" "$WHY" "$ITEM_KEYS"
fi
