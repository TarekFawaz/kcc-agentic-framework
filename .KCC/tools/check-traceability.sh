#!/usr/bin/env bash
# KCC framework (c) 2026 Tarek Fawaz, https://tikasway.dev/kcc. Licensed under the terms in LICENSE.
#
# AC -> Test ID -> test file -> PASS result traceability gate.
# Mirror of check-traceability.ps1 (same IDs, exit codes). Read-only.
# Contract: .KCC/kernel/contracts/tool-contract.md
#
#   TRC-000 planner      plan.md missing (or --spec matches nothing)
#   TRC-001 planner      an item AC has no Test ID row in plan.md '## Atomic test cases'
#   TRC-005 implementer  no src/IDEA-{ID}-*/ workspace
#   TRC-002 implementer  Test ID not referenced by any test file under src/IDEA-{ID}-*/
#   TRC-003 verifier     Test ID has no PASS result (test-run-summary.md row or JUnit XML)
#   TRC-004 implementer  Test ID has only FAIL results
#
# Without --spec only specs at Review/Done status (or with a review.md) are traced.
#
# Usage: bash .KCC/tools/check-traceability.sh [--repo-root PATH] [--spec SPEC-ID] [--json]

set -euo pipefail

TOOL_VERSION="1.0.0"
REPO_ROOT=""
SPEC=""
SCOPE="all"
JSON=0

while [ $# -gt 0 ]; do
  case "$1" in
    --repo-root) REPO_ROOT="${2:-}"; shift 2 ;;
    --spec) SPEC="${2:-}"; shift 2 ;;
    --scope) SCOPE="${2:-}"; shift 2 ;;
    --json) JSON=1; shift ;;
    -h|--help) sed -n '2,17p' "$0"; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

TOOL_DIR="$(cd "$(dirname "$0")" && pwd)"
if [ -z "$REPO_ROOT" ]; then
  PARENT="$(dirname "$TOOL_DIR")"
  if [ "$(basename "$PARENT")" = ".KCC" ]; then REPO_ROOT="$(dirname "$PARENT")"; else REPO_ROOT="$PARENT"; fi
fi
if [ ! -d "$REPO_ROOT" ]; then echo "workspace not found: $REPO_ROOT" >&2; exit 2; fi
REPO_ROOT="$(cd "$REPO_ROOT" && pwd)"
SPECS_DIR="$REPO_ROOT/specs"

ERRORS=0
WARNINGS=0
VJSON=""
TAB="$(printf '\t')"

je() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\t'/\\t}"
  s="${s//$'\r'/}"
  s="${s//$'\n'/\\n}"
  printf '%s' "$s"
}
lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }
rel() { printf '%s' "${1#"$REPO_ROOT"/}"; }
violation() { # id severity owner message [file]
  local id="$1" sev="$2" owner="$3" msg="$4" file="${5:-}" obj
  if [ "$sev" = "error" ]; then ERRORS=$((ERRORS + 1)); else WARNINGS=$((WARNINGS + 1)); fi
  obj="{\"id\":\"$(je "$id")\",\"severity\":\"$sev\",\"fix_owner\":\"$(je "$owner")\",\"file\":\"$(je "$file")\",\"message\":\"$(je "$msg")\"}"
  if [ -z "$VJSON" ]; then VJSON="$obj"; else VJSON="$VJSON,$obj"; fi
  if [ "$JSON" -eq 0 ]; then
    printf '[%s] %s (%s) %s: %s\n' "$(printf '%s' "$sev" | tr '[:lower:]' '[:upper:]')" "$id" "$owner" "$file" "$msg"
  fi
  return 0
}

section() {
  [ -f "$1" ] || return 0
  awk -v pat="$(lower "$2")" '
    { sub(/\r$/, "") }
    /^##[ \t]/ {
      if (inside) stop = 1
      if (!stop) { t = tolower($0); sub(/^##[ \t]+/, "", t); if (t ~ ("^" pat)) inside = 1 }
      next
    }
    inside && !stop { print }' "$1"
}

table_field() {
  awk -v col="$(lower "$2")" '
    function trim(s) { gsub(/^[ \t*`]+|[ \t*`]+$/, "", s); return s }
    { sub(/\r$/, "") }
    fin { next }
    /^[ \t]*\|/ {
      line = $0; gsub(/\\\|/, "/", line)
      if (!hdr) {
        n = split(line, c, "|"); idx = 0
        for (i = 1; i <= n; i++) if (tolower(trim(c[i])) == col) { idx = i; break }
        hdr = 1
        if (!idx) { print "__NOCOL__"; fin = 1 }
        next
      }
      if (line ~ /^[ \t]*\|[ \t:|-]*$/) next
      n = split(line, c, "|")
      if (idx <= n) print trim(c[idx])
      fin = 1; next
    }
    hdr { fin = 1 }
    END { if (!hdr) print "__NOCOL__" }' "$1"
}

status_rank() {
  local t
  t="$(lower "$1" | sed 's/^[[:space:]]*//')"
  case "$t" in
    "") echo -1 ;;
    draft*) echo 0 ;;
    ready*) echo 1 ;;
    planned*|planning*) echo 2 ;;
    "in progress"*|in-progress*|inprogress*|implement*) echo 3 ;;
    testing*|test*|review*|"in review"*|in-review*|inreview*|verif*) echo 4 ;;
    done*|complete*|closed*|delivered*) echo 5 ;;
    *) echo -1 ;;
  esac
}

backlog_dir() { # spec-dir -> Backlog folder with its real on-disk casing
  local d first=""
  for d in "$1"/*; do
    [ -d "$d" ] || continue
    case "$(basename "$d")" in
      Backlog) printf '%s' "$d"; return 0 ;;
      [Bb][Aa][Cc][Kk][Ll][Oo][Gg]) if [ -z "$first" ]; then first="$d"; fi ;;
    esac
  done
  printf '%s' "$first"
  return 0
}

list_items() {
  local bd f n key
  bd="$(backlog_dir "$1")"
  [ -n "$bd" ] || return 0
  for f in "$bd"/*.md; do
    [ -f "$f" ] || continue
    n="$(basename "$f")"
    key="$(printf '%s' "$n" | grep -oE '^(Story|Enabler|Bug)-[0-9]+' || true)"
    [ -n "$key" ] || continue
    printf '%s\t%s\t%s\n' "$key" "${key%%-*}" "$f"
  done
  return 0
}

item_acs() {
  section "$1" 'acceptance criteria' | awk '
    {
      if (match($0, /^[ \t]*[-*][ \t]*(\[[ xX]\][ \t]*)?\**[ \t]*AC-[0-9]+/)) {
        s = substr($0, RSTART, RLENGTH); match(s, /AC-[0-9]+$/); a = substr(s, RSTART, RLENGTH)
        if (!(a in seen)) { seen[a] = 1; print a }
      }
    }'
}

plan_tests() {
  [ -f "$1" ] || return 0
  section "$1" 'atomic test cases' | awk '
    function trim(s) { gsub(/^[ \t*`]+|[ \t*`]+$/, "", s); return s }
    /^[ \t]*\|/ {
      n = split($0, c, "|")
      if (!hdr) {
        for (i = 1; i <= n; i++) { t = tolower(trim(c[i])); if (t == "test id") ti = i; else if (t == "item") ii = i; else if (t == "ac") ai = i }
        hdr = 1; next
      }
      if ($0 ~ /^[ \t]*\|[ \t:|-]*$/) next
      if (!ti || ti > n) next
      id = trim(c[ti]); if (id == "") next
      item = ""; if (ii && ii <= n && match(c[ii], /(Story|Enabler|Bug)-[0-9]+/)) item = substr(c[ii], RSTART, RLENGTH)
      ac = ""; if (ai && ai <= n) ac = trim(c[ai])
      print id "\t" item "\t" ac
    }'
}

list_all_specs() {
  local d name id group idea
  [ -d "$SPECS_DIR" ] || return 0
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    name="$(basename "$d")"
    [ -f "$d/$name.md" ] || continue
    id="$(printf '%s' "$name" | grep -oE '^SPEC-[0-9]+' || true)"
    [ -n "$id" ] || continue
    group="$(dirname "$d")"
    idea="$(basename "$group" | grep -oE '^IDEA-[0-9]+' || true)"
    printf '%s\t%s\t%s\t%s\t%s\n' "$id" "$name" "$d" "$d/$name.md" "$idea"
  done <<EOF
$(find "$SPECS_DIR" -type d -name 'SPEC-*' 2>/dev/null | LC_ALL=C sort)
EOF
  return 0
}

spec_match() {
  local s n
  [ -n "$SPEC" ] || return 0
  s="$(lower "$SPEC")"; n="$(lower "$1")"
  if [ "$n" = "$s" ] || [ "$(lower "$2")" = "$s" ]; then return 0; fi
  case "$n" in "$s"-*) return 0 ;; esac
  return 1
}

# Test ID -> ERE accepting T-001 / T_001 / T001 with non-alnum boundaries.
id_pattern() {
  local id="$1" pre num core
  if printf '%s' "$id" | grep -qE '^[A-Za-z]+[-_]?[0-9]+$'; then
    pre="$(printf '%s' "$id" | sed -E 's/^([A-Za-z]+).*$/\1/')"
    num="$(printf '%s' "$id" | sed -E 's/^.*[^0-9]([0-9]+)$/\1/')"
    core="${pre}[-_]?${num}"
  else
    core="$(printf '%s' "$id" | sed 's/[][\.*^$+?(){}|/]/\\&/g')"
  fi
  printf '(^|[^A-Za-z0-9])%s([^0-9]|$)' "$core"
}

# Test files under one src/IDEA-* dir (paths containing test|spec; no docs; no vendor/build dirs).
test_files() {
  find "$1" \( -type d \( -name node_modules -o -name .git -o -name bin -o -name obj -o -name dist -o -name build \
      -o -name .venv -o -name venv -o -name __pycache__ -o -name target -o -name .next -o -name coverage \) -prune \) \
      -o -type f -print 2>/dev/null | while IFS= read -r f; do
    r="$(lower "${f#"$1"}")"
    case "$r" in *.md|*.txt|*.log|*.lock|*.csv|*.png|*.jpg|*.jpeg|*.gif|*.svg|*.pdf|*.ico) continue ;; esac
    case "$r" in *test*|*spec*) printf '%s\n' "$f" ;; esac
  done
  return 0
}

# JUnit cases for one spec -> name \t pass|fail|skip
junit_cases() { # idea spec
  local tr="$REPO_ROOT/TestResults" x r own
  [ -d "$tr" ] || return 0
  own="$(lower "/$1/$2/")"
  while IFS= read -r x; do
    [ -n "$x" ] || continue
    r="$(lower "/${x#"$tr"/}")"
    if printf '%s' "$r" | grep -qE '^/idea-[^/]+/spec-[^/]+/'; then
      case "$r" in "$own"*) ;; *) continue ;; esac
    fi
    tr '\r\n' '  ' < "$x" | awk '{ gsub(/<testcase/, "\n<testcase"); print }' | awk '
      /^<testcase/ {
        if (match($0, /[ \t]name="[^"]*"/)) {
          nm = substr($0, RSTART, RLENGTH); sub(/^[ \t]name="/, "", nm); sub(/"$/, "", nm)
          st = "pass"
          if ($0 ~ /<failure/ || $0 ~ /<error/) st = "fail"; else if ($0 ~ /<skipped/) st = "skip"
          print nm "\t" st
        }
      }'
  done <<EOF
$(find "$tr" -type f -name '*.xml' 2>/dev/null)
EOF
  return 0
}

ALL="$(list_all_specs)"
SPECS=""
while IFS="$TAB" read -r id name dir file idea; do
  [ -n "$id" ] || continue
  if spec_match "$name" "$id"; then SPECS="$SPECS$id$TAB$name$TAB$dir$TAB$file$TAB$idea
"; fi
done <<EOF
$ALL
EOF
if [ -n "$SPEC" ] && [ -z "$SPECS" ]; then
  violation "TRC-000" "error" "planner" "No spec folder matches $SPEC." "specs"
fi

if [ "$JSON" -eq 0 ]; then echo "KCC traceability: $REPO_ROOT"; fi

while IFS="$TAB" read -r id name dir file idea; do
  [ -n "$id" ] || continue
  if [ -z "$SPEC" ]; then
    st="$(table_field "$file" Status)"
    if [ "$st" = "__NOCOL__" ]; then st=""; fi
    if [ "$(status_rank "$st")" -lt 4 ] && [ ! -f "$dir/review.md" ]; then continue; fi
  fi
  items="$(list_items "$dir" | awk -F'\t' '$2 != "Bug"')"
  [ -n "$items" ] || continue
  plan="$dir/plan.md"
  prel="$(rel "$dir")/plan.md"
  if [ ! -f "$plan" ]; then
    violation "TRC-000" "error" "planner" "$name has no plan.md, so no AC can be traced to a Test ID." "$prel"
    continue
  fi
  tests="$(plan_tests "$plan")"
  ids=""
  while IFS="$TAB" read -r it_key it_type it_file; do
    [ -n "$it_key" ] || continue
    while IFS= read -r ac; do
      [ -n "$ac" ] || continue
      hits="$(printf '%s\n' "$tests" | awk -F'\t' -v k="$it_key" -v a="$ac" '$2 == k && $3 ~ (a "([^0-9]|$)") { print $1 }')"
      if [ -z "$hits" ]; then
        violation "TRC-001" "error" "planner" "$id $it_key $ac has no Test ID in plan.md atomic test cases." "$prel"
        continue
      fi
      while IFS= read -r t; do
        [ -n "$t" ] || continue
        case "$TAB$ids" in *"$TAB$t$TAB"*) ;; *) ids="$ids$t$TAB" ;; esac
      done <<EOF
$hits
EOF
    done <<EOF
$(item_acs "$it_file")
EOF
  done <<EOF
$items
EOF
  [ -n "$ids" ] || continue

  srcdirs=""
  if [ -n "$idea" ] && [ -d "$REPO_ROOT/src" ]; then
    for d in "$REPO_ROOT/src/$idea"-* "$REPO_ROOT/src/$idea"; do
      if [ -d "$d" ]; then srcdirs="$srcdirs$d
"; fi
    done
  fi
  tfiles=""
  if [ -z "$srcdirs" ]; then
    violation "TRC-005" "error" "implementer" "No source workspace src/$idea-*/ exists for $id." "src/$idea"
  else
    while IFS= read -r d; do
      [ -n "$d" ] || continue
      tfiles="$tfiles$(test_files "$d")
"
    done <<EOF
$srcdirs
EOF
  fi

  summary="$REPO_ROOT/TestResults/$idea/$id/test-run-summary.md"
  srel="TestResults/$idea/$id/test-run-summary.md"
  junit="$(junit_cases "$idea" "$id")"

  IFS_OLD="$IFS"; IFS="$TAB"
  for t in $ids; do
    IFS="$IFS_OLD"
    [ -n "$t" ] || continue
    pat="$(id_pattern "$t")"
    if [ -n "$srcdirs" ]; then
      found="$(printf '%s' "$tfiles" | grep -v '^$' | tr '\n' '\0' | xargs -0 grep -lE -- "$pat" 2>/dev/null | head -n 1 || true)"
      if [ -z "$found" ]; then
        violation "TRC-002" "error" "implementer" "$id Test ID $t is not referenced by any test file under src/$idea-*/." "src/$idea"
      fi
    fi
    pass=0; fail=0
    if [ -f "$summary" ]; then
      lines="$(tr -d '\r' < "$summary" | grep -E -- "$pat" || true)"
      if [ -n "$lines" ]; then
        while IFS= read -r l; do
          ll="$(lower "$l")"
          if printf '%s' "$ll" | grep -qE '(^|[^a-z0-9_])fail(ed|ure)?([^a-z0-9_]|$)'; then fail=1
          elif printf '%s' "$ll" | grep -qE '(^|[^a-z0-9_])pass(ed)?([^a-z0-9_]|$)'; then pass=1; fi
        done <<EOF
$lines
EOF
      fi
    fi
    if [ -n "$junit" ]; then
      jr="$(printf '%s\n' "$junit" | awk -F'\t' -v p="$pat" '$1 ~ p { print $2 }')"
      case "$jr" in *pass*) pass=1 ;; esac
      case "$jr" in *fail*) fail=1 ;; esac
    fi
    if [ "$pass" -eq 0 ]; then
      if [ "$fail" -eq 1 ]; then
        violation "TRC-004" "error" "implementer" "$id Test ID $t has a FAIL result." "$srel"
      else
        violation "TRC-003" "error" "verifier" "$id Test ID $t has no PASS result in test-run-summary.md or JUnit XML under TestResults/." "$srel"
      fi
    fi
    IFS="$TAB"
  done
  IFS="$IFS_OLD"
done <<EOF
$SPECS
EOF

STATUS="pass"
if [ "$ERRORS" -gt 0 ]; then STATUS="fail"; fi
if [ "$JSON" -eq 1 ]; then
  SPEC_JSON="null"
  if [ -n "$SPEC" ]; then SPEC_JSON="\"$(je "$SPEC")\""; fi
  printf '{"tool":"check-traceability","version":"%s","scope":"%s","spec":%s,"errors":%d,"warnings":%d,"status":"%s","violations":[%s]}\n' \
    "$TOOL_VERSION" "$(je "$SCOPE")" "$SPEC_JSON" "$ERRORS" "$WARNINGS" "$STATUS" "$VJSON"
else
  echo "Errors: $ERRORS  Warnings: $WARNINGS"
fi
if [ "$ERRORS" -gt 0 ]; then exit 1; fi
exit 0
