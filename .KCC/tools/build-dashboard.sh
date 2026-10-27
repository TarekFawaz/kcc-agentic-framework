#!/usr/bin/env bash
# KCC framework (c) 2026 Tarek Fawaz, https://tikasway.dev/kcc. Licensed under the terms in LICENSE.
# KCC native bash dashboard generator (macOS/Linux). Mirror of build-dashboard.ps1: it collects the same
# data (roadmaps, specs, bugs, backchannel, checkpoints, traces, run state) as one JSON block and fills
# .KCC/kernel/templates/dashboard.html. Offline output: dashboard/index.html. Needs bash 3.2+, awk, sed, grep.
set -eu   # no pipefail: grep exiting 1 on "no match" inside pipelines is normal here

# abs_dir DIR -> ABS: what `cd DIR && pwd` prints. A path that is already absolute without dot segments needs no fork (Git Bash on
# Windows pays ~0.3 s for each one); the cd still runs when the folder is missing, so the error is the same.
abs_dir() {
  [[ -d "$1" ]] || cd "$1"
  case "$1" in
    /*) case "$1/" in */./*|*/../*|*//*) ABS="$(cd "$1" && pwd)" ;; *) ABS="${1%/}"; [[ -n "$ABS" ]] || ABS=/ ;; esac ;;
    *) ABS="$(cd "$1" && pwd)" ;;
  esac
}
SCRIPT_DIR="${BASH_SOURCE[0]}"
case "$SCRIPT_DIR" in */*) SCRIPT_DIR="${SCRIPT_DIR%/*}" ;; *) SCRIPT_DIR="." ;; esac
abs_dir "$SCRIPT_DIR"; SCRIPT_DIR="$ABS"
REPO_ROOT=""
OPEN=0
TEMPLATE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo-root|-RepoRoot) abs_dir "$2"; REPO_ROOT="$ABS"; shift 2 ;;
    --open|-Open) OPEN=1; shift ;;
    --template|-Template) TEMPLATE="$2"; shift 2 ;;
    *) echo "error: unknown argument: $1" >&2; exit 2 ;;
  esac
done
if [[ -z "$REPO_ROOT" ]]; then abs_dir "$SCRIPT_DIR/../.."; REPO_ROOT="$ABS"; fi

MAX_TRACE_CHARS=24000
MAX_EVENTS=4000

# ---- helpers --------------------------------------------------------------
# JSON-escape stdin (no trailing newline).
jstr() { tr -d '\000-\010\013\014\016-\037' | awk 'BEGIN{ORS=""} {gsub(/\\/,"\\\\"); gsub(/"/,"\\\""); gsub(/\t/,"\\t"); gsub(/\r/,""); print sep $0; sep="\\n"}'; }
q() { printf '"'; printf '%s' "$1" | jstr; printf '"'; }
bool() { if [[ "$1" == "1" ]]; then printf 'true'; else printf 'false'; fi; }
num() { if [[ "$1" =~ ^-?[0-9]+$ ]]; then printf '%s' "$1"; else printf '0'; fi; }

# ---- spawn-free helpers ---------------------------------------------------------------------
# Git Bash on Windows pays ~0.3-0.4 s for every fork and every exec, and a build used to run a grep/sed/awk/tr pipeline per field of
# every file (thousands of processes). These helpers work on variables and arrays instead: results come back in globals, never through
# $(...). LC_COLLATE=C makes a glob sort like `LC_ALL=C sort`, and makes the control-character ranges below mean bytes.
LC_COLLATE=C
if [[ "${BASH_VERSINFO[0]}" -ge 4 ]]; then eval 'lcv() { LCV="${1,,}"; }; ucv() { UCV="${1^^}"; }'
else lcv() { LCV="$(printf '%s' "$1" | tr 'A-Z' 'a-z')"; }; ucv() { UCV="$(printf '%s' "$1" | tr 'a-z' 'A-Z')"; }; fi
# qv VALUE -> Q: the JSON string literal for the value, byte for byte what `printf %s VALUE | jstr` framed in quotes gave
# (one trailing newline is a record terminator, not content; other control characters are dropped; lines are joined with \n).
qv() {
  local s="$1"
  if [[ "$s" == *$'\n' ]]; then s="${s%$'\n'}"; fi
  s="${s//[$'\001'-$'\010'$'\013'$'\014'$'\016'-$'\037']/}"
  s="${s//$'\r'/}"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\t'/\\t}"
  s="${s//$'\n'/\\n}"
  Q="\"$s\""
}
# pj FORMAT ARGS...: printf where %q is "the next argument as a JSON string literal" and %s is "the next argument as is".
pjv() {
  local fmt="$1" out="" a head; shift
  while [[ "$fmt" == *%[qs]* ]]; do
    head="${fmt%%%[qs]*}"; a="${fmt:${#head}+1:1}"; fmt="${fmt:${#head}+2}"
    out+="$head"
    if [[ "$a" == q ]]; then qv "${1-}"; out+="$Q"; else out+="${1-}"; fi
    shift || true
  done
  PJ="$out$fmt"
}
pj() { pjv "$@"; printf '%s' "$PJ"; }
numv() { if [[ "$1" =~ ^-?[0-9]+$ ]]; then NV="$1"; else NV=0; fi; }
# rd FILE -> FL[0..FN-1]: the lines of the file without a trailing CR (the {sub(/\r$/,"")} every awk helper here started with)
FL=(); FN=0
rd() {
  FL=(); FN=0
  [[ -f "$1" ]] || return 0
  local l
  while IFS= read -r l || [[ -n "$l" ]]; do FL[FN++]="${l%$'\r'}"; done < "$1"
}
# fm_in KEY -> FV: first value of KEY in the frontmatter of the file rd loaded (fm_get)
fm_in() {
  FV=""
  [[ $FN -gt 0 ]] || return 0
  local i l re="^$1[[:blank:]]*:[[:blank:]]*" re0='^---[[:blank:]]*$'
  [[ "${FL[0]}" =~ $re0 ]] || return 0
  for ((i = 1; i < FN; i++)); do
    l="${FL[i]}"
    if [[ "$l" == ---* ]]; then return 0; fi
    if [[ "$l" =~ $re ]]; then
      l="${l:${#BASH_REMATCH[0]}}"
      l="${l%"${l##*[![:blank:]]}"}"
      l="${l#[\"\']}"; l="${l%[\"\']}"
      FV="$l"; return 0
    fi
  done
}
# h1_in -> H1: the first '# ' heading of the loaded file, without the hashes
h1_in() {
  H1=""
  local i l
  for ((i = 0; i < FN; i++)); do
    if [[ "${FL[i]}" == "# "* ]]; then l="${FL[i]#\#}"; H1="${l#"${l%%[! ]*}"}"; return 0; fi
  done
}
# sec_in PATTERN -> SEC[0..SN-1]: body of the first section whose heading matches the regex (case-insensitive), of the loaded file
sec_in() {
  SEC=(); SN=0
  local i l ins=0 L=0 lvl t pl re_h='^(#+) '
  lcv "$1"; pl="$LCV"
  for ((i = 0; i < FN; i++)); do
    l="${FL[i]}"
    if [[ "$l" =~ $re_h ]]; then
      lvl=${#BASH_REMATCH[1]}
      if [[ $ins -eq 1 && $lvl -le $L ]]; then break; fi
      if [[ $ins -eq 0 ]]; then
        t="${l:$((lvl + 1))}"; lcv "$t"
        if [[ "$LCV" =~ $pl ]]; then ins=1; L=$lvl; continue; fi
      fi
    fi
    if [[ $ins -eq 1 ]]; then SEC[SN++]="$l"; fi
  done
}
# split_bar LINE -> CB[0..CBN-1]: awk's split(line, c, "|") (empty fields kept)
split_bar() {
  CB=(); CBN=0
  local rest="$1"
  while [[ "$rest" == *"|"* ]]; do CB[CBN++]="${rest%%|*}"; rest="${rest#*|}"; done
  CB[CBN++]="$rest"
}
trim_v() { local s="$1"; s="${s#"${s%%[![:space:]]*}"}"; TV="${s%"${s##*[![:space:]]}"}"; }
# tbl_in COLS SRC -> TR[0..TRN-1]: TSV rows of the first table of SRC (FL or SEC; the first argument names it), COLS a comma list of
# lowercase header names (#1 = the first column): the table_tsv awk, row for row
tbl_in() {
  TR=(); TRN=0
  local cols="$1" src="$2" n i j k m l line hdr=0 hm=0 done_=0 out v h w
  local -a W H
  local re_row='^[[:blank:]]*\|' re_sep='^[[:blank:]:|-]+$'
  IFS=',' read -r -a W <<< "$cols"
  n=${#W[@]}
  eval "m=\${#$src[@]}"
  if [[ -n "${3-}" && $m -gt $3 ]]; then m=$3; fi
  for ((k = 0; k < m; k++)); do
    eval "l=\${$src[k]}"
    if [[ "$l" =~ $re_row ]]; then
      if [[ $done_ -eq 1 ]]; then continue; fi
      line="${l#"${l%%[![:blank:]]*}"}"; line="${line#|}"; line="${line%"${line##*[![:blank:]]}"}"; line="${line%|}"
      split_bar "$line"
      if [[ $hdr -eq 0 ]]; then
        for ((i = 0; i < CBN; i++)); do
          h="${CB[i]}"; lcv "$h"; h="$LCV"
          h="${h#"${h%%[![:blank:]*]*}"}"; h="${h%"${h##*[![:blank:]*]}"}"
          H[i]="$h"
        done
        hdr=1; hm=$CBN; continue
      fi
      if [[ "$line" =~ $re_sep ]]; then continue; fi
      out=""
      for ((j = 0; j < n; j++)); do
        v=""
        for ((i = 0; i < hm; i++)); do
          if [[ "${H[i]}" == "${W[j]}" || ( "${W[j]}" == "#1" && $i -eq 0 ) ]]; then
            v="${CB[i]-}"
            v="${v#"${v%%[![:blank:]]*}"}"; v="${v%"${v##*[![:blank:]]}"}"
            v="${v//\[\[/}"; v="${v//\]\]/}"; v="${v//\*\*/}"
          fi
        done
        if [[ $j -gt 0 ]]; then out+=$'\t'; fi
        out+="$v"
      done
      TR[TRN++]="$out"
    elif [[ $hdr -eq 1 ]]; then done_=1; fi
  done
}

if printf '' 2>/dev/null && printf '%(%s)T' -1 >/dev/null 2>&1; then TZ=UTC printf -v NOW '%(%Y-%m-%dT%H:%M:%SZ)T' -1
else NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"; fi
PROJECT="${REPO_ROOT##*/}"; [[ -n "$PROJECT" ]] || PROJECT="/"

# ---- run + states ------------------------------------------------------------
# rj_load FILE -> RJ[0..RJN-1] (every CR removed, as tr -d '\r'); rawv KEY -> RV: the first line of RJ that has "KEY":"value"
# gives the value (the last such pair on that line, like the greedy sed it replaces), with \" and \\ unescaped.
RJ=(); RJN=0; RV=""
rj_load() {
  RJ=(); RJN=0
  [[ -f "$1" ]] || return 0
  local l
  while IFS= read -r l || [[ -n "$l" ]]; do RJ[RJN++]="${l//$'\r'/}"; done < "$1"
}
rawv() {
  RV=""
  local i re='^.*"'"$1"'"[[:space:]]*:[[:space:]]*"(([^"\\]|\\.)*)"'
  for ((i = 0; i < RJN; i++)); do
    if [[ "${RJ[i]}" =~ $re ]]; then
      RV="${BASH_REMATCH[1]}"
      RV="${RV//\\\"/\"}"; RV="${RV//\\\\/\\}"
      return 0
    fi
  done
}
RUN_FILE="$REPO_ROOT/coordination/run/run.json"
FAST=0; PAR=0; SCEN=""
if [[ -f "$RUN_FILE" ]]; then
  rj_load "$RUN_FILE"
  rawv fasttrack; if [[ "$RV" == "1" ]]; then FAST=1; fi
  rawv parallel; if [[ "$RV" == "1" ]]; then PAR=1; fi
  # a chat orchestrator writes the flags as a list: "flags":["--fasttrack"]
  RJTXT="$(<"$RUN_FILE")"
  if [[ "$RJTXT" == *--fasttrack* ]]; then FAST=1; fi
  if [[ "$RJTXT" == *--parallel* ]]; then PAR=1; fi
fi
# A chat run may have no run.json at all: its policy is in the first auto-policy-parsed event.
if [[ -f "$REPO_ROOT/coordination/backchannel.jsonl" ]]; then
  pol=""; re_pol='"kind"[[:space:]]*:[[:space:]]*"auto-policy-parsed"'
  while IFS= read -r l || [[ -n "$l" ]]; do
    if [[ "$l" =~ $re_pol ]]; then pol="$l"; break; fi
  done < "$REPO_ROOT/coordination/backchannel.jsonl"
  re_f='--fasttrack|"fasttrack"[[:space:]]*:[[:space:]]*(true|"1")'; re_p='--parallel|"parallel"[[:space:]]*:[[:space:]]*(true|"1")'
  if [[ "$pol" =~ $re_f ]]; then FAST=1; fi
  if [[ "$pol" =~ $re_p ]]; then PAR=1; fi
  rawv scenario; SCEN="$RV"
fi

# The state table: ST_ID/ST_SKIP per state, the JSON records, and max_attempts. The file is read once; it is cut at every `{ "id"` into
# records, and each field is the last pair of that name in its record (what the sed pipeline did).
ST_ID=(); ST_SKIP=(); ST_N=0; STATES_JSON=""; STATES_MAXATT=3
load_states() {
  local f="$REPO_ROOT/.KCC/kernel/auto-states.json" txt rec id name scope skipped skipv onlyv gotov first=1 pat nlrec qn qs bs
  local re_id='^\{ *"id" *: *([0-9]+)' re_name='^.*"name" *: *"([^"]*)"' re_scope='^.*"scope" *: *"([^"]*)"'
  local re_skip='^.*"skip_if_flag" *: *(\[[^]]*\]|"[^"]*")' re_only='^.*"only_in" *: *(\[[^]]*\])' re_goto='^.*"on_fail_goto" *: *([0-9]+)' re_max='^.*"max_attempts" *: *([0-9]+)'
  if [[ $FAST -eq 1 && -f "$REPO_ROOT/.KCC/kernel/auto-states-fasttrack.json" ]]; then f="$REPO_ROOT/.KCC/kernel/auto-states-fasttrack.json"; fi
  [[ -f "$f" ]] || return 0
  txt="$(<"$f")"; txt="${txt//$'\r'/}"; txt="${txt//$'\n'/}"
  if [[ "$txt" =~ $re_max ]]; then STATES_MAXATT="${BASH_REMATCH[1]}"; fi
  # cut at every `{ "id"` with literal patterns (one, two, no spaces): the extglob `{*( )"id"` this used took 5 s of CPU per
  # build on Linux bash 5.2, which timed out every dashboard test on the release runner (0.6.0)
  nlrec=$'\n{ "id"'; txt="${txt//\{ \"id\"/$nlrec}"; txt="${txt//\{  \"id\"/$nlrec}"; txt="${txt//\{\"id\"/$nlrec}"
  while IFS= read -r rec || [[ -n "$rec" ]]; do
    [[ "$rec" =~ $re_id ]] || continue
    id="${BASH_REMATCH[1]}"
    name=""; if [[ "$rec" =~ $re_name ]]; then name="${BASH_REMATCH[1]}"; fi
    scope=""; if [[ "$rec" =~ $re_scope ]]; then scope="${BASH_REMATCH[1]}"; fi
    skipped=0
    skipv=""; if [[ "$rec" =~ $re_skip ]]; then skipv="${BASH_REMATCH[1]}"; fi
    if [[ -n "$skipv" ]]; then
      if [[ "$skipv" == *fasttrack* && $FAST -eq 1 ]]; then skipped=1; fi
      if [[ "$skipv" == *parallel* && $PAR -eq 1 ]]; then skipped=1; fi
    fi
    onlyv=""; if [[ "$rec" =~ $re_only ]]; then onlyv="${BASH_REMATCH[1]}"; fi
    if [[ -n "$onlyv" && -n "$SCEN" && "$onlyv" != *"\"$SCEN\""* ]]; then skipped=1; fi
    # on_fail_goto: where a failed exit check sends the spec (the loop-back edge of the lifecycle flowchart)
    gotov=""; if [[ "$rec" =~ $re_goto ]]; then gotov="${BASH_REMATCH[1]}"; fi
    numv "$id"; qv "$name"; qn="$Q"; qv "$scope"; qs="$Q"; if [[ $skipped -eq 1 ]]; then bs=true; else bs=false; fi
    if [[ $first -eq 1 ]]; then first=0; else STATES_JSON+=","; fi
    STATES_JSON+="{\"id\":$NV,\"name\":$qn,\"scope\":$qs,\"skipped\":$bs,\"goto\":${gotov:-null}}"
    ST_ID[ST_N]="$id"; ST_SKIP[ST_N]="$skipped"; ST_N=$((ST_N + 1))
  done <<EOF
$txt
EOF
}
load_states
emit_states() { printf '%s' "$STATES_JSON"; }
states_max_attempts() { printf '%s' "$STATES_MAXATT"; }

# ---- ideas ---------------------------------------------------------------------
emit_ideas() {
  local d="$REPO_ROOT/ideation" first=1 x folder f id title st slug files nm fl out
  [[ -d "$d" ]] || return 0
  for x in "$d"/IDEA-*; do
    [[ -e "$x" ]] || continue
    folder="${x##*/}"
    f=""; for fl in "$d/$folder"/idea-*.md; do if [[ -e "$fl" ]]; then f="$fl"; fi; break; done
    id=""; if [[ "$folder" =~ ^IDEA-[0-9]+ ]]; then id="${BASH_REMATCH[0]}"; fi
    title=""; st=""; slug=""
    if [[ -n "$f" ]]; then
      rd "$f"; fm_in title; title="$FV"; if [[ -z "$title" ]]; then h1_in; title="$H1"; fi
      fm_in status; st="$FV"; fm_in slug; slug="$FV"
    fi
    files=""
    for fl in "$d/$folder"/*.md; do
      if [[ -e "$fl" ]]; then nm="${fl##*/}"; if [[ "$nm" == *[![:space:]]* ]]; then files+="${files:+,}\"$nm\""; fi; fi
    done
    if [[ $first -eq 1 ]]; then first=0; else printf ','; fi
    pj '{"id":%q,"folder":%q,"title":%q,"slug":%q,"status":%q,"files":[%s]}' "$id" "$folder" "$title" "$slug" "$st" "$files"
  done
}

# ---- ADRs ------------------------------------------------------------------------
emit_adrs() {
  local d="$REPO_ROOT/architecture/adrs" first=1 f id title st i l nm re_id='^ADR-[0-9]+' re_t='^ADR-[0-9]+ *[:-]? *'
  [[ -d "$d" ]] || return 0
  for f in "$d"/ADR-*.md; do
    [[ -e "$f" ]] || continue
    nm="${f##*/}"
    id=""; if [[ "$nm" =~ $re_id ]]; then id="${BASH_REMATCH[0]}"; fi
    rd "$f"
    h1_in; title="$H1"; if [[ "$title" =~ $re_t ]]; then title="${title:${#BASH_REMATCH[0]}}"; fi
    fm_in status; st="$FV"
    if [[ -z "$st" ]]; then
      sec_in '^Status'
      for ((i = 0; i < SN; i++)); do
        l="${SEC[i]}"
        if [[ "$l" == *[![:space:]]* ]]; then
          if [[ "$l" == *"("* ]]; then st="${l%%(*}"; st="${st%"${st##*[! ]}"}"; else st="$l"; fi
          break
        fi
      done
    fi
    if [[ $first -eq 1 ]]; then first=0; else printf ','; fi
    pj '{"id":%q,"title":%q,"status":%q,"file":%q}' "$id" "$title" "$st" "architecture/adrs/$nm"
  done
}

# ---- specs + roadmaps ----------------------------------------------------------------
ROADMAPS_JSON=""
SPECS_JSON=""
# split_tab ROW -> TF[0..TFN-1]: cut -f / awk -F'\t' fields (empty ones kept)
split_tab() {
  TF=(); TFN=0
  local rest="$1"
  while [[ "$rest" == *$'\t'* ]]; do TF[TFN++]="${rest%%$'\t'*}"; rest="${rest#*$'\t'}"; done
  TF[TFN++]="$rest"
}
# ac_json -> ACJ: the '- [x] AC-n text' lines of SEC as JSON objects (ac_tsv | awk): the text is cut at its first tab and only \ and "
# are escaped there (as that awk did), the rest of the object is fixed
ac_json() {
  ACJ=""
  local i l head rest d id first=1 re='^[[:blank:]]*[-*][[:blank:]]*\[[ xX]\][[:blank:]]*AC-[0-9]+' re_id='AC-[0-9]+' re_x='\[[xX]\]' re_lead='^[[:blank:]]*[-:][[:blank:]]*' re_wl='\[\[[^]|]*\|'
  for ((i = 0; i < SN; i++)); do
    l="${SEC[i]}"
    if [[ "$l" =~ $re ]]; then
      head="${BASH_REMATCH[0]}"; rest="${l:${#head}}"
      d=false; if [[ "$head" =~ $re_x ]]; then d=true; fi
      [[ "$head" =~ $re_id ]]; id="${BASH_REMATCH[0]}"
      if [[ "$rest" =~ $re_lead ]]; then rest="${rest:${#BASH_REMATCH[0]}}"; fi
      while [[ "$rest" =~ $re_wl ]]; do rest="${rest/"${BASH_REMATCH[0]}"/}"; done
      rest="${rest//\[\[/}"; rest="${rest//\]\]/}"
      rest="${rest%%$'\t'*}"
      rest="${rest//\\/\\\\}"; rest="${rest//\"/\\\"}"
      if [[ $first -eq 1 ]]; then first=0; else ACJ+=","; fi
      ACJ+="{\"id\":\"$id\",\"text\":\"$rest\",\"done\":$d}"
    fi
  done
}
# count_words RE -> CW: how many whole-word, case-insensitive matches of the ERE the loaded file has (grep -oiwE RE | wc -l)
count_words() {
  CW=0
  local i rest re="(^|[^[:alnum:]_])($1)([^[:alnum:]_]|\$)"
  shopt -s nocasematch
  for ((i = 0; i < FN; i++)); do
    rest="${FL[i]}"
    while [[ "$rest" =~ $re ]]; do CW=$((CW + 1)); rest="${rest#*"${BASH_REMATCH[0]}"}"; done
  done
  shopt -u nocasematch
}
# first_word RE ARRAY-NAME -> FW: the first whole-word case-insensitive match of the ERE in the lines of that array, upper-cased
first_word() {
  FW=""
  local i m l re="(^|[^[:alnum:]_])($1)([^[:alnum:]_]|\$)"
  eval "m=\${#$2[@]}"
  shopt -s nocasematch
  for ((i = 0; i < m; i++)); do
    eval "l=\${$2[i]}"
    if [[ "$l" =~ $re ]]; then ucv "${BASH_REMATCH[2]}"; FW="$UCV"; break; fi
  done
  shopt -u nocasematch
}
# adr_scan: add the ADR-n ids of the loaded file to ADRS (a newline-delimited set)
adr_scan() {
  local i rest re='ADR-[0-9]+'
  for ((i = 0; i < FN; i++)); do
    rest="${FL[i]}"
    while [[ "$rest" =~ $re ]]; do
      case "$ADRS" in *$'\n'"${BASH_REMATCH[0]}"$'\n'*) ;; *) ADRS+="${BASH_REMATCH[0]}"$'\n' ;; esac
      rest="${rest#*"${BASH_REMATCH[0]}"}"
    done
  done
}
collect_specs() {
  local sd="$REPO_ROOT/specs" gp group ideaId sfp sf specId note sLines status prio cat wave title rfirst=1 sfirst=1
  [[ -d "$sd" ]] || return 0
  local re_grp='^IDEA-.*-Specs$' re_idea='^IDEA-[0-9]+' re_spec='^SPEC-[0-9A-Za-z]+' re_rt='^Roadmap *[-:] *' re_st='^SPEC-[0-9A-Za-z]+ *[:-]? *' re_it='^(Story|Enabler|Bug)-[0-9]+' re_itt='^(Story|Enabler|Bug)-[0-9]+ *[:-]? *'
  for gp in "$sd"/IDEA-*-Specs; do
    [[ -e "$gp" ]] || continue
    group="${gp##*/}"
    [[ "$group" =~ $re_grp ]] || continue
    ideaId=""; if [[ "$group" =~ $re_idea ]]; then ideaId="${BASH_REMATCH[0]}"; fi
    local rm="$sd/$group/ROADMAP.md"
    if [[ -f "$rm" ]]; then
      local rows rtitle ri nonempty=0 rj first_r=1 rj_out=""
      rd "$rm"
      sec_in '^Execution Plan'
      for ((ri = 0; ri < SN; ri++)); do if [[ -n "${SEC[ri]}" ]]; then nonempty=1; break; fi; done
      if [[ $nonempty -eq 1 ]]; then tbl_in "order,spec,delivery,depends on,lane,est. tokens,restore point" SEC
      else tbl_in "order,spec,delivery,depends on,lane,est. tokens,restore point" FL; fi
      h1_in; rtitle="$H1"; if [[ "$rtitle" =~ $re_rt ]]; then rtitle="${rtitle:${#BASH_REMATCH[0]}}"; fi
      for ((ri = 0; ri < TRN; ri++)); do
        split_tab "${TR[ri]}"
        if [[ $first_r -eq 1 ]]; then first_r=0; else rj_out+=","; fi
        rj_out+="{\"order\":\"${TF[0]-}\",\"spec\":\"${TF[1]-}\",\"delivery\":\"${TF[2]-}\",\"dependsOn\":\"${TF[3]-}\",\"lane\":\"${TF[4]-}\",\"tokens\":\"${TF[5]-}\",\"restore\":\"${TF[6]-}\"}"
      done
      if [[ $rfirst -eq 1 ]]; then rfirst=0; else ROADMAPS_JSON+=","; fi
      qv "$ideaId"; local qi="$Q"; qv "$rtitle"
      ROADMAPS_JSON+="{\"ideaId\":$qi,\"title\":$Q,\"columns\":[\"order\",\"spec\",\"delivery\",\"dependsOn\",\"lane\",\"tokens\",\"restore\"],\"rows\":[$rj_out]}"
    fi
    for sfp in "$sd/$group"/SPEC-*; do
      [[ -e "$sfp" ]] || continue
      sf="${sfp##*/}"
      [[ "$sf" =~ ^SPEC- ]] || continue
      [[ -d "$sd/$group/$sf" ]] || continue
      local dir="$sd/$group/$sf"
      specId=""; if [[ "$sf" =~ $re_spec ]]; then specId="${BASH_REMATCH[0]}"; fi
      # A spec built in a lane (.kcc-lanes/SPEC-x, .worktrees/SPEC-x) changes its backlog, plan, review and test results there;
      # the workspace copy only catches up when the lane merges. Read the lane copy when there is one.
      local trroot="$REPO_ROOT" ld lcp
      for ld in .kcc-lanes .worktrees; do
        lcp="$REPO_ROOT/$ld/$specId/specs/$group/$sf"
        if [[ -d "$lcp" ]]; then dir="$lcp"; trroot="$REPO_ROOT/$ld/$specId"; break; fi
      done
      note=""
      for nfp in "$dir"/SPEC-*.md; do
        [[ -e "$nfp" ]] || continue
        lcv "$nfp"; if [[ "$LCV" != *backlog* ]]; then note="$nfp"; break; fi
      done
      status=""; prio=""; cat=""; wave=""; title=""
      local who gets value measured acs_json="" BL=() BLN=0 lab val
      who=""; gets=""; value=""; measured=""
      local ADRS=$'\n'
      if [[ -n "$note" ]]; then
        rd "$note"
        # the header table is in the first 12 lines
        tbl_in "status,priority,category,wave" FL 12
        if [[ $TRN -gt 0 ]]; then split_tab "${TR[0]}"; status="${TF[0]-}"; prio="${TF[1]-}"; cat="${TF[2]-}"; wave="${TF[3]-}"; fi
        if [[ -z "$status" ]]; then fm_in status; status="$FV"; fi
        h1_in; title="$H1"; if [[ "$title" =~ $re_st ]]; then title="${title:${#BASH_REMATCH[0]}}"; fi
        if [[ -z "$title" ]]; then fm_in title; title="$FV"; fi
        adr_scan
        # delivery brief
        local re_b='^[[:blank:]]*[-*][[:blank:]]*\*\*[^*]+\*\*' bl bv
        sec_in '^Delivery Brief'
        for ((ri = 0; ri < SN; ri++)); do
          if [[ "${SEC[ri]}" =~ $re_b ]]; then
            bl="${BASH_REMATCH[0]}"; bv="${SEC[ri]:${#bl}}"
            bl="${bl#"${bl%%[![:blank:]]*}"}"; bl="${bl#[-*]}"; bl="${bl#"${bl%%[![:blank:]]*}"}"; bl="${bl#\*\*}"; bl="${bl%\*\*}"; bl="${bl//:/}"
            if [[ "$bv" == :* ]]; then bv="${bv#:}"; fi
            bv="${bv#"${bv%%[![:blank:]]*}"}"
            lcv "$bl"
            IFS=$'\t' read -r lab val <<< "$LCV"$'\t'"$bv"
            case "$lab" in who) who="$val" ;; gets) gets="$val" ;; value) value="$val" ;; measured*) measured="$val" ;; esac
          fi
        done
        # spec-level acceptance criteria
        sec_in '^Acceptance Criteria'; ac_json; acs_json="$ACJ"
        # backlog table (status/wave fallback)
        sec_in '^Backlog'; tbl_in "key,type,title,status,depends on,wave" SEC
        BL=(); for ((ri = 0; ri < TRN; ri++)); do BL[ri]="${TR[ri]}"; done; BLN=$TRN
      fi
      # items and bugs
      local items_json="" bugs_json="" seen=" " bf key type ititle bstat bdialect bdep bwave brow
      local ifirst=1 bfirst=1
      if [[ -d "$dir/Backlog" ]]; then
        for bf in "$dir/Backlog"/*.md; do
          [[ -e "$bf" ]] || continue
          key=""; nm="${bf##*/}"; if [[ "$nm" =~ $re_it ]]; then key="${BASH_REMATCH[0]}"; fi
          [[ -n "$key" ]] || continue
          type="${key%%-*}"
          rd "$bf"
          h1_in; ititle="$H1"; if [[ "$ititle" =~ $re_itt ]]; then ititle="${ititle:${#BASH_REMATCH[0]}}"; fi
          seen="$seen$key "
          if [[ "$type" == "Bug" ]]; then
            local sev bst src ref tst
            tbl_in "severity,status,source,story / ac,regression test" FL 14
            sev=""; bst=""; src=""; ref=""; tst=""
            if [[ $TRN -gt 0 ]]; then split_tab "${TR[0]}"; sev="${TF[0]-}"; bst="${TF[1]-}"; src="${TF[2]-}"; ref="${TF[3]-}"; tst="${TF[4]-}"; fi
            if [[ $bfirst -eq 1 ]]; then bfirst=0; else bugs_json+=","; fi
            pjv '{"key":%q,"title":%q,"severity":%q,"status":%q,"source":%q,"ref":%q,"test":%q}' "$key" "$ititle" "$sev" "$bst" "$src" "$ref" "$tst"; bugs_json+="$PJ"
            continue
          fi
          tbl_in "status,dialect,depends on" FL 14
          bstat=""; bdialect=""; bdep=""
          if [[ $TRN -gt 0 ]]; then split_tab "${TR[0]}"; bstat="${TF[0]-}"; bdialect="${TF[1]-}"; bdep="${TF[2]-}"; fi
          brow=""
          for ((ri = 0; ri < BLN; ri++)); do
            split_tab "${BL[ri]}"
            if [[ "${TF[0]-}" == "$key" ]]; then brow="${BL[ri]}"; break; fi
          done
          split_tab "$brow"
          if [[ -z "$bstat" ]]; then bstat="${TF[3]-}"; fi
          if [[ -z "$ititle" ]]; then ititle="${TF[2]-}"; fi
          if [[ -z "$bdep" ]]; then bdep="${TF[4]-}"; fi
          bwave="${TF[5]-}"
          sec_in '^Acceptance Criteria'; ac_json
          if [[ $ifirst -eq 1 ]]; then ifirst=0; else items_json+=","; fi
          pjv '{"key":%q,"type":%q,"title":%q,"status":%q,"wave":%q,"dependsOn":%q,"dialect":%q,"acs":[%s]}' "$key" "$type" "$ititle" "$bstat" "$bwave" "$bdep" "$bdialect" "$ACJ"; items_json+="$PJ"
        done
      fi
      # table rows whose item file is missing
      local k t ti st dep wv
      for ((ri = 0; ri < BLN; ri++)); do
        IFS=$'\t' read -r k t ti st dep wv <<< "${BL[ri]}"
        [[ -n "$k" && "$k" != Bug-* ]] || continue
        case "$seen" in *" $k "*) continue ;; esac
        if [[ $ifirst -eq 1 ]]; then ifirst=0; else items_json+=","; fi
        pjv '{"key":%q,"type":%q,"title":%q,"status":%q,"wave":%q,"dependsOn":%q,"dialect":"","acs":[]}' "$k" "$t" "$ti" "$st" "$wv" "$dep"; items_json+="$PJ"
      done
      # plan
      local pexists=false pstatus="" pwaves=0 ptests=0 plan="$dir/plan.md" wseen=$'\n' v
      if [[ -f "$plan" ]]; then
        pexists=true
        rd "$plan"
        fm_in status; pstatus="$FV"
        adr_scan
        sec_in '^Waves'; tbl_in "#1" SEC
        for ((ri = 0; ri < TRN; ri++)); do
          v="${TR[ri]}"
          if [[ "$v" == *[![:space:]]* ]]; then case "$wseen" in *$'\n'"$v"$'\n'*) ;; *) wseen+="$v"$'\n'; pwaves=$((pwaves + 1)) ;; esac; fi
        done
        sec_in '^Atomic test cases'; tbl_in "#1" SEC
        ptests=0
        for ((ri = 0; ri < TRN; ri++)); do if [[ "${TR[ri]}" == *[![:space:]]* ]]; then ptests=$((ptests + 1)); fi; done
      fi
      # review
      local rexists=false rverdict=""
      if [[ -f "$dir/review.md" ]]; then
        rexists=true
        # the review's own word: frontmatter "verdict:", else the "Verdict" section, else the first one named anywhere (QUALITY_DEFERRED; TOOLCHAIN_DEFERRED is the older name)
        local vre='APPROVED|CHANGES_NEEDED|QUALITY_DEFERRED|TOOLCHAIN_DEFERRED|WAIVER_NEEDED|BLOCKED' VA=()
        rd "$dir/review.md"
        fm_in verdict; VA=("$FV"); first_word "$vre" VA; rverdict="$FW"
        if [[ -z "$rverdict" ]]; then sec_in '^Verdict'; first_word "$vre" SEC; rverdict="$FW"; fi
        if [[ -z "$rverdict" ]]; then first_word "$vre" FL; rverdict="$FW"; fi
      fi
      # test results
      local verdict="null" trf="$trroot/TestResults/$ideaId/$specId/test-run-summary.md" tp tf
      if [[ -f "$trf" ]]; then
        rd "$trf"; count_words 'PASS|PASSED'; tp="$CW"; count_words 'FAIL|FAILED'; tf="$CW"
        verdict="{\"pass\":$tp,\"fail\":$tf}"
      fi
      # ADR refs
      local adrs="" ar sorted=() n2 j2 tmp2
      if [[ -f "$dir/arch.md" ]]; then rd "$dir/arch.md"; adr_scan; fi
      while IFS= read -r ar; do [[ -n "$ar" ]] || continue; sorted[${#sorted[@]}]="$ar"; done <<< "$ADRS"
      n2=${#sorted[@]}
      for ((ri = 1; ri < n2; ri++)); do
        tmp2="${sorted[ri]}"; j2=$((ri - 1))
        while [[ $j2 -ge 0 && "${sorted[j2]}" > "$tmp2" ]]; do sorted[j2 + 1]="${sorted[j2]}"; j2=$((j2 - 1)); done
        sorted[j2 + 1]="$tmp2"
      done
      for ((ri = 0; ri < n2; ri++)); do adrs+="${adrs:+,}\"${sorted[ri]}\""; done
      if [[ $sfirst -eq 1 ]]; then sfirst=0; else SPECS_JSON+=","; fi
      numv "$pwaves"; local nw="$NV"; numv "$ptests"; local nt="$NV"
      pjv '{"id":%q,"ideaId":%q,"folder":%q,"title":%q,"status":%q,"priority":%q,"category":%q,"wave":%q,"deliveryBrief":{"who":%q,"gets":%q,"value":%q,"measured":%q},"acs":[%s],"items":[%s],"bugs":[%s],"plan":{"exists":%s,"status":%q,"waves":%s,"tests":%s},"review":{"exists":%s,"verdict":%q},"verdict":%s,"adrRefs":[%s]}' \
        "$specId" "$ideaId" "$sf" "$title" "$status" "$prio" "$cat" "$wave" "$who" "$gets" "$value" "$measured" "$acs_json" "$items_json" "$bugs_json" \
        "$pexists" "$pstatus" "$nw" "$nt" "$rexists" "$rverdict" "$verdict" "$adrs"; SPECS_JSON+="$PJ"
    done
  done
}

# ---- run object -------------------------------------------------------------------------
# The `auto` skill in a chat session records progress as backchannel events but does not keep the
# driver's run.json `state`; derive the stage from the events so the pipeline does not sit on REPO.
derive_state() { # prints "<state> <running|done>" or nothing
  local bc="$REPO_ROOT/coordination/backchannel.jsonl" r ids="" si
  DV=""
  [[ -f "$bc" ]] || return 0
  # Non-skipped state ids, in order, so "the next stage after N" skips what --fasttrack skips.
  for ((si = 0; si < ST_N; si++)); do if [[ "${ST_SKIP[si]}" == "0" ]]; then ids+="${ST_ID[si]} "; fi; done
  # Run-wide stages (up to SPECS) advance on any event; PLAN..REVIEW advance per spec, and the pipeline shows
  # the earliest stage a spec is still in (a spec-less event, e.g. an early preflight, moves nothing).
  r="$(tr -d '\r' < "$bc" | awk -v ids="$ids" -v wr="$FAST" '
    function nxt(d,   i) { for (i = 1; i <= n; i++) if (ord[i] + 0 > d + 0) return ord[i] + 0; return d + 0 }
    BEGIN { n = split(ids, ord, " ") }
    { k = ""; f = ""; sp = ""
      if (match($0, /"kind" *: *"[^"]*"/)) { k = substr($0, RSTART, RLENGTH); sub(/^"kind" *: *"/, "", k); sub(/"$/, "", k) }
      if (match($0, /"from" *: *"[^"]*"/)) f = substr($0, RSTART, RLENGTH)
      if (match($0, /"spec" *: *"SPEC-[^"]*"/)) { sp = substr($0, RSTART, RLENGTH); sub(/^"spec" *: *"/, "", sp); sub(/"$/, "", sp) }
      id = -1
      if (k == "specialist-brief-created") id = (f ~ /technical/) ? 3 : 4
      else if (k == "idea-interrogation-completed") id = 1
      else if (k == "architecture-pass-complete") id = 6
      else if (k == "spec-created" || k == "roadmap-created") id = 9
      else if (k == "plan-created") id = 11
      else if (k == "toolchain-preflight-result") id = 14
      else if (k == "implement-completed") id = 15
      else if (k == "test-completed") id = 16
      else if (k == "review-produced") id = 17
      else if (k == "session-closed") { id = 18; closed = 1 }
      if (k == "spec-created" && sp != "" && !(sp in sd)) sd[sp] = (wr == 1 ? 10 : 9) # fast track has a WRITE state (10): a spec-created event with a spec means it is written
      if (id >= 0 && id < 10) { if (id > done) done = id }
      else if (id >= 10 && id < 18 && sp != "") { if (!(sp in sd) || id > sd[sp]) sd[sp] = id }
      else if (id == 18) done = 18
      else if (id == 14 && sp == "") { for (x in sd) if (sd[x] >= 11 && sd[x] < 14) sd[x] = 14 }
      s = -1
      if (k == "toolchain-preflight-started") s = 14; else if (k == "implement-started") s = 15; else if (k == "test-started") s = 16
      if (s > 0 && sp != "" && (!(sp in ss) || s > ss[sp])) ss[sp] = s
      seen = 1
    }
    END { if (!seen) exit
      cur = -1
      if (done >= 9 && done < 18) { for (sp in sd) { v = nxt(sd[sp]); if ((sp in ss) && ss[sp] > sd[sp]) v = ss[sp]; if (cur < 0 || v < cur) cur = v } }
      if (cur < 0) cur = (done >= 18) ? 18 : nxt(done)
      printf "%d %s\n", cur, (closed ? "done" : "running") }')"
  [[ -n "$r" ]] || return 0
  if [[ "${r#* }" == "running" ]]; then
    # Nothing happened for 30 minutes (no event, no agent transcript written): idle, not running.
    local lastts pd recent=0 le now
    lastts="$(tr -d '\r' < "$bc" | grep -oE '"ts"[[:space:]]*:[[:space:]]*"[^"]+"' | tail -n 1 | sed -E 's/.*"([^"]+)"$/\1/')"
    claude_project_dir 2>/dev/null || true; pd="$CPD"
    if [[ -n "$pd" && -d "$pd" ]] && [[ -n "$(find "$pd" -name '*.jsonl' -mmin -30 2>/dev/null | head -n 1)" ]]; then recent=1; fi
    if [[ $recent -eq 0 && -n "$lastts" ]]; then
      le="$(date -u -d "$lastts" +%s 2>/dev/null || date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$lastts" +%s 2>/dev/null || echo 0)"; now="$(date -u +%s)"
      if [[ "$le" -gt 0 && $((now - le)) -gt 1800 ]]; then r="${r%% *} idle"; note_add 'Run marked idle: nothing happened for more than 30 minutes.'; fi
    fi
  fi
  DV="$r"
}


# ---- lanes: git worktrees (.worktrees/) and kcc run lanes (.kcc-lanes/) where specs are being built ----
# epoch_iso EPOCH -> EI (UTC ISO-8601); the printf builtin where bash has it, date otherwise
if printf '%(%s)T' -1 >/dev/null 2>&1; then epoch_iso() { TZ=UTC printf -v EI '%(%Y-%m-%dT%H:%M:%SZ)T' "$1"; }
else epoch_iso() { EI="$(date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "")"; }; fi
emit_lanes() {
  local ld d n files last first=1 spec lrf lst lwv lss lrs lat lgi lgn lgs lup t x re_sp='SPEC-[0-9A-Za-z]+'
  for ld in .worktrees .kcc-lanes; do
    [[ -d "$REPO_ROOT/$ld" ]] || continue
    for d in "$REPO_ROOT/$ld"/*/; do
      [[ -d "$d" ]] || continue
      n="${d%/}"; n="${n##*/}"; spec=""; if [[ "$n" =~ $re_sp ]]; then spec="${BASH_REMATCH[0]}"; fi
      files=0
      if [[ -d "$d/src" ]]; then
        while IFS= read -r x; do files=$((files + 1)); done < <(find "$d/src" -type f -not -path '*/node_modules/*' 2>/dev/null)
      fi
      last=""
      while IFS= read -r t; do
        t="${t%%.*}"
        if [[ -z "$last" || "$t" -gt "$last" ]]; then last="$t"; fi
      done < <(find "$d" -maxdepth 4 -type f -not -path '*/node_modules/*' -not -path '*/.git/*' -printf '%T@\n' 2>/dev/null)
      if [[ -n "$last" ]]; then epoch_iso "$last"; last="$EI"; fi
      if [[ $first -eq 1 ]]; then first=0; else printf ','; fi
      lrf="$d/coordination/run/run.json"; lst=""; lwv=""; lss=""; lrs=""; lat=""; lgi=""; lgn=""; lgs=""; lup=""
      if [[ -f "$lrf" ]]; then
        rj_load "$lrf"
        rawv state; lst="$RV"; rawv wave; lwv="$RV"; rawv status; lss="$RV"
        rawv reason; lrs="$RV"; rawv attempts; lat="$RV"; rawv gate_id; lgi="$RV"; rawv gate_name; lgn="$RV"; rawv gate_state; lgs="$RV"; rawv updated; lup="$RV"
      fi
      pj '{"name":%q,"kind":%q,"spec":%q,"files":%s,"updated":%q,"runState":%q,"runWave":%q,"runStatus":%q,"runReason":%q,"runAttempts":%q,"runGateId":%q,"runGateName":%q,"runGateState":%q,"runUpdated":%q}' "$n" "${ld#.}" "$spec" "${files:-0}" "$last" "$lst" "$lwv" "$lss" \
        "$lrs" "$lat" "$lgi" "$lgn" "$lgs" "$lup"
    done
  done
}

emit_run() {
  local specs idx cur="" st dv rsn="" sp re_sp='SPEC-[0-9A-Za-z]+' e
  local -a spl
  rj_load "$RUN_FILE"
  rawv state; st="$RV"
  if [[ ! -f "$RUN_FILE" ]] || [[ -z "$st" ]]; then
    derive_state; dv="$DV"
    if [[ -n "$dv" ]]; then
      note_add 'Stage derived from backchannel events (chat-driven run).'
      if [[ "${dv#* }" == "idle" ]]; then rsn="no event or agent activity for more than 30 minutes; resume with: auto resume"; fi
      local dd="" di=""
      if [[ -f "$RUN_FILE" ]]; then rawv depthlevel; dd="$RV"; rawv idea; di="$RV"; fi
      if [[ $FAST -eq 1 ]]; then e=true; else e=false; fi
      local pb=false; if [[ $PAR -eq 1 ]]; then pb=true; fi
      pj '{"status":%q,"state":%s,"wave":"","scenario":%q,"harness":"chat","fasttrack":%s,"parallel":%s,"depthlevel":%q,"reason":%q,"updated":"","created":"","input":"","idea":%q,"currentSpec":"","gate_name":"","attempts":"","gate_id":"","gate_state":"","gate_spec":""}' \
        "${dv#* }" "${dv%% *}" "$SCEN" "$e" "$pb" "$dd" "$rsn" "$di"
      return 0
    fi
  fi
  [[ -f "$RUN_FILE" ]] || { printf 'null'; return 0; }
  rawv specs; specs="$RV"; rawv spec_index; idx="$RV"
  [[ "$idx" =~ ^[0-9]+$ ]] || idx=0
  # the idx-th entry of the (space separated) specs list that is not empty, then its SPEC-id
  cur=""; local ci=0
  for sp in $specs; do
    if [[ $ci -eq $idx ]]; then if [[ "$sp" =~ $re_sp ]]; then cur="${BASH_REMATCH[0]}"; fi; break; fi
    ci=$((ci + 1))
  done
  numv "$st"; local nst="$NV"
  local f_b=false p_b=false; if [[ $FAST -eq 1 ]]; then f_b=true; fi; if [[ $PAR -eq 1 ]]; then p_b=true; fi
  local v_status v_wave v_harness v_depth v_reason v_updated v_created v_input v_idea v_gname v_att v_gid v_gstate v_gspec
  rawv status; v_status="$RV"; rawv wave; v_wave="$RV"; rawv harness; v_harness="$RV"; rawv depthlevel; v_depth="$RV"; rawv reason; v_reason="$RV"
  rawv updated; v_updated="$RV"; rawv created; v_created="$RV"; rawv input; v_input="$RV"; rawv idea; v_idea="$RV"; rawv gate_name; v_gname="$RV"
  rawv attempts; v_att="$RV"; rawv gate_id; v_gid="$RV"; rawv gate_state; v_gstate="$RV"; rawv gate_spec; v_gspec="$RV"
  pj '{"status":%q,"state":%s,"wave":%q,"scenario":%q,"harness":%q,"fasttrack":%s,"parallel":%s,"depthlevel":%q,"reason":%q,"updated":%q,"created":%q,"input":%q,"idea":%q,"currentSpec":%q,"gate_name":%q,"attempts":%q,"gate_id":%q,"gate_state":%q,"gate_spec":%q}' \
    "$v_status" "$nst" "$v_wave" "$SCEN" "$v_harness" "$f_b" "$p_b" "$v_depth" "$v_reason" "$v_updated" "$v_created" "$v_input" "$v_idea" "$cur" "$v_gname" "$v_att" "$v_gid" "$v_gstate" "$v_gspec"
}

# ---- events ---------------------------------------------------------------------------------
NOTES=""
note_add() { NOTES+="$1"$'\n'; }
# One awk reads the file (CRs dropped, blank lines skipped) and keeps the last MAX_EVENTS lines in a ring, then writes them out.
emit_events() {
  local bc="$REPO_ROOT/coordination/backchannel.jsonl"
  [[ -f "$bc" ]] || { note_add 'No coordination/backchannel.jsonl yet.'; return 0; }
  awk -v max="$MAX_EVENTS" '
    function esc(s) { gsub(/\\/, "\\\\", s); gsub(/"/, "\\\"", s); gsub(/\t/, "\\t", s); gsub(/[\001-\010\013\014\016-\037]/, "", s); return s }
    function str(h, keys,   n, k, re, a, i) {
      n = split(keys, k, "|")
      for (i = 1; i <= n; i++) { re = "\"" k[i] "\" *: *\"[^\"]*\""; if (match(h, re)) { a = substr(h, RSTART, RLENGTH); sub(/^[^:]*: *"/, "", a); sub(/"$/, "", a); return a } }
      return ""
    }
    { gsub(/\r/, "") }
    NF { ring[cnt % max] = $0; cnt++ }
    END {
      for (ii = (cnt > max ? cnt - max : 0); ii < cnt; ii++) {
        $0 = ring[ii % max]
        pi = index($0, "\"payload\"")
        head = (pi > 0) ? substr($0, 1, pi - 1) : $0
        raw = ""
        if (pi > 0) { rest = substr($0, pi); c = index(rest, ":"); raw = substr(rest, c + 1); sub(/^ +/, "", raw); sub(/\} *$/, "", raw) }
        printf "%s{\"id\":\"%s\",\"ts\":\"%s\",\"kind\":\"%s\",\"from\":\"%s\",\"to\":\"%s\",\"spec\":\"%s\",\"payload\":\"%s\"}", (n++ ? "," : ""), esc(str(head, "id")), esc(str(head, "ts|timestamp")), esc(str(head, "kind|event")), esc(str(head, "from|agent")), esc(str(head, "to")), esc(str(head, "spec")), esc(raw)
      }
    }' "$bc"
}
# A kcc lane (.kcc-lanes/SPEC-x) logs to its own coordination/backchannel.jsonl; the live sync copies those events into the
# workspace file only while `kcc run` is alive. Events of a lane that the workspace file does not hold (same ts, kind, spec)
# are listed here with the lane's name, so the lifecycle flowchart and the timeline see what the lane did.
# One awk per lane reads the workspace file first (the keys it holds), then the lane's file.
emit_lane_events() {
  local bc="$REPO_ROOT/coordination/backchannel.jsonl" lane lbc first=1 piece
  local -a args
  for lane in "$REPO_ROOT"/.kcc-lanes/*/ "$REPO_ROOT"/.worktrees/*/; do
    lane="${lane%/}"; lbc="$lane/coordination/backchannel.jsonl"
    [[ -f "$lbc" ]] || continue
    if [[ -f "$bc" ]]; then args=("$bc" "$lbc"); else args=("$lbc"); fi
    piece="$(awk -v lane="${lane##*/}" -v mainf="$bc" '
      function esc(s) { gsub(/\\/, "\\\\", s); gsub(/"/, "\\\"", s); gsub(/\t/, "\\t", s); gsub(/[\001-\010\013\014\016-\037]/, "", s); return s }
      function str(h, keys,   n, k, re, a, i) {
        n = split(keys, k, "|")
        for (i = 1; i <= n; i++) { re = "\"" k[i] "\" *: *\"[^\"]*\""; if (match(h, re)) { a = substr(h, RSTART, RLENGTH); sub(/^[^:]*: *"/, "", a); sub(/"$/, "", a); return a } }
        return ""
      }
      { gsub(/\r/, "") }
      FILENAME == mainf { if (NF) { t=""; k=""; s=""; h=$0; pi=index(h, "\"payload\""); if (pi > 0) h=substr(h, 1, pi - 1); if (match(h, /"ts" *: *"[^"]*"/)) t=substr(h, RSTART, RLENGTH); if (match(h, /"kind" *: *"[^"]*"/)) k=substr(h, RSTART, RLENGTH); if (match(h, /"spec" *: *"[^"]*"/)) s=substr(h, RSTART, RLENGTH); gsub(/ /, "", t); gsub(/ /, "", k); gsub(/ /, "", s); have[t "|" k "|" s] = 1 } next }
      NF {
        pi = index($0, "\"payload\"")
        head = (pi > 0) ? substr($0, 1, pi - 1) : $0
        raw = ""
        if (pi > 0) { rest = substr($0, pi); c = index(rest, ":"); raw = substr(rest, c + 1); sub(/^ +/, "", raw); sub(/\} *$/, "", raw) }
        ts = str(head, "ts|timestamp"); kd = str(head, "kind|event"); sp = str(head, "spec")
        key = "\"ts\":\"" ts "\"|\"kind\":\"" kd "\"|" (sp == "" ? "" : "\"spec\":\"" sp "\"")
        if (key in have) next
        printf "%s{\"id\":\"%s\",\"ts\":\"%s\",\"kind\":\"%s\",\"from\":\"%s\",\"to\":\"%s\",\"spec\":\"%s\",\"lane\":\"%s\",\"payload\":\"%s\"}", (n++ ? "," : ""), esc(str(head, "id")), esc(ts), esc(kd), esc(str(head, "from|agent")), esc(str(head, "to")), esc(sp), esc(lane), esc(raw)
      }' "${args[@]}")"
    [[ -n "$piece" ]] || continue
    [[ $first -eq 1 ]] || printf ','
    first=0
    printf '%s' "$piece"
  done
}

# ---- needs attention: coordination/NeedsAttention.md of the workspace and of each lane (the page parses the text) ---------
emit_needs_attention() {
  local root f first=1 txt n l
  for root in "$REPO_ROOT" "$REPO_ROOT"/.kcc-lanes/*/ "$REPO_ROOT"/.worktrees/*/; do
    root="${root%/}"; f="$root/coordination/NeedsAttention.md"
    [[ -f "$f" ]] || continue
    # the first 600 lines, CRs removed, trailing newlines dropped
    txt=""; n=0
    while [[ $n -lt 600 ]] && { IFS= read -r l || [[ -n "$l" ]]; }; do txt+="${l//$'\r'/}"$'\n'; n=$((n + 1)); done < "$f"
    while [[ "$txt" == *$'\n' ]]; do txt="${txt%$'\n'}"; done
    [[ $first -eq 1 ]] || printf ','
    first=0
    pj '{"file":%q,"text":%q}' "${f#"$REPO_ROOT"/}" "$txt"
  done
}

# ---- checkpoints -----------------------------------------------------------------------------------
emit_checkpoints() {
  local d="$REPO_ROOT/coordination/checkpoints" first=1 f id latest nm cr rs sp stg na gt pv lt
  [[ -d "$d" ]] || return 0
  rd "$d/latest.md"; fm_in points_to; latest="$FV"
  for f in "$d"/CP-*.md; do
    [[ -e "$f" ]] || continue
    rd "$f"
    fm_in id; id="$FV"; if [[ -z "$id" ]]; then nm="${f##*/}"; id="${nm%.md}"; fi
    fm_in created; cr="$FV"; fm_in reason; rs="$FV"; fm_in spec; sp="$FV"; fm_in stage; stg="$FV"
    fm_in next_action; na="$FV"; fm_in git_tag; gt="$FV"; fm_in previous; pv="$FV"
    if [[ "$id" == "$latest" ]]; then lt=true; else lt=false; fi
    [[ $first -eq 1 ]] || printf ','
    first=0
    pj '{"id":%q,"created":%q,"reason":%q,"spec":%q,"stage":%q,"next_action":%q,"git_tag":%q,"previous":%q,"latest":%s}' \
      "$id" "$cr" "$rs" "$sp" "$stg" "$na" "$gt" "$pv" "$lt"
  done
}

# ---- traces + decisions -----------------------------------------------------------------------------
decisions_json() { # session file -> comma-joined JSON objects
  awk -v session="$1" '
    function esc(s){gsub(/\\/,"\\\\",s);gsub(/"/,"\\\"",s);gsub(/\t/,"\\t",s);gsub(/\r/,"",s);gsub(/\n/,"\\n",s);return s}
    function flush(){ if(title!="" && title !~ /^<.*>$/){ printf "%s{\"session\":\"%s\",\"title\":\"%s\",\"when\":\"%s\",\"by\":\"%s\",\"context\":\"%s\",\"options\":\"%s\",\"decision\":\"%s\",\"rationale\":\"%s\",\"impact\":\"%s\",\"text\":\"%s\"}", (n++?",":""), esc(session),esc(title),esc(w),esc(by),esc(ctx),esc(opt),esc(dec),esc(rat),esc(imp),esc(text) } }
    /^##[ \t]+[0-9]+\.[ \t]+/ { flush(); title=$0; sub(/^##[ \t]+[0-9]+\.[ \t]+/,"",title); sub(/\r$/,"",title); w="";by="";ctx="";opt="";dec="";rat="";imp=""; text=title "\n"; next }
    /^##[ \t]/ { flush(); title=""; next }
    title!="" { text=text $0 "\n"
      if (match($0,/^[ \t]*[-*][ \t]*\*\*[^*]+\*\*/)) { lab=substr($0,RSTART,RLENGTH); val=substr($0,RSTART+RLENGTH); gsub(/^[ \t]*[-*][ \t]*\*\*|\*\*$/,"",lab); gsub(/:/,"",lab); lab=tolower(lab); sub(/^:?[ \t]*/,"",val); sub(/\r$/,"",val); gsub(/\[\[[^]|]*\|/,"",val); gsub(/\[\[|\]\]/,"",val)
        if(lab=="when") w=val; else if(lab=="by") by=val; else if(lab=="context" || lab ~ /^question/) ctx=val; else if(lab ~ /^options/) opt=val
        else if(lab=="decision" || lab=="human decision") dec=val; else if(lab ~ /^rationale/) rat=val; else if(lab=="impact") imp=val } }
    END{ flush() }' "$2"
}
DEC_JSON=""
HDEC_JSON=""
# trace_body FILE -> BODY, TRUNC: the first MAX_TRACE_CHARS bytes with invalid UTF-8 dropped (head -c | iconv -c), and whether the file is longer.
# A pure-ASCII file (the usual case) is read by the builtin; anything else takes the original pipeline.
trace_body() {
  BODY=""; TRUNC=false
  local more="" rc=0 LC_ALL=C   # bytes, so -N and the high-byte test mean what head -c and iconv do
  if [[ "${BASH_VERSINFO[0]}" -gt 4 || ( "${BASH_VERSINFO[0]}" -eq 4 && "${BASH_VERSINFO[1]}" -ge 1 ) ]]; then
    exec 8< "$1"
    IFS= read -r -d '' -N "$MAX_TRACE_CHARS" -u 8 BODY || rc=$?
    if [[ $rc -eq 0 ]]; then IFS= read -r -d '' -N 1 -u 8 more && TRUNC=true; fi
    exec 8<&-
    if [[ "$BODY" != *[$'\200'-$'\377']* ]]; then
      while [[ "$BODY" == *$'\n' ]]; do BODY="${BODY%$'\n'}"; done
      return 0
    fi
    TRUNC=false
  fi
  BODY="$(head -c "$MAX_TRACE_CHARS" "$1" | { iconv -f utf-8 -t utf-8 -c 2>/dev/null || cat; })"
  if [[ "$(wc -c < "$1" | tr -d ' ')" -gt "$MAX_TRACE_CHARS" ]]; then TRUNC=true; fi
}
emit_sessions() {
  local td="$REPO_ROOT/Traces" first=1 sess n f p present lines trunc body firstf piece sp ln
  if [[ ! -d "$td" ]]; then note_add 'No Traces/ folder yet (fast-track runs do not write traces).'; return 0; fi
  for sp in "$td"/Session-*; do
    [[ -e "$sp" ]] || continue
    sess="${sp##*/}"
    [[ -d "$td/$sess" ]] || continue
    [[ $first -eq 1 ]] || printf ','
    first=0
    pj '{"name":%q,"files":[' "$sess"
    firstf=1
    for n in Decisions HumanDecisions Actions Handovers ToolsUsed HumanActions TokenUsage; do
      f="$td/$sess/$n.md"
      present=false; lines=0; trunc=false; body=""
      if [[ -f "$f" ]]; then
        present=true
        while IFS= read -r ln || [[ -n "$ln" ]]; do lines=$((lines + 1)); done < "$f"
        trace_body "$f"; body="$BODY"; trunc="$TRUNC"
        if [[ "$n" == "Decisions" ]]; then piece="$(decisions_json "$sess" "$f")"; if [[ -n "$piece" ]]; then if [[ -n "$DEC_JSON" ]]; then DEC_JSON+=","; fi; DEC_JSON+="$piece"; fi; fi
        if [[ "$n" == "HumanDecisions" ]]; then piece="$(decisions_json "$sess" "$f")"; if [[ -n "$piece" ]]; then if [[ -n "$HDEC_JSON" ]]; then HDEC_JSON+=","; fi; HDEC_JSON+="$piece"; fi; fi
      fi
      [[ $firstf -eq 1 ]] || printf ','
      firstf=0
      pj '{"name":%q,"present":%s,"lines":%s,"truncated":%s,"text":%q}' "$n" "$present" "$lines" "$trunc" "$body"
    done
    printf ']}'
  done
}
emit_profiles() {
  local d="$REPO_ROOT/.claude/agents" first=1 f nm m e
  [[ -d "$d" ]] || return 0
  for f in "$d"/*.md; do
    [[ -e "$f" ]] || continue
    rd "$f"
    fm_in name; nm="$FV"; if [[ -z "$nm" ]]; then nm="${f##*/}"; nm="${nm%.md}"; fi
    fm_in model; m="$FV"; fm_in effort; e="$FV"
    [[ $first -eq 1 ]] || printf ','
    first=0
    pj '{"name":%q,"model":%q,"effort":%q}' "$nm" "$m" "$e"
  done
}

# ---- agent history (Claude Code transcripts) --------------------------------------------------
# One headless session per kcc-run state, plus one transcript per subagent, under
# ~/.claude/projects/<workspace path with non-alphanumerics replaced by '-'>/ (CLAUDE_CONFIG_DIR is honoured).
# Each transcript is summarised once (awk) and cached under dashboard/.agent-cache until it changes,
# so refreshing after every event stays cheap; one final awk pass writes the JSON.
MAX_SESSIONS=80
CYGW=""
claude_project_dir() { # [root] -> CPD (and stdout): the Claude project folder of the workspace, or of a lane when given
  local base="${CLAUDE_CONFIG_DIR:-}" p
  if [[ -z "$base" ]]; then base="${HOME:-}/.claude"; fi
  p="${1:-$REPO_ROOT}"
  if command -v cygpath >/dev/null 2>&1; then
    if [[ -z "$CYGW" ]]; then CYGW="$(cygpath -w "$REPO_ROOT" 2>/dev/null || printf '%s' "$REPO_ROOT")"; fi
    p="$CYGW"
  fi
  CPD="$base/projects/${p//[^A-Za-z0-9]/-}"
}
# transcript_summary FILE -> TSV: first, last, effort, label, cost, durationMs, models (model|in|out|cacheRead|cacheWrite|messages;...), topModel
transcript_summary() {
  awk '
    function epoch(t,   y,m,d,H,M,S,ms,days,era,yoe,doy,doe,yy,mm) {
      if (t == "") return 0
      y = substr(t,1,4)+0; m = substr(t,6,2)+0; d = substr(t,9,2)+0; H = substr(t,12,2)+0; M = substr(t,15,2)+0; S = substr(t,18,2)+0
      ms = 0; if (substr(t,20,1) == ".") ms = substr(t,21,3)+0
      yy = (m <= 2) ? y - 1 : y; mm = (m > 2) ? m - 3 : m + 9
      era = int(yy / 400); yoe = yy - era * 400; doy = int((153 * mm + 2) / 5) + d - 1; doe = yoe * 365 + int(yoe / 4) - int(yoe / 100) + doy
      days = era * 146097 + doe - 719468
      return ((days * 86400) + H * 3600 + M * 60 + S) * 1000 + ms
    }
    function field(line, key,   re, s) { re = "\"" key "\":[0-9]+"; if (match(line, re)) { s = substr(line, RSTART, RLENGTH); sub(/^[^:]*:/, "", s); return s + 0 } return 0 }
    {
      if (match($0, /"timestamp":"[^"]+"/)) { ts = substr($0, RSTART + 13, RLENGTH - 14); if (first == "") first = ts; last = ts }
      if (match($0, /"effort":"[a-z]+"/)) { e = substr($0, RSTART + 10, RLENGTH - 11); ec[e]++ }
      if (label == "" && nl < 60) { nl++; if (match($0, /KCC run state [0-9]+ [A-Z0-9-]+( for SPEC-[0-9A-Za-z]+)?( wave [0-9]+)?/)) { label = substr($0, RSTART, RLENGTH); if (match($0, /You are the [a-z][a-z0-9-]* agent running this state directly/)) { direct = substr($0, RSTART + 12, RLENGTH - 12); sub(/ agent running.*$/, "", direct) } } }
      if (index($0, "\"type\":\"assistant\"") && index($0, "\"usage\"")) {
        id = ""; if (match($0, /"id":"msg_[A-Za-z0-9_]+"/)) id = substr($0, RSTART + 6, RLENGTH - 7)
        if (id == "") id = "line" NR
        mo = "unknown"; if (match($0, /"model":"[^"]+"/)) mo = substr($0, RSTART + 9, RLENGTH - 10)
        u = substr($0, index($0, "\"usage\""))
        M[id] = mo; I[id] = field(u, "input_tokens"); O[id] = field(u, "output_tokens"); CR[id] = field(u, "cache_read_input_tokens"); CW[id] = field(u, "cache_creation_input_tokens")
      } else if (index($0, "\"type\":\"cost-state\"")) {
        if (match($0, /"totalCostUSD":[0-9.eE+-]+/)) { cost = substr($0, RSTART + 15, RLENGTH - 15) }
      }
    }
    END {
      for (id in M) { m = M[id]; if (!(m in seen)) { seen[m] = 1; order[++n] = m } ti[m] += I[id]; to[m] += O[id]; tr[m] += CR[id]; tw[m] += CW[id]; tc[m]++ }
      best = ""; bo = -1; for (i = 1; i <= n; i++) if (to[order[i]] > bo) { bo = to[order[i]]; best = order[i] }
      eff = ""; bc = 0; for (k in ec) if (ec[k] > bc) { bc = ec[k]; eff = k }
      ms = ""; for (i = 1; i <= n; i++) { m = order[i]; ms = ms (i > 1 ? ";" : "") m "|" ti[m] "|" to[m] "|" tr[m] "|" tw[m] "|" tc[m] }
      dur = (first != "" && last != "") ? epoch(last) - epoch(first) : 0
      printf "%s\t%s\t%s\t%s\t%s\t%d\t%s\t%s\t%s\n", first, last, eff, label, cost, dur, ms, best, direct
    }' "$1"
}
# cached_summary SOURCE_FILE CACHE_KEY -> the summary TSV (recomputed only when the transcript is newer than the cache)
cached_summary() {
  local src="$1" key="$2" cdir="$REPO_ROOT/dashboard/.agent-cache" cf
  cf="$cdir/$key.tsv"
  if [[ -f "$cf" && ! "$src" -nt "$cf" ]]; then cat "$cf"; return 0; fi
  mkdir -p "$cdir"
  transcript_summary "$src" | tee "$cf.tmp" && mv -f "$cf.tmp" "$cf"
}
emit_agents() {
  local pd sf sid sum label jf meta atype adesc pe pm AG_TSV="" ln sd key sessions lane dirs=()
  # A lane (.kcc-lanes/SPEC-x, .worktrees/SPEC-x) runs its sessions with the lane as the working folder, so its
  # transcripts live under the lane's own project folder.
  claude_project_dir; pd="$CPD"; if [[ -d "$pd" ]]; then dirs+=("$pd"); fi
  for lane in "$REPO_ROOT"/.kcc-lanes/*/ "$REPO_ROOT"/.worktrees/*/; do
    [[ -d "$lane" ]] || continue
    claude_project_dir "${lane%/}"; pd="$CPD"; if [[ -d "$pd" ]]; then dirs+=("$pd"); fi
  done
  [[ ${#dirs[@]} -gt 0 ]] || return 0
  sessions="$(for pd in "${dirs[@]}"; do ls -1 "$pd"/*.jsonl 2>/dev/null; done | while IFS= read -r one; do printf '%s %s\n' "$(stat -c %Y "$one" 2>/dev/null || stat -f %m "$one" 2>/dev/null || echo 0)" "$one"; done | sort -rn | head -n "$MAX_SESSIONS" | cut -d' ' -f2- || true)"
  while IFS= read -r sf; do
    [[ -n "$sf" ]] || continue
    sid="$(basename "$sf" .jsonl)"
    sum="$(cached_summary "$sf" "$sid")"
    [[ -n "$(printf '%s' "$sum" | cut -f1)" ]] || continue
    label="$(printf '%s' "$sum" | cut -f4)"
    printf -v ln 'session\t%s\t\tmain session\t%s\t%s\t\t\t%s\n' "$sid" "$label" "$label" "$sum"; AG_TSV+="$ln"
    sd="$(dirname "$sf")/$sid/subagents"
    if [[ -d "$sd" ]]; then
      for jf in $(ls -1 "$sd"/agent-*.jsonl 2>/dev/null | LC_ALL=C sort); do
        meta="${jf%.jsonl}.meta.json"; atype=""; adesc=""
        if [[ -f "$meta" ]]; then
          atype="$(sed -nE 's/.*"agentType" *: *"([^"]*)".*/\1/p' "$meta" | head -n 1)"
          adesc="$(sed -nE 's/.*"description" *: *"(([^"\\]|\\.)*)".*/\1/p' "$meta" | head -n 1 | sed -e 's/\\"/"/g' -e 's/\\\\/\\/g' | tr '\t' ' ')"
        fi
        [[ -n "$atype" ]] || atype="subagent"
        sum="$(cached_summary "$jf" "$sid--$(basename "$jf" .jsonl)")"
        [[ -n "$(printf '%s' "$sum" | cut -f1)" ]] || continue
        pe=""; pm=""
        if [[ -f "$REPO_ROOT/.claude/agents/$atype.md" ]]; then rd "$REPO_ROOT/.claude/agents/$atype.md"; fm_in effort; pe="$FV"; fm_in model; pm="$FV"; fi
        printf -v ln 'subagent\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$sid/$(basename "$jf" .jsonl)" "$sid" "$atype" "$adesc" "$label" "$pe" "$pm" "$sum"; AG_TSV+="$ln"
      done
    fi
  done <<EOF
$sessions
EOF
  printf '%s' "$AG_TSV" | awk -F'\t' '
    function esc(s) { gsub(/\\/, "\\\\", s); gsub(/"/, "\\\"", s); gsub(/\r/, "", s); gsub(/[\001-\010\013\014\016-\037]/, "", s); return s }
    {
      kind = $1; id = $2; parent = $3; agent = $4; desc = $5; label = $6; peffort = $7; pmodel = $8
      first = $9; last = $10; eff = $11; lab = $12; cost = $13; dur = $14; models = $15; best = $16; direct = $17
      mode = (kind == "subagent") ? "subagent" : ((direct != "") ? "direct" : "orchestrator")
      if (kind == "session" && direct != "") agent = direct
      state = ""; sname = ""; spec = ""; wave = ""
      if (label != "") {
        if (match(label, /state [0-9]+/)) state = substr(label, RSTART + 6, RLENGTH - 6)
        if (match(label, /state [0-9]+ [A-Z0-9-]+/)) { t = substr(label, RSTART, RLENGTH); sub(/^state [0-9]+ /, "", t); sname = t }
        if (match(label, /SPEC-[0-9A-Za-z]+/)) spec = substr(label, RSTART, RLENGTH)
        if (match(label, /wave [0-9]+/)) wave = substr(label, RSTART + 5, RLENGTH - 5)
      }
      if (spec == "" && match(desc, /SPEC-[0-9A-Za-z]+/)) spec = substr(desc, RSTART, RLENGTH)
      effsrc = (eff != "") ? "transcript" : ""
      if (peffort != "") { eff = peffort; effsrc = "profile" }
      n = split(models, ML, ";"); tin = 0; tout = 0; tcr = 0; tcw = 0; mj = ""
      for (i = 1; i <= n; i++) {
        split(ML[i], P, "|"); tin += P[2]; tout += P[3]; tcr += P[4]; tcw += P[5]
        mj = mj (i > 1 ? "," : "") "\"" esc(P[1]) "\":{\"input\":" P[2] ",\"output\":" P[3] ",\"cacheRead\":" P[4] ",\"cacheWrite\":" P[5] ",\"messages\":" P[6] "}"
      }
      printf "%s{\"id\":\"%s\",\"kind\":\"%s\",\"parent\":\"%s\",\"agent\":\"%s\",\"description\":\"%s\",\"state\":\"%s\",\"stateName\":\"%s\",\"spec\":\"%s\",\"wave\":\"%s\",\"started\":\"%s\",\"ended\":\"%s\",\"durationMs\":%d,\"model\":\"%s\",\"effort\":\"%s\",\"effortSource\":\"%s\",\"mode\":\"%s\",", \
        (c++ ? "," : ""), esc(id), kind, esc(parent), esc(agent), esc(desc), state, sname, spec, wave, first, last, dur, esc(best), esc(eff), effsrc, mode
      if (pmodel != "") printf "\"profileModel\":\"%s\",", esc(pmodel)
      printf "\"tokens\":{\"input\":%d,\"output\":%d,\"cacheRead\":%d,\"cacheWrite\":%d},\"models\":{%s},\"costUSD\":%s}", tin, tout, tcr, tcw, mj, (cost == "" ? "null" : cost)
    }'
}


# ---- stage timing: one row per harness dispatch (coordination/run/logs/state-*.log) -------------------
# The log header carries the start time; the last write is the end (the harness writes at exit).
mtime_iso() { # file -> ISO UTC of its last write (GNU stat, then BSD stat)
  local e; e="$(stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || echo 0)"
  date -u -d "@$e" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -r "$e" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo ""
}
emit_runlogs() {
  local d f base first=1 spec started root rel i
  local re_log='^state-([0-9]+)-(run|SPEC-[0-9A-Za-z]+)(-w([0-9]+))?-([0-9]+|install)\.log$' re_start='^# kcc-run ([^ ]+)' re_ag='--agent ([^ ]+)' re_mo='--model ([^ ]+)' re_ef='--effort ([^ ]+)'
  local -a files epochs
  for root in "$REPO_ROOT" "$REPO_ROOT"/.kcc-lanes/*/ "$REPO_ROOT"/.worktrees/*/; do
  root="${root%/}"; [[ -d "$root" ]] || continue
  d="$root/coordination/run/logs"
  [[ -d "$d" ]] || continue
  rel=""; if [[ "$root" != "$REPO_ROOT" ]]; then rel="${root#"$REPO_ROOT"/}/"; fi
  # the logs oldest first (one ls), their last-write times (one stat for all of them)
  files=(); epochs=()
  while IFS= read -r f; do files[${#files[@]}]="$f"; done < <(ls -1tr "$d"/state-*.log 2>/dev/null)
  if [[ ${#files[@]} -gt 0 ]]; then
    i=0
    while IFS= read -r f; do
      if [[ "$f" == *" ${files[i]}" ]]; then epochs[i]="${f%% *}"; fi
      i=$((i + 1))
    done < <(stat -c '%Y %n' "${files[@]}" 2>/dev/null)
  fi
  i=-1
  for f in ${files[@]+"${files[@]}"}; do
    i=$((i + 1))
    base="${f##*/}"
    [[ "$base" =~ $re_log ]] || continue
    spec="${BASH_REMATCH[2]}"; if [[ "$spec" == "run" ]]; then spec=""; fi
    local hdr2 lag lmo lef rs1 rs4 rs5 l1 l2 ended
    rs1="${BASH_REMATCH[1]}"; rs4="${BASH_REMATCH[4]:-}"; rs5="${BASH_REMATCH[5]}"
    l1=""; l2=""
    { IFS= read -r l1 || true; IFS= read -r l2 || true; } < "$f"
    started=""; if [[ "$l1" =~ $re_start ]]; then started="${BASH_REMATCH[1]}"; fi
    # line 2 of the log is the harness command: it names the agent, model and effort of this dispatch
    hdr2="${l2:0:600}"
    lag=""; if [[ "$hdr2" =~ $re_ag ]]; then lag="${BASH_REMATCH[1]}"; fi
    lmo=""; if [[ "$hdr2" =~ $re_mo ]]; then lmo="${BASH_REMATCH[1]}"; fi
    lef=""; if [[ "$hdr2" =~ $re_ef ]]; then lef="${BASH_REMATCH[1]}"; fi
    if [[ -n "${epochs[i]-}" ]]; then epoch_iso "${epochs[i]}"; ended="$EI"; else ended="$(mtime_iso "$f")"; fi
    [[ $first -eq 1 ]] || printf ','
    first=0
    pj '{"state":%s,"spec":%q,"wave":%q,"attempt":%q,"started":%q,"ended":%q,"file":%q,"agent":%q,"model":%q,"effort":%q}' "$rs1" "$spec" "$rs4" "$rs5" "$started" "$ended" "${rel}coordination/run/logs/$base" "$lag" "$lmo" "$lef"
  done
  done
}

# ---- assemble ----------------------------------------------------------------------------------------------
TPL="$REPO_ROOT/.KCC/kernel/templates/dashboard.html"
[[ -z "$TEMPLATE" ]] || TPL="$TEMPLATE"
[[ -f "$TPL" ]] || TPL="${SCRIPT_DIR%/*}/kernel/templates/dashboard.html"
[[ -f "$TPL" ]] || { echo "dashboard template not found: $TPL" >&2; exit 2; }
OUT_DIR="$REPO_ROOT/dashboard"; OUT_FILE="$OUT_DIR/index.html"

collect_specs
[[ -d "$REPO_ROOT/specs" ]] || note_add 'No specs/ folder yet.'
[[ -d "$REPO_ROOT/ideation" ]] || note_add 'No ideation/ folder yet.'
MEM_TOTAL=0
if [[ -f "$REPO_ROOT/memory/index.json" ]]; then
  mem_txt="$(<"$REPO_ROOT/memory/index.json")"; re_mid='"id" *:'
  while [[ "$mem_txt" =~ $re_mid ]]; do MEM_TOTAL=$((MEM_TOTAL + 1)); mem_txt="${mem_txt#*"${BASH_REMATCH[0]}"}"; done
fi

[[ -d "$OUT_DIR" ]] || mkdir -p "$OUT_DIR"
# The data is one JSON document written to a pipe; one awk puts it into the template (every "</" becomes "<\/", the lines of the
# document are joined) and writes the page. No temporary folder, no sed, no second pass over the file.
{
  pj '{"schema":2,"generatedAt":%q,"repoRoot":%q,"project":%q,"run":' "$NOW" "$REPO_ROOT" "$PROJECT"
  emit_run
  printf ',"states":['; emit_states; printf ']'
  printf ',"ideas":['; emit_ideas; printf ']'
  printf ',"specs":[%s]' "$SPECS_JSON"
  printf ',"roadmaps":[%s]' "$ROADMAPS_JSON"
  numv "$STATES_MAXATT"; printf ',"maxAttempts":%s' "$NV"
  printf ',"events":['; emit_events; printf ']'
  printf ',"laneEvents":['; emit_lane_events; printf ']'
  printf ',"needsAttention":['; emit_needs_attention; printf ']'
  printf ',"checkpoints":['; emit_checkpoints; printf ']'
  printf ',"sessions":['; emit_sessions; printf ']'
  printf ',"decisions":[%s]' "$DEC_JSON"
  printf ',"humanDecisions":[%s]' "$HDEC_JSON"
  printf ',"adrs":['; emit_adrs; printf ']'
  printf ',"agents":['; emit_agents; printf ']'
  printf ',"lanes":['; emit_lanes; printf ']'
  printf ',"profiles":['; emit_profiles; printf ']'
  printf ',"runLogs":['; emit_runlogs; printf ']'
  printf ',"memory":{"total":%s,"byType":{}}' "$MEM_TOTAL"
  printf ',"notes":['
  nfirst=1
  while IFS= read -r nl; do
    [[ "$nl" == *[![:space:]]* ]] || continue
    nl="${nl//\\/\\\\}"; nl="${nl//\"/\\\"}"
    if [[ $nfirst -eq 1 ]]; then nfirst=0; else printf ','; fi
    printf '"%s"' "$nl"
  done <<< "$NOTES"
  printf ']}'
  printf '\n__KCC_END__\n'
} | KCC_DASH_OUT="$OUT_FILE" awk '
  BEGIN {
    while ((getline l < "/dev/stdin") > 0) {
      if (l == "__KCC_END__") { ok = 1; break }
      while ((p = index(l, "</")) > 0) { json = json substr(l, 1, p - 1) "<\\/"; l = substr(l, p + 2) }
      json = json l
    }
    if (!ok) exit 2
  }
  { buf[++nb] = $0 }
  END {
    # the page is written only when the data was collected to its end: a failure leaves the previous page as it was
    if (!ok) exit 2
    out = ENVIRON["KCC_DASH_OUT"]
    for (k = 1; k <= nb; k++) {
      line = buf[k]; i = index(line, "__KCC_DATA__")
      if (i > 0) { printf "%s", substr(line, 1, i - 1) > out; printf "%s", json > out; print substr(line, i + 12) > out } else print line > out
    }
    close(out)
  }' "$TPL"

echo "Dashboard written to $OUT_FILE"
echo "  specs/events/sessions collected; open it in a browser (works offline)"
# A lane (<root>/.kcc-lanes/SPEC-x) builds its own page, but the page people look at is the workspace's. Rebuild that one
# too, so lane activity reaches it even when the scheduler that normally refreshes it is not running.
if [[ "${KCC_DASH_PARENT:-}" != "1" ]]; then
  lane_norm="${REPO_ROOT//\\//}"
  lane_norm="${lane_norm%/}"
  if [[ "$lane_norm" =~ /\.kcc-lanes/[^/]+$ ]]; then
    parent_root="${REPO_ROOT%/*}"; parent_root="${parent_root%/*}"
    if [[ -f "$parent_root/coordination/lanes.json" && -f "$parent_root/.KCC/tools/build-dashboard.sh" ]]; then
      KCC_DASH_PARENT=1 bash "$parent_root/.KCC/tools/build-dashboard.sh" --repo-root "$parent_root" >/dev/null 2>&1 || true
    fi
  fi
fi
if [[ "$OPEN" -eq 1 ]]; then
  # KCC_DASHBOARD_URL: `kcc run` serves a live page; open that instead of the file so the page stays current.
  OPEN_TARGET="${KCC_DASHBOARD_URL:-$OUT_FILE}"
  if [[ -n "${KCC_OPEN_LOG:-}" ]]; then printf '%s\n' "$OPEN_TARGET" >> "$KCC_OPEN_LOG"   # automation hook: record instead of launching
  elif command -v xdg-open >/dev/null 2>&1; then xdg-open "$OPEN_TARGET" >/dev/null 2>&1 &
  elif command -v open >/dev/null 2>&1; then open "$OPEN_TARGET" >/dev/null 2>&1 &
  else echo "Open not supported on this host; file is at $OUT_FILE"; fi
fi
