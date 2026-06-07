---
title: Testing Unit Dialect
tags: [kcc/kernel, dialects, testing, unit]
created: 2026-05-29
updated: 2026-05-29
version: 0.1.0
status: active
copyright: "KCC framework (c) 2026 Tarek Fawaz"
homepage: "https://tikasway.dev/kcc"
license: "Licensed under the terms in LICENSE"
---

# Testing Unit Dialect

Use for fast, isolated tests that exercise a single function, class, module,
or component in memory with no external I/O. This dialect is **mandatory** for
every Story and Enabler that produces executable code; the planner enumerates
atomic unit test cases inside `plan.md` and the implementer translates each
into real test code under the per-idea workspace.

## Coding
- Place unit tests next to the code or under the language's standard test
  path (e.g. `tests/unit/`, `__tests__/`, `*_test.go`, `*.spec.ts`) inside
  `src/IDEA-{ID}-{slug}/`.
- One assertion concern per test. Use AAA (Arrange / Act / Assert) layout.
- Stub or fake external dependencies - no network, no filesystem (use temp
  dirs only when unavoidable), no real database, no real time.
- Test IDs from `plan.md` (`T-001`, `T-002`, ...) must appear in the test name
  or a tag/annotation so verifier can trace them back to acceptance criteria.

## Review
- Each AC referenced in `plan.md` has at least one passing unit test.
- No flaky timing, no shared mutable state across tests, no swallowed errors.
- Tests fail for the right reason (mutation-test mentally: would changing the
  production behavior actually break this test?).

## Bug Fix
- Write a failing unit test that reproduces the bug first, then patch.

## Testing
- Target sub-second per test, sub-30s for the unit suite of a single Story.
- Coverage is a signal, not a goal; prefer behavior coverage of every AC.

## Docs
- Story/Enabler `Test Hints` and `plan.md` Atomic test cases together fully
  describe the expected unit suite. README run instructions must show how to
  execute unit tests alone.

## Complexity
- low: pure functions, simple branches.
- medium: stateful component with mocked collaborators.
- high: complex state machines, concurrency, or algorithmic correctness.
- extra-high: property-based, fuzz, or invariant-driven unit suites.
