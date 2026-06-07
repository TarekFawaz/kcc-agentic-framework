---
title: Agent Contract
aliases:
  - agent-contract
tags:
  - kcc/kernel
  - contract
created: 2026-05-25
updated: 2026-06-07
version: 0.5.0
status: active
copyright: "KCC framework (c) 2026 Tarek Fawaz"
homepage: "https://tikasway.dev/kcc"
license: "Licensed under the terms in LICENSE"
---

# Agent Contract

Every KCC agent is a local capability under `.KCC/capabilities/agents/`.
Agents are reusable roles, not project output.

Required frontmatter:

```yaml
name: kebab-case-name
role: short role phrase
model-class: strong-reasoning | balanced | fast-implementation | local-strong | local-fast
description: one-line purpose
tools-required:
  - read
  - search
inputs: expected input
outputs: expected artifacts
```

Required body sections:

- `## Process`
- `## Output Format`
- `## Constraints`

Rules:

- End lifecycle-affecting work with `Confidence: NN%`.
- Invoke the confidence gate below the active threshold.
- Write runtime outputs outside `.KCC/`.
- Use kernel protocols before inventing local conventions.
- Use dialect protocols for coding, review, bug fixing, testing, and docs.
- End lifecycle-affecting work with an `ActualTokenUsage` block (below).

## Return contract: `ActualTokenUsage` (required)

Every lifecycle-affecting agent turn MUST return an `ActualTokenUsage` block so
the meta-agents can record real token cost and calibrate estimates against it:

```yaml
ActualTokenUsage:
  actual_input_tokens: <int|null>
  actual_output_tokens: <int|null>
  actual_total_tokens: <int|null>
  source: harness-reported | api-usage | unavailable
  unavailable_reason: <text when source=unavailable>
  estimate_event_id: <BC-NNNNN of the matching estimate-issued event, or null>
```

Rules for this block:

- **NEVER invent actuals.** If the harness cannot expose token usage, set
  `source: unavailable`, fill `unavailable_reason`, and leave the three count
  fields `null`. Faking precision is a contract violation - an honest
  `unavailable` is always correct.
- Set `source: harness-reported` or `api-usage` only when the count came from a
  real meter (the harness usage report or the provider API usage field).
- Set `estimate_event_id` to the `BC-NNNNN` of the `estimate-issued` event this
  turn was estimated against, when one exists; otherwise `null`.
- The meta-agents consume this block: [[../../capabilities/agents/butler]]
  (remember mode) extracts it into the session's `TokenUsage.md` and emits an
  `actual-recorded` backchannel event when counts are present;
  [[../../capabilities/agents/token-guard]] matches it via `estimate_event_id`,
  computes estimate-vs-actual variance, feeds calibration, and records "actual
  unavailable" without fabrication when `source: unavailable`.
