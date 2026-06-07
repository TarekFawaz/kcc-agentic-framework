---
# Functional fields (none - this document describes a kernel-level scaffold,
# it is not consumed directly by harness adapters)

# Obsidian metadata (used in the vault, ignored by harness adapters)
title: Inspector Pipeline (Scaffold)
aliases:
  - inspector
  - inspector-pipeline
  - kcc-inspector
tags:
  - kcc/kernel
  - framework/protocol
  - inspector
created: 2026-05-25
updated: 2026-06-06
version: 1.1.0
status: active
copyright: "KCC framework (c) 2026 Tarek Fawaz"
homepage: "https://tikasway.dev/kcc"
license: "Licensed under the terms in LICENSE"
---

# Inspector Pipeline

The **Inspector Pipeline** is KCC v0.4's cross-team learning engine. It
continuously mines decision traces and coordination signals from real agent
runs and proposes capability changes (new dialects, refined protocols,
deprecated agents, sharpened skills) that the kernel maintainer can review
and promote.

A **BASIC automated inspector now exists**: `.KCC/tools/kcc-inspect.ps1`
(run via the `/inspect` skill) implements the **Detect -> Propose** stages at
a basic level. **Observe** reads existing traces + backchannel; **Review** and
**Promote** remain human. The scaffold below still describes the full target
contract; see [What is automated today](#what-is-automated-today) for the
current scope and its honest limits.

## What it is

A five-stage pipeline:

1. **[[observe]]** - capture raw signals from running agents (traces,
   backchannel events, confidence scores, gate outcomes, token-actuals).
2. **[[detect]]** - mine those signals for repeating patterns, drift, or
   anomalies that suggest a capability is over/under-serving its callers.
3. **[[propose]]** - turn a detection into a concrete, reviewable change
   proposal (a Markdown file with diff-style intent and rationale).
4. **[[review]]** - kernel maintainer (human) examines the proposal,
   approves / revises / rejects.
5. **[[promote]]** - approved proposals are merged into
   `.KCC/capabilities/` or `.KCC/kernel/` and recorded in the proposal log.

Each stage has its own document under `stages/` describing inputs, outputs,
owners, and stage-N->N+1 triggers.

## Why v0.4 mandates it

KCC v0.4 separates **Kernel** (slow-changing governance) from
**Capabilities** (fast-changing agents and skills) precisely so the
capabilities layer can evolve from evidence. Without an Inspector, the
capabilities layer drifts based on whoever shouted loudest in the last
session. The Inspector replaces that with a structured promotion path
grounded in real traces.

Concretely:

- Cells (cell teams) operating against a shared kernel need a feedback
  channel that doesn't require kernel maintainer involvement on every
  tweak.
- Behavior-based trust (a Phase 2 prerequisite, see [[phase-model]])
  cannot exist without a reliable observation surface.
- The Lethal Trifecta detector ([[lethal-trifecta]]) and other safety
  protocols depend on the Inspector to surface their misses for
  hardening.

## The five stages

| # | Stage | Owner | Triggered by |
|---|--|--|--|
| 1 | [[observe]] | cell-team / automation | Every agent turn ends. |
| 2 | [[detect]] | automation | New Observe batch lands. |
| 3 | [[propose]] | cell-team or automation | Detect emits a candidate. |
| 4 | [[review]] | kernel maintainer | Proposal file appears in `proposals/`. |
| 5 | [[promote]] | kernel maintainer | Reviewed proposal is approved. |

## Data sources (consumed)

- `coordination/backchannel.jsonl` - append-only event log between meta-
  agents (`butler`, `token-guard`) and the lifecycle agents. Provides
  `brief-issued`, `remember-stored`, `estimate-issued`,
  `estimate-aborted`, `actual-recorded`, `calibration-update`, and
  `coordination-note` events. See [[backchannel]].
- `Traces/Session-*/` - per-session folders with `Decisions.md`,
  `Handovers.md`, `Actions.md`, `ToolsUsed.md`, `HumanActions.md`,
  `HumanDecisions.md`, `TokenUsage.md`. See [[trace-layout]].
- `memory/index.json` - read-only snapshot of curated knowledge, used by
  Detect to know what is already common knowledge (so it doesn't propose
  re-learning it).
- `coordination/gate-outcomes/` (when present) -
  [[critical-human-gate]] decisions, including override / revise /
  abort frequencies per agent.

## Data sinks (written)

- `.KCC/inspector/proposals/{YYYY-MM-DD}-{slug}.md` - one file per
  proposal, frontmatter `status: draft|under-review|approved|rejected`,
  body has the proposed diff intent and the supporting evidence pointers.
- `.KCC/inspector/proposals/index.md` - MOC of all proposals (created
  the first time a proposal lands).
- `coordination/backchannel.jsonl` - Inspector also EMITS
  `inspector-detected`, `inspector-proposed`, `inspector-promoted`
  events (taxonomy to be defined when automation lands).

Note: proposals live in `.KCC/inspector/proposals/`, not under
`.KCC/kernel/`, because they are runtime artifacts (continuously
generated) rather than kernel governance documents. The
`.KCC/kernel/inspector/` directory contains only the *protocol*
description; the *output* of the pipeline lives at `.KCC/inspector/`.
This keeps the kernel diff-clean.

## What is automated today

A **basic** Detect -> Propose implementation now ships:

- **Driver:** `.KCC/tools/kcc-inspect.ps1`, exposed as the `/inspect`
  skill.
- **Observe (read-only):** the driver reads
  `coordination/backchannel.jsonl`, `Traces/Session-*/`, and
  `TestResults/` directly. There is no scheduled collector yet; Observe is
  on-demand when `/inspect` runs.
- **Detect (basic):** mines a few simple, counted patterns -
  repeated `estimate-aborted` / `auto-policy-cap-exceeded`, recurring
  confidence-gate trips per agent, recurring bug categories (by severity)
  across `TestResults/*/Bug-*.md`, and calibration divergence per agent
  (only when `calibration-update` events exist).
- **Propose (basic):** writes one reviewable stub per detected pattern to
  `.KCC/inspector/proposals/{YYYY-MM-DD}-{slug}.md` with what was observed,
  the suggested capability/kernel area, and a recommended action
  (Adopt / Investigate / Defer).
- **Honesty floor:** if there is too little signal (few backchannel events
  and few bug files), the driver prints `insufficient signal - N events;
  need more runs` and **writes nothing**. It never fabricates patterns.

**Review** and **Promote** remain **human**: a kernel maintainer reads each
proposal, decides, and promotes manually into `.KCC/capabilities/` or
`.KCC/kernel/`.

## TBD - not yet built

- A scheduled `Observe` collector that aggregates the trace tree on a
  cadence (today Observe is on-demand inside `/inspect`).
- Richer `Detect` mining (drift models, cross-session correlation, anomaly
  scoring) beyond the current simple counted patterns.
- An LLM-backed auto-`Propose` agent that writes richer diff-intent
  proposals (today proposals are deterministic stubs from the PS driver).
- Inspector backchannel event schema additions
  (`inspector-detected` / `inspector-proposed` / `inspector-promoted`).
- An auto-`Promote` path (intentionally human-only for now).

The scaffold remains honest: a human kernel maintainer can still execute the
full pipeline manually, while the basic driver automates the repetitive
Detect+Propose mining and leaves judgment to the human.

## See also

- [[phase-model]] - the Inspector going automated is a Phase 2
  prerequisite.
- [[lethal-trifecta]] - one of the safety patterns that benefits from
  Inspector signal.
- [[backchannel]] - event taxonomy the Inspector will extend.
- [[trace-layout]] - primary input format.
