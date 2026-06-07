---
title: Backend Java Dialect
tags: [kcc/kernel, dialects, backend, java]
created: 2026-05-25
updated: 2026-06-06
version: 0.5.0
status: active
copyright: "KCC framework (c) 2026 Tarek Fawaz"
homepage: "https://tikasway.dev/kcc"
license: "Licensed under the terms in LICENSE"
---

# Backend Java Dialect

Use for Java backend services, APIs, workers, and libraries.

## Coding
- Follow build-tool and framework conventions. Keep domain logic separated from transport.
- Use typed configuration, validation, clear exceptions, and observable service boundaries.

## Review
- Check thread safety, transaction boundaries, validation, dependency injection, logging, and API compatibility.

## Bug Fix
- Reproduce with a failing test, patch narrowly, run the project test task.

## Testing
- Unit tests for domain logic; integration tests for framework/persistence boundaries.

## Docs
- README must include JDK version, build/test commands, configuration, and service entrypoints.

## API & Architecture defaults
- When this dialect exposes an HTTP/REST API, follow [[api-standards]]: ship an OpenAPI 3.x document + served Swagger UI (default `/docs`) + verifier-checked route conformance. Waivable only with an ADR.
- Default architecture style is Clean Architecture + DDD per [[architecture-styles]] (domain/application/infrastructure/interface layering, dependency rule inward); opt down only for trivial work with an ADR.

## Complexity
- low: junior-safe method/controller update.
- medium: mid-level service change.
- high: senior persistence, integration, or concurrency.
- extra-high: principal-expert distributed, regulated, or legacy modernization.
