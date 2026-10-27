---
# Functional fields
description: DeepThinking mode: the few named, bounded analysis tasks that may run on the most capable model at xhigh/max effort, and the cost gate a human passes first.
inputs: A proposed deep task (agent, task id, why), the token-guard estimate, `kernel/models.json` (`deep` tier, `deep_tasks`, `deep_cost_observed`), `.KCC/settings.json -> deep`.
outputs: A human decision (approve at xhigh, approve at max, use strong, skip), the events `deep-proposed`, `deep-approved` or `deep-declined`, `deep-spawned`, `deep-completed`, and one analysis file.

# Obsidian metadata
title: "DeepThinking Protocol"
aliases:
  - deep-thinking
  - deep-mode
tags:
  - framework/protocol
  - orchestration
  - models
  - cost
created: 2026-10-16
updated: 2026-10-16
version: 1.0.0
status: active
copyright: "KCC framework (c) 2026 Tarek Fawaz"
---

# DeepThinking

The `deep` tier is the most capable model in the registry (Claude: `claude-fable-5-1`) at `xhigh` or
`max` effort. It is **not** an agent class and the router never picks it
([[model-routing]] stops at `strong`). An existing agent is spawned *on* it for one task, after a
human has seen what it will cost. Nothing else may use it.

## Two ways in

| Path | Who starts it | Tasks | Run limits |
|--|--|--|--|
| **Orchestrator** | the orchestrator, during `auto` and also under `--fasttrack`, when a catalogue trigger is met | the four named tasks | `max_per_run`, budget floor, no proposal in silent runs |
| **Human** | you, with `/deep <task or question>` at any time, in or out of a run | the four named tasks, or `human-directed` (any bounded question you name, run by the agent you pick) | none: you see the cost every time |

Both pass the same cost gate and both are recorded (`initiator` in every event).

## Why a gate

Measured on 2026-10-16 (`deep_cost_observed` in the registry): a one-word reply costs about **$0.80**
(41k tokens of session context), and a 400-word answer at `max` produced **10.7k output tokens**, mostly
thinking, for about $0.75. Output is about $48 per million tokens. A real deep task runs from a few to
tens of dollars, and `max` can spend several times what `xhigh` does on the same prompt.

## The task catalogue (closed list: `models.json -> deep_tasks`)

| Task id | Agent | Use it when | Output (analysis only, never `src/`) |
|--|--|--|--|
| `architecture-tradeoff` | `architect` | ONE decision with two or more viable options that is costly to reverse (data store, tenancy, consistency model, auth model, public API shape) in a `novel`/`specialised` domain, or the critic returned DRIFT twice on it | one ADR or Decisions-table row, <= 60 lines |
| `threat-model` | `security-analyst` | a CR-7 domain with no catalogue default (crypto scheme, authorisation model, regulated or personal data flow) | one threat model, <= 80 lines |
| `failure-root-cause` | `verifier` | a unit has failed review twice already (once at `strong`) and the cause is still unclear | a diagnosis note, <= 50 lines; the fix is then built by the normal implementer |
| `cross-spec-consistency` | `architect` | once per idea, before build, with four or more specs whose dependencies or shared data contradict | a conflict list with a proposed fix per conflict, <= 60 lines |
| `human-directed` | the agent the human picks (default `architect`) | only the human can start it, with `/deep`: any bounded analysis they name | an analysis file `docs/deep/DEEP-{date}-{slug}.md`, <= 80 lines |

The orchestrator never proposes `human-directed`, and never proposes deep for interrogation, specs, plans,
implementation, scaffolding, docs, routine review, the butler or the token-guard. A task id that is not in the
table is refused (`DEEP-003`), not improvised. A human who wants one of those deep uses `/deep` and says so.

## The gate (every spawn, no exceptions except pre-approval)

1. Emit `deep-proposed` (`initiator`: `orchestrator` | `human`, `agent`, `task`, `reason`, `est_usd_low`, `est_usd_high`).
   Estimate: `0.8 + output_tokens x 0.000048 + extra_input_tokens x 0.00002`, with the token-guard's
   output range for a <= N-line artifact; say it is an estimate.
2. Ask the human once (`AskUserQuestion`, or `/critical-human-gate` when the run is not interactive-capable).
   The question states the task, why `strong` is not enough, the estimate range, and (orchestrator path) how
   many deep calls this run has left. Under `--fasttrack` put the proposal into the single ASK round when the
   trigger is already known there; otherwise ask on its own. Options:
   - **Approve at xhigh** (recommended; effort `deep.default_effort`)
   - **Approve at max** (highest cost; the human picks it, nothing else may)
   - **Use strong instead** (Opus at `high`; records `deep-declined`, `fallback: strong`)
   - **Skip** (records `deep-declined`, `fallback: none`)
3. On approval emit `deep-approved` (`initiator`, `agent`, `task`, `effort`, `est_usd_high`, `approved_by: human`),
   then spawn with `model` set to the registry `deep` id (alias `fable` is accepted where only aliases are)
   and the chosen `effort`, then emit `deep-spawned` (`initiator`, `agent`, `task`, `model`, `effort`).
4. After the return emit `deep-completed` (`initiator`, `agent`, `task`, `actual_usd` and tokens from the
   `ActualTokenUsage` block). Record the spend in the token trace when traces are on.

One approval covers one spawn. A retry, or the same task on another unit, is a new proposal.

## Limits and special cases

- **Per run:** at most `deep.max_per_run` (default 2) orchestrator-started spawns; more is `DEEP-002`. A
  human's `/deep` is not counted: they approve each one.
- **Silent runs and unattended drivers:** no human is present, so no proposal is made and `strong` is used
  (`deep-declined`, `fallback: strong`, `approved_by: policy`). The exception is `deep.pre_approved_usd`
  greater than 0, which a human sets in settings: a spawn whose `est_usd_high` is at or under it is approved
  as `approved_by: pre-approved`. Default 0.
- **Direct runs** (`kcc-run` worker states run as the agent with no orchestrator above them): there is no one
  to ask, so no proposal is made. `/deep` still works in a chat session.
- **`--fasttrack`:** the orchestrator may propose deep like in a full run, and the gate still asks. Fast track
  exists to be cheap, so propose only when a trigger is clearly met, not "to be safe".
- **Budget gate:** a deep spawn counts against `--budget` like any spawn. Under 20% budget left, the
  orchestrator proposes nothing; a human `/deep` is still allowed.
- **Harness without a `deep` entry** (Codex, OpenCode, Ollama today): the request becomes `strong` at `high`;
  no deep gate, no event.
- **`deep.enabled: false`** turns the mode off for the workspace, both paths.

## Checked, not trusted

`check-run-conformance -Scope deep` (included in `all`) reads the backchannel: `DEEP-001` a `deep-spawned`
with no unused `deep-approved` for the same agent and task; `DEEP-002` more spawns than `max_per_run`;
`DEEP-003` a task id outside the catalogue. The count in `DEEP-002` skips events with `initiator: human`. `kcc models --check` does **not** probe the deep id (a probe costs
about $0.80); use `kcc models --check --deep` and accept that.

## Related

- [[model-routing]] (tiers up to `strong`), [[confidence-gate]], [[token-budget]], [[backchannel]]
- Human entry point: the `/deep` skill (`capabilities/skills/deep.md`)
- Registry: `kernel/models.json`; orchestrator spawn rule 11: `kernel/templates/orchestrator.md`
