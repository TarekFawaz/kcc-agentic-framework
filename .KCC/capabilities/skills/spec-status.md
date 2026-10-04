---
# Functional fields (consumed by harness adapters)
name: spec-status
description: >
 Show status dashboard of all epic specs, their plans, backlog items, branches, reviews, and verdicts.
argument-placeholder: <ARGS>
delegates-to: []
maturity: L2
maintainer: tarek.fawaz1983@gmail.com
copyright: "KCC framework (c) 2026 Tarek Fawaz"
homepage: "https://tikasway.dev/kcc"
license: "Licensed under the terms in LICENSE"

# Obsidian metadata (used in the vault, ignored by harness adapters)
title: Spec Status Skill
tags:
  - framework/skill
created: 2026-05-24
updated: 2026-09-21
version: 4.0.0
status: active
---

# Spec Status

Show the status dashboard for all specs.

## Steps

1. Read `specs/specs.md` and each `IDEA-*-Specs/ROADMAP.md` (order, lanes).
2. For each `specs/IDEA-*-Specs/SPEC-{ID}-{slug}/` folder, check:
   - `SPEC-{ID}-{slug}.md` `## Backlog` table: count stories/enablers/bugs
     (legacy v5: `backlog.md`).
   - `plan.md` exists (absent = not planned; no stubs in v6).
   - Branch exists: `git branch --list 'spec/SPEC-{ID}'` when git is available.
   - `review.md` exists and has verdict if verification has run.
3. Display a table:

| Spec | Priority | Status | Stories | Enablers | Open bugs | Plan | Branch | Review | Verdict |
|--|--|--|--|--|--|--|--|--|--|

4. Below the table, highlight:
   - Specs with unmet dependencies.
   - Specs missing a Backlog table or INVEST checks; open blocker/major bugs.
   - Specs in progress with no ready plan.
   - Next recommended specs to work on.
