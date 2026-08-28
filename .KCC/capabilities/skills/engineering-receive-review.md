---
# Functional fields (consumed by harness adapters)
name: engineering-receive-review
description: >
 Receive code review feedback for the current task with technical rigor: verify each finding against the codebase before applying it and record the rejected finding with its evidence. Usage: /engineering-receive-review
argument-placeholder: <ARGS>
delegates-to: []
maturity: L1
maintainer: tarek.fawaz1983@gmail.com
copyright: "KCC framework (c) 2026 Tarek Fawaz"
homepage: "https://tikasway.dev/kcc"
license: "Licensed under the terms in LICENSE"
lifecycle-owner: false
upstream: obra/superpowers
upstream-url: https://github.com/obra/superpowers
upstream-commit: b36e0829c6d0140e93cfef2ca599b1b07d4a7797
upstream-license: MIT
adapted-from: skills/receiving-code-review/SKILL.md

# Obsidian metadata (used in the vault, ignored by harness adapters)
title: Engineering Receive Review Skill
aliases:
  - engineering-receive-review-skill
tags:
  - framework/skill
  - superpowers/engineering
created: 2026-08-28
updated: 2026-08-28
version: 1.0.0
status: active
---

# Engineering Receive Review

Receive code review feedback on the current task with technical rigor:
performance is never a substitute for verification, and agreement is
never a substitute for correctness.

## The response pattern

1. Read the complete feedback without reacting to it.
2. Restate each requirement in your own words, or ask for clarification.
3. **Verify each finding** against the codebase reality: run the exact
   command that proves or disproves it **before applying it**.
4. Evaluate whether the finding is technically sound for the current
   task, then respond with the technical reason — acknowledgement or
   reasoned pushback.
5. Apply accepted findings one at a time and test each change.
6. **Record the rejected finding with its evidence**: which part was
   checked, what the check showed, and why the finding does not apply, so
   the rejection stays reviewable.

## Handling unclear feedback

If any item is unclear, do not implement the clear items and leave the
unclear ones: ask for clarification on the unclear items first, because
partial understanding produces the wrong change.

## Applying accepted findings

- Fix blocking issues first, then simple fixes, then complex fixes.
- Test each fix individually and confirm no regressions before the next.
- After all accepted findings are applied, run the verify step with the
  exact commands and their recorded output.

## Attribution and boundary

Adapted from obra/superpowers
(https://github.com/obra/superpowers, MIT License) at pinned commit
`b36e0829c6d0140e93cfef2ca599b1b07d4a7797`; see
`THIRD_PARTY_NOTICES.md`. This skill is a bounded, task-local engineering
discipline: it governs the current task only and does not change task
scope.
