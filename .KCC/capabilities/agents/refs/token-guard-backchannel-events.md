---
title: Token Guard Backchannel Events
tags:
  - framework/agent-ref
updated: 2026-09-21
---

# Token Guard Backchannel Events

## Backchannel

Token Guard is one of two meta-agents that participate in the
[[backchannel]] protocol. The single source of truth lives at
`coordination/backchannel.jsonl`. See [[backchannel]] for full schema, ID
allocation, and failure modes; the events Token Guard is concerned with
are summarized here.

### Events Token Guard EMITS

#### `estimate-issued`

Appended after the budget table is printed in Mode A.

```json
{
  "ts": "2026-05-24T10:20:11Z",
  "id": "BC-00044",
  "from": "token-guard",
  "to": "broadcast",
  "kind": "estimate-issued",
  "spec": "SPEC-007",
  "session": "<session-id-or-null>",
  "payload": {
    "input_total": 64500,
    "output_total": 32100,
    "cost_total_usd": 4.85,
    "confidence_band_pct": 30,
    "plan_present": false
  }
}
```

#### `estimate-approved`

Appended when the human says "approve".

```json
{
  "ts": "2026-05-24T10:21:03Z",
  "id": "BC-00045",
  "from": "token-guard",
  "to": "broadcast",
  "kind": "estimate-approved",
  "spec": "SPEC-007",
  "session": "<session-id-or-null>",
  "payload": {
    "approved_total_usd": 4.85,
    "approved_input": 64500,
    "approved_output": 32100
  }
}
```

#### `auto-policy-approved`

Appended when the human approves an upfront auto budget cap.

```json
{
  "ts": "2026-05-24T10:21:03Z",
  "id": "BC-00046",
  "from": "token-guard",
  "to": "broadcast",
  "kind": "auto-policy-approved",
  "spec": "IDEA-007",
  "session": "<session-id-or-null>",
  "payload": {
    "budget_cap_amount": 200,
    "budget_cap_currency": "USD",
    "confidence_threshold_pct": 95,
    "silent": true,
    "assume": true
  }
}
```

#### `estimate-auto-approved`

Appended when a later estimate is covered by an approved AutoPolicy.

```json
{
  "ts": "2026-05-24T10:30:03Z",
  "id": "BC-00047",
  "from": "token-guard",
  "to": "broadcast",
  "kind": "estimate-auto-approved",
  "spec": "SPEC-007",
  "session": "<session-id-or-null>",
  "payload": {
    "cost_total_usd": 4.85,
    "cumulative_cost_usd": 12.35,
    "budget_cap_amount": 200,
    "budget_cap_currency": "USD",
    "policy_event_id": "BC-00046"
  }
}
```

#### `auto-policy-cap-exceeded`

Appended when the updated cumulative estimate exceeds the approved cap.

```json
{
  "ts": "2026-05-24T10:35:03Z",
  "id": "BC-00048",
  "from": "token-guard",
  "to": "broadcast",
  "kind": "auto-policy-cap-exceeded",
  "spec": "SPEC-007",
  "session": "<session-id-or-null>",
  "payload": {
    "cost_total_usd": 230.40,
    "budget_cap_amount": 200,
    "budget_cap_currency": "USD",
    "over_by_usd": 30.40,
    "policy_event_id": "BC-00046"
  }
}
```

#### `estimate-aborted`

Appended when the human says "abort".

```json
{
  "ts": "2026-05-24T10:21:50Z",
  "id": "BC-00046",
  "from": "token-guard",
  "to": "broadcast",
  "kind": "estimate-aborted",
  "spec": "SPEC-007",
  "session": "<session-id-or-null>",
  "payload": {
    "reason": "scope too large - revisit after splitting spec"
  }
}
```

#### `coordination-note` (payload tag `loop-detected`)

Appended when the per-spec-per-step trials counter (trace `TokenUsage.md`) reaches
3 (see Mode A step 10). The orchestrator must then invoke
`/critical-human-gate` before any further attempt at that step.

```json
{
  "ts": "2026-05-29T10:42:30Z",
  "id": "BC-00062",
  "from": "token-guard",
  "to": "broadcast",
  "kind": "coordination-note",
  "spec": "SPEC-007",
  "session": "<session-id-or-null>",
  "payload": {
    "tag": "loop-detected",
    "spec": "SPEC-007",
    "step": "implement",
    "trial_count": 3,
    "guidance": "invoke-critical-human-gate"
  }
}
```

#### `actual-recorded`

Appended once per lifecycle step after the harness writes
`Traces/Session-*/TokenUsage.md`. Token Guard reads that file in
calibration mode and replays one event per step. Actual counts are only actual
when `source` is `harness-reported`, `api-usage`, or `manual-meter`. If the
harness does not expose usage, emit `source: unavailable` plus
`unavailable_reason` and leave actual count fields null rather than guessing.

```json
{
  "ts": "2026-05-24T18:42:30Z",
  "id": "BC-00060",
  "from": "token-guard",
  "to": "broadcast",
  "kind": "actual-recorded",
  "spec": "SPEC-007",
  "session": "<session-id-or-null>",
  "payload": {
    "step": "plan",
    "agent": "planner",
    "model_class": "strong-reasoning",
    "actual_input_tokens": 18200,
    "actual_output_tokens": 11100,
    "actual_total_tokens": 29300,
    "source": "harness-reported",
    "estimate_input": 14336,
    "estimate_output": 8602,
    "estimate_event_id": "BC-00044"
  }
}
```

#### `calibration-update`

Appended when calibration pass updates formula constants (see
[[token-budget]] section Calibration).

```json
{
  "ts": "2026-05-24T19:05:00Z",
  "id": "BC-00061",
  "from": "token-guard",
  "to": "broadcast",
  "kind": "calibration-update",
  "spec": null,
  "session": "<session-id-or-null>",
  "payload": {
    "sample_size": 23,
    "updated": {
      "step_multiplier.plan": 0.95,
      "step_multiplier.implement": 1.80,
      "confidence_band_pct": 22
    }
  }
}
```

### Events Token Guard CONSUMES

Token Guard reads (does not write) these kinds from [[butler]] to enrich
estimates:

- `brief-issued` - the entry IDs in the payload point at decisions and
  patterns that may justify model-class overrides (e.g. a pattern entry
  saying "this codebase has good test coverage, drop test step to
  `fast-implementation`").
- `remember-stored` - fresh `incident` entries about budget overruns are
  the strongest signal to widen the band. When a recent `INC-*` ID covers
  similar work, treat it as a band-widening trigger per Mode A step 3.

### How to append

**Always append via the deterministic helper `.KCC/tools/backchannel-append.ps1`.
Do NOT hand-author JSON or hand-allocate IDs** - the freeform "also write JSON"
step is exactly what got skipped before and left `backchannel.jsonl` empty.
Every estimate, approval, abort, auto-approval, cap-exceeded, loop-detected
note, actual-recorded, and calibration-update MUST be emitted with this call:

```powershell
powershell -ExecutionPolicy Bypass -File .KCC\tools\backchannel-append.ps1 `
  -Kind <estimate-issued|estimate-approved|estimate-aborted|auto-policy-approved|estimate-auto-approved|auto-policy-cap-exceeded|coordination-note|actual-recorded|calibration-update> `
  -From token-guard -To broadcast `
  -Spec "<SPEC-ID|IDEA-ID|empty>" -Session "<session-id|empty>" `
  -Payload '<key=val;key=val OR {"json":...}>'
```

The helper allocates the next `BC-NNNNN` (scanning back on a corrupt tail),
stamps a UTC `ts`, and appends one LF-terminated line (UTF-8, no BOM). It
prints the line; read its `id` into the `Backchannel: BC-NNNNN` row of your
budget table. Mode B (prompt) is the only mode that emits nothing.

