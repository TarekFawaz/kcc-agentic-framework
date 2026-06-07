---
title: Testing Integration Dialect
tags: [kcc/kernel, dialects, testing, integration]
created: 2026-05-29
updated: 2026-05-29
version: 0.1.0
status: active
copyright: "KCC framework (c) 2026 Tarek Fawaz"
homepage: "https://tikasway.dev/kcc"
license: "Licensed under the terms in LICENSE"
---

# Testing Integration Dialect

Use for tests that exercise two or more real components together - module
plus database, API plus handler plus persistence, CLI plus filesystem, UI
plus mocked backend, etc. This dialect is **mandatory** for any Story or
Enabler that crosses a process, persistence, or transport boundary; the
planner enumerates atomic integration test cases inside `plan.md` and the
implementer translates each into real test code under the per-idea workspace.

## Coding
- Place integration tests under `tests/integration/` (or the host
  language's equivalent) inside `src/IDEA-{ID}-{slug}/`.
- Spin up real dependencies via ephemeral resources: in-memory DB,
  testcontainers, temp directories, local servers on ephemeral ports.
- One scenario per test. Setup and teardown must leave no residual state.
- Test IDs from `plan.md` (`T-NNN`) must appear in the test name or
  annotation so verifier can trace them back to acceptance criteria.

## Review
- Each AC marked `integration` in `plan.md` has at least one passing test.
- No reliance on shared external environments (no shared staging DB, no
  production endpoints, no flaky public services).
- Tests are deterministic: fixed clocks, seeded random, controlled ordering.

## Bug Fix
- Reproduce with an integration test when the bug crosses a boundary; if it
  is purely internal, fall back to a unit test.

## Testing
- Target a few seconds per test, sub-5-minute integration suite per Story.
- Mark slow tests so CI can shard them; keep the hot path under a minute.

## Docs
- README must document how to run the integration suite, what external
  tooling (Docker, runtime engines) is required, and how to reset state.

## Complexity
- low: single-boundary smoke test.
- medium: full request/response cycle through real persistence.
- high: multi-service workflow or distributed transaction test.
- extra-high: contract / consumer-driven / chaos-style integration suites.
