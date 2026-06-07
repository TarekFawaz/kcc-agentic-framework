---
title: Backend C# Dialect
tags: [kcc/kernel, dialects, backend, csharp]
created: 2026-05-25
updated: 2026-06-06
version: 0.5.0
status: active
copyright: "KCC framework (c) 2026 Tarek Fawaz"
homepage: "https://tikasway.dev/kcc"
license: "Licensed under the terms in LICENSE"
---

# Backend C# Dialect

Use for C# backend services, APIs, workers, and libraries.

## Coding
- Prefer idiomatic .NET project layout under `src/`.
- Use clear namespaces, dependency injection, async APIs where appropriate, and typed configuration.
- Keep domain logic testable outside controllers or transport handlers.

## Review
- Check nullability, error handling, async usage, logging, configuration, validation, and security boundaries.

## Bug Fix
- Reproduce with a failing test or minimal command, patch narrowly, then verify regression coverage.

## Testing
- Prefer unit tests for domain logic and integration tests for API/persistence boundaries.

## Docs
- README must include SDK version, run/test commands, configuration, and API entrypoints.

## API & Architecture defaults
- When this dialect exposes an HTTP/REST API, follow [[api-standards]]: ship an OpenAPI 3.x document + served Swagger UI (default `/docs`) + verifier-checked route conformance. Waivable only with an ADR.
- Default architecture style is Clean Architecture + DDD per [[architecture-styles]] (domain/application/infrastructure/interface layering, dependency rule inward); opt down only for trivial work with an ADR.

## Complexity
- low: junior-safe small endpoint or utility.
- medium: mid-level service change.
- high: senior cross-cutting behavior or persistence.
- extra-high: principal-expert distributed, regulated, or high-scale service design.
