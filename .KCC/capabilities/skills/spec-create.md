---
# Functional fields (consumed by harness adapters)
name: spec-create
description: >
 Create one or more lean v6 specs (smallest user-valuable delivery each: one `SPEC-{ID}-{slug}.md` + `Backlog/` items, sized SZ-1..5) plus the per-idea `ROADMAP.md` under `IDEA-{ID}-{slug}-Specs/`, from an idea handoff, detailed human prompt, source file, source folder, or SpecWriterStarter.md. Usage: /spec-create <problem description or file-or-folder path or SpecWriterStarter.md>
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
updated: 2026-09-21
version: 4.0.0
status: active
---

# Spec Create

Create v6 spec(s) for: <ARGS>

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
3. For idea handoffs, treat `QuickRoadmap.md` as the high-level map. The
   spec-writer slices it into the smallest user-valuable deliveries (one spec
   each, SZ-1..5) and orders them in `ROADMAP.md`; ask the human which to
   create now only when the slicing is ambiguous.
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
   their backlogs to avoid duplicate specs or items. If
   `solution/solution.md` exists, include the solution baseline in the
   spec-writer context.
8. Delegate to the **spec-writer** agent with the full source context,
   architect outputs, parent `IDEA-{ID}` + slug, and next SPEC-ID.
9. Confirm with `.KCC/tools/check-run-conformance -Scope specs` (exit 0);
   route each violation to its `fix_owner`. It checks: per-idea index (only
   upstream link), `ROADMAP.md` (Execution Plan + Token Plan), each
   `SPEC-{ID}-{slug}.md` (Delivery Brief, ACs, Backlog table with Wave
   column, Architecture), `Backlog/Story-*|Enabler-*.md` (AC-N, INVEST,
   Impacted Files, Test Hints), `arch.md` skeleton, SZ-1..5, and **no**
   stubs or retired files (`plan.md`/`review.md` come later from their
   owners; `backlog.md`, `parallelization.md`, `budget.md`, `handovers.md`
   are v5-only).
10. Stop after spec creation unless the caller is the `auto` skill and the
    next gate is ready. The next normal step is `/token-estimate SPEC-{ID}`
    before `/spec-plan`; do not plan or implement from `/spec-create`
    directly.
11. If any invoked agent reports confidence below the configured threshold
    (95% by default), invoke `/critical-human-gate` and pause the lifecycle.
12. Display per spec: ID, delivery, priority, parent idea, item counts, AC
    count, dialects (incl. `testing-*`), waves, and the ROADMAP order/lanes.

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
