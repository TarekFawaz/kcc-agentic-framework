#!/usr/bin/env bash
# KCC framework (c) 2026 Tarek Fawaz, https://tikasway.dev/kcc. Licensed under the terms in LICENSE.
#
# Deterministic conformance linter over a KCC run's OUTPUT (not the framework).
# Mirror of check-run-conformance.ps1. Read-only.
#
# Usage:
#   bash .KCC/tools/check-run-conformance.sh [--repo-root PATH] [--scope all|architecture|linking|trace|memory|token|harness]
#
# Exit code 1 if any error-severity violation is found, else 0.

set -u

REPO_ROOT=""
SCOPE="all"

while [ $# -gt 0 ]; do
  case "$1" in
    --repo-root) REPO_ROOT="$2"; shift 2 ;;
    --scope) SCOPE="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

if [ -z "$REPO_ROOT" ]; then
  TOOL_DIR="$(cd "$(dirname "$0")" && pwd)"
  PARENT="$(dirname "$TOOL_DIR")"
  if [ "$(basename "$PARENT")" = ".KCC" ]; then
    REPO_ROOT="$(dirname "$PARENT")"
  else
    REPO_ROOT="$PARENT"
  fi
fi
REPO_ROOT="$(cd "$REPO_ROOT" && pwd)"

ARCH_DIR="$REPO_ROOT/architecture"
SPECS_DIR="$REPO_ROOT/specs"
IDEATION_DIR="$REPO_ROOT/ideation"
TRACES_DIR="$REPO_ROOT/Traces"
MEMORY_DIR="$REPO_ROOT/memory"
DSH_DIR="$REPO_ROOT/.dsh"
DSH_SKILLS_DIR="$DSH_DIR/skills"
CAP_SKILLS_DIR="$REPO_ROOT/.KCC/capabilities/skills"

ERRORS=0
WARNINGS=0

rel() { printf '%s' "${1#$REPO_ROOT/}"; }

violation() { # code severity owner message
  if [ "$2" = "error" ]; then ERRORS=$((ERRORS + 1)); else WARNINGS=$((WARNINGS + 1)); fi
  printf '  [%s] %s  (fix owner: %s)\n      %s\n' "$(printf '%s' "$2" | tr '[:lower:]' '[:upper:]')" "$1" "$3" "$4"
}

has_mermaid() { grep -qE '^[[:space:]]*```mermaid' "$1" 2>/dev/null; }

# Extract the first `key: value` scalar from a file's leading YAML frontmatter.
fm_scalar() {
  local file="$1" key="$2"
  awk -v key="$key" '
    NR == 1 && $0 == "---" { in_fm=1; next }
    in_fm && $0 == "---" { exit }
    in_fm && $0 ~ "^" key ":[[:space:]]*" {
      val=$0
      sub("^" key ":[[:space:]]*", "", val)
      if (val == ">" || val == "|") { next }
      sub(/[[:space:]]+$/, "", val)
      print val
      exit
    }
  ' "$file"
}

check_architecture() {
  [ -d "$ARCH_DIR" ] || return 0
  local md_count mmd_files populated
  md_count=$(find "$ARCH_DIR" -type f -name '*.md' ! -name '.gitkeep' 2>/dev/null | wc -l | tr -d ' ')
  mmd_files=$(find "$ARCH_DIR" -type f -name '*.mmd' 2>/dev/null)
  [ "$md_count" -gt 0 ] || [ -n "$mmd_files" ] || return 0

  local doc="$ARCH_DIR/architecture.md"
  if [ ! -f "$doc" ]; then
    violation "ARCH-001" "error" "architect" "architecture/architecture.md is missing. The Architecture Document must exist (not a README hub)."
  else
    local size
    size=$(wc -c < "$doc" | tr -d ' ')
    if [ "$size" -lt 800 ]; then
      violation "ARCH-002a" "error" "architect" "architecture/architecture.md is a stub ($size bytes). It must be a narrative document with embedded diagrams."
    fi
    if ! has_mermaid "$doc"; then
      violation "ARCH-002b" "error" "architect" "architecture/architecture.md contains no embedded \`\`\`mermaid\`\`\` block. Diagrams must be embedded inline."
    fi
  fi

  if [ -n "$mmd_files" ]; then
    while IFS= read -r f; do
      [ -n "$f" ] && violation "ARCH-003" "error" "architect" "Deprecated loose diagram file: $(rel "$f"). Embed fenced \`\`\`mermaid\`\`\` in a .md instead."
    done <<EOF
$mmd_files
EOF
  fi

  for name in README.md readme.md; do
    [ -f "$ARCH_DIR/$name" ] && violation "ARCH-004" "error" "architect" "architecture/$name must not exist - the Architecture Document is architecture.md, not a README hub."
  done

  if [ -d "$SPECS_DIR" ]; then
    while IFS= read -r sa; do
      [ -z "$sa" ] && continue
      if ! has_mermaid "$sa"; then
        violation "ARCH-005" "error" "architect" "$(rel "$sa") has no embedded \`\`\`mermaid\`\`\` block (content bar). Spec arch.md must embed its design slice."
      fi
    done <<EOF
$(find "$SPECS_DIR" -type f -name 'arch.md' 2>/dev/null)
EOF
  fi
}

check_linking() {
  [ -d "$IDEATION_DIR" ] || return 0

  while IFS= read -r idea; do
    [ -z "$idea" ] && continue
    grep -qE '\[\[[^]]*-Specs' "$idea" || violation "LINK-001" "error" "idea-interrogator" "$(rel "$idea") does not wikilink its specs index ([[...-Specs...]]). Idea must connect to its specs in the graph."
  done <<EOF
$(find "$IDEATION_DIR" -type f -name 'idea-*.md' 2>/dev/null)
EOF

  [ -d "$SPECS_DIR" ] || return 0

  while IFS= read -r idx; do
    [ -z "$idx" ] && continue
    grep -qE '\[\[[^]]*ideation' "$idx" || violation "LINK-002" "error" "spec-writer" "$(rel "$idx") does not wikilink back to its idea ([[...ideation...]])."
    grep -qE '\[\[[^]]*SPEC-' "$idx" || violation "LINK-003" "error" "spec-writer" "$(rel "$idx") does not wikilink any SPEC folder note."
  done <<EOF
$(find "$SPECS_DIR" -type f -name 'IDEA-*-Specs.md' 2>/dev/null)
EOF

  # SPEC folder notes: file basename equals its parent folder name.
  while IFS= read -r note; do
    [ -z "$note" ] && continue
    local base parent
    base="$(basename "$note" .md)"
    parent="$(basename "$(dirname "$note")")"
    [ "$base" = "$parent" ] || continue
    local r stripped
    r="$(rel "$note")"
    stripped="$(sed 's/\[\[[^]]*\]\]//g' "$note")"
    grep -qE 'architecture[\\/](README|readme)' "$note" && violation "LINK-004" "error" "spec-writer" "$r references architecture/README - link [[...architecture/architecture]] instead."
    printf '%s' "$stripped" | grep -qE '\.\.[\\/].*architecture[\\/]' && violation "LINK-005" "error" "spec-writer" "$r uses bare (non-wikilink) relative architecture paths - use [[wikilinks]] so the graph connects."
    grep -qE '\[\[[^]]*architecture' "$note" || violation "LINK-006" "error" "spec-writer" "$r does not wikilink the Architecture Document ([[...architecture/architecture]])."
    grep -qE '\[\[[^]]*(Story|Enabler)-' "$note" || violation "LINK-007" "error" "spec-writer" "$r does not wikilink its stories/enablers."
  done <<EOF
$(find "$SPECS_DIR" -type f -name 'SPEC-*.md' 2>/dev/null)
EOF
}

check_trace() {
  [ -d "$TRACES_DIR" ] || return 0
  local latest
  latest="$(find "$TRACES_DIR" -maxdepth 1 -type d -name 'Session-*' -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2-)"
  if [ -z "$latest" ]; then
    violation "TRACE-000" "error" "butler" "No Traces/Session-* folder exists. Butler must create a trace session at run start."
    return 0
  fi
  for r in Decisions.md Handovers.md Actions.md ToolsUsed.md HumanActions.md HumanDecisions.md TokenUsage.md; do
    [ -f "$latest/$r" ] || violation "TRACE-001" "error" "butler" "Trace session $(basename "$latest") is missing canonical file $r. Copy _session-template and use the 7 canonical files."
  done
}

check_token() {
  [ -d "$TRACES_DIR" ] || return 0
  local has_arch=0 has_specs=0
  if [ -d "$ARCH_DIR" ] && [ "$(find "$ARCH_DIR" -type f -name '*.md' ! -name '.gitkeep' 2>/dev/null | wc -l | tr -d ' ')" -gt 0 ]; then has_arch=1; fi
  if [ -d "$SPECS_DIR" ] && [ "$(find "$SPECS_DIR" -type f -name 'SPEC-*.md' 2>/dev/null | wc -l | tr -d ' ')" -gt 0 ]; then has_specs=1; fi
  [ "$has_arch" -eq 1 ] || [ "$has_specs" -eq 1 ] || return 0

  local latest
  latest="$(find "$TRACES_DIR" -maxdepth 1 -type d -name 'Session-*' -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2-)"
  [ -n "$latest" ] || return 0
  local tf="$latest/TokenUsage.md"
  if [ ! -f "$tf" ]; then
    violation "TOKEN-001" "error" "butler" "Trace session $(basename "$latest") has no TokenUsage.md. Record actuals via record-token-actuals (SessionEnd hook / --manual-total / --unavailable)."
    return 0
  fi
  if ! grep -qE '^[[:space:]]*source:[[:space:]]*(harness-reported|api-usage|manual-meter|unavailable)' "$tf"; then
    violation "TOKEN-001" "error" "butler" "TokenUsage.md in $(basename "$latest") has estimates only - no actual row. Run record-token-actuals at session end."
  fi
}

check_memory() {
  [ -d "$MEMORY_DIR" ] || return 0
  local has_arch=0 has_specs=0
  if [ -d "$ARCH_DIR" ] && [ "$(find "$ARCH_DIR" -type f -name '*.md' ! -name '.gitkeep' 2>/dev/null | wc -l | tr -d ' ')" -gt 0 ]; then has_arch=1; fi
  if [ -d "$SPECS_DIR" ] && [ "$(find "$SPECS_DIR" -type f -name 'SPEC-*.md' 2>/dev/null | wc -l | tr -d ' ')" -gt 0 ]; then has_specs=1; fi
  [ "$has_arch" -eq 1 ] || [ "$has_specs" -eq 1 ] || return 0

  local dec pre
  dec=$(find "$MEMORY_DIR/decisions" -type f -name '*.md' ! -name '.gitkeep' 2>/dev/null | wc -l | tr -d ' ')
  pre=$(find "$MEMORY_DIR/preferences" -type f -name '*.md' ! -name '.gitkeep' 2>/dev/null | wc -l | tr -d ' ')
  if [ "$((dec + pre))" -eq 0 ]; then
    violation "MEM-001" "error" "butler" 'A substantive run (ADRs/specs created) recorded no memory entries. Butler must write decisions/preferences via memory-append, or justify "none".'
  fi
}

# Required worker-boundary markers that every generated .dsh skill must carry.
# These encode the Plan 08 DSH worker boundary verbatim: post-lock native
# read-only allowlist direct; everything else fail-closed; governed actions go
# through exactly `kcc_policy_exec` / `kcc_policy_write`; KCC owns
# controller/status/resume. Skill generation alone is not Full Autopilot - the
# policy-guard profile/plugin proof is separate (Plan 08 Task 5 / Task 7).
DSH_BOUNDARY_MARKERS=(
  'native read-only allowlist'
  'fail closed'
  'kcc_policy_exec'
  'kcc_policy_write'
  'KCC owns controller, status, and resume'
  'code-runtime'
  'Cordis'
)

check_harness() {
  # Generated harness surface conformance. Judges only what exists (same
  # skip-if-absent rule as the other scopes): when a .dsh surface has been
  # generated, it must be complete, in sync with the neutral skills, and carry
  # the full worker-boundary text.
  [ -d "$DSH_SKILLS_DIR" ] || return 0

  local name f missing marker
  if [ -d "$CAP_SKILLS_DIR" ]; then
    while IFS= read -r src; do
      [ -z "$src" ] && continue
      name="$(basename "$src" .md)"
      [ -f "$DSH_SKILLS_DIR/$name/SKILL.md" ] || violation "DSH-001" "error" "sync-adapters" "Neutral skill $name has no generated .dsh/skills/$name/SKILL.md - rerun sync-adapters dsh."
    done < <(find "$CAP_SKILLS_DIR" -maxdepth 1 -type f -name '*.md' | sort)
  fi

  while IFS= read -r d; do
    [ -z "$d" ] && continue
    name="$(basename "$d")"
    if [ -d "$CAP_SKILLS_DIR" ] && [ ! -f "$CAP_SKILLS_DIR/$name.md" ]; then
      violation "DSH-002" "error" "sync-adapters" "Generated .dsh/skills/$name/SKILL.md has no neutral source (.KCC/capabilities/skills/$name.md) - stale surface, rerun sync-adapters dsh after removing the capability or delete the orphan."
    fi
  done < <(find "$DSH_SKILLS_DIR" -mindepth 1 -maxdepth 1 -type d | sort)

  while IFS= read -r f; do
    [ -z "$f" ] && continue
    name="$(basename "$(dirname "$f")")"
    local fm_name
    fm_name="$(fm_scalar "$f" name)"
    [ "$fm_name" = "$name" ] || violation "DSH-003" "error" "sync-adapters" "$(rel "$f") frontmatter name '${fm_name:-<empty>}' does not match its skill directory - regenerate via sync-adapters dsh."

    missing=""
    for marker in "${DSH_BOUNDARY_MARKERS[@]}"; do
      grep -qF "$marker" "$f" || missing="$missing $marker"
    done
    if [ -n "$missing" ]; then
      violation "DSH-004" "error" "sync-adapters" "$(rel "$f") is missing worker-boundary markers:$missing"
    fi
  done < <(find "$DSH_SKILLS_DIR" -name 'SKILL.md' -type f | sort)

  if [ ! -f "$REPO_ROOT/AGENTS.md" ]; then
    violation "DSH-005" "error" "framework-init" 'The .dsh surface exists but root AGENTS.md is missing. DSH reads root AGENTS.md as its entrypoint; it is created once from .KCC/kernel/templates/ when missing and then preserved (never overwritten by sync).'
  fi
}

echo "KCC run conformance: $REPO_ROOT  (scope: $SCOPE)"
echo ""

case "$SCOPE" in
  all) check_architecture; check_linking; check_trace; check_memory; check_token; check_harness ;;
  architecture) check_architecture ;;
  linking) check_linking ;;
  trace) check_trace ;;
  memory) check_memory ;;
  token) check_token ;;
  harness) check_harness ;;
  *) echo "unknown scope: $SCOPE" >&2; exit 2 ;;
esac

if [ "$ERRORS" -eq 0 ] && [ "$WARNINGS" -eq 0 ]; then
  echo "Conformant. No violations."
fi
echo ""
echo "Errors: $ERRORS"
echo "Warnings: $WARNINGS"
if [ "$ERRORS" -eq 0 ]; then echo "Conformance check passed."; else echo "Conformance check FAILED."; fi

[ "$ERRORS" -eq 0 ]
