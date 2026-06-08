---
# Functional fields (none - adapter docs are pure prose, no harness-consumed fields)

# Obsidian metadata (used in the vault, ignored by harness adapters)
title: Claude Code Adapter
aliases:
  - claude-adapter
tags:
  - framework/adapter
  - harness/claude
created: 2026-05-24
updated: 2026-06-05
version: 1.2.0
status: active
copyright: "KCC framework (c) 2026 Tarek Fawaz"
homepage: "https://tikasway.dev/kcc"
license: "Licensed under the terms in LICENSE"
---

# Claude Code adapter

How `.KCC/kernel/` neutral sources map onto Claude Code's on-disk conventions.

## Invocation

```powershell
powershell -ExecutionPolicy Bypass -File .KCC\tools\framework-init.ps1 claude
# or, as part of an all-harness run:
powershell -ExecutionPolicy Bypass -File .KCC\tools\sync-adapters.ps1
```

## Generated files

`.KCC/tools/sync-adapters.ps1` regenerates these from `.KCC/kernel/`:

| Neutral source                       | Generated Claude file                          |
|--|--|
| `.KCC/capabilities/agents/{name}.md`         | `.claude/agents/{name}.md`                     |
| `.KCC/capabilities/skills/{name}.md`         | `.claude/skills/{name}/SKILL.md`               |

The root `CLAUDE.md` is created from `.KCC/kernel/templates/CLAUDE.md` when
missing, then preserved for local edits.

## Frontmatter mapping (agents)

Neutral -> Claude:

| Neutral field        | Claude field      | Notes                                    |
|--|--|--|
| `name`               | (filename)        | Filename is the canonical name           |
| `role`               | (omitted)         | Folded into the body / description       |
| `model-class`        | `model:`          | Resolved via the table below             |
| `description`        | `description:`    | Copied verbatim                          |
| `tools-required`     | `allowed-tools:`  | Mapped via the tool table below          |
| `inputs` / `outputs` | (omitted)         | Documented in the body sections          |

### Model class mapping

| Neutral class         | Claude model        |
|--|--|
| `strong-reasoning`    | `claude-opus-4-8`   |
| `balanced`            | `claude-sonnet-4-6` |
| `fast-implementation` | `claude-haiku-4-5`  |
| `local-strong`        | n/a - use Ollama adapter |
| `local-fast`          | n/a - use Ollama adapter |

### Tool name mapping

| Neutral tool | Claude tool(s)                            |
|--|--|
| `read`       | `Read`                                    |
| `search`     | `Glob`, `Grep`                            |
| `edit`       | `Write`, `Edit`                           |
| `exec`       | `Bash` (narrow as `Bash(git log*)` etc.)  |
| `web`        | `WebSearch`, `WebFetch`                   |

The sync script preserves narrow exec scopes (`Bash(git log*)`, `Bash(git diff*)`) using a small per-agent overrides table inside the script - the neutral file just lists `exec` semantically.

## Frontmatter mapping (skills)

Neutral -> Claude:

| Neutral field           | Claude field      | Notes                                        |
|--|--|--|
| `name`                  | (folder name)     | Becomes `.claude/skills/{name}/SKILL.md`     |
| `description`           | `description:`    | Copied verbatim                              |
| `argument-placeholder`  | (substitution)    | `<ARGS>` is rewritten to `$ARGUMENTS`        |
| `delegates-to`          | (informational)   | Claude resolves delegation by agent name     |

## Parallel execution realization

Claude Code is the **built and validated** realization of the spawner contract
`run(independent_items)` in [[../protocols/parallel-execution|parallel-execution]].

- **Mechanism:** native parallel subagents. To execute a wave, the orchestrator
  issues **one subagent (Task/Agent) call per wave item in a single turn**.
  Claude Code runs those subagent calls **concurrently**.
- **Scope per call:** each subagent is scoped to one wave item (a story/enabler
  at L2, or a whole spec flow at L1) and that item's declared impacted files
  under `src/IDEA-{ID}-{slug}/...`. Because the planner guarantees waves are
  file-disjoint, the concurrent subagents write non-overlapping files.
- **Barrier:** "await all subagent results." The turn completes only when every
  subagent in the wave has returned; the orchestrator then collects results and
  starts the next wave.
- **Levels:** L1 (across independent specs) and L2 (across independent
  stories/enablers within a wave) both use this same one-call-per-item pattern.
- **Governance:** butler-brief/remember wrap each subagent (shared trace
  session, agent-named appends); token-guard accounts each; confidence-gate and
  loop detection apply per subagent. One upfront token-budget gate covers the
  whole wave set.
- **Visible / sandboxed option:** `.KCC/tools/start-agent-session.ps1` can
  additionally surface these flows in visible windows or sandbox a risky unit;
  it complements native subagents and is not a fallback. HOTL window-permission
  rules in [[../protocols/auto-mode|auto-mode]] still apply.

## Caveats

- The lifecycle hook in `.claude/settings.json` (`SubagentStart` matcher for `implementer`) is harness-specific and **not** modelled in `.KCC/kernel/`. Keep it in `settings.json` directly.
- Claude's permissions (`permissions.allow`) are also harness-specific; the sync script must not overwrite `.claude/settings.json`.
- Round-trip is faithful: regenerated `.claude/agents/*.md` and `.claude/skills/*/SKILL.md` are content-equivalent to the originals (modulo minor whitespace normalization). The only deliberate drift is the `model:` line, which now reads from the neutral class table rather than being hand-set per file.
