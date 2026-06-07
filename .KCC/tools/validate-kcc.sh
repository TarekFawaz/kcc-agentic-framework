#!/usr/bin/env bash
# KCC framework (c) 2026 Tarek Fawaz, https://tikasway.dev/kcc. Licensed under the terms in LICENSE.
# KCC v0.4 native bash validator for macOS/Linux.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
MODE="cell"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo-root|-RepoRoot)
      REPO_ROOT="$(cd "$2" && pwd)"
      shift 2
      ;;
    --mode|-Mode)
      MODE="$2"
      case "$MODE" in
        cell|repo) ;;
        *)
          echo "error: --mode must be cell or repo" >&2
          exit 2
          ;;
      esac
      shift 2
      ;;
    *)
      echo "error: unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

errors=()
warnings=()

add_error() { errors+=("$1"); }
add_warning() { warnings+=("$1"); }

required_path() {
  local rel="$1"
  [[ -e "$REPO_ROOT/$rel" ]] || add_error "Missing required path: $rel"
}

has_frontmatter_key() {
  local file="$1"
  local key="$2"
  awk -v key="$key" '
    NR == 1 && $0 == "---" { in_fm=1; next }
    in_fm && $0 == "---" { exit }
    in_fm && $0 ~ "^" key ":[[:space:]]*" { found=1; exit }
    END { exit(found ? 0 : 1) }
  ' "$file"
}

echo
echo "Validating KCC v0.4 at $REPO_ROOT"
echo "Mode: $MODE"
echo

cell_required_paths=(
  ".KCC/README.md"
  ".KCC/kernel/README.md"
  ".KCC/kernel/adapters"
  ".KCC/kernel/contracts"
  ".KCC/kernel/protocols"
  ".KCC/kernel/protocols/dialects"
  ".KCC/kernel/templates"
  ".KCC/capabilities/agents"
  ".KCC/capabilities/skills"
  ".KCC/tools/framework-init.ps1"
  ".KCC/tools/framework-init.sh"
  ".KCC/tools/sync-adapters.ps1"
  ".KCC/tools/sync-adapters.sh"
  ".KCC/tools/adapt-workflow.ps1"
  ".KCC/tools/adapt-workflow.sh"
  ".KCC/tools/show-backchannel.ps1"
  ".KCC/tools/show-backchannel.sh"
  ".KCC/tools/backchannel-append.ps1"
  ".KCC/tools/backchannel-append.sh"
  ".KCC/tools/build-dashboard.ps1"
  ".KCC/tools/build-dashboard.sh"
  ".KCC/tools/start-agent-session.ps1"
  ".KCC/tools/start-agent-session.sh"
  ".KCC/tools/validate-kcc.ps1"
  ".KCC/tools/validate-kcc.sh"
)
repo_required_paths=(
  "README.md"
  "QUICKSTART.md"
  "PLAN.md"
  "docs/alignment-matrix.md"
  "output/README.md"
  "AGENTS.md"
  "CLAUDE.md"
)

required_paths=("${cell_required_paths[@]}")
if [[ "$MODE" == "repo" ]]; then
  required_paths+=("${repo_required_paths[@]}")
else
  for rel in AGENTS.md CLAUDE.md README.md QUICKSTART.md PLAN.md; do
    [[ -e "$REPO_ROOT/$rel" ]] || add_warning "Optional repo/cell entrypoint is absent in cell mode: $rel"
  done
fi

for rel in "${required_paths[@]}"; do required_path "$rel"; done

dialects=(
  dialect-registry.md
  backend-csharp.md backend-go.md backend-python.md backend-rust.md
  backend-php.md backend-java.md backend-cpp.md backend-nodejs.md
  fullstack-dotnet.md fullstack-mern.md fullstack-nestjs.md
  fullstack-python.md fullstack-go.md
  embedded-c.md embedded-cpp.md embedded-rust.md
  frontend-angular.md frontend-react.md frontend-vanilla-js.md
  frontend-general.md devops-cloud.md devops-k8s-onprem-agnostic.md
)
for file in "${dialects[@]}"; do
  required_path ".KCC/kernel/protocols/dialects/$file"
done

expected_agents=(
  architect.md architecture-critic.md butler.md idea-interrogator.md implementer.md
  infrastructure-implementer.md infrastructure-planner.md migrator.md
  planner.md security-analyst.md solution-cartographer.md
  solution-inspector.md spec-writer.md technical-interrogator.md
  token-guard.md ux-ui-designer.md verifier.md
)
expected_skills=(
  adapt-workflow.md architecture-review.md auto.md butler-brief.md butler-remember.md
  critical-human-gate.md dashboard.md idea-interrogator.md
  infrastructure-interrogator.md inspect.md security-interrogator.md
  solution-onboard.md spec-create.md spec-deploy.md
  spec-implement.md spec-plan.md spec-review.md spec-status.md spec-test.md
  technical-interrogator.md token-estimate.md ux-ui-interrogator.md
)

for file in "${expected_agents[@]}"; do
  required_path ".KCC/capabilities/agents/$file"
done
for file in "${expected_skills[@]}"; do
  required_path ".KCC/capabilities/skills/$file"
done

if [[ -d "$REPO_ROOT/.KCC/capabilities/agents" ]]; then
  while IFS= read -r -d '' file; do
    base="$(basename "$file")"
    found=0
    for expected in "${expected_agents[@]}"; do [[ "$base" == "$expected" ]] && found=1; done
    (( found == 1 )) || add_warning "Agent '$base' exists on disk but is not in validate-kcc.sh expected_agents."
    has_frontmatter_key "$file" maturity || add_warning "Agent missing maturity: .KCC/capabilities/agents/$base"
    has_frontmatter_key "$file" maintainer || add_warning "Agent missing maintainer: .KCC/capabilities/agents/$base"
  done < <(find "$REPO_ROOT/.KCC/capabilities/agents" -maxdepth 1 -type f -name '*.md' -print0)
fi

if [[ -d "$REPO_ROOT/.KCC/capabilities/skills" ]]; then
  while IFS= read -r -d '' file; do
    base="$(basename "$file")"
    found=0
    for expected in "${expected_skills[@]}"; do [[ "$base" == "$expected" ]] && found=1; done
    (( found == 1 )) || add_warning "Skill '$base' exists on disk but is not in validate-kcc.sh expected_skills."
    has_frontmatter_key "$file" maturity || add_warning "Skill missing maturity: .KCC/capabilities/skills/$base"
    has_frontmatter_key "$file" maintainer || add_warning "Skill missing maintainer: .KCC/capabilities/skills/$base"
  done < <(find "$REPO_ROOT/.KCC/capabilities/skills" -maxdepth 1 -type f -name '*.md' -print0)
fi

runtime_inside_kcc=(
  .KCC/ideation .KCC/specs .KCC/architecture .KCC/coordination
  .KCC/memory .KCC/Traces .KCC/solution .KCC/src .KCC/docs
)
for rel in "${runtime_inside_kcc[@]}"; do
  [[ -e "$REPO_ROOT/$rel" ]] && add_error "Runtime output must stay outside .KCC: $rel"
done

text_roots=("$REPO_ROOT/.KCC")
for rel in AGENTS.md CLAUDE.md QUICKSTART.md README.md PLAN.md docs output architecture coordination ollama; do
  [[ -e "$REPO_ROOT/$rel" ]] && text_roots+=("$REPO_ROOT/$rel")
done

tmp_stale="${TMPDIR:-/tmp}/kcc-stale-refs.$$"
tmp_corrupt="${TMPDIR:-/tmp}/kcc-corruption.$$"

if grep -RInE '\.KCC/framework|framework/agents|framework/skills|framework/protocols|framework/templates|framework/adapters' \
  "${text_roots[@]}" --include='*.md' --include='*.sh' --include='*.ps1' --include='*.json' --include='*.toml' >"$tmp_stale" 2>/dev/null; then
  while IFS= read -r line; do
    case "$line" in
      *".KCC/tools/sync-adapters.ps1"*|*".KCC/tools/validate-kcc.ps1"*|*".KCC/tools/validate-kcc.sh"*) ;;
      *) add_error "Stale retired framework reference: $line" ;;
    esac
  done < "$tmp_stale"
fi
rm -f "$tmp_stale"

# UTF-8-as-Windows-1252 mojibake sequences (literal bytes of the rendered marks):
#   Ã¢â‚¬ , â€" , â€™ , â€œ , Ã© , Ã¨ , Â (stray) , ðŸ (broken emoji)
moji_ea2082="$(printf '\303\203\302\242\303\242\342\202\254')"   # Ã¢â‚¬
moji_dash="$(printf '\303\242\342\202\254\342\200\235')"         # â€"
moji_apos="$(printf '\303\242\342\202\254\342\204\242')"         # â€™
moji_quote="$(printf '\303\242\342\202\254\305\223')"            # â€œ
moji_eacute="$(printf '\303\203\302\251')"                       # Ã©
moji_egrave="$(printf '\303\203\302\250')"                       # Ã¨
moji_stray="$(printf '\303\202\302\240')"                        # Â (stray nbsp)
moji_emoji="$(printf '\303\260\305\270')"                        # ðŸ broken emoji
bad_replacement="$(printf '\357\277\275')"                       # U+FFFD
mid_bom="$(printf '\357\273\277')"                               # ï»¿ BOM mid-file
control_pattern=$'[\001-\010\013\014\016-\037\177]'
corruption_pattern="${control_pattern}|${moji_ea2082}|${moji_dash}|${moji_apos}|${moji_quote}|${moji_eacute}|${moji_egrave}|${moji_stray}|${moji_emoji}|${bad_replacement}|${mid_bom}"
if grep -RInE "$corruption_pattern" "${text_roots[@]}" \
  --include='*.md' --include='*.sh' --include='*.ps1' --include='*.json' --include='*.jsonl' --include='*.mmd' --include='*.toml' >"$tmp_corrupt" 2>/dev/null; then
  shown=0
  while IFS= read -r line; do
    case "$line" in
      *".KCC/tools/sync-adapters.ps1"*|*".KCC/tools/validate-kcc.ps1"*|*".KCC/tools/validate-kcc.sh"*) ;;
      *)
        if (( shown < 25 )); then
          add_error "Text/control-character corruption marker: $line"
        fi
        shown=$((shown + 1))
        ;;
    esac
  done < "$tmp_corrupt"
  if (( shown > 25 )); then
    add_warning "Additional corruption markers omitted from output: $((shown - 25))"
  fi
fi
rm -f "$tmp_corrupt"

if [[ -d "$REPO_ROOT/.KCC/capabilities/agents" ]]; then
  while IFS= read -r -d '' file; do
    if grep -qi 'untrusted-input' "$file" && grep -qi 'private-data' "$file" && grep -qi 'external-comms' "$file"; then
      grep -qi 'sandbox' "$file" || add_warning "Possible Lethal Trifecta agent lacks sandbox mention: ${file#$REPO_ROOT/}"
    fi
  done < <(find "$REPO_ROOT/.KCC/capabilities/agents" -maxdepth 1 -type f -name '*.md' -print0)
fi

# -----------------------------------------------------------------------------
# Architecture-format structural check (both modes, when architecture/ exists)
# Authority: .KCC/kernel/protocols/architecture-documentation.md
# -----------------------------------------------------------------------------
if [[ -d "$REPO_ROOT/architecture" ]]; then
  mmd_found="$(find "$REPO_ROOT/architecture" -type f -name '*.mmd' -print 2>/dev/null | head -n 10 | tr '\n' ' ')"
  if [[ -n "$mmd_found" ]]; then
    add_error "Deprecated architecture format: .mmd file(s) found under architecture/ ($mmd_found). Use named .md diagram files with embedded inline mermaid (see .KCC/kernel/protocols/architecture-documentation.md)."
  fi
  if [[ -d "$REPO_ROOT/architecture/diagrams" ]]; then
    add_error "Deprecated architecture format: architecture/diagrams/ folder exists. Use named .md diagram files with embedded inline mermaid (see .KCC/kernel/protocols/architecture-documentation.md)."
  fi

  if [[ -f "$REPO_ROOT/architecture/architecture.md" ]]; then
    arch_size="$(wc -c < "$REPO_ROOT/architecture/architecture.md" | tr -d '[:space:]')"
    if (( arch_size < 2048 )); then
      add_warning "architecture/architecture.md is suspiciously thin ($arch_size bytes < 2 KB); it should be a mature Architecture Document, not a stub."
    fi
  fi

  has_adrs=0
  if [[ -d "$REPO_ROOT/architecture/adrs" ]]; then
    while IFS= read -r -d '' adr; do
      base="$(basename "$adr")"
      case "$base" in
        adrs.md|template.md|.gitkeep) ;;
        *) has_adrs=1 ;;
      esac
    done < <(find "$REPO_ROOT/architecture/adrs" -maxdepth 1 -type f -name '*.md' -print0 2>/dev/null)
  fi
  if (( has_adrs == 1 )); then
    for supporting in fitness-functions.md nfrs.md technical-budgets.md adrs/adrs.md; do
      [[ -e "$REPO_ROOT/architecture/$supporting" ]] || add_warning "architecture/ has ADRs but is missing expected supporting file: architecture/$supporting"
    done
  fi
fi

# -----------------------------------------------------------------------------
# Generated-cell hygiene (WARN only, never fail)
# -----------------------------------------------------------------------------
gitignore_text=""
[[ -f "$REPO_ROOT/.gitignore" ]] && gitignore_text="$(cat "$REPO_ROOT/.gitignore")"

hygiene_present() {
  case "$1" in
    '.tmp-*')          compgen -G "$REPO_ROOT/.tmp-*" >/dev/null 2>&1 ;;
    '**/__pycache__/') [[ -n "$(find "$REPO_ROOT" -type d -name '__pycache__' -print -quit 2>/dev/null)" ]] ;;
    '*.pyc')           [[ -n "$(find "$REPO_ROOT" -type f -name '*.pyc' -print -quit 2>/dev/null)" ]] ;;
    '*.db')            [[ -n "$(find "$REPO_ROOT" -type f -name '*.db' -print -quit 2>/dev/null)" ]] ;;
    '*.db-journal')    [[ -n "$(find "$REPO_ROOT" -type f -name '*.db-journal' -print -quit 2>/dev/null)" ]] ;;
    '.test-tmp/')      [[ -d "$REPO_ROOT/.test-tmp" ]] ;;
    'node_modules/')   [[ -n "$(find "$REPO_ROOT" -type d -name 'node_modules' -print -quit 2>/dev/null)" ]] ;;
    '.next/')          [[ -n "$(find "$REPO_ROOT" -type d -name '.next' -print -quit 2>/dev/null)" ]] ;;
    *) return 1 ;;
  esac
}

for pattern in '.tmp-*' '**/__pycache__/' '*.pyc' '*.db' '*.db-journal' '.test-tmp/' 'node_modules/' '.next/'; do
  if hygiene_present "$pattern"; then
    if ! grep -qxF "$pattern" <<<"$gitignore_text"; then
      add_warning "Generated-cell hygiene: runtime/build artifact matching '$pattern' is present but not listed in .gitignore."
    fi
  fi
done

echo "Checks complete."
echo "Errors: ${#errors[@]}"
echo "Warnings: ${#warnings[@]}"
echo

if (( ${#warnings[@]} > 0 )); then
  echo "Warnings:"
  for item in "${warnings[@]}"; do echo "  - $item"; done
  echo
fi

if (( ${#errors[@]} > 0 )); then
  echo "Errors:"
  for item in "${errors[@]}"; do echo "  - $item"; done
  exit 1
fi

echo "KCC validation passed."
