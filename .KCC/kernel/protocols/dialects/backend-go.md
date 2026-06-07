---
title: Backend Go Dialect
tags: [kcc/kernel, dialects, backend, go]
created: 2026-05-25
updated: 2026-06-06
version: 0.5.0
status: active
copyright: "KCC framework (c) 2026 Tarek Fawaz"
homepage: "https://tikasway.dev/kcc"
license: "Licensed under the terms in LICENSE"
---

# Backend Go Dialect

Use for Go APIs, CLIs, workers, and services.

## Coding
- Keep packages small and explicit. Prefer standard library first.
- Put application code under `src/` for greenfield KCC projects unless an existing Go layout already exists.
- Return errors with context; avoid hidden global state.

## Review
- Check context propagation, error wrapping, goroutine safety, resource cleanup, and interface size.

## Bug Fix
- Add a failing test, isolate the package boundary, patch directly, run `go test ./...`.

## Testing
- Table-driven tests are preferred. Use integration tests for external systems.

## Docs
- README must include Go version, build/test commands, environment variables, and examples.

## API & Architecture defaults
- When this dialect exposes an HTTP/REST API, follow [[api-standards]]: ship an OpenAPI 3.x document + served Swagger UI (default `/docs`) + verifier-checked route conformance. Waivable only with an ADR.
- Default architecture style is Clean Architecture + DDD per [[architecture-styles]] (domain/application/infrastructure/interface layering, dependency rule inward); opt down only for trivial work with an ADR.

## Complexity
- low: junior-safe utility or handler.
- medium: mid-level package/service change.
- high: senior concurrency, persistence, or API design.
- extra-high: principal-expert distributed or performance-critical system.
