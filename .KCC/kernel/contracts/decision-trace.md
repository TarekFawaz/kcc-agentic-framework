---
title: Decision Trace Contract
aliases:
  - decision-trace
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

# Decision Trace Contract

Lifecycle decisions must be human-readable and traceable.

Record:

- human approvals, revisions, aborts, and AutoPolicy decisions;
- confidence gates and resolutions;
- budget approvals and cap breaches;
- architecture decisions and diagram updates;
- sub-agent session plans and launch permission;
- dialect choices and complexity levels.

Runtime traces live under `Traces/`. Coordination events live in
`coordination/backchannel.jsonl`. Framework source never stores command output.
