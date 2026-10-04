#!/usr/bin/env bash
# KCC framework (c) 2026 Tarek Fawaz, https://tikasway.dev/kcc. Licensed under the terms in LICENSE.
#
# quality-gate.sh - deterministic quality gate for a KCC workspace.
# Mirror of quality-gate.ps1 (same check IDs, JSON shape, exit codes).
# Contract: .KCC/kernel/contracts/tool-contract.md
#
# Checks: QG-STACK QG-LOCK QG-BUILD QG-LINT QG-TEST QG-COV QG-SECRETS
#         QG-DEPS QG-SAST QG-SBOM QG-IMAGE
#
# Usage:
#   bash .KCC/tools/quality-gate.sh [--repo-root PATH] [--spec SPEC-ID] [--path DIR]
#        [--scope all|lock,build,lint,test,coverage,secrets,deps,sast,sbom,image]
#        [--fast] [--require] [--emit] [--json]
#
# Exit: 0 pass | 1 violations | 2 usage/environment | 3 deferred (a scanner or
# toolchain is missing; NOT a pass). This tool NEVER installs anything; it
# prints the toolchain-preflight command for the human to approve.
# No python / jq dependency.
set -euo pipefail

VERSION="1.0.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT=""
JSON=0
SPEC=""
WS_PATH=""
FAST=0
REQUIRE=0
EMIT=0
SCOPE="all"

usage() {
  cat >&2 <<'EOF'
usage: quality-gate.sh [--repo-root PATH] [--spec SPEC-ID] [--path DIR] [--scope LIST]
                       [--fast] [--require] [--emit] [--json]
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo-root|-RepoRoot) [[ $# -ge 2 ]] || { usage; exit 2; }; REPO_ROOT="$2"; shift 2 ;;
    --spec|-Spec) [[ $# -ge 2 ]] || { usage; exit 2; }; SPEC="$2"; shift 2 ;;
    --path|-Path) [[ $# -ge 2 ]] || { usage; exit 2; }; WS_PATH="$2"; shift 2 ;;
    --scope|-Scope) [[ $# -ge 2 ]] || { usage; exit 2; }; SCOPE="$2"; shift 2 ;;
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
REPO_ROOT="$(cd "$REPO_ROOT" && pwd)"

if [[ -n "$SPEC" && ! "$SPEC" =~ ^SPEC-[0-9A-Za-z]+$ ]]; then die_env "invalid --spec '$SPEC' (expected SPEC-{ID})"; fi
SCOPE="$(printf '%s' "$SCOPE" | tr 'A-Z' 'a-z' | tr -d ' ')"
for s in ${SCOPE//,/ }; do
  case "$s" in all|lock|build|lint|test|coverage|secrets|deps|sast|sbom|image) ;; *) die_env "unknown scope '$s'";; esac
done
if [[ $FAST -eq 1 ]]; then SCOPE="secrets"; fi
in_scope() { [[ ",$SCOPE," == *",all,"* || ",$SCOPE," == *",$1,"* ]]; }

# ---------------------------------------------------------------- JSON helpers
json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\r'/\\r}"
  s="${s//$'\t'/\\t}"
  printf '%s' "$s"
}
jstr() { if [[ -z "$1" ]]; then printf 'null'; else printf '"%s"' "$(json_escape "$1")"; fi; }

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
flat_get() { # flat-text key
  printf '%s\n' "$1" | awk -F'\t' -v k="$2" '$1 == k { v = $2 } END { if (v != "" && v != "null") print v }'
}

# ---------------------------------------------------------------- settings
SETTINGS_FILE="$REPO_ROOT/.KCC/settings.json"
SETTINGS_FLAT="$(json_flatten_file "$SETTINGS_FILE")"
setting() { local v; v="$(flat_get "$SETTINGS_FLAT" "$1")"; if [[ -n "$v" ]]; then printf '%s' "$v"; else printf '%s' "${2:-}"; fi; }

COV_MIN="$(setting quality.coverage_min_pct 80)"
COV_SRC="settings.quality.coverage_min_pct"
[[ -f "$SETTINGS_FILE" ]] || COV_SRC="default"
FAIL_DEPS="$(setting quality.fail_on.dependencies high | tr 'A-Z' 'a-z')"
FAIL_SAST="$(setting quality.fail_on.sast error | tr 'A-Z' 'a-z')"
# local (semgrep on PATH) or docker (semgrep/semgrep image; Windows has no native semgrep).
SAST_RUNNER="$(setting quality.scanners.sast_runner local | tr 'A-Z' 'a-z')"
FAIL_SECRETS="$(setting quality.fail_on.secrets any | tr 'A-Z' 'a-z')"

cov_override_from() { grep -Eo 'coverage_min_pct:[[:space:]]*[0-9]+(\.[0-9]+)?' "$1" 2>/dev/null | tail -n 1 | grep -Eo '[0-9]+(\.[0-9]+)?$' || true; }
if [[ -f "$REPO_ROOT/architecture/quality-gates.md" ]]; then
  v="$(cov_override_from "$REPO_ROOT/architecture/quality-gates.md")"
  if [[ -n "$v" ]]; then COV_MIN="$v"; COV_SRC="architecture/quality-gates.md"; fi
fi
if [[ "$COV_SRC" != "architecture/quality-gates.md" && -d "$REPO_ROOT/architecture/adrs" ]]; then
  for f in $(ls "$REPO_ROOT/architecture/adrs" 2>/dev/null | grep -E '\.md$' | sort); do
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
native_path() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf "%s" "$1"; fi; }

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
  local expr=() n
  for n in "${PRUNE_NAMES[@]}"; do expr+=( -name "$n" -o ); done
  find "$WS" -maxdepth 4 \( -type d ! -path "$WS" \( "${expr[@]}" -name '.?*' \) \) -prune -o -type f \( \
    -name package.json -o -name pyproject.toml -o -name requirements.txt -o -name setup.py -o \
    -name '*.sln' -o -name '*.csproj' -o -name '*.fsproj' -o -name go.mod -o -name Cargo.toml -o \
    -name pom.xml -o -name build.gradle -o -name build.gradle.kts -o -name CMakeLists.txt -o \
    -name composer.json \) -print 2>/dev/null | while IFS= read -r f; do
      local b st
      b="$(basename "$f")"
      case "$b" in
        package.json) st=node ;; pyproject.toml|requirements.txt|setup.py) st=python ;;
        *.sln|*.csproj|*.fsproj) st=dotnet ;; go.mod) st=go ;; Cargo.toml) st=rust ;;
        pom.xml|build.gradle|build.gradle.kts) st=java ;; CMakeLists.txt) st=cpp ;; composer.json) st=php ;;
        *) continue ;;
      esac
      printf '%s\t%s\n' "$st" "$(dirname "$f")"
    done | sort -u | awk -F'\t' '{ print length($2) "\t" $0 }' | sort -t "$(printf '\t')" -k1,1n -k3,3 -k2,2 | cut -f2- | awk -F'\t' '
      { keep = 1
        for (i = 1; i <= k; i++) { if (S[i] == $1 && index($2 "/", D[i] "/") == 1 && $2 != D[i]) { keep = 0; break } }
        if (keep) { k++; S[k] = $1; D[k] = $2; print } }'
}

dialect_stacks() {
  [[ -n "$SPEC_DIR" ]] || return 0
  grep -rhoE '(backend|fullstack|frontend|embedded)-(nodejs|mern|nestjs|react|angular|vanilla-js|python|csharp|dotnet|go|rust|java|cpp|c|php)\b' "$SPEC_DIR" 2>/dev/null | sort -u | while IFS= read -r d; do
    case "$d" in
      backend-nodejs|fullstack-mern|fullstack-nestjs|frontend-react|frontend-angular|frontend-vanilla-js) echo "node $d" ;;
      backend-python|fullstack-python) echo "python $d" ;;
      backend-csharp|fullstack-dotnet) echo "dotnet $d" ;;
      backend-go|fullstack-go) echo "go $d" ;;
      backend-rust|embedded-rust) echo "rust $d" ;;
      backend-java) echo "java $d" ;;
      backend-cpp|embedded-c|embedded-cpp) echo "cpp $d" ;;
      backend-php) echo "php $d" ;;
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
check_lock() { # stack proj dir
  local st="$1" proj="$2" dir="$3" f=""
  in_scope lock || return 0
  case "$st" in
    node) f="$(find_up "$dir" package-lock.json npm-shrinkwrap.json pnpm-lock.yaml yarn.lock bun.lockb bun.lock || true)" ;;
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
    if [[ -n "$glroot" && -f "$glroot/.gitleaks.toml" ]]; then glcfg=(-c "$(native_path "$glroot/.gitleaks.toml")"); fi
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
    [[ -f "$report" ]] && count="$(grep -o '"RuleID"' "$report" | wc -l | tr -d ' ' || true)"
    if [[ $rc -eq 0 ]]; then add_check QG-SECRETS secrets "" "" pass none "$shown" "$rc" "gitleaks: no leaks ($mode)" human "$(rel "$report")"
    elif [[ "$count" -gt 0 ]]; then add_check QG-SECRETS secrets "" "" fail error "$shown" "$rc" "gitleaks: $count potential secret(s) (redacted; fail_on=$FAIL_SECRETS); rotate and remove" human "$(rel "$report")"
    else add_check QG-SECRETS secrets "" "" fail error "$shown" "$rc" "gitleaks failed to run (exit $rc)" human "$(rel "$LAST_LOG")"; fi
    return 0
  fi
  # gitleaks missing: builtin fallback (reduced ruleset), still deferred unless it finds something.
  [[ -n "$list" ]] || list="$(list_ws_files)"
  local hits="$ART/builtin-secrets.txt" nfiles
  builtin_secret_scan "$list" >"$hits" || true
  nfiles="$(wc -l <"$list" | tr -d ' ')"
  local nh; nh="$(wc -l <"$hits" | tr -d ' ')"
  if [[ "$nh" -gt 0 ]]; then
    note_missing gitleaks
    add_check QG-SECRETS secrets "" "" fail error "builtin-secret-scan" 1 "builtin fallback found $nh potential secret(s) in $nfiles $mode file(s): $(head -n 5 "$hits" | tr '\n' ' ')(values redacted); install gitleaks for full coverage" human "$(rel "$hits")"
  else
    defer_check QG-SECRETS secrets "" "" gitleaks "secrets scan (builtin fallback clean over $nfiles $mode file(s))"
  fi
}

deps_fallback() { # stack dir proj
  local st="$1" dir="$2" proj="$3" rc=0
  case "$st" in
    node)
      if [[ -f "$dir/package-lock.json" ]] && have npm; then
        local lvl="$FAIL_DEPS"; [[ "$lvl" == "medium" ]] && lvl=moderate; [[ "$lvl" == "any" ]] && lvl=low
        run_split "$dir" npm audit --json "--audit-level=$lvl" || rc=$?
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
        local n; n="$(grep -o '"fix_versions"' "$LAST_OUT" | wc -l | tr -d ' ' || true)"
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
  defer_check QG-DEPS dependencies "$st" "$proj" osv-scanner "dependency scan$fb"
}

check_deps() {
  in_scope deps || return 0
  if [[ -z "$PROJECTS" ]]; then add_check QG-DEPS dependencies "" "" skipped none "" "" "no dependency manifests detected" implementer ""; return 0; fi
  if have osv-scanner; then
    local out="$ART/osv.json" rc=0
    run_split "$WS" osv-scanner --format json -r "$(native_path "$WS")" || rc=$?
    cp "$LAST_OUT" "$out" 2>/dev/null || true
    if [[ $rc -eq 0 ]]; then add_check QG-DEPS dependencies "" "" pass none "osv-scanner --format json -r <ws>" "$rc" "osv-scanner: no known vulnerabilities" implementer "$(rel "$out")"; return 0; fi
    if [[ $rc -eq 128 ]]; then add_check QG-DEPS dependencies "" "" pass none "osv-scanner --format json -r <ws>" "$rc" "osv-scanner: no packages found to scan" implementer "$(rel "$out")"; return 0; fi
    if [[ $rc -ne 1 ]]; then add_check QG-DEPS dependencies "" "" fail error "osv-scanner --format json -r <ws>" "$rc" "osv-scanner failed (exit $rc)" implementer "$(rel "$out")"; return 0; fi
    local counts; counts="$(grep -Eo '"max_severity"[[:space:]]*:[[:space:]]*"[0-9.]*"' "$out" | grep -Eo '"[0-9.]*"$' | tr -d '"' | awk -v f="$DEPS_FLOOR" '{ if ($1 == "" || ($1 + 0) >= (f + 0)) a++; t++ } END { printf "%d %d", a, t }')"
    local above="${counts% *}" total="${counts#* }"
    if [[ "$above" -gt 0 ]]; then add_check QG-DEPS dependencies "" "" fail error "osv-scanner --format json -r <ws>" "$rc" "osv-scanner: $above of $total vulnerability group(s) at or above '$FAIL_DEPS' (unknown severity counts)" implementer "$(rel "$out")"
    else add_check QG-DEPS dependencies "" "" pass none "osv-scanner --format json -r <ws>" "$rc" "osv-scanner: $total group(s), none at or above '$FAIL_DEPS'" implementer "$(rel "$out")"; fi
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
  local use_docker=0
  if ! have semgrep; then
    if [[ "$SAST_RUNNER" == "docker" ]] && have docker; then use_docker=1
    else defer_check QG-SAST sast "" "" semgrep "SAST"; return 0; fi
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
    run_in "$WS" semgrep scan --config auto --json --quiet --output "$(native_path "$out")" "$(native_path "$WS")" || rc=$?
  fi
  if [[ ! -f "$out" ]]; then add_check QG-SAST sast "" "" fail error "semgrep scan --config auto --json" "$rc" "semgrep failed (exit $rc)" implementer "$(rel "$LAST_LOG")"; return 0; fi
  local pat='ERROR'
  case "$FAIL_SAST" in warning) pat='ERROR|WARNING';; info|any) pat='ERROR|WARNING|INFO';; esac
  local n; n="$(grep -Eo "\"severity\"[[:space:]]*:[[:space:]]*\"($pat)\"" "$out" | wc -l | tr -d ' ')"
  if [[ "$n" -gt 0 ]]; then add_check QG-SAST sast "" "" fail error "semgrep scan --config auto --json" "$rc" "semgrep: $n finding(s) at severity >= $FAIL_SAST" implementer "$(rel "$out")"
  elif [[ $rc -ne 0 ]]; then add_check QG-SAST sast "" "" fail error "semgrep scan --config auto --json" "$rc" "semgrep exited $rc" implementer "$(rel "$out")"
  else add_check QG-SAST sast "" "" pass none "semgrep scan --config auto --json" "$rc" "semgrep: no findings at severity >= $FAIL_SAST" implementer "$(rel "$out")"; fi
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
        local n; n="$(grep -Eo '"Severity"[[:space:]]*:[[:space:]]*"[A-Z]+"' "$out" | wc -l | tr -d ' ' || true)"
        add_check QG-IMAGE image-scan "" "" fail error "trivy fs --severity $sevs --exit-code 1" "$rc" "trivy: $n finding(s) at $sevs" infrastructure-implementer "$(rel "$out")"
      else add_check QG-IMAGE image-scan "" "" fail error "trivy fs --severity $sevs --exit-code 1" "$rc" "trivy failed (exit $rc)" infrastructure-implementer "$(rel "$LAST_LOG")"; fi
    else defer_check QG-IMAGE image-scan "" "" trivy "image/fs scan"; fi
  fi
}

# ---------------------------------------------------------------- run
PROJECTS=""
STACKS_JSON=""
if [[ $FAST -eq 0 ]]; then
  PROJECTS="$(discover_projects || true)"
  if in_scope lock || in_scope build || in_scope lint || in_scope test || in_scope coverage || in_scope deps; then
    if [[ -z "$PROJECTS" ]]; then
      add_check QG-STACK stack-detection "" "" skipped warning "" "" "no stack markers found in $(rel "$WS")" implementer "$(rel "$WS")"
    else
      add_check QG-STACK stack-detection "" "" pass none "" "" "detected: $(printf '%s\n' "$PROJECTS" | awk -F'\t' '{ printf "%s%s", (NR > 1 ? ", " : ""), $1 }')" implementer "$(rel "$WS")"
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
  local i first=1
  printf '{"tool":"quality-gate","version":"%s","scope":%s,"mode":"%s","spec":%s,"idea":%s,' "$VERSION" "$(jstr "$SCOPE_OUT")" "$MODE" "$(jstr "$SPEC")" "$(jstr "${IDEA_ID:+IDEA-$IDEA_ID}")"
  printf '"workspace":%s,"require":%s,"coverage_min_pct":%s,"coverage_min_source":%s,' "$(jstr "$(rel "$WS")")" "$([[ $REQUIRE -eq 1 ]] && echo true || echo false)" "$COV_MIN" "$(jstr "$COV_SRC")"
  printf '"errors":%d,"warnings":%d,"deferred":%d,"status":"%s","exit_code":%d,' "$ERRORS" "$WARNINGS" "$DEFERRED" "$STATUS" "$EXIT"
  printf '"stacks":[%s],"checks":[' "$STACKS_JSON"
  for i in "${!C_ID[@]}"; do
    [[ $first -eq 1 ]] || printf ','; first=0
    local rcj="null"; [[ -n "${C_RC[$i]}" ]] && rcj="${C_RC[$i]}"
    printf '{"id":%s,"name":%s,"stack":%s,"project":%s,"status":%s,"severity":%s,"command":%s,"exit_code":%s,"message":%s,"fix_owner":%s,"evidence":%s}' \
      "$(jstr "${C_ID[$i]}")" "$(jstr "${C_NAME[$i]}")" "$(jstr "${C_STACK[$i]}")" "$(jstr "${C_PROJ[$i]}")" "$(jstr "${C_STATUS[$i]}")" \
      "$(jstr "${C_SEV[$i]}")" "$(jstr "${C_CMD[$i]}")" "$rcj" "$(jstr "${C_MSG[$i]}")" "$(jstr "${C_OWNER[$i]}")" "$(jstr "${C_EVID[$i]}")"
  done
  printf '],"violations":['
  first=1
  for i in "${!C_ID[@]}"; do
    [[ "${C_SEV[$i]}" == error || "${C_SEV[$i]}" == warning ]] || continue
    [[ $first -eq 1 ]] || printf ','; first=0
    local file="${C_PROJ[$i]}"; [[ -n "$file" ]] || file="${C_EVID[$i]}"
    local msg="${C_MSG[$i]}"; [[ -n "${C_STACK[$i]}" ]] && msg="[${C_STACK[$i]}] $msg"
    printf '{"id":%s,"severity":%s,"fix_owner":%s,"file":%s,"message":%s}' "$(jstr "${C_ID[$i]}")" "$(jstr "${C_SEV[$i]}")" "$(jstr "${C_OWNER[$i]}")" "$(jstr "$file")" "$(jstr "$msg")"
  done
  printf '],"missing_tools":['
  first=1
  local t
  for t in ${MISSING//,/ }; do [[ $first -eq 1 ]] || printf ','; first=0; printf '%s' "$(jstr "$t")"; done
  printf '],"install_hint":'
  if [[ -n "$HINT_PS" ]]; then printf '{"powershell":%s,"bash":%s,"note":"human-gated: run only after approval via the toolchain-preflight gate"}' "$(jstr "$HINT_PS")" "$(jstr "$HINT_SH")"; else printf 'null'; fi
  if [[ $DROP_ART -eq 1 ]]; then printf ',"artifacts":null,"report":'; else printf ',"artifacts":%s,"report":' "$(jstr "$(native_path "$ART")")"; fi
  if [[ -n "$REPORT_JSON" ]]; then printf '{"json":%s,"md":%s}' "$(jstr "$(rel "$REPORT_JSON")")" "$(jstr "$(rel "$REPORT_MD")")"; else printf 'null'; fi
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
