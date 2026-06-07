---
# Functional fields (consumed by harness adapters)
name: solution-onboard
description: >
  Build a read-only baseline understanding of an existing solution or codebase before using the framework for ideas/specs. Usage: /solution-onboard <path-or-current-repo> [--depth=minimal|standard|deep] [--skip-inspector]
argument-placeholder: <ARGS>
delegates-to:
  - solution-cartographer
  - solution-inspector
maturity: L1
maintainer: tarek.fawaz1983@gmail.com
copyright: "KCC framework (c) 2026 Tarek Fawaz"
homepage: "https://tikasway.dev/kcc"
license: "Licensed under the terms in LICENSE"

# Obsidian metadata
title: Solution Onboard Skill
aliases:
  - solution-onboard-skill
tags:
  - framework/skill
  - solution
  - workspace
created: 2026-05-25
updated: 2026-06-06
version: 1.3.0
status: active
---

# Solution Onboard

Build a solution baseline for: <ARGS>

This skill chains two agents - **solution-cartographer** (maps the codebase
into `solution/`) and **solution-inspector** (interrogates workspace topology
and populates `.KCC/settings.json`). See [[workspace]] for the workspace-layer
protocol and [[solution-onboarding]] for the artifact contract.

## Steps

1. Resolve `<ARGS>` to a source path. If no path is provided, use the current
   repo root. Parse optional flags:
   - `--depth=minimal|standard|deep` (default `standard`; ask before `deep`).
   - `--skip-inspector` to bypass step 3 entirely (rare - only for trivial
     single-repo solutions where the human explicitly declines the workspace
     interrogation).
2. **Create `solution/` if missing.** This folder is created lazily by this
   skill on invocation - it never pre-exists from init. Then **delegate to the
   solution-cartographer agent** and confirm the output folder contents:
   - `solution/solution.md`
   - `solution/CodebaseMap.md`
   - `solution/TechStack.md`
   - `solution/ArchitectureSnapshot.md` (context + container diagrams embedded as inline fenced ```mermaid``` blocks)
   - `solution/DataAndInterfaces.md`
   - `solution/RuntimeAndOperations.md`
   - `solution/RisksAndOpenQuestions.md`

   Diagrams are **embedded inline** in `ArchitectureSnapshot.md` per the
   [[architecture-documentation]] embed rule - no loose `.mmd` files and no
   `solution/diagrams/` folder.
3. **Delegate to the solution-inspector agent** unless `--skip-inspector`
   was passed or `--depth=minimal` is in effect. The inspector reads
   `solution/solution.md` as input, interrogates the human about workspace
   topology (single vs multi-repo, cross-repo dependencies, tracker choice,
   defaults), populates `.KCC/settings.json` per [[workspace]], and writes
   `solution/SolutionInspectionBrief.md` summarizing the decisions. Multi-idea
   handling stays on the `src/IDEA-{ID}-{slug}/` folder convention defined
   in [[spec-layout]] - the inspector does not invent a new mechanism.
4. If confidence on either agent is below the configured threshold
   (95% by default), invoke `/critical-human-gate`.
5. Print a summary: cartographer artifacts written, inspector decisions
   recorded, `.KCC/settings.json` state (created / updated / unchanged),
   and recommended next step.
6. Tell the human to link this baseline from future ideas/specs that target
   the existing solution.

## Depth flag semantics

| Depth      | Cartographer | Inspector | Notes                                                                 |
|--|--|--|--|
| `minimal`  | Yes          | No        | Cartographer only. Skip workspace interrogation; suitable for tiny tools. |
| `standard` | Yes          | Yes       | Default. Both agents run; inspector asks the topology questions.      |
| `deep`     | Yes          | Yes       | Both agents plus additional probing (inspector decides what "deeper" means - typically cross-repo dependency tracing, deeper tracker-integration discovery, secondary boundary analysis). Ask the human before using `deep`. |

`--skip-inspector` is a hard override that bypasses step 3 regardless of the
chosen depth.

## AutoPolicy behavior

Under `--silent --assume` mode, the inspector:

- Documents low-risk topology assumptions (e.g. "single-repo because no
  sibling repos were detected") instead of asking.
- **Always asks the tracker choice** (Jira / Azure DevOps / Asana / Linear /
  GitHub Issues / none) - tracker integration is never silently assumed
  because it touches external credentials and team workflow.
- Honors the AutoPolicy budget cap for any probing work it does in `deep`
  mode.

## Constraints

- Read-only on application code. Cartographer never writes outside
  `solution/`; inspector writes only to `.KCC/settings.json` and
  `solution/SolutionInspectionBrief.md`.
- Do not create or change specs.
- Do not modify application source code.
- Multi-repo / multi-cell composition lives in `.KCC/settings.json` per
  [[workspace]], not in this skill's logic.
