---
title: Backend Rust Dialect
tags: [kcc/kernel, dialects, backend, rust]
created: 2026-05-25
updated: 2026-05-25
version: 0.4.0
status: active
copyright: "KCC framework (c) 2026 Tarek Fawaz"
homepage: "https://tikasway.dev/kcc"
license: "Licensed under the terms in LICENSE"
---

# Backend Rust Dialect

Use for Rust backend services, CLIs, libraries, and performance-sensitive systems.

## Coding
- Favor explicit ownership, small crates/modules, typed errors, and minimal unsafe code.
- Use `src/` and Cargo conventions; document any unsafe block.

## Review
- Check error types, lifetimes/ownership, concurrency, panic paths, feature flags, and unsafe usage.

## Bug Fix
- Add or update tests, reproduce, patch narrowly, run `cargo test` and `cargo clippy` when available.

## Testing
- Unit tests for pure logic; integration tests for IO/service boundaries.

## Docs
- README must include toolchain, build/test commands, features, and runtime configuration.

## Complexity
- low: junior-safe pure module.
- medium: mid-level service or CLI change.
- high: senior async/concurrency/performance.
- extra-high: principal-expert unsafe, embedded, distributed, or regulated work.
