---
title: Frontend Vanilla JS Dialect
tags: [kcc/kernel, dialects, frontend, vanilla-js]
created: 2026-05-25
updated: 2026-05-25
version: 0.4.0
status: active
copyright: "KCC framework (c) 2026 Tarek Fawaz"
homepage: "https://tikasway.dev/kcc"
license: "Licensed under the terms in LICENSE"
---

# Frontend Vanilla JS Dialect

Use for plain HTML, CSS, and JavaScript projects.

## Coding
- Use `src/` for source, `assets/` for media, and clear modules when possible.
- Keep DOM state explicit, keyboard/mouse controls accessible, and CSS responsive.

## Review
- Check DOM lifecycle, event cleanup, accessibility, responsive layout, asset licensing, and browser compatibility.

## Bug Fix
- Reproduce in browser, patch narrow script/style, run a browser smoke check.

## Testing
- Use available JS tests or manual/browser checks documented in review.

## Docs
- README must include how to run locally, controls/usage, file structure, and asset credits.

## Complexity
- low: junior-safe static interaction.
- medium: mid-level app/game behavior.
- high: senior animation/state/performance.
- extra-high: principal-expert complex rendering, offline, or accessibility-critical work.
