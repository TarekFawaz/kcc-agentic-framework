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
updated: 2026-05-25
version: 3.1.0
status: active
---

# Spec Status

Show the status dashboard for all specs.

## Steps

1. Read `specs/specs.md` for the epic list and statuses.
2. For each `specs/SPEC-{ID}-{slug}/` folder, check:
   - same-name folder note exists.
   - `backlog.md` exists and count stories/enablers.
   - `plan.md` status is awaiting or ready.
   - Branch exists: `git branch --list 'spec/SPEC-{ID}'` when git is available.
   - `review.md` exists and has verdict if verification has run.
3. Display a table:

| Spec | Priority | Status | Stories | Enablers | Plan | Branch | Review | Verdict |
|--|--|--|--|--|--|--|--|--|

4. Below the table, highlight:
   - Specs with unmet dependencies.
   - Specs missing `backlog.md` or INVEST checks.
   - Specs in progress with no ready plan.
   - Next recommended specs to work on.
