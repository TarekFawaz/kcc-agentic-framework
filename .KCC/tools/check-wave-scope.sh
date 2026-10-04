#!/usr/bin/env bash
# KCC framework (c) 2026 Tarek Fawaz, https://tikasway.dev/kcc. Licensed under the terms in LICENSE.
#
# Wave scope gate: every changed file under src/ must be declared in the
# Impacted Files of an item planned for that wave (plan.md '## Waves', legacy
# parallelization.md). Mirror of check-wave-scope.ps1. Read-only (except that
# --test-command runs the given command).
#
# Changed files: git diff --name-only <base> + untracked (base default: newest
# kcc/cp-* tag, else HEAD); without git, src/ vs coordination/checkpoints/
# latest.manifest (path<TAB>sha256) or the manifest given as --base.
#
#   WAVE-001 implementer  changed src/ file not declared for the wave
#   WAVE-002 implementer  --test-command exited non-zero
#   WAVE-003 planner      wave has no items in plan.md
#
# Usage: bash .KCC/tools/check-wave-scope.sh --spec SPEC-ID --wave N [--base REF|MANIFEST]
#        [--test-command "CMD"] [--repo-root PATH] [--json]

set -euo pipefail

TOOL_VERSION="1.0.0"
REPO_ROOT=""
SPEC=""
WAVE=""
BASE=""
TEST_COMMAND=""
SCOPE="all"
JSON=0

while [ $# -gt 0 ]; do
  case "$1" in
    --repo-root) REPO_ROOT="${2:-}"; shift 2 ;;
    --spec) SPEC="${2:-}"; shift 2 ;;
    --wave) WAVE="${2:-}"; shift 2 ;;
    --base) BASE="${2:-}"; shift 2 ;;
    --test-command) TEST_COMMAND="${2:-}"; shift 2 ;;
    --scope) SCOPE="${2:-}"; shift 2 ;;
    --json) JSON=1; shift ;;
    -h|--help) sed -n '2,19p' "$0"; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

usage_fail() { echo "$1" >&2; exit 2; }

TOOL_DIR="$(cd "$(dirname "$0")" && pwd)"
if [ -z "$REPO_ROOT" ]; then
  PARENT="$(dirname "$TOOL_DIR")"
  if [ "$(basename "$PARENT")" = ".KCC" ]; then REPO_ROOT="$(dirname "$PARENT")"; else REPO_ROOT="$PARENT"; fi
fi
[ -d "$REPO_ROOT" ] || usage_fail "workspace not found: $REPO_ROOT"
REPO_ROOT="$(cd "$REPO_ROOT" && pwd)"
[ -n "$SPEC" ] || usage_fail 'usage: check-wave-scope --spec SPEC-{ID} --wave N [--base <ref|manifest>] [--test-command "<cmd>"] [--json]'
case "$WAVE" in ''|*[!0-9]*) usage_fail "--wave N is required (a number)." ;; esac
WAVE_N=$((10#$WAVE))

ERRORS=0
WARNINGS=0
VJSON=""
HUMAN=""
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
violation() {
  local id="$1" sev="$2" owner="$3" msg="$4" file="${5:-}" obj
  if [ "$sev" = "error" ]; then ERRORS=$((ERRORS + 1)); else WARNINGS=$((WARNINGS + 1)); fi
  obj="{\"id\":\"$(je "$id")\",\"severity\":\"$sev\",\"fix_owner\":\"$(je "$owner")\",\"file\":\"$(je "$file")\",\"message\":\"$(je "$msg")\"}"
  if [ -z "$VJSON" ]; then VJSON="$obj"; else VJSON="$VJSON,$obj"; fi
  HUMAN="$HUMAN[$(printf '%s' "$sev" | tr '[:lower:]' '[:upper:]')] $id ($owner) $file: $msg
"
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

backlog_dir() {
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

impacted_files() {
  section "$1" 'impacted files' | awk '
    /^[ \t]*[-*][ \t]+[^ \t]/ {
      l = $0
      if (match(l, /`[^`]+`/)) p = substr(l, RSTART + 1, RLENGTH - 2)
      else { sub(/^[ \t]*[-*][ \t]+/, "", l); split(l, a, /[ \t]+/); p = a[1] }
      gsub(/^[ \t]+|[ \t]+$/, "", p); gsub(/\\/, "/", p); sub(/^\.\//, "", p)
      print p
    }'
}

wave_list() {
  awk '
    function trim(s) { gsub(/^[ \t*`]+|[ \t*`]+$/, "", s); return s }
    { sub(/\r$/, ""); l = $0; low = tolower(l) }
    low ~ /^###+[ \t]*wave[ \t]*[0-9]+/ { s = low; sub(/^###+[ \t]*wave[ \t]*/, "", s); match(s, /^[0-9]+/); cur = substr(s, 1, RLENGTH) + 0; next }
    {
      w = ""; nsrc = 0
      if (l ~ /^[ \t]*\|/) {
        if (l ~ /^[ \t]*\|[ \t:|-]*$/) next
        n = split(l, c, "|")
        if (l !~ /(Story|Enabler|Bug)-[0-9]+/) {
          wc = 0; split("", ex)
          for (i = 1; i <= n; i++) { t = tolower(trim(c[i])); if (t == "wave" && !wc) wc = i; if (t ~ /depend|block|after/) ex[i] = 1 }
          next
        }
        if (wc && wc <= n) { t = tolower(trim(c[wc])); if (t ~ /^(wave[ \t]*)?[0-9]+$/) { sub(/^wave[ \t]*/, "", t); w = t + 0 } }
        if (w == "") { for (i = 1; i <= n; i++) { t = tolower(trim(c[i])); if (t ~ /^(wave[ \t]*)?[0-9]+$/) { sub(/^wave[ \t]*/, "", t); w = t + 0; break } } }
        for (i = 1; i <= n; i++) if (!(i in ex)) src[++nsrc] = c[i]
      } else {
        if (match(low, /wave[ \t]*[0-9]+/)) { t = substr(low, RSTART, RLENGTH); sub(/wave[ \t]*/, "", t); w = t + 0 }
        src[++nsrc] = l
      }
      if (w == "") w = cur
      if (w == "") next
      for (k = 1; k <= nsrc; k++) { r = src[k]; while (match(r, /(Story|Enabler|Bug)-[0-9]+/)) { print w "\t" substr(r, RSTART, RLENGTH); r = substr(r, RSTART + RLENGTH) } }
    }'
}

ignored() { # rel-path -> 0 when inside a generated folder
  case "/$(lower "$1")/" in
    */node_modules/*|*/__pycache__/*|*/bin/*|*/obj/*|*/dist/*|*/build/*|*/.venv/*|*/venv/*|*/target/*|*/coverage/*|*/.pytest_cache/*) return 0 ;;
  esac
  return 1
}

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1
  elif command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | cut -d' ' -f1
  else openssl dgst -sha256 "$1" | sed 's/^.*= //'
  fi
}

gitc() { git -C "$REPO_ROOT" -c core.quotepath=off "$@"; }

# --- locate spec ---
SPEC_DIR=""
if [ -d "$REPO_ROOT/specs" ]; then
  s="$(lower "$SPEC")"
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    name="$(basename "$d")"
    [ -f "$d/$name.md" ] || continue
    n="$(lower "$name")"
    id="$(lower "$(printf '%s' "$name" | grep -oE '^SPEC-[0-9]+' || true)")"
    if [ "$n" = "$s" ] || [ "$id" = "$s" ]; then SPEC_DIR="$d"; break; fi
    case "$n" in "$s"-*) SPEC_DIR="$d"; break ;; esac
  done <<EOF
$(find "$REPO_ROOT/specs" -type d -name 'SPEC-*' 2>/dev/null | LC_ALL=C sort)
EOF
fi
[ -n "$SPEC_DIR" ] || usage_fail "no spec folder matches $SPEC"

# --- declared files for the wave ---
WSRC=""
if [ -f "$SPEC_DIR/plan.md" ]; then WSRC="$(section "$SPEC_DIR/plan.md" 'waves')"; fi
if [ -z "$WSRC" ] && [ -f "$SPEC_DIR/parallelization.md" ]; then
  WSRC="$(section "$SPEC_DIR/parallelization.md" 'waves')"
  if [ -z "$WSRC" ]; then WSRC="$(tr -d '\r' < "$SPEC_DIR/parallelization.md")"; fi
fi
WAVE_ITEMS=""
if [ -n "$WSRC" ]; then
  WAVE_ITEMS="$(printf '%s\n' "$WSRC" | wave_list | awk -F'\t' -v w="$WAVE_N" '$1 == w && !seen[$2]++ { print $2 }')"
fi
DECLARED=""
BD="$(backlog_dir "$SPEC_DIR")"
if [ -n "$BD" ] && [ -n "$WAVE_ITEMS" ]; then
  while IFS= read -r it; do
    [ -n "$it" ] || continue
    for f in "$BD/$it"*.md; do
      [ -f "$f" ] || continue
      case "$(basename "$f")" in "$it"[0-9]*) continue ;; esac
      DECLARED="$DECLARED$(impacted_files "$f" | tr '[:upper:]' '[:lower:]')
"
    done
  done <<EOF
$WAVE_ITEMS
EOF
fi
# Plan-declared allowances: plan.md '## Wave file allowances' rows
# '| Story-001 | `src/.../tests/x/**` `src/.../*.csproj` |'. Item 'any' applies to every wave.
if [ -f "$SPEC_DIR/plan.md" ] && [ -n "$WAVE_ITEMS" ]; then
  DECLARED="$DECLARED$(section "$SPEC_DIR/plan.md" 'wave file allowances' | awk -v items="$(printf '%s' "$WAVE_ITEMS" | tr '\n' ' ')" '
    BEGIN { n = split(items, a, " "); for (i = 1; i <= n; i++) ok[a[i]] = 1 }
    function trim(s) { gsub(/^[ \t*`]+|[ \t*`]+$/, "", s); return s }
    /^[ \t]*\|/ {
      if ($0 ~ /^[ \t]*\|[ \t:|-]*$/) next
      m = split($0, c, "|"); if (m < 3) next
      it = trim(c[2])
      if (!(it in ok) && tolower(it) != "any") next
      for (k = 3; k <= m; k++) {
        r = c[k]
        while (match(r, /`[^`]+`/)) {
          p = substr(r, RSTART + 1, RLENGTH - 2); r = substr(r, RSTART + RLENGTH)
          gsub(/^[ \t]+|[ \t]+$/, "", p); gsub(/\\/, "/", p); sub(/^\.\//, "", p); sub(/\/\*\*$/, "/", p)
          if (p != "") print tolower(p)
        }
      }
    }')
"
fi
PREL="$(rel "$SPEC_DIR")/plan.md"
ITEMS_CSV="$(printf '%s' "$WAVE_ITEMS" | tr '\n' ',' | sed 's/,$//; s/,/, /g')"
if [ -z "$WAVE_ITEMS" ]; then
  violation "WAVE-003" "error" "planner" "$(basename "$SPEC_DIR") has no items for wave $WAVE_N in plan.md '## Waves' (or legacy parallelization.md)." "$PREL"
fi

# --- changed files ---
CHANGED=""
MODE=""
BASE_USED=""
if command -v git >/dev/null 2>&1 && gitc rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  MODE="git"
  HAS_HEAD=0
  if gitc rev-parse --verify --quiet 'HEAD^{commit}' >/dev/null 2>&1; then HAS_HEAD=1; fi
  if [ -n "$BASE" ]; then BASE_USED="$BASE"
  elif [ "$HAS_HEAD" -eq 1 ]; then
    BASE_USED="$(gitc tag -l 'kcc/cp-*' --sort=-creatordate 2>/dev/null | head -n 1 || true)"
    if [ -z "$BASE_USED" ]; then BASE_USED="HEAD"; fi
  fi
  if [ -n "$BASE_USED" ]; then
    gitc rev-parse --verify --quiet "$BASE_USED^{commit}" >/dev/null 2>&1 || usage_fail "git base not found: $BASE_USED"
    CHANGED="$(gitc diff --name-only --relative "$BASE_USED" 2>/dev/null || true)"
  else
    BASE_USED="(no commits)"
    CHANGED="$(gitc ls-files 2>/dev/null || true)"
  fi
  CHANGED="$CHANGED
$(gitc ls-files --others --exclude-standard 2>/dev/null || true)"
else
  MANIFEST="$REPO_ROOT/coordination/checkpoints/latest.manifest"
  if [ -n "$BASE" ]; then
    if [ -f "$BASE" ]; then MANIFEST="$BASE"
    elif [ -f "$REPO_ROOT/$BASE" ]; then MANIFEST="$REPO_ROOT/$BASE"
    else usage_fail "not a git repository and base manifest not found: $BASE"; fi
  fi
  [ -f "$MANIFEST" ] || usage_fail "not a git repository and no coordination/checkpoints/latest.manifest to compare against."
  MODE="manifest"
  BASE_USED="$(rel "$MANIFEST")"
  KNOWN="$(tr -d '\r' < "$MANIFEST" | awk -F'\t' 'NF >= 2 { p = $1; gsub(/^[ \t]+|[ \t]+$/, "", p); gsub(/\\/, "/", p); sub(/^\.\//, "", p); h = tolower($2); gsub(/[ \t]/, "", h); if (p != "") print tolower(p) "\t" h "\t" p }')"
  CUR=""
  if [ -d "$REPO_ROOT/src" ]; then
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      r="$(rel "$f")"
      if ignored "$r"; then continue; fi
      CUR="$CUR$(lower "$r")$TAB$(sha256_of "$f")$TAB$r
"
    done <<EOF
$(find "$REPO_ROOT/src" -type f 2>/dev/null)
EOF
  fi
  CHANGED="$({ printf '%s\n' "$KNOWN"; echo "@@"; printf '%s' "$CUR"; } | awk -F'\t' '
    $0 == "@@" { part = 2; next }
    part != 2 { if ($1 != "") { k[$1] = $2; orig[$1] = $3 } next }
    $1 != "" { seen[$1] = 1; if (!($1 in k) || k[$1] != $2) print $3 }
    END { for (p in k) if (substr(p, 1, 4) == "src/" && !(p in seen)) print orig[p] }')"
fi

# --- WAVE-001 ---
SRC_CHANGED=0
while IFS= read -r c; do
  [ -n "$c" ] || continue
  r="${c//\\//}"
  low="$(lower "$r")"
  case "$low" in src/*) ;; *) continue ;; esac
  if ignored "$r"; then continue; fi
  SRC_CHANGED=$((SRC_CHANGED + 1))
  ok=0
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    if [ "$d" = "$low" ]; then ok=1; break; fi
    case "$d" in
      */) case "$low" in "$d"*) ok=1; break ;; esac ;;
      *\**) case "$low" in $d) ok=1; break ;; esac ;;
    esac
  done <<EOF
$DECLARED
EOF
  if [ "$ok" -eq 0 ]; then
    violation "WAVE-001" "error" "implementer" "$r changed but is not in the Impacted Files of any wave $WAVE_N item ($ITEMS_CSV)." "$r"
  fi
done <<EOF
$(printf '%s\n' "$CHANGED" | grep -v '^$' | LC_ALL=C sort -u || true)
EOF

# --- WAVE-002 ---
TEST_EXIT="null"
if [ -n "$TEST_COMMAND" ]; then
  rc=0
  (cd "$REPO_ROOT" && bash -c "$TEST_COMMAND") 1>&2 || rc=$?
  TEST_EXIT="$rc"
  if [ "$rc" -ne 0 ]; then
    violation "WAVE-002" "error" "implementer" "Test command failed with exit $rc: $TEST_COMMAND" ""
  fi
fi

STATUS="pass"
if [ "$ERRORS" -gt 0 ]; then STATUS="fail"; fi
if [ "$JSON" -eq 1 ]; then
  printf '{"tool":"check-wave-scope","version":"%s","scope":"%s","spec":"%s","wave":%d,"mode":"%s","base":"%s","src_changed":%d,"test_exit":%s,"errors":%d,"warnings":%d,"status":"%s","violations":[%s]}\n' \
    "$TOOL_VERSION" "$(je "$SCOPE")" "$(je "$SPEC")" "$WAVE_N" "$MODE" "$(je "$BASE_USED")" "$SRC_CHANGED" "$TEST_EXIT" "$ERRORS" "$WARNINGS" "$STATUS" "$VJSON"
else
  echo "KCC wave scope: $SPEC wave $WAVE_N (mode: $MODE, base: $BASE_USED, src changes: $SRC_CHANGED)"
  printf '%s' "$HUMAN"
  echo "Errors: $ERRORS  Warnings: $WARNINGS"
fi
if [ "$ERRORS" -gt 0 ]; then exit 1; fi
exit 0
