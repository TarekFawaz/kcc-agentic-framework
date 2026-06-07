---
title: Skill Contract
aliases:
  - skill-contract
tags:
  - kcc/kernel
  - contract
created: 2026-05-25
updated: 2026-05-25
version: 0.4.0
status: active
copyright: "KCC framework (c) 2026 Tarek Fawaz"
homepage: "https://tikasway.dev/kcc"
license: "Licensed under the terms in LICENSE"
---

# Skill Contract

Every KCC skill is a local reusable command under `.KCC/capabilities/skills/`.
Skills orchestrate agents and kernel protocols.

Required frontmatter:

```yaml
name: skill-name
description: One-line behavior and usage.
argument-placeholder: <ARGS>
delegates-to:
  - agent-name
```

Required body:

- concise purpose statement;
- `## Steps`;
- output and hard-stop rules when useful.

Rules:

- Skills should be portable across Claude, Codex, OpenCode, and generic `.agents`.
- Never write generated output under `.KCC/`.
- Preserve human gates unless AutoPolicy explicitly covers them.
- Prefer artifact paths and handoff files over hidden session state.
