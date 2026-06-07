---
# Functional fields (none - adapter docs are pure prose, no harness-consumed fields)

# Obsidian metadata (used in the vault, ignored by harness adapters)
title: Generic .agents Adapter
aliases:
  - generic-adapter
  - agents-adapter
tags:
  - framework/adapter
  - harness/generic
created: 2026-05-24
updated: 2026-06-05
version: 1.2.0
status: active
copyright: "KCC framework (c) 2026 Tarek Fawaz"
homepage: "https://tikasway.dev/kcc"
license: "Licensed under the terms in LICENSE"
---

# Generic .agents adapter

How `.KCC/kernel/` neutral sources are surfaced for harnesses that understand or can ingest a portable `.agents/` bundle.

## Invocation

```powershell
powershell -ExecutionPolicy Bypass -File .KCC\tools\sync-adapters.ps1 generic
# or, as part of an all-harness run:
powershell -ExecutionPolicy Bypass -File .KCC\tools\sync-adapters.ps1
```

## Convention

The generic adapter creates a local `.agents/` tree that favors broad
readability over harness-specific behavior. It uses the common
`skills/{name}/SKILL.md` package shape, plus plain markdown agent files and
JSON indexes for tools that prefer structured discovery.

OpenCode explicitly discovers project-local `.agents/skills/<name>/SKILL.md`
packages. Harness skills are Markdown instruction files in a workflow
repository with root `AGENTS.md` / `CLAUDE.md` context and skill files that can
be referenced by coding assistants. The generic adapter is therefore a portable
bundle for ingestion or copying, not a Harness platform installer.

## Generated files

| Neutral source                       | Generated generic file                              |
|--|--|
| `.KCC/capabilities/agents/{name}.md`         | `.agents/agents/{name}.md`                          |
| `.KCC/capabilities/skills/{name}.md`         | `.agents/skills/{name}/SKILL.md`                    |
| tool contract                        | `.agents/tools/README.md`                           |
| adapter config                       | `.agents/config.json`                               |
| adapter manifest                     | `.agents/manifest.json`                             |
| readable catalog                     | `.agents/AGENTS.md`                                 |

## Tool mapping

Generic harnesses should map each agent's neutral `tools-required` values to their own permission system:

| Neutral tool | Expected capability |
|--|--|
| `read`       | Read project files |
| `search`     | Glob, grep, or semantic search over project files |
| `edit`       | Create and modify files in the workspace |
| `exec`       | Run shell commands subject to the harness approval policy |
| `web`        | Fetch or search web documentation when enabled |

## Parallel execution realization

**Documented, not yet built.** The generic adapter realizes the spawner contract
`run(independent_items)` from
[[../protocols/parallel-execution|parallel-execution]] with the **universal
spawner** `start-agent-session.ps1` / `.sh`.

- **Mechanism:** `start-agent-session.ps1` (or `.sh`) opens **N sessions** - one
  per wave item, each scoped to its story/enabler and that item's declared
  impacted files under `src/IDEA-{ID}-{slug}/...`. If the host runtime cannot
  spawn concurrent sessions, fall back to **sequential** execution of the wave
  items.
- **Barrier:** the orchestrator waits for all spawned sessions in the wave to
  complete, collects results, then starts the next wave.
- **Levels:** L1 (one session per independent spec flow) and L2 (one per
  independent story/enabler in a wave) both apply.
- **Merge-safety:** the planner's file-disjoint wave rule keeps concurrent
  sessions writing non-overlapping files; optional git-worktree isolation for
  risky waves.
- **Visible / sandboxed role:** `start-agent-session.ps1` is itself the
  visible/sandboxed spawner available to all harnesses; for the generic adapter
  it is also the primary parallel mechanism. HOTL window-permission rules in
  [[../protocols/auto-mode|auto-mode]] apply.

## Caveats

- `.agents/` is descriptive and local-only. It does not grant permissions by itself.
- Harnesses differ on whether they read `.agents/AGENTS.md`, `.agents/manifest.json`, or only `skills/*/SKILL.md`; the adapter emits all three discovery surfaces.
