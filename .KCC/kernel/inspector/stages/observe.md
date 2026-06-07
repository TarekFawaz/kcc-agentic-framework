---
# Functional fields (none - stage description, not consumed by adapters)

# Obsidian metadata
title: Inspector Stage 1 - Observe
aliases:
  - inspector-observe
  - stage-observe
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

# Stage 1 - Observe

The capture surface. Observe collects raw evidence of how agents and
skills behaved on real turns. It does not interpret; it normalizes and
forwards.

## Inputs

- `Traces/Session-*/` - every per-session folder closed in the window.
  Specifically `Decisions.md`, `Handovers.md`, `Actions.md`,
  `ToolsUsed.md`, `HumanActions.md`, `HumanDecisions.md`,
  `TokenUsage.md`.
- `coordination/backchannel.jsonl` - all events since the last Observe
  run (use the last-seen `id` as a watermark).
- `coordination/gate-outcomes/` - [[critical-human-gate]] decisions, if
  any landed since last run.

## Outputs

- A normalized **observation batch** - one record per (session, agent,
  turn) with columns: `agent`, `skill`, `model-class`, `confidence`,
  `gate-outcome`, `token-actual`, `tools-used`, `human-overrides`,
  `pitfall-hits`.
- Written (today, manually) as a Markdown table inside a draft
  proposal, or (tomorrow, automated) to
  `.KCC/inspector/observations/{YYYY-MM-DD}.jsonl`.

## Owner

- **Today:** the cell-team running the work (manual scrape of their own
  session) or the kernel maintainer doing a periodic sweep.
- **Tomorrow:** an automated collector triggered on a schedule or on
  every `remember-stored` backchannel event.

## When this stage fires

- Every closed session (lifecycle skill returning a verdict).
- Periodic kernel-maintainer sweep (e.g. weekly) over the trace tree.

## What triggers stage N+1 (Detect)

A new observation batch - or, manually, the kernel maintainer
deciding "we have enough recent traces to mine". When automation lands,
Detect runs immediately after each Observe batch is written.

## Example artifact (hand-written sample)

```markdown
| session | agent | skill | conf | gate | actual-tok | overrides |
|--|--|--|--|--|--|--|
| S-0042  | planner | spec-plan | 92% | n/a | 18,400 | 0 |
| S-0042  | implementer | spec-implement | 78% | revise | 41,200 | 1 |
| S-0043  | planner | spec-plan | 64% | abort | 7,800 | 1 |
```

That sample alone hints at a Detect candidate: `planner` confidence is
bimodal - when it dips below the gate threshold, the gate is firing
correctly, but the abort is happening late (after 7.8k tokens already
spent). That pattern, observed three more times, becomes a [[propose]]
candidate to move planner's confidence self-check earlier.

## Constraints

- Observe is **read-only** on every input. It never edits traces or
  backchannel.
- Observe must not embed private payloads from the trace (e.g. raw
  human answers); only structural metadata. Sensitive content stays in
  `Traces/` and `memory/` and is referenced by path, not copied.
