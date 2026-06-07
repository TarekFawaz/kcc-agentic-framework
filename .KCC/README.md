---
title: KCC Local Framework Container
aliases:
  - KCC
  - local-kcc
tags:
  - framework/documentation
  - kcc
created: 2026-05-24
updated: 2026-05-25
version: 0.4.0
status: active
---

# .KCC

This folder contains the local KCC v0.4 operating-model slice. It is the
framework source and tooling container. It is not a place for generated project
code, agent traces, or runtime workflow output.

## Contents

| Path | Purpose |
|--|--|
| `.KCC/kernel/` | Governance, protocols, contracts, adapter notes, templates, and dialect definitions. |
| `.KCC/capabilities/` | Local reusable agents and skills. These are the source files used to generate harness-specific adapters. |
| `.KCC/tools/` | Canonical local tools for initialization, sync, validation, workflow import, backchannel viewing, and approved session fan-out. |

Root `AGENTS.md`, `CLAUDE.md`, and `QUICKSTART.md` stay outside `.KCC`
because harnesses and humans expect to find them at the project root.

Runtime output also stays outside `.KCC`: `ideation/`, `specs/`,
`architecture/`, `coordination/`, `memory/`, `Traces/`, `migrations/`,
`solution/`, application `src/`, application `docs/`, and generated harness
folders such as `.codex/`, `.claude/`, `.opencode/`, `.agents/`, and `ollama/`.

## First Run

Use the framework initializer from the repo root:

```powershell
powershell -ExecutionPolicy Bypass -File .KCC\tools\framework-init.ps1 codex
```

`framework-init.ps1` delegates to `sync-adapters.ps1`, so either command can
create missing infrastructure and regenerate harness adapters.

## Compatibility

The root `tools/` folder contains thin wrappers that call `.KCC/tools/` so older
commands such as this still work:

```powershell
powershell -ExecutionPolicy Bypass -File tools\sync-adapters.ps1 codex
```

## Deferred

Global capability installation, global meta-agents, Inspector Pipeline
promotion, and deeper KCC governance automation are deferred to later stages.
