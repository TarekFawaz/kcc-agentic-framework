---
# Functional fields (consumed by harness adapters)
description: >
  Defines the JSONL backchannel that meta-agents [[butler]] and [[token-guard]]
  use to coordinate across lifecycle skills. The single source of truth lives
  at `coordination/backchannel.jsonl`. This document specifies the event
  schema, the event-kind taxonomy, ID allocation, failure modes, and the
  human-readable viewer command.

# Obsidian metadata (vault-only; ignored by harness adapters)
title: Backchannel Protocol
aliases:
  - backchannel
  - jsonl-bus
tags:
  - framework/protocol
  - coordination
created: 2026-05-24
updated: 2026-06-07
version: 1.3.0
status: active
copyright: "KCC framework (c) 2026 Tarek Fawaz"
homepage: "https://tikasway.dev/kcc"
license: "Licensed under the terms in LICENSE"
---

# Backchannel Protocol

The **backchannel** is an append-only JSONL file at
`coordination/backchannel.jsonl` that meta-agents use as their single source
of truth for cross-agent coordination. It exists because [[butler]] and
[[token-guard]] both run on every lifecycle turn and need a low-cost,
machine-parseable way to exchange signals (estimates, abort reasons, memory
deltas, calibration shifts) without each one re-reading the other's full
output.

The file is **machine-first**. Use `.KCC/tools/show-backchannel.ps1` for a
human-readable console view.

---

## How events are written (deterministic helper)

Events MUST be appended with the deterministic helper - never by hand-authoring
JSON and hand-allocating IDs. Earlier runs treated the emit as a soft "also
write JSON" step in markdown instructions, and it was silently skipped at
runtime, leaving `backchannel.jsonl` thin or empty. Routing every emit through
the helper makes the write a single, unmissable command.

```powershell
powershell -ExecutionPolicy Bypass -File .KCC\tools\backchannel-append.ps1 `
  -Kind <event-kind> -From <agent> -To <agent|broadcast> `
  -Spec "<SPEC-ID|IDEA-ID|empty>" -Session "<session-id|empty>" `
  -Payload '<key=val;key=val OR {"json":...}>'
```

```bash
bash .KCC/tools/backchannel-append.sh \
  --kind <event-kind> --from <agent> --to <agent|broadcast> \
  --spec "<SPEC-ID|IDEA-ID|empty>" --session "<session-id|empty>" \
  --payload '<key=val;key=val OR {"json":...}>'
```

The helper creates `coordination/` and the file if missing, allocates the next
monotonic `BC-NNNNN` (reading the last readable line and scanning back over a
corrupt tail), stamps a UTC ISO-8601 `ts`, serializes one compact JSON object,
and appends exactly one LF-terminated line in UTF-8 (no BOM). It prints the
written line so the caller can read the allocated `id`. The helper implements
the `## Event schema`, `## ID allocation`, and `## Failure modes and recovery`
rules below; agents do not reimplement them.

After a successful append, the helper refreshes `dashboard/index.html`
best-effort so the human-facing dashboard updates as events land. Set
`KCC_SKIP_DASHBOARD=1` or pass `-NoDashboard` / `--no-dashboard` for bulk
replay or tests. Dashboard refresh failure never invalidates the event write.

**Invariant:** a real run's `coordination/backchannel.jsonl` is **never empty**.
Each meta-agent (butler, token-guard) emits at least one event per turn (brief,
remember, estimate, approval, abort, calibration) via the helper; a turn that
produced no new line means the emit was skipped and must be re-run. Auto mode
enforces this at every lifecycle gate (see [[auto]] CR-10).

---

## Why JSONL

- **Append-only** maps naturally to a log of events. No locking; concurrent
  appends are safe enough at agent-scale write rates (one line per turn).
- **One JSON object per line** lets any tool (`jq`, `Get-Content -Tail`,
  `Where-Object`) filter by `from`, `kind`, or `spec` without parsing the
  whole file.
- No header, no preamble. Parsers should not need any.

---

## File location

```
coordination/backchannel.jsonl
```

Encoding: **UTF-8, no BOM**. Line terminator: `\n` (LF) - even on Windows.
Append a single `\n` after each event object.

The file is created empty (zero bytes) by the framework scaffolding. The
first agent to emit an event writes line 1 with `id: "BC-00001"`.

---

## Event schema

Every line is a single JSON object with these **required** top-level fields:

```json
{
  "ts": "2026-05-24T10:15:42Z",
  "id": "BC-00001",
  "from": "butler",
  "to": "broadcast",
  "kind": "brief-issued",
  "spec": "SPEC-007",
  "session": "session-abc123",
  "payload": { }
}
```

| Field     | Type   | Notes                                                                |
|--|--|--|
| `ts`      | string | ISO-8601 UTC, second precision, `Z` suffix.                          |
| `id`      | string | `BC-NNNNN`, zero-padded to 5 digits. Monotonic, never reused.        |
| `from`    | string | `butler`, `token-guard`, or any other agent name.                    |
| `to`      | string | `butler`, `token-guard`, or `broadcast`. Use `broadcast` by default. |
| `kind`    | string | One of the kinds in `## Event kinds`. New kinds require a doc PR.    |
| `spec`    | string | `SPEC-NNN`, `IDEA-NNN`, or `null` if the event is not spec-scoped.   |
| `session` | string | Harness session id, or `null` if unavailable.                        |
| `payload` | object | Event-specific. See per-kind shapes in `## Event kinds`.             |

No additional top-level fields. Anything event-specific belongs inside
`payload`.

---

## Event kinds

This is the taxonomy. Adding a new kind is a protocol change - open a PR
that updates this section.

## Lifecycle event spine (canonical taxonomy)

Every real agentic run leaves a readable **lifecycle spine** - one event per
lifecycle transition - not just a final completion event. This is the canonical
event-kind taxonomy. **Cross-cutting rule: every lifecycle transition emits its
event via `backchannel-append.ps1`; a completed run's `backchannel.jsonl`
contains the full ordered spine below.** A missing event means the emit was
skipped and must be re-run.

The canonical minimum sequence, in lifecycle order, with `from` / typical `to` /
required `payload` keys:

| # | Canonical kind | from | to (typical) | Required payload keys | Emitter (skill/agent) |
|--|--|--|--|--|--|
| 1 | `auto-policy-parsed` | orchestrator | broadcast | `scenario` (1/2/3/all), `silent`, `assume`, `confidence_threshold_pct`, `budget_cap_amount` (or null), `budget_cap_currency` | [[../../capabilities/skills/auto\|auto]] (at flag normalization) |
| 2 | `trace-session-created` | butler | broadcast | `session_id`, `session_path`, `slug` | [[butler]] (brief mode, on new session) |
| 3 | `brief-issued` | butler | broadcast | `topic`, `entry_ids`, `pack_tokens_est` | [[butler]] (every brief) |
| 4 | `idea-interrogation-started` | idea-interrogator | broadcast | `idea_id`, `input_class` | [[../../capabilities/skills/auto\|auto]] / `/idea-interrogator` |
| 5 | `idea-interrogation-completed` | idea-interrogator | broadcast | `idea_id`, `artifact_paths`, `confidence_pct` | [[../../capabilities/skills/auto\|auto]] / `/idea-interrogator` |
| 6 | `specialist-brief-created` | orchestrator | broadcast | `brief_type` (`technical`/`ux`/`security`/`infrastructure`), `artifact_path`, `idea_id` | [[../../capabilities/skills/auto\|auto]] (one per specialist brief) |
| 7 | `architecture-pass-complete` | architect | broadcast | `artifact_paths`, `adr_ids`, `confidence_pct` | [[../../capabilities/skills/auto\|auto]] (architect pass) |
| 8 | `estimate-issued` | token-guard | broadcast | `input_total`, `output_total`, `cost_total_usd`, `confidence_band_pct`, `plan_present` | [[token-guard]] |
| 9 | `estimate-auto-approved` | token-guard | broadcast | `cost_total_usd`, `cumulative_cost_usd`, `budget_cap_amount`, `budget_cap_currency`, `policy_event_id` | [[token-guard]] (AutoPolicy path) |
| 10 | `human-gate-decision` | orchestrator | broadcast | `gate` (`budget`/`confidence`/`roi`/`loop`/`toolchain`/`prohibited-assumption`), `decision` (`approve`/`revise`/`escalate`/`abort`/`proceed`), `trigger_event_id` (or null), `human_decision_path` | [[../../capabilities/skills/auto\|auto]] / `/critical-human-gate` |
| 11 | `spec-created` | spec-writer | broadcast | `spec_id`, `idea_id`, `artifact_path` | [[../../capabilities/skills/auto\|auto]] / `/spec-create` |
| 12 | `plan-created` | planner | broadcast | `spec_id`, `artifact_path`, `plan_steps_count`, `atomic_test_cases_count` | [[../../capabilities/skills/auto\|auto]] / `/spec-plan` |
| 13 | `toolchain-preflight-started` | orchestrator | broadcast | `stage` (`pre-implement`/`pre-test`), `dialects`, `required_tools` | [[toolchain-preflight]] callers |
| 14 | `toolchain-preflight-result` | orchestrator | broadcast | `stage`, `present`, `missing`, `suggested_commands` | [[toolchain-preflight]] callers |
| 15 | `toolchain-gate-decision` | orchestrator | broadcast | `stage`, `decision` (`install`/`human-install`/`defer`), `missing`, `commands`, `human_decision_path` | [[toolchain-preflight]] callers |
| 16 | `toolchain-install-complete` | orchestrator | broadcast | `stage`, `status` (`installed`/`failed`), `command`, `installed` (re-detected versions), `tools_used_path` | [[toolchain-preflight]] callers |
| 17 | `implement-started` | implementer | broadcast | `spec_id`, `scope` (wave/story/enabler) | [[../../capabilities/skills/auto\|auto]] / `/spec-implement` |
| 18 | `implement-completed` | implementer | broadcast | `spec_id`, `scope`, `files_changed`, `confidence_pct` | [[../../capabilities/skills/auto\|auto]] / `/spec-implement` |
| 19 | `test-started` | verifier | broadcast | `spec_id` | [[../../capabilities/skills/auto\|auto]] / `/spec-test` |
| 20 | `test-completed` | verifier | broadcast | `spec_id`, `verdict` (`APPROVED`/`CHANGES_NEEDED`/`TOOLCHAIN_DEFERRED`), `passed`, `failed`, `verdict_path` | [[../../capabilities/skills/auto\|auto]] / `/spec-test` |
| 21 | `review-produced` | verifier | broadcast | `spec_id`, `review_path`, `findings_count` | [[../../capabilities/skills/auto\|auto]] / `/spec-review` |
| 22 | `remember-stored` | butler | broadcast | `entry_ids`, `summary` | [[butler]] (every remember) |
| 23 | `session-closed` | butler | broadcast | `session_id`, `summary` | [[butler]] (run close) |

Beyond the spine, token accounting adds `actual-recorded` (and
`calibration-update`) once harness/API actuals exist (see those kinds below).

### Naming compatibility (prior kinds retained)

This canonical taxonomy **supersedes/extends** the earlier names; the prior
kinds remain valid so existing logs still parse. Equivalences:

| Canonical kind | Retained prior kind(s) (still accepted) |
|--|--|
| `architecture-pass-complete` | `architecture-pass-completed` |
| `specialist-brief-created` | `technical-brief-issued`, `ux-brief-issued`, `security-brief-issued`, `infrastructure-brief-issued` (one per domain; encode the domain in `brief_type`) |
| `implement-completed` | `implement-complete` |
| `test-completed` | `test-verdict` |
| `review-produced` | `review-complete` |
| `human-gate-decision` | `human-gate-triggered` + `human-gate-resolved` (the decision event records the resolved choice; the trigger may still be emitted for the pause) |

New emitters SHOULD use the canonical name; readers MUST accept either form.

The backchannel is not a full transcript; the trace files are. Backchannel
events are compact facts that let humans and tools reconstruct the lifecycle
without opening every trace artifact.

### `brief-issued`

Emitter: [[butler]]. Direction: `broadcast`.

Indicates Butler delivered a brief-mode context pack. Other agents can use
this to know which memory entries are already in their consumer's context.

```json
"payload": {
  "topic": "SPEC-007 - token guard refactor",
  "entry_ids": ["DEC-012", "PAT-004", "INC-003"],
  "pack_tokens_est": 420
}
```

### `brief-consumed`

Emitter: any agent. Direction: `butler`.

Lets Butler track which entries were actually useful. Optional - agents that
do not bother to emit this are still well-behaved.

```json
"payload": {
  "brief_event_id": "BC-00042",
  "entries_used": ["DEC-012", "INC-003"]
}
```

### `remember-stored`

Emitter: [[butler]]. Direction: `broadcast`.

Indicates Butler wrote (or updated) one or more memory entries.
`entry_ids` may be empty when nothing was retained.

```json
"payload": {
  "entry_ids": ["INC-004", "PAT-005"],
  "summary": "Captured backchannel viewer omission as INC-004; reusable JSONL append pattern as PAT-005."
}
```

### `estimate-issued`

Emitter: [[token-guard]]. Direction: `broadcast`.

A fresh budget table has been printed and is awaiting human decision.

```json
"payload": {
  "input_total": 64500,
  "output_total": 32100,
  "cost_total_usd": 4.85,
  "confidence_band_pct": 30,
  "plan_present": false
}
```

For specs that include any `local-strong` / `local-fast` steps, set
`cost_total_usd` to the hosted-only subtotal and add
`local_steps_token_total` to the payload.

### `estimate-approved`

Emitter: [[token-guard]] (on behalf of the human). Direction: `broadcast`.

The human approved the most recent `estimate-issued` for this spec.

```json
"payload": {
  "approved_total_usd": 4.85,
  "approved_input": 64500,
  "approved_output": 32100
}
```

### `auto-policy-approved`

Emitter: [[token-guard]] or orchestrator. Direction: `broadcast`.

The human approved an upfront auto budget policy for an idea or auto run.

```json
"payload": {
  "budget_cap_amount": 200,
  "budget_cap_currency": "USD",
  "confidence_threshold_pct": 95,
  "silent": true,
  "assume": true
}
```

### `estimate-auto-approved`

Emitter: [[token-guard]]. Direction: `broadcast`.

A token estimate was covered by a previously approved AutoPolicy, so auto mode
continued without asking again.

```json
"payload": {
  "cost_total_usd": 4.85,
  "cumulative_cost_usd": 12.35,
  "budget_cap_amount": 200,
  "budget_cap_currency": "USD",
  "policy_event_id": "BC-00046"
}
```

### `auto-policy-cap-exceeded`

Emitter: [[token-guard]] or orchestrator. Direction: `broadcast`.

The updated estimate exceeded the approved AutoPolicy budget cap and auto mode
must pause for the human.

```json
"payload": {
  "cost_total_usd": 230.40,
  "budget_cap_amount": 200,
  "budget_cap_currency": "USD",
  "over_by_usd": 30.40,
  "policy_event_id": "BC-00046"
}
```

### Lifecycle coordination events

Emitter: orchestrator or the responsible lifecycle agent. Direction:
`broadcast`.

These event kinds use a compact shared payload shape unless a more specific
schema is listed elsewhere (see the canonical-spine table for required payload
keys per kind):

- `trace-session-created`
- `auto-policy-parsed`
- `idea-interrogation-started`
- `idea-interrogation-completed`
- `specialist-brief-created` (canonical; `brief_type` distinguishes the domain)
- `technical-brief-issued`, `ux-brief-issued`, `security-brief-issued`,
  `infrastructure-brief-issued` (retained prior per-domain kinds)
- `architecture-pass-complete` (canonical; `architecture-pass-completed` retained)
- `spec-created`
- `plan-created`
- `implement-started`
- `implement-completed` (canonical; `implement-complete` retained)
- `test-started`
- `test-completed` (canonical; `test-verdict` retained)
- `review-produced` (canonical; `review-complete` retained)
- `human-gate-decision` (canonical; `human-gate-triggered` / `human-gate-resolved` retained)
- `session-closed`

```json
"payload": {
  "stage": "architecture",
  "artifact_paths": ["architecture/c4-context.mmd", "architecture/guardrails.md"],
  "confidence_pct": 97,
  "summary": "Container diagram, guardrails, and quality gates created."
}
```

For `test-verdict`, include `passed`, `failed`, and `verdict_path` when
available. For `spec-created` and `plan-created`, include `spec_id` and the
primary artifact path. For `implement-started`, include the wave/story/enabler
scope when implementation is parallelized.

### Toolchain events

Emitter: orchestrator, implementer, verifier, or infrastructure implementer.
Direction: `broadcast`.

`toolchain-preflight-started` records the derived required tool list before
detection:

```json
"payload": {
  "stage": "pre-implement",
  "dialects": ["frontend-react", "backend-nodejs"],
  "required_tools": ["git", "node", "pnpm"]
}
```

`toolchain-preflight-result` records what detection found:

```json
"payload": {
  "stage": "pre-test",
  "present": {"git": "2.45.0"},
  "missing": ["python"],
  "suggested_commands": ["winget install Python.Python.3.12"]
}
```

`toolchain-gate-decision` records the human's choice and links to the trace
decision:

```json
"payload": {
  "stage": "pre-test",
  "decision": "install",
  "missing": ["python"],
  "commands": ["winget install Python.Python.3.12"],
  "human_decision_path": "Traces/Session-.../HumanDecisions.md"
}
```

`toolchain-install-complete` records the post-install result: the command run,
the result status, and the re-detected version. Use `status: "failed"` when the
command was approved but did not complete.

```json
"payload": {
  "stage": "pre-test",
  "status": "installed",
  "command": "winget install Python.Python.3.12",
  "installed": {"python": "3.12.10"},
  "tools_used_path": "Traces/Session-.../ToolsUsed.md"
}
```

Worked example - human approved a Python install at the pre-implement gate:

```text
toolchain-gate-decision  -> payload.decision="install", missing=["python"],
                            commands=["winget install Python.Python.3.12"]
toolchain-install-complete -> payload.command="winget install Python.Python.3.12",
                            status="installed", installed={"python":"3.12.10"}
```

### `estimate-aborted`

Emitter: [[token-guard]] (on behalf of the human). Direction: `broadcast`.

The human aborted. The reason is captured verbatim and is the highest-signal
input to a future [[butler]] `incident` entry.

```json
"payload": {
  "reason": "scope too large - revisit after splitting spec"
}
```

### `human-gate-triggered`

Emitter: orchestrator or any agent. Direction: `broadcast`.

An agent reported confidence below the configured threshold and lifecycle
progression is paused until the human resolves the gate.

```json
  "payload": {
    "agent": "planner",
    "confidence_pct": 91,
    "threshold_pct": 95,
    "reason": "Unclear data migration path",
    "proposed_next_action": "revise plan"
  }
```

### `human-gate-resolved`

Emitter: orchestrator or gate skill. Direction: `broadcast`.

The human resolved a `human-gate-triggered` event.

```json
"payload": {
  "trigger_event_id": "BC-00042",
  "decision": "approve",
  "notes": "Proceed with migration risk accepted."
}
```

### `human-gate-decision` (canonical)

Emitter: orchestrator or gate skill. Direction: `broadcast`.

The single canonical record of any human gate outcome (budget, confidence, ROI,
loop, toolchain, prohibited-assumption). It supersedes the
`human-gate-triggered` + `human-gate-resolved` pair (both retained): the pause
may still emit `human-gate-triggered`, but the resolved choice is recorded as
`human-gate-decision`.

```json
"payload": {
  "gate": "toolchain",
  "decision": "install",
  "trigger_event_id": "BC-00042",
  "human_decision_path": "Traces/Session-.../HumanDecisions.md",
  "notes": "Approved Python install at pre-implement gate."
}
```

Allowed `gate` values: `budget`, `confidence`, `roi`, `loop`, `toolchain`,
`prohibited-assumption`. Allowed `decision` values: `approve`, `revise`,
`escalate`, `abort`, `proceed`, plus the toolchain triple
(`install`/`human-install`/`defer`).

### `actual-recorded`

Emitter: [[token-guard]]. Direction: `broadcast`.

One event per lifecycle step or agent invocation after Butler/Token Guard read
`Traces/Session-*/TokenUsage.md`. Actuals are only actual when the harness or
API reported them. If the harness did not expose usage, emit the event with
`source: "unavailable"` and an `unavailable_reason`; do **not** invent counts.

```json
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
```

Allowed `source` values: `harness-reported`, `api-usage`, `manual-meter`,
`unavailable`.

### `calibration-update`

Emitter: [[token-guard]]. Direction: `broadcast`.

A calibration pass changed formula constants in [[token-budget]].

```json
"payload": {
  "sample_size": 23,
  "updated": {
    "step_multiplier.plan": 0.95,
    "step_multiplier.implement": 1.80,
    "confidence_band_pct": 22
  }
}
```

### `coordination-note`

Emitter: any agent. Direction: any.

Free-form payload for ad-hoc cross-agent messages that do not fit the
existing taxonomy. Use sparingly - if you find yourself emitting the same
shape twice, propose a new kind.

```json
"payload": {
  "note": "Token Guard widened band on SPEC-007; Butler please flag if you write a fresh INC-* about it."
}
```

---

## ID allocation

`.KCC/tools/backchannel-append.ps1` performs this allocation; the rule is
documented here so the helper's behavior is auditable. Allocation rule, in
order:

1. Read the **last line only** of `coordination/backchannel.jsonl` (use
   `Get-Content -Tail 1` on Windows, `tail -n 1` elsewhere).
2. Parse it as JSON. Extract `id`.
3. Strip the `BC-` prefix, parse the remainder as a base-10 integer,
   increment by 1, zero-pad to 5 digits, re-prefix with `BC-`.
4. If the file is empty (zero bytes) or has no readable last line, start at
   `BC-00001`.
5. If the last line fails to parse (see `## Failure modes`), fall back to
   the recovery rule.

IDs are monotonic, never reused, never reordered. Lines are written in
strict timestamp order.

---

## Failure modes and recovery

The backchannel is robust to a single bad line.

### Corrupt line (invalid JSON)

A reader encountering a line that does not parse as JSON **skips it and
logs a warning** to its own output (not to the backchannel - that would
risk a cascade). It continues to the next line.

For ID allocation, if the last line is corrupt, the writer scans the last
~50 lines from the end and uses the highest `id` it can successfully parse.
If none parse, it writes `BC-00001` to a new line and proceeds (the corrupt
tail is left in place - never edit or truncate).

### Missing required field

A reader treats an event missing any required top-level field as corrupt
and skips it (same as the JSON-parse case). Writers MUST include every
required field; defaulting `session` and `spec` to `null` is fine.

### Concurrent appends

JSONL appends are individually atomic at the OS level if each line is
written with a single write syscall and ends in `\n`. Agents at agent-scale
write rates (one line per turn) do not need explicit locking. If a future
high-throughput agent emerges, add `fcntl`/`flock`-style locking at that
time.

### Partial write (truncated last line)

If a writer crashes mid-append, the last line may be incomplete. Readers
detect this via JSON parse failure and skip; writers detect it via the
recovery rule above and allocate the next ID accordingly. The truncated
fragment stays in the file as a forensic breadcrumb.

---

## Viewer command

`.KCC/tools/show-backchannel.ps1` renders the JSONL into a human-readable
console table. `.KCC/tools/show-backchannel.sh` provides the native
macOS/Linux equivalent. Supported flags:

- `-Last N` - show the last N events (default 20)
- `-From <agent>` - filter by `from`
- `-Spec SPEC-NNN` - filter by `spec`
- `-Kind <kind>` - filter by `kind`
- `-Json` - emit filtered events as JSON

```powershell
powershell -ExecutionPolicy Bypass -File .KCC\tools\show-backchannel.ps1 -Last 20
powershell -ExecutionPolicy Bypass -File .KCC\tools\show-backchannel.ps1 -Kind approval -Spec SPEC-003
```

```bash
bash .KCC/tools/show-backchannel.sh --last 20
bash .KCC/tools/show-backchannel.sh --kind estimate-approved --spec SPEC-003
```

The viewer is read-only and writes no output files.

---

## Constraints

- The file is **append-only**. No agent may rewrite, reorder, or truncate
  existing lines.
- Events are facts about the past. They are never updated; superseding
  events are written as new lines that reference the prior `id` in their
  payload if needed.
- The protocol is intentionally minimal. Resist the urge to add fields -
  prefer richer payload structures over top-level field growth.
