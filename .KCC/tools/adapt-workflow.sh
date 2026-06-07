#!/usr/bin/env bash
# KCC framework (c) 2026 Tarek Fawaz, https://tikasway.dev/kcc. Licensed under the terms in LICENSE.
# KCC v0.4 native bash migration scaffold for macOS/Linux.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SOURCE=""
FORMAT="auto"

usage() {
  cat <<'EOF'
Usage:
  .KCC/tools/adapt-workflow.sh <path-or-repo> [--format=<hint>] [--repo-root <path>]

Formats:
  auto | cursor | claude | codex | opencode | aider | generic
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --format=*) FORMAT="${1#--format=}"; shift ;;
    --format|-Format) FORMAT="$2"; shift 2 ;;
    --repo-root|-RepoRoot) REPO_ROOT="$(cd "$2" && pwd)"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *)
      if [[ -z "$SOURCE" ]]; then
        SOURCE="$1"; shift
      else
        echo "error: unexpected argument: $1" >&2
        exit 2
      fi ;;
  esac
done

[[ -n "$SOURCE" ]] || { usage; exit 2; }
[[ -e "$SOURCE" ]] || { echo "error: source path not found: $SOURCE" >&2; exit 1; }
SOURCE_ABS="$(cd "$SOURCE" 2>/dev/null && pwd || (cd "$(dirname "$SOURCE")" && printf '%s/%s\n' "$(pwd)" "$(basename "$SOURCE")"))"

detect_format() {
  local root="$1"
  if [[ "$FORMAT" != "auto" ]]; then echo "$FORMAT"; return; fi
  [[ -d "$root/.cursor/rules" ]] && { echo "cursor"; return; }
  [[ -d "$root/.claude/agents" || -d "$root/.claude/skills" ]] && { echo "claude"; return; }
  [[ -d "$root/.codex/skills" || -f "$root/AGENTS.md" ]] && { echo "codex"; return; }
  [[ -d "$root/.opencode" || -f "$root/opencode.json" || -f "$root/opencode.toml" ]] && { echo "opencode"; return; }
  [[ -f "$root/.aider.conf.yml" || -f "$root/CONVENTIONS.md" ]] && { echo "aider"; return; }
  [[ -d "$root/prompts" || -d "$root/agents" || -d "$root/skills" ]] && { echo "generic"; return; }
  echo "generic"
}

EFFECTIVE_FORMAT="$(detect_format "$SOURCE_ABS")"
MIGRATIONS_DIR="$REPO_ROOT/migrations"
mkdir -p "$MIGRATIONS_DIR"

next_id=1
while [[ -e "$MIGRATIONS_DIR/IMPORT-$(printf '%03d' "$next_id")" ]]; do
  next_id=$((next_id + 1))
done
IMPORT_ID="IMPORT-$(printf '%03d' "$next_id")"
IMPORT_DIR="$MIGRATIONS_DIR/$IMPORT_ID"
mkdir -p "$IMPORT_DIR/drafts/agents" "$IMPORT_DIR/drafts/skills"

inventory_file="$IMPORT_DIR/inventory.tsv"
: > "$inventory_file"

add_inventory() {
  local kind="$1"
  local path="$2"
  local name
  name="$(basename "$path")"
  printf '%s\t%s\t%s\n' "$kind" "$name" "$path" >> "$inventory_file"
}

case "$EFFECTIVE_FORMAT" in
  cursor)
    [[ -d "$SOURCE_ABS/.cursor/rules" ]] && while IFS= read -r file; do add_inventory "rule" "$file"; done < <(find "$SOURCE_ABS/.cursor/rules" -type f | sort)
    ;;
  claude)
    [[ -d "$SOURCE_ABS/.claude/agents" ]] && while IFS= read -r file; do add_inventory "agent" "$file"; done < <(find "$SOURCE_ABS/.claude/agents" -type f -name '*.md' | sort)
    [[ -d "$SOURCE_ABS/.claude/skills" ]] && while IFS= read -r file; do add_inventory "skill" "$file"; done < <(find "$SOURCE_ABS/.claude/skills" -type f -name 'SKILL.md' | sort)
    ;;
  codex)
    [[ -f "$SOURCE_ABS/AGENTS.md" ]] && add_inventory "entrypoint" "$SOURCE_ABS/AGENTS.md"
    [[ -d "$SOURCE_ABS/.codex/skills" ]] && while IFS= read -r file; do add_inventory "skill" "$file"; done < <(find "$SOURCE_ABS/.codex/skills" -type f -name 'SKILL.md' | sort)
    ;;
  opencode)
    [[ -d "$SOURCE_ABS/.opencode" ]] && while IFS= read -r file; do add_inventory "opencode" "$file"; done < <(find "$SOURCE_ABS/.opencode" -type f | sort)
    [[ -f "$SOURCE_ABS/opencode.json" ]] && add_inventory "config" "$SOURCE_ABS/opencode.json"
    ;;
  aider)
    [[ -f "$SOURCE_ABS/.aider.conf.yml" ]] && add_inventory "config" "$SOURCE_ABS/.aider.conf.yml"
    [[ -f "$SOURCE_ABS/CONVENTIONS.md" ]] && add_inventory "conventions" "$SOURCE_ABS/CONVENTIONS.md"
    ;;
  generic|*)
    for dir in prompts agents skills; do
      [[ -d "$SOURCE_ABS/$dir" ]] && while IFS= read -r file; do add_inventory "$dir" "$file"; done < <(find "$SOURCE_ABS/$dir" -type f | sort)
    done
    ;;
esac

today="$(date +%F)"
{
  echo "---"
  echo "title: Migration Plan $IMPORT_ID"
  echo "tags: [migration, lifecycle/meta]"
  echo "status: scaffolded"
  echo "created: $today"
  echo "---"
  echo
  echo "# Migration Plan: $IMPORT_ID"
  echo
  echo "_Scaffolded by native bash `.KCC/tools/adapt-workflow.sh`. The migrator agent populates the rest._"
  echo
  echo "## Source"
  echo
  echo "- Path: \`$SOURCE_ABS\`"
  echo "- Format hint: \`$FORMAT\`"
  echo "- Format detected: \`$EFFECTIVE_FORMAT\`"
  echo
  echo "## Inventory (pre-mapping)"
  echo
  echo "| Kind | Name | Source path |"
  echo "|------|------|-------------|"
  if [[ -s "$inventory_file" ]]; then
    while IFS=$'\t' read -r kind name path; do
      echo "| $kind | $name | \`$path\` |"
    done < "$inventory_file"
  else
    echo "| _none_ | | _migrator agent to investigate_ |"
  fi
  echo
  echo "## Mapping decisions"
  echo
  echo "_To be filled by migrator._"
  echo
  echo "## Items needing human input"
  echo
  echo "_To be filled by migrator._"
  echo
  echo "## Recommended order of import"
  echo
  echo "_To be filled by migrator._"
} > "$IMPORT_DIR/plan.md"

{
  echo "# Mapping Report: $IMPORT_ID"
  echo
  echo "| Source | Draft target | Decision |"
  echo "|---|---|---|"
  if [[ -s "$inventory_file" ]]; then
    while IFS=$'\t' read -r kind name path; do
      echo "| \`$path\` | _TBD_ | Review and map to .KCC/capabilities. |"
    done < "$inventory_file"
  fi
} > "$IMPORT_DIR/mapping.md"

rm -f "$inventory_file"

echo "Migration scaffold created: $IMPORT_DIR"
echo "Detected format: $EFFECTIVE_FORMAT"
echo "Review plan.md, mapping.md, and drafts/. Promote drafts manually afterward."
