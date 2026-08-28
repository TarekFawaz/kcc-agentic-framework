---
# Functional fields (consumed by harness adapters)
name: engineering-verify
description: >
 Verify the current task before claiming completion: identify the exact verification command, run it fresh, and record the evidence reference next to the claim. Usage: /engineering-verify
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
adapted-from: skills/verification-before-completion/SKILL.md

# Obsidian metadata (used in the vault, ignored by harness adapters)
title: Engineering Verify Skill
aliases:
  - engineering-verify-skill
tags:
  - framework/skill
  - superpowers/engineering
created: 2026-08-28
updated: 2026-08-28
version: 1.0.0
status: active
---

# Engineering Verify

Verification before completion claims for the current task. Evidence
before assertions, always.

## The Iron Law

```
NO COMPLETION CLAIM WITHOUT FRESH VERIFICATION EVIDENCE
```

If the verification command was not run in this session, the claim is not
made.

## The gate (exact sequence)

1. Identify the exact verification command that would prove the claim.
2. Run it fresh and complete, from the current state of the task.
3. Read the full output, the exit code and the failure count.
4. Confirm the output actually supports the claim. If it does not, state
   the actual status with the evidence instead.
5. Record the evidence reference — the exact command and its output —
   next to the claim.

## Claims that always need the gate

- "Tests pass": the exact test command output with zero failures.
- "Bug fixed": the original reproduction test now passes, and the
  regression proof was watched to fail first.
- "Requirements met": the task's acceptance criteria are checked line by
  line against the actual change.
- "Agent reported success": never trusted; verify the change and rerun
  the commands yourself.

## Red flags

- Words like "should", "probably" or "seems to" in a status claim mean
  the verification command has not been run.
- No claim of success, satisfaction or completion is made without the
  recorded evidence reference.

## Attribution and boundary

Adapted from obra/superpowers
(https://github.com/obra/superpowers, MIT License) at pinned commit
`b36e0829c6d0140e93cfef2ca599b1b07d4a7797`; see
`THIRD_PARTY_NOTICES.md`. This skill is a bounded, task-local engineering
discipline: it governs the current task only and does not change task
scope.
