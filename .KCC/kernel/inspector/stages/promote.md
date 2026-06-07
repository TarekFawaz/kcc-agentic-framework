---
# Functional fields (none - stage description, not consumed by adapters)

# Obsidian metadata
title: Inspector Stage 5 - Promote
aliases:
  - inspector-promote
  - stage-promote
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

# Stage 5 - Promote

The merger. Promote applies an `approved` proposal to the real
capability or kernel files, bumps versions, and records the change in
the proposal log.

## Inputs

- A proposal under `.KCC/inspector/proposals/` with
  `status: approved`.
- The current state of every file listed in `affected-files`.
- The version conventions in [[obsidian-standard]] (`MAJOR.MINOR.PATCH`)
  for the version bump.

## Outputs

- Edits to the files in `affected-files`, matching the diff intent in
  the proposal exactly (any deviation requires looping back to
  [[review]]).
- A version bump on each touched capability/kernel file (`updated`
  date and `version`).
- The proposal's frontmatter updated:
  - `status: promoted`
  - `promoted`: ISO date.
  - `promoter`: maintainer email.
- A `inspector-promoted` event appended to
  `coordination/backchannel.jsonl` (event schema is a TBD in the
  Inspector [[README]]).
- A run of `.KCC/tools/sync-adapters.ps1` to regenerate harness
  outputs, then `.KCC/tools/validate-kcc.ps1` to confirm the change
  did not break the structure or the Lethal Trifecta detector.

## Owner

- **Always the kernel maintainer.** Promote is the only stage that
  actually mutates the kernel/capabilities source of truth, so it is
  intentionally not delegated.

## When this stage fires

- A proposal transitions to `status: approved` AND the maintainer
  decides to apply it (batching multiple approved proposals into a
  single promote pass is allowed).

## What triggers stage N+1

There is no stage N+1. After promote, the Inspector cycle restarts at
[[observe]] - subsequent sessions running against the new
capability surface generate fresh observations that can either confirm
the change improved things or detect a regression and trigger a new
proposal.

## Example artifact (final state of PROP-0007 after promote)

```yaml
---
id: PROP-0007
created: 2026-05-25
status: promoted
copyright: "KCC framework (c) 2026 Tarek Fawaz"
homepage: "https://tikasway.dev/kcc"
license: "Licensed under the terms in LICENSE"
reviewer: tarek.fawaz1983@gmail.com
reviewed: 2026-05-28
promoter: tarek.fawaz1983@gmail.com
promoted: 2026-05-28
affected-files:
  - .KCC/capabilities/agents/spec-writer.md
applied-version-bumps:
  - .KCC/capabilities/agents/spec-writer.md: 2.1.0 -> 2.2.0
---
```

## Constraints

- Promote must not deviate from the approved diff intent. If the
  reality of the file has shifted since review, loop back: set
  `status: revise` and re-draft.
- `sync-adapters.ps1` and `validate-kcc.ps1` must both pass before
  the proposal is marked `promoted`. A failure means the edit is
  reverted (or fixed forward inside the same promote pass with the
  reviewer's consent recorded in `## Verdict notes`).
- A promoted proposal is the historical record. Never edit it again
  after promotion; further changes go through a new proposal.
