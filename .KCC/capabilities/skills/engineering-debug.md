---
# Functional fields (consumed by harness adapters)
name: engineering-debug
description: >
 Apply the bounded systematic-debugging discipline to the current task: reproduce the failure, gather evidence, hold one hypothesis, run the smallest experiment, fix the root cause and keep a regression test. Usage: /engineering-debug
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
adapted-from: skills/systematic-debugging/SKILL.md

# Obsidian metadata (used in the vault, ignored by harness adapters)
title: Engineering Debug Skill
aliases:
  - engineering-debug-skill
tags:
  - framework/skill
  - superpowers/engineering
created: 2026-08-28
updated: 2026-08-28
version: 1.0.0
status: active
---

# Engineering Debug

Systematic debugging for the current task: find the root cause of a bug,
test failure or unexpected behavior before proposing any fix. Symptom
fixes are failure.

## The Iron Law

```
NO FIXES WITHOUT ROOT CAUSE INVESTIGATION FIRST
```

Without completing the investigation cycle below, no fix may be proposed.

## The cycle (exact sequence)

1. **Reproduce.** Reproduce the failure consistently and write down the
   exact steps, including the failing command. If it cannot be
   reproduced, collect more information before changing anything.
2. **Evidence.** Read the full error messages and stack traces, check the
   recent changes, and add diagnostic instrumentation at component
   boundaries until the evidence shows where the failure starts. Never
   guess at a cause.
3. **One hypothesis.** State a single hypothesis in one sentence: "I
   think X is the root cause because Y." One at a time — do not hold
   multiple concurrent hypotheses.
4. **Smallest experiment.** Make the smallest possible change that tests
   the hypothesis; change one variable at a time. If it does not confirm
   the hypothesis, form a new one instead of stacking more fixes.
5. **Root-cause fix.** Fix the cause, not the symptom: first write a
   failing reproduction test for the confirmed cause, then implement one
   single fix that addresses it.
6. **Regression test.** Verify the reproduction test now passes, run the
   related tests, and keep the regression test in place for the future.

## Stop rules

- If three fix attempts have failed to confirm a cause, stop and escalate
  instead of attempting a fourth fix.
- Each new fix attempt that reveals a different failure point is a signal
  to go back and re-investigate, not to keep patching.
- A failure that genuinely has no reproducible cause is reported with
  exactly what was tried and what remains unknown.

## Attribution and boundary

Adapted from obra/superpowers
(https://github.com/obra/superpowers, MIT License) at pinned commit
`b36e0829c6d0140e93cfef2ca599b1b07d4a7797`; see
`THIRD_PARTY_NOTICES.md`. This skill is a bounded, task-local engineering
discipline: it governs the current task only and does not change task
scope.
