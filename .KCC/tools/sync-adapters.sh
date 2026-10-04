#!/usr/bin/env bash
# KCC framework (c) 2026 Tarek Fawaz, https://tikasway.dev/kcc. Licensed under the terms in LICENSE.
# KCC v0.4 native bash adapter materializer for macOS/Linux.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
HARNESS="all"
INSTALL_CODEX_SKILLS=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    claude|codex|opencode|generic|ollama|all)
      HARNESS="$1"; shift ;;
    --harness|-Harness)
      HARNESS="$2"; shift 2 ;;
    --repo-root|-RepoRoot)
      REPO_ROOT="$(cd "$2" && pwd)"; shift 2 ;;
    --install-codex-skills|-InstallCodexSkills)
      INSTALL_CODEX_SKILLS=1; shift ;;
    --install-codex-prompts|-InstallCodexPrompts)
      echo "warning: -InstallCodexPrompts is deprecated and is a no-op. Use --install-codex-skills for project-local skills." >&2
      shift ;;
    *)
      echo "error: unknown argument: $1" >&2
      exit 2 ;;
  esac
done

case "$HARNESS" in
  claude|codex|opencode|generic|ollama|all) ;;
  *) echo "error: unsupported harness: $HARNESS" >&2; exit 2 ;;
esac

KERNEL_ROOT="$REPO_ROOT/.KCC/kernel"
CAP_ROOT="$REPO_ROOT/.KCC/capabilities"
AGENTS_DIR="$CAP_ROOT/agents"
SKILLS_DIR="$CAP_ROOT/skills"

[[ -d "$AGENTS_DIR" ]] || { echo "error: agents directory not found: $AGENTS_DIR" >&2; exit 1; }
[[ -d "$SKILLS_DIR" ]] || { echo "error: skills directory not found: $SKILLS_DIR" >&2; exit 1; }

mkdir -p "$REPO_ROOT/coordination"

# Write-time guard: strip disallowed control characters from a file in place,
# keeping only printable text plus tab (0x09), LF (0x0A) and CR (0x0D). This
# mirrors the PowerShell Remove-ControlChars guard and ensures a stray control
# char (e.g. a backtick-escape that slipped into content) can never corrupt
# generated output. Removes 0x00-0x08, 0x0B, 0x0C, 0x0E-0x1F and DEL (0x7F).
strip_ctrl_file() {
  local f="$1"
  [[ -f "$f" ]] || return 0
  local tmp
  tmp="$(mktemp)"
  LC_ALL=C tr -d '\000-\010\013\014\016-\037\177' < "$f" > "$tmp"
  mv "$tmp" "$f"
}

# Sanitize every generated file under a directory tree (or a single file).
strip_ctrl_tree() {
  local target="$1"
  [[ -e "$target" ]] || return 0
  if [[ -f "$target" ]]; then
    strip_ctrl_file "$target"
    return 0
  fi
  while IFS= read -r f; do
    strip_ctrl_file "$f"
  done < <(find "$target" -type f)
}

normalize_one_line() {
  tr '\r\n' '  ' | sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//'
}

yaml_scalar() {
  local file="$1"
  local key="$2"
  awk -v key="$key" '
    NR == 1 && $0 == "---" { in_fm=1; next }
    in_fm && $0 == "---" { exit }
    in_fm && $0 ~ "^" key ":[[:space:]]*" {
      val=$0
      sub("^" key ":[[:space:]]*", "", val)
      if (val == ">" || val == "|") { folded=1; next }
      print val
      exit
    }
    folded {
      if ($0 ~ /^[[:space:]]+/) {
        gsub(/^[[:space:]]+/, "", $0)
        if (out) printf " "
        printf "%s", $0
        out=1
        next
      }
      exit
    }
  ' "$file" | normalize_one_line
}

yaml_list() {
  local file="$1"
  local key="$2"
  awk -v key="$key" '
    NR == 1 && $0 == "---" { in_fm=1; next }
    in_fm && $0 == "---" { exit }
    in_fm && $0 ~ "^" key ":[[:space:]]*$" { collect=1; next }
    collect {
      if ($0 ~ /^[[:space:]]+-[[:space:]]*/) {
        sub(/^[[:space:]]+-[[:space:]]*/, "", $0)
        sub(/[[:space:]]+#.*$/, "", $0)
        if ($0 != "") print $0
        next
      }
      exit
    }
  ' "$file"
}

body_after_frontmatter() {
  local file="$1"
  awk '
    NR == 1 && $0 == "---" { seen=1; next }
    seen && $0 == "---" { emit=1; next }
    emit { print }
  ' "$file"
}

json_escape() {
  sed -E 's/\\/\\\\/g; s/"/\\"/g' | tr '\r\n' '  '
}

display_name() {
  local name="$1"
  local out=""
  IFS='-' read -r -a parts <<< "$name"
  for part in "${parts[@]}"; do
    [[ -z "$part" ]] && continue
    out+="$(printf '%s' "$part" | awk '{print toupper(substr($0,1,1)) substr($0,2)}') "
  done
  printf '%s' "${out% }"
}

short_description() {
  local text="$1"
  text="$(printf '%s' "$text" | sed -E 's/[[:space:]]+Usage:[[:space:]].*$//')"
  if (( ${#text} > 120 )); then
    printf '%s...' "${text:0:117}"
  else
    printf '%s' "$text"
  fi
}

model_for() {
  local surface="$1"
  local class="$2"
  case "$surface:$class" in
    claude:strong-reasoning|claude:local-strong) echo "opus" ;;
    claude:balanced) echo "sonnet" ;;
    claude:fast-implementation|claude:local-fast) echo "haiku" ;;
    claude-id:strong-reasoning|claude-id:local-strong) echo "claude-opus-5" ;;
    claude-id:balanced) echo "claude-sonnet-5" ;;
    claude-id:fast-implementation|claude-id:local-fast) echo "claude-haiku-4-5" ;;
    codex:strong-reasoning) echo "gpt-5" ;;
    codex:balanced) echo "gpt-5-mini" ;;
    codex:fast-implementation) echo "gpt-5-nano" ;;
    opencode:strong-reasoning) echo "anthropic/claude-opus-5" ;;
    opencode:balanced) echo "anthropic/claude-sonnet-5" ;;
    opencode:fast-implementation) echo "anthropic/claude-haiku-4-5" ;;
    ollama:strong-reasoning) echo "qwen2.5:72b" ;;
    ollama:balanced) echo "qwen2.5:32b" ;;
    ollama:fast-implementation) echo "qwen2.5:14b" ;;
    *:local-strong) echo "qwen2.5:72b" ;;
    *:local-fast) echo "qwen2.5:7b" ;;
    claude:*) echo "sonnet" ;;
    claude-id:*) echo "claude-sonnet-5" ;;
    codex:*) echo "gpt-5-mini" ;;
    opencode:*) echo "anthropic/claude-sonnet-5" ;;
    ollama:*) echo "qwen2.5:32b" ;;
    *) echo "balanced" ;;
  esac
}

# model-class -> default reasoning effort; an agent's `effort:` overrides it.
class_default_effort() {
  case "$1" in
    strong-reasoning|local-strong) echo "high" ;;
    balanced) echo "medium" ;;
    fast-implementation|local-fast) echo "low" ;;
    *) echo "medium" ;;
  esac
}

effort_for() {
  local file="$1" effort
  effort="$(yaml_scalar "$file" effort)"
  case "$effort" in
    low|medium|high|xhigh|max) echo "$effort" ;;
    *) class_default_effort "$(yaml_scalar "$file" model-class)" ;;
  esac
}

codex_effort() {
  case "$1" in
    xhigh|max) echo "high" ;;
    *) echo "$1" ;;
  esac
}

# Claude subagent `tools` takes bare names only (comma-separated).
claude_tools_line() {
  claude_tools "$1" | sed 's/^  - //' | awk '!seen[$0]++' | paste -sd ',' - | sed 's/,/, /g'
}

first_sentence() {
  printf "%s" "$1" | normalize_one_line | sed -E 's/[[:space:]]+Usage:[[:space:]]*\/.*$//' \
    | sed -E 's/^(([^.!?]|e\.g\.|i\.e\.)*[.!?])[[:space:]]+[A-Z`(\[].*$/\1/' | cut -c1-300
}

# Shared runtime rules live in one contract; every agent gets a pointer.
agent_runtime_footer() {
  printf '
## Runtime

Follow `.KCC/kernel/contracts/agent-runtime.md`: handover in, lazy reads, `Confidence: NN%%` + `ActualTokenUsage`, lean return.
'
}

skill_spawn_footer() {
  local file="$1" names
  names="$(yaml_list "$file" delegates-to | sed 's/^/`/; s/$/`/' | paste -sd ',' - | sed 's/,/, /g')"
  [[ -n "$names" ]] || return 0
  printf '\n## Spawning\n\nDelegate to %s per `coordination/orchestrator.md` -> *Spawn protocol*: fresh subagent per unit, model and effort from its profile (`orchestrator.json` -> `agents[].spawn`), handover packet in, lean return out.\n' "$names"
}

claude_tools() {
  local file="$1"
  local any=0
  while IFS= read -r tool; do
    any=1
    case "$tool" in
      read) printf '  - Read\n' ;;
      search) printf '  - Glob\n  - Grep\n' ;;
      edit) printf '  - Write\n  - Edit\n' ;;
      exec) printf '  - Bash\n' ;;
      web) printf '  - WebSearch\n  - WebFetch\n' ;;
    esac
  done < <(yaml_list "$file" "tools-required")
  (( any == 1 )) || printf '  - Read\n'
}

plain_tools() {
  local file="$1"
  local any=0
  while IFS= read -r tool; do
    any=1
    printf '  - %s\n' "$tool"
  done < <(yaml_list "$file" "tools-required")
  (( any == 1 )) || printf '  - read\n'
}

replace_args() {
  local token="$1"
  sed "s|<ARGS>|$token|g"
}

metadata_block() {
  local file="$1"
  local printed=0
  local key value list item

  for key in title aliases tags created updated version status copyright homepage license; do
    if [[ "$key" == "aliases" || "$key" == "tags" ]]; then
      list="$(yaml_list "$file" "$key")"
      [[ -n "$list" ]] || continue
      if (( printed == 0 )); then
        echo
        echo "# Obsidian metadata (Obsidian vault + framework provenance)"
        printed=1
      fi
      echo "$key:"
      while IFS= read -r item; do
        [[ -n "$item" ]] && printf '  - %s\n' "$item"
      done <<< "$list"
    else
      value="$(yaml_scalar "$file" "$key")"
      [[ -n "$value" ]] || continue
      if (( printed == 0 )); then
        echo
        echo "# Obsidian metadata (Obsidian vault + framework provenance)"
        printed=1
      fi
      printf '%s: %s\n' "$key" "$value"
    fi
  done
}

skill_package() {
  local skill_file="$1"
  local name="$2"
  local token="$3"
  local compatibility="$4"
  local desc
  desc="$(yaml_scalar "$skill_file" description)"
  {
    echo "---"
    echo "name: $name"
    echo "description: >"
    echo "  $desc"
    echo "compatibility: $compatibility"
    metadata_block "$skill_file"
    echo "---"
    echo
    body_after_frontmatter "$skill_file" | replace_args "$token"
    skill_spawn_footer "$skill_file"
  }
}

agent_table() {
  echo "| Agent | Role | Model class | Effort | Purpose |"
  echo "|-------|------|-------------|--------|---------|"
  while IFS= read -r file; do
    local name role model desc
    name="$(yaml_scalar "$file" name)"
    [[ -n "$name" ]] || name="$(basename "$file" .md)"
    role="$(yaml_scalar "$file" role)"
    model="$(yaml_scalar "$file" model-class)"
    desc="$(first_sentence "$(yaml_scalar "$file" description)")"
    printf '| `%s` | %s | `%s` | `%s` | %s |\n' "$name" "$role" "$model" "$(effort_for "$file")" "$desc"
  done < <(find "$AGENTS_DIR" -maxdepth 1 -type f -name '*.md' | sort)
}

skill_table() {
  echo "| Skill | Usage | Delegates to |"
  echo "|-------|-------|--------------|"
  while IFS= read -r file; do
    local name desc usage delegates
    name="$(yaml_scalar "$file" name)"
    [[ -n "$name" ]] || name="$(basename "$file" .md)"
    desc="$(yaml_scalar "$file" description)"
    usage="$(printf '%s' "$desc" | sed -nE 's/.*Usage:[[:space:]]*(.*)$/\1/p')"
    [[ -n "$usage" ]] || usage="/$name"
    delegates="$(yaml_list "$file" delegates-to | sed 's/^/`/; s/$/`/' | paste -sd ', ' -)"
    [[ -n "$delegates" ]] || delegates="(direct file read)"
    printf '| `%s` | `%s` | %s |\n' "$name" "$usage" "$delegates"
  done < <(find "$SKILLS_DIR" -maxdepth 1 -type f -name '*.md' | sort)
}

route_table() {
  echo "| Trigger | Skill | Agent invoked |"
  echo "|---------|-------|---------------|"
  while IFS= read -r file; do
    local name desc usage delegates
    name="$(yaml_scalar "$file" name)"
    [[ -n "$name" ]] || name="$(basename "$file" .md)"
    desc="$(yaml_scalar "$file" description)"
    usage="$(printf '%s' "$desc" | sed -nE 's/.*Usage:[[:space:]]*(.*)$/\1/p')"
    [[ -n "$usage" ]] || usage="/$name"
    delegates="$(yaml_list "$file" delegates-to | sed 's/^/`/; s/$/`/' | paste -sd ', ' -)"
    [[ -n "$delegates" ]] || delegates="(none)"
    printf '| `%s` | `%s` | %s |\n' "$usage" "$name" "$delegates"
  done < <(find "$SKILLS_DIR" -maxdepth 1 -type f -name '*.md' | sort)
}

harness_output_table() {
  cat <<'TABLE'
| Harness | Generated paths |
|---------|-----------------|
| `claude` | `.claude/agents/`, `.claude/skills/`, `CLAUDE.md` if missing |
| `codex` | `.codex/agents/`, `.codex/skills/*/SKILL.md`, `.codex/tools/`, `.codex/config.toml`, `AGENTS.md` if missing |
| `opencode` | `.opencode/agents/`, `.opencode/commands/`, `.opencode/skills/`, `opencode.json`, `AGENTS.md` if missing |
| `generic` | `.agents/agents/`, `.agents/skills/`, `.agents/tools/`, `.agents/config.json`, `.agents/manifest.json` |
| `ollama` | `ollama/agents.json`, `ollama/README.md` |
TABLE
}

model_class_table() {
  echo "| Class | Claude | Default effort | Codex | OpenCode | Ollama |"
  echo "|-------|--------|----------------|-------|----------|--------|"
  local cls
  for cls in strong-reasoning balanced fast-implementation local-strong local-fast; do
    printf '| `%s` | `%s` (%s) | `%s` | `%s` | `%s` | `%s` |\n' "$cls" "$(model_for claude "$cls")" "$(model_for claude-id "$cls")" \
      "$(class_default_effort "$cls")" "$(model_for codex "$cls")" "$(model_for opencode "$cls")" "$(model_for ollama "$cls")"
  done
}

spawn_table() {
  echo "| Agent | Class | Claude model | Effort | Codex model/effort | Tools (Claude) | Inputs -> Outputs |"
  echo "|-------|-------|--------------|--------|--------------------|----------------|-------------------|"
  while IFS= read -r file; do
    local name cls eff io
    name="$(yaml_scalar "$file" name)"; [[ -n "$name" ]] || name="$(basename "$file" .md)"
    cls="$(yaml_scalar "$file" model-class)"
    eff="$(effort_for "$file")"
    io="$(first_sentence "$(yaml_scalar "$file" inputs)" | cut -c1-90) -> $(first_sentence "$(yaml_scalar "$file" outputs)" | cut -c1-90)"
    io="${io//|//}"
    printf '| `%s` | `%s` | `%s` (%s) | `%s` | `%s` / `%s` | %s | %s |\n' "$name" "$cls" "$(model_for claude "$cls")" "$(model_for claude-id "$cls")" \
      "$eff" "$(model_for codex "$cls")" "$(codex_effort "$eff")" "$(claude_tools_line "$file")" "$io"
  done < <(find "$AGENTS_DIR" -maxdepth 1 -type f -name '*.md' | sort)
}

expand_template() {
  local template="$1"
  local date
  date="$(date +%F)"
  sed \
    -e "s/{{DATE}}/$date/g" \
    -e "/{{AGENT_TABLE}}/{
      r /dev/stdin
      d
    }" "$template" >/tmp/kcc-template-1.$$
}

write_template() {
  local template="$1"
  local out="$2"
  local text
  text="$(cat "$template")"
  text="${text//\{\{DATE\}\}/$(date +%F)}"
  text="${text//\{\{HARNESS_OUTPUT_TABLE\}\}/$(harness_output_table)}"
  text="${text//\{\{MODEL_CLASS_TABLE\}\}/$(model_class_table)}"
  text="${text//\{\{AGENT_TABLE\}\}/$(agent_table)}"
  text="${text//\{\{SKILL_TABLE\}\}/$(skill_table)}"
  text="${text//\{\{ROUTE_TABLE\}\}/$(route_table)}"
  text="${text//\{\{SPAWN_TABLE\}\}/$(spawn_table)}"
  printf '%s\n' "$text" > "$out"
}

ensure_file() {
  local path="$1"
  local content="$2"
  if [[ ! -f "$path" ]]; then
    mkdir -p "$(dirname "$path")"
    printf '%s\n' "$content" > "$path"
    echo "[init     ] [create] $path"
  fi
}

initialize_framework() {
  local today
  today="$(date +%F)"
  mkdir -p \
    "$REPO_ROOT/ideation" "$REPO_ROOT/specs" "$REPO_ROOT/solution" \
    "$REPO_ROOT/architecture/adrs" \
    "$REPO_ROOT/memory" "$REPO_ROOT/coordination" "$REPO_ROOT/Traces/_session-template" \
    "$REPO_ROOT/migrations" "$REPO_ROOT/src"

  ensure_file "$REPO_ROOT/.gitignore" "# KCC generated cell outputs and local runtime artifacts.
.claude/
.codex/
.opencode/
.agents/
ollama/

Traces/Session-*/
ideation/IDEA-*/
specs/IDEA-*-Specs/
solution/*/
migrations/IMPORT-*/
src/
dashboard/

coordination/backchannel.jsonl
coordination/backchannel-*.jsonl

.tmp/
.tmp-*
.test-tmp/
.test-tmp
*.tmp-edge-profile-*
.tmp-edge-profile-*/
.tmp-chromium-profile-*/
*.playwright-profile-*/
__pycache__/
*.py[cod]

*.db
*.db-journal
*.sqlite
*.sqlite3

.DS_Store
Thumbs.db
desktop.ini"

  [[ -f "$REPO_ROOT/AGENTS.md" ]] || write_template "$KERNEL_ROOT/templates/AGENTS.md" "$REPO_ROOT/AGENTS.md"
  if [[ "$HARNESS" == "all" || "$HARNESS" == "claude" ]]; then
    [[ -f "$REPO_ROOT/CLAUDE.md" ]] || write_template "$KERNEL_ROOT/templates/CLAUDE.md" "$REPO_ROOT/CLAUDE.md"
  fi

  ensure_file "$REPO_ROOT/ideation/ideas.md" "---
title: Ideas MOC
tags: [ideation, entrypoint]
created: $today
updated: $today
version: 1.0.0
status: active
---

# Ideas

| Idea | Date | Brief | ROI confidence | Status | Specs/Epics |
|------|------|-------|----------------|--------|-------------|
| _(no ideas yet)_ | | | | | |"

  ensure_file "$REPO_ROOT/specs/specs.md" "---
title: Specs MOC
tags: [spec, entrypoint]
created: $today
updated: $today
version: 1.0.0
status: active
---

# Specs

| ID | Title | Priority | Status | Source idea | Stories | Enablers | Depends on | Blocks |
|----|-------|----------|--------|-------------|---------|----------|------------|--------|
| _(no specs yet)_ | | | | | | | | |"

  ensure_file "$REPO_ROOT/solution/solution.md" "---
title: Solution Baseline MOC
tags: [solution, entrypoint]
created: $today
updated: $today
version: 1.0.0
status: active
---

# Solution Baseline

Populate with: /solution-onboard . --depth=standard"

  ensure_file "$REPO_ROOT/coordination/backchannel.jsonl" ""
  ensure_file "$REPO_ROOT/coordination/coordination.md" "---
title: Coordination MOC
tags: [coordination, entrypoint]
created: $today
updated: $today
version: 1.0.0
status: active
---

# Coordination

- backchannel.jsonl - append-only meta-agent event log.
- orchestrator.md - generated skill-to-agent route map.
- orchestrator.json - generated machine-readable route map.
- .KCC/tools/backchannel-append.sh - deterministic event append helper that refreshes dashboard/index.html.
- .KCC/tools/show-backchannel.sh - read-only human-readable backchannel viewer."

  write_template "$KERNEL_ROOT/templates/orchestrator.md" "$REPO_ROOT/coordination/orchestrator.md"

  local json="$REPO_ROOT/coordination/orchestrator.json" runtime=""
  # Preserve butler-owned runtime keys (active-session pointer).
  [[ -f "$json" ]] && runtime="$(grep -oE '"active_session[a-z_]*": *("[^"]*"|null)' "$json" | paste -sd ',' -)"
  {
    echo '{'
    echo '  "schema_version": "2.0",'
    printf '  "generated": "%s",\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo '  "spawn_protocol": {"doc":"coordination/orchestrator.md#spawn-protocol","effort_levels":["low","medium","high","xhigh","max"]},'
    echo '  "model_classes": {'
    local cls sep=""
    for cls in strong-reasoning balanced fast-implementation local-strong local-fast; do
      printf '%s    "%s": {"default_effort":"%s","claude":"%s","claude_model_id":"%s","codex":"%s","opencode":"%s","ollama":"%s"}' "$sep" "$cls" \
        "$(class_default_effort "$cls")" "$(model_for claude "$cls")" "$(model_for claude-id "$cls")" "$(model_for codex "$cls")" "$(model_for opencode "$cls")" "$(model_for ollama "$cls")"
      sep=$',\n'
    done
    echo
    echo '  },'
    echo '  "agents": ['
    local first=1
    while IFS= read -r file; do
      local name role cls eff desc tools
      name="$(yaml_scalar "$file" name)"; [[ -n "$name" ]] || name="$(basename "$file" .md)"
      role="$(yaml_scalar "$file" role | json_escape)"
      cls="$(yaml_scalar "$file" model-class)"
      eff="$(effort_for "$file")"
      desc="$(first_sentence "$(yaml_scalar "$file" description)" | json_escape)"
      tools="$(claude_tools_line "$file" | sed 's/, /","/g')"
      (( first == 0 )) && echo ','
      first=0
      printf '    {"name":"%s","role":"%s","summary":"%s","spawn":{"model_class":"%s","effort":"%s","claude":{"model":"%s","model_id":"%s","effort":"%s","tools":["%s"]},"codex":{"model":"%s","effort":"%s"},"opencode":{"model":"%s"},"ollama":{"model":"%s"}},"definition":".KCC/capabilities/agents/%s.md"}' \
        "$name" "$role" "$desc" "$cls" "$eff" "$(model_for claude "$cls")" "$(model_for claude-id "$cls")" "$eff" "$tools" \
        "$(model_for codex "$cls")" "$(codex_effort "$eff")" "$(model_for opencode "$cls")" "$(model_for ollama "$cls")" "$name"
    done < <(find "$AGENTS_DIR" -maxdepth 1 -type f -name '*.md' | sort)
    echo
    echo '  ],'
    echo '  "skills": ['
    first=1
    while IFS= read -r file; do
      local name desc delegates
      name="$(yaml_scalar "$file" name)"; [[ -n "$name" ]] || name="$(basename "$file" .md)"
      desc="$(first_sentence "$(yaml_scalar "$file" description)" | json_escape)"
      delegates="$(yaml_list "$file" delegates-to | sed 's/.*/"&"/' | paste -sd ',' -)"
      (( first == 0 )) && echo ','
      first=0
      printf '    {"name":"%s","delegates_to":[%s],"summary":"%s"}' "$name" "$delegates" "$desc"
    done < <(find "$SKILLS_DIR" -maxdepth 1 -type f -name '*.md' | sort)
    echo
    if [[ -n "$runtime" ]]; then
      echo '  ],'
      printf '  %s\n' "$runtime"
    else
      echo '  ]'
    fi
    echo '}'
  } > "$json"
}

sync_claude() {
  local agents_out="$REPO_ROOT/.claude/agents"
  local skills_out="$REPO_ROOT/.claude/skills"
  mkdir -p "$agents_out" "$skills_out"
  while IFS= read -r file; do
    local name role model_class model desc
    name="$(yaml_scalar "$file" name)"; [[ -n "$name" ]] || name="$(basename "$file" .md)"
    model_class="$(yaml_scalar "$file" model-class)"
    model="$(model_for claude "$model_class")"
    desc="$(yaml_scalar "$file" description)"
    {
      echo "---"
      echo "name: $name"
      echo "description: >"
      echo "  $(first_sentence "$desc" | cut -c1-300)"
      echo "model: $model"
      echo "effort: $(effort_for "$file")"
      echo "tools: $(claude_tools_line "$file")"
      metadata_block "$file"
      echo "---"
      echo
      body_after_frontmatter "$file"
      agent_runtime_footer
    } > "$agents_out/$name.md"
    echo "[claude   ] [agent ] $agents_out/$name.md"
  done < <(find "$AGENTS_DIR" -maxdepth 1 -type f -name '*.md' | sort)
  while IFS= read -r file; do
    local name desc
    name="$(yaml_scalar "$file" name)"; [[ -n "$name" ]] || name="$(basename "$file" .md)"
    desc="$(yaml_scalar "$file" description)"
    mkdir -p "$skills_out/$name"
    {
      echo "---"
      echo "name: $name"
      echo "description: >"
      echo "  $desc"
      metadata_block "$file"
      echo "---"
      echo
      body_after_frontmatter "$file" | replace_args '$ARGUMENTS'
      skill_spawn_footer "$file"
    } > "$skills_out/$name/SKILL.md"
    echo "[claude   ] [skill ] $skills_out/$name/SKILL.md"
  done < <(find "$SKILLS_DIR" -maxdepth 1 -type f -name '*.md' | sort)

  # Seed .claude/settings.json from the kernel template ONLY when absent
  # (new cells get the token-actuals SessionEnd hook). Never overwrite a
  # hand-edited settings.json.
  local claude_settings="$REPO_ROOT/.claude/settings.json"
  local settings_tpl="$REPO_ROOT/.KCC/kernel/templates/claude-settings.json"
  if [[ ! -f "$claude_settings" ]]; then
    if [[ -f "$settings_tpl" ]]; then
      cp "$settings_tpl" "$claude_settings"
      echo "[claude   ] [config] $claude_settings (seeded from template)"
    fi
  else
    echo "[claude   ] [config] $claude_settings is hand-edited and was not touched."
  fi
}

sync_codex() {
  local agents_out="$REPO_ROOT/.codex/agents"
  local skills_out="$REPO_ROOT/.codex/skills"
  local tools_out="$REPO_ROOT/.codex/tools"
  mkdir -p "$agents_out" "$skills_out" "$tools_out"
  while IFS= read -r file; do
    local name role model_class model desc
    name="$(yaml_scalar "$file" name)"; [[ -n "$name" ]] || name="$(basename "$file" .md)"
    role="$(yaml_scalar "$file" role)"
    model_class="$(yaml_scalar "$file" model-class)"
    model="$(model_for codex "$model_class")"
    desc="$(yaml_scalar "$file" description)"
    {
      echo "---"
      echo "name: $name"
      echo "role: $role"
      echo "model: $model"
      echo "model-class: $model_class"
      echo "description: >"
      echo "  $desc"
      echo "tools:"
      plain_tools "$file"
      metadata_block "$file"
      echo "---"
      echo
      body_after_frontmatter "$file"
      agent_runtime_footer
    } > "$agents_out/$name.md"
    echo "[codex    ] [agent ] $agents_out/$name.md"
  done < <(find "$AGENTS_DIR" -maxdepth 1 -type f -name '*.md' | sort)
  while IFS= read -r file; do
    local name desc display short
    name="$(yaml_scalar "$file" name)"; [[ -n "$name" ]] || name="$(basename "$file" .md)"
    desc="$(yaml_scalar "$file" description)"
    mkdir -p "$skills_out/$name/agents"
    skill_package "$file" "$name" '$1' codex > "$skills_out/$name/SKILL.md"
    display="$(display_name "$name")"
    short="$(short_description "$desc")"
    printf 'interface:\n  display_name: "%s"\n  short_description: "%s"\n  default_prompt: "/%s "\n' "$display" "$short" "$name" > "$skills_out/$name/agents/openai.yaml"
    echo "[codex    ] [skill ] $skills_out/$name/SKILL.md"
  done < <(find "$SKILLS_DIR" -maxdepth 1 -type f -name '*.md' | sort)
  cat > "$tools_out/README.md" <<'EOF'
# Codex tools

Codex exposes tools through the active CLI sandbox, approval policy, installed
MCP servers, and enabled plugins. KCC mirrors neutral `tools-required`
metadata into generated agent files for routing context.
EOF
  if [[ ! -f "$REPO_ROOT/.codex/config.toml" ]]; then
    cat > "$REPO_ROOT/.codex/config.toml" <<'EOF'
# Project-scoped Codex CLI hints. Generated by .KCC/tools/sync-adapters.sh.

[project]
name = "spec-driven-framework"
entrypoint = "AGENTS.md"
EOF
  fi
  (( INSTALL_CODEX_SKILLS == 1 )) && echo "[codex    ] project-local Codex skills initialized"
}

sync_opencode() {
  local agents_out="$REPO_ROOT/.opencode/agents"
  local commands_out="$REPO_ROOT/.opencode/commands"
  local skills_out="$REPO_ROOT/.opencode/skills"
  mkdir -p "$agents_out" "$commands_out" "$skills_out"
  while IFS= read -r file; do
    local name model_class model desc
    name="$(yaml_scalar "$file" name)"; [[ -n "$name" ]] || name="$(basename "$file" .md)"
    model_class="$(yaml_scalar "$file" model-class)"
    model="$(model_for opencode "$model_class")"
    desc="$(yaml_scalar "$file" description)"
    {
      echo "---"
      echo "description: >"
      echo "  $desc"
      echo "mode: subagent"
      echo "model: $model"
      echo "permission:"
      echo "  read: allow"
      echo "  grep: allow"
      echo "  glob: allow"
      echo "  edit: allow"
      echo "  bash: allow"
      echo "  skill: allow"
      metadata_block "$file"
      echo "---"
      echo
      body_after_frontmatter "$file"
      agent_runtime_footer
    } > "$agents_out/$name.md"
    echo "[opencode ] [agent ] $agents_out/$name.md"
  done < <(find "$AGENTS_DIR" -maxdepth 1 -type f -name '*.md' | sort)
  while IFS= read -r file; do
    local name desc
    name="$(yaml_scalar "$file" name)"; [[ -n "$name" ]] || name="$(basename "$file" .md)"
    desc="$(yaml_scalar "$file" description)"
    {
      echo "---"
      echo "description: >"
      echo "  $desc"
      metadata_block "$file"
      echo "---"
      echo
      body_after_frontmatter "$file" | replace_args '$ARGUMENTS'
    } > "$commands_out/$name.md"
    mkdir -p "$skills_out/$name"
    skill_package "$file" "$name" '$ARGUMENTS' opencode > "$skills_out/$name/SKILL.md"
    echo "[opencode ] [skill ] $commands_out/$name.md"
  done < <(find "$SKILLS_DIR" -maxdepth 1 -type f -name '*.md' | sort)
  if [[ ! -f "$REPO_ROOT/opencode.json" ]]; then
    cat > "$REPO_ROOT/opencode.json" <<'EOF'
{
  "$schema": "https://opencode.ai/config.json",
  "theme": "system",
  "model": "anthropic/claude-sonnet-5",
  "autoshare": false,
  "autoupdate": false
}
EOF
  fi
}

sync_generic() {
  local base="$REPO_ROOT/.agents"
  local agents_out="$base/agents"
  local skills_out="$base/skills"
  local tools_out="$base/tools"
  mkdir -p "$agents_out" "$skills_out" "$tools_out"
  while IFS= read -r file; do
    local name role model_class desc
    name="$(yaml_scalar "$file" name)"; [[ -n "$name" ]] || name="$(basename "$file" .md)"
    role="$(yaml_scalar "$file" role)"
    model_class="$(yaml_scalar "$file" model-class)"
    desc="$(yaml_scalar "$file" description)"
    {
      echo "---"
      echo "name: $name"
      echo "role: $role"
      echo "model-class: $model_class"
      echo "description: >"
      echo "  $desc"
      echo "tools-required:"
      plain_tools "$file"
      metadata_block "$file"
      echo "---"
      echo
      body_after_frontmatter "$file"
      agent_runtime_footer
    } > "$agents_out/$name.md"
    echo "[generic  ] [agent ] $agents_out/$name.md"
  done < <(find "$AGENTS_DIR" -maxdepth 1 -type f -name '*.md' | sort)
  while IFS= read -r file; do
    local name
    name="$(yaml_scalar "$file" name)"; [[ -n "$name" ]] || name="$(basename "$file" .md)"
    mkdir -p "$skills_out/$name"
    skill_package "$file" "$name" '<ARGS>' generic > "$skills_out/$name/SKILL.md"
    echo "[generic  ] [skill ] $skills_out/$name/SKILL.md"
  done < <(find "$SKILLS_DIR" -maxdepth 1 -type f -name '*.md' | sort)
  cat > "$tools_out/README.md" <<'EOF'
# Generic tool contract

Map neutral `tools-required` values to the target harness permission model.
EOF
  cat > "$base/config.json" <<'EOF'
{
  "schema": "spec-driven-framework.generic-agents.v1",
  "schema_version": "1.0",
  "entrypoint": "../AGENTS.md",
  "agents_path": "agents",
  "skills_path": "skills",
  "tools_path": "tools",
  "local_only": true
}
EOF
  {
    echo '{'
    echo '  "schema_version": "1.0",'
    printf '  "generated": "%s",\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo '  "entrypoint": "../AGENTS.md",'
    echo '  "agents_path": "agents",'
    echo '  "skills_path": "skills"'
    echo '}'
  } > "$base/manifest.json"
  {
    echo "# Generic Agent Bundle"
    echo
    echo "Generated from .KCC/kernel and .KCC/capabilities."
    echo
    echo "## Agents"
    while IFS= read -r file; do
      local name desc
      name="$(yaml_scalar "$file" name)"; [[ -n "$name" ]] || name="$(basename "$file" .md)"
      desc="$(yaml_scalar "$file" description)"
      echo "- \`$name\` - $desc"
    done < <(find "$AGENTS_DIR" -maxdepth 1 -type f -name '*.md' | sort)
    echo
    echo "## Skills"
    while IFS= read -r file; do
      local name desc
      name="$(yaml_scalar "$file" name)"; [[ -n "$name" ]] || name="$(basename "$file" .md)"
      desc="$(yaml_scalar "$file" description)"
      echo "- \`/$name\` - $desc"
    done < <(find "$SKILLS_DIR" -maxdepth 1 -type f -name '*.md' | sort)
  } > "$base/AGENTS.md"
}

sync_ollama() {
  local out="$REPO_ROOT/ollama"
  mkdir -p "$out"
  {
    echo '{'
    echo '  "schema_version": "1.0",'
    printf '  "generated": "%s",\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo '  "agents": ['
    local first=1
    while IFS= read -r file; do
      local name role model_class model desc
      name="$(yaml_scalar "$file" name)"; [[ -n "$name" ]] || name="$(basename "$file" .md)"
      role="$(yaml_scalar "$file" role | json_escape)"
      model_class="$(yaml_scalar "$file" model-class)"
      model="$(model_for ollama "$model_class")"
      desc="$(yaml_scalar "$file" description | json_escape)"
      (( first == 0 )) && echo ','
      first=0
      printf '    {"name":"%s","role":"%s","model_class":"%s","recommended_model":"%s","description":"%s"}' "$name" "$role" "$model_class" "$model" "$desc"
    done < <(find "$AGENTS_DIR" -maxdepth 1 -type f -name '*.md' | sort)
    echo
    echo '  ]'
    echo '}'
  } > "$out/agents.json"
  cat > "$out/README.md" <<'EOF'
# Ollama bindings

Generated local-model recommendations for KCC agents. Use with an
OpenAI-compatible Ollama bridge or a harness that can route by agent name.
EOF
  echo "[ollama   ] [manifest] $out/agents.json"
}

initialize_framework
case "$HARNESS" in
  claude) sync_claude ;;
  codex) sync_codex ;;
  opencode) sync_opencode ;;
  generic) sync_generic ;;
  ollama) sync_ollama ;;
  all)
    sync_claude
    sync_codex
    sync_opencode
    sync_generic
    sync_ollama
    ;;
esac

# Write-time guard sweep: strip disallowed control characters from all
# generated output so corruption can never silently survive a future edit.
strip_ctrl_tree "$REPO_ROOT/coordination"
for gen in AGENTS.md CLAUDE.md .claude .codex .opencode .agents ollama; do
  strip_ctrl_tree "$REPO_ROOT/$gen"
done

echo
echo "Sync complete for harness: $HARNESS"
echo "Source of truth: .KCC/kernel and .KCC/capabilities"
echo "Generated adapter surfaces are local output and should not be committed."
