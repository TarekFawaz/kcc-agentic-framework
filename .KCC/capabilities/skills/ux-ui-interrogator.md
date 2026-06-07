---
name: ux-ui-interrogator
description: >
 Interrogate user-facing work for UX/UI, themes, colors, logos/icons, shapes, motion, audio, accessibility, responsive behavior, and design-system direction. Usage: /ux-ui-interrogator <idea-folder or spec request>
argument-placeholder: <ARGS>
delegates-to:
  - ux-ui-designer
maturity: L1
maintainer: tarek.fawaz1983@gmail.com
copyright: "KCC framework (c) 2026 Tarek Fawaz"
homepage: "https://tikasway.dev/kcc"
license: "Licensed under the terms in LICENSE"

# Obsidian metadata (used in the vault, ignored by harness adapters)
title: UX/UI Interrogator Skill
tags:
  - framework/skill
  - lifecycle/interrogate
  - ux
created: 2026-05-25
updated: 2026-05-25
version: 0.5.0
status: active
---

# UX/UI Interrogator

Interrogate user experience for: <ARGS>

## Steps

1. Resolve `<ARGS>` to an idea folder, spec request, or backlog item.
2. Delegate to **ux-ui-designer**.
3. Require `UXDecisionBrief.md` for user-facing work, or an explicit "UX brief
   not required" result for non-UI work.
4. Pass the UX brief to architect, spec-writer, planner, implementer, and verifier.
5. If confidence is below the active threshold, invoke `/critical-human-gate`.

## Constraints

- Do not implement UI.
- Do not skip for games, dashboards, web apps, mobile apps, reports, or internal tools.
