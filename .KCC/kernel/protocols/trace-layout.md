---
# Functional fields
description: Folder convention for agent traces and per-session MOCs.
inputs: A session title and start datetime, produced when an agent begins a turn.
outputs: A `Traces/Session-{slug}-{datetime}/` folder with the required seven trace files plus a `session-{slug}-{datetime}.md` MOC.

# Obsidian metadata
title: "Trace Folder Layout Protocol"
aliases:
  - trace-layout
  - traces convention
tags:
  - framework/protocol
  - trace
  - documentation
created: 2026-05-24
updated: 2026-06-07
version: 2.3.0
status: active
copyright: "KCC framework (c) 2026 Tarek Fawaz"
homepage: "https://tikasway.dev/kcc"
license: "Licensed under the terms in LICENSE"
---

# Trace Folder Layout

Every model-backed agent turn is traced. Deterministic helper commands such as
adapter sync, initialization, and backchannel viewing are not agent traces by
themselves; when they are run during an agent session, record them in that
session's `ToolsUsed.md` or `Actions.md`.

Traces live under the top-level `Traces/` directory; each user session gets its
own subfolder named `Session-{slug}-{datetime}/` containing a fixed set of
seven artifact files plus a per-session MOC called
`session-{slug}-{datetime}.md`.

Command output should not be written into `.KCC/kernel/`, `.KCC/capabilities/`, or generated
harness folders. Human-readable exports belong in `Traces/`, the relevant
spec/idea folder, or the console.

This protocol replaces the v1 `Traces/README.md` convention with an
Obsidian-native MOC at `Traces/traces.md` and a parent MOC inside every
session folder.

---

## Ownership and lifecycle

Tracing has a single, always-on owner: the **butler** agent is the **trace
custodian**. Tracing is **per-run, auto-owned** - exactly one
`Traces/Session-{slug}-{datetime}/` folder is created per run, where a "run" is
one `auto` invocation (HOTL) or one human working session of individual skill
use (HITL). This holds for HITL individual-skill use too: the first
`butler-brief` of a working session creates the session folder, and every
subsequent `butler-remember` in that same run appends to it. No other agent or
skill is responsible for creating trace folders; previously the seven-file
convention was documented but unowned, so `Session-*` folders were never
created.

Butler already wraps every agent turn - `butler-brief` at the start and
`butler-remember` at the end - so it is the natural always-on custodian rather
than asking every capability agent to remember to append.

### Session creation (butler-brief, at run start)

When `butler-brief` runs, butler **ensures the active session exists**:

1. Read the active-session pointer in `coordination/orchestrator.json` (e.g.
   `"active_session": "Traces/Session-{slug}-{datetime}"`, plus a
   `"active_session_id"`).
2. If there is no active session pointer, or the pointer is stale for the
   current run (different run / no live folder), butler copies
   `Traces/_session-template/` to a new
   `Traces/Session-{slug}-{datetime}/` folder. The **slug** derives from the
   spec / idea / topic in scope; the **datetime** is the current date/time
   available to the agent at runtime (ISO-8601, e.g. `2026-06-05T0930`).
3. Butler records the active session path + id back into
   `coordination/orchestrator.json` (`active_session`, `active_session_id`).
4. The copied `session-{slug}-{datetime}.md` MOC is renamed from the
   template's `session-template.md` and its frontmatter is populated
   (`session-id`, `date`, `agent`, `spec`, `status: active`).

Ensuring the folder exists is cheap and idempotent: if the active session is
already live for this run, butler-brief does nothing beyond confirming the
pointer.

### Per-turn appends (butler-remember, at turn end)

When `butler-remember` runs at the end of each agent turn, butler **appends**
that turn's telemetry to the seven artifact files in the **active** session
folder (resolved from the `coordination/orchestrator.json` pointer):

- `Actions.md` - what the agent did this turn.
- `Decisions.md` - the agent's decisions + rationale.
- `ToolsUsed.md` - tools / commands invoked.
- `Handovers.md` - any handover envelopes sent or received.
- `HumanActions.md` - what the human did (answers, approvals).
- `HumanDecisions.md` - human approve / revise / abort / escalate at gates.
- `TokenUsage.md` - token counts for the turn (from [[token-guard]] where
  available).

Each append is **timestamped** and **names the agent** whose turn it was.
Butler **only ever appends** - it never rewrites or deletes prior entries.
After appending, butler updates the per-session MOC
`session-{slug}-{datetime}.md` (linking the seven files and the running
summary) and adds / refreshes the session's row in `Traces/traces.md`.

### Tracing is NOT memory

Tracing and memory are **separate concerns** and must not be conflated:

| | Tracing | Memory |
|--|--|--|
| What | Full, raw session **telemetry** - every turn, every tool call, every gate decision. | **Curated, reusable** knowledge entries. |
| Where | `Traces/Session-{slug}-{datetime}/` (seven files). | `memory/{type}/{id}.md` + `memory/index.json`. |
| Volume | Append everything that happened this run. | Conservative - only non-obvious + reusable items. |
| Owner | butler (trace custodian). | butler (sole memory writer). |

`butler-remember` does **both** jobs on each turn, but they are independent
steps: the trace append captures what happened (always), and the memory triage
keeps only the small subset that is non-obvious and reusable (usually nothing).
Mode D (accuracy calibration) is likewise unaffected by trace custody.

---

## Top-level shape

```text
Traces/
|-- traces.md
|-- _session-template/
|   |-- session-template.md
|   |-- Decisions.md
|   |-- Handovers.md
|   |-- Actions.md
|   |-- ToolsUsed.md
|   |-- HumanActions.md
|   |-- HumanDecisions.md
|   `-- TokenUsage.md
|-- Session-onboarding-2026-05-24T0930/
|   |-- session-onboarding-2026-05-24T0930.md
|   |-- Decisions.md
|   |-- Handovers.md
|   |-- Actions.md
|   |-- ToolsUsed.md
|   |-- HumanActions.md
|   |-- HumanDecisions.md
|   `-- TokenUsage.md
`-- Session-spec-007-implement-2026-05-25T1415/
    `-- ...
```

The `_session-template/` folder name starts with an underscore so it sorts
to the top of any file listing and visually reads as a template, not a real
session. Do not put live trace content there.

---

## The seven required files

Inside every `Session-{slug}-{datetime}/` folder:

| File                | Purpose                                                          |
|--|--|
| `Decisions.md`      | Agent-driven decisions: what was decided, why, alternatives.     |
| `Handovers.md`      | Handover envelopes sent and received this session.               |
| `Actions.md`        | Concrete actions taken (file writes, commits, agent invocations).|
| `ToolsUsed.md`      | Each tool call: tool, args summary, outcome.                     |
| `HumanActions.md`   | Things the human did inside or alongside the session.            |
| `HumanDecisions.md` | Decisions the human made (approvals, vetoes, scope changes).     |
| `TokenUsage.md`     | Token-guard accounting: estimate vs. actual, per agent invocation.|

All seven exist from the moment the session starts (copied as stubs from
`_session-template/` by butler at run start - see
[[#ownership-and-lifecycle|Ownership and lifecycle]]). Butler appends to them
via `butler-remember` as the session progresses; it never rewrites prior
entries.

**These exact seven filenames are mandatory and non-negotiable.** Inventing a
different scheme (e.g. `AgentReports.md`, `Summary.md`, `OpenQuestions.md`) in
their place is a conformance failure - the run-close gate
(`check-run-conformance`, TRACE-001) checks for the seven by name. Extra files
are allowed only as **additions** alongside the seven, never as substitutes, and
the seven must be genuinely populated (the blog pilot shipped custom files and
omitted `Decisions.md`/`Handovers.md`/`HumanActions.md`/`TokenUsage.md`).

## TokenUsage actuals contract

Every model-backed agent turn must return a compact token-usage block for
Butler to append into `TokenUsage.md`. Actual counts are accepted only when
the harness or API exposes usage metadata. If the harness does not expose it,
the turn still records an explicit unavailable row; agents must not estimate
and label it as actual.

```yaml
- ts: 2026-06-07T10:15:42Z
  agent: planner
  stage: plan
  spec: SPEC-007
  model_class: strong-reasoning
  model: gpt-5
  estimate_event_id: BC-00044
  estimate_input_tokens: 14336
  estimate_output_tokens: 8602
  actual_input_tokens: 18200
  actual_output_tokens: 11100
  actual_total_tokens: 29300
  source: harness-reported
  unavailable_reason:
```

Allowed `source` values:

| Source | Meaning |
|--|--|
| `harness-reported` | The harness surfaced usage metadata for the turn. |
| `api-usage` | A direct API response surfaced usage metadata. |
| `manual-meter` | A trusted external meter or billing export supplied the counts. |
| `unavailable` | No reliable actual count was available; token fields are blank or `null`. |

When `source` is `unavailable`, `unavailable_reason` is required, for example:
`codex-cli-did-not-expose-usage`. Token Guard uses these rows for transparency
but excludes them from calibration math.

After Butler appends a row with actual counts, Token Guard emits
`actual-recorded` to the backchannel, linking the `estimate_event_id` where
available. If the row is unavailable, Token Guard may still emit
`actual-recorded` with `source: "unavailable"` so the gap is auditable.

---

## The per-session MOC: `session-{slug}-{datetime}.md`

A small index file that links to the seven artifacts above and captures
session-level metadata. This is the file a human opens first when reviewing a
session in Obsidian.

Required frontmatter:

```yaml
---
title: "Session: <chat title>"
session-id: Session-<slug>-<datetime>
date: 2026-05-24
agent: <primary agent name>
spec: SPEC-XXX | none
status: active | complete | aborted
copyright: "KCC framework (c) 2026 Tarek Fawaz"
homepage: "https://tikasway.dev/kcc"
license: "Licensed under the terms in LICENSE"
tags:
  - trace
  - session
  - lifecycle/<stage>
created: 2026-05-24
updated: 2026-05-24
---
```

Required body sections:

1. `## Summary` - one paragraph (filled in at session end).
2. `## Artifacts` - wikilinks to all seven files.
3. `## Key decisions` - top 3 decisions (links into `Decisions.md`).
4. `## Outcomes` - what shipped, what was deferred, follow-up specs created.

---

## The top-level MOC: `Traces/traces.md`

The landing page for traces. Lists every session subfolder with: Session ID,
Date, Title, primary Agent, key decisions summary. Also documents the layout
(this protocol) and the seven required files so a fresh reader can orient
without leaving the file.

Maintained by butler (the trace custodian) whenever it creates a session via
`butler-brief`. Each new session folder appends a row.

---

## Per-spec traces

A spec folder may have its own `traces/` subdirectory containing
`Session-{slug}-{datetime}/` folders that follow the same shape as the
top-level `Traces/` convention. Use this when the trace is tightly scoped to
one spec and you want it to travel with the spec folder.

The top-level `Traces/` remains the canonical, complete record. Per-spec
traces are duplicative (mirrored) or scoped (spec-only); decide per session.

---

## Why a fixed seven-file shape

- Predictability - humans and agents always know where to look for decisions
  vs. actions vs. tool calls.
- Auditability - token usage and human decisions are separated from routine
  action logs so post-hoc analysis is straightforward.
- Obsidian graph - fixed filenames mean cross-session backlinks such as
  `[[Decisions]]` resolve cleanly inside any session folder.

---

## Related

- Spec layout: [[spec-layout]]
- Obsidian standard: [[obsidian-standard]]
- Top-level traces MOC: [[../../Traces/traces|Traces MOC]]
- Session template: [[../../Traces/_session-template/session-template|Session MOC template]]
- Trace custodian: [[../../capabilities/agents/butler|butler]]
- Session creation: [[../../capabilities/skills/butler-brief|butler-brief]]
- Per-turn appends: [[../../capabilities/skills/butler-remember|butler-remember]]
