---
title: Embedded Rust Dialect
tags: [kcc/kernel, dialects, embedded, rust]
created: 2026-05-25
updated: 2026-05-25
version: 0.4.0
status: active
copyright: "KCC framework (c) 2026 Tarek Fawaz"
homepage: "https://tikasway.dev/kcc"
license: "Licensed under the terms in LICENSE"
---

# Embedded Rust Dialect

Use for embedded Rust firmware and constrained systems.

## Coding
- Keep ownership, lifetimes, unsafe blocks, HAL assumptions, and no_std constraints explicit.
- Minimize unsafe and document every unsafe block.

## Review
- Check unsafe, interrupt/concurrency safety, allocation, panic behavior, feature flags, and hardware assumptions.

## Bug Fix
- Reproduce with unit tests, simulator, or hardware note. Patch narrowly and run `cargo test` where possible.

## Testing
- Host tests for pure logic; hardware/simulator tests for integration.

## Docs
- README must include toolchain, target, build/flash/test commands, features, and constraints.

## Complexity
- low: junior-safe pure module.
- medium: mid-level firmware component.
- high: senior unsafe/concurrency/resource work.
- extra-high: principal-expert safety-critical, real-time, or platform architecture.
