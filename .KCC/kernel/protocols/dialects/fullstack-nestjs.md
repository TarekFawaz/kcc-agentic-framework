---
title: Full-stack NestJS Dialect
tags: [kcc/kernel, dialects, fullstack, nestjs]
created: 2026-05-25
updated: 2026-06-06
version: 0.5.0
status: active
copyright: "KCC framework (c) 2026 Tarek Fawaz"
homepage: "https://tikasway.dev/kcc"
license: "Licensed under the terms in LICENSE"
---

# Full-stack NestJS Dialect

Use for NestJS-centered full-stack or backend-heavy TypeScript systems.

## Coding
- Use modules, providers, DTOs, validation pipes, and clear boundaries.
- Keep UI/client and API contracts explicit.

## Review
- Check dependency injection, validation, auth guards, async errors, module boundaries, and contract tests.

## Bug Fix
- Reproduce with controller/service tests, patch the smallest provider/module, run targeted tests.

## Testing
- Unit tests for providers; integration/e2e tests for controllers and main user flows.

## Docs
- README must include Node version, package manager, env vars, run/test commands, and API routes.

## API & Architecture defaults
- When this dialect exposes an HTTP/REST API, follow [[api-standards]]: ship an OpenAPI 3.x document + served Swagger UI (default `/docs`) + verifier-checked route conformance. Waivable only with an ADR.
- Default architecture style is Clean Architecture + DDD per [[architecture-styles]] (domain/application/infrastructure/interface layering, dependency rule inward); opt down only for trivial work with an ADR.

## Complexity
- low: junior-safe controller/provider.
- medium: mid-level feature module.
- high: senior cross-module workflow.
- extra-high: principal-expert distributed, regulated, or high-scale service.
