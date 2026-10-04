---
title: Cost Envelope Contract
aliases:
  - cost-envelope
tags:
  - kcc/kernel
  - contract
created: 2026-05-25
updated: 2026-05-25
version: 0.4.0
status: active
copyright: "KCC framework (c) 2026 Tarek Fawaz"
homepage: "https://tikasway.dev/kcc"
license: "Licensed under the terms in LICENSE"
---

# Cost Envelope Contract

Token Guard owns cost estimates. The orchestrator owns progression decisions.

Rules:

- Plan and implementation require a fresh estimate.
- AutoPolicy may provide one upfront budget cap.
- Later estimates may auto-approve only while cumulative hosted-model spend
  remains within the cap.
- Local model rows track tokens only unless a separate infra cost model exists.
- Cost decisions must be recorded in `ROADMAP.md` (Token Plan), trace
  `TokenUsage.md` / `HumanDecisions.md`, and the backchannel when applicable
  (per-spec `budget.md` is retired).
