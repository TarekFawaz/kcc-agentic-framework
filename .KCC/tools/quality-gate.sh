#!/usr/bin/env bash
# KCC framework (c) 2026 Tarek Fawaz, https://tikasway.dev/kcc. Licensed under the terms in LICENSE.
#
# quality-gate.sh - deterministic quality gate for a KCC workspace.
# Mirror of quality-gate.ps1 (same check IDs, JSON shape, exit codes).
# Contract: .KCC/kernel/contracts/tool-contract.md
#
# Checks: QG-STACK QG-LOCK QG-BUILD QG-LINT QG-TEST QG-COV QG-SECRETS
#         QG-DEPS QG-SAST QG-STATIC QG-SBOM QG-IMAGE
#
# Usage:
#   bash .KCC/tools/quality-gate.sh [--repo-root PATH] [--spec SPEC-ID] [--path DIR]
#        [--scope all|lock,build,lint,test,coverage,secrets,deps,sast,static,sbom,image]
#        [--fast] [--require] [--emit] [--json]
#
# Exit: 0 pass | 1 violations | 2 usage/environment | 3 deferred (a scanner or
# toolchain is missing; NOT a pass). This tool NEVER installs anything; it
# prints the toolchain-preflight command for the human to approve.
# No python / jq dependency.
set -euo pipefail

VERSION="1.0.0"
# Spawn budget: under Git Bash on Windows every fork and exec costs ~0.3-0.4 s, so the helpers below hand results back in variables and
# use builtins; the tools that do real work (git, the scanners, the build) are untouched. lc: ${x,,} where bash 4 has it, tr on macOS 3.2.
if [[ "${BASH_VERSINFO[0]}" -ge 4 ]]; then eval 'lc() { LC="${1,,}"; }'
else lc() { LC="$(printf '%s' "$1" | tr 'A-Z' 'a-z')"; }; fi
# abs_dir DIR -> ABS: what `cd DIR && pwd` prints; no fork for an absolute path without dot segments (a missing folder still fails in cd)
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
JSON=0
SPEC=""
WS_PATH=""
FAST=0
REQUIRE=0
EMIT=0
SCOPE="all"
SCOPE_GIVEN=0

usage() {
  cat >&2 <<'EOF'
usage: quality-gate.sh [--repo-root PATH] [--spec SPEC-ID] [--path DIR] [--scope LIST]
                       [--fast] [--require] [--emit] [--json]
  scopes: all lock build lint test coverage secrets deps sast static sbom image (default all)
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo-root|-RepoRoot) [[ $# -ge 2 ]] || { usage; exit 2; }; REPO_ROOT="$2"; shift 2 ;;
    --spec|-Spec) [[ $# -ge 2 ]] || { usage; exit 2; }; SPEC="$2"; shift 2 ;;
    --path|-Path) [[ $# -ge 2 ]] || { usage; exit 2; }; WS_PATH="$2"; shift 2 ;;
    --scope|-Scope) [[ $# -ge 2 ]] || { usage; exit 2; }; SCOPE="$2"; SCOPE_GIVEN=1; shift 2 ;;
    --json|-Json) JSON=1; shift ;;
    --fast|-Fast) FAST=1; shift ;;
    --require|-Require) REQUIRE=1; shift ;;
    --emit|-Emit) EMIT=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "error: unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done

die_env() { echo "error: $*" >&2; exit 2; }

if [[ -z "$REPO_ROOT" ]]; then
  PARENT="$(dirname "$SCRIPT_DIR")"
  if [[ "$(basename "$PARENT")" == ".KCC" ]]; then REPO_ROOT="$(dirname "$PARENT")"; else REPO_ROOT="$PARENT"; fi
fi
[[ -d "$REPO_ROOT" ]] || die_env "repo root not found: $REPO_ROOT"
abs_dir "$REPO_ROOT"; REPO_ROOT="$ABS"

if [[ -n "$SPEC" && ! "$SPEC" =~ ^SPEC-[0-9A-Za-z]+$ ]]; then die_env "invalid --spec '$SPEC' (expected SPEC-{ID})"; fi
lc "$SCOPE"; SCOPE="${LC// /}"
for s in ${SCOPE//,/ }; do
  case "$s" in all|lock|build|lint|test|coverage|secrets|deps|sast|static|sbom|image) ;; *) die_env "unknown scope '$s'";; esac
done
if [[ $FAST -eq 1 ]]; then SCOPE="secrets"; fi
in_scope() { [[ ",$SCOPE," == *",all,"* || ",$SCOPE," == *",$1,"* ]]; }
SCOPE_SOURCE="option"; [[ "${SCOPE_GIVEN:-0}" -eq 1 || $FAST -eq 1 ]] || SCOPE_SOURCE="default (all)"
# The architect decides which gates apply (architecture/quality-gates.md), the planner maps them in plan.md -> ## Gates coverage
# (check:QG-ID tokens; PLAN-007). Without --scope, a spec's gate runs exactly the checks that table covers, so a gate the
# architecture excluded (round 12: image scans for a local tool) is reported as out of scope, not as a failure. No table: all.
plan_scope() { # -> prints the scope list derived from plan.md, or nothing
  local plan="${SPEC_DIR:-}/plan.md" tbl ids out="" id n
  [[ -n "${SPEC_DIR:-}" && -f "$plan" ]] || return 0
  tbl="$(awk '/^## Gates coverage/{p=1; next} p && /^## /{exit} p' "$plan" | tr -d '\r')"
  [[ -n "$tbl" ]] || return 0
  ids="$(printf '%s\n' "$tbl" | grep -oE 'check:QG-[A-Z]+' | sed 's/^check://' | sort -u)"
  if printf '%s\n' "$tbl" | grep -qE '^\|[[:space:]]*QG-QUALITY[[:space:]]*\|'; then ids="$ids"$'\n'"QG-LOCK"$'\n'"QG-BUILD"$'\n'"QG-LINT"$'\n'"QG-TEST"$'\n'"QG-COV"$'\n'"QG-SECRETS"$'\n'"QG-DEPS"$'\n'"QG-SAST"; fi
  if printf '%s\n' "$tbl" | grep -qE '^\|[[:space:]]*QG-STATIC[[:space:]]*\|'; then ids="$ids"$'\n'"QG-STATIC"; fi
  while IFS= read -r id; do
    case "$id" in
      QG-LOCK) n=lock;; QG-BUILD) n=build;; QG-LINT) n=lint;; QG-TEST) n=test;; QG-COV) n=coverage;; QG-SECRETS) n=secrets;;
      QG-DEPS) n=deps;; QG-SAST) n=sast;; QG-STATIC) n=static;; QG-SBOM) n=sbom;; QG-IMAGE) n=image;; *) continue;;
    esac
    case ",$out," in *",$n,"*) ;; *) out="${out:+$out,}$n";; esac
  done <<<"$ids"
  printf '%s' "$out"
}

# ---------------------------------------------------------------- JSON helpers
json_escape_v() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\r'/\\r}"
  JE="${s//$'\t'/\\t}"
}
json_escape() { json_escape_v "$1"; printf '%s' "$JE"; }
jstr_v() { if [[ -z "$1" ]]; then JS=null; else json_escape_v "$1"; JS="\"$JE\""; fi; }
jstr() { jstr_v "$1"; printf '%s' "$JS"; }
# pjn FORMAT ARGS... -> PJ: printf where %j is the next argument as jstr (null when empty) and %s is it as is; no command substitution
pjn() {
  local fmt="$1" out="" a head; shift
  while [[ "$fmt" == *%[js]* ]]; do
    head="${fmt%%%[js]*}"; a="${fmt:${#head}+1:1}"; fmt="${fmt:${#head}+2}"
    out+="$head"
    if [[ "$a" == j ]]; then jstr_v "${1-}"; out+="$JS"; else out+="${1-}"; fi
    shift || true
  done
  PJ="$out$fmt"
}

# Flatten a JSON document into "path<TAB>scalar" lines (no jq).
AWK_FLAT='
function skip() { while (pos <= n && index(" \t\r\n", substr(s, pos, 1)) > 0) pos++ }
function rstr(   c, nx, out) {
  pos++; out = ""
  while (pos <= n) {
    c = substr(s, pos, 1)
    if (c == "\\") {
      nx = substr(s, pos + 1, 1)
      if (nx == "n") out = out " "; else if (nx == "t") out = out " "; else if (nx == "r") out = out ""
      else if (nx == "u") { out = out "?"; pos += 4 } else out = out nx
      pos += 2; continue
    }
    if (c == "\"") { pos++; return out }
    out = out c; pos++
  }
  return out
}
function val(path,   c, k, i, st, tok) {
  skip(); if (pos > n) return
  c = substr(s, pos, 1)
  if (c == "{") {
    pos++; skip()
    if (substr(s, pos, 1) == "}") { pos++; return }
    while (pos <= n) {
      skip(); k = rstr(); skip(); pos++
      val((path == "" ? k : path "." k))
      skip(); c = substr(s, pos, 1); pos++
      if (c != ",") return
    }
    return
  }
  if (c == "[") {
    pos++; skip()
    if (substr(s, pos, 1) == "]") { pos++; return }
    i = 0
    while (pos <= n) {
      val(path "[" i "]"); i++
      skip(); c = substr(s, pos, 1); pos++
      if (c != ",") return
    }
    return
  }
  if (c == "\"") { tok = rstr(); print path "\t" tok; return }
  st = pos
  while (pos <= n && index(",}] \t\r\n", substr(s, pos, 1)) == 0) pos++
  tok = substr(s, st, pos - st); print path "\t" tok
}
{ s = s $0 "\n" }
END { n = length(s); pos = 1; val("") }
'
json_flatten_file() { [[ -f "$1" ]] && awk "$AWK_FLAT" "$1" 2>/dev/null || true; }
# flat_get_v FLAT KEY -> FGV: the last value of KEY ("" when absent or null). A bash pattern match on the flat text instead of an awk
# per lookup (`$1 == k { v = $2 } END { if (v != "" && v != "null") print v }`).
flat_get_v() {
  local t=$'\n'"$1" k=$'\n'"$2"$'\t'
  FGV=""
  if [[ "$t" == *"$k"* ]]; then
    t="${t##*"$k"}"; t="${t%%$'\n'*}"; FGV="${t%%$'\t'*}"
    if [[ "$FGV" == "null" ]]; then FGV=""; fi
  fi
}
flat_get() { flat_get_v "$1" "$2"; if [[ -n "$FGV" ]]; then printf '%s\n' "$FGV"; fi; }

# ---------------------------------------------------------------- settings
SETTINGS_FILE="$REPO_ROOT/.KCC/settings.json"
SETTINGS_FLAT="$(json_flatten_file "$SETTINGS_FILE")"
setting_v() { flat_get_v "$SETTINGS_FLAT" "$1"; if [[ -n "$FGV" ]]; then SV="$FGV"; else SV="${2:-}"; fi; }
setting() { setting_v "$1" "${2:-}"; printf '%s' "$SV"; }

setting_v quality.coverage_min_pct 80; COV_MIN="$SV"
COV_SRC="settings.quality.coverage_min_pct"
[[ -f "$SETTINGS_FILE" ]] || COV_SRC="default"
setting_v quality.fail_on.dependencies high; lc "$SV"; FAIL_DEPS="$LC"
# The npm audit gate covers what ships; dev-only advisories gate only when quality.audit_dev_dependencies is true.
setting_v quality.audit_dev_dependencies false; lc "$SV"; AUDIT_DEV="$LC"
setting_v quality.fail_on.sast error; lc "$SV"; FAIL_SAST="$LC"
# local (semgrep on PATH) or docker (semgrep/semgrep image; Windows has no native semgrep).
setting_v quality.scanners.sast_runner local; lc "$SV"; SAST_RUNNER="$LC"
setting_v quality.scanners.sast semgrep; lc "$SV"; SAST_TOOL="$LC"
setting_v quality.sast_rules auto; SAST_RULES="$SV"
setting_v quality.fail_on.secrets any; lc "$SV"; FAIL_SECRETS="$LC"

cov_override_from() { # file -> the number of its last `coverage_min_pct: N` (grep -Eo | tail | grep -Eo, in bash)
  local t rest v="" re='coverage_min_pct:[[:blank:]]*([0-9]+(\.[0-9]+)?)'
  [[ -f "$1" ]] || return 0
  t="$(<"$1")" 2>/dev/null || return 0
  rest="$t"
  while [[ "$rest" =~ $re ]]; do v="${BASH_REMATCH[1]}"; rest="${rest#*"${BASH_REMATCH[0]}"}"; done
  if [[ -n "$v" ]]; then printf '%s\n' "$v"; fi
}
if [[ -f "$REPO_ROOT/architecture/quality-gates.md" ]]; then
  v="$(cov_override_from "$REPO_ROOT/architecture/quality-gates.md")"
  if [[ -n "$v" ]]; then COV_MIN="$v"; COV_SRC="architecture/quality-gates.md"; fi
fi
if [[ "$COV_SRC" != "architecture/quality-gates.md" && -d "$REPO_ROOT/architecture/adrs" ]]; then
  for f in "$REPO_ROOT/architecture/adrs"/*.md; do
    [[ -f "$f" ]] || continue
    f="${f##*/}"
    v="$(cov_override_from "$REPO_ROOT/architecture/adrs/$f")"
    if [[ -n "$v" ]]; then COV_MIN="$v"; COV_SRC="architecture/adrs/$f"; fi
  done
fi

sev_threshold() { # name -> CVSS floor
  case "$1" in
    critical) echo 9.0 ;; high) echo 7.0 ;; medium|moderate) echo 4.0 ;; low) echo 0.1 ;; *) echo 0 ;;
  esac
}
DEPS_FLOOR="$(sev_threshold "$FAIL_DEPS")"

rel() {
  local p="$1"
  if [[ "$p" == "$REPO_ROOT" ]]; then printf '.'
  elif [[ "$p" == "$REPO_ROOT/"* ]]; then printf '%s' "${p#"$REPO_ROOT"/}"
  elif [[ "$p" == /* ]]; then native_path "$p"
  else printf '%s' "$p"; fi
}
# rel_v PATH -> RELV: rel without the command substitution
rel_v() {
  local p="$1"
  if [[ "$p" == "$REPO_ROOT" ]]; then RELV='.'
  elif [[ "$p" == "$REPO_ROOT/"* ]]; then RELV="${p#"$REPO_ROOT"/}"
  elif [[ "$p" == /* ]]; then RELV="$(native_path "$p")"
  else RELV="$p"; fi
}

# ---------------------------------------------------------------- workspace
SPEC_DIR=""
IDEA_ID=""
OUT_DIR=""
WS=""
if [[ -n "$SPEC" ]]; then
  [[ -d "$REPO_ROOT/specs" ]] || die_env "no specs/ folder under $REPO_ROOT"
  SPEC_DIR="$(find "$REPO_ROOT/specs" -maxdepth 3 -type d \( -name "$SPEC-*" -o -name "$SPEC" \) 2>/dev/null | head -n 1 || true)"
  [[ -n "$SPEC_DIR" ]] || die_env "spec $SPEC not found under specs/"
  parent="$(basename "$(dirname "$SPEC_DIR")")"
  if [[ "$parent" =~ ^IDEA-([0-9A-Za-z]+)- ]]; then IDEA_ID="${BASH_REMATCH[1]}"; fi
  if [[ -z "$IDEA_ID" ]]; then
    IDEA_ID="$(grep -hEo 'IDEA-[0-9]+' "$SPEC_DIR"/*.md 2>/dev/null | head -n 1 | sed 's/^IDEA-//' || true)"
  fi
  [[ -n "$IDEA_ID" ]] || die_env "cannot resolve IDEA id for $SPEC"
  OUT_DIR="$REPO_ROOT/TestResults/IDEA-$IDEA_ID/$SPEC"
  if [[ -z "$WS_PATH" ]]; then
    WS="$(find "$REPO_ROOT/src" -maxdepth 1 -type d \( -name "IDEA-$IDEA_ID-*" -o -name "IDEA-$IDEA_ID" \) 2>/dev/null | head -n 1 || true)"
    [[ -n "$WS" ]] || die_env "no workspace src/IDEA-$IDEA_ID-*/ for $SPEC (use --path)"
  fi
fi
if [[ -n "$WS_PATH" ]]; then
  [[ -d "$WS_PATH" ]] || die_env "workspace path not found: $WS_PATH"
  WS="$(cd "$WS_PATH" && pwd)"
fi
[[ -n "$WS" ]] || WS="$REPO_ROOT"

if [[ -n "$OUT_DIR" ]]; then
  ART="$OUT_DIR/quality-gate-artifacts"
  rm -rf "$ART" 2>/dev/null || true   # own output; keeps reruns idempotent
else
  ART="${TMPDIR:-/tmp}/kcc-quality-gate-$$"
fi
mkdir -p "$ART"

# ---------------------------------------------------------------- check registry
C_ID=(); C_NAME=(); C_STACK=(); C_PROJ=(); C_STATUS=(); C_SEV=(); C_CMD=(); C_RC=(); C_MSG=(); C_OWNER=(); C_EVID=()
MISSING=""
add_check() { # id name stack proj status severity cmd rc message owner evidence
  C_ID+=("$1"); C_NAME+=("$2"); C_STACK+=("$3"); C_PROJ+=("$4"); C_STATUS+=("$5"); C_SEV+=("$6")
  C_CMD+=("$7"); C_RC+=("$8"); C_MSG+=("$9"); C_OWNER+=("${10}"); C_EVID+=("${11}")
}
note_missing() { case ",$MISSING," in *",$1,"*) ;; *) MISSING="${MISSING:+$MISSING,}$1" ;; esac; }
# count_lines_v FILE -> CL: wc -l (newline characters), without the processes
count_lines_v() { local n=0 l; if [[ -f "$1" ]]; then while IFS= read -r l; do n=$((n + 1)); done < "$1"; fi; CL="$n"; }
# count_matches_v FILE ERE -> CL: `grep -oE ERE FILE | wc -l` (every match of the expression, not every line); a big file takes the original pipeline
count_matches_v() {
  local t rest re="$2"
  CL=0
  [[ -f "$1" ]] || return 0
  t="$(<"$1")"
  if [[ ${#t} -gt 200000 ]]; then CL="$(grep -Eo -e "$re" "$1" 2>/dev/null | wc -l | tr -d ' ' || true)"; return 0; fi
  rest="$t"
  while [[ "$rest" =~ $re ]]; do CL=$((CL + 1)); rest="${rest#*"${BASH_REMATCH[0]}"}"; done
}
defer_check() { # id name stack proj tool message
  note_missing "$5"
  if [[ $REQUIRE -eq 1 ]]; then
    add_check "$1" "$2" "$3" "$4" fail error "" "" "$6: required tool '$5' is missing (--require)" human "tool-missing:$5"
  else
    add_check "$1" "$2" "$3" "$4" deferred warning "" "" "$6: tool '$5' is missing; deferred (not a pass)" human "tool-missing:$5"
  fi
}
have() { command -v "$1" >/dev/null 2>&1; }
# Paths handed to native tools: mixed form (E:/x) on MSYS/Cygwin, unchanged elsewhere.
# A drive mount (/e/x -> E:/x) is converted by bash itself; anything else, and bash 3.2, asks cygpath (one fork and exec per call).
ART_N=""
native_path_v() {
  if command -v cygpath >/dev/null 2>&1; then
    if [[ -n "$ART_N" && "$1" == "$ART"/* ]]; then NP="$ART_N${1#"$ART"}"   # the artifacts folder was converted once
    elif [[ "${BASH_VERSINFO[0]}" -ge 4 && "$1/" != *"/../"* && "$1/" != *"/./"* && "$1" != *//* && "$1" =~ ^/([A-Za-z])(/.*)?$ && -d "/${BASH_REMATCH[1]}" ]]; then
      local dl="${BASH_REMATCH[1]}" dr="${BASH_REMATCH[2]:-/}"
      NP="${dl^^}:$dr"
    else NP="$(cygpath -m "$1")"; fi
  else NP="$1"; fi
}
native_path() { native_path_v "$1"; printf '%s' "$NP"; }
native_path_v "$ART"; ART_N="$NP"

LOGN=0
LAST_LOG=""
run_in() { # dir cmd... -> rc ; output to LAST_LOG
  local dir="$1"; shift
  LOGN=$((LOGN + 1))
  LAST_LOG="$ART/log-$LOGN.txt"
  local rc=0
  ( cd "$dir" && "$@" ) >"$LAST_LOG" 2>&1 </dev/null || rc=$?
  return $rc
}
# run_split: like run_in, but stdout -> LAST_OUT (clean JSON) and stderr -> LAST_LOG
LAST_OUT=""
run_split() {
  local dir="$1"; shift
  LOGN=$((LOGN + 1))
  LAST_LOG="$ART/log-$LOGN.txt"; LAST_OUT="$ART/out-$LOGN.json"
  local rc=0
  ( cd "$dir" && "$@" ) >"$LAST_OUT" 2>"$LAST_LOG" </dev/null || rc=$?
  return $rc
}
show_cmd() { local out="" a; for a in "$@"; do if [[ "$a" == *" "* ]]; then out="$out \"$a\""; else out="$out $a"; fi; done; printf '%s' "${out# }"; }

# ---------------------------------------------------------------- python resolver
PY=""
resolve_python() {
  [[ -n "$PY" ]] && return 0
  local c
  for c in python3 python; do
    if have "$c" && "$c" --version 2>&1 | grep -q '^Python 3'; then PY="$c"; return 0; fi
  done
  return 1
}

# ---------------------------------------------------------------- stack discovery
PRUNE_NAMES=(node_modules vendor target bin obj dist build out TestResults __pycache__ venv .venv)
discover_projects() {
  local expr=() n f b st d
  local -a E_ST=() E_DIR=() K_ST=() K_DIR=()
  local cnt=0 i j k tmp dup
  for n in "${PRUNE_NAMES[@]}"; do expr+=( -name "$n" -o ); done
  # one entry per (stack, folder) that holds a marker file: what the find | while | sort -u pipeline produced, in bash
  while IFS= read -r f; do
    b="${f##*/}"
    case "$b" in
      package.json) st=node ;; pyproject.toml|requirements.txt|setup.py) st=python ;;
      *.sln|*.csproj|*.fsproj) st=dotnet ;; go.mod) st=go ;; Cargo.toml) st=rust ;;
      pom.xml|build.gradle|build.gradle.kts) st=java ;; CMakeLists.txt) st=cpp ;; composer.json) st=php ;;
      *) continue ;;
    esac
    d="${f%/*}"
    dup=0
    for ((i = 0; i < cnt; i++)); do if [[ "${E_ST[i]}" == "$st" && "${E_DIR[i]}" == "$d" ]]; then dup=1; break; fi; done
    if [[ $dup -eq 0 ]]; then E_ST[cnt]="$st"; E_DIR[cnt]="$d"; cnt=$((cnt + 1)); fi
  done < <(find "$WS" -maxdepth 4 \( -type d ! -path "$WS" \( "${expr[@]}" -name '.?*' \) \) -prune -o -type f \( \
    -name package.json -o -name pyproject.toml -o -name requirements.txt -o -name setup.py -o \
    -name '*.sln' -o -name '*.csproj' -o -name '*.fsproj' -o -name go.mod -o -name Cargo.toml -o \
    -name pom.xml -o -name build.gradle -o -name build.gradle.kts -o -name CMakeLists.txt -o \
    -name composer.json \) -print 2>/dev/null)
  # shortest folder first, then by folder, then by stack (sort -k1,1n -k3,3 -k2,2 on length, stack, folder)
  for ((i = 1; i < cnt; i++)); do
    st="${E_ST[i]}"; d="${E_DIR[i]}"; j=$((i - 1))
    while [[ $j -ge 0 ]]; do
      if [[ ${#E_DIR[j]} -gt ${#d} || ( ${#E_DIR[j]} -eq ${#d} && ( "${E_DIR[j]}" > "$d" || ( "${E_DIR[j]}" == "$d" && "${E_ST[j]}" > "$st" ) ) ) ]]; then
        E_ST[j + 1]="${E_ST[j]}"; E_DIR[j + 1]="${E_DIR[j]}"; j=$((j - 1))
      else break; fi
    done
    E_ST[j + 1]="$st"; E_DIR[j + 1]="$d"
  done
  # drop a project that sits inside a kept project of the same stack
  k=0
  for ((i = 0; i < cnt; i++)); do
    dup=0
    for ((j = 0; j < k; j++)); do
      if [[ "${K_ST[j]}" == "${E_ST[i]}" && "${E_DIR[i]}/" == "${K_DIR[j]}/"* && "${E_DIR[i]}" != "${K_DIR[j]}" ]]; then dup=1; break; fi
    done
    if [[ $dup -eq 0 ]]; then K_ST[k]="${E_ST[i]}"; K_DIR[k]="${E_DIR[i]}"; k=$((k + 1)); printf '%s\t%s\n' "${E_ST[i]}" "${E_DIR[i]}"; fi
  done
}

dialect_stacks() {
  [[ -n "$SPEC_DIR" ]] || return 0
  grep -rhoE '(backend|fullstack|frontend|embedded|mobile|scripting)-(nodejs|mern|nestjs|react|angular|vanilla-js|python|csharp|dotnet|go|rust|java|cpp|c|php|flutter|kotlin|swift|ruby|lua)\b' "$SPEC_DIR" 2>/dev/null | sort -u | while IFS= read -r d; do
    case "$d" in
      backend-nodejs|fullstack-mern|fullstack-nestjs|frontend-react|frontend-angular|frontend-vanilla-js) echo "node $d" ;;
      backend-python|fullstack-python) echo "python $d" ;;
      backend-csharp|fullstack-dotnet) echo "dotnet $d" ;;
      backend-go|fullstack-go) echo "go $d" ;;
      backend-rust|embedded-rust) echo "rust $d" ;;
      backend-java) echo "java $d" ;;
      backend-cpp|embedded-c|embedded-cpp) echo "cpp $d" ;;
      backend-php) echo "php $d" ;;
      mobile-flutter) echo "flutter $d" ;;
      mobile-kotlin) echo "kotlin $d" ;;
      mobile-swift) echo "swift $d" ;;
      backend-ruby) echo "ruby $d" ;;
      scripting-lua) echo "lua $d" ;;
    esac
  done
}

find_up() { # dir name... -> first match in dir or ancestors up to WS
  local d="$1"; shift
  local n
  while :; do
    for n in "$@"; do if [[ -e "$d/$n" ]]; then printf '%s' "$d/$n"; return 0; fi; done
    [[ "$d" == "$WS" || "$d" == "/" || "$d" == "." ]] && return 1
    local p; p="$(dirname "$d")"
    [[ "$p" == "$d" ]] && return 1
    d="$p"
  done
}

# ---------------------------------------------------------------- coverage parsers
pct_ge() { awk -v a="$1" -v b="$2" 'BEGIN { exit !((a + 0) >= (b + 0)) }'; }
cov_node() { # dir
  local d="$1" f v
  f="$d/coverage/coverage-summary.json"
  if [[ -f "$f" ]]; then
    v="$(tr -d '\r\n' <"$f" | grep -Eo '"total"[[:space:]]*:[[:space:]]*\{[[:space:]]*"lines"[[:space:]]*:[[:space:]]*\{[^}]*\}' | grep -Eo '"pct"[[:space:]]*:[[:space:]]*[0-9.]+' | grep -Eo '[0-9.]+$' | head -n 1 || true)"
    [[ -n "$v" ]] && { printf '%s' "$v"; return 0; }
  fi
  f="$d/coverage/lcov.info"
  [[ -f "$f" ]] && { cov_lcov "$f"; return 0; }
  return 0
}
cov_lcov() { awk -F: '/^LF:/ { lf += $2 } /^LH:/ { lh += $2 } END { if (lf > 0) printf "%.2f", (lh * 100) / lf }' "$1" 2>/dev/null || true; }
cov_py_json() { [[ -f "$1" ]] || return 0; tr -d '\r\n' <"$1" | grep -Eo '"totals"[[:space:]]*:[[:space:]]*\{[^}]*\}' | grep -Eo '"percent_covered"[[:space:]]*:[[:space:]]*[0-9.]+' | tail -n 1 | grep -Eo '[0-9.]+$' || true; }
cov_cobertura() { [[ -f "$1" ]] || return 0; grep -Eo '<coverage[^>]*line-rate="[0-9.]+"' "$1" | head -n 1 | grep -Eo 'line-rate="[0-9.]+"' | grep -Eo '[0-9.]+' | awk '{ printf "%.2f", $1 * 100 }' || true; }
cov_jacoco_csv() { [[ -f "$1" ]] || return 0; awk -F, 'NR > 1 { m += $8; c += $9 } END { if (m + c > 0) printf "%.2f", (c * 100) / (m + c) }' "$1" 2>/dev/null || true; }
cov_generic() { [[ -f "$1" ]] || return 0; grep -Eo '[0-9]+(\.[0-9]+)?%' "$1" | tail -n 1 | tr -d '%' || true; }

# ---------------------------------------------------------------- per-check runner
# run_step ID NAME STACK PROJ DIR OWNER cmd...   (records pass/fail from exit code)
run_step() {
  local id="$1" name="$2" st="$3" proj="$4" dir="$5" owner="$6"; shift 6
  local rc=0 shown; shown="$(show_cmd "$@")"
  run_in "$dir" "$@" || rc=$?
  if [[ $rc -eq 0 ]]; then
    add_check "$id" "$name" "$st" "$proj" pass none "$shown" "$rc" "ok" "$owner" "$(rel "$LAST_LOG")"
  else
    add_check "$id" "$name" "$st" "$proj" fail error "$shown" "$rc" "command failed (exit $rc); see log" "$owner" "$(rel "$LAST_LOG")"
  fi
  return $rc
}
override_cmd() { setting "quality.commands.$1.$2" ""; }
# run_override STACK CHECK ID NAME PROJ DIR -> 0 handled (sets OV_RC), 1 no override
OV_RC=0
run_override() {
  local st="$1" ck="$2" id="$3" name="$4" proj="$5" dir="$6" ov
  ov="$(override_cmd "$st" "$ck")"
  [[ -n "$ov" ]] || return 1
  if [[ "$ov" == "skip" ]]; then
    add_check "$id" "$name" "$st" "$proj" skipped warning "" "" "skipped by settings quality.commands.$st.$ck" human "settings"
    OV_RC=0; return 0
  fi
  OV_RC=0
  run_step "$id" "$name" "$st" "$proj" "$dir" implementer sh -c "$ov" || OV_RC=$?
  return 0
}

record_cov() { # stack proj pct source-evidence command
  local st="$1" proj="$2" pct="$3" evid="$4" cmd="${5:-}"
  if [[ -z "$pct" ]]; then
    add_check QG-COV coverage "$st" "$proj" fail error "$cmd" "" "no coverage report found; configure a coverage command (quality.commands.$st.coverage) or reporter" implementer "$evid"
  elif pct_ge "$pct" "$COV_MIN"; then
    add_check QG-COV coverage "$st" "$proj" pass none "$cmd" "" "coverage $pct% >= $COV_MIN% ($COV_SRC)" implementer "$evid"
  else
    add_check QG-COV coverage "$st" "$proj" fail error "$cmd" "" "coverage $pct% < $COV_MIN% ($COV_SRC)" implementer "$evid"
  fi
}

# cov_from_override STACK PROJ DIR COMMAND -> runs a settings coverage command, parses the last NN% of its output
cov_from_override() {
  local st="$1" proj="$2" dir="$3" ov="$4" rc=0
  if [[ "$ov" == "skip" ]]; then
    add_check QG-COV coverage "$st" "$proj" skipped warning "" "" "skipped by settings quality.commands.$st.coverage" human "settings"; return 0
  fi
  run_in "$dir" sh -c "$ov" || rc=$?
  if [[ $rc -ne 0 ]]; then add_check QG-COV coverage "$st" "$proj" fail error "$ov" "$rc" "coverage command failed (exit $rc)" implementer "$(rel "$LAST_LOG")"; return 0; fi
  record_cov "$st" "$proj" "$(cov_generic "$LAST_LOG")" "$(rel "$LAST_LOG")" "$ov"
}

# ---------------------------------------------------------------- stacks
# node_ws_root_lock -> the lockfile of an ancestor npm/yarn/pnpm workspace root (above WS, up to the repository root), or nothing.
node_ws_root_lock() {
  local a p n
  a="$(dirname "$WS")"
  while [[ -n "$a" && ${#a} -ge ${#REPO_ROOT} ]]; do
    if { [[ -f "$a/package.json" ]] && grep -q '"workspaces"' "$a/package.json"; } || [[ -f "$a/pnpm-workspace.yaml" ]]; then
      for n in package-lock.json npm-shrinkwrap.json pnpm-lock.yaml yarn.lock bun.lockb bun.lock; do if [[ -e "$a/$n" ]]; then printf '%s' "$a/$n"; return 0; fi; done
    fi
    [[ "$a" == "$REPO_ROOT" ]] && break
    p="$(dirname "$a")"; [[ "$p" == "$a" ]] && break
    a="$p"
  done
  return 0
}

check_lock() { # stack proj dir
  local st="$1" proj="$2" dir="$3" f=""
  in_scope lock || return 0
  case "$st" in
    node)
      f="$(find_up "$dir" package-lock.json npm-shrinkwrap.json pnpm-lock.yaml yarn.lock bun.lockb bun.lock || true)"
      # A monorepo keeps ONE lockfile at the workspace root, which can sit above the spec's src folder (npm/yarn/pnpm
      # workspaces). Accept it from an ancestor, up to the repository root, when that ancestor declares workspaces.
      if [[ -z "$f" ]]; then f="$(node_ws_root_lock)"; fi
      ;;
    python)
      f="$(find_up "$dir" poetry.lock uv.lock Pipfile.lock pdm.lock || true)"
      if [[ -z "$f" && -f "$dir/requirements.txt" ]]; then
        local unpinned
        unpinned="$(grep -vE '^[[:space:]]*(#|$|-)' "$dir/requirements.txt" | tr -d '\r' | grep -vE '==' | head -n 3 || true)"
        if [[ -z "$unpinned" ]]; then f="$dir/requirements.txt"; else
          add_check QG-LOCK lockfile "$st" "$proj" fail error "" "" "requirements.txt has unpinned entries (use == pins, or a lockfile: uv.lock/poetry.lock)" implementer "$(rel "$dir/requirements.txt")"
          return 0
        fi
      fi ;;
    dotnet) f="$(find "$dir" -maxdepth 4 -name packages.lock.json -not -path '*/obj/*' 2>/dev/null | head -n 1 || true)" ;;
    go)
      f="$(find_up "$dir" go.sum || true)"
      if [[ -z "$f" ]] && ! grep -qE '^[[:space:]]*require' "$dir/go.mod" 2>/dev/null; then
        add_check QG-LOCK lockfile "$st" "$proj" pass none "" "" "go.mod has no requirements; go.sum not needed" implementer "$(rel "$dir/go.mod")"; return 0
      fi ;;
    rust) f="$(find_up "$dir" Cargo.lock || true)" ;;
    java)
      if [[ -f "$dir/pom.xml" ]]; then
        add_check QG-LOCK lockfile "$st" "$proj" skipped warning "" "" "maven has no native lockfile; pin versions and rely on QG-DEPS" implementer "$(rel "$dir/pom.xml")"; return 0
      fi
      f="$(find_up "$dir" gradle.lockfile || true)"
      [[ -z "$f" && -d "$dir/gradle/dependency-locks" ]] && f="$dir/gradle/dependency-locks" ;;
    cpp)
      if [[ -f "$dir/conan.lock" ]]; then f="$dir/conan.lock"
      elif [[ -f "$dir/vcpkg.json" ]]; then
        if grep -q 'builtin-baseline' "$dir/vcpkg.json" || [[ -f "$dir/vcpkg-configuration.json" ]]; then f="$dir/vcpkg.json"; fi
      elif [[ ! -f "$dir/conanfile.txt" && ! -f "$dir/conanfile.py" ]]; then
        add_check QG-LOCK lockfile "$st" "$proj" skipped none "" "" "no C/C++ package manager in use" implementer ""; return 0
      fi ;;
    php) f="$(find_up "$dir" composer.lock || true)" ;;
  esac
  if [[ -n "$f" ]]; then
    add_check QG-LOCK lockfile "$st" "$proj" pass none "" "" "lockfile present" implementer "$(rel "$f")"
  else
    add_check QG-LOCK lockfile "$st" "$proj" fail error "" "" "no lockfile for $st project; commit one for reproducible builds" implementer "$(rel "$dir")"
  fi
}

defer_project() { # stack proj tool
  local c
  for c in build lint test coverage; do
    in_scope "$c" || continue
    case "$c" in build) defer_check QG-BUILD build "$1" "$2" "$3" "$1 build" ;;
      lint) defer_check QG-LINT lint "$1" "$2" "$3" "$1 lint" ;;
      test) defer_check QG-TEST test "$1" "$2" "$3" "$1 tests" ;;
      coverage) defer_check QG-COV coverage "$1" "$2" "$3" "$1 coverage" ;; esac
  done
}

stack_node() { # proj dir idx
  local proj="$1" dir="$2" idx="$3" pm=npm flat
  if [[ -n "$(find_up "$dir" pnpm-lock.yaml || true)" ]]; then pm=pnpm
  elif [[ -n "$(find_up "$dir" yarn.lock || true)" ]]; then pm=yarn
  elif [[ -n "$(find_up "$dir" bun.lockb bun.lock || true)" ]]; then pm=bun; fi
  if ! have node; then defer_project node "$proj" node; return 0; fi
  if ! have "$pm"; then defer_project node "$proj" "$pm"; return 0; fi
  flat="$(json_flatten_file "$dir/package.json")"
  local has_deps; has_deps="$(printf '%s\n' "$flat" | grep -cE '^(dependencies|devDependencies)\.' || true)"
  if [[ "$has_deps" -gt 0 && -z "$(find_up "$dir" node_modules || true)" ]]; then
    local c
    for c in build lint test coverage; do
      in_scope "$c" || continue
      local id; case "$c" in build) id=QG-BUILD;; lint) id=QG-LINT;; test) id=QG-TEST;; coverage) id=QG-COV;; esac
      add_check "$id" "$c" node "$proj" fail error "" "" "dependencies not installed (node_modules missing); run '$pm install' / '$pm ci' first" human "$(rel "$dir")"
    done
    return 0
  fi
  local test_ok=1
  if in_scope build; then
    if ! run_override node build QG-BUILD build "$proj" "$dir"; then
      if [[ -n "$(flat_get "$flat" scripts.build)" ]]; then run_step QG-BUILD build node "$proj" "$dir" implementer "$pm" run build || true
      else add_check QG-BUILD build node "$proj" skipped none "" "" "no build script in package.json" implementer "$(rel "$dir/package.json")"; fi
    fi
  fi
  if in_scope lint; then
    if ! run_override node lint QG-LINT lint "$proj" "$dir"; then
      if [[ -n "$(flat_get "$flat" scripts.lint)" ]]; then run_step QG-LINT lint node "$proj" "$dir" implementer "$pm" run lint || true
      else add_check QG-LINT lint node "$proj" skipped warning "" "" "no lint script in package.json" implementer "$(rel "$dir/package.json")"; fi
    fi
  fi
  if in_scope test; then
    if run_override node test QG-TEST test "$proj" "$dir"; then [[ $OV_RC -eq 0 ]] || test_ok=0
    elif [[ -n "$(flat_get "$flat" scripts.test)" ]]; then run_step QG-TEST test node "$proj" "$dir" implementer "$pm" run test || test_ok=0
    else add_check QG-TEST test node "$proj" fail error "" "" "no test script in package.json" implementer "$(rel "$dir/package.json")"; test_ok=0; fi
  fi
  if in_scope coverage; then
    if [[ $test_ok -eq 0 ]]; then add_check QG-COV coverage node "$proj" skipped none "" "" "tests did not pass; coverage not evaluated" implementer ""; return 0; fi
    local ov; ov="$(override_cmd node coverage)"
    if [[ "$ov" == "skip" ]]; then run_override node coverage QG-COV coverage "$proj" "$dir"; return 0; fi
    local cmd=() pct="" log=""
    if [[ -n "$ov" ]]; then cmd=(sh -c "$ov")
    elif [[ -n "$(flat_get "$flat" scripts.coverage)" ]]; then cmd=("$pm" run coverage)
    elif [[ -n "$(flat_get "$flat" 'scripts.test:coverage')" ]]; then cmd=("$pm" run test:coverage); fi
    if [[ ${#cmd[@]} -gt 0 ]]; then
      local rc=0; run_in "$dir" "${cmd[@]}" || rc=$?; log="$LAST_LOG"
      if [[ $rc -ne 0 ]]; then add_check QG-COV coverage node "$proj" fail error "$(show_cmd "${cmd[@]}")" "$rc" "coverage command failed (exit $rc)" implementer "$(rel "$log")"; return 0; fi
    fi
    pct="$(cov_node "$dir")"
    [[ -z "$pct" && -n "$log" ]] && pct="$(cov_generic "$log")"
    record_cov node "$proj" "$pct" "$(rel "$dir/coverage")" "$(if [[ ${#cmd[@]} -gt 0 ]]; then show_cmd "${cmd[@]}"; fi)"
  fi
}

stack_python() {
  local proj="$1" dir="$2" idx="$3"
  if ! resolve_python; then defer_project python "$proj" python; return 0; fi
  local test_ok=1 covjson="$ART/py-cov-$idx.json" cov_mode=none
  if in_scope build; then
    if ! run_override python build QG-BUILD build "$proj" "$dir"; then
      run_step QG-BUILD build python "$proj" "$dir" implementer "$PY" -m compileall -q -x '(^|[\\/])(\.venv|venv|node_modules|\.git|build|dist)([\\/]|$)' . || true
    fi
  fi
  if in_scope lint; then
    if ! run_override python lint QG-LINT lint "$proj" "$dir"; then
      if have ruff; then run_step QG-LINT lint python "$proj" "$dir" implementer ruff check . || true
      elif "$PY" -c 'import flake8' >/dev/null 2>&1; then run_step QG-LINT lint python "$proj" "$dir" implementer "$PY" -m flake8 --exclude .venv,venv,node_modules,build,dist . || true
      else defer_check QG-LINT lint python "$proj" ruff "python lint"; fi
    fi
  fi
  local has_pytest=0 has_cov=0 has_coverage=0
  "$PY" -c 'import pytest' >/dev/null 2>&1 && has_pytest=1
  "$PY" -c 'import pytest_cov' >/dev/null 2>&1 && has_cov=1
  "$PY" -c 'import coverage' >/dev/null 2>&1 && has_coverage=1
  if in_scope test; then
    if run_override python test QG-TEST test "$proj" "$dir"; then [[ $OV_RC -eq 0 ]] || test_ok=0
    else
      local tests; tests="$(find "$dir" -maxdepth 5 -mindepth 1 \( -name .venv -o -name venv -o -name node_modules -o -name '.?*' \) -prune -o -type f \( -name 'test_*.py' -o -name '*_test.py' \) -print 2>/dev/null | head -n 1 || true)"
      if [[ -z "$tests" ]]; then add_check QG-TEST test python "$proj" fail error "" "" "no tests found (test_*.py / *_test.py)" implementer "$(rel "$dir")"; test_ok=0
      elif [[ $has_pytest -eq 0 ]]; then defer_check QG-TEST test python "$proj" pytest "python tests"; test_ok=0; note_missing pytest-cov
      elif [[ $has_cov -eq 1 ]]; then cov_mode=pytestcov
        run_step QG-TEST test python "$proj" "$dir" implementer "$PY" -m pytest -q --cov=. "--cov-report=json:$(native_path "$covjson")" || test_ok=0
      elif [[ $has_coverage -eq 1 ]]; then cov_mode=coverage
        run_step QG-TEST test python "$proj" "$dir" implementer "$PY" -m coverage run -m pytest -q || test_ok=0
      else run_step QG-TEST test python "$proj" "$dir" implementer "$PY" -m pytest -q || test_ok=0; fi
    fi
  fi
  if in_scope coverage; then
    local ov; ov="$(override_cmd python coverage)"
    if [[ -n "$ov" ]]; then cov_from_override python "$proj" "$dir" "$ov"; return 0; fi
    if [[ $test_ok -eq 0 ]]; then
      if [[ $has_pytest -eq 0 ]]; then defer_check QG-COV coverage python "$proj" pytest-cov "python coverage"
      else add_check QG-COV coverage python "$proj" skipped none "" "" "tests did not pass; coverage not evaluated" implementer ""; fi
      return 0
    fi
    case "$cov_mode" in
      pytestcov) record_cov python "$proj" "$(cov_py_json "$covjson")" "$(rel "$covjson")" "pytest --cov" ;;
      coverage)
        local rc=0; run_in "$dir" "$PY" -m coverage json -o "$(native_path "$covjson")" || rc=$?
        record_cov python "$proj" "$(cov_py_json "$covjson")" "$(rel "$covjson")" "$PY -m coverage json" ;;
      *) defer_check QG-COV coverage python "$proj" pytest-cov "python coverage" ;;
    esac
  fi
}

stack_dotnet() {
  local proj="$1" dir="$2" idx="$3" target
  if ! have dotnet; then defer_project dotnet "$proj" dotnet; return 0; fi
  target="$(ls "$dir"/*.sln 2>/dev/null | head -n 1 || true)"
  [[ -n "$target" ]] || target="$(ls "$dir"/*.csproj "$dir"/*.fsproj 2>/dev/null | head -n 1 || true)"
  target="$(basename "$target")"
  local test_ok=1 res="$ART/dotnet-$idx"
  if in_scope build; then run_override dotnet build QG-BUILD build "$proj" "$dir" || run_step QG-BUILD build dotnet "$proj" "$dir" implementer dotnet build "$target" --nologo || true; fi
  if in_scope lint; then run_override dotnet lint QG-LINT lint "$proj" "$dir" || run_step QG-LINT lint dotnet "$proj" "$dir" implementer dotnet format "$target" --verify-no-changes || true; fi
  if in_scope test; then
    if run_override dotnet test QG-TEST test "$proj" "$dir"; then [[ $OV_RC -eq 0 ]] || test_ok=0
    else run_step QG-TEST test dotnet "$proj" "$dir" implementer dotnet test "$target" --nologo --collect "XPlat Code Coverage" --results-directory "$(native_path "$res")" || test_ok=0; fi
  fi
  if in_scope coverage; then
    if [[ $test_ok -eq 0 ]]; then add_check QG-COV coverage dotnet "$proj" skipped none "" "" "tests did not pass; coverage not evaluated" implementer ""; return 0; fi
    local f; f="$(find "$res" -name coverage.cobertura.xml 2>/dev/null | head -n 1 || true)"
    record_cov dotnet "$proj" "$(cov_cobertura "$f")" "$(rel "${f:-$res}")" "dotnet test --collect \"XPlat Code Coverage\""
  fi
}

stack_go() {
  local proj="$1" dir="$2" idx="$3"
  if ! have go; then defer_project go "$proj" go; return 0; fi
  local test_ok=1 prof="$ART/go-cover-$idx.out"
  if in_scope build; then run_override go build QG-BUILD build "$proj" "$dir" || run_step QG-BUILD build go "$proj" "$dir" implementer go build ./... || true; fi
  if in_scope lint; then run_override go lint QG-LINT lint "$proj" "$dir" || run_step QG-LINT lint go "$proj" "$dir" implementer go vet ./... || true; fi
  if in_scope test; then
    if run_override go test QG-TEST test "$proj" "$dir"; then [[ $OV_RC -eq 0 ]] || test_ok=0
    else run_step QG-TEST test go "$proj" "$dir" implementer go test ./... "-coverprofile=$(native_path "$prof")" || test_ok=0; fi
  fi
  if in_scope coverage; then
    if [[ $test_ok -eq 0 || ! -f "$prof" ]]; then add_check QG-COV coverage go "$proj" skipped none "" "" "tests did not pass or no profile; coverage not evaluated" implementer ""; return 0; fi
    local rc=0 pct=""; run_in "$dir" go tool cover "-func=$(native_path "$prof")" || rc=$?
    pct="$(grep -E '^total:' "$LAST_LOG" | grep -Eo '[0-9.]+%' | tr -d '%' || true)"
    record_cov go "$proj" "$pct" "$(rel "$prof")" "go tool cover -func"
  fi
}

stack_rust() {
  local proj="$1" dir="$2" idx="$3"
  if ! have cargo; then defer_project rust "$proj" cargo; return 0; fi
  local test_ok=1
  if in_scope build; then run_override rust build QG-BUILD build "$proj" "$dir" || run_step QG-BUILD build rust "$proj" "$dir" implementer cargo build || true; fi
  if in_scope lint; then
    if ! run_override rust lint QG-LINT lint "$proj" "$dir"; then
      if have cargo-clippy; then run_step QG-LINT lint rust "$proj" "$dir" implementer cargo clippy --all-targets -- -D warnings || true
      else defer_check QG-LINT lint rust "$proj" cargo-clippy "rust lint"; fi
    fi
  fi
  if in_scope test; then
    if run_override rust test QG-TEST test "$proj" "$dir"; then [[ $OV_RC -eq 0 ]] || test_ok=0
    else run_step QG-TEST test rust "$proj" "$dir" implementer cargo test || test_ok=0; fi
  fi
  if in_scope coverage; then
    if [[ $test_ok -eq 0 ]]; then add_check QG-COV coverage rust "$proj" skipped none "" "" "tests did not pass; coverage not evaluated" implementer ""; return 0; fi
    local ov; ov="$(override_cmd rust coverage)"
    if [[ -z "$ov" ]] && ! have cargo-llvm-cov; then defer_check QG-COV coverage rust "$proj" cargo-llvm-cov "rust coverage"; return 0; fi
    local rc=0 cmd=(cargo llvm-cov --summary-only); [[ -n "$ov" ]] && cmd=(sh -c "$ov")
    run_in "$dir" "${cmd[@]}" || rc=$?
    if [[ $rc -ne 0 ]]; then add_check QG-COV coverage rust "$proj" fail error "$(show_cmd "${cmd[@]}")" "$rc" "coverage command failed" implementer "$(rel "$LAST_LOG")"; return 0; fi
    local pct; pct="$(grep -E '^TOTAL' "$LAST_LOG" | grep -Eo '[0-9.]+%' | tail -n 1 | tr -d '%' || true)"
    [[ -n "$pct" ]] || pct="$(cov_generic "$LAST_LOG")"
    record_cov rust "$proj" "$pct" "$(rel "$LAST_LOG")" "$(show_cmd "${cmd[@]}")"
  fi
}

stack_java() {
  local proj="$1" dir="$2" idx="$3" tool=() kind=maven
  if [[ -f "$dir/pom.xml" ]]; then
    if [[ -f "$dir/mvnw" ]]; then tool=(sh ./mvnw); elif have mvn; then tool=(mvn); else defer_project java "$proj" mvn; return 0; fi
  else
    kind=gradle
    if [[ -f "$dir/gradlew" ]]; then tool=(sh ./gradlew); elif have gradle; then tool=(gradle); else defer_project java "$proj" gradle; return 0; fi
  fi
  if ! have java; then defer_project java "$proj" java; return 0; fi
  local test_ok=1
  if in_scope build; then
    if ! run_override java build QG-BUILD build "$proj" "$dir"; then
      if [[ $kind == maven ]]; then run_step QG-BUILD build java "$proj" "$dir" implementer "${tool[@]}" -B -q -DskipTests package || true
      else run_step QG-BUILD build java "$proj" "$dir" implementer "${tool[@]}" build -x test || true; fi
    fi
  fi
  if in_scope lint; then
    if ! run_override java lint QG-LINT lint "$proj" "$dir"; then
      if [[ $kind == gradle ]]; then run_step QG-LINT lint java "$proj" "$dir" implementer "${tool[@]}" check -x test || true
      else add_check QG-LINT lint java "$proj" skipped warning "" "" "no default maven lint; set quality.commands.java.lint (e.g. mvn checkstyle:check)" implementer ""; fi
    fi
  fi
  if in_scope test; then
    if run_override java test QG-TEST test "$proj" "$dir"; then [[ $OV_RC -eq 0 ]] || test_ok=0
    else run_step QG-TEST test java "$proj" "$dir" implementer "${tool[@]}" -B test || test_ok=0; fi
  fi
  if in_scope coverage; then
    if [[ $test_ok -eq 0 ]]; then add_check QG-COV coverage java "$proj" skipped none "" "" "tests did not pass; coverage not evaluated" implementer ""; return 0; fi
    local csv="$dir/target/site/jacoco/jacoco.csv"
    if [[ $kind == gradle ]]; then
      local rc=0; run_in "$dir" "${tool[@]}" jacocoTestReport || rc=$?
      csv="$dir/build/reports/jacoco/test/jacocoTestReport.csv"
    fi
    record_cov java "$proj" "$(cov_jacoco_csv "$csv")" "$(rel "$csv")" "jacoco csv"
  fi
}

stack_cpp() {
  local proj="$1" dir="$2" idx="$3" bdir="$ART/cmake-$idx"
  if ! have cmake; then defer_project cpp "$proj" cmake; return 0; fi
  local build_ok=1 test_ok=1
  if in_scope build || in_scope test; then
    if ! run_override cpp build QG-BUILD build "$proj" "$dir"; then
      local rc=0; run_in "$dir" cmake -S . -B "$(native_path "$bdir")" || rc=$?
      if [[ $rc -ne 0 ]]; then add_check QG-BUILD build cpp "$proj" fail error "cmake -S . -B <build>" "$rc" "cmake configure failed" implementer "$(rel "$LAST_LOG")"; build_ok=0
      else run_step QG-BUILD build cpp "$proj" "$dir" implementer cmake --build "$(native_path "$bdir")" || build_ok=0; fi
    else [[ $OV_RC -eq 0 ]] || build_ok=0; fi
  fi
  if in_scope lint; then run_override cpp lint QG-LINT lint "$proj" "$dir" || add_check QG-LINT lint cpp "$proj" skipped warning "" "" "no default C/C++ lint; set quality.commands.cpp.lint (e.g. clang-tidy)" implementer ""; fi
  if in_scope test; then
    if run_override cpp test QG-TEST test "$proj" "$dir"; then [[ $OV_RC -eq 0 ]] || test_ok=0
    elif [[ $build_ok -eq 0 ]]; then add_check QG-TEST test cpp "$proj" fail error "" "" "build failed; tests not run" implementer ""; test_ok=0
    elif have ctest; then run_step QG-TEST test cpp "$proj" "$dir" implementer ctest --test-dir "$(native_path "$bdir")" --output-on-failure --no-tests=error || test_ok=0
    else defer_check QG-TEST test cpp "$proj" ctest "cpp tests"; test_ok=0; fi
  fi
  if in_scope coverage; then
    if [[ $test_ok -eq 0 ]]; then add_check QG-COV coverage cpp "$proj" skipped none "" "" "tests did not pass; coverage not evaluated" implementer ""; return 0; fi
    local ov; ov="$(override_cmd cpp coverage)"
    if [[ -z "$ov" ]] && ! have gcovr; then defer_check QG-COV coverage cpp "$proj" gcovr "cpp coverage"; return 0; fi
    local rc=0 cmd=(gcovr -r . "$(native_path "$bdir")" --print-summary); [[ -n "$ov" ]] && cmd=(sh -c "$ov")
    run_in "$dir" "${cmd[@]}" || rc=$?
    local pct; pct="$(grep -E '^lines:' "$LAST_LOG" | grep -Eo '[0-9.]+%' | head -n 1 | tr -d '%' || true)"
    [[ -n "$pct" ]] || pct="$(cov_generic "$LAST_LOG")"
    record_cov cpp "$proj" "$pct" "$(rel "$LAST_LOG")" "$(show_cmd "${cmd[@]}")"
  fi
}

stack_php() {
  local proj="$1" dir="$2" idx="$3"
  if ! have composer; then defer_project php "$proj" composer; return 0; fi
  local test_ok=1
  if in_scope build; then run_override php build QG-BUILD build "$proj" "$dir" || run_step QG-BUILD build php "$proj" "$dir" implementer composer validate --no-check-publish || true; fi
  if in_scope lint; then run_override php lint QG-LINT lint "$proj" "$dir" || add_check QG-LINT lint php "$proj" skipped warning "" "" "no default PHP lint; set quality.commands.php.lint (e.g. vendor/bin/phpcs)" implementer ""; fi
  local tlog=""
  if in_scope test; then
    if run_override php test QG-TEST test "$proj" "$dir"; then [[ $OV_RC -eq 0 ]] || test_ok=0
    elif [[ -f "$dir/vendor/bin/phpunit" ]]; then run_step QG-TEST test php "$proj" "$dir" implementer php vendor/bin/phpunit --coverage-text || test_ok=0; tlog="$LAST_LOG"
    else add_check QG-TEST test php "$proj" fail error "" "" "vendor/bin/phpunit not found (composer install?)" implementer ""; test_ok=0; fi
  fi
  if in_scope coverage; then
    if [[ $test_ok -eq 0 ]]; then add_check QG-COV coverage php "$proj" skipped none "" "" "tests did not pass; coverage not evaluated" implementer ""; return 0; fi
    local pct=""; [[ -n "$tlog" ]] && pct="$(grep -E 'Lines:' "$tlog" | head -n 1 | grep -Eo '[0-9.]+%' | tr -d '%' || true)"
    record_cov php "$proj" "$pct" "$(rel "${tlog:-$dir}")" "phpunit --coverage-text"
  fi
}

# ---------------------------------------------------------------- scanners
SECRET_PATTERNS=(
  'private-key|-----BEGIN[ A-Z]*PRIVATE KEY-----'
  'aws-access-key|(A3T[A-Z0-9]|AKIA|ASIA)[A-Z0-9]{16}'
  'github-token|gh[pousr]_[A-Za-z0-9]{36,}'
  'github-pat|github_pat_[A-Za-z0-9_]{60,}'
  'gitlab-token|glpat-[A-Za-z0-9_-]{20,}'
  'slack-token|xox[baprs]-[A-Za-z0-9-]{10,}'
  'stripe-live-key|[sr]k_live_[0-9A-Za-z]{24,}'
  'google-api-key|AIza[0-9A-Za-z_-]{35}'
  'openai-key|sk-(proj-)?[A-Za-z0-9_-]{40,}'
)
# builtin_secret_scan FILELIST -> prints "file:line:rule" (never the secret)
builtin_secret_scan() {
  local list="$1" entry rule pat
  [[ -s "$list" ]] || return 0
  for entry in "${SECRET_PATTERNS[@]}"; do
    rule="${entry%%|*}"; pat="${entry#*|}"
    # -o prints the match, which is discarded here: only file:line:rule is kept.
    tr '\n' '\0' <"$list" | xargs -0 grep -EnIoH -- "$pat" 2>/dev/null \
      | awk -F: -v r="$rule" -v root="$REPO_ROOT/" '{ f = $1; if (index(f, root) == 1) f = substr(f, length(root) + 1); print f ":" $2 ":" r }' || true
  done | sort -u
}
list_ws_files() { # -> file list path
  local out="$ART/files-scan.txt" expr=() n
  for n in "${PRUNE_NAMES[@]}"; do expr+=( -name "$n" -o ); done
  find "$WS" \( -type d ! -path "$WS" \( "${expr[@]}" -name '.?*' \) \) -prune -o -type f -size -2048k -print 2>/dev/null >"$out" || true
  printf '%s' "$out"
}

GIT_TOP=""
if have git && git -C "$WS" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  GIT_TOP="$(cd "$WS" && cdup="$(git rev-parse --show-cdup 2>/dev/null)" && cd "./$cdup" && pwd || true)"
fi

check_secrets() {
  in_scope secrets || return 0
  local mode=full list="" rc=0 cmd=()
  if [[ $FAST -eq 1 && -n "$GIT_TOP" ]]; then
    mode=staged
    list="$ART/files-staged.txt"
    git -C "$GIT_TOP" diff --cached --name-only --diff-filter=ACMR 2>/dev/null | while IFS= read -r f; do printf '%s\n' "$GIT_TOP/$f"; done >"$list" || true
    if [[ ! -s "$list" ]]; then add_check QG-SECRETS secrets "" "" pass none "git diff --cached --name-only" 0 "no staged files" human ""; return 0; fi
  fi
  if have gitleaks; then
    local report="$ART/gitleaks.json" newcli=0 nrep ntop nws
    local -a glcfg=(); local glroot="${GIT_TOP:-$REPO_ROOT}"
    if [[ -n "$glroot" && -f "$glroot/.gitleaks.toml" ]]; then glcfg=(-c "$(native_path "$glroot/.gitleaks.toml")")
    elif [[ $mode == staged ]]; then
      # Pre-commit scan: a freshly staged lockfile is megabytes of generated hashes and made every commit wait
      # minutes. Skip lockfiles here; the full quality gate still scans them.
      cat > "$ART/gitleaks-fast.toml" <<'GLTOML'
[extend]
useDefault = true
[allowlist]
description = "KCC fast (pre-commit) scan: lockfiles are generated, skip them"
paths = ['''(^|/)(package-lock\.json|npm-shrinkwrap\.json|pnpm-lock\.yaml|yarn\.lock|bun\.lockb|poetry\.lock|Pipfile\.lock|Cargo\.lock|go\.sum|composer\.lock|Gemfile\.lock)$''']
GLTOML
      glcfg=(-c "$(native_path "$ART/gitleaks-fast.toml")")
    fi
    nrep="$(native_path "$report")"; nws="$(native_path "$WS")"
    gitleaks dir --help >/dev/null 2>&1 && newcli=1
    if [[ $mode == staged ]]; then
      ntop="$(native_path "$GIT_TOP")"
      if [[ $newcli -eq 1 ]]; then cmd=(gitleaks git "${glcfg[@]}" --staged --no-banner --redact --exit-code 1 --report-format json --report-path "$nrep" "$ntop")
      else cmd=(gitleaks protect --staged --no-banner --redact --exit-code 1 --report-format json --report-path "$nrep" --source "$ntop"); fi
    else
      if [[ $newcli -eq 1 ]]; then cmd=(gitleaks dir "${glcfg[@]}" --no-banner --redact --exit-code 1 --report-format json --report-path "$nrep" "$nws")
      else cmd=(gitleaks detect --no-git --no-banner --redact --exit-code 1 --report-format json --report-path "$nrep" --source "$nws"); fi
    fi
    run_in "$WS" "${cmd[@]}" || rc=$?
    local count=0 shown="gitleaks ${cmd[1]} --redact ($mode)"
    if [[ -f "$report" ]]; then count_matches_v "$report" '"RuleID"'; count="$CL"; fi
    if [[ $rc -eq 0 ]]; then add_check QG-SECRETS secrets "" "" pass none "$shown" "$rc" "gitleaks: no leaks ($mode)" human "$(rel "$report")"
    elif [[ "$count" -gt 0 ]]; then add_check QG-SECRETS secrets "" "" fail error "$shown" "$rc" "gitleaks: $count potential secret(s) (redacted; fail_on=$FAIL_SECRETS); rotate and remove" human "$(rel "$report")"
    else add_check QG-SECRETS secrets "" "" deferred warning "$shown" "$rc" "gitleaks exited $rc without a report (a tool error, not a finding); deferred (not a pass)" human "$(rel "$LAST_LOG")"; fi
    return 0
  fi
  # gitleaks missing: builtin fallback (reduced ruleset), still deferred unless it finds something.
  [[ -n "$list" ]] || list="$(list_ws_files)"
  local hits="$ART/builtin-secrets.txt" nfiles
  builtin_secret_scan "$list" >"$hits" || true
  count_lines_v "$list"; nfiles="$CL"
  local nh; count_lines_v "$hits"; nh="$CL"
  if [[ "$nh" -gt 0 ]]; then
    note_missing gitleaks
    add_check QG-SECRETS secrets "" "" fail error "builtin-secret-scan" 1 "builtin fallback found $nh potential secret(s) in $nfiles $mode file(s): $(head -n 5 "$hits" | tr '\n' ' ')(values redacted); install gitleaks for full coverage" human "$(rel "$hits")"
  else
    defer_check QG-SECRETS secrets "" "" gitleaks "secrets scan (builtin fallback clean over $nfiles $mode file(s))"
  fi
}

OSV_ERROR=""
deps_fallback() { # stack dir proj
  local st="$1" dir="$2" proj="$3" rc=0
  case "$st" in
    node)
      if [[ -f "$dir/package-lock.json" ]] && have npm; then
        local lvl="$FAIL_DEPS"; [[ "$lvl" == "medium" ]] && lvl=moderate; [[ "$lvl" == "any" ]] && lvl=low
        local omit=(); [[ "$AUDIT_DEV" == "true" ]] || omit=(--omit=dev)
        run_split "$dir" npm audit --json "--audit-level=$lvl" ${omit[@]+"${omit[@]}"} || rc=$?
        local flat; flat="$(json_flatten_file "$LAST_OUT")"
        local total; total="$(flat_get "$flat" metadata.vulnerabilities.total)"
        if [[ -z "$total" ]]; then
          if [[ $REQUIRE -eq 1 ]]; then add_check QG-DEPS dependencies node "$proj" fail error "npm audit --json" "$rc" "npm audit did not complete (registry unreachable?)" human "$(rel "$LAST_OUT")"
          else note_missing osv-scanner; add_check QG-DEPS dependencies node "$proj" deferred warning "npm audit --json" "$rc" "npm audit did not complete (registry unreachable?); install osv-scanner or retry online" human "$(rel "$LAST_OUT")"; fi
          return 0
        fi
        local c=0 s v
        for s in critical high moderate low; do
          case "$s" in critical) v=9.0;; high) v=7.0;; moderate) v=4.0;; low) v=0.1;; esac
          if pct_ge "$v" "$DEPS_FLOOR"; then c=$((c + $(flat_get "$flat" "metadata.vulnerabilities.$s" | grep -Eo '^[0-9]+' || echo 0))); fi
        done
        if [[ $c -gt 0 ]]; then add_check QG-DEPS dependencies node "$proj" fail error "npm audit --json --audit-level=$lvl" "$rc" "npm audit: $c vulnerable package(s) at or above '$FAIL_DEPS' (total $total)" implementer "$(rel "$LAST_OUT")"
        else add_check QG-DEPS dependencies node "$proj" pass none "npm audit --json --audit-level=$lvl" "$rc" "npm audit: none at or above '$FAIL_DEPS' (total $total)" implementer "$(rel "$LAST_OUT")"; fi
        return 0
      fi ;;
    python)
      if have pip-audit; then
        local args=(pip-audit -f json); [[ -f "$dir/requirements.txt" ]] && args+=(-r requirements.txt)
        run_split "$dir" "${args[@]}" || rc=$?
        local n; count_matches_v "$LAST_OUT" '"fix_versions"'; n="$CL"
        if [[ $rc -eq 0 ]]; then add_check QG-DEPS dependencies python "$proj" pass none "$(show_cmd "${args[@]}")" "$rc" "pip-audit: no known vulnerabilities" implementer "$(rel "$LAST_OUT")"
        elif [[ "$n" -gt 0 ]]; then add_check QG-DEPS dependencies python "$proj" fail error "$(show_cmd "${args[@]}")" "$rc" "pip-audit: $n vulnerability(ies) (no severity data; any counts)" implementer "$(rel "$LAST_OUT")"
        else add_check QG-DEPS dependencies python "$proj" fail error "$(show_cmd "${args[@]}")" "$rc" "pip-audit failed (exit $rc)" implementer "$(rel "$LAST_OUT")"; fi
        return 0
      fi ;;
    dotnet)
      if have dotnet; then
        run_in "$dir" dotnet list package --vulnerable --include-transitive || rc=$?
        local pat='Critical'
        case "$FAIL_DEPS" in high) pat='Critical|High';; medium|moderate) pat='Critical|High|Moderate';; low|any) pat='Critical|High|Moderate|Low';; esac
        local n; n="$(grep -cE "[[:space:]]($pat)[[:space:]]" "$LAST_LOG" || true)"
        if [[ $rc -ne 0 ]]; then add_check QG-DEPS dependencies dotnet "$proj" fail error "dotnet list package --vulnerable --include-transitive" "$rc" "dotnet vulnerability listing failed (exit $rc)" implementer "$(rel "$LAST_LOG")"
        elif [[ "$n" -gt 0 ]]; then add_check QG-DEPS dependencies dotnet "$proj" fail error "dotnet list package --vulnerable --include-transitive" "$rc" "$n vulnerable package(s) at or above '$FAIL_DEPS'" implementer "$(rel "$LAST_LOG")"
        else add_check QG-DEPS dependencies dotnet "$proj" pass none "dotnet list package --vulnerable --include-transitive" "$rc" "no vulnerable packages at or above '$FAIL_DEPS'" implementer "$(rel "$LAST_LOG")"; fi
        return 0
      fi ;;
  esac
  local fb=""; case "$st" in python) fb=" (or pip-audit)";; esac
  if [[ -n "${OSV_ERROR:-}" ]]; then
    add_check QG-DEPS dependencies "$st" "$proj" deferred warning "" "" "dependency scan$fb: $OSV_ERROR and no stack audit for $st; deferred (not a pass): run the scanner by hand or set quality.scanners.dependencies" human "$(rel "$dir")"
    return 0
  fi
  defer_check QG-DEPS dependencies "$st" "$proj" osv-scanner "dependency scan$fb"
}

# deps_lockfiles -> the lockfiles of the workspace (and, when it has no node lockfile of its own, the lockfile of an ancestor
# npm/yarn/pnpm workspace root, as QG-LOCK accepts it), one path per line, for `osv-scanner -L`.
deps_lockfiles() {
  local expr=() nm=() n found nodefound=0 anc
  for n in "${PRUNE_NAMES[@]}"; do expr+=( -name "$n" -o ); done
  for n in package-lock.json npm-shrinkwrap.json pnpm-lock.yaml yarn.lock poetry.lock uv.lock Pipfile.lock Cargo.lock composer.lock packages.lock.json gradle.lockfile; do nm+=( -name "$n" -o ); done
  unset 'nm[${#nm[@]}-1]'
  found="$(find "$WS" -maxdepth 5 \( -type d ! -path "$WS" \( "${expr[@]}" -name '.?*' \) \) -prune -o -type f \( "${nm[@]}" \) -print 2>/dev/null | sort || true)"
  if printf '%s\n' "$found" | grep -qE '(package-lock|npm-shrinkwrap)\.json$|pnpm-lock\.yaml$|yarn\.lock$'; then nodefound=1; fi
  if [[ $nodefound -eq 0 ]] && printf '%s\n' "$PROJECTS" | grep -q '^node'$'\t'; then
    anc="$(node_ws_root_lock)"
    case "$anc" in *package-lock.json|*npm-shrinkwrap.json|*pnpm-lock.yaml|*yarn.lock) found="${found:+$found$'\n'}$anc" ;; esac
  fi
  [[ -n "$found" ]] && printf '%s\n' "$found"
  return 0
}

check_deps() {
  in_scope deps || return 0
  if [[ -z "$PROJECTS" ]]; then add_check QG-DEPS dependencies "" "" skipped none "" "" "no dependency manifests detected" implementer ""; return 0; fi
  if have osv-scanner; then
    local out="$ART/osv.json" rc=0 lf shown lockargs=() nlock=0
    # The lockfiles by name (-L): a directory walk can come back with "no packages" although the workspace has a lockfile (round 11,
    # npm workspaces). osv-scanner 2.x takes either -L or -r; given both it stops with exit 127 before scanning (round 12: QG-DEPS
    # red for a whole run), so the directory walk runs only when no lockfile was found.
    while IFS= read -r lf; do
      [[ -n "$lf" ]] || continue
      lockargs+=( -L "$(native_path "$lf")" ); nlock=$((nlock + 1))
    done <<<"$(deps_lockfiles)"
    if [[ $nlock -gt 0 ]]; then shown="osv-scanner --format json -L <lockfile>..."; run_split "$WS" osv-scanner --format json "${lockargs[@]}" || rc=$?
    else shown="osv-scanner --format json -r <ws>"; run_split "$WS" osv-scanner --format json -r "$(native_path "$WS")" || rc=$?; fi
    cp "$LAST_OUT" "$out" 2>/dev/null || true
    if [[ $rc -eq 0 ]]; then add_check QG-DEPS dependencies "" "" pass none "$shown" "$rc" "osv-scanner: no known vulnerabilities" implementer "$(rel "$out")"; return 0; fi
    if [[ $rc -eq 128 ]]; then
      # The scanner looked and found no packages: nothing was checked, so this is not a pass.
      local nomsg="osv-scanner found no packages to scan (nothing was checked)"
      if [[ $REQUIRE -eq 1 ]]; then add_check QG-DEPS dependencies "" "" fail error "$shown" "$rc" "$nomsg (--require)" implementer "$(rel "$out")"
      else add_check QG-DEPS dependencies "" "" deferred warning "$shown" "$rc" "$nomsg; deferred (not a pass)" human "$(rel "$out")"; fi
      return 0
    fi
    if [[ $rc -ne 1 ]]; then
      # The scanner stopped before it produced a result (a flag it rejects, a crash, a database it cannot load). That is a tool
      # error, not a finding and not the implementer's code: the per-stack audit stands in where there is one, else the check is
      # deferred to a human (never a pass, never a FIX pass).
      local first; first="$(grep -m1 -vE '^[[:space:]]*$' "$LAST_LOG" 2>/dev/null | cut -c1-160 || true)"
      OSV_ERROR="osv-scanner exited $rc before scanning (a tool error, not a result${first:+: $first})"
      add_check QG-DEPS dependencies "" "" skipped warning "$shown" "$rc" "$OSV_ERROR; the stack audit below stands in" human "$(rel "$LAST_LOG")"
      local st dir
      while IFS=$'\t' read -r st dir; do [[ -n "$st" ]] || continue; deps_fallback "$st" "$dir" "$(rel "$dir")"; done <<<"$PROJECTS"
      return 0
    fi
    # osv-scanner marks each package with its dependency_groups (npm, pip, bundler...); a "dev" package gates only when
    # quality.audit_dev_dependencies is true (round 12: vitest and tinypool advisories are not what ships). Unknown severity counts.
    local counts; counts="$(awk -v f="$DEPS_FLOOR" -v dev="$AUDIT_DEV" '
      /"package"[[:space:]]*:[[:space:]]*\{/ { isdev = 0; ingrp = 0 }
      /"dependency_groups"[[:space:]]*:/ { ingrp = 1; if ($0 ~ /"dev"/) isdev = 1 }
      ingrp && /"dev"/ { isdev = 1 }
      ingrp && /\]/ { ingrp = 0 }
      /"max_severity"[[:space:]]*:/ { s = $0; sub(/.*"max_severity"[[:space:]]*:[[:space:]]*"/, "", s); sub(/".*/, "", s)
        if (isdev && dev != "true") { d++; next }
        if (s == "" || (s + 0) >= (f + 0)) a++; t++ }
      END { printf "%d %d %d", a, t, d }' "$out")"
    local above total devn; read -r above total devn <<<"$counts"
    local devnote=""; [[ "${devn:-0}" -gt 0 ]] && devnote="; $devn dev-only group(s) not gating (quality.audit_dev_dependencies=false)"
    if [[ "$above" -gt 0 ]]; then add_check QG-DEPS dependencies "" "" fail error "$shown" "$rc" "osv-scanner: $above of $total production vulnerability group(s) at or above '$FAIL_DEPS' (unknown severity counts)$devnote" implementer "$(rel "$out")"
    else add_check QG-DEPS dependencies "" "" pass none "$shown" "$rc" "osv-scanner: $total production group(s), none at or above '$FAIL_DEPS'$devnote" implementer "$(rel "$out")"; fi
    return 0
  fi
  note_missing osv-scanner
  local line st dir
  while IFS=$'\t' read -r st dir; do
    [[ -n "$st" ]] || continue
    deps_fallback "$st" "$dir" "$(rel "$dir")"
  done <<<"$PROJECTS"
}

check_sast() {
  in_scope sast || return 0
  local use_docker=0 sast=semgrep
  # quality.scanners.sast names the scanner (semgrep, the default, or opengrep, its LGPL fork that takes the same rules and flags);
  # when the named one is missing the other stands in, so a machine with either runs SAST. Rules: quality.sast_rules
  # (default `auto`, the registry; opengrep has no registry, so give it a local rules folder or it is deferred).
  if [[ "$SAST_TOOL" == "opengrep" ]]; then sast=opengrep; fi
  if ! have "$sast"; then
    if [[ "$sast" == "semgrep" ]] && have opengrep; then sast=opengrep
    elif [[ "$sast" == "opengrep" ]] && have semgrep; then sast=semgrep
    elif [[ "$SAST_RUNNER" == "docker" ]] && have docker; then use_docker=1
    else defer_check QG-SAST sast "" "" "$sast" "SAST"; return 0; fi
  fi
  local rules="$SAST_RULES"
  if [[ "$sast" == "opengrep" && "$rules" == "auto" ]]; then
    if [[ -d "$REPO_ROOT/architecture/sast-rules" ]]; then rules="$REPO_ROOT/architecture/sast-rules"
    else add_check QG-SAST sast "" "" deferred warning "opengrep scan" "" "opengrep has no rule registry: put rules under architecture/sast-rules/ or set quality.sast_rules; deferred (not a pass)" human ""; return 0; fi
  fi
  local out="$ART/semgrep.json" rc=0
  if (( use_docker )); then
    local -a caargs=()
    # user-scope registry value wins over a stale inherited process value (Windows harness shells)
    ca_bundle="${KCC_CA_BUNDLE:-}"
    if [[ "${OS:-}" == "Windows_NT" ]] && command -v powershell.exe >/dev/null 2>&1; then
      ca_reg="$(powershell.exe -NoProfile -Command "[Environment]::GetEnvironmentVariable('KCC_CA_BUNDLE','User')" 2>/dev/null | tr -d '\r')"
      if [[ -n "$ca_reg" && -f "$ca_reg" ]]; then ca_bundle="$ca_reg"; fi
    fi
    if [[ -n "$ca_bundle" && -f "$ca_bundle" ]]; then KCC_CA_BUNDLE="$ca_bundle"; caargs=(-v "$(native_path "$KCC_CA_BUNDLE"):/certs/ca.pem:ro" -e SSL_CERT_FILE=/certs/ca.pem -e REQUESTS_CA_BUNDLE=/certs/ca.pem -e CURL_CA_BUNDLE=/certs/ca.pem); fi
    # MSYS_NO_PATHCONV: Git Bash would rewrite the container-side paths (/src, /out, /certs/ca.pem) into Windows paths.
    MSYS_NO_PATHCONV=1 run_in "$WS" docker run --rm -v "$(native_path "$WS"):/src" -v "$(native_path "$ART"):/out" "${caargs[@]}" semgrep/semgrep semgrep scan --config auto --json --quiet --output /out/semgrep.json /src || rc=$?
  else
    run_in "$WS" "$sast" scan --config "$rules" --json --quiet --output "$(native_path "$out")" "$(native_path "$WS")" || rc=$?
  fi
  local shown="$sast scan --config $rules --json"
  if [[ ! -f "$out" ]]; then
    # No result file: the scanner did not run to completion (rules unreachable, a crash). A tool error is deferred, never a code finding.
    local first; first="$(grep -m1 -vE '^[[:space:]]*$' "$LAST_LOG" 2>/dev/null | cut -c1-160 || true)"
    add_check QG-SAST sast "" "" deferred warning "$shown" "$rc" "$sast exited $rc without a result (a tool error, not a finding${first:+: $first}); deferred (not a pass)" human "$(rel "$LAST_LOG")"; return 0
  fi
  local pat='ERROR'
  case "$FAIL_SAST" in warning) pat='ERROR|WARNING';; info|any) pat='ERROR|WARNING|INFO';; esac
  local n; count_matches_v "$out" "\"severity\"[[:space:]]*:[[:space:]]*\"($pat)\""; n="$CL"
  if [[ "$n" -gt 0 ]]; then add_check QG-SAST sast "" "" fail error "$shown" "$rc" "$sast: $n finding(s) at severity >= $FAIL_SAST" implementer "$(rel "$out")"
  elif [[ $rc -ne 0 && $rc -ne 1 ]]; then add_check QG-SAST sast "" "" deferred warning "$shown" "$rc" "$sast exited $rc (a tool error, not a finding); deferred (not a pass)" human "$(rel "$out")"
  else add_check QG-SAST sast "" "" pass none "$shown" "$rc" "$sast: no findings at severity >= $FAIL_SAST" implementer "$(rel "$out")"; fi
}

# ---------------------------------------------------------------- QG-STATIC (architecture/static-rules.tsv)
# One rule per line, tab-separated: id <TAB> files <TAB> forbidden <TAB> allowed_in <TAB> message
#   files      ERE matched against the path relative to the workspace (which files the rule scans)
#   forbidden  ERE searched in every matching file (grep -E semantics; keep to the POSIX subset so both shells agree)
#   allowed_in ERE of relative paths where the pattern IS permitted (may be empty)
# '#' starts a comment line; a header row "id<TAB>files<TAB>..." is ignored. node_modules, dist, build, .git, coverage,
# TestResults, lockfiles and the rules file itself are never scanned; test files are scanned like any other.
check_static() {
  in_scope static || return 0
  local rules="$REPO_ROOT/architecture/static-rules.tsv" rrel="architecture/static-rules.tsv"
  if [[ ! -f "$rules" ]]; then
    add_check QG-STATIC static-rules "" "" skipped none "" "" "no architecture/static-rules.tsv declared" architect ""
    return 0
  fi
  local -a R_ID=() R_FILES=() R_PAT=() R_ALLOW=() R_MSG=()
  local -a bad=()
  local line t rest id files pat allow msg tabs n=0 rc
  while IFS= read -r line || [[ -n "$line" ]]; do
    n=$((n + 1))
    line="${line%$'\r'}"
    t="${line#"${line%%[![:space:]]*}"}"
    [[ -z "$t" || "${t:0:1}" == "#" ]] && continue
    tabs="${line//[^$'\t']/}"
    if [[ ${#tabs} -lt 4 ]]; then bad+=("line $n: expected 5 tab-separated columns (id, files, forbidden, allowed_in, message), found $((${#tabs} + 1))"); continue; fi
    id="${line%%$'\t'*}"; rest="${line#*$'\t'}"
    files="${rest%%$'\t'*}"; rest="${rest#*$'\t'}"
    pat="${rest%%$'\t'*}"; rest="${rest#*$'\t'}"
    allow="${rest%%$'\t'*}"; msg="${rest#*$'\t'}"
    if [[ "$id" == "id" && "$files" == "files" ]]; then continue; fi
    if [[ -z "$id" || -z "$files" || -z "$pat" || -z "$msg" ]]; then bad+=("line $n: id, files, forbidden and message must not be empty"); continue; fi
    rc=0; LC_ALL=C grep -E -e "$files" </dev/null >/dev/null 2>&1 || rc=$?
    if [[ $rc -ge 2 ]]; then bad+=("line $n ($id): 'files' is not a valid extended regex"); continue; fi
    rc=0; LC_ALL=C grep -E -e "$pat" </dev/null >/dev/null 2>&1 || rc=$?
    if [[ $rc -ge 2 ]]; then bad+=("line $n ($id): 'forbidden' is not a valid extended regex"); continue; fi
    if [[ -n "$allow" ]]; then
      rc=0; LC_ALL=C grep -E -e "$allow" </dev/null >/dev/null 2>&1 || rc=$?
      if [[ $rc -ge 2 ]]; then bad+=("line $n ($id): 'allowed_in' is not a valid extended regex"); continue; fi
    fi
    R_ID+=("$id"); R_FILES+=("$files"); R_PAT+=("$pat"); R_ALLOW+=("$allow"); R_MSG+=("$msg")
  done <"$rules"
  if [[ ${#bad[@]} -gt 0 ]]; then
    add_check QG-STATIC static-rules "" "" fail error "" "" "$rrel is malformed (${#bad[@]} line(s)): $(printf '%s; ' "${bad[@]:0:5}")fix the rules file" architect "$rrel"
    return 0
  fi
  if [[ ${#R_ID[@]} -eq 0 ]]; then
    add_check QG-STATIC static-rules "" "" skipped none "" "" "$rrel declares no rules" architect "$rrel"
    return 0
  fi
  local list="$ART/static-files.txt" sel="$ART/static-sel.txt" sel2="$ART/static-sel2.txt" hits="$ART/static-hits.all.txt" ev="$ART/static-hits.txt"
  : >"$hits"
  ( cd "$WS" && find . -type d \( -name node_modules -o -name dist -o -name build -o -name .git -o -name coverage -o -name TestResults \) -prune -o \
      -type f ! \( -name package-lock.json -o -name npm-shrinkwrap.json -o -name pnpm-lock.yaml -o -name yarn.lock -o -name bun.lockb -o -name bun.lock \
      -o -name poetry.lock -o -name Pipfile.lock -o -name Cargo.lock -o -name go.sum -o -name composer.lock -o -name Gemfile.lock \) -print ) 2>/dev/null \
    | sed 's|^\./||' | LC_ALL=C sort >"$list" || true
  # the rules file is data, not code: it names the forbidden patterns
  if [[ "$WS" == "$REPO_ROOT" ]]; then grep -vxF -e "$rrel" "$list" >"$sel" || true; mv "$sel" "$list"; fi
  local nfiles; count_lines_v "$list"; nfiles="$CL"
  local i
  for i in "${!R_ID[@]}"; do
    LC_ALL=C grep -E -e "${R_FILES[$i]}" "$list" >"$sel" || true
    if [[ -n "${R_ALLOW[$i]}" ]]; then LC_ALL=C grep -Ev -e "${R_ALLOW[$i]}" "$sel" >"$sel2" || true; mv "$sel2" "$sel"; fi
    [[ -s "$sel" ]] || continue
    ( cd "$WS" && tr '\n' '\0' <"$sel" | LC_ALL=C xargs -0 grep -nHIE -e "${R_PAT[$i]}" -- 2>/dev/null ) \
      | awk -F: -v id="${R_ID[$i]}" '{ print $1 ":" $2 " " id }' >>"$hits" || true
  done
  local nh; count_lines_v "$hits"; nh="$CL"
  if [[ "$nh" -eq 0 ]]; then
    add_check QG-STATIC static-rules "" "" pass none "static-rules scan (${#R_ID[@]} rule(s) from $rrel)" 0 "static rules: ${#R_ID[@]} rule(s) over $nfiles file(s), no forbidden pattern found" implementer ""
    return 0
  fi
  { head -n 20 "$hits"; if [[ "$nh" -gt 20 ]]; then echo "... and $((nh - 20)) more"; fi; } >"$ev"
  local ids first
  # rule ids of the hits (second field), each once, sorted; the first three hits joined with ", " (was awk | sort -u | tr | sed, head | tr | sed)
  local -a idl=(); local hl hf1 hf2 hrest hi hj hnew hn=0
  while IFS= read -r hl; do
    read -r hf1 hf2 hrest <<< "$hl"
    [[ -n "$hf2" ]] || continue
    hnew=1; for hi in ${idl[@]+"${idl[@]}"}; do if [[ "$hi" == "$hf2" ]]; then hnew=0; break; fi; done
    if [[ $hnew -eq 1 ]]; then idl[${#idl[@]}]="$hf2"; fi
  done < "$hits"
  for ((hi = 1; hi < ${#idl[@]}; hi++)); do
    hnew="${idl[hi]}"; hj=$((hi - 1))
    while [[ $hj -ge 0 && "${idl[hj]}" > "$hnew" ]]; do idl[hj + 1]="${idl[hj]}"; hj=$((hj - 1)); done
    idl[hj + 1]="$hnew"
  done
  ids=""; for hi in ${idl[@]+"${idl[@]}"}; do ids="${ids:+$ids,}$hi"; done
  first=""
  while IFS= read -r hl && [[ $hn -lt 3 ]]; do first="${first:+$first,}$hl"; hn=$((hn + 1)); done < "$hits"
  first="${first//,/, }"
  add_check QG-STATIC static-rules "" "" fail error "static-rules scan (${#R_ID[@]} rule(s) from $rrel)" 1 "static rules: $nh forbidden-pattern hit(s) (rule(s): $ids); first: $first; first 20 in the evidence file" implementer "$(rel "$ev")"
}

# ---------------------------------------------------------------- QG-IMAGE image-scan-built (compose-built images)
# image_stale_file IMAGE -> the first workspace file newer than the image's Created time (sources, manifests, lockfiles, Dockerfiles;
# build output and dependency folders pruned), or nothing when the image is newer than all of them or its time cannot be read.
image_stale_file() {
  local created stamp expr=() n f
  created="$(docker image inspect -f '{{.Created}}' "$1" 2>/dev/null | head -n 1 | tr -d '\r')"
  [[ -n "$created" ]] || return 0
  stamp="$ART/.image-$(printf '%s' "$1" | tr -c 'A-Za-z0-9' '_').stamp"
  if ! touch -d "$created" "$stamp" 2>/dev/null; then
    # BSD touch has no -d: take the first 14 digits as [[CC]YY]MMDDhhmm.SS
    local d; d="$(printf '%s' "$created" | tr -dc '0-9' | cut -c1-14)"
    touch -t "${d:0:12}.${d:12:2}" "$stamp" 2>/dev/null || return 0
  fi
  for n in "${PRUNE_NAMES[@]}"; do expr+=( -name "$n" -o ); done
  f="$(find "$WS" \( -type d \( "${expr[@]}" -name '.?*' \) -prune \) -o -type f -newer "$stamp" -print 2>/dev/null | head -n 1 || true)"
  rm -f "$stamp"
  printf '%s' "$f"
}
# Images come from the compose file(s) in the workspace or the repo root: the image: value of every service that has build:, or
# <project>-<service> (what compose names it) when no image: is set. The compose file is parsed, not rendered with
# "docker compose config", because that needs every required ${VAR:?} to be set and fails on a clean checkout.
find_compose_files() {
  local d n seen=""
  for d in "$WS" "$REPO_ROOT"; do
    for n in docker-compose.yml docker-compose.yaml compose.yml compose.yaml; do
      if [[ -f "$d/$n" ]]; then
        case "|$seen|" in *"|$d/$n|"*) ;; *) seen="${seen:+$seen|}$d/$n"; printf '%s\n' "$d/$n" ;; esac
      fi
    done
  done
}
# prints "P|<top-level name:>" and "S|<service>|<image:>|<1 if build:>" lines
parse_compose() {
  awk '
    function val(s) { sub(/^[^:]*:[ \t]*/, "", s); sub(/[ \t]+#.*$/, "", s); gsub(/^["\047]|["\047]$/, "", s); gsub(/[ \t]+$/, "", s); return s }
    function flush() { if (name != "") print "S|" name "|" img "|" bld; name = ""; img = ""; bld = 0 }
    { line = $0; sub(/\r$/, "", line) }
    line ~ /^[ \t]*(#.*)?$/ { next }
    { match(line, /^ */); ind = RLENGTH; txt = substr(line, ind + 1) }
    ind == 0 { flush(); insvc = (txt ~ /^services:[ \t]*(#.*)?$/); if (txt ~ /^name:/) print "P|" val(txt); next }
    !insvc { next }
    svcind == 0 { svcind = ind }
    ind == svcind { flush(); name = txt; sub(/:.*$/, "", name); gsub(/["\047 ]/, "", name); next }
    propind == 0 { propind = ind }
    ind == propind { if (txt ~ /^build:/) bld = 1; else if (txt ~ /^image:/) img = val(txt) }
    END { flush() }
  ' "$1"
}
interp_env() { # ${VAR}, ${VAR:-default}, ${VAR-default} from the environment
  local s="$1" re='\$\{([A-Za-z_][A-Za-z0-9_]*)(:?-([^}]*))?\}' name def val k=0
  while [[ "$s" =~ $re && $k -lt 10 ]]; do
    name="${BASH_REMATCH[1]}"; def="${BASH_REMATCH[3]}"; val="${!name:-$def}"
    s="${s/"${BASH_REMATCH[0]}"/$val}"; k=$((k + 1))
  done
  printf '%s' "$s"
}

check_image_built() { # $1 = 1 when a Dockerfile exists in the workspace
  local has_df="$1" files f imgs="" kind a b c proj svc img
  files="$(find_compose_files)"
  if [[ -z "$files" ]]; then
    [[ "$has_df" == 1 ]] && add_check QG-IMAGE image-scan-built "" "" skipped none "" "" "no compose file declared (docker-compose.yml/compose.yml): built-image scan skipped" infrastructure-implementer ""
    return 0
  fi
  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    proj="${COMPOSE_PROJECT_NAME:-}"
    local parsed; parsed="$(parse_compose "$f")"
    if [[ -z "$proj" ]]; then
      while IFS='|' read -r pk pv _; do if [[ "$pk" == "P" ]]; then proj="$pv"; break; fi; done <<< "$parsed"
    fi
    if [[ -z "$proj" ]]; then pd="${f%/*}"; proj="${pd##*/}"; fi
    lc "$proj"; proj="${LC//[^a-z0-9_-]/}"
    while IFS='|' read -r kind a b c; do
      [[ "$kind" == S && "$c" == 1 ]] || continue
      svc="$a"; img="$(interp_env "$b")"
      [[ -n "$img" ]] || img="$proj-$svc"
      printf '%s
' "$imgs" | grep -qxF -e "$img" || imgs="${imgs:+$imgs
}$img"
    done <<<"$parsed"
  done <<<"$files"
  if [[ -z "$imgs" ]]; then
    [[ "$has_df" == 1 ]] && add_check QG-IMAGE image-scan-built "" "" skipped none "" "" "compose file declares no service with build: built-image scan skipped" infrastructure-implementer ""
    return 0
  fi
  if ! have docker; then defer_check QG-IMAGE image-scan-built "" "" docker "built-image scan"; return 0; fi
  if ! have trivy; then defer_check QG-IMAGE image-scan-built "" "" trivy "built-image scan"; return 0; fi
  local sevs="CRITICAL"
  case "$FAIL_DEPS" in high) sevs="HIGH,CRITICAL";; medium|moderate) sevs="MEDIUM,HIGH,CRITICAL";; low|any) sevs="LOW,MEDIUM,HIGH,CRITICAL";; esac
  local i=0 rc rc2 out all nfix ntot unf shown
  while IFS= read -r img; do
    i=$((i + 1)); rc=0
    run_in "$WS" docker image inspect "$img" || rc=$?
    if [[ $rc -ne 0 ]]; then
      # not built (or the daemon is unreachable): never a pass, and this tool does not build (builds are slow)
      if [[ $REQUIRE -eq 1 ]]; then add_check QG-IMAGE image-scan-built "" "" fail error "docker image inspect $img" "$rc" "built image '$img' not found locally: image not built: run docker compose build (--require)" infrastructure-implementer "image-not-built:$img"
      else add_check QG-IMAGE image-scan-built "" "" deferred warning "docker image inspect $img" "$rc" "built image '$img' not found locally: image not built: run docker compose build; deferred (not a pass)" infrastructure-implementer "image-not-built:$img"; fi
      continue
    fi
    # An image older than the workspace files was not built from this code (round 12: images left over from an earlier run were
    # scanned and failed the gate). Stale = deferred with a rebuild hint; only an image newer than every source file is scanned.
    local newer; newer="$(image_stale_file "$img")"
    if [[ -n "$newer" ]]; then
      add_check QG-IMAGE image-scan-built "" "" deferred warning "docker image inspect $img" 0 "built image '$img' is older than the workspace file $(rel "$newer") (built $(docker image inspect -f '{{.Created}}' "$img" 2>/dev/null | cut -c1-19)): stale, not scanned; run docker compose build and re-run the gate; deferred (not a pass)" infrastructure-implementer "image-stale:$img"
      continue
    fi
    out="$ART/trivy-image-$i.json"; all="$ART/trivy-image-$i-all.json"
    shown="trivy image --severity $sevs --ignore-unfixed --exit-code 1 $img"
    rc=0
    run_in "$WS" trivy image --severity "$sevs" --ignore-unfixed --exit-code 1 --format json --output "$(native_path "$out")" "$img" || rc=$?
    local logf="$LAST_LOG"
    if [[ $rc -ne 0 && ( $rc -ne 1 || ! -f "$out" ) ]]; then
      add_check QG-IMAGE image-scan-built "" "" deferred warning "$shown" "$rc" "trivy image $img exited $rc without a report (a tool error or an unreachable database, not a finding); deferred (not a pass)" human "$(rel "$logf")"
      continue
    fi
    nfix=0; if [[ $rc -eq 1 ]]; then count_matches_v "$out" '"Severity"[[:space:]]*:[[:space:]]*"[A-Z]+"'; nfix="$CL"; fi
    # second pass without --ignore-unfixed: only to report how many findings have no fix (visible, never gating)
    rc2=0; unf="unfixed count unavailable"
    run_in "$WS" trivy image --severity "$sevs" --format json --output "$(native_path "$all")" "$img" || rc2=$?
    if [[ $rc2 -eq 0 && -f "$all" ]]; then
      count_matches_v "$all" '"Severity"[[:space:]]*:[[:space:]]*"[A-Z]+"'; ntot="$CL"
      unf="$((ntot - nfix)) unfixed, not gating"; [[ $((ntot - nfix)) -ge 0 ]] || unf="0 unfixed, not gating"
    fi
    if [[ $rc -eq 0 ]]; then
      local evf="$out"; [[ -f "$all" ]] && evf="$all"
      add_check QG-IMAGE image-scan-built "" "" pass none "$shown" "$rc" "trivy image $img: no fixable finding at $sevs ($unf)" infrastructure-implementer "$(rel "$evf")"
    else
      add_check QG-IMAGE image-scan-built "" "" fail error "$shown" "$rc" "trivy image $img: $nfix fixable finding(s) at $sevs ($unf)" infrastructure-implementer "$(rel "$out")"
    fi
  done <<<"$imgs"
}

DOCKERFILE=""
check_container() {
  in_scope sbom || in_scope image || return 0
  local expr=() n
  for n in "${PRUNE_NAMES[@]}"; do expr+=( -name "$n" -o ); done
  DOCKERFILE="$(find "$WS" -maxdepth 3 \( -type d ! -path "$WS" \( "${expr[@]}" -name '.?*' \) \) -prune -o -type f \( -name Dockerfile -o -name 'Dockerfile.*' -o -name '*.Dockerfile' -o -name Containerfile \) -print 2>/dev/null | head -n 1 || true)"
  if [[ -z "$DOCKERFILE" ]]; then
    in_scope sbom && add_check QG-SBOM sbom "" "" skipped none "" "" "not a deployable (no Dockerfile/Containerfile)" infrastructure-implementer ""
    in_scope image && add_check QG-IMAGE image-scan "" "" skipped none "" "" "not a deployable (no Dockerfile/Containerfile)" infrastructure-implementer ""
    in_scope image && check_image_built 0
    return 0
  fi
  if in_scope sbom; then
    if have syft; then
      local sbom="$ART/sbom.cdx.json" rc=0
      run_in "$WS" syft "dir:$(native_path "$WS")" -o "cyclonedx-json=$(native_path "$sbom")" || rc=$?
      if [[ $rc -eq 0 && -s "$sbom" ]]; then add_check QG-SBOM sbom "" "" pass none "syft dir:<ws> -o cyclonedx-json" "$rc" "SBOM generated" infrastructure-implementer "$(rel "$sbom")"
      else add_check QG-SBOM sbom "" "" fail error "syft dir:<ws> -o cyclonedx-json" "$rc" "syft failed (exit $rc)" infrastructure-implementer "$(rel "$LAST_LOG")"; fi
    else defer_check QG-SBOM sbom "" "" syft "SBOM"; fi
  fi
  if in_scope image; then
    if have trivy; then
      local sevs="CRITICAL"
      case "$FAIL_DEPS" in high) sevs="HIGH,CRITICAL";; medium|moderate) sevs="MEDIUM,HIGH,CRITICAL";; low|any) sevs="LOW,MEDIUM,HIGH,CRITICAL";; esac
      local out="$ART/trivy.json" rc=0
      run_in "$WS" trivy fs --scanners vuln,misconfig --severity "$sevs" --exit-code 1 --format json --output "$(native_path "$out")" "$(native_path "$WS")" || rc=$?
      if [[ $rc -eq 0 ]]; then add_check QG-IMAGE image-scan "" "" pass none "trivy fs --severity $sevs --exit-code 1" "$rc" "trivy: no findings at $sevs" infrastructure-implementer "$(rel "$out")"
      elif [[ $rc -eq 1 && -f "$out" ]]; then
        local n; count_matches_v "$out" '"Severity"[[:space:]]*:[[:space:]]*"[A-Z]+"'; n="$CL"
        add_check QG-IMAGE image-scan "" "" fail error "trivy fs --severity $sevs --exit-code 1" "$rc" "trivy: $n finding(s) at $sevs" infrastructure-implementer "$(rel "$out")"
      else add_check QG-IMAGE image-scan "" "" deferred warning "trivy fs --severity $sevs --exit-code 1" "$rc" "trivy fs exited $rc without a report (a tool error or an unreachable database, not a finding); deferred (not a pass)" human "$(rel "$LAST_LOG")"; fi
    else defer_check QG-IMAGE image-scan "" "" trivy "image/fs scan"; fi
    check_image_built 1
  fi
}

# ---------------------------------------------------------------- run
PLAN_SCOPE=""
if [[ "${SCOPE_GIVEN:-0}" -eq 0 && $FAST -eq 0 && -n "$SPEC" ]]; then
  PLAN_SCOPE="$(plan_scope)"
  if [[ -n "$PLAN_SCOPE" ]]; then
    SCOPE="$PLAN_SCOPE"; SCOPE_SOURCE="plan.md Gates coverage"
    notc=""; for n in lock build lint test coverage secrets deps sast static sbom image; do in_scope "$n" || notc="${notc:+$notc, }$n"; done
    add_check QG-SCOPE gate-scope "" "" pass none "" "" "scope from $(rel "$SPEC_DIR")/plan.md -> ## Gates coverage: $SCOPE${notc:+; not covered by the plan (the architecture decides the gates): $notc}" architect "$(rel "$SPEC_DIR/plan.md")"
  fi
fi
PROJECTS=""
STACKS_JSON=""
if [[ $FAST -eq 0 ]]; then
  PROJECTS="$(discover_projects || true)"
  if in_scope lock || in_scope build || in_scope lint || in_scope test || in_scope coverage || in_scope deps; then
    if [[ -z "$PROJECTS" ]]; then
      add_check QG-STACK stack-detection "" "" skipped warning "" "" "no stack markers found in $(rel "$WS")" implementer "$(rel "$WS")"
    else
      det=""; while IFS= read -r pl; do det="${det:+$det, }${pl%%$'\t'*}"; done <<< "$PROJECTS"
      rel_v "$WS"
      add_check QG-STACK stack-detection "" "" pass none "" "" "detected: $det" implementer "$RELV"
    fi
    while IFS=' ' read -r st dl; do
      [[ -n "$st" ]] || continue
      if ! printf '%s\n' "$PROJECTS" | grep -q "^$st"$'\t'; then
        add_check QG-STACK stack-detection "$st" "" fail warning "" "" "dialect $dl selected but no $st project markers found" implementer "$(rel "${SPEC_DIR:-$WS}")"
      fi
    done <<<"$(dialect_stacks)"
  fi
  idx=0
  while IFS=$'\t' read -r st dir; do
    [[ -n "$st" ]] || continue
    idx=$((idx + 1))
    proj="$(rel "$dir")"
    STACKS_JSON="${STACKS_JSON:+$STACKS_JSON,}{\"stack\":$(jstr "$st"),\"dir\":$(jstr "$proj")}"
    check_lock "$st" "$proj" "$dir"
    if in_scope build || in_scope lint || in_scope test || in_scope coverage; then
      "stack_$st" "$proj" "$dir" "$idx"
    fi
  done <<<"$PROJECTS"
fi
check_secrets
if [[ $FAST -eq 0 ]]; then
  check_deps
  check_sast
  check_static
  check_container
fi

# ---------------------------------------------------------------- summarize
ERRORS=0; WARNINGS=0; DEFERRED=0
for i in "${!C_ID[@]}"; do
  case "${C_SEV[$i]}" in error) ERRORS=$((ERRORS + 1));; warning) WARNINGS=$((WARNINGS + 1));; esac
  [[ "${C_STATUS[$i]}" == deferred ]] && DEFERRED=$((DEFERRED + 1))
done
STATUS=pass; EXIT=0
if [[ $ERRORS -gt 0 ]]; then STATUS=fail; EXIT=1; elif [[ $DEFERRED -gt 0 ]]; then STATUS=deferred; EXIT=3; fi

HINT_PS=""; HINT_SH=""
if [[ -n "$MISSING" ]]; then
  HINT_PS="powershell -ExecutionPolicy Bypass -File .KCC\\tools\\toolchain-preflight.ps1 -Tools $MISSING"
  HINT_SH="bash .KCC/tools/toolchain-preflight.sh ${MISSING//,/ }"
fi
MODE=full; [[ $FAST -eq 1 ]] && MODE=fast
SCOPE_OUT="$SCOPE"; [[ $FAST -eq 1 ]] && SCOPE_OUT="fast"

REPORT_JSON=""; REPORT_MD=""
if [[ -n "$OUT_DIR" ]]; then REPORT_JSON="$OUT_DIR/quality-gate.json"; REPORT_MD="$OUT_DIR/quality-gate.md"; fi

build_json() {
  local i first=1 rcj file msg t reqb
  pjn '{"tool":"quality-gate","version":"%s","scope":%j,"scope_source":%j,"mode":"%s","spec":%j,"idea":%j,' "$VERSION" "$SCOPE_OUT" "$SCOPE_SOURCE" "$MODE" "$SPEC" "${IDEA_ID:+IDEA-$IDEA_ID}"; printf '%s' "$PJ"
  rel_v "$WS"; reqb=false; [[ $REQUIRE -eq 1 ]] && reqb=true
  pjn '"workspace":%j,"require":%s,"coverage_min_pct":%s,"coverage_min_source":%j,' "$RELV" "$reqb" "$COV_MIN" "$COV_SRC"; printf '%s' "$PJ"
  printf '"errors":%d,"warnings":%d,"deferred":%d,"status":"%s","exit_code":%d,' "$ERRORS" "$WARNINGS" "$DEFERRED" "$STATUS" "$EXIT"
  printf '"stacks":[%s],"checks":[' "$STACKS_JSON"
  for i in "${!C_ID[@]}"; do
    [[ $first -eq 1 ]] || printf ','; first=0
    rcj="null"; [[ -n "${C_RC[$i]}" ]] && rcj="${C_RC[$i]}"
    pjn '{"id":%j,"name":%j,"stack":%j,"project":%j,"status":%j,"severity":%j,"command":%j,"exit_code":%s,"message":%j,"fix_owner":%j,"evidence":%j}' \
      "${C_ID[$i]}" "${C_NAME[$i]}" "${C_STACK[$i]}" "${C_PROJ[$i]}" "${C_STATUS[$i]}" \
      "${C_SEV[$i]}" "${C_CMD[$i]}" "$rcj" "${C_MSG[$i]}" "${C_OWNER[$i]}" "${C_EVID[$i]}"
    printf '%s' "$PJ"
  done
  printf '],"violations":['
  first=1
  for i in "${!C_ID[@]}"; do
    [[ "${C_SEV[$i]}" == error || "${C_SEV[$i]}" == warning ]] || continue
    [[ $first -eq 1 ]] || printf ','; first=0
    file="${C_PROJ[$i]}"; [[ -n "$file" ]] || file="${C_EVID[$i]}"
    msg="${C_MSG[$i]}"; [[ -n "${C_STACK[$i]}" ]] && msg="[${C_STACK[$i]}] $msg"
    pjn '{"id":%j,"severity":%j,"fix_owner":%j,"file":%j,"message":%j}' "${C_ID[$i]}" "${C_SEV[$i]}" "${C_OWNER[$i]}" "$file" "$msg"; printf '%s' "$PJ"
  done
  printf '],"missing_tools":['
  first=1
  for t in ${MISSING//,/ }; do [[ $first -eq 1 ]] || printf ','; first=0; jstr_v "$t"; printf '%s' "$JS"; done
  printf '],"install_hint":'
  if [[ -n "$HINT_PS" ]]; then pjn '{"powershell":%j,"bash":%j,"note":"human-gated: run only after approval via the toolchain-preflight gate"}' "$HINT_PS" "$HINT_SH"; printf '%s' "$PJ"; else printf 'null'; fi
  if [[ $DROP_ART -eq 1 ]]; then printf ',"artifacts":null,"report":'; else jstr_v "$(native_path "$ART")"; printf ',"artifacts":%s,"report":' "$JS"; fi
  if [[ -n "$REPORT_JSON" ]]; then rel_v "$REPORT_JSON"; local rj="$RELV"; rel_v "$REPORT_MD"; pjn '{"json":%j,"md":%j}' "$rj" "$RELV"; printf '%s' "$PJ"; else printf 'null'; fi
  printf '}\n'
}

# Non-spec runs: keep scanner/command logs only when something needs attention.
DROP_ART=0
if [[ -z "$OUT_DIR" && $EXIT -eq 0 && "${KCC_QG_KEEP_ARTIFACTS:-}" != "1" ]]; then DROP_ART=1; fi
JSON_DOC="$(build_json)"

if [[ -n "$OUT_DIR" ]]; then
  mkdir -p "$OUT_DIR"
  printf '%s\n' "$JSON_DOC" >"$REPORT_JSON"
  {
    printf -- '---\ntitle: "Quality Gate %s"\ntags:\n  - kcc/quality-gate\nstatus: %s\n---\n\n' "$SPEC" "$STATUS"
    printf '# Quality Gate - %s (IDEA-%s)\n\n' "$SPEC" "$IDEA_ID"
    printf -- '- Status: **%s** (exit %d)\n- Workspace: `%s`\n- Mode: %s%s\n- Coverage minimum: %s%% (%s)\n- Errors: %d  Warnings: %d  Deferred: %d\n\n' \
      "$STATUS" "$EXIT" "$(rel "$WS")" "$MODE" "$([[ $REQUIRE -eq 1 ]] && echo ', require' || true)" "$COV_MIN" "$COV_SRC" "$ERRORS" "$WARNINGS" "$DEFERRED"
    printf '| Check | Stack | Project | Status | Command | Exit | Message | Evidence |\n|--|--|--|--|--|--|--|--|\n'
    for i in "${!C_ID[@]}"; do
      printf '| %s | %s | %s | %s | `%s` | %s | %s | %s |\n' "${C_ID[$i]}" "${C_STACK[$i]:--}" "${C_PROJ[$i]:--}" "${C_STATUS[$i]}" "${C_CMD[$i]//|/\\|}" "${C_RC[$i]:--}" "${C_MSG[$i]//|/\\|}" "${C_EVID[$i]:--}"
    done
    if [[ -n "$HINT_PS" ]]; then
      printf '\n## Missing tools (deferred - NOT a pass)\n\nApprove through the toolchain-preflight gate, then re-run:\n\n```powershell\n%s\n```\n\n```bash\n%s\n```\n' "$HINT_PS" "$HINT_SH"
    fi
  } >"$REPORT_MD"
fi

if [[ $EMIT -eq 1 ]]; then
  payload="{\"status\":\"$STATUS\",\"errors\":$ERRORS,\"warnings\":$WARNINGS,\"deferred\":$DEFERRED,\"mode\":\"$MODE\",\"missing_tools\":\"$(json_escape "$MISSING")\",\"report\":$(jstr "${REPORT_JSON:+$(rel "$REPORT_JSON")}")}"
  bash "$SCRIPT_DIR/backchannel-append.sh" --kind quality-gate-result --from quality-gate --spec "$SPEC" --payload "$payload" --repo-root "$REPO_ROOT" >/dev/null 2>&1 || echo "warning: backchannel emit failed" >&2
fi

if [[ $JSON -eq 1 ]]; then
  printf '%s\n' "$JSON_DOC"
else
  for i in "${!C_ID[@]}"; do
    tag="$(printf '%s' "${C_STATUS[$i]}" | tr 'a-z' 'A-Z')"
    where=""; [[ -n "${C_STACK[$i]}" ]] && where=" [${C_STACK[$i]}${C_PROJ[$i]:+ ${C_PROJ[$i]}}]"
    extra=""; [[ -n "${C_CMD[$i]}" ]] && extra=" ($(printf '%s' "${C_CMD[$i]}") -> exit ${C_RC[$i]:-?})"
    printf '%-8s %-10s%s %s%s\n' "$tag" "${C_ID[$i]}" "$where" "${C_MSG[$i]}" "$extra"
  done
  if [[ -n "$HINT_PS" ]]; then
    echo "Missing tools (human-gated install; not run by this tool):"
    echo "  $HINT_SH"
    echo "  $HINT_PS"
  fi
  [[ -n "$REPORT_JSON" ]] && echo "Report: $(rel "$REPORT_MD")"
  echo "Errors: $ERRORS  Warnings: $WARNINGS"
  echo "Status: $STATUS (exit $EXIT)"
fi

if [[ $DROP_ART -eq 1 ]]; then rm -rf "$ART" 2>/dev/null || true; fi
exit $EXIT
