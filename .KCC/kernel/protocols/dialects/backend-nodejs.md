---
title: Backend NodeJS Dialect
tags: [kcc/kernel, dialects, backend, nodejs]
created: 2026-05-25
updated: 2026-06-06
version: 0.5.0
status: active
copyright: "KCC framework (c) 2026 Tarek Fawaz"
homepage: "https://tikasway.dev/kcc"
license: "Licensed under the terms in LICENSE"
---

# Backend NodeJS Dialect

Use for NodeJS backends, APIs, workers, and CLIs.

## Coding
- Prefer TypeScript when allowed. Use `src/`, explicit configuration, structured errors, and clear async boundaries.

## Review
- Check input validation, async error paths, dependency risk, security headers, secrets, and logging.

## Bug Fix
- Reproduce with a failing test or request, patch narrowly, run targeted tests and lint.

## Testing
- Use the project runner. Cover API boundaries and async failures.

## Docs
- README must include Node version, package manager, run/test commands, and environment variables.

## API & Architecture defaults
- When this dialect exposes an HTTP/REST API, follow [[api-standards]]: ship an OpenAPI 3.x document + served Swagger UI (default `/docs`) + verifier-checked route conformance. Waivable only with an ADR.
- Default architecture style is Clean Architecture + DDD per [[architecture-styles]] (domain/application/infrastructure/interface layering, dependency rule inward); opt down only for trivial work with an ADR.

## Complexity
- low: junior-safe handler or utility.
- medium: mid-level service change.
- high: senior auth/integration/performance.
- extra-high: principal-expert distributed, regulated, or high-scale backend.
