#!/usr/bin/env bash
# KCC framework (c) 2026 Tarek Fawaz, https://tikasway.dev/kcc. Licensed under the terms in LICENSE.
#
# Deterministic conformance linter over a KCC run's OUTPUT (not the framework).
# Mirror of check-run-conformance.ps1 (same scopes, IDs, exit codes). Read-only.
# Contract: .KCC/kernel/contracts/tool-contract.md
#
# Usage:
#   bash .KCC/tools/check-run-conformance.sh [--repo-root PATH] [--json] [--spec SPEC-ID]
#        [--scope all|architecture|linking|trace|memory|token|idea|specs|plan|review|bugs|deep]
#        [--run-profile fasttrack]   (auto-detected from coordination/run/run.json)
#
# Exit: 0 pass, 1 errors found, 2 usage/environment error.

set -euo pipefail

TOOL_VERSION="2.0.0"
REPO_ROOT=""
SCOPE="all"
SPEC=""
RUN_PROFILE=""
JSON=0

while [ $# -gt 0 ]; do
  case "$1" in
    --repo-root) REPO_ROOT="${2:-}"; shift 2 ;;
    --scope) SCOPE="${2:-}"; shift 2 ;;
    --spec) SPEC="${2:-}"; shift 2 ;;
    --run-profile) RUN_PROFILE="${2:-}"; shift 2 ;;
    --json) JSON=1; shift ;;
    -h|--help) sed -n '2,13p' "$0"; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

case "$RUN_PROFILE" in
  ""|fasttrack) ;;
  *) echo "unknown run profile: $RUN_PROFILE (valid: fasttrack)" >&2; exit 2 ;;
esac

case "$SCOPE" in
  all|architecture|linking|trace|memory|token|idea|specs|plan|review|bugs|deep) ;;
  *) echo "unknown scope: $SCOPE" >&2; exit 2 ;;
esac

case "$0" in */*) TOOL_DIR="${0%/*}" ;; *) TOOL_DIR="." ;; esac
case "$TOOL_DIR" in /*) ;; *) TOOL_DIR="$PWD/$TOOL_DIR" ;; esac
if [ -z "$REPO_ROOT" ]; then
  TOOL_DIR="$(cd "$TOOL_DIR" && pwd)"
  PARENT="$(dirname "$TOOL_DIR")"
  if [ "$(basename "$PARENT")" = ".KCC" ]; then REPO_ROOT="$(dirname "$PARENT")"; else REPO_ROOT="$PARENT"; fi
fi
if [ ! -d "$REPO_ROOT" ]; then echo "workspace not found: $REPO_ROOT" >&2; exit 2; fi
case "$REPO_ROOT" in
  /*) # an absolute path without dot segments is already what `cd && pwd` would print; skip the fork
    case "$REPO_ROOT/" in */./*|*/../*|*//*) REPO_ROOT="$(cd "$REPO_ROOT" && pwd)" ;; *) REPO_ROOT="${REPO_ROOT%/}"; [ -n "$REPO_ROOT" ] || REPO_ROOT="/" ;; esac ;;
  *) REPO_ROOT="$(cd "$REPO_ROOT" && pwd)" ;;
esac

ARCH_DIR="$REPO_ROOT/architecture"
SPECS_DIR="$REPO_ROOT/specs"
IDEATION_DIR="$REPO_ROOT/ideation"
TRACES_DIR="$REPO_ROOT/Traces"
MEMORY_DIR="$REPO_ROOT/memory"

ERRORS=0
WARNINGS=0
VJSON=""
TAB=$'\t'

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------
je() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\t'/\\t}"
  s="${s//$'\r'/}"
  s="${s//$'\n'/\\n}"
  printf '%s' "$s"
}
# jev: je into JV (no command substitution, so no fork); lc: lower-case $1 into LC. Git Bash on Windows pays ~0.3 s per fork, and
# `$(...)` is a fork, so the hot helpers hand their result back in a variable. ${x,,} needs bash 4; macOS bash 3.2 falls back to tr.
jev() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\t'/\\t}"
  s="${s//$'\r'/}"
  JV="${s//$'\n'/\\n}"
}
if [ "${BASH_VERSINFO[0]}" -ge 4 ]; then
  eval 'lc() { LC="${1,,}"; }'
else
  lc() { LC="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"; }
fi

lower() { lc "$1"; printf '%s' "$LC"; }

rel() { printf '%s' "${1#"$REPO_ROOT"/}"; }

violation() { # id severity owner message [file]
  local id="$1" sev="$2" owner="$3" msg="$4" file="${5:-}" obj ej eo ef em
  if [ "$sev" = "error" ]; then ERRORS=$((ERRORS + 1)); else WARNINGS=$((WARNINGS + 1)); fi
  jev "$id"; ej="$JV"; jev "$owner"; eo="$JV"; jev "$file"; ef="$JV"; jev "$msg"; em="$JV"
  obj="{\"id\":\"$ej\",\"code\":\"$ej\",\"severity\":\"$sev\",\"fix_owner\":\"$eo\",\"owner\":\"$eo\",\"file\":\"$ef\",\"message\":\"$em\"}"
  if [ -z "$VJSON" ]; then VJSON="$obj"; else VJSON="$VJSON,$obj"; fi
  if [ "$JSON" -eq 0 ]; then
    case "$sev" in error) sev="ERROR" ;; warning) sev="WARNING" ;; *) sev="$(printf '%s' "$sev" | tr '[:lower:]' '[:upper:]')" ;; esac
    printf '[%s] %s (%s) %s: %s\n' "$sev" "$id" "$owner" "$file" "$msg"
  fi
  return 0
}

has_mermaid() { grep -qE '^[[:space:]]*```mermaid' "$1" 2>/dev/null; }

# ---------------------------------------------------------------------------
# Settings (spec_sizing)
# ---------------------------------------------------------------------------
# settings.json is read once; setting sets SV to the first `"key": <digits>` (the grep -oE | head -n 1 it replaces, without the processes).
SETTINGS_TXT=""
if [ -f "$REPO_ROOT/.KCC/settings.json" ]; then SETTINGS_TXT="$(<"$REPO_ROOT/.KCC/settings.json")"; fi
setting() { # key default -> SV
  local re="\"$1\"[[:blank:]]*:[[:blank:]]*([0-9]+)"
  if [[ "$SETTINGS_TXT" =~ $re ]]; then SV="${BASH_REMATCH[1]}"; else SV="$2"; fi
}
setting max_items 6; MAX_ITEMS="$SV"
setting max_files_per_item 5; MAX_FILES="$SV"
setting max_tests_per_item 8; MAX_TESTS="$SV"
setting max_spec_lines 150; MAX_SPEC_LINES="$SV"
setting max_backlog_item_lines 80; MAX_BACKLOG_LINES="$SV"
setting max_plan_lines 250; MAX_PLAN_LINES="$SV"
# Checks the quality-gate tool implements; a plan's `## Gates coverage` row may say `check:<ID>` (PLAN-007).
# Keep in sync with check-run-conformance.ps1 ($GateChecks) and quality-gate.* .
GATE_CHECKS="QG-LOCK QG-BUILD QG-LINT QG-TEST QG-COV QG-SECRETS QG-DEPS QG-SAST QG-SBOM QG-IMAGE QG-STATIC"
setting max_brief_lines 100; MAX_BRIEF_LINES="$SV"
setting max_specs_fasttrack 8; MAX_SPECS_FAST="$SV"
setting max_per_run 2; MAX_DEEP="$SV"

# Fast-track profile: explicit --run-profile, else the current run's policy (kcc-run stores "fasttrack": "1").
FASTTRACK=0
if [ "$RUN_PROFILE" = "fasttrack" ]; then FASTTRACK=1
elif [ -z "$RUN_PROFILE" ] && [ -f "$REPO_ROOT/coordination/run/run.json" ]; then
  _ft_re='"fasttrack"[[:blank:]]*:[[:blank:]]*"?1"?([^0-9]|$)'; _ft_txt="$(<"$REPO_ROOT/coordination/run/run.json")"
  if [[ "$_ft_txt" =~ $_ft_re ]]; then FASTTRACK=1; fi
fi

# ---------------------------------------------------------------------------
# Markdown helpers (mirrored 1:1 in check-run-conformance.ps1)
# ---------------------------------------------------------------------------
has_heading() { # file heading-regex (case-insensitive)
  grep -qiE "^##[[:space:]]+$2" "$1" 2>/dev/null
}

section() { # file heading-regex -> lines between '## heading' and next '## '
  [ -f "$1" ] || return 0
  lc "$2"; awk -v pat="$LC" '
    { sub(/\r$/, "") }
    /^##[ \t]/ {
      if (inside) stop = 1
      if (!stop) { t = tolower($0); sub(/^##[ \t]+/, "", t); if (t ~ ("^" pat)) inside = 1 }
      next
    }
    inside && !stop { print }' "$1"
}

table_field() { # file column -> value of column in first data row of first table; __NOCOL__ if absent
  lc "$2"; awk -v col="$LC" '
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
  lc "$1"; t="${LC#"${LC%%[![:space:]]*}"}"
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

spec_status() { # spec-file
  local v
  v="$(table_field "$1" Status)"
  if [ -n "$v" ] && [ "$v" != "__NOCOL__" ]; then printf '%s' "$v"; return 0; fi
  v="$(tr -d '\r' < "$1" | grep -m 1 -E '^status:' | sed -E 's/^status:[[:space:]]*"?([^"]*)"?.*$/\1/' || true)"
  printf '%s' "$v"
}

backlog_dir() { # spec-dir -> Backlog folder with its real on-disk casing
  local d first=""
  for d in "$1"/*; do
    [ -d "$d" ] || continue
    case "${d##*/}" in
      Backlog) printf '%s' "$d"; return 0 ;;
      [Bb][Aa][Cc][Kk][Ll][Oo][Gg]) if [ -z "$first" ]; then first="$d"; fi ;;
    esac
  done
  printf '%s' "$first"
  return 0
}

list_items() { # spec-dir -> key \t type \t path
  local bd f n key
  bd="$(backlog_dir "$1")"
  [ -n "$bd" ] || return 0
  for f in "$bd"/*.md; do
    [ -f "$f" ] || continue
    n="${f##*/}"
    [[ "$n" =~ ^(Story|Enabler|Bug)-[0-9]+ ]] || continue
    key="${BASH_REMATCH[0]}"
    printf '%s\t%s\t%s\n' "$key" "${key%%-*}" "$f"
  done
  return 0
}

item_acs() { # item-file -> AC ids
  section "$1" 'acceptance criteria' | awk '
    {
      if (match($0, /^[ \t]*[-*][ \t]*(\[[ xX]\][ \t]*)?\**[ \t]*AC-[0-9]+/)) {
        s = substr($0, RSTART, RLENGTH); match(s, /AC-[0-9]+$/); a = substr(s, RSTART, RLENGTH)
        if (!(a in seen)) { seen[a] = 1; print a }
      }
    }'
}

impacted_files() { # item-file -> paths
  section "$1" 'impacted files' | awk '
    /^[ \t]*[-*][ \t]+[^ \t]/ {
      l = $0
      if (match(l, /`[^`]+`/)) p = substr(l, RSTART + 1, RLENGTH - 2)
      else { sub(/^[ \t]*[-*][ \t]+/, "", l); split(l, a, /[ \t]+/); p = a[1] }
      gsub(/^[ \t]+|[ \t]+$/, "", p); gsub(/\\/, "/", p); sub(/^\.\//, "", p)
      print p
    }'
}

plan_tests() { # plan-file -> id \t item \t ac
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

wave_list() { # stdin markdown -> wave \t item
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

spec_waves() { # spec-dir -> wave \t item (plan.md ## Waves, else legacy parallelization.md)
  local out=""
  if [ -f "$1/plan.md" ]; then out="$(section "$1/plan.md" 'waves')"; fi
  if [ -z "$out" ] && [ -f "$1/parallelization.md" ]; then
    out="$(section "$1/parallelization.md" 'waves')"
    if [ -z "$out" ]; then out="$(tr -d '\r' < "$1/parallelization.md")"; fi
  fi
  [ -n "$out" ] || return 0
  printf '%s\n' "$out" | wave_list
}

review_verdict() { # review-file -> APPROVED | CHANGES_NEEDED | TOOLCHAIN_DEFERRED | QUALITY_DEFERRED | ""
  [ -f "$1" ] || return 0
  awk '
    { sub(/\r$/, "") }
    !found {
      l = tolower($0)
      if (l ~ /verdict/ && match(l, /(^|[^a-z0-9_])(changes_needed|approved|toolchain-deferred|quality-deferred)([^a-z0-9_]|$)/)) {
        s = substr(l, RSTART, RLENGTH); gsub(/[^a-z_-]/, "", s); gsub(/-/, "_", s); print toupper(s); found = 1
      }
    }' "$1"
}

# All spec folders: id \t name \t dir \t file \t group \t idea \t legacy
ALL_SPECS=""
list_all_specs() {
  local d name id group idea legacy
  [ -d "$SPECS_DIR" ] || return 0
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    name="${d##*/}"
    [ -f "$d/$name.md" ] || continue
    [[ "$name" =~ ^SPEC-[0-9]+ ]] || continue
    id="${BASH_REMATCH[0]}"
    group="${d%/*}"
    idea=""; if [[ "${group##*/}" =~ ^IDEA-[0-9]+ ]]; then idea="${BASH_REMATCH[0]}"; fi
    legacy=0
    if [ -f "$d/backlog.md" ]; then legacy=1; fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$id" "$name" "$d" "$d/$name.md" "$group" "$idea" "$legacy"
  done <<EOF
$(find "$SPECS_DIR" -type d -name 'SPEC-*' 2>/dev/null | LC_ALL=C sort)
EOF
  return 0
}

spec_match() { # name id
  local s n
  [ -n "$SPEC" ] || return 0
  lc "$SPEC"; s="$LC"; lc "$1"; n="$LC"; lc "$2"
  if [ "$n" = "$s" ] || [ "$LC" = "$s" ]; then return 0; fi
  case "$n" in "$s"-*) return 0 ;; esac
  return 1
}

target_specs() {
  local id name dir file group idea legacy
  if [ -z "$ALL_SPECS" ]; then ALL_SPECS="$(list_all_specs)"; fi
  [ -n "$ALL_SPECS" ] || return 0
  while IFS="$TAB" read -r id name dir file group idea legacy; do
    [ -n "$id" ] || continue
    if spec_match "$name" "$id"; then printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$id" "$name" "$dir" "$file" "$group" "$idea" "$legacy"; fi
  done <<EOF
$ALL_SPECS
EOF
  return 0
}

# ---------------------------------------------------------------------------
# ARCHITECTURE
# ---------------------------------------------------------------------------
check_architecture() {
  [ -d "$ARCH_DIR" ] || return 0
  local md_count mmd_files doc size f sa name
  md_count=$(find "$ARCH_DIR" -type f -name '*.md' ! -name '.gitkeep' 2>/dev/null | wc -l | tr -d ' ')
  mmd_files=$(find "$ARCH_DIR" -type f -name '*.mmd' 2>/dev/null || true)
  if [ "$md_count" -eq 0 ] && [ -z "$mmd_files" ]; then return 0; fi

  doc="$ARCH_DIR/architecture.md"
  if [ ! -f "$doc" ]; then
    violation "ARCH-001" "error" "architect" "architecture/architecture.md is missing. The Architecture Document must exist (not a README hub)." "architecture/architecture.md"
  else
    size=$(wc -c < "$doc" | tr -d ' ')
    if [ "$size" -lt 800 ]; then
      violation "ARCH-002a" "error" "architect" "architecture/architecture.md is a stub ($size bytes). It must be a narrative document with embedded diagrams." "architecture/architecture.md"
    fi
    if ! has_mermaid "$doc"; then
      violation "ARCH-002b" "error" "architect" "architecture/architecture.md contains no embedded \`\`\`mermaid\`\`\` block. Diagrams must be embedded inline." "architecture/architecture.md"
    fi
  fi

  while IFS= read -r f; do
    [ -n "$f" ] || continue
    violation "ARCH-003" "error" "architect" "Deprecated loose diagram file: $(rel "$f"). Embed fenced \`\`\`mermaid\`\`\` in a .md instead." "$(rel "$f")"
  done <<EOF
$mmd_files
EOF

  for name in README.md readme.md; do
    if [ -f "$ARCH_DIR/$name" ]; then
      violation "ARCH-004" "error" "architect" "architecture/$name must not exist - the Architecture Document is architecture.md, not a README hub." "architecture/$name"
      break
    fi
  done

  # Fast-track profile (architecture-documentation.md -> required artifacts, column `fasttrack`): the
  # Architecture Document carries C1, C2, a Decisions table and the toolchain; flowcharts and quality
  # gates exist; ADR files, component diagrams, DFDs and sequences do not (over-production is drift).
  if [ "$FASTTRACK" -eq 1 ]; then
    if [ -f "$doc" ]; then
      grep -q 'C4Context' "$doc" || violation "ARCH-FT-001" "error" "architect" "fast track: architecture.md has no embedded C1 context diagram (C4Context)." "architecture/architecture.md"
      grep -q 'C4Container' "$doc" || violation "ARCH-FT-002" "error" "architect" "fast track: architecture.md has no embedded C2 container diagram (C4Container)." "architecture/architecture.md"
      grep -qE '^##+[[:space:]]+Decisions' "$doc" || violation "ARCH-FT-003" "error" "architect" "fast track: architecture.md has no '## Decisions' table (decision, library and version range, catalogue citation, status)." "architecture/architecture.md"
      grep -qE '^##+[[:space:]]+Toolchain' "$doc" || violation "ARCH-FT-004" "error" "architect" "fast track: architecture.md has no '## Toolchain' table." "architecture/architecture.md"
    fi
    if [ -z "$(find "$ARCH_DIR/flowcharts" -maxdepth 1 -type f -name '*.md' 2>/dev/null | head -n 1)" ]; then violation "ARCH-FT-005" "error" "architect" "fast track: architecture/flowcharts/ has no business flowchart." "architecture/flowcharts"; fi
    [ -f "$ARCH_DIR/quality-gates.md" ] || violation "ARCH-FT-006" "error" "architect" "fast track: architecture/quality-gates.md is missing." "architecture/quality-gates.md"
    if [ -n "$(find "$ARCH_DIR/adrs" -maxdepth 1 -type f -name 'ADR-*.md' 2>/dev/null | head -n 1)" ]; then violation "ARCH-FT-007" "error" "architect" "fast track records decisions in architecture.md -> ## Decisions, not in ADR files; remove architecture/adrs/." "architecture/adrs"; fi
    [ -f "$ARCH_DIR/c4-component.md" ] && violation "ARCH-FT-008" "error" "architect" "fast track writes no component diagram; remove architecture/c4-component.md." "architecture/c4-component.md"
    for extra in dfds sequences; do
      if [ -n "$(find "$ARCH_DIR/$extra" -maxdepth 1 -type f 2>/dev/null | head -n 1)" ]; then violation "ARCH-FT-009" "error" "architect" "fast track writes no $extra; remove architecture/$extra/." "architecture/$extra"; fi
    done
    return 0
  fi

  if [ -d "$SPECS_DIR" ]; then
    while IFS= read -r sa; do
      [ -n "$sa" ] || continue
      if ! has_mermaid "$sa"; then
        violation "ARCH-005" "error" "architect" "$(rel "$sa") has no embedded \`\`\`mermaid\`\`\` block (content bar). Spec arch.md must embed its design slice." "$(rel "$sa")"
      fi
    done <<EOF
$(find "$SPECS_DIR" -type f -name 'arch.md' 2>/dev/null)
EOF
  fi
  return 0
}

# ---------------------------------------------------------------------------
# LINKING
# ---------------------------------------------------------------------------
check_linking() {
  [ -d "$IDEATION_DIR" ] || return 0
  local idea idx note base parent r stripped
  while IFS= read -r idea; do
    [ -n "$idea" ] || continue
    if ! grep -qE '\[\[[^]]*-Specs' "$idea"; then
      violation "LINK-001" "error" "idea-interrogator" "$(rel "$idea") does not wikilink its specs index ([[...-Specs...]]). Idea must connect to its specs in the graph." "$(rel "$idea")"
    fi
  done <<EOF
$(find "$IDEATION_DIR" -type f -name 'idea-*.md' 2>/dev/null)
EOF

  [ -d "$SPECS_DIR" ] || return 0

  while IFS= read -r idx; do
    [ -n "$idx" ] || continue
    if ! grep -qE '\[\[[^]]*ideation' "$idx"; then
      violation "LINK-002" "error" "spec-writer" "$(rel "$idx") does not wikilink back to its idea ([[...ideation...]])." "$(rel "$idx")"
    fi
    if ! grep -qE '\[\[[^]]*SPEC-' "$idx"; then
      violation "LINK-003" "error" "spec-writer" "$(rel "$idx") does not wikilink any SPEC folder note." "$(rel "$idx")"
    fi
  done <<EOF
$(find "$SPECS_DIR" -type f -name 'IDEA-*-Specs.md' 2>/dev/null)
EOF

  while IFS= read -r note; do
    [ -n "$note" ] || continue
    base="$(basename "$note" .md)"
    parent="$(basename "$(dirname "$note")")"
    [ "$base" = "$parent" ] || continue
    r="$(rel "$note")"
    stripped="$(sed 's/\[\[[^]]*\]\]//g' "$note")"
    if grep -qE 'architecture[\\/](README|readme)' "$note"; then
      violation "LINK-004" "error" "spec-writer" "$r references architecture/README - link [[...architecture/architecture]] instead." "$r"
    fi
    if printf '%s\n' "$stripped" | grep -qE '\.\.[\\/].*architecture[\\/]'; then
      violation "LINK-005" "error" "spec-writer" "$r uses bare (non-wikilink) relative architecture paths - use [[wikilinks]] so the graph connects." "$r"
    fi
    if ! grep -qE '\[\[[^]]*architecture' "$note"; then
      violation "LINK-006" "error" "spec-writer" "$r does not wikilink the Architecture Document ([[...architecture/architecture]])." "$r"
    fi
    if ! grep -qE '\[\[[^]]*(Story|Enabler)-' "$note"; then
      violation "LINK-007" "error" "spec-writer" "$r does not wikilink its stories/enablers." "$r"
    fi
  done <<EOF
$(find "$SPECS_DIR" -type f -name 'SPEC-*.md' 2>/dev/null)
EOF
  return 0
}

# ---------------------------------------------------------------------------
# TRACE / MEMORY / TOKEN
# ---------------------------------------------------------------------------
latest_session() {
  local s
  s="$(ls -1dt "$TRACES_DIR"/Session-*/ 2>/dev/null | head -n 1 || true)"
  s="${s%/}"
  printf '%s' "$s"
}

check_trace() {
  [ "$FASTTRACK" -eq 0 ] || return 0
  [ -d "$TRACES_DIR" ] || return 0
  local latest r
  latest="$(latest_session)"
  if [ -z "$latest" ]; then
    violation "TRACE-000" "error" "butler" "No Traces/Session-* folder exists. Butler must create a trace session at run start." "Traces"
    return 0
  fi
  for r in Decisions.md Handovers.md Actions.md ToolsUsed.md HumanActions.md HumanDecisions.md TokenUsage.md; do
    if [ ! -f "$latest/$r" ]; then
      violation "TRACE-001" "error" "butler" "Trace session $(basename "$latest") is missing canonical file $r. Copy _session-template and use the 7 canonical files." "Traces/$(basename "$latest")"
    fi
  done
  return 0
}

substantive_run() {
  if [ -d "$ARCH_DIR" ] && [ "$(find "$ARCH_DIR" -type f -name '*.md' ! -name '.gitkeep' 2>/dev/null | wc -l | tr -d ' ')" -gt 0 ]; then return 0; fi
  if [ -d "$SPECS_DIR" ] && [ "$(find "$SPECS_DIR" -type f -name 'SPEC-*.md' 2>/dev/null | wc -l | tr -d ' ')" -gt 0 ]; then return 0; fi
  return 1
}

check_token() {
  [ "$FASTTRACK" -eq 0 ] || return 0
  [ -d "$TRACES_DIR" ] || return 0
  substantive_run || return 0
  local latest tf
  latest="$(latest_session)"
  [ -n "$latest" ] || return 0
  tf="$latest/TokenUsage.md"
  if [ ! -f "$tf" ]; then
    violation "TOKEN-001" "error" "butler" "Trace session $(basename "$latest") has no TokenUsage.md. Record actuals via record-token-actuals (SessionEnd hook / --manual-total / --unavailable)." "Traces/$(basename "$latest")"
    return 0
  fi
  if ! grep -qE '^[[:space:]]*source:[[:space:]]*(harness-reported|api-usage|manual-meter|unavailable)' "$tf"; then
    violation "TOKEN-001" "error" "butler" "TokenUsage.md in $(basename "$latest") has estimates only - no actual row (source: harness-reported|api-usage|manual-meter|unavailable). Run record-token-actuals at session end." "$(rel "$tf")"
  fi
  return 0
}

check_memory() {
  [ "$FASTTRACK" -eq 0 ] || return 0
  [ -d "$MEMORY_DIR" ] || return 0
  substantive_run || return 0
  local dec pre
  dec=$(find "$MEMORY_DIR/decisions" -type f -name '*.md' ! -name '.gitkeep' 2>/dev/null | wc -l | tr -d ' ')
  pre=$(find "$MEMORY_DIR/preferences" -type f -name '*.md' ! -name '.gitkeep' 2>/dev/null | wc -l | tr -d ' ')
  if [ "$((dec + pre))" -eq 0 ]; then
    violation "MEM-001" "error" "butler" 'A substantive run (ADRs/specs created) recorded no memory entries. Butler must write decisions/preferences via memory-append, or justify "none".' "memory"
  fi
  return 0
}

# ---------------------------------------------------------------------------
# IDEA
# ---------------------------------------------------------------------------
check_idea() {
  [ -d "$IDEATION_DIR" ] || return 0
  local idea r h dir a roi
  while IFS= read -r idea; do
    [ -n "$idea" ] || continue
    case "$(basename "$(dirname "$idea")")" in IDEA-*) ;; *) continue ;; esac
    r="$(rel "$idea")"
    idea_headings="Reasoning|Phases|Upfront Budget|Effort Estimate"
    if [ "$FASTTRACK" -eq 1 ]; then idea_headings="Reasoning|Phases"; fi
    while IFS= read -r h; do
      [ -n "$h" ] || continue
      if ! has_heading "$idea" "$h"; then
        violation "IDEA-001" "error" "idea-interrogator" "$r is missing required section '## $h'." "$r"
      fi
    done <<EOH
$(printf '%s\n' "$idea_headings" | tr '|' '\n')
EOH
    if grep -qiE 'input[ _-]?class[^[:alnum:]_]*existing-solution' "$idea"; then
      for h in "Impact Analysis" "Gap Analysis" "Alternatives"; do
        if ! has_heading "$idea" "$h"; then
          violation "IDEA-002" "error" "idea-interrogator" "$r declares input class existing-solution+idea but has no '## $h' section." "$r"
        fi
      done
    fi
    if grep -qiE '^[[:space:]]*(assume|silent)[[:space:]]*:[[:space:]]*true|--assume|--silent|^[[:space:]]*mode[[:space:]]*:.*(assume|silent)' "$idea"; then
      if ! has_heading "$idea" "Assumptions"; then
        violation "IDEA-003" "error" "idea-interrogator" "$r records assume/silent mode but has no '## Assumptions' section." "$r"
      fi
    fi
    dir="$(dirname "$idea")"
    idea_artifacts="Questionnaire.md HumanAnswers.md Research.md ROI.md Conclusion.md QuickRoadmap.md SpecWriterStarter.md"
    if [ "$FASTTRACK" -eq 1 ]; then idea_artifacts="Research.md QuickRoadmap.md SpecWriterStarter.md"; fi
    for a in $idea_artifacts; do
      if [ ! -f "$dir/$a" ]; then
        violation "IDEA-004" "error" "idea-interrogator" "$(rel "$dir") is missing required artifact $a." "$(rel "$dir")/$a"
      fi
    done
    for bf in "$dir"/*Brief.md; do
      [ -f "$bf" ] || continue
      bn="$(awk 'END { print NR }' "$bf")"
      if [ "$bn" -gt "$MAX_BRIEF_LINES" ]; then
        violation "BRIEF-001" "warning" "idea-interrogator" "$(rel "$bf") has $bn lines (max $MAX_BRIEF_LINES). Shorten it; keep decisions and one-line reasons." "$(rel "$bf")"
      fi
    done
    roi="$dir/ROI.md"
    if [ -f "$roi" ] && ! grep -qiE 'confidence.*[0-9]{1,3}(\.[0-9]+)?[[:space:]]*%' "$roi"; then
      violation "IDEA-005" "error" "idea-interrogator" "$(rel "$roi") has no ROI confidence percentage (e.g. 'ROI confidence: 80%')." "$(rel "$roi")"
    fi
  done <<EOF
$(find "$IDEATION_DIR" -type f -name 'idea-*.md' 2>/dev/null | LC_ALL=C sort)
EOF
  return 0
}

# ---------------------------------------------------------------------------
# SPECS
# ---------------------------------------------------------------------------
backlog_rows() { # spec-dir spec-file legacy -> key \t type \t link
  local src
  if [ "$3" = "1" ]; then src="$(tr -d '\r' < "$1/backlog.md")"; else src="$(section "$2" 'backlog')"; fi
  [ -n "$src" ] || return 0
  printf '%s\n' "$src" | awk '
    function trim(s) { gsub(/^[ \t*`]+|[ \t*`]+$/, "", s); return s }
    /^[ \t]*\|/ {
      n = split($0, c, "|"); if (n < 2) next
      k = trim(c[2])
      if (!match(k, /^\[?\[?(Story|Enabler|Bug)-[0-9]+/)) next
      kk = substr(k, RSTART, RLENGTH); match(kk, /(Story|Enabler|Bug)-[0-9]+/); key = substr(kk, RSTART, RLENGTH)
      type = key; sub(/-[0-9]+$/, "", type)
      link = ""
      if (match($0, /\[\[[^]|#]+/)) { link = substr($0, RSTART + 2, RLENGTH - 2); gsub(/^[ \t]+|[ \t]+$/, "", link); sub(/\\+$/, "", link); gsub(/[ \t]+$/, "", link) }
      print key "\t" type "\t" link
    }'
}

resolve_link() { # spec-dir link -> resolved path (or nothing)
  local t c1 bd
  [ -n "$2" ] || return 0
  t="${2//\\//}"
  case "$(lower "$t")" in *.md) ;; *) t="$t.md" ;; esac
  c1="$1/$t"
  if [ -f "$c1" ] && [ "$(lower "$(basename "$(dirname "$c1")")")" = "backlog" ]; then printf '%s' "$c1"; return 0; fi
  bd="$(backlog_dir "$1")"
  if [ -n "$bd" ] && [ -f "$bd/$(basename "$t")" ]; then printf '%s' "$bd/$(basename "$t")"; fi
  return 0
}

check_specs() {
  local specs id name dir file group idea legacy r sev h n rows key type link why counted it_key it_type it_file ir nf
  local groups g gsev all_legacy rm rt done6 dupes
  specs="$(target_specs)"
  if [ -n "$SPEC" ] && [ -z "$specs" ]; then
    violation "SPEC-000" "error" "spec-writer" "No spec folder matches $SPEC." "specs"
    return 0
  fi
  groups=""
  while IFS="$TAB" read -r id name dir file group idea legacy; do
    [ -n "$id" ] || continue
    r="$(rel "$file")"
    sev="error"
    if [ "$legacy" = "1" ]; then
      sev="warning"
      violation "SPEC-LEGACY" "warning" "spec-writer" "$name uses the legacy v5 layout (backlog.md). Findings are warnings; migrate per spec-layout 'Legacy v5 specs'." "$r"
    else
      for h in "Delivery Brief" "Acceptance Criteria" "Backlog" "Architecture"; do
        if ! has_heading "$file" "$h"; then
          violation "SPEC-001" "error" "spec-writer" "$r is missing required section '## $h'." "$r"
        fi
      done
      # The dashboard and the lifecycle read the spec's status from its frontmatter.
      if ! head -n 40 "$file" | tr -d '\r' | grep -qE '^status[[:space:]]*:[[:space:]]*[^[:space:]]'; then
        violation "SPEC-010" "error" "spec-writer" "$r has no 'status:' in its frontmatter." "$r"
      fi
      n="$(awk 'END { print NR }' "$file")"
      if [ "$n" -gt "$MAX_SPEC_LINES" ]; then
        violation "SZ-5" "error" "spec-writer" "$r has $n lines (max $MAX_SPEC_LINES). Move detail into backlog items or arch.md." "$r"
      fi
    fi
    if [ ! -f "$dir/arch.md" ]; then
      violation "SPEC-003" "$sev" "spec-writer" "$name has no arch.md." "$(rel "$dir")/arch.md"
    fi
    rows="$(backlog_rows "$dir" "$file" "$legacy")"
    counted=0
    while IFS="$TAB" read -r key type link; do
      [ -n "$key" ] || continue
      if [ "$type" != "Bug" ]; then counted=$((counted + 1)); fi
      if [ -z "$(resolve_link "$dir" "$link")" ]; then
        if [ -n "$link" ]; then why="wikilink [[$link]] does not resolve to a file under Backlog/"; else why="has no [[wikilink]] to its Backlog/ file"; fi
        violation "SPEC-002" "$sev" "spec-writer" "$r: backlog row $key $why." "$r"
      fi
    done <<EOF
$rows
EOF
    if [ "$counted" -gt "$MAX_ITEMS" ]; then
      violation "SZ-2" "$sev" "spec-writer" "$r has $counted stories/enablers (max $MAX_ITEMS). Split the spec." "$r"
    fi
    while IFS="$TAB" read -r it_key it_type it_file; do
      [ -n "$it_key" ] || continue
      [ "$it_type" != "Bug" ] || continue
      ir="$(rel "$it_file")"
      if ! grep -qiE '^[[:space:]]*(#{1,6}[[:space:]]*|[-*][[:space:]]*|\*\*)?INVEST([^[:alnum:]_]|$)' "$it_file"; then
        violation "SPEC-004" "$sev" "spec-writer" "$ir has no INVEST line/section." "$ir"
      fi
      il="$(awk 'END { print NR }' "$it_file")"
      if [ "$il" -gt "$MAX_BACKLOG_LINES" ]; then
        violation "SZ-6" "$sev" "spec-writer" "$ir has $il lines (max $MAX_BACKLOG_LINES). Keep the item to its ACs, impacted files, and INVEST line." "$ir"
      fi
      nf="$(impacted_files "$it_file" | awk 'END { print NR }')"
      if [ "$nf" -gt "$MAX_FILES" ]; then
        violation "SZ-3" "$sev" "spec-writer" "$ir lists $nf impacted files (max $MAX_FILES). Split the item." "$ir"
      fi
      # Greenfield code lives under src/IDEA-{ID}-{slug}/; traceability and the wave-scope gate look only there.
      badpath="$(impacted_files "$it_file" | awk '/^src\// && !/^src\/IDEA-/ { print; exit }')"
      if [ -n "$badpath" ]; then
        violation "SPEC-008" "error" "spec-writer" "$ir: impacted file '$badpath' is outside src/IDEA-{ID}-{slug}/." "$ir"
      fi
    done <<EOF
$(list_items "$dir")
EOF
    case "$TAB$groups$TAB" in *"$TAB$group$TAB"*) ;; *) groups="$groups$group$TAB" ;; esac
  done <<EOF
$specs
EOF

  # ROADMAP per idea group
  local IFS_OLD="$IFS"
  IFS="$TAB"
  for g in $groups; do
    IFS="$IFS_OLD"
    [ -n "$g" ] || continue
    all_legacy=1
    while IFS="$TAB" read -r id name dir file group idea legacy; do
      [ -n "$id" ] || continue
      if [ "$group" = "$g" ] && [ "$legacy" != "1" ]; then all_legacy=0; fi
    done <<EOF
$specs
EOF
    gsev="error"; if [ "$all_legacy" = "1" ]; then gsev="warning"; fi
    rm="$g/ROADMAP.md"
    if [ ! -f "$rm" ]; then
      violation "SPEC-005" "$gsev" "spec-writer" "$(rel "$g") has no ROADMAP.md." "$(rel "$g")/ROADMAP.md"
      IFS="$TAB"; continue
    fi
    # Fast track: a spec budget keeps the run small (each spec costs a writer, a plan, a build, a review).
    # The human sets the budget at SPECS; a larger split needs their recorded 'Spec budget: N (human)'.
    if [ "$FASTTRACK" -eq 1 ]; then
      budget="$MAX_SPECS_FAST"
      hb="$(tr -d '\r' < "$rm" | grep -iE '^[^[:alnum:]]*spec budget[^[:alnum:]]*[0-9]+.*human' | head -n 1 | grep -oE '[0-9]+' | head -n 1 || true)"
      [ -n "$hb" ] && budget="$hb"
      nspecs="$(printf '%s\n' "$specs" |awk -F'\t' -v g="$g" '$5 == g && $1 != "" && !seen[$1]++' | awk 'END { print NR }')"
      if [ "$nspecs" -gt "$budget" ]; then
        violation "SPEC-009" "error" "spec-writer" "$(rel "$g") has $nspecs specs; the fast-track budget is $budget. Merge specs into user-visible slices, or record the human's 'Spec budget: N (human approved)' in ROADMAP.md." "$(rel "$rm")"
      fi
    fi
    done6=""
    while IFS="$TAB" read -r id name dir file group idea legacy; do
      [ -n "$id" ] || continue
      [ "$group" = "$g" ] || continue
      case " $done6 " in *" $id "*) continue ;; esac
      done6="$done6 $id"
      if ! grep -qiE "${id}([^0-9]|\$)" "$rm"; then
        sev="error"; if [ "$legacy" = "1" ]; then sev="warning"; fi
        violation "SPEC-006" "$sev" "spec-writer" "$(rel "$rm") does not list $id." "$(rel "$rm")"
      fi
    done <<EOF
$specs
EOF
    IFS="$TAB"
  done
  IFS="$IFS_OLD"

  # Duplicate SPEC IDs across the whole specs tree
  if [ -z "$ALL_SPECS" ]; then ALL_SPECS="$(list_all_specs)"; fi
  dupes="$(printf '%s\n' "$ALL_SPECS" | cut -f1 | grep -v '^$' | LC_ALL=C sort | uniq -d || true)"
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    if [ -n "$SPEC" ] && ! printf '%s\n' "$specs" | cut -f1 | grep -qx "$id"; then continue; fi
    local where
    where="$(printf '%s\n' "$ALL_SPECS" | awk -F'\t' -v i="$id" '$1 == i { print $3 }' | while IFS= read -r p; do rel "$p"; printf ', '; done)"
    where="${where%, }"
    violation "SPEC-007" "error" "spec-writer" "Duplicate spec ID $id: $where." "specs"
  done <<EOF
$dupes
EOF
  return 0
}

# ---------------------------------------------------------------------------
# PLAN
# ---------------------------------------------------------------------------
# PLAN-007 helper: prints one problem per line (nothing when the plan's `## Gates coverage` is complete).
# Required: a row for every QG-* id on the plan's `Gates:` line and, when QG-PROD is cited, for every numbered
# item of the QG-PROD checklist table in quality-gates.md (a row says `QG-PROD-7`). `Covered by` holds
# Test IDs (T-007, T-024..T-029), `check:<QG-ID>` or `verifier:<step>`, separated by commas.
#
# Guardrails (round 11: GR-012 "declared libraries are the ones used" had no test or check): every active GR-nnn id
# in architecture/guardrails.md or the `## Guardrails` table of quality-gates.md / architecture.md also needs a row,
# `Covered by` the same forms, `static-rules:<rule-id>` (a rule id in architecture/static-rules.tsv) or `n/a:<reason>`.
guardrail_ids() { # -> active GR-nnn ids, one per line
  local f
  {
    if [ -f "$ARCH_DIR/guardrails.md" ]; then tr -d '\r' < "$ARCH_DIR/guardrails.md"; fi
    for f in quality-gates.md architecture.md; do
      if [ -f "$ARCH_DIR/$f" ]; then section "$ARCH_DIR/$f" 'guardrails'; fi
    done
  } | awk '
    function trim(s) { gsub(/^[ \t*`]+|[ \t*`]+$/, "", s); return s }
    !/^[ \t]*\|/ { si = 0; next }
    /^[ \t]*\|[ \t:|-]*$/ { next }
    {
      line = $0; gsub(/\\\|/, "/", line)
      n = split(line, c, "|")
      if (trim(c[2]) !~ /^GR-[0-9]+/) {
        if (tolower(trim(c[2])) == "id" || tolower(trim(c[2])) ~ /^(guardrail|#)$/) { si = 0; for (i = 1; i <= n; i++) if (tolower(trim(c[i])) == "status") si = i }
        next
      }
      id = trim(c[2]); match(id, /^GR-[0-9]+/); id = substr(id, RSTART, RLENGTH)
      if (si && si <= n && tolower(trim(c[si])) ~ /(retired|superseded|withdrawn|deprecated|obsolete)/) next
      if (!(id in seen)) { seen[id] = 1; print id }
    }'
}

static_rule_ids() { # -> rule ids of architecture/static-rules.tsv
  [ -f "$ARCH_DIR/static-rules.tsv" ] || return 0
  tr -d '\r' < "$ARCH_DIR/static-rules.tsv" | awk -F'\t' '/^#/ || NF < 2 { next } tolower($1) == "id" { next } $1 != "" { print $1 }'
}

gates_coverage_problems() { # plan-file quality-gates-file plan_tests-output
  local plan="$1" qg="$2" tests="$3" cited prod="" grs srs hassr=0
  cited="$(tr -d '\r' < "$plan" | grep -iE '^[[:space:]]*([-*][[:space:]]+)?[*_]*gates[[:space:]]*[*_]*[[:space:]]*:' | grep -oE 'QG-[A-Z0-9]+(-[A-Z0-9]+)*' | awk '!s[$0]++' || true)"
  grs="$(guardrail_ids)"
  srs="$(static_rule_ids)"
  if [ -f "$ARCH_DIR/static-rules.tsv" ]; then hassr=1; fi
  if [ -f "$qg" ] && printf '%s\n' "$cited" | grep -qx 'QG-PROD'; then
    prod="$(tr -d '\r' < "$qg" | awk '
      /^#/ { inside = ($0 ~ /QG-PROD/); next }
      inside && /^[ \t]*\|/ { c = $0; sub(/^[ \t]*\|[ \t]*/, "", c); if (c ~ /^[0-9]+[ \t]*\|/) { sub(/[ \t]*\|.*/, "", c); print c + 0 } }' | awk '!s[$0]++')"
  fi
  if ! has_heading "$plan" "Gates coverage"; then
    printf '%s\n' "has no '## Gates coverage' table (| Gate | Covered by |): map every architecture gate the plan cites (and every architecture guardrail GR-nnn) to Test IDs, check:<QG-ID>, verifier:<step> or static-rules:<rule-id>. A gate no quality-gate check implements needs a Test ID of its own in the atomic table (round 10: QG-STATIC had no test, the image scan was claimed but never run)."
    return 0
  fi
  {
    printf '@@T\n'; printf '%s\n' "$tests" | cut -f1
    printf '@@R\n'; printf '%s\n' "$cited"
    printf '@@P\n'; printf '%s\n' "$prod"
    printf '@@GR\n'; printf '%s\n' "$grs"
    printf '@@S\n'; printf '%s\n' "$srs"
    printf '@@G\n'; section "$plan" 'gates coverage' | tr -d '\r'
  } | awk -v checks="$GATE_CHECKS" -v hassr="$hassr" '
    function trim(s) { gsub(/^[ \t*`]+|[ \t*`]+$/, "", s); return s }
    function badpart(p, isgr,   n, k, tok, tk, e, lo, hi) {
      p = trim(p)
      if (p == "") return "empty entry"
      if (tolower(substr(p, 1, 13)) == "static-rules:") {
        tok = trim(substr(p, 14))
        if (tok == "") return "static-rules: names no rule id"
        if (!hassr) return "static-rules: but architecture/static-rules.tsv does not exist"
        n = split(tok, tk, /[ \t]+/)
        for (k = 1; k <= n; k++) if (tk[k] != "" && !(tk[k] in sr)) return "unknown static rule \"" tk[k] "\" (not in architecture/static-rules.tsv)"
        return ""
      }
      if (tolower(substr(p, 1, 4)) == "n/a:") {
        if (!isgr) return "n/a: is allowed only for a guardrail GR-nnn"
        if (trim(substr(p, 5)) == "") return "n/a: names no reason"
        return ""
      }
      if (tolower(substr(p, 1, 6)) == "check:") {
        tok = trim(substr(p, 7))
        if ((" " checks " ") !~ (" " tok " ")) return "unknown check \"" tok "\" (quality-gate implements: " checks ")"
        return ""
      }
      if (tolower(substr(p, 1, 9)) == "verifier:") {
        if (trim(substr(p, 10)) == "") return "verifier: names no step"
        return ""
      }
      n = split(p, tk, /[ \t]+/)
      for (k = 1; k <= n; k++) {
        if (tk[k] == "") continue
        e = index(tk[k], "..")
        if (e > 1) {
          lo = substr(tk[k], 1, e - 1); hi = substr(tk[k], e + 2)
          if (!(lo in tid)) return "\"" lo "\" is not a Test ID in ## Atomic test cases"
          if (!(hi in tid)) return "\"" hi "\" is not a Test ID in ## Atomic test cases"
        } else if (!(tk[k] in tid)) return "\"" tk[k] "\" is not a Test ID in ## Atomic test cases (use T-nnn, check:<QG-ID> or verifier:<step>)"
      }
      return ""
    }
    /^@@T$/ { part = "T"; next }
    /^@@R$/ { part = "R"; next }
    /^@@P$/ { part = "P"; next }
    /^@@G$/ { part = "G"; next }
    /^@@GR$/ { part = "GR"; next }
    /^@@S$/ { part = "S"; next }
    part == "GR" { if ($0 != "") greq[++ngr] = trim($0); next }
    part == "S" { if ($0 != "") sr[trim($0)] = 1; next }
    part == "T" { if ($0 != "") tid[trim($0)] = 1; next }
    part == "R" { if ($0 != "") { req[++nreq] = $0 }; next }
    part == "P" { if ($0 != "") { preq[++npreq] = $0 }; next }
    part == "G" {
      if ($0 !~ /^[ \t]*\|/) next
      line = $0; gsub(/\\\|/, "/", line)
      n = split(line, c, "|")
      if (!hdr) {
        for (i = 1; i <= n; i++) { t = tolower(trim(c[i])); if (t == "gate") gi = i; else if (t ~ /^covered/) ci = i }
        hdr = 1; next
      }
      if (line ~ /^[ \t]*\|[ \t:|-]*$/) next
      if (!gi || !ci || gi > n) next
      g = c[gi]; cov = (ci <= n) ? trim(c[ci]) : ""
      ids = ""; nonGr = 0
      while (match(g, /(^|[^A-Za-z0-9_-])GR-[0-9]+/)) {
        s = substr(g, RSTART, RLENGTH); sub(/^[^G]+/, "", s)
        ids = ids " " s
        g = substr(g, 1, RSTART - 1) " " substr(g, RSTART + RLENGTH)
      }
      while (match(g, /QG-PROD[-_ #.\/:]*([Ii]tem[ ]*)?[0-9]+/)) {
        s = substr(g, RSTART, RLENGTH); sub(/^QG-PROD[-_ #.\/:]*([Ii]tem[ ]*)?/, "", s)
        ids = ids " QG-PROD-" (s + 0); nonGr = 1
        g = substr(g, 1, RSTART - 1) " " substr(g, RSTART + RLENGTH)
      }
      while (match(g, /QG-[A-Z0-9]+(-[A-Z0-9]+)*/)) {
        ids = ids " " substr(g, RSTART, RLENGTH); nonGr = 1
        g = substr(g, 1, RSTART - 1) " " substr(g, RSTART + RLENGTH)
      }
      if (ids == "") next
      why = ""
      if (cov == "") why = "empty Covered by"
      else {
        np = split(cov, parts, /[;,]/)
        for (k = 1; k <= np && why == ""; k++) why = badpart(parts[k], !nonGr)
      }
      m = split(ids, idl, " ")
      for (k = 1; k <= m; k++) {
        if (idl[k] == "") continue
        named[idl[k]] = 1
        if (why == "") good[idl[k]] = 1
        else if (!((idl[k] SUBSEP why) in said)) { said[idl[k], why] = 1; bad[++nbad] = idl[k] ": " why }
      }
      next
    }
    END {
      for (i = 1; i <= nbad; i++) print "Gates coverage row " bad[i]
      miss = ""
      for (i = 1; i <= nreq; i++) {
        r = req[i]
        if (r == "QG-PROD" && npreq > 0) continue
        if (!(r in named)) miss = miss (miss == "" ? "" : ", ") r
      }
      for (i = 1; i <= npreq; i++) {
        r = "QG-PROD-" preq[i]
        if (!(r in named)) miss = miss (miss == "" ? "" : ", ") r
      }
      if (miss != "") print "## Gates coverage has no row for: " miss ". Add one per gate the plan cites (and one per numbered QG-PROD checklist item as QG-PROD-<n>)."
      gm = ""
      for (i = 1; i <= ngr; i++) if (!(greq[i] in named)) gm = gm (gm == "" ? "" : ", ") greq[i]
      if (gm != "") print "## Gates coverage has no row for guardrail(s): " gm ". Add one per architecture guardrail (Covered by: Test ID, check:<ID>, verifier:<step>, static-rules:<rule-id> or n/a:<reason>). Round 11: GR-012 (declared libraries are used) had no test or check, so the code ignored the Decisions table."
    }'
}

check_plan() {
  local specs id name dir file group idea legacy plan prel rank tests it_key it_type it_file ac n waves itemfiles grids
  specs="$(target_specs)"
  if [ -n "$SPEC" ] && [ -z "$specs" ]; then
    violation "SPEC-000" "error" "planner" "No spec folder matches $SPEC." "specs"
    return 0
  fi
  while IFS="$TAB" read -r id name dir file group idea legacy; do
    [ -n "$id" ] || continue
    plan="$dir/plan.md"
    prel="$(rel "$dir")/plan.md"
    if [ ! -f "$plan" ]; then
      rank="$(status_rank "$(spec_status "$file")")"
      if { [ -n "$SPEC" ] && [ "$SCOPE" = "plan" ]; } || [ "$rank" -ge 2 ] || [ "$FASTTRACK" -eq 1 ]; then
        violation "PLAN-001" "error" "planner" "$name has no plan.md (spec status requires a plan)." "$prel"
      fi
      continue
    fi
    pl="$(awk 'END { print NR }' "$plan")"
    if [ "$pl" -gt "$MAX_PLAN_LINES" ]; then
      violation "SZ-7" "error" "planner" "$prel has $pl lines (max $MAX_PLAN_LINES). Merge duplicate rows and move detail into the backlog items." "$prel"
    fi
    if ! has_heading "$plan" "Waves" && [ ! -f "$dir/parallelization.md" ]; then
      violation "PLAN-002" "error" "planner" "$prel has no '## Waves' section (and no legacy parallelization.md)." "$prel"
    fi
    if ! has_heading "$plan" "Atomic test cases"; then
      violation "PLAN-003" "error" "planner" "$prel has no '## Atomic test cases' section." "$prel"
    fi
    # The architecture cites standards with a verifier conformance check each; the plan says which Test ID or step covers it.
    if [ -f "$REPO_ROOT/architecture/architecture.md" ] && ! has_heading "$plan" "Standards coverage"; then
      violation "PLAN-006" "warning" "planner" "$prel has no '## Standards coverage' table: map each cited standard's verifier conformance check to a Test ID or a Verification Step (round 9: the plan said the OpenAPI document is generated at runtime, the API standard requires it checked in)." "$prel"
    fi
    tests="$(plan_tests "$plan")"
    # PLAN-007: every architecture gate the plan cites maps to a Test ID, a quality-gate check, or a verifier step.
    grids="$(guardrail_ids)"
    if [ "$legacy" != "1" ] && { [ -f "$ARCH_DIR/quality-gates.md" ] || [ -n "$grids" ]; }; then
      while IFS= read -r gmsg; do
        [ -n "$gmsg" ] || continue
        violation "PLAN-007" "error" "planner" "plan.md $gmsg" "$prel"
      done <<EOF
$(gates_coverage_problems "$plan" "$ARCH_DIR/quality-gates.md" "$tests")
EOF
    fi
    itemfiles=""
    while IFS="$TAB" read -r it_key it_type it_file; do
      [ -n "$it_key" ] || continue
      [ "$it_type" != "Bug" ] || continue
      itemfiles="$itemfiles$(impacted_files "$it_file" | awk -v k="$it_key" '{ print k "\t" $0 }')
"
      while IFS= read -r ac; do
        [ -n "$ac" ] || continue
        if ! printf '%s\n' "$tests" | awk -F'\t' -v k="$it_key" -v a="$ac" 'BEGIN { f = 1 } $2 == k && $3 ~ (a "([^0-9]|$)") { f = 0 } END { exit f }'; then
          violation "PLAN-004" "error" "planner" "$it_key $ac has no Test ID row in plan.md atomic test cases." "$prel"
        fi
      done <<EOF
$(item_acs "$it_file")
EOF
      n="$(printf '%s\n' "$tests" | awk -F'\t' -v k="$it_key" '$2 == k { c++ } END { print c + 0 }')"
      if [ "$n" -gt "$MAX_TESTS" ]; then
        violation "SZ-4" "error" "planner" "$it_key needs $n atomic tests (max $MAX_TESTS). Split the item." "$prel"
      fi
    done <<EOF
$(list_items "$dir")
EOF
    waves="$(spec_waves "$dir")"
    while IFS="$TAB" read -r w a b f; do
      [ -n "$w" ] || continue
      violation "PLAN-005" "error" "planner" "Wave $w: $a and $b both touch $f; items in one wave must have disjoint impacted files." "$prel"
    done <<EOF
$({ printf '%s\n' "$waves"; echo "@@"; printf '%s' "$itemfiles"; } | awk -F'\t' '
  $0 == "@@" { part = 2; next }
  part != 2 { if ($1 != "" && !(($1 SUBSEP $2) in seen)) { seen[$1, $2] = 1; nw[$1]++; wi[$1, nw[$1]] = $2; if (!($1 in wk)) { wk[$1] = 1; order[++nwv] = $1 } } next }
  $1 != "" { nf[$1]++; fl[$1, nf[$1]] = $2; has[$1] = 1 }
  END {
    for (o = 1; o <= nwv; o++) {
      w = order[o]
      for (x = 1; x <= nw[w]; x++) for (y = x + 1; y <= nw[w]; y++) {
        a = wi[w, x]; b = wi[w, y]
        if (!(a in has) || !(b in has)) continue
        for (i = 1; i <= nf[a]; i++) for (j = 1; j <= nf[b]; j++)
          if (tolower(fl[a, i]) == tolower(fl[b, j])) print w "\t" a "\t" b "\t" fl[a, i]
      }
    }
  }')
EOF
  done <<EOF
$specs
EOF
  return 0
}

# ---------------------------------------------------------------------------
# REVIEW
# ---------------------------------------------------------------------------
open_severe_bug() { # bug-file -> 0 when blocker|major and open|fixing
  local sev st
  sev="$(lower "$(table_field "$1" Severity)")"
  st="$(lower "$(table_field "$1" Status)")"
  case "$sev" in blocker|major) ;; *) return 1 ;; esac
  case "$st" in open|fixing|blocked) return 0 ;; esac
  return 1
}

check_review() {
  local specs id name dir file group idea legacy rev rrel rank verdict ev rc it_key it_type it_file
  specs="$(target_specs)"
  if [ -n "$SPEC" ] && [ -z "$specs" ]; then
    violation "SPEC-000" "error" "verifier" "No spec folder matches $SPEC." "specs"
    return 0
  fi
  while IFS="$TAB" read -r id name dir file group idea legacy; do
    [ -n "$id" ] || continue
    rev="$dir/review.md"
    rrel="$(rel "$dir")/review.md"
    if [ ! -f "$rev" ]; then
      rank="$(status_rank "$(spec_status "$file")")"
      if { [ -n "$SPEC" ] && [ "$SCOPE" = "review" ]; } || [ "$rank" -ge 5 ]; then
        violation "REV-001" "error" "verifier" "$name has no review.md." "$rrel"
      fi
      continue
    fi
    verdict="$(review_verdict "$rev")"
    if [ -z "$verdict" ]; then
      violation "REV-002" "error" "verifier" "$rrel has no verdict line (APPROVED | CHANGES_NEEDED | toolchain-deferred | quality-deferred)." "$rrel"
    fi
    if ! has_heading "$rev" "Evidence"; then
      violation "REV-003" "error" "verifier" "$rrel has no '## Evidence' section." "$rrel"
    else
      ev="$(section "$rev" 'evidence' | awk '
        /^[ \t]*```/ { fence = !fence; next }
        {
          if (fence && $0 ~ /[^ \t]/) cmd = 1
          if ($0 ~ /`[^`]+`/ || $0 ~ /^[ \t]*(\$|>|PS>)[ \t]*[^ \t]/) cmd = 1
          l = tolower($0)
          if (l ~ /exit[ _-]*(code)?[^0-9]*-?[0-9]/) ex = 1
          if ($0 ~ /^[ \t]*\|/ && l ~ /exit/) hdr = 1
          else if (hdr && $0 ~ /\|[ \t]*-?[0-9]+[ \t]*(\||$)/) ex = 1
        }
        END { if (cmd && ex) print "ok" }')"
      if [ "$ev" != "ok" ]; then
        violation "REV-003" "error" "verifier" "$rrel '## Evidence' needs at least one command line and its exit code." "$rrel"
      fi
    fi
    if [ "$verdict" = "APPROVED" ]; then
      rc=0
      bash "$TOOL_DIR/check-traceability.sh" --repo-root "$REPO_ROOT" --spec "$id" --json >/dev/null 2>&1 || rc=$?
      if [ "$rc" -ne 0 ]; then
        violation "REV-004" "error" "verifier" "$rrel is APPROVED but check-traceability fails for $id (exit $rc)." "$rrel"
      fi
      while IFS="$TAB" read -r it_key it_type it_file; do
        [ -n "$it_key" ] || continue
        [ "$it_type" = "Bug" ] || continue
        if open_severe_bug "$it_file"; then
          violation "REV-005" "error" "verifier" "$rrel is APPROVED but $it_key is an open blocker/major bug." "$rrel"
        fi
      done <<EOF
$(list_items "$dir")
EOF
    fi
  done <<EOF
$specs
EOF
  return 0
}

# ---------------------------------------------------------------------------
# BUGS
# ---------------------------------------------------------------------------
check_bugs() {
  local items specs id name dir file group idea legacy it_key it_type it_file br spec_done test_ids f v src sev st rt rq
  specs="$(target_specs)"
  while IFS="$TAB" read -r id name dir file group idea legacy; do
    [ -n "$id" ] || continue
    items="$(list_items "$dir")"
    case "$items" in *"${TAB}Bug${TAB}"*) ;; *) continue ;; esac
    spec_done=0
    if [ "$(status_rank "$(spec_status "$file")")" -ge 5 ] || [ "$(review_verdict "$dir/review.md")" = "APPROVED" ]; then spec_done=1; fi
    test_ids="$(plan_tests "$dir/plan.md" | cut -f1)"
    while IFS="$TAB" read -r it_key it_type it_file; do
      [ -n "$it_key" ] || continue
      [ "$it_type" = "Bug" ] || continue
      br="$(rel "$it_file")"
      for f in "Source" "Severity" "Status" "Story / AC" "Regression test"; do
        v="$(table_field "$it_file" "$f")"
        if [ "$v" = "__NOCOL__" ]; then
          violation "BUG-001" "error" "human" "$br bug table has no '$f' column." "$br"
        fi
      done
      src="$(table_field "$it_file" Source)"; sev="$(table_field "$it_file" Severity)"; st="$(table_field "$it_file" Status)"
      if [ "$src" != "__NOCOL__" ]; then
        case "$(lower "$src")" in human|verifier) ;; *) violation "BUG-002" "error" "human" "$br Source '$src' is not human|verifier." "$br" ;; esac
      fi
      if [ "$sev" != "__NOCOL__" ]; then
        case "$(lower "$sev")" in blocker|major|minor) ;; *) violation "BUG-002" "error" "human" "$br Severity '$sev' is not blocker|major|minor." "$br" ;; esac
      fi
      if [ "$st" != "__NOCOL__" ]; then
        case "$(lower "$st")" in open|fixing|fixed|verified|blocked|wontfix) ;; *) violation "BUG-002" "error" "human" "$br Status '$st' is not open|fixing|fixed|verified|blocked|wontfix." "$br" ;; esac
      fi
      if [ "$spec_done" = "1" ] && open_severe_bug "$it_file"; then
        violation "BUG-003" "error" "human" "$br is an $(lower "$st") $(lower "$sev") bug but $id is Done/APPROVED." "$br"
      fi
      case "$(lower "$st")" in
        blocked)
          # blocked = the fix needs a human ruling. It is its own finding (not BUG-OPEN: retrying the fix cannot help); the implementer writes
          # the '## Ruling needed' section once, and the message quotes it so the human sees the options without opening the file.
          rq="$(section "$it_file" 'ruling needed' | tr -d '\r' | tr '\n' ' ' | sed -e 's/  */ /g' -e 's/^ //' -e 's/ $//' | cut -c1-400)"
          if [ -z "$rq" ]; then
            violation "BUG-007" "error" "implementer" "$br is blocked but has no '## Ruling needed' section naming the options and the recommended one." "$br"
          fi
          violation "BUG-006" "error" "human" "$br is blocked and needs a human ruling: ${rq:-no ruling section written}" "$br"
          ;;
        fixing|fixed|verified)
          rt="$(table_field "$it_file" 'Regression test')"
          if [ "$rt" = "__NOCOL__" ]; then rt=""; fi
          rt_raw="$rt"
          rt="$(printf '%s' "$rt" | grep -oE '[A-Za-z]+-[0-9]+' | head -n 1 || true)"
          # A bug no test can express (a missing document, a gate) may say so: `n/a (<reason>)`. It is a warning, not a pass.
          if [ -z "$rt" ] && printf '%s' "$rt_raw" | grep -qE '^[[:space:]]*[Nn]/[Aa][[:space:]]*[(:-].{8,}'; then
            violation "BUG-005" "warning" "human" "$br has no regression Test ID: $(printf '%s' "$rt_raw" | tr -s ' ')" "$br"
          elif [ -z "$rt" ]; then
            violation "BUG-004" "error" "planner" "$br is $(lower "$st") but names no regression Test ID." "$br"
          elif ! printf '%s\n' "$test_ids" | grep -qxF "$rt"; then
            violation "BUG-004" "error" "planner" "$br regression test $rt is not in plan.md atomic test cases." "$br"
          fi
          ;;
      esac
    done <<EOF
$(list_items "$dir")
EOF
  done <<EOF
$specs
EOF
  return 0
}

# DeepThinking (protocols/deep-thinking.md): every deep-spawned needs an unused deep-approved for the same agent and
# task, orchestrator-started spawns (a human's /deep is not counted) stay within deep.max_per_run, and the task is in models.json -> deep_tasks. Counted since the latest
# auto-policy-parsed (one run).
check_deep() {
  local bc="$REPO_ROOT/coordination/backchannel.jsonl" mp="$REPO_ROOT/.KCC/kernel/models.json" cat="" out line
  [ -f "$bc" ] || return 0
  if [ -f "$mp" ]; then
    cat="$(tr -d '\r\n' < "$mp" | grep -oE '"deep_tasks"[[:space:]]*:[[:space:]]*\[[^]]*\]' | grep -oE '"[^"]+"' | grep -v '^"deep_tasks"$' | tr -d '"' | tr '\n' ' ' || true)"
  fi
  out="$(awk -v maxdeep="$MAX_DEEP" -v cat="$cat" '
    function field(l, name,   m, r) {
      r = "\"" name "\"[[:space:]]*:[[:space:]]*\"[^\"]*\""
      if (match(l, r)) { m = substr(l, RSTART, RLENGTH); sub(/^[^:]*:[[:space:]]*"/, "", m); sub(/"$/, "", m); return m }
      return ""
    }
    BEGIN { n = split(cat, arr, " "); for (i = 1; i <= n; i++) known[arr[i]] = 1 }
    { lines[NR] = $0; if ($0 ~ /"kind"[[:space:]]*:[[:space:]]*"auto-policy-parsed"/) start = NR }
    END {
      spawns = 0
      for (i = (start ? start : 1); i <= NR; i++) {
        l = lines[i]
        if (l ~ /"kind"[[:space:]]*:[[:space:]]*"deep-approved"/) { k = field(l, "agent") "|" field(l, "task"); ap[k]++ }
        else if (l ~ /"kind"[[:space:]]*:[[:space:]]*"deep-spawned"/) {
          a = field(l, "agent"); t = field(l, "task"); k = a "|" t
          if (l !~ /"initiator"[[:space:]]*:[[:space:]]*"human"/) spawns++
          if (ap[k] > 0) ap[k]--; else print "DEEP-001\tdeep-spawned (" a ", " t ") has no unused deep-approved event before it. A human must see the cost first."
          if (n > 0 && !(t in known)) print "DEEP-003\tdeep task " t " is not in models.json deep_tasks (" cat ")."
        }
      }
      if (spawns > maxdeep) print "DEEP-002\t" spawns " deep spawns in this run, max " maxdeep " (settings deep.max_per_run)."
    }' "$bc")"
  [ -n "$out" ] || return 0
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    violation "${line%%	*}" "error" "orchestrator" "${line#*	}" "coordination/backchannel.jsonl"
  done <<EOF
$out
EOF
  return 0
}

if [ "$JSON" -eq 0 ]; then echo "KCC run conformance: $REPO_ROOT  (scope: $SCOPE)"; fi

case "$SCOPE" in
  all) check_architecture; check_linking; check_trace; check_memory; check_token; check_idea; check_specs; check_plan; check_review; check_bugs; check_deep ;;
  architecture) check_architecture ;;
  linking) check_linking ;;
  trace) check_trace ;;
  memory) check_memory ;;
  token) check_token ;;
  idea) check_idea ;;
  specs) check_specs ;;
  plan) check_plan ;;
  review) check_review ;;
  bugs) check_bugs ;;
  deep) check_deep ;;
esac

STATUS="pass"
if [ "$ERRORS" -gt 0 ]; then STATUS="fail"; fi
if [ "$JSON" -eq 1 ]; then
  SPEC_JSON="null"
  if [ -n "$SPEC" ]; then SPEC_JSON="\"$(je "$SPEC")\""; fi
  printf '{"tool":"check-run-conformance","version":"%s","scope":"%s","spec":%s,"errors":%d,"warnings":%d,"status":"%s","repo_root":"%s","error_count":%d,"warn_count":%d,"violations":[%s]}\n' \
    "$TOOL_VERSION" "$SCOPE" "$SPEC_JSON" "$ERRORS" "$WARNINGS" "$STATUS" "$(je "$REPO_ROOT")" "$ERRORS" "$WARNINGS" "$VJSON"
else
  echo "Errors: $ERRORS  Warnings: $WARNINGS"
fi

if [ "$ERRORS" -gt 0 ]; then exit 1; fi
exit 0
