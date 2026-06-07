---
title: Confidence Contract
aliases:
  - confidence-contract
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

# Confidence Contract

Every agent result that can move lifecycle state must report:

```text
Confidence: NN%
```

Default threshold is 95%. AutoPolicy may set another threshold for one auto
run. Below threshold, invoke `/critical-human-gate` before any downstream
handoff, implementation, review closure, window launch, or approval.

Confidence is not decoration. It must reflect missing context, uncertainty,
unverified assumptions, test gaps, and architectural risk.
