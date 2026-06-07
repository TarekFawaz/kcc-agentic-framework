---
title: Embedded C++ Dialect
tags: [kcc/kernel, dialects, embedded, cpp]
created: 2026-05-25
updated: 2026-05-25
version: 0.4.0
status: active
copyright: "KCC framework (c) 2026 Tarek Fawaz"
homepage: "https://tikasway.dev/kcc"
license: "Licensed under the terms in LICENSE"
---

# Embedded C++ Dialect

Use for embedded C++ firmware, drivers, and constrained runtimes.

## Coding
- Prefer deterministic allocation, RAII where safe, clear ownership, and minimal runtime surprises.
- Document hardware, timing, and memory constraints.

## Review
- Check object lifetimes, interrupts, allocation, exceptions/RTTI policy, timing, and resource use.

## Bug Fix
- Reproduce via unit harness, simulator, or hardware note. Patch narrowly and document verification limits.

## Testing
- Host tests for pure logic; hardware/simulator checks for integration.

## Docs
- README must include toolchain, target, build/flash/test commands, and constraints.

## Complexity
- low: junior-safe pure module.
- medium: mid-level driver/component.
- high: senior timing/resource-sensitive work.
- extra-high: principal-expert safety-critical, real-time, or hardware-bound architecture.
