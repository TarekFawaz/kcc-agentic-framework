---
title: Testing Performance Dialect
tags: [kcc/kernel, dialects, testing, performance]
created: 2026-05-29
updated: 2026-05-29
version: 0.1.0
status: active
copyright: "KCC framework (c) 2026 Tarek Fawaz"
homepage: "https://tikasway.dev/kcc"
license: "Licensed under the terms in LICENSE"
---

# Testing Performance Dialect

Use only when performance is explicitly scoped during interrogation (latency
SLO, throughput target, memory budget, cold-start ceiling, etc.). Optional by
default. When selected, the planner enumerates atomic performance test cases
inside `plan.md` and the implementer translates each into real test code
under the per-idea workspace.

## Coding
- Place performance tests under `tests/performance/` inside
  `src/IDEA-{ID}-{slug}/`.
- Pin the load profile: concurrency, ramp, duration, payload shape.
- Record results to a stable artifact (JSON/CSV) so verifier can diff.
- Test IDs from `plan.md` (`T-NNN`) must appear in the scenario name.

## Review
- Each performance AC has an explicit numeric target (p50/p95/p99, RPS,
  memory MB, cold-start ms) and a passing run that meets it.
- No "looks fast" verdicts - always cite the recorded number.

## Bug Fix
- Reproduce with a load profile that triggers the regression, fix, then
  re-run the same profile to confirm the number is back inside the target.

## Testing
- Run on a controlled environment (local container, dedicated runner). Note
  the environment in the result artifact; verifier compares within-env only.

## Docs
- README must document how to run the perf suite, environment requirements,
  and where result artifacts are stored.

## Complexity
- low: microbenchmark of a single function.
- medium: single-endpoint load test with steady RPS.
- high: multi-endpoint workload with realistic mix.
- extra-high: full-system load with SLO budgets and burn-rate alerts.
