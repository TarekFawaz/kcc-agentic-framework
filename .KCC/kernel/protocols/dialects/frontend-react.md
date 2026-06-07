---
title: Frontend React Dialect
tags: [kcc/kernel, dialects, frontend, react]
created: 2026-05-25
updated: 2026-05-25
version: 0.4.0
status: active
copyright: "KCC framework (c) 2026 Tarek Fawaz"
homepage: "https://tikasway.dev/kcc"
license: "Licensed under the terms in LICENSE"
---

# Frontend React Dialect

Use for React applications and component systems.

## Coding
- Prefer typed components when TypeScript is available, predictable state, accessible controls, and stable responsive layout.
- Keep source under `src/`; assets under `public/` or `src/assets/` by convention.

## Review
- Check state flow, component boundaries, accessibility, keyboard behavior, responsive layout, assets, and tests.

## Bug Fix
- Reproduce in component test or browser, patch narrow component/hook, run tests and visual smoke check.

## Testing
- Use component/unit tests and browser checks for key interactions.

## Docs
- README must include Node version, package manager, run/test commands, routes, and asset credits.

## Complexity
- low: junior-safe component/style.
- medium: mid-level feature flow.
- high: senior state/performance/integration.
- extra-high: principal-expert design system, rendering architecture, or platform work.
