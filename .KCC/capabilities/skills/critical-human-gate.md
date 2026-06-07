---
# Functional fields (consumed by harness adapters)
name: critical-human-gate
description: >
 Pause lifecycle progression when an agent reports confidence below the configured threshold, ask the human to approve/revise/escalate/abort, and record the decision. Usage: /critical-human-gate <agent confidence context>
argument-placeholder: <ARGS>
delegates-to: []
maturity: L1
maintainer: tarek.fawaz1983@gmail.com
copyright: "KCC framework (c) 2026 Tarek Fawaz"
homepage: "https://tikasway.dev/kcc"
license: "Licensed under the terms in LICENSE"

# Obsidian metadata (used in the vault, ignored by harness adapters)
title: Critical Human Gate Skill
aliases:
  - critical-human-gate-skill
  - confidence-gate-skill
tags:
  - framework/skill
  - lifecycle/gate
  - hitl
created: 2026-05-24
updated: 2026-06-06
version: 1.3.0
status: active
---

# Critical Human Gate

Gate context: <ARGS>

This skill serves two distinct gate types (see
[[../../kernel/protocols/confidence-gate|confidence-gate]]):

1. **Default accuracy/confidence gate** - an agent's `Confidence: NN%` fell
   below the active threshold (default 95%, tunable via `--accuracy`).
2. **ROI-confidence gate** (`mode: roi-gate`) - the idea-interrogator's ROI
   confidence is **< 60%** (fixed threshold, not tuned by `--accuracy`). Used
   even in `--silent --assume` mode so silent runs do not chase a weak
   economic case.

Detect the mode from `<ARGS>` (look for `mode: roi-gate`); default to the
accuracy/confidence gate otherwise.

## Steps - default accuracy/confidence gate

1. Parse the triggering agent, confidence score, active threshold, uncertainty
   reason, and proposed next action from `<ARGS>`. If no threshold is supplied,
   use 95%.
2. If confidence is equal to or higher than the active threshold, report that
   the gate is not required and return.
3. Append a `human-gate-triggered` event to `coordination/backchannel.jsonl`
   when available.
4. Ask the human to choose exactly one:
   - approve
   - revise
   - escalate
   - abort
5. Record the decision in `Traces/Session-*/HumanDecisions.md` when a trace
   folder exists and append `human-gate-resolved` to the backchannel.
6. Route based on the decision:
   - approve: continue the lifecycle.
   - revise: return to the triggering agent with corrections.
   - escalate: route to architect, verifier, or alternate model/harness.
   - abort: stop the lifecycle.

## Steps - ROI-confidence gate (`mode: roi-gate`)

1. Parse the ROI confidence %, the idea ID, and the supplied ROI summary,
   documented assumptions, and alternatives from `<ARGS>` (the
   idea-interrogator surfaces these in `ROI.md`).
2. If ROI confidence is **>= 60%**, report that the ROI gate is not required
   and return.
3. Append a `human-gate-triggered` event (with `gate: roi-confidence` and the
   ROI %) to `coordination/backchannel.jsonl` when available.
4. Present to the human, then ask them to choose exactly one
   (`proceed / revise scope / abort`):
   - **ROI summary** - value/cost drivers, payback, and the computed ROI
     confidence %.
   - **Documented assumptions** - what was assumed under the silent AutoPolicy.
   - **Alternatives** - at least two (e.g. narrower scope, defer, different
     solution shape).
5. Record the decision in `Traces/Session-*/HumanDecisions.md` (note it as an
   ROI gate with the % and the chosen option) and append `human-gate-resolved`
   (with `gate: roi-confidence`) to the backchannel.
6. Route based on the decision:
   - proceed: continue the lifecycle silently (the human accepted the ROI risk).
   - revise scope: return to the idea-interrogator to re-frame scope and
     recompute ROI before continuing.
   - abort: stop the lifecycle and record the reason.

## Constraints

- Never continue auto mode while this gate is unresolved.
- Never open new agent windows while this gate is unresolved.
- Do not infer human approval from silence.
