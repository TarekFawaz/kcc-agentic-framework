---
# Functional fields (none - adapter docs are pure prose, no harness-consumed fields)

# Obsidian metadata (used in the vault, ignored by harness adapters)
title: OpenAI Codex CLI Adapter
aliases:
  - codex-adapter
tags:
  - framework/adapter
  - harness/codex
created: 2026-05-24
updated: 2026-06-05
version: 1.3.0
status: active
copyright: "KCC framework (c) 2026 Tarek Fawaz"
homepage: "https://tikasway.dev/kcc"
license: "Licensed under the terms in LICENSE"
---

# OpenAI Codex CLI adapter

How `.KCC/kernel/` neutral sources are surfaced to OpenAI's Codex CLI.

## Invocation

```powershell
# First-time or refresh:
powershell -ExecutionPolicy Bypass -File .KCC\tools\framework-init.ps1 codex

# Explicit project-local skill initialization:
powershell -ExecutionPolicy Bypass -File .KCC\tools\sync-adapters.ps1 codex -InstallCodexSkills

# Or as part of an all-harness run:
powershell -ExecutionPolicy Bypass -File .KCC\tools\sync-adapters.ps1
```

## Convention

Codex CLI loads the root `AGENTS.md` at the project root and treats it as the directive catalogue. The initializer creates `AGENTS.md` from `.KCC/kernel/templates/AGENTS.md` when missing, then preserves it for local edits.

In addition, the script generates a local `.codex/` tree with reference agents, native `SKILL.md` skill packages, and a small tools note. This initializer is local-first: it never writes to `~/.codex`. Global/meta-agent skill installation should be handled by a later bootstrap pipeline.

## Generated files

| Neutral source                       | Generated Codex file                              |
|--|--|
| `.KCC/capabilities/agents/{name}.md`         | `.codex/agents/{name}.md`                         |
| `.KCC/capabilities/skills/{name}.md`         | `.codex/skills/{name}/SKILL.md`                   |
| `.KCC/capabilities/skills/{name}.md`         | `.codex/skills/{name}/agents/openai.yaml`         |
| tool contract                        | `.codex/tools/README.md`                          |
| (one-time scaffold)                  | `.codex/config.toml` (only created if absent)     |

The root `AGENTS.md` is created when missing and never overwritten by normal sync. Every generated file carries Obsidian frontmatter alongside its harness-required fields where that is safe for the target format.

## Model class mapping

| Neutral class         | Codex CLI model     |
|--|--|
| `strong-reasoning`    | `gpt-5`             |
| `balanced`            | `gpt-5-mini`        |
| `fast-implementation` | `gpt-5-nano`        |
| `local-strong`        | falls back to `gpt-5` (or use Ollama adapter) |
| `local-fast`          | falls back to `gpt-5-nano` (or use Ollama adapter) |

Resolution is documented in each `.codex/agents/{name}.md` frontmatter (`model:` field). The actual session model Codex uses is whatever the CLI was launched with. To enforce per-agent classes, drive Codex from a wrapper script that re-launches with the right `--model` flag per delegation.

## Argument placeholder

Codex skill bodies keep slash-command style arguments by rewriting the neutral `<ARGS>` placeholder to `$1` inside `.codex/skills/{name}/SKILL.md`.

## Tool mapping

Codex CLI exposes tools via its sandbox / approval policy rather than a per-agent allowlist. The neutral `tools-required` list is mirrored as a plain YAML list in each `.codex/agents/{name}.md` for documentation; Codex itself grants the union of what the project's sandbox config allows. Make sure `exec`-requiring agents have shell access enabled in the launching profile.

## Parallel execution realization

**Documented, not yet built.** Codex realizes the spawner contract
`run(independent_items)` from
[[../protocols/parallel-execution|parallel-execution]] with **N headless
`codex exec` (non-interactive) processes** - one per wave item.

- **Mechanism:** the orchestrator launches one `codex exec` process per wave
  item, each scoped to its story/enabler and that item's declared impacted files
  under `src/IDEA-{ID}-{slug}/...`.
- **Barrier:** the orchestrator waits on all spawned processes for the wave, then
  collects their results before starting the next wave.
- **Levels:** L1 (one process per independent spec flow) and L2 (one process per
  independent story/enabler in a wave) both apply.
- **Merge-safety:** the planner's file-disjoint wave rule means the concurrent
  processes write non-overlapping files; optional git-worktree isolation per
  process for risky waves.
- **Visible / sandboxed option:** `.KCC/tools/start-agent-session.ps1` can launch
  the `codex exec` units in visible windows or sandbox them; complementary, not a
  fallback.

## Caveats

- Codex CLI does not auto-load `.codex/agents/*.md` today; those files are reference material that mirror `.claude/agents/`. The authoritative directive catalogue Codex reads is the root `AGENTS.md`.
- `.codex/skills/{name}/SKILL.md` follows the local skill-package convention (`name` + `description` frontmatter, optional `agents/openai.yaml` UI metadata). This repo does not install global skills.
- The root `AGENTS.md` is shared with the OpenCode adapter; see [[opencode]].
