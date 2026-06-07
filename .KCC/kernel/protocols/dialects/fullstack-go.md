---
title: Full-stack Go Dialect
tags: [kcc/kernel, dialects, fullstack, go]
created: 2026-05-25
updated: 2026-06-06
version: 0.5.0
status: active
copyright: "KCC framework (c) 2026 Tarek Fawaz"
homepage: "https://tikasway.dev/kcc"
license: "Licensed under the terms in LICENSE"
---

# Full-stack Go Dialect

Use for Go web apps with server-rendered UI, API plus frontend, or embedded assets.

## Coding
- Keep Go packages, templates/assets, tests, and docs clearly separated.
- Prefer explicit handlers, small packages, and simple build steps.

## Review
- Check context/error handling, template safety, asset pipeline, accessibility, and deployment assumptions.

## Bug Fix
- Reproduce with route or package test, patch narrowly, run `go test ./...`.

## Testing
- Table-driven tests for logic; integration checks for routes and assets.

## Docs
- README must include Go version, build/test/run commands, env vars, and routes.

## API & Architecture defaults
- When this dialect exposes an HTTP/REST API, follow [[api-standards]]: ship an OpenAPI 3.x document + served Swagger UI (default `/docs`) + verifier-checked route conformance. Waivable only with an ADR.
- Default architecture style is Clean Architecture + DDD per [[architecture-styles]] (domain/application/infrastructure/interface layering, dependency rule inward); opt down only for trivial work with an ADR.

## Complexity
- low: junior-safe handler/template.
- medium: mid-level feature slice.
- high: senior cross-layer workflow.
- extra-high: principal-expert performance, distributed, or regulated system.
