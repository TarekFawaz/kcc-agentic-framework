#!/usr/bin/env bash
# KCC framework (c) 2026 Tarek Fawaz, https://tikasway.dev/kcc. Licensed under the terms in LICENSE.
# KCC native bash dashboard generator (macOS/Linux). Mirror of build-dashboard.ps1: it collects the same
# data (roadmaps, specs, bugs, backchannel, checkpoints, traces, run state) as one JSON block and fills
# .KCC/kernel/templates/dashboard.html. Offline output: dashboard/index.html. Needs bash 3.2+, awk, sed, grep.
set -eu   # no pipefail: grep exiting 1 on "no match" inside pipelines is normal here

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
OPEN=0
TEMPLATE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo-root|-RepoRoot) REPO_ROOT="$(cd "$2" && pwd)"; shift 2 ;;
    --open|-Open) OPEN=1; shift ;;
    --template|-Template) TEMPLATE="$2"; shift 2 ;;
    *) echo "error: unknown argument: $1" >&2; exit 2 ;;
  esac
done

MAX_TRACE_CHARS=24000
MAX_EVENTS=4000
TMP="$(mktemp -d 2>/dev/null || mktemp -d -t kccdash)"
trap 'rm -rf "$TMP"' EXIT

# ---- helpers --------------------------------------------------------------
# JSON-escape stdin (no trailing newline).
jstr() { tr -d '\000-\010\013\014\016-\037' | awk 'BEGIN{ORS=""} {gsub(/\\/,"\\\\"); gsub(/"/,"\\\""); gsub(/\t/,"\\t"); gsub(/\r/,""); print sep $0; sep="\\n"}'; }
q() { printf '"'; printf '%s' "$1" | jstr; printf '"'; }
bool() { if [[ "$1" == "1" ]]; then printf 'true'; else printf 'false'; fi; }
num() { if [[ "$1" =~ ^-?[0-9]+$ ]]; then printf '%s' "$1"; else printf '0'; fi; }

fm_get() { # file key -> first frontmatter value
  [[ -f "$1" ]] || return 0
  awk -v k="$2" '{sub(/\r$/,"")} NR==1&&/^---[ \t]*$/{fm=1;next} fm&&/^---/{exit} fm{ if(match($0,"^" k "[ \t]*:[ \t]*")){v=substr($0,RLENGTH+1); sub(/[ \t]+$/,"",v); gsub(/^["\047]|["\047]$/,"",v); print v; exit} }' "$1"
}
h1() { [[ -f "$1" ]] && awk '{sub(/\r$/,"")} /^# /{sub(/^# +/,""); print; exit}' "$1" || true; }
section() { # file heading-regex -> body lines of that section
  [[ -f "$1" ]] || return 0
  awk -v pat="$2" '{sub(/\r$/,"")} match($0,/^#+ /){lvl=RLENGTH-1; t=substr($0,RLENGTH+1); if(ins&&lvl<=L)exit; if(!ins&&tolower(t) ~ tolower(pat)){ins=1;L=lvl;next}} ins{print}' "$1"
}
table_tsv() { # cols (comma list of lowercase header names, #1 = first column); stdin lines -> TSV rows of the first table
  awk -v want="$1" 'BEGIN{n=split(want,W,",")} {sub(/\r$/,"")}
    /^[ \t]*\|/ { if(done)next; line=$0; sub(/^[ \t]*\|/,"",line); sub(/\|[ \t]*$/,"",line); m=split(line,C,"|");
      if(!hdr){ for(i=1;i<=m;i++){h=tolower(C[i]); gsub(/^[ \t*]+|[ \t*]+$/,"",h); H[i]=h} hdr=1; hm=m; next }
      if(line ~ /^[ \t:|-]+$/) next
      out=""; for(j=1;j<=n;j++){ v=""; for(i=1;i<=hm;i++) if(H[i]==W[j] || (W[j]=="#1" && i==1)) {v=C[i]; gsub(/^[ \t]+|[ \t]+$/,"",v); gsub(/\[\[[^]|]*\|/,"",v); gsub(/\[\[|\]\]/,"",v); gsub(/\*\*/,"",v)} out=out (j>1?"\t":"") v }
      print out; next }
    { if(hdr) done=1 }'
}
ac_tsv() { # stdin section lines -> done<TAB>id<TAB>text
  awk '{sub(/\r$/,"")} match($0,/^[ \t]*[-*][ \t]*\[[ xX]\][ \t]*AC-[0-9]+/){head=substr($0,RSTART,RLENGTH); rest=substr($0,RLENGTH+1); d=(head ~ /\[[xX]\]/)?"1":"0"; match(head,/AC-[0-9]+/); id=substr(head,RSTART,RLENGTH); sub(/^[ \t]*[-:][ \t]*/,"",rest); gsub(/\[\[[^]|]*\|/,"",rest); gsub(/\[\[|\]\]/,"",rest); print d "\t" id "\t" rest}'
}
count_lines() { [[ -f "$1" ]] && awk 'END{print NR}' "$1" || echo 0; }
rawval() { # file key -> raw string value of "key":"value" (first match)
  [[ -f "$1" ]] || return 0
  tr -d '\r' < "$1" | sed -nE "s/.*\"$2\"[[:space:]]*:[[:space:]]*\"(([^\"\\\\]|\\\\.)*)\".*/\1/p" | head -n 1 | sed -e 's/\\"/"/g' -e 's/\\\\/\\/g'
}
is_sorted_list() { ls -1 "$1" 2>/dev/null | LC_ALL=C sort || true; }

NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
PROJECT="$(basename "$REPO_ROOT")"

# ---- run + states ------------------------------------------------------------
RUN_FILE="$REPO_ROOT/coordination/run/run.json"
FAST=0; PAR=0; SCEN=""
if [[ -f "$RUN_FILE" ]]; then
  [[ "$(rawval "$RUN_FILE" fasttrack)" == "1" ]] && FAST=1
  [[ "$(rawval "$RUN_FILE" parallel)" == "1" ]] && PAR=1
  # a chat orchestrator writes the flags as a list: "flags":["--fasttrack"]
  grep -q -- '--fasttrack' "$RUN_FILE" && FAST=1
  grep -q -- '--parallel' "$RUN_FILE" && PAR=1
fi
# A chat run may have no run.json at all: its policy is in the first auto-policy-parsed event.
if [[ -f "$REPO_ROOT/coordination/backchannel.jsonl" ]]; then
  pol="$(grep -m1 -E '"kind"[[:space:]]*:[[:space:]]*"auto-policy-parsed"' "$REPO_ROOT/coordination/backchannel.jsonl" || true)"
  if printf '%s' "$pol" | grep -qE -- '--fasttrack|"fasttrack"[[:space:]]*:[[:space:]]*(true|"1")'; then FAST=1; fi
  if printf '%s' "$pol" | grep -qE -- '--parallel|"parallel"[[:space:]]*:[[:space:]]*(true|"1")'; then PAR=1; fi
  SCEN="$(rawval "$RUN_FILE" scenario)"
fi

emit_states() {
  local f="$REPO_ROOT/.KCC/kernel/auto-states.json" first=1 rec id name scope skipped skipv onlyv
  [[ $FAST -eq 1 && -f "$REPO_ROOT/.KCC/kernel/auto-states-fasttrack.json" ]] && f="$REPO_ROOT/.KCC/kernel/auto-states-fasttrack.json"
  [[ -f "$f" ]] || return 0
  tr -d '\r\n' < "$f" | sed 's/{ *"id"/\n{ "id"/g' | grep -E '^\{ *"id"' | while IFS= read -r rec; do
    id="$(printf '%s' "$rec" | sed -nE 's/^\{ *"id" *: *([0-9]+).*/\1/p')"
    name="$(printf '%s' "$rec" | sed -nE 's/.*"name" *: *"([^"]*)".*/\1/p')"
    scope="$(printf '%s' "$rec" | sed -nE 's/.*"scope" *: *"([^"]*)".*/\1/p')"
    skipped=0
    skipv="$(printf '%s' "$rec" | sed -nE 's/.*"skip_if_flag" *: *(\[[^]]*\]|"[^"]*").*/\1/p')"
    if [[ -n "$skipv" ]]; then
      [[ "$skipv" == *fasttrack* && $FAST -eq 1 ]] && skipped=1
      [[ "$skipv" == *parallel* && $PAR -eq 1 ]] && skipped=1
    fi
    onlyv="$(printf '%s' "$rec" | sed -nE 's/.*"only_in" *: *(\[[^]]*\]).*/\1/p')"
    if [[ -n "$onlyv" && -n "$SCEN" && "$onlyv" != *"\"$SCEN\""* ]]; then skipped=1; fi
    [[ $first -eq 1 ]] || printf ','
    first=0
    printf '{"id":%s,"name":%s,"scope":%s,"skipped":%s}' "$(num "$id")" "$(q "$name")" "$(q "$scope")" "$(bool $skipped)"
  done
}

# ---- ideas ---------------------------------------------------------------------
emit_ideas() {
  local d="$REPO_ROOT/ideation" first=1 folder f idea title files st id
  [[ -d "$d" ]] || return 0
  for folder in $(is_sorted_list "$d" | grep -E '^IDEA-' || true); do
    f="$(ls -1 "$d/$folder"/idea-*.md 2>/dev/null | head -n 1 || true)"
    id="$(printf '%s' "$folder" | grep -oE '^IDEA-[0-9]+' || true)"
    title=""; st=""
    if [[ -n "$f" ]]; then title="$(fm_get "$f" title)"; [[ -n "$title" ]] || title="$(h1 "$f")"; st="$(fm_get "$f" status)"; fi
    files="$(ls -1 "$d/$folder"/*.md 2>/dev/null | while IFS= read -r x; do printf '%s\n' "$(basename "$x")"; done || true)"
    [[ $first -eq 1 ]] || printf ','
    first=0
    printf '{"id":%s,"folder":%s,"title":%s,"slug":%s,"status":%s,"files":[' "$(q "$id")" "$(q "$folder")" "$(q "$title")" "$(q "$([[ -n "$f" ]] && fm_get "$f" slug || true)")" "$(q "$st")"
    printf '%s' "$files" | awk 'NF{printf "%s\"%s\"", (n++?",":""), $0}'
    printf ']}'
  done
}

# ---- ADRs ------------------------------------------------------------------------
emit_adrs() {
  local d="$REPO_ROOT/architecture/adrs" first=1 f id title st
  [[ -d "$d" ]] || return 0
  for f in $(ls -1 "$d"/ADR-*.md 2>/dev/null | LC_ALL=C sort); do
    id="$(basename "$f" | grep -oE '^ADR-[0-9]+' || true)"
    title="$(h1 "$f" | sed -E 's/^ADR-[0-9]+[ ]*[:-]?[ ]*//')"
    st="$(fm_get "$f" status)"
    if [[ -z "$st" ]]; then st="$(section "$f" '^Status' | awk 'NF{print; exit}' | sed -E 's/[ ]*\(.*$//')"; fi
    [[ $first -eq 1 ]] || printf ','
    first=0
    printf '{"id":%s,"title":%s,"status":%s,"file":%s}' "$(q "$id")" "$(q "$title")" "$(q "$st")" "$(q "architecture/adrs/$(basename "$f")")"
  done
}

# ---- specs + roadmaps ----------------------------------------------------------------
ROADMAPS_FILE="$TMP/roadmaps.json"; : > "$ROADMAPS_FILE"
SPECS_FILE="$TMP/specs.json"; : > "$SPECS_FILE"
collect_specs() {
  local sd="$REPO_ROOT/specs" group ideaId sf specId note sLines status prio cat wave title rfirst=1 sfirst=1
  [[ -d "$sd" ]] || return 0
  for group in $(ls -1 "$sd" 2>/dev/null | grep -E '^IDEA-.*-Specs$' | LC_ALL=C sort || true); do
    ideaId="$(printf '%s' "$group" | grep -oE '^IDEA-[0-9]+' || true)"
    local rm="$sd/$group/ROADMAP.md"
    if [[ -f "$rm" ]]; then
      local rows tbl
      tbl="$(section "$rm" '^Execution Plan')"; [[ -n "$tbl" ]] || tbl="$(cat "$rm")"
      rows="$(printf '%s\n' "$tbl" | table_tsv "order,spec,delivery,depends on,lane,est. tokens,restore point")"
      [[ $rfirst -eq 1 ]] || printf ',' >> "$ROADMAPS_FILE"
      rfirst=0
      {
        printf '{"ideaId":%s,"title":%s,"columns":["order","spec","delivery","dependsOn","lane","tokens","restore"],"rows":[' "$(q "$ideaId")" "$(q "$(h1 "$rm" | sed -E 's/^Roadmap[ ]*[-:][ ]*//')")"
        printf '%s' "$rows" | awk -F'\t' 'NF{printf "%s{\"order\":\"%s\",\"spec\":\"%s\",\"delivery\":\"%s\",\"dependsOn\":\"%s\",\"lane\":\"%s\",\"tokens\":\"%s\",\"restore\":\"%s\"}", (n++?",":""), $1,$2,$3,$4,$5,$6,$7}' | awk '1'
        printf ']}'
      } >> "$ROADMAPS_FILE"
    fi
    for sf in $(ls -1 "$sd/$group" 2>/dev/null | grep -E '^SPEC-' | LC_ALL=C sort || true); do
      [[ -d "$sd/$group/$sf" ]] || continue
      local dir="$sd/$group/$sf"
      specId="$(printf '%s' "$sf" | grep -oE '^SPEC-[0-9A-Za-z]+' | head -n 1 || true)"
      note="$(ls -1 "$dir"/SPEC-*.md 2>/dev/null | grep -vi backlog | head -n 1 || true)"
      status=""; prio=""; cat=""; wave=""; title=""
      if [[ -n "$note" ]]; then
        local hdr
        hdr="$(head -n 12 "$note" | table_tsv "status,priority,category,wave" | head -n 1)"
        status="$(printf '%s' "$hdr" | cut -f1)"; prio="$(printf '%s' "$hdr" | cut -f2)"; cat="$(printf '%s' "$hdr" | cut -f3)"; wave="$(printf '%s' "$hdr" | cut -f4)"
        [[ -n "$status" ]] || status="$(fm_get "$note" status)"
        title="$(h1 "$note" | sed -E 's/^SPEC-[0-9A-Za-z]+[ ]*[:-]?[ ]*//')"; [[ -n "$title" ]] || title="$(fm_get "$note" title)"
      fi
      # delivery brief
      local who gets value measured
      who=""; gets=""; value=""; measured=""
      if [[ -n "$note" ]]; then
        while IFS=$'\t' read -r lab val; do
          case "$lab" in who) who="$val" ;; gets) gets="$val" ;; value) value="$val" ;; measured*) measured="$val" ;; esac
        done < <(section "$note" '^Delivery Brief' | awk '{sub(/\r$/,"")} match($0,/^[ \t]*[-*][ \t]*\*\*[^*]+\*\*/){lab=substr($0,RSTART,RLENGTH); val=substr($0,RSTART+RLENGTH); gsub(/^[ \t]*[-*][ \t]*\*\*|\*\*$/,"",lab); gsub(/:/,"",lab); sub(/^:?[ \t]*/,"",val); print tolower(lab) "\t" val}')
      fi
      # spec-level acceptance criteria
      local acs_json=""
      if [[ -n "$note" ]]; then
        acs_json="$(section "$note" '^Acceptance Criteria' | ac_tsv | awk -F'\t' '{gsub(/\\/,"\\\\",$3); gsub(/"/,"\\\"",$3); printf "%s{\"id\":\"%s\",\"text\":\"%s\",\"done\":%s}", (n++?",":""), $2,$3,($1=="1"?"true":"false")}')"
      fi
      # backlog table (status/wave fallback)
      local BL=""
      [[ -n "$note" ]] && BL="$(section "$note" '^Backlog' | table_tsv "key,type,title,status,depends on,wave")"
      # items and bugs
      local items_json="" bugs_json="" seen=" " bf key type ititle bstat bdialect bdep bwave brow
      local ifirst=1 bfirst=1
      if [[ -d "$dir/Backlog" ]]; then
        for bf in $(ls -1 "$dir/Backlog"/*.md 2>/dev/null | LC_ALL=C sort); do
          key="$(basename "$bf" | grep -oE '^(Story|Enabler|Bug)-[0-9]+' || true)"
          [[ -n "$key" ]] || continue
          type="${key%%-*}"
          ititle="$(h1 "$bf" | sed -E 's/^(Story|Enabler|Bug)-[0-9]+[ ]*[:-]?[ ]*//')"
          seen="$seen$key "
          if [[ "$type" == "Bug" ]]; then
            local bt sev bst src ref tst
            bt="$(head -n 14 "$bf" | table_tsv "severity,status,source,story / ac,regression test" | head -n 1)"
            sev="$(printf '%s' "$bt" | cut -f1)"; bst="$(printf '%s' "$bt" | cut -f2)"; src="$(printf '%s' "$bt" | cut -f3)"; ref="$(printf '%s' "$bt" | cut -f4)"; tst="$(printf '%s' "$bt" | cut -f5)"
            [[ $bfirst -eq 1 ]] || bugs_json="$bugs_json,"
            bfirst=0
            bugs_json="$bugs_json{\"key\":$(q "$key"),\"title\":$(q "$ititle"),\"severity\":$(q "$sev"),\"status\":$(q "$bst"),\"source\":$(q "$src"),\"ref\":$(q "$ref"),\"test\":$(q "$tst")}"
            continue
          fi
          local it
          it="$(head -n 14 "$bf" | table_tsv "status,dialect,depends on" | head -n 1)"
          bstat="$(printf '%s' "$it" | cut -f1)"; bdialect="$(printf '%s' "$it" | cut -f2)"; bdep="$(printf '%s' "$it" | cut -f3)"
          brow="$(printf '%s\n' "$BL" | awk -F'\t' -v k="$key" '$1==k{print; exit}')"
          [[ -n "$bstat" ]] || bstat="$(printf '%s' "$brow" | cut -f4)"
          [[ -n "$ititle" ]] || ititle="$(printf '%s' "$brow" | cut -f3)"
          [[ -n "$bdep" ]] || bdep="$(printf '%s' "$brow" | cut -f5)"
          bwave="$(printf '%s' "$brow" | cut -f6)"
          local iacs
          iacs="$(section "$bf" '^Acceptance Criteria' | ac_tsv | awk -F'\t' '{gsub(/\\/,"\\\\",$3); gsub(/"/,"\\\"",$3); printf "%s{\"id\":\"%s\",\"text\":\"%s\",\"done\":%s}", (n++?",":""), $2,$3,($1=="1"?"true":"false")}')"
          [[ $ifirst -eq 1 ]] || items_json="$items_json,"
          ifirst=0
          items_json="$items_json{\"key\":$(q "$key"),\"type\":$(q "$type"),\"title\":$(q "$ititle"),\"status\":$(q "$bstat"),\"wave\":$(q "$bwave"),\"dependsOn\":$(q "$bdep"),\"dialect\":$(q "$bdialect"),\"acs\":[$iacs]}"
        done
      fi
      # table rows whose item file is missing
      while IFS=$'\t' read -r k t ti st dep wv; do
        [[ -n "$k" && "$k" != Bug-* ]] || continue
        case "$seen" in *" $k "*) continue ;; esac
        [[ $ifirst -eq 1 ]] || items_json="$items_json,"
        ifirst=0
        items_json="$items_json{\"key\":$(q "$k"),\"type\":$(q "$t"),\"title\":$(q "$ti"),\"status\":$(q "$st"),\"wave\":$(q "$wv"),\"dependsOn\":$(q "$dep"),\"dialect\":\"\",\"acs\":[]}"
      done <<EOF
$BL
EOF
      # plan
      local pexists=false pstatus="" pwaves=0 ptests=0 plan="$dir/plan.md"
      if [[ -f "$plan" ]]; then
        pexists=true; pstatus="$(fm_get "$plan" status)"
        pwaves="$(section "$plan" '^Waves' | table_tsv "#1" | awk 'NF' | sort -u | awk 'END{print NR}')"
        ptests="$(section "$plan" '^Atomic test cases' | table_tsv "#1" | awk 'NF' | awk 'END{print NR}')"
      fi
      # review
      local rexists=false rverdict=""
      if [[ -f "$dir/review.md" ]]; then
        rexists=true
        rverdict="$(grep -oiwE 'APPROVED|CHANGES_NEEDED|TOOLCHAIN_DEFERRED|BLOCKED' "$dir/review.md" | head -n 1 | tr 'a-z' 'A-Z' || true)"
      fi
      # test results
      local verdict="null" trf="$REPO_ROOT/TestResults/$ideaId/$specId/test-run-summary.md" tp tf
      if [[ -f "$trf" ]]; then
        tp="$(grep -oiwE 'PASS|PASSED' "$trf" | awk 'END{print NR}')"; tf="$(grep -oiwE 'FAIL|FAILED' "$trf" | awk 'END{print NR}')"
        verdict="{\"pass\":$(num "$tp"),\"fail\":$(num "$tf")}"
      fi
      # ADR refs
      local adrs
      adrs="$( { [[ -n "$note" ]] && cat "$note"; [[ -f "$dir/arch.md" ]] && cat "$dir/arch.md"; [[ -f "$plan" ]] && cat "$plan"; true; } 2>/dev/null | grep -oE 'ADR-[0-9]+' | LC_ALL=C sort -u | awk '{printf "%s\"%s\"", (n++?",":""), $0}')"
      [[ $sfirst -eq 1 ]] || printf ',' >> "$SPECS_FILE"
      sfirst=0
      printf '{"id":%s,"ideaId":%s,"folder":%s,"title":%s,"status":%s,"priority":%s,"category":%s,"wave":%s,"deliveryBrief":{"who":%s,"gets":%s,"value":%s,"measured":%s},"acs":[%s],"items":[%s],"bugs":[%s],"plan":{"exists":%s,"status":%s,"waves":%s,"tests":%s},"review":{"exists":%s,"verdict":%s},"verdict":%s,"adrRefs":[%s]}' \
        "$(q "$specId")" "$(q "$ideaId")" "$(q "$sf")" "$(q "$title")" "$(q "$status")" "$(q "$prio")" "$(q "$cat")" "$(q "$wave")" \
        "$(q "$who")" "$(q "$gets")" "$(q "$value")" "$(q "$measured")" "$acs_json" "$items_json" "$bugs_json" \
        "$pexists" "$(q "$pstatus")" "$(num "$pwaves")" "$(num "$ptests")" "$rexists" "$(q "$rverdict")" "$verdict" "$adrs" >> "$SPECS_FILE"
    done
  done
}

# ---- run object -------------------------------------------------------------------------
# The `auto` skill in a chat session records progress as backchannel events but does not keep the
# driver's run.json `state`; derive the stage from the events so the pipeline does not sit on REPO.
derive_state() { # prints "<state> <running|done>" or nothing
  local bc="$REPO_ROOT/coordination/backchannel.jsonl" r ids
  [[ -f "$bc" ]] || return 0
  # Non-skipped state ids, in order, so "the next stage after N" skips what --fasttrack skips.
  ids="$(emit_states | tr '{' '\n' | grep '"skipped":false' | sed -nE 's/.*"id":([0-9]+).*/\1/p' | tr '\n' ' ')"
  # Run-wide stages (up to SPECS) advance on any event; PLAN..REVIEW advance per spec, and the pipeline shows
  # the earliest stage a spec is still in (a spec-less event, e.g. an early preflight, moves nothing).
  r="$(tr -d '\r' < "$bc" | awk -v ids="$ids" '
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
      if (k == "spec-created" && sp != "" && !(sp in sd)) sd[sp] = 9
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
    pd="$(claude_project_dir 2>/dev/null || true)"
    if [[ -n "$pd" && -d "$pd" ]] && [[ -n "$(find "$pd" -name '*.jsonl' -mmin -30 2>/dev/null | head -n 1)" ]]; then recent=1; fi
    if [[ $recent -eq 0 && -n "$lastts" ]]; then
      le="$(date -u -d "$lastts" +%s 2>/dev/null || date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$lastts" +%s 2>/dev/null || echo 0)"; now="$(date -u +%s)"
      if [[ "$le" -gt 0 && $((now - le)) -gt 1800 ]]; then r="${r%% *} idle"; echo 'Run marked idle: nothing happened for more than 30 minutes.' >> "$NOTES_FILE"; fi
    fi
  fi
  echo "$r"
}

# ---- lanes: git worktrees (.worktrees/) and kcc run lanes (.kcc-lanes/) where specs are being built ----
emit_lanes() {
  local ld d n files last first=1 spec lrf lst lwv lss
  for ld in .worktrees .kcc-lanes; do
    [[ -d "$REPO_ROOT/$ld" ]] || continue
    for d in "$REPO_ROOT/$ld"/*/; do
      [[ -d "$d" ]] || continue
      n="$(basename "$d")"; spec="$(printf '%s' "$n" | grep -oE 'SPEC-[0-9A-Za-z]+' | head -n 1)"
      files=0; [[ -d "$d/src" ]] && files="$(find "$d/src" -type f -not -path '*/node_modules/*' 2>/dev/null | wc -l | tr -d ' ')"
      last="$(find "$d" -maxdepth 4 -type f -not -path '*/node_modules/*' -not -path '*/.git/*' -printf '%T@\n' 2>/dev/null | sort -n | tail -n 1 | cut -d. -f1)"
      [[ -n "$last" ]] && last="$(date -u -d "@$last" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)"
      [[ $first -eq 1 ]] || printf ','; first=0
      lrf="$d/coordination/run/run.json"; lst=""; lwv=""; lss=""
      if [[ -f "$lrf" ]]; then lst="$(rawval "$lrf" state)"; lwv="$(rawval "$lrf" wave)"; lss="$(rawval "$lrf" status)"; fi
      printf '{"name":%s,"kind":%s,"spec":%s,"files":%s,"updated":%s,"runState":%s,"runWave":%s,"runStatus":%s}' "$(q "$n")" "$(q "${ld#.}")" "$(q "$spec")" "${files:-0}" "$(q "$last")" "$(q "$lst")" "$(q "$lwv")" "$(q "$lss")"
    done
  done
}

emit_run() {
  local specs idx cur="" st dv
  if [[ ! -f "$RUN_FILE" ]] || [[ -z "$(rawval "$RUN_FILE" state)" ]]; then
    dv="$(derive_state)"
    if [[ -n "$dv" ]]; then
      echo 'Stage derived from backchannel events (chat-driven run).' >> "$NOTES_FILE"
      local rsn=""; [[ "${dv#* }" == "idle" ]] && rsn="no event or agent activity for more than 30 minutes; resume with: auto resume"
      printf '{"status":%s,"state":%s,"wave":"","scenario":%s,"harness":"chat","fasttrack":%s,"parallel":%s,"depthlevel":%s,"reason":%s,"updated":"","created":"","input":"","idea":%s,"currentSpec":"","gate_name":""}' \
        "$(q "${dv#* }")" "${dv%% *}" "$(q "$SCEN")" "$(bool $FAST)" "$(bool $PAR)" "$(q "$( [[ -f "$RUN_FILE" ]] && rawval "$RUN_FILE" depthlevel)")" "$(q "$rsn")" "$(q "$( [[ -f "$RUN_FILE" ]] && rawval "$RUN_FILE" idea)")"
      return 0
    fi
  fi
  [[ -f "$RUN_FILE" ]] || { printf 'null'; return 0; }
  specs="$(rawval "$RUN_FILE" specs)"; idx="$(rawval "$RUN_FILE" spec_index)"
  [[ "$idx" =~ ^[0-9]+$ ]] || idx=0
  cur="$(printf '%s' "$specs" | tr ' ' '\n' | awk -v i="$idx" 'NF{ if (n++==i) print }' | grep -oE 'SPEC-[0-9A-Za-z]+' | head -n 1 || true)"
  st="$(rawval "$RUN_FILE" state)"
  printf '{"status":%s,"state":%s,"wave":%s,"scenario":%s,"harness":%s,"fasttrack":%s,"parallel":%s,"depthlevel":%s,"reason":%s,"updated":%s,"created":%s,"input":%s,"idea":%s,"currentSpec":%s,"gate_name":%s}' \
    "$(q "$(rawval "$RUN_FILE" status)")" "$(num "$st")" "$(q "$(rawval "$RUN_FILE" wave)")" "$(q "$SCEN")" "$(q "$(rawval "$RUN_FILE" harness)")" "$(bool $FAST)" "$(bool $PAR)" \
    "$(q "$(rawval "$RUN_FILE" depthlevel)")" "$(q "$(rawval "$RUN_FILE" reason)")" "$(q "$(rawval "$RUN_FILE" updated)")" "$(q "$(rawval "$RUN_FILE" created)")" \
    "$(q "$(rawval "$RUN_FILE" input)")" "$(q "$(rawval "$RUN_FILE" idea)")" "$(q "$cur")" "$(q "$(rawval "$RUN_FILE" gate_name)")"
}

# ---- events ---------------------------------------------------------------------------------
NOTES_FILE="$TMP/notes.txt"; : > "$NOTES_FILE"
emit_events() {
  local bc="$REPO_ROOT/coordination/backchannel.jsonl"
  [[ -f "$bc" ]] || { echo 'No coordination/backchannel.jsonl yet.' >> "$NOTES_FILE"; return 0; }
  tr -d '\r' < "$bc" | awk 'NF' | tail -n "$MAX_EVENTS" | awk '
    function esc(s) { gsub(/\\/, "\\\\", s); gsub(/"/, "\\\"", s); gsub(/\t/, "\\t", s); gsub(/[\001-\010\013\014\016-\037]/, "", s); return s }
    function str(h, keys,   n, k, re, a, i) {
      n = split(keys, k, "|")
      for (i = 1; i <= n; i++) { re = "\"" k[i] "\" *: *\"[^\"]*\""; if (match(h, re)) { a = substr(h, RSTART, RLENGTH); sub(/^[^:]*: *"/, "", a); sub(/"$/, "", a); return a } }
      return ""
    }
    {
      pi = index($0, "\"payload\"")
      head = (pi > 0) ? substr($0, 1, pi - 1) : $0
      raw = ""
      if (pi > 0) { rest = substr($0, pi); c = index(rest, ":"); raw = substr(rest, c + 1); sub(/^ +/, "", raw); sub(/\} *$/, "", raw) }
      printf "%s{\"id\":\"%s\",\"ts\":\"%s\",\"kind\":\"%s\",\"from\":\"%s\",\"to\":\"%s\",\"spec\":\"%s\",\"payload\":\"%s\"}", (n++ ? "," : ""), esc(str(head, "id")), esc(str(head, "ts|timestamp")), esc(str(head, "kind|event")), esc(str(head, "from|agent")), esc(str(head, "to")), esc(str(head, "spec")), esc(raw)
    }'
}

# ---- checkpoints -----------------------------------------------------------------------------------
emit_checkpoints() {
  local d="$REPO_ROOT/coordination/checkpoints" first=1 f id latest
  [[ -d "$d" ]] || return 0
  latest="$(fm_get "$d/latest.md" points_to)"
  for f in $(ls -1 "$d"/CP-*.md 2>/dev/null | LC_ALL=C sort); do
    id="$(fm_get "$f" id)"; [[ -n "$id" ]] || id="$(basename "$f" .md)"
    [[ $first -eq 1 ]] || printf ','
    first=0
    printf '{"id":%s,"created":%s,"reason":%s,"spec":%s,"stage":%s,"next_action":%s,"git_tag":%s,"previous":%s,"latest":%s}' \
      "$(q "$id")" "$(q "$(fm_get "$f" created)")" "$(q "$(fm_get "$f" reason)")" "$(q "$(fm_get "$f" spec)")" "$(q "$(fm_get "$f" stage)")" \
      "$(q "$(fm_get "$f" next_action)")" "$(q "$(fm_get "$f" git_tag)")" "$(q "$(fm_get "$f" previous)")" "$([[ "$id" == "$latest" ]] && echo true || echo false)"
  done
}

# ---- traces + decisions -----------------------------------------------------------------------------
DEC_FILE="$TMP/decisions.json"; : > "$DEC_FILE"
HDEC_FILE="$TMP/hdecisions.json"; : > "$HDEC_FILE"
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
emit_sessions() {
  local td="$REPO_ROOT/Traces" first=1 sess n f p present lines trunc body firstf dfirst=1 hfirst=1 piece
  if [[ ! -d "$td" ]]; then echo 'No Traces/ folder yet (fast-track runs do not write traces).' >> "$NOTES_FILE"; return 0; fi
  for sess in $(ls -1 "$td" 2>/dev/null | grep -E '^Session-' | LC_ALL=C sort || true); do
    [[ -d "$td/$sess" ]] || continue
    [[ $first -eq 1 ]] || printf ','
    first=0
    printf '{"name":%s,"files":[' "$(q "$sess")"
    firstf=1
    for n in Decisions HumanDecisions Actions Handovers ToolsUsed HumanActions TokenUsage; do
      f="$td/$sess/$n.md"
      present=false; lines=0; trunc=false; body=""
      if [[ -f "$f" ]]; then
        present=true; lines="$(count_lines "$f")"
        body="$(head -c "$MAX_TRACE_CHARS" "$f" | { iconv -f utf-8 -t utf-8 -c 2>/dev/null || cat; })"
        [[ "$(wc -c < "$f" | tr -d ' ')" -gt "$MAX_TRACE_CHARS" ]] && trunc=true
        if [[ "$n" == "Decisions" ]]; then piece="$(decisions_json "$sess" "$f")"; if [[ -n "$piece" ]]; then [[ -s "$DEC_FILE" ]] && printf ',' >> "$DEC_FILE"; printf '%s' "$piece" >> "$DEC_FILE"; fi; fi
        if [[ "$n" == "HumanDecisions" ]]; then piece="$(decisions_json "$sess" "$f")"; if [[ -n "$piece" ]]; then [[ -s "$HDEC_FILE" ]] && printf ',' >> "$HDEC_FILE"; printf '%s' "$piece" >> "$HDEC_FILE"; fi; fi
      fi
      [[ $firstf -eq 1 ]] || printf ','
      firstf=0
      printf '{"name":%s,"present":%s,"lines":%s,"truncated":%s,"text":%s}' "$(q "$n")" "$present" "$(num "$lines")" "$trunc" "$(q "$body")"
    done
    printf ']}'
  done
}

# ---- agent history (Claude Code transcripts) --------------------------------------------------
# One headless session per kcc-run state, plus one transcript per subagent, under
# ~/.claude/projects/<workspace path with non-alphanumerics replaced by '-'>/ (CLAUDE_CONFIG_DIR is honoured).
# Each transcript is summarised once (awk) and cached under dashboard/.agent-cache until it changes,
# so refreshing after every event stays cheap; one final awk pass writes the JSON.
MAX_SESSIONS=80
claude_project_dir() { # [root] -> the Claude project folder of the workspace, or of a lane when given
  local base="${CLAUDE_CONFIG_DIR:-}" p
  if [[ -z "$base" ]]; then base="${HOME:-}/.claude"; fi
  p="${1:-$REPO_ROOT}"
  if command -v cygpath >/dev/null 2>&1; then p="$(cygpath -w "$REPO_ROOT" 2>/dev/null || printf '%s' "$REPO_ROOT")"; fi
  printf '%s/projects/%s' "$base" "$(printf '%s' "$p" | sed 's/[^A-Za-z0-9]/-/g')"
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
emit_profiles() {
  local d="$REPO_ROOT/.claude/agents" first=1 f nm
  [[ -d "$d" ]] || return 0
  for f in $(ls -1 "$d"/*.md 2>/dev/null | LC_ALL=C sort); do
    nm="$(fm_get "$f" name)"; [[ -n "$nm" ]] || nm="$(basename "$f" .md)"
    [[ $first -eq 1 ]] || printf ','
    first=0
    printf '{"name":%s,"model":%s,"effort":%s}' "$(q "$nm")" "$(q "$(fm_get "$f" model)")" "$(q "$(fm_get "$f" effort)")"
  done
}
emit_agents() {
  local pd sf sid sum label jf meta atype adesc pe pm tsv="$TMP/agents.tsv" sd key sessions lane dirs=()
  : > "$tsv"
  # A lane (.kcc-lanes/SPEC-x, .worktrees/SPEC-x) runs its sessions with the lane as the working folder, so its
  # transcripts live under the lane's own project folder.
  pd="$(claude_project_dir)"; [[ -d "$pd" ]] && dirs+=("$pd")
  for lane in "$REPO_ROOT"/.kcc-lanes/*/ "$REPO_ROOT"/.worktrees/*/; do
    [[ -d "$lane" ]] || continue
    pd="$(claude_project_dir "${lane%/}")"; [[ -d "$pd" ]] && dirs+=("$pd")
  done
  [[ ${#dirs[@]} -gt 0 ]] || return 0
  sessions="$(for pd in "${dirs[@]}"; do ls -1 "$pd"/*.jsonl 2>/dev/null; done | while IFS= read -r one; do printf '%s %s\n' "$(stat -c %Y "$one" 2>/dev/null || stat -f %m "$one" 2>/dev/null || echo 0)" "$one"; done | sort -rn | head -n "$MAX_SESSIONS" | cut -d' ' -f2- || true)"
  while IFS= read -r sf; do
    [[ -n "$sf" ]] || continue
    sid="$(basename "$sf" .jsonl)"
    sum="$(cached_summary "$sf" "$sid")"
    [[ -n "$(printf '%s' "$sum" | cut -f1)" ]] || continue
    label="$(printf '%s' "$sum" | cut -f4)"
    printf 'session\t%s\t\tmain session\t%s\t%s\t\t\t%s\n' "$sid" "$label" "$label" "$sum" >> "$tsv"
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
        if [[ -f "$REPO_ROOT/.claude/agents/$atype.md" ]]; then pe="$(fm_get "$REPO_ROOT/.claude/agents/$atype.md" effort)"; pm="$(fm_get "$REPO_ROOT/.claude/agents/$atype.md" model)"; fi
        printf 'subagent\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$sid/$(basename "$jf" .jsonl)" "$sid" "$atype" "$adesc" "$label" "$pe" "$pm" "$sum" >> "$tsv"
      done
    fi
  done <<EOF
$sessions
EOF
  awk -F'\t' '
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
    }' "$tsv"
}


# ---- stage timing: one row per harness dispatch (coordination/run/logs/state-*.log) -------------------
# The log header carries the start time; the last write is the end (the harness writes at exit).
mtime_iso() { # file -> ISO UTC of its last write (GNU stat, then BSD stat)
  local e; e="$(stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || echo 0)"
  date -u -d "@$e" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -r "$e" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo ""
}
emit_runlogs() {
  local d f base first=1 spec started root rel
  for root in "$REPO_ROOT" "$REPO_ROOT"/.kcc-lanes/*/ "$REPO_ROOT"/.worktrees/*/; do
  root="${root%/}"; [[ -d "$root" ]] || continue
  d="$root/coordination/run/logs"
  [[ -d "$d" ]] || continue
  rel=""; [[ "$root" != "$REPO_ROOT" ]] && rel="${root#"$REPO_ROOT"/}/"
  for f in $(ls -1tr "$d"/state-*.log 2>/dev/null); do
    base="$(basename "$f")"
    [[ "$base" =~ ^state-([0-9]+)-(run|SPEC-[0-9A-Za-z]+)(-w([0-9]+))?-([0-9]+|install)\.log$ ]] || continue
    spec="${BASH_REMATCH[2]}"; [[ "$spec" == "run" ]] && spec=""
    started="$(head -n 1 "$f" | sed -nE 's/^# kcc-run ([^ ]+).*/\1/p')"
    [[ $first -eq 1 ]] || printf ','
    first=0
    printf '{"state":%s,"spec":%s,"wave":%s,"attempt":%s,"started":%s,"ended":%s,"file":%s}' "${BASH_REMATCH[1]}" "$(q "$spec")" "$(q "${BASH_REMATCH[4]:-}")" "$(q "${BASH_REMATCH[5]}")" "$(q "$started")" "$(q "$(mtime_iso "$f")")" "$(q "${rel}coordination/run/logs/$base")"
  done
  done
}

# ---- assemble ----------------------------------------------------------------------------------------------
collect_specs
[[ -d "$REPO_ROOT/specs" ]] || echo 'No specs/ folder yet.' >> "$NOTES_FILE"
[[ -d "$REPO_ROOT/ideation" ]] || echo 'No ideation/ folder yet.' >> "$NOTES_FILE"
MEM_TOTAL=0
if [[ -f "$REPO_ROOT/memory/index.json" ]]; then MEM_TOTAL="$(grep -oE '"id" *:' "$REPO_ROOT/memory/index.json" | awk 'END{print NR}')"; fi

JSON_FILE="$TMP/data.json"
{
  printf '{"schema":2,"generatedAt":%s,"repoRoot":%s,"project":%s,"run":' "$(q "$NOW")" "$(q "$REPO_ROOT")" "$(q "$PROJECT")"
  emit_run
  printf ',"states":['; emit_states; printf ']'
  printf ',"ideas":['; emit_ideas; printf ']'
  printf ',"specs":['; cat "$SPECS_FILE"; printf ']'
  printf ',"roadmaps":['; cat "$ROADMAPS_FILE"; printf ']'
  printf ',"events":['; emit_events; printf ']'
  printf ',"checkpoints":['; emit_checkpoints; printf ']'
  printf ',"sessions":['; emit_sessions; printf ']'
  printf ',"decisions":['; cat "$DEC_FILE"; printf ']'
  printf ',"humanDecisions":['; cat "$HDEC_FILE"; printf ']'
  printf ',"adrs":['; emit_adrs; printf ']'
  printf ',"agents":['; emit_agents; printf ']'
  printf ',"lanes":['; emit_lanes; printf ']'
  printf ',"profiles":['; emit_profiles; printf ']'
  printf ',"runLogs":['; emit_runlogs; printf ']'
  printf ',"memory":{"total":%s,"byType":{}}' "$(num "$MEM_TOTAL")"
  printf ',"notes":['; awk 'NF{gsub(/\\/,"\\\\"); gsub(/"/,"\\\""); printf "%s\"%s\"", (n++?",":""), $0}' "$NOTES_FILE"; printf ']}'
} > "$JSON_FILE"
sed -i.bak 's#</#<\\/#g' "$JSON_FILE" && rm -f "$JSON_FILE.bak"

TPL="$REPO_ROOT/.KCC/kernel/templates/dashboard.html"
[[ -z "$TEMPLATE" ]] || TPL="$TEMPLATE"
[[ -f "$TPL" ]] || TPL="$(dirname "$SCRIPT_DIR")/kernel/templates/dashboard.html"
[[ -f "$TPL" ]] || { echo "dashboard template not found: $TPL" >&2; exit 2; }
OUT_DIR="$REPO_ROOT/dashboard"; OUT_FILE="$OUT_DIR/index.html"
mkdir -p "$OUT_DIR"
awk -v jf="$JSON_FILE" '{ i=index($0,"__KCC_DATA__"); if(i>0){ printf "%s", substr($0,1,i-1); while((getline l < jf)>0) printf "%s", l; print substr($0,i+12) } else print }' "$TPL" > "$OUT_FILE"

echo "Dashboard written to $OUT_FILE"
echo "  specs/events/sessions collected; open it in a browser (works offline)"
# A lane (<root>/.kcc-lanes/SPEC-x) builds its own page, but the page people look at is the workspace's. Rebuild that one
# too, so lane activity reaches it even when the scheduler that normally refreshes it is not running.
if [[ "${KCC_DASH_PARENT:-}" != "1" ]]; then
  lane_norm="$(printf '%s' "$REPO_ROOT" | tr '\134' '/')"
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
