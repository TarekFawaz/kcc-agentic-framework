---
# Functional fields (consumed by harness adapters)
name: spec-review
description: >
 Quick diff review of epic spec changes against epic criteria, story/enabler backlog items (under `Backlog/`), and the planner's atomic test-case table - without writing the full verifier report. Usage: /spec-review SPEC-003
argument-placeholder: <ARGS>
delegates-to:
  - verifier
maturity: L2
maintainer: tarek.fawaz1983@gmail.com
copyright: "KCC framework (c) 2026 Tarek Fawaz"
homepage: "https://tikasway.dev/kcc"
license: "Licensed under the terms in LICENSE"

# Obsidian metadata (used in the vault, ignored by harness adapters)
title: Spec Review Skill
tags:
  - framework/skill
  - lifecycle/review
created: 2026-05-24
updated: 2026-05-29
version: 3.3.0
status: active
---

# Spec Review

Quick review of <ARGS> implementation.

## Steps

1. Locate the spec folder under
   `specs/IDEA-{ID}-{slug}-Specs/SPEC-{ID}-{slug}/` and read the same-name
   folder note, `backlog.md`, `Backlog/Story-*.md`, `Backlog/Enabler-*.md`,
   `parallelization.md`, `plan.md` (including its `## Atomic test cases`
   table), and the per-idea index `../IDEA-{ID}-{slug}-Specs.md`.
2. Run `git diff main..HEAD -- <impacted files from spec>` when git is
   available, scoped to `src/IDEA-{ID}-{slug}/...` plus any cross-cutting
   files declared in the spec.
3. Load the selected dialect files from
   `.KCC/kernel/protocols/dialects/` (including `testing-unit`,
   `testing-integration`, and `testing-performance` / `testing-security` if
   the plan loaded them) and apply their review/bug-fix checklists to the
   changed files.
4. For each epic acceptance criterion (`AC-N`), state whether the diff
   addresses it: YES / PARTIAL / NO.
5. For each `Backlog/Story-*.md` and `Backlog/Enabler-*.md`, state whether
   each of its `AC-N`s appears satisfied: YES / PARTIAL / NO.
6. Spot-check the atomic test-case table: for a sample of Test IDs, confirm
   a matching test exists (search by Test ID in test names / annotations
   under `src/IDEA-{ID}-{slug}/`).
7. List any changed files not declared in the spec's impacted files or
   outside `src/IDEA-{ID}-{slug}/`.
8. Verify architecture `.mmd` diagrams and greenfield
   `src/IDEA-{ID}-{slug}/`, `docs/`, and per-idea `README.md` requirements
   when applicable.
9. Output a brief summary directly; do not create a file unless the user
   asks for the full `/spec-test` verifier report (which writes
   `review.md`).
