---
title: KCC Kernel
aliases:
  - kernel-readme
  - kcc-kernel
tags:
  - framework/documentation
  - kernel
created: 2026-05-24
updated: 2026-05-25
version: 0.4.0
status: active
copyright: "KCC framework (c) 2026 Tarek Fawaz"
homepage: "https://tikasway.dev/kcc"
license: "Licensed under the terms in LICENSE"
---

# KCC Kernel

`.KCC/kernel/` contains the governance side of the local KCC framework:
protocols, contracts, templates, adapter notes, and dialect definitions.
Reusable executable behavior lives in `.KCC/capabilities/`.

Edit kernel files when you are changing the operating model. Edit
capabilities files when you are changing agents or skills. After either kind of
edit, run:

```powershell
powershell -ExecutionPolicy Bypass -File .KCC\tools\sync-adapters.ps1
```

## Layout

```text
.KCC/kernel/
|-- README.md
|-- adapters/
|-- contracts/
|-- protocols/
|   `-- dialects/
`-- templates/
```

| Path | Purpose |
|--|--|
| `.KCC/kernel/adapters/` | Harness mapping notes for Claude Code, Codex, OpenCode, generic `.agents`, and Ollama. |
| `.KCC/kernel/contracts/` | Compact contracts for agents, skills, confidence, cost envelopes, and decision traces. |
| `.KCC/kernel/protocols/` | Cross-cutting workflow rules: ideas, specs, auto mode, traces, handovers, architecture, token budgets, and Obsidian conventions. |
| `.KCC/kernel/protocols/dialects/` | Implementation/review dialects selected by architect and consumed by implementer, verifier, planner, token-guard, and butler. |
| `.KCC/kernel/templates/` | Root entrypoint and artifact templates used by initialization and adapter sync. |

## Capability Source

Agents and skills are local capabilities:

```text
.KCC/capabilities/
|-- agents/
`-- skills/
```

Each agent file must include neutral functional fields (`name`, `role`,
`model-class`, `description`, `tools-required`, `inputs`, `outputs`) plus a
clear process, output format, and constraints.

Each skill file must include neutral functional fields (`name`, `description`,
`argument-placeholder`, `delegates-to`) plus concise orchestration steps.

## Generated Outputs

`sync-adapters.ps1` reads `.KCC/kernel/` and `.KCC/capabilities/`, then
generates harness outputs outside `.KCC`:

| Harness | Generated output |
|--|--|
| Claude Code | `.claude/agents/`, `.claude/skills/` |
| Codex | `.codex/agents/`, `.codex/skills/`, `.codex/config.toml` |
| OpenCode | `.opencode/agents/`, `.opencode/commands/`, `.opencode/skills/`, `opencode.json` |
| Generic | `.agents/agents/`, `.agents/skills/`, `.agents/tools/`, `.agents/config.json`, `.agents/manifest.json` |
| Ollama | `ollama/agents.json`, `ollama/README.md` |

Root `AGENTS.md` and `CLAUDE.md` are created from templates only when missing,
then preserved for local project edits.

## Runtime Output

Runtime workflow artifacts stay at the project root:

```text
ideation/
specs/
architecture/
coordination/
memory/
Traces/
migrations/
solution/
src/
docs/
```

No command output, traces, generated source code, or project documentation
should be written under `.KCC/kernel/`.

## Deterministic Autobuild Runtime

`.KCC/runtime/` contains executable control-plane support for the optional
`autobuild` workflow: schemas, durable state, lifecycle validation, budgets,
leases, policy evaluation, evidence verification, and local API/CLI code.
Generated run state remains at `coordination/autobuild/<RUN-ID>/`; `.KCC/runtime/`
is source code only.
