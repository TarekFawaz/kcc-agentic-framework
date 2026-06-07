---
# Functional fields
description: Defines the parallel-execution intent and an abstract spawner contract that turns planned dependency waves into actually-concurrent agent flows, at two fan-out levels (across independent specs, and within a spec across independent stories/enablers), with wave/barrier semantics, a file-disjoint merge-safety rule, per-spawned-unit governance, and per-harness realizations.
inputs: A `parallelization.md` with dependency waves and proposed sessions, and/or a set of independent specs ready for the same lifecycle step.
outputs: Concurrent agent flows executed wave by wave with a barrier between waves, each flow's outputs collected (files under `src/IDEA-{ID}-{slug}/...`, tests, trace appends) and merged.

# Obsidian metadata
title: "Parallel Execution Protocol"
aliases:
  - parallel-execution
  - fan-out
  - wave-barrier
  - spawner-contract
tags:
  - framework/protocol
  - parallel-execution
  - orchestration
  - kcc/v04
created: 2026-06-05
updated: 2026-06-05
version: 1.0.0
status: active
copyright: "KCC framework (c) 2026 Tarek Fawaz"
homepage: "https://tikasway.dev/kcc"
license: "Licensed under the terms in LICENSE"
---

# Parallel Execution

The planner produces `parallelization.md` with dependency waves and proposed
sessions, but planning is not execution. Historically the orchestrator read the
plan and then **self-overrode to sequential** ("to avoid merge churn"), so the
concurrency that was designed never happened. This protocol fixes that: it
defines the parallel **intent** plus an **abstract spawner contract** that the
orchestrator actually invokes, so planned waves become concurrent agent flows.

> **Parallel means concurrent agent flows that finish the work faster.** It is
> true sub-agent fan-out (concurrent execution), **not** opening terminal
> windows. Visible/sandboxed session windows are a complementary delivery
> surface (see [The visible / sandboxed spawner](#the-visible--sandboxed-spawner)),
> not the mechanism of parallelism itself.

---

## Purpose

1. Stop the self-override to sequential by making file-disjoint waves the
   merge-safety guarantee, so concurrent execution is provably safe.
2. Give the orchestrator one **spawner contract** to call, with each harness
   declaring its own realization. All five harnesses are first-class; none is a
   "fallback."
3. Preserve every governance gate (butler, token-guard, confidence, loop
   detection) at the granularity of each spawned unit.

---

## The two fan-out levels

Parallelism happens at two independent levels. Both use the same spawner
contract and the same wave/barrier semantics.

### L1 - across independent specs

When multiple specs share no cross-spec dependency, spawn one **spec flow** per
spec concurrently. Example: a fleet system with `SPEC-1` user-management,
`SPEC-2` live-tracking, and `SPEC-3` playback (no cross-spec dependency) -> run
all three spec flows at once. This is the level `auto all` and multi-spec ideas
exercise. The dependency graph across specs comes from each spec folder note's
`## Dependencies` and the cross-idea dependency table in `specs/specs.md`.

### L2 - within a spec

Inside one spec flow, read `parallelization.md` and, for each **wave**, spawn
one agent per **independent story/enabler** in that wave. A barrier between
waves means wave N+1 starts only after wave N fully completes. This is the level
`/spec-implement SPEC-{ID}` (whole-spec scope) drives.

L1 and L2 compose: `auto all` may fan out across specs (L1), and each spec flow
fans out across its wave items (L2).

---

## Wave and barrier semantics

- A **wave** is a set of items (specs at L1, stories/enablers at L2) that are
  declared safe to run concurrently.
- All items in a wave are spawned **concurrently** through the spawner contract.
- A **barrier** sits between waves: wave N+1 does not begin until **every** item
  in wave N has completed (success, or a terminal stop after governance gates).
- If any item in a wave trips a hard stop (confidence gate, loop detection, a
  prohibited assumption, or an unrecoverable error), the orchestrator finishes
  the rest of the in-flight wave, then pauses at the barrier and reports before
  starting the next wave.

---

## The abstract spawner contract

Every harness realizes the same contract:

```text
run(independent_items) -> results
```

- **Input:** `independent_items` - a list of work units (specs at L1, or
  stories/enablers at L2) that the planner has certified as mutually
  parallel-eligible for this wave (see
  [File-disjoint merge-safety](#file-disjoint-merge-safety)).
- **Behavior:** the harness executes all items **concurrently**, each in its own
  agent flow scoped to its work unit and that unit's declared impacted files.
- **Barrier:** `run` returns only after **all** items have completed - this is
  the barrier. The orchestrator then collects results and advances to the next
  wave.
- **Output:** `results` - per-item outcome (files written, tests added, trace
  appends, confidence, any stop reason).

The orchestrator never calls items in a wave sequentially when the wave is
parallel-eligible. Sequential execution is only correct when a runtime cannot
spawn (see the generic realization) or when the planner placed items in
different waves because they share files.

---

## Per-harness realization matrix

Each harness declares how it realizes `run(independent_items)`. All five are
first-class. **PI / pi.dev is explicitly out of scope** for now and is not part
of this matrix.

| Harness | Parallel realization | Build status |
|--|--|--|
| **Claude Code** | Native parallel subagents: the orchestrator issues one subagent (Task/Agent) call per wave item **in a single turn**; the harness runs them concurrently; the barrier is "await all subagent results." | **Built / validated** |
| **Codex** | N headless `codex exec` (non-interactive) processes, one per wave item, each scoped to its story/enabler + its impacted files; the orchestrator waits on all processes and collects their results. | Documented, not yet built |
| **OpenCode** | N headless OpenCode run/session invocations, one per wave item; barrier on process completion. | Documented, not yet built |
| **Ollama** | Ollama has no agent loop of its own. Parallelism = concurrent model calls issued by whichever harness is **driving** Ollama, bounded by `OLLAMA_NUM_PARALLEL`. The driving harness realizes the contract; Ollama only needs `num_parallel` configured. This is explicitly **not** process-level fan-out by Ollama itself. | Documented, not yet built |
| **generic** | `start-agent-session.ps1` / `.sh` opens N sessions (the universal spawner), or runs sequentially if the runtime cannot spawn. | Documented, not yet built |

See each adapter's "Parallel execution realization" section:
[[../adapters/claude|claude]], [[../adapters/codex|codex]],
[[../adapters/opencode|opencode]], [[../adapters/ollama|ollama]],
[[../adapters/generic|generic]].

### Current build status

- **Claude Code realization: built and validated.** Native parallel subagents,
  one call per wave item in one turn, await-all barrier.
- **Codex, OpenCode, Ollama, generic: documented, not yet built.** Their
  realizations are specified here and in their adapter notes so the contract is
  stable, but the orchestrator code for them lands later.
- **PI / pi.dev: out of scope.** Do not add a PI realization now.

---

## File-disjoint merge-safety

The rule that lets the orchestrator stop self-overriding to sequential:

> **Items in the same wave MUST be file-disjoint to be parallel-eligible.**

- The **planner enforces this** when building `parallelization.md`: if two items
  would touch the same file (per their `## Impacted Files`), they cannot share a
  wave - the later-ordered one is pushed to a subsequent wave. So
  `parallel-eligible == file-disjoint` by construction.
- Because items in a wave write to disjoint file sets under
  `src/IDEA-{ID}-{slug}/...`, concurrent execution produces **no merge conflict
  in the common case** - there is nothing to merge-resolve.
- L1 is naturally file-disjoint because each spec writes under its own scope;
  the orchestrator still confirms no two concurrent specs declare the same
  impacted file.

### Optional: git-worktree isolation (NOT the default)

For risky cases (e.g. a wave that the planner could not fully prove disjoint, or
generated/shared artifacts that resist static analysis), each spawned unit may
optionally run in its own **git worktree** and be merged at the barrier. This is
an opt-in upgrade, not the default - the default is plain file-disjoint waves in
a shared working tree, because that is sufficient when the planner's disjoint
rule holds.

---

## Governance per spawned unit

Every parallel gate from the sequential lifecycle still applies, at the
granularity of each spawned unit:

- **butler-brief / butler-remember** wrap each spawned agent. The active trace
  session is **shared** across the fan-out (per Phase B trace custody); each
  spawned agent's appends are **agent-named** so concurrent writes stay
  attributable. See [[trace-layout]].
- **token-guard** accounts each spawned unit's usage against the run.
- **confidence-gate** applies per spawned unit: a unit below threshold triggers
  `/critical-human-gate` for that unit. See [[confidence-gate]].
- **loop detection** applies per spawned unit (max 3 trials per
  `(agent, step, unit)`); a tripped unit pauses without aborting siblings that
  already passed the barrier.
- **One upfront token-budget gate covers the whole wave set.** The orchestrator
  estimates the fan-out once before spawning; it does not re-gate each item
  inside the wave. See [[token-budget]].

---

## HOTL gating

How the fan-out interacts with auto mode (see [[auto-mode]]):

- **Default `auto` (Scenario 1):** before spawning a fan-out, the orchestrator
  **shows the `parallelization.md` session plan** (waves, items per wave,
  agent/dialect per item, working directories, expected outputs) and **asks the
  human** to approve the fan-out, run sequentially, or abort.
- **`--silent --assume` (Scenarios 2/3):** spawning is **pre-authorized** by the
  pre-flight warning; the orchestrator fans out at maximum parallelism without a
  per-wave prompt.
- **`--budget` cap (Scenario 3):** the budget cap still bounds the **whole** set;
  if the fan-out's projected cumulative spend crosses the cap, the run stops at
  the upfront gate or the next barrier per the cap rules.

---

## Result collection and merge

After a wave's barrier:

1. The orchestrator collects each unit's outputs: files written under
   `src/IDEA-{ID}-{slug}/...`, tests added, and trace appends (agent-named) to
   the shared session.
2. Because waves are file-disjoint, there is **no merge conflict** in the common
   case - collection is a union of disjoint file sets.
3. The orchestrator records per-unit confidence and any stop reason, then
   proceeds to the next wave (or to test/review when waves are exhausted).
4. If git-worktree isolation was used for a risky wave, the barrier is also the
   merge point; conflicts (rare, by design) are surfaced to the human.

---

## The visible / sandboxed spawner

`.KCC/tools/start-agent-session.ps1` remains the **visible / sandboxed** spawner
available to **all** harnesses, complementary to each harness's native
mechanism - **not** a fallback tier. Use it when:

- a human wants to **watch** the concurrent flows in visible session windows; or
- a unit needs **Docker isolation** for untrusted-input + sensitive-capability +
  outbound-channel work (see [[sandbox-runtime]]).

A harness with a native realization (e.g. Claude's parallel subagents) can still
use `start-agent-session.ps1` to surface those flows visibly or to sandbox a
risky unit. The native mechanism and the visible/sandboxed spawner co-exist; the
choice is about observability and isolation, not capability tiers. Opening
visible windows in default `auto` still requires the human permission step in
[[auto-mode]].

---

## Related

- Auto mode (HOTL gating, session permission): [[auto-mode]]
- Spec layout (`parallelization.md` shape, file-disjoint note): [[spec-layout]]
- Token budget (one upfront gate per wave set): [[token-budget]]
- Confidence gate (per spawned unit): [[confidence-gate]]
- Trace layout (shared session, agent-named appends): [[trace-layout]]
- Sandbox runtime (Docker isolation for risky units): [[sandbox-runtime]]
- Cells (per-idea workspace isolation): [[cells]]
- Planner agent: [[../../capabilities/agents/planner]]
- Implementer agent: [[../../capabilities/agents/implementer]]
- Auto skill: [[../../capabilities/skills/auto]]
- Spec implement skill: [[../../capabilities/skills/spec-implement]]
