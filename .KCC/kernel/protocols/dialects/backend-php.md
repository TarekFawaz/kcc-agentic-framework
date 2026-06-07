---
title: Backend PHP Dialect
tags: [kcc/kernel, dialects, backend, php]
created: 2026-05-25
updated: 2026-05-25
version: 0.4.0
status: active
copyright: "KCC framework (c) 2026 Tarek Fawaz"
homepage: "https://tikasway.dev/kcc"
license: "Licensed under the terms in LICENSE"
---

# Backend PHP Dialect

Use for PHP backend applications, APIs, and services.

## Coding
- Use Composer conventions, typed declarations, explicit validation, and framework-native structure.
- Put greenfield application code under `src/` when no framework convention overrides it.

## Review
- Check input validation, auth boundaries, dependency versions, secrets, error handling, and framework idioms.

## Bug Fix
- Reproduce with a failing test or request, patch narrowly, run unit/integration tests.

## Testing
- Prefer PHPUnit/Pest or the existing project test runner.

## Docs
- README must include PHP version, Composer install, run/test commands, and environment setup.

## Complexity
- low: junior-safe controller/helper change.
- medium: mid-level feature.
- high: senior persistence/auth/integration.
- extra-high: principal-expert regulated, legacy modernization, or multi-service work.
