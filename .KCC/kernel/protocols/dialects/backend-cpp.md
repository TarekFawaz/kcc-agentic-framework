---
title: Backend C++ Dialect
tags: [kcc/kernel, dialects, backend, cpp]
created: 2026-05-25
updated: 2026-05-25
version: 0.4.0
status: active
copyright: "KCC framework (c) 2026 Tarek Fawaz"
homepage: "https://tikasway.dev/kcc"
license: "Licensed under the terms in LICENSE"
---

# Backend C++ Dialect

Use for C++ backend services, libraries, tools, and performance-sensitive systems.

## Coding
- Prefer RAII, clear ownership, modern C++ idioms, and minimal global state.
- Keep headers and implementation organized under `src/`/`include/` when greenfield.

## Review
- Check memory ownership, lifetime, concurrency, exceptions/error codes, ABI/API compatibility, and build portability.

## Bug Fix
- Reproduce with a failing test or minimal binary, patch narrowly, run tests and sanitizers when available.

## Testing
- Use the existing C++ test framework; add boundary and regression tests.

## Docs
- README must include compiler/toolchain, build/test commands, and runtime configuration.

## Complexity
- low: junior-safe pure function or small module.
- medium: mid-level library/service change.
- high: senior concurrency/performance/API boundary.
- extra-high: principal-expert memory-critical, safety-critical, or legacy modernization.
