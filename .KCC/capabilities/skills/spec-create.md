---
# Functional fields (consumed by harness adapters)
name: spec-create
description: >
 Create a new epic-level spec folder with a same-name folder note and JIRA-style story/enabler backlog under its per-idea `IDEA-{ID}-{slug}-Specs/` parent folder, from an idea handoff, detailed human prompt, source file, source folder, or SpecWriterStarter.md. Usage: /spec-create <problem description or file-or-folder path or SpecWriterStarter.md>
argument-placeholder: <ARGS>
delegates-to:
  - technical-interrogator
  - ux-ui-designer
  - security-analyst
  - infrastructure-planner
  - architect
  - spec-writer
maturity: L2
maintainer: tarek.fawaz1983@gmail.com
copyright: "KCC framework (c) 2026 Tarek Fawaz"
homepage: "https://tikasway.dev/kcc"
license: "Licensed under the terms in LICENSE"

# Obsidian metadata (used in the vault, ignored by harness adapters)
title: Spec Create Skill
tags:
  - framework/skill
  - lifecycle/create
created: 2026-05-24
updated: 2026-05-29
version: 3.5.0
status: active
---

# Spec Create

Create a new epic-level spec for: <ARGS>

## Steps

1. Read `specs/specs.md` to determine the next available SPEC-ID across all
   ideas. If `specs/specs.md` does not exist, initialize it as the Obsidian
   MOC described in [[.KCC/kernel/protocols/spec-layout]] (per-idea sections,
   cross-idea dependency table, statistics, link to the layout protocol).
2. Resolve the source:
   - Idea handoff: read the parent idea file (`idea-{ID}-{slug}.md`; legacy
     `idea.md` is accepted), `Conclusion.md`, `QuickRoadmap.md`, and
     `SpecWriterStarter.md`. Capture the parent `IDEA-{ID}` and idea slug so
     spec-writer can build the per-idea specs folder name.
   - Direct file: read the referenced file as the human's source material
     (for example a PRD, notes file, issue, analysis, or uploaded design).
     If the work clearly maps to an existing `IDEA-{ID}`, pass that idea
     identity in; otherwise allocate the next free `IDEA-{ID}` + slug for
     the spec-group folder only (do not retroactively create an idea folder).
   - Direct folder: inspect the folder index/readme and obvious human-authored
     markdown/text source files; avoid generated/build/vendor output.
   - Detailed prompt: treat `<ARGS>` itself as the source material.
   Direct file/folder/prompt usage is valid. Do not force `/idea-interrogator`
   when the human intentionally starts at `/spec-create`.
3. For idea handoffs, treat `QuickRoadmap.md` as the high-level epic map. If
   it identifies multiple likely specs, build a spec startup list first, ask
   the human which epics to create now, and create each selected spec as its
   own folder under the per-idea `IDEA-{ID}-{slug}-Specs/`. For direct
   sources, infer candidate epics from the supplied material and ask only if
   there is more than one plausible epic.
4. Invoke `/technical-interrogator` to collect technical decision inputs
   before spec writing. If an idea folder already contains
   `TechnicalDecisionBrief.md`, reuse it unless the human asks to refresh it.
   If the direct source already includes technical decisions, pass them to
   the technical interrogator for verification instead of re-asking
   everything.
5. Invoke specialist interrogators when the source indicates they matter:
   - `/ux-ui-interrogator` for web/mobile/game/dashboard/report/internal-tool
     work or any human-visible experience.
   - `/security-interrogator` for identity, authorization, public access,
     sensitive data, privacy, compliance, audit, secrets, or payment flows.
     When invoked, ensure the resulting brief flags whether the
     `testing-security` dialect should be scoped for any backlog item.
   - `/infrastructure-interrogator` for cloud/on-prem/Kubernetes,
     production deployment, paid services, SLOs, DR, observability, scaling,
     or operational ownership. When invoked, ensure the resulting brief
     flags whether the `testing-performance` dialect should be scoped for
     any backlog item.
   Reuse existing `UXDecisionBrief.md`, `SecurityDecisionBrief.md`, or
   `InfrastructureDecisionBrief.md` when present and still valid.
6. Delegate to the **architect** with all decision briefs so global ADRs,
   guardrails, quality gates, selected dialects (including `testing-unit`
   and `testing-integration` always, and `testing-performance` /
   `testing-security` when scoped), and required Mermaid diagrams are
   created or updated before spec writing.
7. Check existing per-idea specs groups under `specs/IDEA-*-Specs/` and
   their backlogs to avoid duplicate epics, stories, or enablers. If
   `solution/solution.md` exists, include the solution baseline in the
   spec-writer context.
8. Delegate to the **spec-writer** agent with the full source context,
   architect outputs, parent `IDEA-{ID}` + slug, and next SPEC-ID.
9. After each epic folder is created, confirm:
   - `specs/IDEA-{ID}-{slug}-Specs/` exists.
   - `specs/IDEA-{ID}-{slug}-Specs/IDEA-{ID}-{slug}-Specs.md` exists (the
     only file allowed to link back to `ideation/IDEA-{ID}-{slug}/...`).
   - `specs/IDEA-{ID}-{slug}-Specs/SPEC-{ID}-{slug}/SPEC-{ID}-{slug}.md`
     exists and links up only to the per-idea index.
   - `specs/IDEA-{ID}-{slug}-Specs/SPEC-{ID}-{slug}/backlog.md` exists.
   - `specs/IDEA-{ID}-{slug}-Specs/SPEC-{ID}-{slug}/Backlog/Story-*.md`
     and/or `.../Backlog/Enabler-*.md` exist (note capital `B` in
     `Backlog/`, capitalized first letter in `Story-` and `Enabler-`).
   - Each story / enabler file contains AC-N IDs, Success Factors, INVEST
     Check, Impacted Files using `src/IDEA-{ID}-{slug}/...`, Test Hints
     (unit + integration always, perf/security only if scoped), and
     Handoff Notes.
   - `parallelization.md` exists and lists dependency waves plus proposed
     sub-agent sessions with working directory `src/IDEA-{ID}-{slug}/`.
   - `plan.md`, `review.md`, `budget.md`, and `handovers.md` stubs exist.
   - `specs/specs.md` has the new spec linked through its per-idea section.
10. Stop after spec creation unless the caller is the `auto` skill and the
    next gate is ready. The next normal step is `/token-estimate SPEC-{ID}`
    before `/spec-plan`; do not plan or implement from `/spec-create`
    directly.
11. If any invoked agent reports confidence below the configured threshold
    (95% by default), invoke `/critical-human-gate` and pause the lifecycle.
12. Display the created epic summary: ID, title, priority, parent idea,
    per-idea spec group, source, story count, enabler count, acceptance
    criteria count, selected dialects (including which `testing-*`),
    complexity spread, proposed parallel waves, and whether additional
    roadmap epics remain uncreated.

## Constraints

- `/spec-create` is a valid create-level entrypoint for detailed human
  inputs.
- Do not require an `ideation/` folder when the human passes direct source
  material; allocate an `IDEA-{ID}` for the spec-group folder only.
- Honor the layout naming case exactly:
  `IDEA-{ID}-{slug}-Specs/` (capital S), `SPEC-{ID}-{slug}/` (all caps),
  `Backlog/` (capital B), `Story-...` and `Enabler-...` (capitalized first
  letter), zero-padded three-digit IDs.
- The per-idea index is the only file that links upstream to `ideation/`.
- Do not write implementation code, create branches, run `/spec-plan`, or
  run `/spec-implement`.
