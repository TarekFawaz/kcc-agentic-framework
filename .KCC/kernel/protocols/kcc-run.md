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
| 7 | NEEDS ATTENTION: only under `--silent --assume`, which never pauses. A spec could not continue and was parked as an open item (a lane stops at once with 7; a bare multi-spec run goes on with the next spec and ends with 7). The items are in `coordination/NeedsAttention.md`; `kcc run` finishes every other spec, closes the run, and exits 7 instead of 0 |

## Loop (per unit = state x spec x wave)

1. Apply the `only_in` and `skip_if_flag` filters.
2. Idempotent skip: if the exit check already passes, the unit is done. Wave units and approval-gated units are never skipped this way.
3. Dispatch the preamble plus the rendered command (`{input} {IDEA} {SPEC} {WAVE} {silent_assume} {parallel} {fasttrack} {depthlevel} {TOOLS}`). A retry adds the previous violations. For the S1 `interactive_in` states, the driver prints the command and opens an `interactive` gate (`done` / `abort`) instead.
4. If the harness output matches a usage-limit pattern (the same patterns as `kcc-limit-watch`), the run is SUSPENDED.
5. Run the check, then its `then` check. Exit 0 = done. Exit 1 = retry, up to `max_attempts`, then the `loop` gate. Exit 3 = the state's gate, or `quality-deferred-on-exit-3`. A REVIEW failure goes to state 15 for that spec (`on_fail_goto`) and counts toward the attempts.
   - **FIX and blocked bugs.** The FIX state's check (`internal:no-open-bugs`) counts `open` and `fixing` Bug items as `BUG-OPEN`. A Bug with `Status: blocked` (it needs a human ruling, with a `## Ruling needed` section) is `BUG-006` (owner human): when only blocked Bugs are left, the driver opens the `ruling` gate at once, before dispatching the implementer and without using an attempt, so a fix that cannot proceed is never retried.
   - **TEST: full pass, then scoped re-verification.** The first TEST of a spec is a full verification. When a `review.md` with the verdict `CHANGES_NEEDED` exists, the next TEST prompt carries `RE-VERIFICATION MODE`: re-verify only the Bug items whose Status changed and the ACs and Test IDs whose files changed since the commit recorded in that `review.md` (`commit:`), always run `quality-gate` and `check-traceability`, and copy the other verdict rows unchanged (`agents/verifier.md` -> *Re-verification mode*). `model-selected` carries `pass: full|scoped`.
   - **At most two full verifier passes per spec** (counter `full:SPEC-ID` in `run.json -> attempts`). A third full pass is not run: the driver opens the `loop` gate (CR-3) listing the still-open Bug items; `revise` or `escalate` grants exactly one more full pass.
   - **A deferred scanner is not a reason to loop (QUALITY_DEFERRED / TOOLCHAIN_DEFERRED).** The verifier writes `QUALITY_DEFERRED` when `quality-gate` exits 3 (a scanner such as semgrep is missing) and everything else was verified; `TOOLCHAIN_DEFERRED` when the build/test toolchain was missing and the install was deferred. The driver reads both, hyphenated or lower case, as the same class. When the gate (or the toolchain gate) is accepted for a spec, the driver records `defer:SPEC-ID` in `run.json -> attempts` and emits `deferral-accepted` (spec, verdict, tools, checks, by). A REVIEW whose verdict is deferred and whose bugs are all `fixed`, `verified` or `wontfix` is then closed as deferred-accepted: no FIX, no second TEST, no second full pass, state 17 done, and the lane goes on to its end. With a bug still `open` or `blocked` the implementer has work, so it goes to FIX as for CHANGES_NEEDED. A `QUALITY_DEFERRED` review makes the next TEST a scoped re-verification (never a full pass), so a deferred-only outcome never uses the second full pass. The last message of the run (and `closed.md`) says `DEFERRED, NOT A PASS` for each such spec with the missing tool, the install command (`toolchain-preflight`) and the command that re-runs the gate (`quality-gate -Spec SPEC-ID`).
   - **FIX with nothing to do is skipped.** When the spec goes back to FIX (`on_fail_goto`) and has no `open`/`fixing`/`blocked` Bug item and the violations that sent it back name no `implementer` or `infrastructure-implementer` owner (for example a `verifier`-owned REV-* finding), no agent runs: the unit completes as skipped (`fix-completed` with `skipped: true`) and the flow goes on to TEST. A manual `--from 19` or `--only 19` (no violations) still runs the implementer.
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
| `ruling` gate: `revise` / `escalate` | Sets each blocked Bug item back to `open`, appends the answer under `## Ruling` in the Bug file, and re-runs FIX with the `-Note` as the ruling (no note: the recommended option of the `## Ruling needed` section applies). A note that states the human's approval (for example "Option A approved: amend D10") is the recorded human decision that lets the implementer make an otherwise architect-owned edit such as the Decisions table |
| `ruling` gate: `waive` | Sets each blocked Bug item to `wontfix` (a human decision, recorded in the Bug file) and re-checks |
| `increase` + `-Budget` | Raises the cap and re-checks |
| `install` | Sends an install prompt to the harness, then re-checks |
| `init-local` / `connect-remote` / `skip` | Runs `repo-bootstrap -Apply <answer>` |
| `defer` / `accept-deferred` / `sequential` / `confirm` / `proceed` | Marks the unit done |

A `--silent --assume` run never pauses: see *Silent runs never stop for a human* below. A run without `--silent --assume` keeps every blocking gate (exit 4).

Budget in S2: emits `auto-policy-approved-unlimited`. Budget in S3: the latest
`estimate-issued` amount (`cost_total_usd`, ...) that the driver did not emit
itself is compared with the cap. At or under the cap it emits
`auto-policy-approved-bounded`; otherwise it opens the `budget-cap` gate.

## Silent runs never stop for a human

Under `--silent --assume` nobody answers a prompt, so the driver never pauses (exit 4). Every gate is answered by policy with the safest
continuing choice; the answer is written to the gate file, emitted as `human-gate-decision` (`answered_by: "policy"`, `note`), and an
item is appended to `coordination/NeedsAttention.md`. A run without `--silent --assume` keeps today's blocking gates.

| Gate | Policy answer | NeedsAttention status |
|--|--|--|
| `ruling` | `revise`: the implementer applies the recommended option of the Bug file's `## Ruling needed` (at most twice per spec; then the spec is parked) | decided |
| `quality-deferred-on-exit-3` | `accept-deferred` (never a pass; names the tool, see *Loop* step 5) | decided |
| `toolchain` | `defer` (TOOLCHAIN_DEFERRED; nothing is installed) | decided |
| `roi-gate` (confidence) | `proceed`, the assumption recorded | decided |
| `repo-bootstrap` | `skip` (no repository is created) | decided |
| `confirm` / `budget` / `windows` | `confirm` / `approve` / `sequential` (S1 only; listed for completeness) | decided |
| `loop` (3 failed exit checks, or a third full verifier pass) | none: the state stops retrying and the **spec is parked as needs-attention** | open |
| `budget-cap` (the estimate exceeds the cap) | none: a silent run does not raise a cap; parked | open |
| an exit check that returns exit 2, a plan without `## Waves` | none; parked (instead of STOPPED exit 6) | open |

**Parking a spec.** The attempts of that unit are reset (a later `--from <state>` or `--resume` retries it fresh), an `open` item is
written, and: a run with more specs after this one goes on with the next spec; a lane (`--until`, the `kcc run` scheduler) or `--only` run stops
at once with exit 7 and `run.json` `status: stopped`; the last spec of a bare run goes on to CLOSE. The scheduler marks the lane
`needs-attention` in `coordination/lanes.json` (with the reason; the specs that depend on it are marked `needs-attention: waits for ...`), runs every
other spec, closes the run, and exits 7. A final `DONE` with an open item exits 7 (`status` in `-Json` output: `needs-attention`); with only
`decided` items it exits 0 and prints the file's path and item count. Exit codes: 0 nothing open, 7 open items, 6 stopped (environment), 4 never.

**`coordination/NeedsAttention.md`.** A new run archives the previous file as `NeedsAttention-<timestamp>.md`. Lanes write their own copy
(never merged as a file); `kcc run` appends each lane's new sections to the workspace file while the lane runs and when it stops. Shape: a
header, then one section per item:

```
## [open|decided] SPEC-002 | loop | state 16 TEST | 2026-10-17T12:00:00Z

- when: 2026-10-17T12:00:00Z
- spec: SPEC-002              (run = a run-level item)
- state: 16 TEST
- gate: loop                  (gate kind or check name: ruling, loop, toolchain, quality-deferred-on-exit-3, roi-gate, budget-cap, check-error, no-waves, merge-conflict, lane-stopped)
- status: open                (open = a human must act; decided = the run went on, check the decision)
- decided: what the run did, e.g. "applied the recommended option of the ruling"
- why: the violations or the situation that caused it
- todo: what a human should check or do, e.g. "fix the cause, then: kcc run --lane SPEC-002 --from 16 ; kcc run --resume"
- links: coordination/gates/GATE-004.md, coordination/run/logs/state-16-SPEC-002-3.log
```

Each item is also a `needs-attention` event (`status`, `gate`, `decided`, `reason`, `todo`, `file`).

## Files, settings, limits (v1)

- `coordination/run/run.json` holds the policy, input, idea, specs, pointer, attempts and pending gate. Older runs are kept as `run-<ts>.json`.
- `coordination/run/logs/state-{id}-{spec}[-w{wave}]-{n}.log` holds harness output, one log per dispatch: the first dispatch of a unit is `-1` (a retry `-2`, as before), and when that file already exists (a second TEST pass, FIX again after a review) `n` counts up to the next free number, so no run overwrites an earlier log (`state-16-SPEC-001-2.log`). `check-{state}_{spec}-{n}-{tool}.out` holds the output of the check that followed dispatch `n`, so the two pair up. `agent-run-started` / `agent-run-ended` carry `attempt` (the retry counter) and `dispatch` (= `n`).
- `settings.json -> run`: `max_attempts` (3), `state_timeout_minutes` (60; after that the harness is killed and the attempt fails), `harness`.
- No parallel lanes inside the driver: one `kcc-run` is one sequential run. `kcc run` (the CLI) schedules the specs by dependency and runs independent ones in parallel lanes ([[parallel-lanes]]), using `-Until <id>` to stop the shared run after SPECS. The states the table marks `"fanout": true` (fast track: WRITE, PLAN) are per-spec like the rest, so the bare driver does them spec by spec; `kcc run` runs each of them for all specs at the same time first, with no limit (`kcc run --max-fanout N` sets one; `--max-parallel` bounds only the build lanes). Every harness dispatch emits `agent-run-started` and `agent-run-ended` (state, agent, spec, attempt, log, exit, seconds) next to its log `state-{id}-{spec}-{attempt}.log`, so overlapping runs show on the dashboard. `internal:roadmap-specs` is the SPECS exit check of fast track: ROADMAP.md lists specs, each has a folder with a stub note, and the per-idea index `specs/IDEA-NNN-slug-Specs/IDEA-NNN-slug-Specs.md` exists (SPEC-006; the split step writes it, the planners and `check-run-conformance` LINK-002/003 read it, and `spec-plan` writes it from ROADMAP.md rather than stopping if it is the only thing missing).
- **Harness-neutral.** `kcc-run` assumes no harness. How a harness takes an agent, a model and an effort is the data in
  `kernel/harnesses.json` (override a key with `settings.json -> harness_invoke.<harness>.<key>`), and which model a tier is on
  each harness is `kernel/models.json` (`run.registry` picks another column, for example `ollama` behind the `opencode`
  harness, which adds its `ollama/` prefix). A harness with no agent flag (Codex today) runs worker states under one
  orchestrator session; one with no effort flag simply gets no effort. Efforts above what a harness accepts are folded by
  its `effort_map` (Codex tops out at `high`).
- Under `-Fasttrack`, each dispatch's orchestrator session runs on the `run.orchestrator_tier` model (default `fast`) at
  `run.orchestrator_effort` (default `low`) of the active harness, and spawns the agents as subagents as usual. An explicit
  `run.orchestrator_model` still wins, but a Claude id is never passed to another harness (a bare `haiku`/`sonnet`/`opus` is
  mapped to the pinned 5.5 ID on Claude). Every dispatch, in every cycle (full `auto` too), asks the router (`.KCC/tools/kcc-route`,
  the port of `cli/src/run/router.ts`) for the state's agent with the spec, wave and attempt: a direct worker gets the model and
  effort as flags, an orchestrator session is told in its prompt which tier, model and effort to spawn the agent on, and
  `model-selected` records the choice. `run.fasttrack_direct: true`
  (the default) starts a state that has `agent_fasttrack` as that agent, with no orchestrator above it, where the harness can
  select an agent and has an agent file for it.
- Full runs add one sentence to every dispatch telling the orchestrator to brief and remember with the butler (CR-8); `run.butler: off` removes it. Fasttrack names the butler in the IDEA and CLOSE commands instead, in memory-only mode.
- `-Fasttrack` skips the states whose `skip_if_flag` lists `fasttrack` (a flag name or a list in `auto-states.json`), uses a state's `command_fasttrack` when it has one, and emits `fasttrack-approved` after `auto-policy-parsed` (that event opens `check-impl-lock`). `-DepthLevel N` (1-5) is stored in `run.json` and rendered as `--depthlevel N` below 5; `-Fasttrack` alone sets 2. Both default to off/5 for runs that predate them.
- `{TOOLS}` for the preflight is derived from dialect names in the spec, `plan.md` and the TechnicalDecisionBrief.
- A resume command with paths containing spaces depends on `kcc-limit-watch` quoting.
