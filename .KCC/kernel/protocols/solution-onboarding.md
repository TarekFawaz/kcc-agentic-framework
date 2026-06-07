---
# Functional fields
description: Read-only onboarding convention for building a baseline understanding of an existing solution or codebase.
inputs: A source path and desired onboarding depth.
outputs: A `solution/` folder with a solution MOC, codebase map, architecture snapshot, tech stack, interfaces, operations notes, diagrams, risks, and open questions.

# Obsidian metadata
title: "Solution Onboarding Protocol"
aliases:
  - solution-onboarding
  - codebase-onboarding
  - existing-solution-baseline
tags:
  - framework/protocol
  - solution
  - documentation
created: 2026-05-25
updated: 2026-05-29
version: 1.1.0
status: active
copyright: "KCC framework (c) 2026 Tarek Fawaz"
homepage: "https://tikasway.dev/kcc"
license: "Licensed under the terms in LICENSE"
---

# Solution Onboarding

Use solution onboarding when the framework is introduced to an existing
solution, repo, or codebase. It builds a read-only baseline so future ideas,
specs, architecture decisions, and plans start from the real system instead of
from guesses.

## Command

```text
/solution-onboard <path-or-current-repo> [--depth=minimal|standard|deep]
```

Default depth is `standard`. Ask the human before using `deep`.

| Depth | Use for | Expected work |
|--|--|--|
| `minimal` | Small app, CLI, docs, or quick orientation. | Structure, tech stack, entrypoints, test commands, obvious risks. |
| `standard` | Normal product/service repo. | Minimal plus dependencies, modules/domains, interfaces, data stores, operations, diagrams. |
| `deep` | Large, legacy, regulated, or multi-service system. | Standard plus bounded contexts, deployment topology, SLO/DR prompts, security-sensitive areas, and prioritized open questions. |

## Output Folder

```text
solution/
|-- solution.md
|-- CodebaseMap.md
|-- TechStack.md
|-- ArchitectureSnapshot.md   <- context + container views embedded as inline fenced ```mermaid``` blocks
|-- DataAndInterfaces.md
|-- RuntimeAndOperations.md
`-- RisksAndOpenQuestions.md
```

Diagrams are **embedded inline** in `ArchitectureSnapshot.md` (one fenced
```mermaid``` block per view, with a caption), per the embed rule in
[[architecture-documentation]]. There is **no** `solution/diagrams/` folder and
**no** loose `.mmd` files - the same convention `architecture/` uses.

## Required Behavior

- Work read-only against the target codebase.
- Do not read secrets or private credentials. Skip `.env`, key files, tokens,
  generated output, build artifacts, vendored dependencies, and large binaries.
- Prefer repository evidence over assumptions. Mark unknowns explicitly.
- Embed Mermaid context/container views as inline fenced ```mermaid``` blocks
  inside `ArchitectureSnapshot.md` when architecture can be inferred (no `.mmd`
  files, no `diagrams/` folder).
- Link the baseline from future ideas/specs when those changes target the
  existing solution.

## Inspector phase

After [[solution-cartographer]] produces `solution/solution.md`, the
[[solution-inspector]] agent runs to interrogate **workspace topology and
intent**. Cartographer maps what's there; inspector captures what's
declared.

Inspector behavior:

- Reads the cartographer's `solution/solution.md` as input (or notes its
  absence and proceeds on interrogation alone).
- Asks the workspace interrogation questions W1-W6 defined in
  [[.KCC/capabilities/agents/solution-inspector]] (topology, repositories,
  cross-repo dependencies, tracker integration, model-class overrides,
  AutoPolicy defaults).
- Populates the `workspace`, `tracker`, and (optionally) `defaults`
  sections of `.KCC/settings.json` per the schema in [[workspace]].
- Writes `solution/SolutionInspectionBrief.md` with the human's answers,
  detected topology, and any conflicts between detected and declared.
- Emits a `coordination-note` event to `coordination/backchannel.jsonl`
  summarizing the workspace.

The inspector phase is **required** in `/solution-onboard` unless the
`--skip-inspector` flag is passed. Skipping is appropriate for read-only
discovery passes that have no intention of producing specs against the
solution.

Under `auto --silent --assume`, the inspector documents low-risk
assumptions instead of asking, but always asks the **tracker choice** (W4)
and never assumes production-impacting workspace structure changes
(W1-W3 are always confirmed with the human).

## Relationship To Architecture

The solution baseline describes what exists now. Architecture design describes
what should exist next. ADRs, guardrails, and quality gates still belong under
`architecture/`.

## Related

- Architecture governance: [[architecture-governance]]
- Idea layout: [[idea-layout]]
- Spec layout: [[spec-layout]]
- Workspace protocol: [[workspace]]
- Solution cartographer: [[.KCC/capabilities/agents/solution-cartographer]]
- Solution inspector: [[.KCC/capabilities/agents/solution-inspector]]
