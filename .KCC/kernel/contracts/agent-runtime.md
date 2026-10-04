---
title: Agent Runtime Contract
aliases:
  - agent-runtime
tags:
  - kcc/kernel
  - contract
created: 2026-09-21
updated: 2026-09-21
version: 1.0.0
status: active
copyright: "KCC framework (c) 2026 Tarek Fawaz"
homepage: "https://tikasway.dev/kcc"
license: "Licensed under the terms in LICENSE"
---

# Agent Runtime Contract

These rules apply to every KCC agent turn. Agent bodies do not restate them;
they only add what is specific to their role.

1. **Input.** You receive a handover packet: goal, ids, `read`, `write`,
   constraints, confidence threshold, budget. See
   `coordination/orchestrator.md` -> *Spawn protocol*. The packet plus your
   profile `inputs` are your whole reading list.
2. **Lazy reads.** For any `.KCC/kernel/**` protocol, template, or
   `refs/` file, and for any file over ~400 lines, Grep for the heading you
   need and read only that section. Never load `.KCC/` wholesale, and never
   re-read a file you already have in context.
3. **Writes.** Write only the paths in your packet's `write` list or in your
   documented outputs. Runtime output goes outside `.KCC/`. Never hand-edit
   generated harness files (`.claude/`, `.codex/`, `.opencode/`,
   `.agents/`, `coordination/orchestrator.*`).
4. **Assumptions.** Under `assume`, make only reversible, low-risk
   assumptions and record each one. The prohibited classes (legal, security,
   privacy, compliance, data sensitivity, auth model, destructive,
   production, external spend, toolchain install) always escalate. See
   `.KCC/kernel/protocols/auto-mode.md` -> *AutoPolicy Semantics*.
5. **Evidence.** Emit lifecycle events only through
   `.KCC/tools/backchannel-append.ps1|.sh`, and only where your process
   names one. Trace and memory writes belong to `butler`.
6. **Confidence.** End lifecycle work with `Confidence: NN%`. Below the
   packet threshold (default 95), stop, list the open questions, and return.
   The orchestrator runs `/critical-human-gate`, not you.
7. **Token actuals.** Append the `ActualTokenUsage` block from
   `.KCC/kernel/contracts/agent-contract.md`. Never invent counts; use
   `source: unavailable` when no meter exists.
8. **Lean return.** Return a summary of 150 words or less, the artifact
   paths written, open questions, confidence, and ActualTokenUsage. Don't
   echo file contents or restate inputs.
