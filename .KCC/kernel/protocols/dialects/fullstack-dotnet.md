---
title: Full-stack .NET Dialect
tags: [kcc/kernel, dialects, fullstack, dotnet]
created: 2026-05-25
updated: 2026-06-06
version: 0.5.0
status: active
copyright: "KCC framework (c) 2026 Tarek Fawaz"
homepage: "https://tikasway.dev/kcc"
license: "Licensed under the terms in LICENSE"
---

# Full-stack .NET Dialect

Use for .NET solutions with backend plus UI.

## Coding
- Keep backend, frontend, tests, and shared contracts separated under `src/`.
- Respect framework conventions for ASP.NET, Blazor, Razor, or chosen UI stack.

## Review
- Check API/UI contract drift, auth, validation, state flow, accessibility, and build/test coverage.

## Bug Fix
- Reproduce at the affected boundary, patch smallest layer, verify backend and UI behavior.

## Testing
- Unit tests for domain logic; integration/e2e checks for user flows.

## Docs
- README must explain solution layout, run/test commands, environment setup, and user-facing routes.

## API & Architecture defaults
- When this dialect exposes an HTTP/REST API, follow [[api-standards]]: ship an OpenAPI 3.x document + served Swagger UI (default `/docs`) + verifier-checked route conformance. Waivable only with an ADR.
- Default architecture style is Clean Architecture + DDD per [[architecture-styles]] (domain/application/infrastructure/interface layering, dependency rule inward); opt down only for trivial work with an ADR.

## Complexity
- low: junior-safe single screen/API change.
- medium: mid-level feature slice.
- high: senior cross-layer workflow.
- extra-high: principal-expert distributed, regulated, or multi-app platform.
