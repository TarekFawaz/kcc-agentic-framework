---
# Functional fields (none - stage description, not consumed by adapters)

# Obsidian metadata
title: Inspector Stage 3 - Propose
aliases:
  - inspector-propose
  - stage-propose
tags:
  - kcc/kernel
  - framework/protocol
  - inspector
created: 2026-05-25
updated: 2026-05-25
version: 1.0.0
status: draft
copyright: "KCC framework (c) 2026 Tarek Fawaz"
homepage: "https://tikasway.dev/kcc"
license: "Licensed under the terms in LICENSE"
---

# Stage 3 - Propose

The change drafter. Propose converts a [[detect]] candidate into a
concrete, reviewable artifact: a Markdown proposal that names exactly
which files would change, what the diff intent is, and why.

## Inputs

- A single detection candidate (or a coherent group of related
  candidates).
- The current `.KCC/capabilities/` and `.KCC/kernel/` snapshot -
  the proposal must reference real, existing files.
- The relevant `memory/` entries - to cite prior decisions or
  patterns the proposal builds on or contradicts.

## Outputs

- One file: `.KCC/inspector/proposals/{YYYY-MM-DD}-{slug}.md`.
- Frontmatter must include: `id`, `created`, `status: draft`,
  `affected-files`, `evidence-pointers`, `risk-class`
  (`safety` | `quality` | `cost` | `style`), `confidence-gate`
  (`required` for safety, optional otherwise).
- Body sections: `## Context`, `## Evidence`, `## Proposed change`
  (with file-by-file diff intent in fenced blocks), `## Risks`,
  `## Rollback plan`.

## Owner

- **Today:** the cell-team that owns the affected capability - or the
  kernel maintainer for cross-cutting protocol changes.
- **Tomorrow:** an automated `model-class/balanced` proposer agent that
  reads Detect output and drafts the proposal file. The human still
  reviews in stage 4.

## When this stage fires

- A detection candidate clears its evidence threshold.
- A cell-team manually requests a kernel change with sufficient
  rationale.

## What triggers stage N+1 (Review)

The proposal file landing under `.KCC/inspector/proposals/` with
`status: draft` triggers the kernel maintainer's review queue.

## Example artifact

```markdown
---
id: PROP-0007
created: 2026-05-25
status: draft
copyright: "KCC framework (c) 2026 Tarek Fawaz"
homepage: "https://tikasway.dev/kcc"
license: "Licensed under the terms in LICENSE"
affected-files:
  - .KCC/capabilities/agents/spec-writer.md
evidence-pointers:
  - Traces/Session-S-0021-*/
  - Traces/Session-S-0023-*/
risk-class: cost
confidence-gate: optional
tags:
  - inspector
  - proposal
---

# PROP-0007 - Tighten spec-writer tool surface

## Context
`spec-writer.tools-required` includes `exec`, originally for read-only
git history queries. The capability has not invoked `exec` in any
session over the last 30 days (18 sessions observed).

## Evidence
See linked sessions. Trace `ToolsUsed.md` files show zero `exec`
invocations from `spec-writer`.

## Proposed change
```diff
 tools-required:
   - read
   - search
   - edit
-  - exec        # narrow: read-only git history (e.g. `git log`)
```

## Risks
- If a future spec genuinely needs git history, the capability would
  need to be re-granted. Mitigated by 30-day evidence window.

## Rollback plan
Re-add the `exec` line via single-line edit; no downstream files
depend on it.
```

## Constraints

- A proposal must touch only `.KCC/` files. Runtime artifacts
  (`specs/`, `ideation/`, `memory/`, `Traces/`) are out of scope -
  those belong to the cell-team, not the kernel.
- If `risk-class: safety`, `confidence-gate: required` must be set, and
  the review stage must route through [[critical-human-gate]].
- Proposals are immutable once `status` leaves `draft`. Subsequent
  changes require a new proposal that links the old one.
