#!/usr/bin/env bash
# KCC framework (c) 2026 Tarek Fawaz, https://tikasway.dev/kcc. Licensed under the terms in LICENSE.
#
# Deterministic conformance linter over a KCC run's OUTPUT (not the framework).
# Mirror of check-run-conformance.ps1 (same scopes, IDs, exit codes). Read-only.
# Contract: .KCC/kernel/contracts/tool-contract.md
#
# Usage:
#   bash .KCC/tools/check-run-conformance.sh [--repo-root PATH] [--json] [--spec SPEC-ID]
#        [--scope all|architecture|linking|trace|memory|token|idea|specs|plan|review|bugs]
#
# Exit: 0 pass, 1 errors found, 2 usage/environment error.

set -euo pipefail

TOOL_VERSION="2.0.0"
REPO_ROOT=""
SCOPE="all"
SPEC=""
JSON=0

while [ $# -gt 0 ]; do
  case "$1" in
    --repo-root) REPO_ROOT="${2:-}"; shift 2 ;;
    --scope) SCOPE="${2:-}"; shift 2 ;;
    --spec) SPEC="${2:-}"; shift 2 ;;
    --json) JSON=1; shift ;;
    -h|--help) sed -n '2,13p' "$0"; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

case "$SCOPE" in
  all|architecture|linking|trace|memory|token|idea|specs|plan|review|bugs) ;;
  *) echo "unknown scope: $SCOPE" >&2; exit 2 ;;
esac

TOOL_DIR="$(cd "$(dirname "$0")" && pwd)"
if [ -z "$REPO_ROOT" ]; then
  PARENT="$(dirname "$TOOL_DIR")"
  if [ "$(basename "$PARENT")" = ".KCC" ]; then REPO_ROOT="$(dirname "$PARENT")"; else REPO_ROOT="$PARENT"; fi
fi
if [ ! -d "$REPO_ROOT" ]; then echo "workspace not found: $REPO_ROOT" >&2; exit 2; fi
REPO_ROOT="$(cd "$REPO_ROOT" && pwd)"

ARCH_DIR="$REPO_ROOT/architecture"
SPECS_DIR="$REPO_ROOT/specs"
IDEATION_DIR="$REPO_ROOT/ideation"
TRACES_DIR="$REPO_ROOT/Traces"
MEMORY_DIR="$REPO_ROOT/memory"

ERRORS=0
WARNINGS=0
VJSON=""
TAB="$(printf '\t')"

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

lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

rel() { printf '%s' "${1#"$REPO_ROOT"/}"; }

violation() { # id severity owner message [file]
  local id="$1" sev="$2" owner="$3" msg="$4" file="${5:-}" obj
  if [ "$sev" = "error" ]; then ERRORS=$((ERRORS + 1)); else WARNINGS=$((WARNINGS + 1)); fi
  obj="{\"id\":\"$(je "$id")\",\"code\":\"$(je "$id")\",\"severity\":\"$sev\",\"fix_owner\":\"$(je "$owner")\",\"owner\":\"$(je "$owner")\",\"file\":\"$(je "$file")\",\"message\":\"$(je "$msg")\"}"
  if [ -z "$VJSON" ]; then VJSON="$obj"; else VJSON="$VJSON,$obj"; fi
  if [ "$JSON" -eq 0 ]; then
    printf '[%s] %s (%s) %s: %s\n' "$(printf '%s' "$sev" | tr '[:lower:]' '[:upper:]')" "$id" "$owner" "$file" "$msg"
  fi
  return 0
}

has_mermaid() { grep -qE '^[[:space:]]*```mermaid' "$1" 2>/dev/null; }

# ---------------------------------------------------------------------------
# Settings (spec_sizing)
# ---------------------------------------------------------------------------
setting() { # key default
  local f="$REPO_ROOT/.KCC/settings.json" v=""
  if [ -f "$f" ]; then
    v="$(grep -oE "\"$1\"[[:space:]]*:[[:space:]]*[0-9]+" "$f" 2>/dev/null | head -n 1 | grep -oE '[0-9]+$' || true)"
  fi
  if [ -n "$v" ]; then printf '%s' "$v"; else printf '%s' "$2"; fi
}
MAX_ITEMS="$(setting max_items 6)"
MAX_FILES="$(setting max_files_per_item 5)"
MAX_TESTS="$(setting max_tests_per_item 8)"
MAX_SPEC_LINES="$(setting max_spec_lines 150)"

# ---------------------------------------------------------------------------
# Markdown helpers (mirrored 1:1 in check-run-conformance.ps1)
# ---------------------------------------------------------------------------
has_heading() { # file heading-regex (case-insensitive)
  grep -qiE "^##[[:space:]]+$2" "$1" 2>/dev/null
}

section() { # file heading-regex -> lines between '## heading' and next '## '
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

table_field() { # file column -> value of column in first data row of first table; __NOCOL__ if absent
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
    case "$(basename "$d")" in
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
    n="$(basename "$f")"
    key="$(printf '%s' "$n" | grep -oE '^(Story|Enabler|Bug)-[0-9]+' || true)"
    [ -n "$key" ] || continue
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
    name="$(basename "$d")"
    [ -f "$d/$name.md" ] || continue
    id="$(printf '%s' "$name" | grep -oE '^SPEC-[0-9]+' || true)"
    [ -n "$id" ] || continue
    group="$(dirname "$d")"
    idea="$(basename "$group" | grep -oE '^IDEA-[0-9]+' || true)"
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
  s="$(lower "$SPEC")"; n="$(lower "$1")"
  if [ "$n" = "$s" ] || [ "$(lower "$2")" = "$s" ]; then return 0; fi
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
    for h in "Reasoning" "Phases" "Upfront Budget" "Effort Estimate"; do
      if ! has_heading "$idea" "$h"; then
        violation "IDEA-001" "error" "idea-interrogator" "$r is missing required section '## $h'." "$r"
      fi
    done
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
    for a in Questionnaire.md HumanAnswers.md Research.md ROI.md Conclusion.md QuickRoadmap.md SpecWriterStarter.md; do
      if [ ! -f "$dir/$a" ]; then
        violation "IDEA-004" "error" "idea-interrogator" "$(rel "$dir") is missing required artifact $a." "$(rel "$dir")/$a"
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
      nf="$(impacted_files "$it_file" | awk 'END { print NR }')"
      if [ "$nf" -gt "$MAX_FILES" ]; then
        violation "SZ-3" "$sev" "spec-writer" "$ir lists $nf impacted files (max $MAX_FILES). Split the item." "$ir"
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
check_plan() {
  local specs id name dir file group idea legacy plan prel rank tests it_key it_type it_file ac n waves itemfiles
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
      if { [ -n "$SPEC" ] && [ "$SCOPE" = "plan" ]; } || [ "$rank" -ge 2 ]; then
        violation "PLAN-001" "error" "planner" "$name has no plan.md (spec status requires a plan)." "$prel"
      fi
      continue
    fi
    if ! has_heading "$plan" "Waves" && [ ! -f "$dir/parallelization.md" ]; then
      violation "PLAN-002" "error" "planner" "$prel has no '## Waves' section (and no legacy parallelization.md)." "$prel"
    fi
    if ! has_heading "$plan" "Atomic test cases"; then
      violation "PLAN-003" "error" "planner" "$prel has no '## Atomic test cases' section." "$prel"
    fi
    tests="$(plan_tests "$plan")"
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
  case "$st" in open|fixing) return 0 ;; esac
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
  local items specs id name dir file group idea legacy it_key it_type it_file br spec_done test_ids f v src sev st rt
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
        case "$(lower "$st")" in open|fixing|fixed|verified|wontfix) ;; *) violation "BUG-002" "error" "human" "$br Status '$st' is not open|fixing|fixed|verified|wontfix." "$br" ;; esac
      fi
      if [ "$spec_done" = "1" ] && open_severe_bug "$it_file"; then
        violation "BUG-003" "error" "human" "$br is an $(lower "$st") $(lower "$sev") bug but $id is Done/APPROVED." "$br"
      fi
      case "$(lower "$st")" in
        fixing|fixed|verified)
          rt="$(table_field "$it_file" 'Regression test')"
          if [ "$rt" = "__NOCOL__" ]; then rt=""; fi
          rt="$(printf '%s' "$rt" | grep -oE '[A-Za-z]+-[0-9]+' | head -n 1 || true)"
          if [ -z "$rt" ]; then
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

if [ "$JSON" -eq 0 ]; then echo "KCC run conformance: $REPO_ROOT  (scope: $SCOPE)"; fi

case "$SCOPE" in
  all) check_architecture; check_linking; check_trace; check_memory; check_token; check_idea; check_specs; check_plan; check_review; check_bugs ;;
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
