---
# Functional fields (consumed by harness adapters)
name: engineering-tdd
description: >
 Apply the bounded test-driven engineering discipline to the current task: write the smallest meaningful failing test first, watch it fail, write the minimum implementation, watch it pass, then refactor while staying green. Usage: /engineering-tdd
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
adapted-from: skills/test-driven-development/SKILL.md

# Obsidian metadata (used in the vault, ignored by harness adapters)
title: Engineering TDD Skill
aliases:
  - engineering-tdd-skill
tags:
  - framework/skill
  - superpowers/engineering
created: 2026-08-28
updated: 2026-08-28
version: 1.0.0
status: active
---

# Engineering TDD

Test-driven engineering for the current task: write the test first, watch
it fail, write the minimum code to pass, watch it pass, then clean up
while staying green.

## The Iron Law

```
NO PRODUCTION CODE WITHOUT A FAILING TEST FIRST
```

Code written before its test is discarded and rewritten from the test.
There are no reference copies and no "adapt it while writing the test"
exceptions.

## The cycle (exact sequence)

1. **RED — smallest meaningful failing test.** Write the smallest
   meaningful failing test showing the required behavior: one behavior,
   a clear name, and real code under test rather than mocks.
2. **Verify RED.** Run the exact test command. Confirm the test fails
   (not errors), the failure message is the expected one, and the test
   fails because the feature is missing rather than because of a typo.
   **Mandatory — never skip.**
3. **GREEN — minimum implementation.** Write the simplest code that makes
   the test pass. Add no features and clean up nothing beyond the test.
4. **Verify GREEN.** Run the exact test command plus the related tests.
   Confirm the test passes, the other tests still pass, and the output is
   pristine (no errors or warnings).
5. **REFACTOR.** Only after green: remove duplication, improve names,
   extract helpers. Keep every test green and add no behavior.

## When this applies

The discipline applies to every behavioral change in the current task:
new features, bug fixes, refactors and behavior changes. Non-code changes
(e.g. documentation that alone proves the claim) state why no test change
is required.

## Checks before the task is reported done

- Every new behavior has a test that was watched to fail first.
- Each test failed for the expected reason (feature missing, not typo).
- The minimum implementation was written to pass each test.
- The target and related tests all pass with pristine output.

## Attribution and boundary

Adapted from obra/superpowers
(https://github.com/obra/superpowers, MIT License) at pinned commit
`b36e0829c6d0140e93cfef2ca599b1b07d4a7797`; see
`THIRD_PARTY_NOTICES.md`. This skill is a bounded, task-local engineering
discipline: it governs the current task only and does not change task
scope.
