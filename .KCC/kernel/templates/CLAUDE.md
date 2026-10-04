---
title: CLAUDE.md - Claude Code Orchestrator
aliases:
  - claude-orchestrator
tags:
  - framework/documentation
  - entrypoint
  - harness/claude
created: {{DATE}}
updated: {{DATE}}
version: 2.0.0
status: active
copyright: "KCC framework (c) 2026 Tarek Fawaz"
homepage: "https://tikasway.dev/kcc"
license: "Licensed under the terms in LICENSE"
---

# CLAUDE.md

Loaded every session, so keep it short. Details live in the files it points to.

## Project

<!-- Fill in by hand or through /solution-onboard. Keep it to 40 lines or
fewer: goal, fixed constraints, definition of done. Add a "Context loading"
table (task -> file -> ~tokens) so agents load one detail file at a time, and
list the large files that must NOT be loaded by default. -->

## KCC Framework

Spec-driven, harness-neutral workflow. Claude Code already lists the
generated `.claude/agents/` and `.claude/skills/` at session start, so don't
re-read them.

- **Spawning agents:** follow `coordination/orchestrator.md` -> *Spawn
  protocol*. Each agent's model, effort, tools, inputs, and outputs are in
  its *Agent profiles* row there, and in `coordination/orchestrator.json` ->
  `agents[].spawn`.
- **Lifecycle:** `interrogate -> create -> token-budget -> plan -> token-budget -> implement -> test -> review`,
  wrapped by `butler-brief` / `butler-remember` (memory), `token-estimate`
  (budget gate), and `auto` (chains the lifecycle and stops at human gates
  unless an AutoPolicy covers them).
- **Operator commands:** `/bug-report` (a human-found bug re-enters the flow),
  `auto resume` (continue from the latest restore point),
  `.KCC/tools/kcc-handover` (switch harness or CLI),
  `.KCC/tools/kcc-limit-watch` (unattended resume after a usage-limit reset),
  `.KCC/tools/repo-bootstrap` (git init/remote and hooks, asked once),
  and the optional post-review steps `/spec-merge` (pull-request draft via
  `repo-steward`; never pushes) and `/spec-deploy` (pipeline + IaC files;
  never deploys).
- **Git workflow:** protected `main`, work on `spec/SPEC-{ID}`, merge by pull
  request after an `APPROVED` review, commit subjects
  `SPEC-NNN Story-NNN: ...`. Rules, hooks, and settings:
  `.KCC/kernel/protocols/git-workflow.md`.
- **Source of truth:** `.KCC/kernel/` + `.KCC/capabilities/`. Regenerate with
  `powershell -ExecutionPolicy Bypass -File .KCC\tools\framework-init.ps1 -Harness claude`
  (or `bash .KCC/tools/framework-init.sh claude`). This file is created only
  when missing, so local edits persist.

## Quality Gates

- Fresh ideas start with `/idea-interrogator`; existing code starts with `/solution-onboard`.
- `auto` never writes source before the interrogation, spec, plan, and token-budget gates pass.
- Specs are epic folders: a folder note, `backlog.md`, INVEST-checked
  `Backlog/Story-*|Enabler-*.md`, and `parallelization.md`.
- `/technical-interrogator` runs before spec creation. UX/UI, security, and
  infrastructure interrogators run when their domain applies.
- The architect owns ADRs, guardrails, quality gates, dialects, and `.mmd` diagrams under `architecture/`.
- Confidence below the threshold (95% by default) runs `/critical-human-gate`.
- Plan and implement need token-budget approval, unless an AutoPolicy covers them.
- Implement per the approved plan and dialects; if the plan is wrong, stop and report.
- The verifier gives explicit PASS/FAIL per epic and backlog acceptance criterion.
- Code goes in `src/`, docs in `docs/`, and a root `README.md` is required.

## Local State

`ideation/IDEA-*/` · `specs/IDEA-*-Specs/SPEC-*/` · `solution/solution.md` ·
`architecture/` · `coordination/` (orchestrator map, backchannel) · `memory/` · `Traces/`
