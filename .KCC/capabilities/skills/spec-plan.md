---
# Functional fields (consumed by harness adapters)
name: spec-plan
description: >
 Create an implementation plan (including an atomic test-case enumeration) for an epic spec and its story/enabler backlog. Usage: /spec-plan SPEC-003
argument-placeholder: <ARGS>
delegates-to:
  - planner
maturity: L2
maintainer: tarek.fawaz1983@gmail.com
copyright: "KCC framework (c) 2026 Tarek Fawaz"
homepage: "https://tikasway.dev/kcc"
license: "Licensed under the terms in LICENSE"

# Obsidian metadata (used in the vault, ignored by harness adapters)
title: Spec Plan Skill
tags:
  - framework/skill
  - lifecycle/plan
created: 2026-05-24
updated: 2026-05-29
version: 3.5.0
status: active
---

# Spec Plan

Plan the implementation for spec <ARGS>.

## Steps

1. Locate `specs/IDEA-{ID}-{slug}-Specs/SPEC-{ID}-{slug}/` from the
   supplied SPEC-ID by scanning the per-idea spec groups under `specs/`. If
   no matching folder exists, list available specs from `specs/specs.md`
   and stop. If the spec is at any v4-or-older path (e.g.
   `specs/SPEC-{ID}-{slug}/`), tell the user to migrate via spec-writer and
   stop.
2. Verify the following exist inside the spec folder:
   - `SPEC-{ID}-{slug}.md` (same-name folder note);
   - `backlog.md`;
   - `Backlog/` subfolder with `Story-*.md` and/or `Enabler-*.md` files
     (note capital B in `Backlog/`, capitalized first letter in
     `Story-` / `Enabler-`);
   - `parallelization.md`;
   - the per-idea index `../IDEA-{ID}-{slug}-Specs.md`.
   If any are missing, stop and ask to regenerate the spec using the
   current spec-layout protocol.
3. Read every `Backlog/Story-*.md` and `Backlog/Enabler-*.md`. Confirm each
   item has acceptance criteria with `AC-N` IDs, Success Factors, Test
   Hints, Impacted Files using `src/IDEA-{ID}-{slug}/...`, dependencies,
   selected dialect, complexity, parallel eligibility, and a passing
   INVEST check. Missing fields must be repaired by spec-writer before
   planning.
4. Verify `/token-estimate SPEC-{ID}` has one of these approvals recorded
   in the current session trace or in `budget.md` for the plan stage:
   - explicit human approval; or
   - AutoPolicy `auto-approved` with cumulative hosted-model spend still
     inside the approved budget cap.
   If no valid approval exists, stop and ask the human to run
   `/token-estimate SPEC-{ID}`.
5. If `plan.md` already contains a ready plan (status `ready`, version
   >= 1.0.0, and an `## Atomic test cases` table), ask whether to
   regenerate or keep the existing plan.
6. Delegate to the **planner** agent with the spec ID and backlog scope.
   The planner must:
   - load the selected dialect files from
     `.KCC/kernel/protocols/dialects/`, always including `testing-unit` and
     `testing-integration`, and adding `testing-performance` /
     `testing-security` if any backlog item scopes them;
   - refine `parallelization.md` so sub-agent sessions reference working
     directory `src/IDEA-{ID}-{slug}/`;
   - emit a mandatory `## Atomic test cases` table mapping every AC on every
     story and enabler to one or more Test IDs (`T-001`, ...) at level
     unit / integration / performance / security;
   - avoid unnecessary dependencies between stories/enablers.
7. Display a summary of the plan: backlog items covered, selected dialects
   (including which `testing-*`), ordered changes, proposed parallel
   waves / sub-agent sessions, total atomic test-case count grouped by
   level, risk flags, and verification steps.
