---
title: AGENTS.md - Spec-Driven Orchestrator
aliases:
  - agents-catalog
  - orchestrator
tags:
  - framework/documentation
  - entrypoint
created: {{DATE}}
updated: {{DATE}}
version: 1.3.0
status: active
copyright: "KCC framework (c) 2026 Tarek Fawaz"
homepage: "https://tikasway.dev/kcc"
license: "Licensed under the terms in LICENSE"
---

# AGENTS.md

Root orchestrator for the spec-driven workflow framework. Codex, OpenCode,
Ollama-backed harnesses, and many generic agent runners can use this file as
their project entrypoint.

This file was created from `.KCC/kernel/templates/AGENTS.md` because no root
`AGENTS.md` existed. It is safe to edit after initialization. To refresh
generated harness outputs, edit `.KCC/kernel/` or `.KCC/capabilities/` and
rerun:

```powershell
powershell -ExecutionPolicy Bypass -File .KCC\tools\framework-init.ps1 -Harness all
```

```bash
bash .KCC/tools/framework-init.sh all
```

## What This Repo Is

A portable, harness-neutral spec-driven workflow framework. You seed an idea,
or onboard an existing codebase, then the workflow moves through
interrogation, spec creation, budget gating, planning, implementation,
verification, and review.

## Harness Outputs

{{HARNESS_OUTPUT_TABLE}}

## Lifecycle

```text
interrogate -> create -> token-budget -> plan -> token-budget -> implement -> test -> review
```

Meta-agents wrap the lifecycle:

- `butler-brief` gathers relevant memory before agent work.
- `butler-remember` stores reusable learnings after agent work.
- `token-estimate` gates expensive plan and implementation steps.
- `auto` chains the lifecycle but starts fresh ideas with interrogation and
  stops at every human gate unless an explicit AutoPolicy covers the gate.

## Agents

{{AGENT_TABLE}}

## Skills

{{SKILL_TABLE}}

## Orchestrator Map

{{ROUTE_TABLE}}

The generated machine-readable route map lives at
`coordination/orchestrator.json`.

## Model Classes

{{MODEL_CLASS_TABLE}}

## Quality Gates

- Fresh ideas should start with `idea-interrogator`, which creates
  `ideation/IDEA-{ID}-{slug}/idea-{ID}-{slug}.md` plus linked supporting artifacts.
- `auto <idea>` must route to the `auto` skill and must never write
  application/source files before interrogation, spec creation, planning, and
  token-budget gates complete. `auto <idea> --silent --assume --accuracy 95% --budget 200 USD`
  is allowed to use documented assumptions and one upfront budget approval,
  then continue silently until confidence drops below threshold or projected
  spend exceeds the cap.
- Existing codebases should start with `/solution-onboard` so future ideas and
  specs can reference the real solution baseline.
- Each spec is an epic folder. The same-name folder note defines the epic and
  `backlog.md` indexes separate INVEST-checked story/enabler files under
  `backlog/`. `parallelization.md` records dependency waves and proposed
  sub-agent sessions.
- `/technical-interrogator` runs before spec creation; UX/UI, security, and
  infrastructure interrogators run when their domains apply.
- Architect maintains global ADRs, guardrails, quality gates, selected
  dialects, and required Mermaid `.mmd` diagrams under `architecture/`.
- Any agent confidence below the configured threshold (95% by default) triggers `/critical-human-gate`.
- Token budget approval is required before planning and implementation unless
  a valid AutoPolicy budget approval covers the current estimate.
- Implementation should follow the approved plan and selected dialects; if the
  plan is wrong, stop and report.
- Verifier must produce explicit PASS/FAIL per epic and backlog-item acceptance
  criterion and apply the same dialect review guidance.
- Greenfield generated code lives under `src/`, project docs under `docs/`,
  and a root `README.md` is required.
- Framework source lives under `.KCC/kernel/` and `.KCC/capabilities/`;
  generated harness files should be regenerated, not hand-edited.

## Local State

- Ideas: `ideation/IDEA-{ID}-{slug}/idea-{ID}-{slug}.md`
- Specs: `specs/SPEC-{ID}-{slug}/SPEC-{ID}-{slug}.md` plus `backlog.md`,
  `backlog/STORY-*.md`, `backlog/ENABLER-*.md`, and `parallelization.md`
- Existing solution baseline: `solution/solution.md`
- Architecture: `architecture/adrs/`, `architecture/guardrails.md`, `architecture/quality-gates.md`
- Coordination: `coordination/backchannel.jsonl`
- Memory: `memory/`
- Traces: `Traces/`
