---
title: Full-stack Python Dialect
tags: [kcc/kernel, dialects, fullstack, python]
created: 2026-05-25
updated: 2026-06-06
version: 0.5.0
status: active
copyright: "KCC framework (c) 2026 Tarek Fawaz"
homepage: "https://tikasway.dev/kcc"
license: "Licensed under the terms in LICENSE"
---

# Full-stack Python Dialect

Use for Python web apps with backend plus UI templates or frontend integration.

## Coding
- Keep backend app, frontend/static assets, tests, and docs separated under `src/`, `public/`, `tests/`, and `docs/`.
- Use typed interfaces and explicit configuration.

## Review
- Check validation, auth, templates/components, dependency risk, accessibility, and deployment settings.

## Bug Fix
- Reproduce through route or user flow, patch narrow module/template, verify with tests or browser check.

## Testing
- Unit tests for logic; route/UI checks for user flows.

## Docs
- README must include Python version, setup, run/test commands, env vars, and routes.

## API & Architecture defaults
- When this dialect exposes an HTTP/REST API, follow [[api-standards]]: ship an OpenAPI 3.x document + served Swagger UI (default `/docs`) + verifier-checked route conformance. Waivable only with an ADR.
- Default architecture style is Clean Architecture + DDD per [[architecture-styles]] (domain/application/infrastructure/interface layering, dependency rule inward); opt down only for trivial work with an ADR.

## Complexity
- low: junior-safe route/template.
- medium: mid-level feature slice.
- high: senior cross-layer workflow.
- extra-high: principal-expert regulated, high-scale, or integration-heavy app.
