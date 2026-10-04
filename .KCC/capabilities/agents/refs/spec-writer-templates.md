---
title: Spec Writer Templates
tags:
  - framework/agent-ref
updated: 2026-09-21
---

# Spec Writer Templates

Shapes are defined in `.KCC/kernel/protocols/spec-layout.md` (v6); this file
only lists what spec-writer writes and the arch skeleton.

## Files Written

```text
specs/
|-- specs.md
`-- IDEA-{ID}-{slug}-Specs/
    |-- IDEA-{ID}-{slug}-Specs.md
    |-- ROADMAP.md                 <- Execution Plan + Token Plan (token-guard fills estimates)
    `-- SPEC-{ID}-{slug}/
        |-- SPEC-{ID}-{slug}.md    <- Delivery Brief / ACs / Backlog (Wave col) / Architecture / Risks
        |-- arch.md                <- section skeleton only
        `-- Backlog/
            |-- Story-001-{slug}.md
            `-- Enabler-001-{slug}.md
```

Not written by spec-writer: `plan.md` (planner), `review.md` (verifier),
`Backlog/Bug-*.md` (`/bug-report`, verifier). No stubs. Retired v5 files
(`backlog.md`, `parallelization.md`, `budget.md`, `handovers.md`) are never
created.

## arch.md Skeleton

Frontmatter from `[[../../kernel/templates/spec-arch|spec-arch.md]]`
(`status: awaiting`), then headings only - no placeholder diagrams:

```markdown
# SPEC-{ID} Architecture

## What this spec changes architecturally
## Context / container slice
## Workflow this spec changes
## Data flow (if relevant)
## Inherited governance + overrides
## Open architecture questions
## Related
```

The architect fills it; content bar: >= 1 embedded ```mermaid``` block plus
prose (`[[../../kernel/protocols/architecture-documentation]]`).

## Priority Scale

- P0 CRITICAL: data loss, security vulnerability, crash, legal blocker.
- P1 HIGH: reliability, test coverage, blocking infrastructure, major user value.
- P2 MEDIUM: maintainability, observability, non-blocking improvements.
- P3 LOW: cleanup, cosmetic, nice-to-have.
