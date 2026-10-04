---
title: Migrator Output Template
tags:
  - framework/agent-ref
updated: 2026-09-21
---

# Migrator Output Template

## Import Layout

```text
migrations/IMPORT-{NNN}/
|-- plan.md
|-- mapping.md
`-- drafts/
    |-- agents/
    |   `-- {name}.md        (status: draft, with provenance comment)
    `-- skills/
        `-- {name}.md        (status: draft, with provenance comment)
```

## Console Summary

Console paragraph:

```text
Imported from <source path> (format: <detected>). Found <N> artifacts
(<A> agents, <S> skills). Migrated <M> as drafts; <R> flagged for human
review. See migrations/IMPORT-{NNN}/plan.md to review and promote.
```
