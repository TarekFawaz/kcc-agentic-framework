---
title: kcc-run Protocol
aliases: [kcc-run, deterministic-driver]
tags: [framework/protocol, orchestration]
created: 2026-09-21
updated: 2026-09-21
version: 1.0.0
status: active
copyright: "KCC framework (c) 2026 Tarek Fawaz"
---

# kcc-run (deterministic driver)

`.KCC/tools/kcc-run.ps1|.sh` runs the `auto` lifecycle ([[auto-mode]]) from the
state table `.KCC/kernel/auto-states.json`. It never reads prose. Each state's
command goes to the harness **non-interactively**
(`continuity.start[harness]` + `{permission_mode}`; bypass-flag templates are refused).
It moves on only when the state's exit-check script passes.

## CLI

`kcc-run -Input "<idea|path|IDEA-ID|SPEC-ID|all>" [-Silent -Assume] [-Accuracy NN] [-Budget NN -Currency USD] [-Parallel] [-Harness claude|codex|opencode|generic] [-Resume] [-Answer <choice>] [-From <id>] [-Only <id>] [-DryRun] [-Json] [-MaxAttempts N] [-RemoteUrl url] [-Note text]`.
In bash, use `--kebab-case` names. Giving only one of silent and assume exits 2.
With no arguments and an existing `run.json`, it behaves like `-Resume`.
`-DryRun` prints every planned state x spec x wave and changes nothing.
`-Json` prints one status object `{status, state, state_name, spec, wave, gate, log, reason}`.

## Exit codes

| Code | Meaning |
|--|--|
| 0 | DONE, dry run, or `-Only` finished |
| 2 | Usage or environment error (bad arguments, missing harness template, bypass flag, a check exited 2) |
| 4 | PAUSED at a human gate |
| 5 | SUSPENDED: usage limit. It wrote `kcc-checkpoint -Reason limit-hard` and armed `kcc-limit-watch -Arm -Command "<kcc-run -Resume>"` |
| 6 | STOPPED or ABORTED (the reason is in `run.json` and in the `session-closed` event) |

## Loop (per unit = state x spec x wave)

1. Apply the `only_in` and `skip_if_flag` filters.
2. Idempotent skip: if the exit check already passes, the unit is done. Wave units and approval-gated units are never skipped this way.
3. Dispatch the preamble plus the rendered command (`{input} {IDEA} {SPEC} {WAVE} {silent_assume} {parallel} {fasttrack} {depthlevel} {TOOLS}`). A retry adds the previous violations. For the S1 `interactive_in` states, the driver prints the command and opens an `interactive` gate (`done` / `abort`) instead.
4. If the harness output matches a usage-limit pattern (the same patterns as `kcc-limit-watch`), the run is SUSPENDED.
5. Run the check, then its `then` check. Exit 0 = done. Exit 1 = retry, up to `max_attempts`, then the `loop` gate. Exit 3 = the state's gate, or `quality-deferred-on-exit-3`. A REVIEW failure goes to state 15 for that spec (`on_fail_goto`) and counts toward the attempts.
6. When a unit completes, emit its `event` (or `run-state-completed`). Checkpoint `spec-reviewed` after REVIEW. Before the first attempt of each wave, write a `manual` baseline checkpoint, because `check-wave-scope` diffs against the newest restore point.

Specs run in `ROADMAP.md` Order, sequentially in v1 even within an order slot.
Waves come from `plan.md -> ## Waves` (`parallelization.md` as the fallback).

## Gates

Each gate is a file, `coordination/gates/GATE-NNN.md`, and opening one emits
`human-gate-triggered`. On a TTY without `-Json` the driver asks inline;
otherwise it exits 4. `-Answer` checks the answer against
`auto-states.json -> gates`, then records it in the gate file, the backchannel
(`human-gate-decision` with `trigger_event_id`) and the trace's `HumanDecisions.md`.

| Answer | Effect |
|--|--|
| `abort` | ABORTED |
| `approve` (budget) | Emits `estimate-approved`, then runs the check |
| `revise` / `escalate` | Resets the attempts and re-runs the state (ROI and CONFIRM re-run the previous command state) |
| `increase` + `-Budget` | Raises the cap and re-checks |
| `install` | Sends an install prompt to the harness, then re-checks |
| `init-local` / `connect-remote` / `skip` | Runs `repo-bootstrap -Apply <answer>` |
| `defer` / `accept-deferred` / `sequential` / `confirm` / `proceed` | Marks the unit done |

Budget in S2: emits `auto-policy-approved-unlimited`. Budget in S3: the latest
`estimate-issued` amount (`cost_total_usd`, ...) that the driver did not emit
itself is compared with the cap. At or under the cap it emits
`auto-policy-approved-bounded`; otherwise it opens the `budget-cap` gate.

## Files, settings, limits (v1)

- `coordination/run/run.json` holds the policy, input, idea, specs, pointer, attempts and pending gate. Older runs are kept as `run-<ts>.json`.
- `coordination/run/logs/state-{id}-{spec}-{attempt}.log` holds harness output; `check-*.out` holds check output.
- `settings.json -> run`: `max_attempts` (3), `state_timeout_minutes` (60; after that the harness is killed and the attempt fails), `harness`.
- No parallel lanes inside the driver: one `kcc-run` is one sequential run. `kcc run` (the CLI) schedules the specs by dependency and runs independent ones in parallel lanes ([[parallel-lanes]]), using `-Until <id>` to stop the shared run after SPECS.
- Under `-Fasttrack` on Claude Code, each dispatch's orchestrator session runs on `settings.json -> run.orchestrator_model` / `orchestrator_effort` (default `claude-haiku-5-5`, `low`; a bare `haiku`/`sonnet`/`opus` in an older `settings.json` is mapped to the pinned 5.5 ID, because the alias can still resolve to Haiku 4.5, which has no auto mode) and spawns the agents as subagents as usual. For the implementer state the prompt tells it to spawn the implementer on `run.escalation_model` (default `claude-sonnet-5-5`) when the wave's Complexity in `plan.md` is `high`/`extra-high`, or on a retry, and `model-escalated` is emitted. `run.fasttrack_direct: true` instead starts a state that has `agent_fasttrack` as that agent (`claude --agent <name>`), with no orchestrator above it.
- Full runs add one sentence to every dispatch telling the orchestrator to brief and remember with the butler (CR-8); `run.butler: off` removes it. Fasttrack names the butler in the IDEA and CLOSE commands instead, in memory-only mode.
- `-Fasttrack` skips the states whose `skip_if_flag` lists `fasttrack` (a flag name or a list in `auto-states.json`), uses a state's `command_fasttrack` when it has one, and emits `fasttrack-approved` after `auto-policy-parsed` (that event opens `check-impl-lock`). `-DepthLevel N` (1-5) is stored in `run.json` and rendered as `--depthlevel N` below 5; `-Fasttrack` alone sets 2. Both default to off/5 for runs that predate them.
- `{TOOLS}` for the preflight is derived from dialect names in the spec, `plan.md` and the TechnicalDecisionBrief.
- A resume command with paths containing spaces depends on `kcc-limit-watch` quoting.
