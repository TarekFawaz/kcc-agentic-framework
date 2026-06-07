---
# Functional fields (none - stage description, not consumed by adapters)

# Obsidian metadata
title: Inspector Stage 4 - Review
aliases:
  - inspector-review
  - stage-review
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

# Stage 4 - Review

The human gate. The kernel maintainer (or a delegated reviewer) reads
a draft proposal, decides whether it should ship, and records the
verdict in the proposal's frontmatter.

## Inputs

- The proposal file under `.KCC/inspector/proposals/` with
  `status: draft`.
- Linked evidence pointers (traces, backchannel events, memory
  entries).
- Current state of the affected files - the reviewer must read them
  before judging the diff intent.

## Outputs

- The same proposal file, with frontmatter updated:
  - `status`: `approved` | `revise` | `rejected`.
  - `reviewer`: maintainer email.
  - `reviewed`: ISO date.
  - `verdict-notes`: optional body section appended.
- For `safety`-class proposals, a [[critical-human-gate]] decision
  recorded under `coordination/gate-outcomes/`.

## Owner

- **Always human.** This stage is the one part of the Inspector that
  must not auto-resolve in Phase 1 or Phase 2 (see [[phase-model]]).
  In Phase 3, low-risk style/cost proposals on Golden Path
  capabilities may auto-approve without per-turn human review -
  safety proposals never.

## When this stage fires

- A new file appears in `.KCC/inspector/proposals/` with
  `status: draft`, OR a previously `revise` proposal is updated by
  the proposer with a new draft.

## What triggers stage N+1 (Promote)

`status: approved` in the proposal frontmatter. `status: revise`
loops back to [[propose]] (the proposer drafts a v2). `status:
rejected` ends the pipeline for that candidate.

## Example artifact (post-review diff to PROP-0007)

```yaml
---
id: PROP-0007
created: 2026-05-25
status: approved
copyright: "KCC framework (c) 2026 Tarek Fawaz"
homepage: "https://tikasway.dev/kcc"
license: "Licensed under the terms in LICENSE"
reviewer: tarek.fawaz1983@gmail.com
reviewed: 2026-05-28
affected-files:
  - .KCC/capabilities/agents/spec-writer.md
risk-class: cost
confidence-gate: optional
---
```

with an appended verdict note:

```markdown
## Verdict notes
Approved. The evidence window is sufficient. Promoter should also
bump `spec-writer.version` from 2.1.0 to 2.2.0 to record the
capability surface change.
```

## Constraints

- Reviewers must read the proposed change against the actual file,
  not just the diff block in the proposal. Diff drift is a known
  failure mode.
- For `risk-class: safety` proposals, the reviewer MUST invoke
  [[critical-human-gate]] and record the decision under
  `coordination/gate-outcomes/`. A unilateral approve is forbidden.
- A reviewer may not approve their own proposal when they were also
  the proposer in stage 3, except for `style`-class proposals.
