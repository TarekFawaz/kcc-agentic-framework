---
title: Butler Backchannel Events
tags:
  - framework/agent-ref
updated: 2026-09-21
---

# Butler Backchannel Events

## Backchannel

Butler is one of two meta-agents that participate in the [[backchannel]]
protocol. The single source of truth lives at
`coordination/backchannel.jsonl`. See [[backchannel]] for full schema, ID
allocation, and failure modes; the events Butler is concerned with are
summarized here.

### Events Butler EMITS

#### `brief-issued`

Appended after every brief mode pack is delivered.

```json
{
  "ts": "2026-05-24T10:15:42Z",
  "id": "BC-00042",
  "from": "butler",
  "to": "broadcast",
  "kind": "brief-issued",
  "spec": "SPEC-007",
  "session": "<session-id-or-null>",
  "payload": {
    "topic": "SPEC-007 - token guard refactor",
    "entry_ids": ["DEC-012", "PAT-004", "INC-003"],
    "pack_tokens_est": 420
  }
}
```

#### `remember-stored`

Appended after every remember mode write (including the "nothing retained"
case, in which `entry_ids` is `[]`).

```json
{
  "ts": "2026-05-24T11:02:17Z",
  "id": "BC-00043",
  "from": "butler",
  "to": "broadcast",
  "kind": "remember-stored",
  "spec": "SPEC-007",
  "session": "<session-id-or-null>",
  "payload": {
    "entry_ids": ["INC-004", "PAT-005"],
    "summary": "Captured backchannel viewer omission as INC-004; reusable JSONL append pattern as PAT-005."
  }
}
```

#### `outcome-recorded`

Appended for every `(agent, claimed_confidence, outcome)` triple ingested
during calibration-update mode. See
[[../../kernel/protocols/accuracy-calibration|accuracy-calibration]] for
the full schema and rolling-window semantics.

```json
{
  "ts": "2026-05-29T11:02:17Z",
  "id": "BC-00098",
  "from": "butler",
  "to": "broadcast",
  "kind": "outcome-recorded",
  "spec": "SPEC-007",
  "session": "<session-id-or-null>",
  "payload": {
    "agent": "technical-interrogator",
    "claimed_confidence_pct": 95,
    "outcome": "revised"
  }
}
```

#### `calibration-drift`

Appended when an agent's rolling-window `|drift|` newly exceeds +/-10 pp.
Consumed by [[../../capabilities/skills/critical-human-gate|/critical-human-gate]]
to bias future gate decisions for the drifting agent.

```json
{
  "ts": "2026-05-29T11:02:17Z",
  "id": "BC-00099",
  "from": "butler",
  "to": "broadcast",
  "kind": "calibration-drift",
  "spec": null,
  "session": "<session-id-or-null>",
  "payload": {
    "agent": "technical-interrogator",
    "window_size": 10,
    "mean_claimed_pct": 95,
    "observed_success_pct": 80,
    "drift_pp": -15,
    "direction": "negative",
    "recommendation": "lower trust on next turn; bias /critical-human-gate to fire"
  }
}
```

#### `trace-session-created`

Appended by Butler in brief mode whenever it creates a NEW run trace session
(brief mode step 0). Carries `session_id`, `session_path`, and `slug`. Idempotent
- emitted only on session creation, never on re-confirming an existing one.

#### `actual-recorded`

Appended by Butler in remember mode for the returning agent's `ActualTokenUsage`
block (remember mode step 0). Carries the actual counts, `source`, and
`estimate_event_id` when actuals are present; carries `source: unavailable` plus
`unavailable_reason` (counts null) when the harness did not expose usage. Butler
never fabricates counts. Token Guard also emits `actual-recorded` in its Mode D
replay; both are valid emitters of this kind.

#### `session-closed`

Appended by Butler when the run's trace session is closed (final remember turn
of an `auto` run). Carries `session_id` and a one-line `summary`. This is the
terminal event of the lifecycle spine.

#### `coordination-note` (rare)

Free-form cross-agent message. Use only when an event does not fit the
existing taxonomy and the next session genuinely needs the breadcrumb.

### Events Butler CONSUMES

Butler reads (does not write) these kinds from [[token-guard]] to enrich
briefs:

- `estimate-issued` - confirms a budget exists for this spec; cite the band.
- `estimate-aborted` - strong pitfall signal. Surface the abort reason
  verbatim in `## Known Pitfalls`.
- `actual-recorded` - if actuals diverged from estimate, that is a reusable
  signal for a future estimate. Surface as a pitfall when relevant.
- `calibration-update` - note in the brief that formula constants have
  shifted since prior memory entries were written.

### How to append

**Always append via the deterministic helper `.KCC/tools/backchannel-append.ps1`.
Do NOT hand-author JSON or hand-allocate IDs** - that is exactly the freeform
step that got skipped in earlier runs and left `backchannel.jsonl` empty.

```powershell
powershell -ExecutionPolicy Bypass -File .KCC\tools\backchannel-append.ps1 `
  -Kind <event-kind> -From butler -To broadcast `
  -Spec "<SPEC-ID|IDEA-ID|empty>" -Session "<session-id|empty>" `
  -Payload '<key=val;key=val OR {"json":...}>'
```

The helper reads the last readable line, allocates the next monotonic
`BC-NNNNN` (scanning back on a corrupt tail), stamps a UTC ISO-8601 `ts`,
serializes one compact line, and appends it with a trailing `\n` (UTF-8, no
BOM), creating the file/dir if missing. It prints the written line; read the
`id` from it for your output footer. See [[backchannel]] for the schema and
recovery rule the helper implements.

