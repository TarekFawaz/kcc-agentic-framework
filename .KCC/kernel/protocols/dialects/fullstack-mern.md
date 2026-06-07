---
title: Full-stack MERN Dialect
tags: [kcc/kernel, dialects, fullstack, mern]
created: 2026-05-25
updated: 2026-06-06
version: 0.5.0
status: active
copyright: "KCC framework (c) 2026 Tarek Fawaz"
homepage: "https://tikasway.dev/kcc"
license: "Licensed under the terms in LICENSE"
---

# Full-stack MERN Dialect

Use for MongoDB, Express, React, and NodeJS applications.

## Coding
- Separate client, server, shared types, and tests under `src/` where practical.
- Validate API inputs and keep React state predictable.

## Review
- Check API contract, data validation, auth, dependency risk, accessibility, and responsive behavior.

## Bug Fix
- Reproduce in client/server boundary, add regression coverage, patch narrow layer.

## Testing
- Use unit tests plus API/UI integration checks when available.

## Docs
- README must include Node version, package manager, env vars, run/test commands, and app routes.

## API & Architecture defaults
- When this dialect exposes an HTTP/REST API, follow [[api-standards]]: ship an OpenAPI 3.x document + served Swagger UI (default `/docs`) + verifier-checked route conformance. Waivable only with an ADR.
- Default architecture style is Clean Architecture + DDD per [[architecture-styles]] (domain/application/infrastructure/interface layering, dependency rule inward); opt down only for trivial work with an ADR.

## Complexity
- low: junior-safe single route/component.
- medium: mid-level feature slice.
- high: senior cross-layer data flow.
- extra-high: principal-expert scale, security, or multi-service work.
