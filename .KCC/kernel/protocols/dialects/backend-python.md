---
title: Backend Python Dialect
tags: [kcc/kernel, dialects, backend, python]
created: 2026-05-25
updated: 2026-06-06
version: 0.5.0
status: active
copyright: "KCC framework (c) 2026 Tarek Fawaz"
homepage: "https://tikasway.dev/kcc"
license: "Licensed under the terms in LICENSE"
---

# Backend Python Dialect

Use for Python APIs, workers, CLIs, data services, and automation.

## Coding
- Use `src/` layout for packages, typed functions, explicit configuration, and small modules.
- Prefer clear dependency boundaries over clever dynamic behavior.

## Review
- Check typing, validation, dependency management, secrets handling, logging, and exception paths.

## Bug Fix
- Reproduce with a failing test or script, patch the smallest module, run targeted tests.

## Testing
- Prefer pytest, fixtures, and boundary tests for IO.

## Docs
- README must include Python version, environment setup, run/test commands, and configuration.

## API & Architecture defaults
- When this dialect exposes an HTTP/REST API, follow [[api-standards]]: ship an OpenAPI 3.x document + served Swagger UI (default `/docs`) + verifier-checked route conformance. Waivable only with an ADR.
- Default architecture style is Clean Architecture + DDD per [[architecture-styles]] (domain/application/infrastructure/interface layering, dependency rule inward); opt down only for trivial work with an ADR.

## Complexity
- low: junior-safe script or small route.
- medium: mid-level package change.
- high: senior async/data/persistence behavior.
- extra-high: principal-expert distributed, regulated, or performance-sensitive system.
