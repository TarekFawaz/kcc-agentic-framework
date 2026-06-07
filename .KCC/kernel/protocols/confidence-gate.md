---
# Functional fields
description: Critical human gate triggered by agent confidence below the configured threshold, 95% by default.
inputs: Agent output, confidence score, and reason for uncertainty.
outputs: Human decision to approve, revise, escalate, or abort.

# Obsidian metadata
title: "Confidence Gate Protocol"
aliases:
  - confidence-gate
  - critical-human-gate
  - human-confidence-gate
tags:
  - framework/protocol
  - lifecycle/gate
  - hitl
created: 2026-05-24
updated: 2026-06-06
version: 1.2.0
status: active
copyright: "KCC framework (c) 2026 Tarek Fawaz"
homepage: "https://tikasway.dev/kcc"
license: "Licensed under the terms in LICENSE"
---

# Confidence Gate

Every agent response that can affect lifecycle progression must end with:

```text
Confidence: NN%
```

If `NN` is below the configured threshold, the orchestrator must automatically
invoke `/critical-human-gate` before any downstream handoff, auto-mode fan-out,
implementation, approval, or commit. The default threshold is 95%. AutoPolicy
may set a different threshold with `--accuracy NN%` (`--acuuracy` is accepted
as a typo alias), and that threshold applies for the current auto run only.

---

## Required Gate Prompt

When confidence is below the configured threshold, ask the human:

```text
Critical human gate triggered:
- Agent: {agent}
- Confidence: {NN}%
- Reason: {uncertainty}
- Proposed next action: {action}

Choose: approve | revise | escalate | abort
```

Meanings:

- `approve`: human accepts the risk and lifecycle may continue.
- `revise`: agent must revise with human corrections.
- `escalate`: route to architect, verifier, or a stronger/alternate model.
- `abort`: stop the lifecycle and record the reason.

---

## Recording

Record the gate in:

- `coordination/backchannel.jsonl` as `human-gate-triggered` and
  `human-gate-resolved`.
- `Traces/Session-*/HumanDecisions.md` when a trace folder exists.

Include the active threshold in both records.

---

## Two distinct gates (do not conflate)

The framework runs **two** human-escalation gates that both route through
`/critical-human-gate` but fire for different reasons and at different
granularity. Keep them distinct.

| | Accuracy / confidence gate | ROI-confidence gate |
|--|--|--|
| **Threshold** | Default **95%** (tunable via `--accuracy NN%`) | Fixed **60%** (NOT tuned by `--accuracy`) |
| **Granularity** | Per-decision / per-agent-turn | Idea-level, once after the ROI step |
| **Trigger** | Any agent's final `Confidence: NN%` line falls below the threshold | Idea-interrogator's ROI confidence % (in `ROI.md`) is below 60% |
| **Fires in silent mode?** | Yes | Yes - this is the silent-mode escalation point so silent runs do not chase low-confidence ROI |
| **`/critical-human-gate` mode** | (default) | `mode: roi-gate` |
| **Human choices** | approve / revise / escalate / abort | proceed / revise scope / abort |
| **Auto-mode rule** | CR-4 in [[auto-mode]] | CR-11 in [[auto-mode]] |

- The **accuracy/confidence gate** protects each individual decision: if an
  agent cannot defend its output at the configured confidence level, the human
  is asked before the lifecycle advances.
- The **ROI-confidence gate** protects the *whole idea's economic case*: even
  when every per-decision confidence is high, a weak ROI (< 60% confidence)
  must surface to the human in silent mode before money/time is committed. The
  idea-interrogator records the ROI confidence % and surfaces the
  low-confidence condition plus alternatives; the `/auto` skill performs the
  escalation.

Both gates are independent of each other and of the Scenario-3 budget cap. Any
combination may fire in a single run.

---

## Related

- Auto mode: [[auto-mode]]
- Backchannel: [[backchannel]]
- Architecture governance: [[architecture-governance]]
