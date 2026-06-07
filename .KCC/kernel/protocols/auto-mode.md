---
# Functional fields
description: HOTL/auto orchestration protocol - encodes operating scenarios (default HOTL, full hand-off HOTL, controlled hand-off HOTL), the always-upfront-budget rule, the always-architecture rule, loop detection, and IDEA-/SPEC-continuation semantics.
inputs: An idea, file path, folder path, existing IDEA-{ID}, existing SPEC-{ID}, or `auto all` request, plus optional AutoPolicy flags.
outputs: A dependency-aware execution plan, optional launched agent sessions, recorded AutoPolicy decisions, and lifecycle progress under the spec-layout v5.0.0 hierarchy.

# Obsidian metadata
title: "Auto Mode Protocol"
aliases:
  - auto-mode
  - hotl
  - parallel-agent-sessions
tags:
  - framework/protocol
  - lifecycle/auto
  - orchestration
created: 2026-05-24
updated: 2026-06-07
version: 1.10.0
status: active
copyright: "KCC framework (c) 2026 Tarek Fawaz"
homepage: "https://tikasway.dev/kcc"
license: "Licensed under the terms in LICENSE"
---

# Auto Mode

`auto` means Human On The Loop: the framework chains lifecycle work and uses
parallel agent sessions where dependencies allow. The protocol exposes
**operating scenarios** plus two continuation modes and `auto all`. It
also enforces orchestrator-side **loop detection** and the **always-upfront
budget** rule.

```text
auto <input>                                                        # Operating scenario 1: default HOTL
auto <input> --silent --assume                                      # Operating scenario 2: full hand-off HOTL
auto <input> --silent --assume --accuracy NN% --budget NN [CCY]     # Operating scenario 3: controlled hand-off HOTL
auto IDEA-{ID}                                                      # resume from an existing idea
auto SPEC-{ID}                                                      # continue an existing spec
auto all                                                            # progress every non-Done spec
```

Typo aliases: `--slient` -> `--silent`; `--acuuracy` -> `--accuracy`;
`--parralel` -> `--parallel`.

If a user message starts with `auto`, route it to the
[[.KCC/capabilities/skills/auto|auto]] skill. The skill is responsible for
argument parsing, scenario classification, and the gate sequence below.

An AutoPolicy is not blanket implementation approval. It is a scoped
decision record that says which assumptions may be made, the minimum
confidence threshold, and the maximum approved hosted-model spend. Auto
mode must still stop when the policy is missing, exceeded, or unsafe.

---

## Common Rules (apply in every operating scenario)

These rules are non-negotiable. The auto skill must enforce them regardless
of which operating scenario is active.

### CR-1 - Upfront budget is ALWAYS shown

`/token-estimate` runs **upfront**, immediately after `/idea-interrogator`
produces the phases + epics breakdown, in every operating scenario. Token-guard's
**idea-scope estimation mode** is used for this upfront call: it is
pessimistic with a +/-50% confidence band initially, tightening to +/-20% as
specs are materialized.

| Operating scenario | Upfront estimate behavior |
|--|--|
| 1 (default HOTL) | Show estimate; human gates with `approve / revise / abort`. |
| 2 (full hand-off HOTL) | Show estimate as awareness only. No gate. |
| 3 (controlled hand-off HOTL) | Show estimate; **STOP** if it exceeds cap. |
| `auto all` | Aggregate per-spec; apply per-spec scenario semantics. |

### CR-2 - Architecture artifacts are ALWAYS produced

The architect pass runs in every operating scenario, including `--silent --assume`.
Required minimum deliverables:

- **Mermaid C4 Context** (`architecture/c4-context.mmd`)
- **Mermaid C4 Container** (`architecture/c4-container.mmd`)
- **Mermaid flowchart(s)** for non-trivial business workflows (NO BPMN)
- **Mermaid DFD(s)** when data flow is non-trivial
- Spec-local `arch.md` per spec when the spec introduces
  architecture-relevant decisions

In silent scenarios the architect documents its assumptions in each
artifact's frontmatter and in `architecture/assumptions.md`.

### CR-3 - Loop detection (orchestrator-tracked)

The orchestrator maintains an in-session counter keyed by
`(agent_id, lifecycle_step)`. On every failed attempt (hard error,
malformed handover, or confidence below threshold), the counter
increments. On the **3rd consecutive failure** for the same pair, auto
mode invokes `/critical-human-gate` with the payload
`agent={id}, step={step}, trials=3, last_error={summary}, last_confidence={pct}`
and the human chooses `revise / escalate / abort`. A successful attempt
resets the counter. The counter is per-session, not persistent.

### CR-4 - Confidence gate

Every agent ends with `Confidence: NN%`. Below the configured threshold
(default 95, or `--accuracy` override) auto invokes
`/critical-human-gate`. In Scenario 3 this is a **refinement loop** (the
human can answer open questions and the agent re-runs once before counting
toward CR-3); in Scenarios 1 and 2 it's a single decision gate.

### CR-5 - Trace chain integrity

When invoking `/spec-create`, the skill **must** pass the originating
IDEA-ID so spec-writer nests the spec under
`specs/IDEA-{ID}-{slug}-Specs/` per spec-layout v5.0.0. Stories/enablers
link to the spec, the spec links to its per-idea index, the index links to
the idea. No edge skipping.

### CR-6 - Atomic test cases flow into the test plan

The planner emits a `## Atomic test cases` table in `plan.md` (per
spec-layout v5.0.0). The implementer turns those rows into real test code
using the `testing-unit` / `testing-integration` (and optionally
`testing-performance` / `testing-security`) dialects. Auto does not spawn
a separate test-case-writer agent.

### CR-7 - Prohibited assumptions (never silent-able)

Even in `--silent --assume`, the following always require a human gate:
legal, security posture, data sensitivity, privacy, compliance, audit,
secrets handling, destructive actions, external spend, paid service
activation, and production-impacting decisions.

### CR-8 - Trace session is created at run start

Before any agent dispatch, invoke `/butler-brief` so Butler creates or confirms
the run's `Traces/Session-{slug}-{datetime}/` folder and records the
active-session pointer in `coordination/orchestrator.json`. One `auto`
invocation = one trace session. When Butler creates a new session it emits
`trace-session-created` to the backchannel.

### CR-9 - Toolchain preflight is never silent-able

Before implementation and before verification, run
[[toolchain-preflight]]. Emit `toolchain-preflight-started` and
`toolchain-preflight-result` for every preflight. If tools are missing, stop
for the install gate (`install` / `human-install` / `defer`). Every gate
decision MUST hit the **four sinks** (per [[toolchain-preflight]]): the choice
in `Traces/Session-*/HumanDecisions.md`; the events
(`toolchain-preflight-started`, `toolchain-preflight-result`,
`toolchain-gate-decision`, and `toolchain-install-complete` with command +
result + re-detected version) on `coordination/backchannel.jsonl` via
`.KCC/tools/backchannel-append.ps1`; the install command in
`Traces/Session-*/ToolsUsed.md`; and the action in `Traces/Session-*/Actions.md`.
If the AI performs an approved install, re-detect and emit
`toolchain-install-complete`. Concrete example: `winget install
Python.Python.3.12` -> `toolchain-gate-decision` (human approved install) then
`toolchain-install-complete` (command, result, version after re-detect). This
gate is never covered by `--silent --assume`.

### CR-10 - Backchannel lifecycle evidence is mandatory

Every lifecycle transition emits its compact backchannel fact through
`.KCC/tools/backchannel-append.ps1` or `.KCC/tools/backchannel-append.sh`; a
completed run's `backchannel.jsonl` contains the **full ordered lifecycle
spine** defined in [[backchannel]]. A fresh `auto <idea>` run emits, in order:
`auto-policy-parsed`, `trace-session-created`, `brief-issued`,
`idea-interrogation-started`, `idea-interrogation-completed`,
`specialist-brief-created` (one per applicable specialist domain),
`architecture-pass-complete`, `estimate-issued` plus the approval/cap event
(`estimate-auto-approved` / `estimate-approved` / `auto-policy-cap-exceeded`),
`human-gate-decision` at each gate, `spec-created`, `plan-created`,
`toolchain-preflight-started`, `toolchain-preflight-result`,
`toolchain-gate-decision` and `toolchain-install-complete` when applicable,
`implement-started`, `implement-completed`, `test-started`, `test-completed`,
`review-produced`, `remember-stored`, and `session-closed` at the end.
`actual-recorded` is emitted whenever harness/API token actuals exist (or with
`source: unavailable` when they do not). The prior kind names
(`architecture-pass-completed`, `implement-complete`, `test-verdict`,
`review-complete`, `human-gate-triggered` / `human-gate-resolved`,
per-domain `*-brief-issued`) remain valid; see the
[[backchannel]] naming-compatibility table.

The trace files remain the full transcript. Backchannel is the compact,
machine-readable spine that proves the lifecycle actually happened.

### CR-11 - ROI-confidence gate (silent-mode escalation, distinct from CR-4)

The idea-interrogator's ROI step records an explicit **ROI confidence %** in
`ROI.md` and the idea file. After that step the orchestrator inspects it:

- **ROI confidence < 60%:** PAUSE - even under `--silent --assume` - and
  invoke `/critical-human-gate` with `mode: roi-gate`, presenting the ROI
  summary, documented assumptions, and alternatives, and capturing
  `proceed / revise scope / abort`.
- **ROI confidence >= 60%:** continue (silently in Scenarios 2/3).

CR-11 is **distinct from CR-4**: CR-4 is the per-decision accuracy/confidence
gate (default 95%, tunable via `--accuracy`, fired by any agent's
`Confidence: NN%`); CR-11 is the idea-level ROI-confidence gate (fixed 60%,
fired once after the ROI step, **not** affected by `--accuracy`). The budget
cap (Scenario 3) is independent again. All route through
`/critical-human-gate` but for different reasons. See [[confidence-gate]].

### CR-12 - Stack is ADR-dictated; a missing toolchain never changes it

The implementation stack is dictated by the architecture ADR /
`TechnicalDecisionBrief.md`, **not** by what toolchain happens to be installed.
A missing toolchain routes through the **preflight install-after-approval gate**
([[toolchain-preflight]]) or **defers** the build/test step (write the declared
stack's code, mark it `TOOLCHAIN_DEFERRED`) - it is **NEVER** a license to
change the stack. Silently swapping the declared stack for a different one (e.g.
static HTML/JS instead of the declared TS + React + Node API; the test8 pilot
regression) is a **prohibited silent assumption** and a re-architecture
requiring a new/updated ADR + explicit human approval via
`/critical-human-gate`. This holds in every operating scenario, including
`--silent --assume`. The planner must not write, and the implementer must not
build, a stack that contradicts the ADR.

### CR-13 - Silent mode never drops planned specs

Silent mode (Scenarios 2/3) creates the specs the idea/architecture defined for
the targeted scope. It must **not** unilaterally collapse a multi-spec plan to a
single spec (test8 shipped 1 of 5 planned specs - a regression). If a blocker
genuinely forces a reduced scope, **escalate via `/critical-human-gate`**
(present the planned spec set, the blocker, and the proposed reduction) rather
than silently dropping `SPEC-002..N`. A planned spec set may only shrink with
explicit human approval.

---

## Operating scenario 1 - default HOTL (`auto <input>`)

The classic Human-In/On-The-Loop flow. Pauses at every interrogation,
confirmation, and budget gate.

### Step sequence

1. **Reasoning step (NEW)** - the idea-interrogator produces a
   `## Reasoning` section in `idea-{ID}-{slug}.md` capturing its
   interpretation, framing, and intended questions.
2. **Idea interrogation** - `/idea-interrogator <input>` full HITL.
3. **Idea-folder verification** - require
   `ideation/IDEA-{ID}-{slug}/idea-{ID}-{slug}.md` with the
   `## Reasoning`, `## Phases`, `## Upfront Budget`, `## Effort` sections
   populated.
4. **Existing-solution analysis** - when `input_class =
   existing-solution-plus-idea`, require `## Impact Analysis`,
   `## Gap Analysis`, `## Alternatives` sections in the idea file.
5. **Technical interrogation** - `/technical-interrogator`; require
   `TechnicalDecisionBrief.md`.
6. **Conditional specialist interrogation**:
   - `/ux-ui-interrogator` for any screen/interaction work - UX agent
     **must** present at least **3 design-system options** (e.g.
     Material, Fluent, Tailwind+shadcn, Carbon, Atlassian, custom) and
     record the human's pick + rationale.
   - `/security-interrogator` for identity, data sensitivity, public
     exposure, compliance, audit, secrets, privacy risk.
   - `/infrastructure-interrogator` for **any deployable, production-ready,
     hostable, or distributable** work - not just explicit cloud requests.
     Fire it for: cloud, on-prem, hybrid/agnostic hosting, K8s/containers, an
     API or service that ships, a deployable app/binary/package, packaging or
     distribution, production/staging environments, scale, observability,
     SLO/latency-percentile, DR/backup, or paid-service work. In
     `--silent --assume` mode the default ambition is production-leaning, so
     this fires by default for any build the human could realistically run in
     production. Skip only for pure local one-off scripts, docs-only changes,
     or throwaway prototypes explicitly framed as such.
7. **Confirmation step (NEW)** - restate **every captured answer** and
   ask one consolidated question: `confirm all / revise <topic> / abort`.
8. **Architect pass (CR-2)** - produce architecture artifacts.
9. **Upfront budget (CR-1)** - `/token-estimate IDEA-{ID}` idea-scope mode;
   human gates `approve / revise / abort`.
10. **Spec creation** - `/spec-create` per spec-layout v5.0.0 hierarchy.
11. **Plan-gate budget** - `/token-estimate SPEC-{ID}`; human gates.
12. **Planning** - `/spec-plan`; require `plan.md` (with `## Atomic test
    cases`, CR-6) and `parallelization.md`.
13. **Sub-agent session permission** - display proposed parallel sessions;
    human gates `approve windows / sequential / abort`.
14. **Implement-gate budget** - `/token-estimate SPEC-{ID}` refined; human
    gates.
15. **Implement -> Test -> Review** - `/spec-implement`, `/spec-test`,
    `/spec-review`.

### Gate table

| Gate | Required evidence |
|--|--|
| Idea | `idea-{ID}-{slug}.md` with Reasoning/Phases/Upfront-Budget/Effort populated. |
| Existing-solution (conditional) | Impact, Gap, Alternatives sections present. |
| Technical | `TechnicalDecisionBrief.md` exists. |
| Specialist | UX/security/infra briefs exist when triggers fire; UX brief includes 3 design-system options. |
| Confirmation | Human answered `confirm all` (logged). |
| Architecture | CR-2 artifacts present. |
| Upfront budget | Explicit human approval. |
| Spec | Folder note, `backlog.md`, backlog item files, `parallelization.md`, stubs all present. |
| Plan budget | Explicit human approval. |
| Plan | `plan.md` ready with `## Atomic test cases`; mapped to backlog keys. |
| Windows | Human approved or declined sub-agent sessions. |
| Implement budget | Explicit human approval. |
| Confidence (every step) | Each agent >= threshold (default 95%). |

---

## Operating scenario 2 - Full hand-off HOTL (`auto <input> --silent --assume`)

Hands-off. Documents assumptions instead of asking. Pauses only on hard
safety gates and the CR-11 ROI-confidence gate.

### Silent-mode default ambition (MID-LEVEL + MODERATE RESEARCH)

`--silent --assume` defaults to **mid-level ambition with moderate research**,
**not** minimal/single-spec/simple (the pilots regressed to that and it was
too shallow):

- **Architecture depth defaults to `standard`**, not `minimal`/lite. Drop to
  `minimal` only for a genuine CLI/script/docs-only change; rise to
  `distributed`/`regulated` only when the idea's content demands it.
- **Decompose into MULTIPLE specs whenever the idea spans distinct concerns.**
  Never force a single spec just because the run is silent.
- **Production-leaning baseline, not gold-plated:** auth/authorization where
  relevant, input validation, error handling, tests (unit + integration), and
  API standards (OpenAPI) for any HTTP API. No speculative extensibility or
  premature optimization.
- **Moderate research:** the idea-interrogator runs a moderate web-research
  pass on prior art + relevant standards before assuming - never from zero.

### Pre-flight warning (MANDATORY)

```text
WARNING - Silent + assume mode

Agents will document low-risk assumptions and run with:
  - unlimited token budget
  - maximum parallel sessions allowed by default
  - NO interrogation questions
  - MID-LEVEL ambition + MODERATE research (standard depth, multi-spec when
    the idea spans distinct concerns, production-leaning baseline)

Pauses ONLY on:
  - confidence below NN% (default 95, configurable via --accuracy)
  - ROI confidence below 60% from the idea-interrogator's ROI step (CR-11)
  - loop detection: same agent failing the same step 3 times (max 3 trials)
  - prohibited-assumption need (CR-7)

Architecture artifacts STILL produced (with assumptions documented).
Upfront budget estimate STILL shown (as awareness, not as a gate).

Proceed? yes / no
```

### Deltas vs. Scenario 1

- `/idea-interrogator` runs in `--silent --assume` at **mid-level ambition**:
  a moderate web-research pass before assuming, architecture depth defaulting
  to `standard`, and multi-spec decomposition when the idea spans distinct
  concerns. Assumptions, chosen depth, and the multi-spec decision go into
  `## Assumptions` / `## Idea Planning` in the idea file.
- **CR-11 ROI-confidence gate:** after the ROI step, if ROI confidence < 60%,
  STOP and escalate via `/critical-human-gate` (`mode: roi-gate`) even in
  silent mode (`proceed / revise scope / abort`).
- Specialist interrogators skip questions but still emit decision briefs
  from assumptions (UX still emits the 3-design-system comparison; agent
  picks default-best with rationale).
- Confirmation step (Scenario 1 step 7) is **skipped**.
- Architecture pass STILL runs (CR-2) with documented assumptions.
- Upfront budget shown as awareness only; **no gate**.
- Both subsequent token estimates record
  `auto-policy-approved-unlimited` and continue.
- Maximum parallel sessions opened without window-gate prompt (the
  pre-flight warning covers this consent).
- Pause-only triggers: CR-4 (confidence), CR-3 (loop detection), CR-7
  (prohibited assumption).

---

## Operating scenario 3 - controlled hand-off HOTL (`auto <input> --silent --assume --accuracy NN% --budget NN [CCY]`)

Like Scenario 2 with a hard budget cap and tunable confidence floor. It
inherits Scenario 2's mid-level + moderate-research default ambition and the
CR-11 ROI-confidence gate (fixed 60%); the budget cap and `--accuracy` floor
replace neither.

### Pre-flight warning (MANDATORY)

Scenario 2 warning + this appended block:

```text
BUDGET CAP - {amount} {currency}

The upfront token-guard estimate runs in idea-scope mode immediately
after /idea-interrogator produces phases + epics. First estimate has a
pessimistic +/-50% band, tightening to +/-20% as specs are materialized.

If upfront estimate EXCEEDS the cap -> run STOPS for you.
If a per-spec re-estimate pushes cumulative over the cap -> run STOPS.
Decisions below {threshold}% confidence -> REFINEMENT loop with you
(not a hard abort).
Loop detection still applies (3 trials per agent/step).

Proceed? yes / no
```

### Deltas vs. Scenario 2

- **Upfront estimate is a HARD GATE.** Run `/token-estimate IDEA-{ID}` in
  idea-scope mode immediately after `/idea-interrogator`.
  - If estimate **> cap** -> STOP; ask
    `revise scope / increase cap / abort`. Cannot proceed silently.
  - If estimate **<= cap** -> record `auto-policy-approved-bounded` in
    `coordination/backchannel.jsonl` and continue.
- Per-spec re-estimates recompute cumulative spend; crossing the cap
  triggers a STOP with the same prompt.
- **Confidence below `--accuracy`** triggers a **refinement loop**, not
  hard abort: `/critical-human-gate` with `mode: refinement`. The human
  supplies missing context; the agent re-runs once. If still missing, it
  counts toward CR-3.
- Architecture pass STILL runs (CR-2).
- Loop detection (CR-3) still applies.

---

## `auto all`

Operate on every spec whose `status != Done` under
`specs/IDEA-*-Specs/SPEC-*/`. For each, derive the current lifecycle
step from folder contents (plan absent -> planning; plan ready, no diff ->
implementation; etc.), spawn sub-agent sessions per `parallelization.md`,
and apply the active operating scenario's gate rules (1, 2, or 3) per spec. CR-3
loop detection is tracked per `(agent, step, spec)` triplet here.

---

## IDEA Continuation (Bug-Fix 1)

`auto IDEA-{ID}` or `auto IDEA-{ID}-{slug}` resumes from an existing
idea folder.

1. Resolve the idea folder (`ideation/IDEA-{ID}-{slug}/`); ID-only
   matches search by glob and reject ambiguity.
2. Inspect for brief completeness:
   - `idea-{ID}-{slug}.md` with `## Reasoning`, `## Phases`,
     `## Upfront Budget`, `## Effort`.
   - `Questionnaire.md`, `HumanAnswers.md`, `Research.md`, `ROI.md`,
     `Conclusion.md`, `QuickRoadmap.md`, `SpecWriterStarter.md`.
   - For existing-solution input: `## Impact Analysis`, `## Gap Analysis`,
     `## Alternatives` in the idea file.
3. **Resume point selection:**

   | Missing artifact | Resume at |
   |--|--|
   | Idea file or any of the seven artifacts | Scenario 1 step 2 (`/idea-interrogator`) |
   | `TechnicalDecisionBrief.md` | Scenario 1 step 5 |
   | Required specialist brief | Scenario 1 step 6 |
   | Confirmation not recorded in trace | Scenario 1 step 7 |
   | Architecture artifacts (CR-2) | Scenario 1 step 8 |
   | Upfront budget decision | Scenario 1 step 9 |
   | No `specs/IDEA-{ID}-{slug}-Specs/` folder | Scenario 1 step 10 |
   | `plan.md` is a stub | Scenario 1 step 11 |
   | Plan exists, no implementation | Scenario 1 step 14 |

4. If brief is **complete** and nothing downstream exists, **skip step
   2** and resume at **step 5** (`/technical-interrogator`).
5. AutoPolicy flags on the continuation invocation apply to the remainder
   (e.g. `auto IDEA-007 --silent --assume --budget 50` flips the rest to
   Scenario 3 semantics).

---

## SPEC Continuation

`auto SPEC-{ID}` or `auto SPEC-{ID}-{slug}` resolves the spec folder
under any `specs/IDEA-*-Specs/` parent and resumes from the spec-layer
entries of the resume table (step 11 onward). AutoPolicy flags apply to
the remainder.

---

## Argument Parser Contract (Bug-Fix 2)

The auto skill **must** explicitly handle the no-argument case before
falling through. `auto` invoked alone (no args, no flags, no whitespace
that produces a non-empty input) prints the usage block and exits with
no agent dispatch and no file writes. It **must NOT** treat empty input
as a fresh idea with empty text.

The skill must also reject `--silent` without `--assume` (and vice
versa) with `auto: --silent and --assume must be used together`.

---

## Default Parallel Behavior

The orchestrator identifies independent work and fans it out:

- Architect review may run in parallel with spec backlog refinement after
  the technical decision brief exists.
- Verifier/reviewer second opinions may run in sibling sessions after
  implementation.
- `auto all` fans out unblocked specs to separate sessions.

Do not parallelize dependent steps. Implementation must wait for the spec
folder note, backlog, technical brief, architecture gates, token approval,
and plan.

### `--parallel` flag semantics

`--parallel` (normalized `parallel: true`, default false) is **independent of
operating scenarios 1/2/3** and combines with any of them. It forces parallel
execution in two places:

1. **Spec-creation fan-out (L0.5).** When an idea yields multiple selected
   epics, spawn one `/spec-create` subagent per epic (reusing the spawner
   contract + barrier from [[parallel-execution]]) instead of calling
   `/spec-create` sequentially. The human still chooses *which* epics; all
   selected epics must finish spec creation (folders + `parallelization.md`)
   before planning starts.
2. **Standing window consent.** It pre-authorizes opening parallel session
   windows for the later L1/L2 fan-out, so the Scenario-1 step-13
   `approve windows` prompt does not fire (the plan is still shown for
   awareness).

Per-unit governance is unchanged (butler-brief/remember, token-guard,
confidence, CR-3 loop detection per spawned unit); one upfront token-budget gate
still covers all planned specs. When `--parallel` is absent, spec creation runs
sequentially and Scenario 1 still prompts before opening windows.

---

## Parallel Execution (the fan-out actually runs)

Planning is not execution. After `/spec-plan` produces `parallelization.md`,
the orchestrator **executes** the planned concurrency through the spawner
contract in [[parallel-execution]] - it must not self-override to sequential.
Two fan-out levels apply:

- **L2 - within a spec.** During implementation, the orchestrator reads
  `parallelization.md` and, for each **wave**, spawns one agent per independent
  story/enabler (`run(independent_items)`), waits on the **barrier**, then
  advances to the next wave. The Claude realization is native parallel
  subagents (one subagent call per wave item in a single turn, await all);
  other harnesses realize the same contract per their adapter notes.
- **L1 - across independent specs.** For multi-spec ideas and `auto all`, the
  orchestrator first fans out across specs that share no cross-spec dependency
  (one spec flow each, concurrent), then each spec flow runs its own L2 waves.

Merge-safety comes from the planner's **file-disjoint wave rule** (items in a
wave touch disjoint files under `src/IDEA-{ID}-{slug}/...`), so concurrent
writes do not conflict. Governance is preserved **per spawned unit**
(butler-brief/remember, token-guard, confidence-gate, loop detection); a single
upfront token-budget gate covers the whole wave set.

HOTL gating:

- **Default `auto` (Scenario 1):** show the `parallelization.md` session plan
  and ask the human before spawning the fan-out
  (`approve windows / sequential / abort`, already covered by Scenario 1 step
  13).
- **`--silent --assume` (Scenarios 2/3):** the pre-flight warning pre-authorizes
  spawning at maximum parallelism; no per-wave prompt.
- **`--parallel` (any scenario):** standing consent - the fan-out (including
  spec-creation L0.5) runs without the per-spec window prompt.
- **`--budget` cap (Scenario 3):** the cap still bounds the whole fan-out.

See [[parallel-execution]] for wave/barrier semantics, the abstract spawner
contract, the per-harness realization matrix (Claude built; Codex / OpenCode /
Ollama / generic documented-not-yet-built; PI out of scope), the file-disjoint
rule and optional git-worktree isolation, and result collection.

---

## Permission Before Opening Windows

Before opening new terminal/CMD/PowerShell/harness session windows, the
orchestrator asks the human for permission and shows:

- number of windows/sessions;
- agent role per session;
- harness command to run;
- working directory;
- assigned story/enabler files and dialects;
- purpose and expected output file(s).

If approved, open visible session windows by default. If declined, run
sequentially in the current session.

Use `.KCC/tools/start-agent-session.ps1` as the local helper when
available.

In Scenario 2 and Scenario 3 the pre-flight warning serves as the
window-opening consent - no per-spec window prompt fires.

---

## AutoPolicy Semantics

| Field | Default | Meaning |
|--|--|--|
| `silent` | false | Minimize status interruptions and ask only when a gate is hit. |
| `assume` | false | Use documented low-risk assumptions for missing answers. |
| `confidence_threshold_pct` | 95 | Invoke `/critical-human-gate` below this score. |
| `budget_cap_amount` | none | Maximum approved cumulative hosted-model spend. |
| `budget_cap_currency` | USD when omitted | Currency for hosted-model spend estimates. |
| `parallel` | false | Force parallel spec creation (one subagent per selected epic) and pre-authorize all parallel session windows. Scenario-independent. |

`silent` and `assume` are coupled: one without the other is rejected. `parallel`
is standalone and combines with any scenario.

Allowed assumptions: reversible, low-risk product, UX, naming, local-file,
and implementation-detail choices.

Prohibited assumptions (CR-7): security posture, data sensitivity,
privacy/compliance obligations, legal constraints,
authentication/authorization model, destructive actions, production
deployment, external purchases, paid-service activation, and any decision
the active agent rates below the configured confidence threshold.

When `--budget` is present, write the approval to
`coordination/backchannel.jsonl` as `auto-policy-approved-bounded` and
to `Traces/Session-*/HumanDecisions.md` when a trace folder exists. When
unlimited (`--silent --assume` without budget), record
`auto-policy-approved-unlimited`. When the cap is exceeded later, emit
`auto-policy-cap-exceeded` and stop.

---

## Hard Stops (cross-operating-scenario)

Stop and report the missing gate when any of these is true, subject to
operating-scenario-specific overrides above:

- Argument parsing failure: empty args (-> usage help), or `--silent` /
  `--assume` not paired (-> reject).
- Fresh idea with no `ideation/IDEA-{ID}-{slug}/` folder after step 2.
- Required idea-file sections missing after interrogation.
- `TechnicalDecisionBrief.md` missing before `/spec-create`.
- Required specialist brief missing for UX / security / infrastructure
  triggers.
- Required architecture artifacts (CR-2) missing before `/spec-create`.
- Confirmation step skipped in Scenario 1.
- Spec folder note, `backlog.md`, backlog items, or `parallelization.md`
  missing before `/spec-plan`.
- Upfront, plan-gate, or implement-gate budget approval missing for the
  active operating scenario.
- Cumulative projected spend exceeds AutoPolicy cap (Scenario 3).
- Missing answer requires a prohibited assumption (CR-7).
- `plan.md` missing or unmapped to backlog items.
- `plan.md` missing `## Atomic test cases` (CR-6).
- `parallelization.md` missing dependency waves before
  `/spec-implement`.
- Confidence below threshold (CR-4) - pause.
- ROI confidence < 60% in silent mode (CR-11) - pause via
  `/critical-human-gate` (`mode: roi-gate`).
- Loop-detection trip (CR-3) - pause.
- Toolchain missing before implementation/test and the install gate
  (`install` / `human-install` / `defer`) unresolved - never silent
  ([[toolchain-preflight]]).
- A stack deviation from the architecture ADR (CR-12) - STOP and require a
  re-architecture (new/updated ADR + human approval); never silently swap the
  stack.
- A planned spec set silently reduced (CR-13) - escalate via
  `/critical-human-gate` rather than dropping `SPEC-002..N`.

---

## Implementation Lock

No application/source files may be created or edited during fresh-idea
auto mode until ALL of these are true:

1. A spec folder exists under `specs/IDEA-{ID}-{slug}-Specs/`.
2. `backlog.md` exists and is INVEST checked.
3. Backlog item files and `parallelization.md` exist.
4. `plan.md` is ready and includes `## Atomic test cases`.
5. The post-plan token estimate is approved (explicit human, or covered
   by the active AutoPolicy budget).
6. Any below-threshold confidence gate is resolved.

When `--parallel` is set with multiple selected epics, **all** selected epics
must finish spec creation (each `SPEC-{ID}-{slug}/` folder + its
`parallelization.md`) before the planning phase starts - await the spec-creation
barrier; do not stagger epic creation and planning.

If the harness attempts to implement from raw idea text, stop and
report: `Blocked: auto fresh idea must complete interrogation, spec,
plan, and budget gates before implementation.`

---

## Confidence Gate Interaction

Every auto-mode step inspects the agent's final `Confidence: NN%` line.
Below threshold (default 95) auto pauses and invokes
`/critical-human-gate`. No new windows are opened and no downstream
agent runs until the human resolves the gate (or, in Scenario 3, the
refinement loop completes).

---

## Related

- Auto skill: [[../../capabilities/skills/auto]]
- Confidence gate: [[confidence-gate]]
- Token budget: [[token-budget]]
- Architecture governance: [[architecture-governance]]
- Handover: [[handover]]
- Spec layout (v5.0.0): [[spec-layout]]
- Idea layout: [[idea-layout]]
- Trace layout: [[trace-layout]]
- Parallel execution: [[parallel-execution]]
- Critical human gate: [[../../capabilities/skills/critical-human-gate]]

