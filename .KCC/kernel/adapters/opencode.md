---
# Functional fields (none - adapter docs are pure prose, no harness-consumed fields)

# Obsidian metadata (used in the vault, ignored by harness adapters)
title: OpenCode Adapter
aliases:
  - opencode-adapter
tags:
  - framework/adapter
  - harness/opencode
created: 2026-05-24
updated: 2026-06-05
version: 1.4.0
status: active
copyright: "KCC framework (c) 2026 Tarek Fawaz"
homepage: "https://tikasway.dev/kcc"
license: "Licensed under the terms in LICENSE"
---

# OpenCode adapter

How `.KCC/kernel/` and `.KCC/capabilities/` neutral sources are surfaced to
OpenCode.

## Invocation

```powershell
powershell -ExecutionPolicy Bypass -File .KCC\tools\framework-init.ps1 opencode
# or, as part of an all-harness run:
powershell -ExecutionPolicy Bypass -File .KCC\tools\sync-adapters.ps1
```

## Convention

OpenCode reads the root `AGENTS.md` for high-level orientation. It also discovers project-local markdown agents from `.opencode/agents/`, slash commands from `.opencode/commands/`, native skills from `.opencode/skills/{name}/SKILL.md`, and per-project config from `opencode.json`. The sync script generates all of these local artifacts.

The generated commands are explicit `/name` prompts. The generated skills are on-demand `SKILL.md` packages that OpenCode can expose through its native `skill` tool.

Per OpenCode skill discovery, project-local skill packages can also live under
`.agents/skills/<name>/SKILL.md`; the generic adapter emits that shape. Skill
frontmatter keeps `name` and `description` present and uses lowercase
hyphenated names that match the directory.

## Generated files

| Neutral source                       | Generated OpenCode file                              |
|--|--|
| `.KCC/capabilities/agents/{name}.md`         | `.opencode/agents/{name}.md`                         |
| `.KCC/capabilities/skills/{name}.md`         | `.opencode/commands/{name}.md`                       |
| `.KCC/capabilities/skills/{name}.md`         | `.opencode/skills/{name}/SKILL.md`                   |
| (one-time scaffold)                  | `opencode.json` (only created if absent)             |

The root `AGENTS.md` is created from `.KCC/kernel/templates/AGENTS.md` when missing, then preserved for local edits. An existing `opencode.json` is detected and left untouched.

## Frontmatter mapping (agents)

The generated `.opencode/agents/{name}.md` follows OpenCode's documented markdown-agent shape:

```yaml
---
description: >
  <one-liner from neutral source>
mode: subagent
model: <provider>/<model>
permission:
  read: allow
  glob: allow
  grep: allow
  list: allow
  edit: deny
  bash: deny
  skill: allow
---
```

`mode` is always `subagent` because the orchestrator drives delegation. The `permission` map is computed from the neutral `tools-required` list. Search enables `glob`, `grep`, and `list`; edit and exec map to `edit` and `bash`; web maps to `webfetch` and `websearch`.

## Model class mapping

| Neutral class         | OpenCode model id                              |
|--|--|
| `strong-reasoning`    | `anthropic/claude-opus-4-8`                    |
| `balanced`            | `openai/gpt-5-5`                  |
| `fast-implementation` | `openai/gpt-5`                   |
| `local-strong`        | `ollama/qwen2.5:72b` (see [[ollama]])          |
| `local-fast`          | `ollama/qwen2.5:7b` (see [[ollama]])           |

Edit `opencode.json` to switch providers globally (for example, `openai/gpt-5`) or override per-agent via the generated agent file's `model:` field.

## Argument placeholder

OpenCode commands and skills use `$ARGUMENTS`. The sync script rewrites the neutral `<ARGS>` placeholder to `$ARGUMENTS` in both `.opencode/commands/*.md` and `.opencode/skills/*/SKILL.md`.

## Parallel execution realization

**Documented, not yet built.** OpenCode realizes the spawner contract
`run(independent_items)` from
[[../protocols/parallel-execution|parallel-execution]] with **N headless
OpenCode run/session invocations** - one per wave item.

- **Mechanism:** the orchestrator launches one headless OpenCode run/session per
  wave item, each scoped to its story/enabler and that item's declared impacted
  files under `src/IDEA-{ID}-{slug}/...`.
- **Barrier:** barrier on completion - the orchestrator waits for all wave
  invocations to finish, collects results, then starts the next wave.
- **Levels:** L1 (one invocation per independent spec flow) and L2 (one per
  independent story/enabler in a wave) both apply.
- **Merge-safety:** the planner's file-disjoint wave rule keeps concurrent
  invocations writing non-overlapping files; optional git-worktree isolation for
  risky waves.
- **Visible / sandboxed option:** `.KCC/tools/start-agent-session.ps1` can surface
  these sessions visibly or sandbox them; complementary, not a fallback.

## Caveats

- OpenCode's project-level `permission` block in `opencode.json` is hand-edited; the sync script only scaffolds the file once.
- Legacy `.opencode/agent/` and `.opencode/command/` folders from earlier versions are not used by the current adapter. The documented generated paths are plural.
- When Claude Code, Codex, and OpenCode are used against the same repo, all regenerated harness trees originate from `.KCC/kernel/` and `.KCC/capabilities/`. Always run the sync script after editing neutral sources.
