---
# Functional fields (none - stage description, not consumed by adapters)

# Obsidian metadata
title: Inspector Stage 2 - Detect
aliases:
  - inspector-detect
  - stage-detect
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

# Stage 2 - Detect

The pattern miner. Detect reads Observe batches and looks for repeating
signals that suggest a capability or protocol should change. It outputs
**candidates**, not decisions.

## Inputs

- One or more observation batches from [[observe]].
- `memory/index.json` - to filter out patterns that are already common
  knowledge (and so don't need re-proposing).
- The current `.KCC/capabilities/` snapshot - to know what an agent's
  declared `inputs`, `outputs`, `tools-required`, and `maturity` are
  today.

## Outputs

- A list of **detection candidates**. Each candidate has:
  - `kind`: `over-asks-human`, `confidence-bimodal`,
    `tool-unused`, `frequent-gate-abort`, `token-overshoot`,
    `trifecta-violation`, `dialect-mismatch`, or `other`.
  - `affected-capability`: agent or skill name.
  - `evidence-count`: number of observations supporting the candidate.
  - `evidence-pointers`: session IDs.
  - `proposed-direction`: one sentence (e.g. "tighten `tools-required`
    by removing `web`; nothing in the last 30 sessions used it").

## Owner

- **Today:** human kernel maintainer reading the manual observation
  batch.
- **Tomorrow:** an automated `model-class/balanced` detector agent
  (probably named `inspector-detector`), invoked by the Observe
  watermark advancing.

## When this stage fires

- Whenever a new observation batch is committed (automated path).
- On-demand during a kernel review session (manual path).

## What triggers stage N+1 (Propose)

A detection candidate exceeding a minimum **evidence threshold**
(default proposed: `evidence-count >= 3` over a rolling 30-day window,
or `evidence-count >= 1` for any safety-class detection such as
`trifecta-violation`).

## Example artifact

```yaml
candidates:
  - kind: tool-unused
    affected-capability: agents/spec-writer
    evidence-count: 18
    evidence-pointers: [S-0021, S-0023, S-0027, ...]
    proposed-direction: |
      `tools-required: [..., exec]` has not been invoked in 30 days.
      Propose removing `exec` to tighten the surface.
  - kind: trifecta-violation
    affected-capability: agents/idea-interrogator
    evidence-count: 1
    evidence-pointers: [S-0044]
    proposed-direction: |
      Lethal Trifecta check flagged: untrusted-input + memory-read +
      web. Propose declaring `confidence-gate: required` in
      frontmatter. See [[lethal-trifecta]].
```

## Constraints

- Detect never writes to `.KCC/capabilities/`. It only writes to
  `.KCC/inspector/detections/` (when automated) or directly to a
  draft proposal (when manual).
- Detect must dedupe against open proposals in
  `.KCC/inspector/proposals/` so the same pattern is not re-proposed
  every run.
- Safety-class candidates (`trifecta-violation`, `gate-bypass`,
  `over-asks-human` collapsing to under-asks) skip the evidence
  threshold and propose immediately.
