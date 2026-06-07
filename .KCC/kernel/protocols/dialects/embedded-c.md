---
title: Embedded C Dialect
tags: [kcc/kernel, dialects, embedded, c]
created: 2026-05-25
updated: 2026-05-25
version: 0.4.0
status: active
copyright: "KCC framework (c) 2026 Tarek Fawaz"
homepage: "https://tikasway.dev/kcc"
license: "Licensed under the terms in LICENSE"
---

# Embedded C Dialect

Use for embedded C firmware, drivers, and constrained systems.

## Coding
- Make memory ownership, hardware assumptions, timing, and failure modes explicit.
- Avoid dynamic allocation unless justified. Keep HAL boundaries clear.

## Review
- Check undefined behavior, buffer bounds, interrupts, concurrency, timing, resource use, and hardware dependencies.

## Bug Fix
- Reproduce on simulator, unit harness, or hardware note. Patch narrowly and document test limits.

## Testing
- Prefer host unit tests for pure logic and hardware-in-loop notes when relevant.

## Docs
- README must include toolchain, target hardware, build/flash/test commands, and limitations.

## Complexity
- low: junior-safe pure helper.
- medium: mid-level driver/module.
- high: senior timing/resource-sensitive work.
- extra-high: principal-expert safety-critical or hardware-constrained architecture.
