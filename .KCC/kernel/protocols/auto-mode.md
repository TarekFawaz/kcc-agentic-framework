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
updated: 2026-09-21
version: 2.1.0
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
produces the phases + epics breakdown, in every operating scenario including the
default HOTL flow and operating scenario 2 (unlimited). The upfront estimate uses
token-guard's **idea-scope estimation mode** (pessimistic, +/-50% confidence
band initially; the band tightens to +/-20% as specs are materialized).

- Operating scenario 1 (default HOTL): show estimate, ask the human for `approve / revise / abort`.
- Operating scenario 2 (full hand-off HOTL): show estimate as awareness; do not block.
- Operating scenario 3 (controlled hand-off HOTL): show estimate; **STOP** if it exceeds the cap.

### CR-2 - Architecture artifacts are ALWAYS produced (embedded, never `.mmd`)

The architect pass runs in every operating scenario, including `--silent --assume`.
All diagrams are **embedded as inline fenced ```mermaid``` blocks inside `.md`
files** per [[architecture-documentation|architecture-documentation]].
**Never** emit loose `.mmd` files; **never** create an `architecture/README.md`
hub. Required minimum deliverables:

- **`architecture/architecture.md`** - the Architecture Document: narrative
  prose **plus** embedded fenced ```mermaid``` blocks (C4 Context + Container at
  minimum). It is NOT a link hub and NOT a sub-1KB stub.
- **C4 Context + Container** as embedded ```mermaid``` (in `architecture.md`
  and/or `architecture/c4-context.md` + `c4-container.md` - `.md`, not `.mmd`).
- **Mermaid flowchart(s)** for non-trivial business workflows (embedded).
- **Mermaid DFD(s)** when data flow is non-trivial (embedded).
- Spec-local `arch.md` inside each `specs/IDEA-{ID}-{slug}-Specs/SPEC-{ID}-{slug}/`
  with **>=1 embedded ```mermaid``` block** plus prose (content bar - a
  link-only or sub-1KB stub FAILS).

**NO BPMN.** Use flowcharts. In silent mode, the architect documents
assumptions in each artifact's frontmatter and in `architecture/assumptions.md`.

The architect MUST self-review via `/architecture-review` **in every scenario,
including `--silent --assume`**, and the orchestrator MUST pass the
architecture-conformance gate (CR-14) before handing off to `/spec-create`.

### CR-3 - Loop detection (orchestrator-tracked)

The orchestrator maintains an in-session counter keyed by
`(agent_id, lifecycle_step)`:

- Counter increments on each **failed attempt** (agent reports failure, hard
  error, returns malformed handover, or its confidence falls below the
  threshold).
- On the **3rd consecutive failure** for the same `(agent, step)` pair:
  - Do NOT retry a 4th time.
  - Invoke `/critical-human-gate` with payload:
    `agent={id}, step={step}, trials=3, last_error={summary}, last_confidence={pct}`.
  - The human chooses: `revise` (reset counter, supply guidance), `escalate`
    (swap agent / dialect), or `abort` (stop the auto run).
- A successful attempt resets the counter for that pair.
- The counter survives within a single `auto` session; it does not persist
  across separate harness invocations.

### CR-4 - Confidence gate

Every agent ends with a `Confidence: NN%` line. If `NN` is below the
configured threshold (default 95, or `--accuracy` override), invoke
`/critical-human-gate`. In Scenario 3 this is a **refinement loop**, not a
hard abort - the human may answer the agent's open questions and the agent
re-runs.

### CR-5 - Trace chain integrity

When dispatching `/spec-create`, always pass the originating IDEA-ID so
spec-writer nests the spec under `specs/IDEA-{ID}-{slug}-Specs/` per the
spec-layout protocol (v5.0.0). Stories/enablers link to their spec, the spec
links to its per-idea index, the index links to the idea. No edge skipping.

### CR-6 - Atomic test cases flow into the test plan

The planner enumerates atomic test cases in `plan.md` (`## Atomic test cases`
table per spec-layout v5.0.0). The implementer turns those rows into real
test code using the `testing-unit` / `testing-integration` (and optionally
`testing-performance` / `testing-security`) dialects. The auto flow does
**not** spawn a separate test-case-writer agent.

### CR-7 - Prohibited assumptions (never silent-able)

Even in `--silent --assume`, the following always require a human gate:
legal, security posture, data sensitivity, privacy, compliance, audit,
secrets handling, destructive actions, external spend, paid service
activation, and production-impacting decisions. Agents must escalate via
`/critical-human-gate` rather than assume.

### CR-8 - Trace session is created at run start

Before any agent dispatch (including the first interrogation), invoke
`/butler-brief` so the trace custodian creates this run's
`Traces/Session-{slug}-{datetime}/` folder and records the active-session
pointer in `coordination/orchestrator.json`. Every downstream agent turn then
appends its telemetry to that one session via `/butler-remember`. One `auto`
invocation = one trace session. See
[[trace-layout|trace-layout]].

Immediately after the trace session is ensured (and again after each gate),
refresh the human-facing dashboard so the human can watch progress live:
`powershell -ExecutionPolicy Bypass -File .KCC\tools\build-dashboard.ps1`
(see [[.KCC/capabilities/skills/dashboard|dashboard]]). It writes a self-contained `dashboard/index.html`.

### CR-9 - Toolchain preflight (never silent-able)

Before any build-dependent work, the build/test toolchain must exist. Run the
toolchain preflight per [[toolchain-preflight|toolchain-preflight]]
at **two** points: (a) before implementation (after the implement-gate budget,
before the fan-out implement step) and (b) before `/spec-test`. The preflight
derives the required tools from the selected dialects / `TechnicalDecisionBrief.md`,
detects present/missing tools (helper:
`.KCC/tools/toolchain-preflight.ps1` / `.sh`), and if anything is missing
invokes the install gate (`install` / `human-install` / `defer`). Every
`install` / `human-install` / `defer` decision MUST hit the **four sinks** (per
[[toolchain-preflight|toolchain-preflight]]): the choice
in `Traces/.../HumanDecisions.md`; the events on
`coordination/backchannel.jsonl` via `.KCC/tools/backchannel-append.ps1`
(`toolchain-preflight-started`, `toolchain-preflight-result`,
`toolchain-gate-decision`, and on an approved install
`toolchain-install-complete` with command + result + re-detected version); the
install command in `Traces/.../ToolsUsed.md`; and the action in
`Traces/.../Actions.md`. Concrete example: `winget install Python.Python.3.12`
-> `toolchain-gate-decision` (human approved install) then
`toolchain-install-complete` (command, result, version after re-detect). These
writes route through Butler's trace custody + the backchannel-append helper.

Toolchain install is a **prohibited-assumption class** (system mutation +
network), same family as CR-7. **Even under `--silent --assume`, the toolchain
gate STILL stops for the human** - the AI never installs silently and never
assumes the toolchain into existence. The preflight gate is the **MANDATORY,
non-bypassable** path for a missing toolchain; there is no implicit "pick a
buildable / toolchain-free stack instead" fallback. The three outcomes
(`install` / `human-install` / `defer`) all keep the ADR-declared stack intact:
on `defer`, the implementer still writes the real declared-stack code and marks
build/test `TOOLCHAIN_DEFERRED`; the verifier writes a `toolchain-deferred`
verdict (NOT pass) and records which commands could not run.

### CR-12 - Stack is ADR-dictated (never silently changed)

The implementation stack is fixed by the architecture ADR /
`TechnicalDecisionBrief.md`, not by what toolchain is installed. A missing
toolchain routes through CR-9's preflight gate (install-after-approval) or
defers the build/test step - it is **NEVER** a license to change the stack.
Swapping the declared stack for a different one (e.g. static HTML/JS instead of
the declared TS + React) is a **prohibited silent assumption** and a
re-architecture: STOP and require a new/updated ADR + explicit human approval
via `/critical-human-gate`. This holds in every operating scenario, including
`--silent --assume`.

**Workspace tool availability MUST NOT drive idea/architecture/scope
decisions.** This applies upstream too, at the idea and architecture stages -
not only at implementation. Never silently choose a static / dependency-free /
single-spec solution "to avoid installing tools" or "so it runs in a fresh
workspace": the toolchain preflight (CR-9) handles installation
(install-after-approval, or defer build/test with the declared stack intact).
Pre-degrading the idea, the architecture, or the spec count to dodge the
preflight is a **prohibited silent assumption** (a re-architecture) and a
**Hard Stop** - escalate via `/critical-human-gate` for a new/updated ADR +
explicit human approval. A genuine throwaway static prototype must be an
explicit human choice or input, never a silent default.

### CR-13 - No silent spec-drop

Silent mode (Scenarios 2/3) must create the specs the idea / architecture
defined for the targeted scope. It must **NOT** unilaterally collapse a
multi-spec plan down to a single spec (the test8 pilot regressed by shipping 1
of 5 planned specs). If a blocker genuinely forces a reduced scope, **escalate
via `/critical-human-gate`** (present the planned spec set, the blocker, and the
proposed reduction) rather than silently dropping `SPEC-002..N`. A planned spec
set may only shrink with explicit human approval.

### CR-10 - Every lifecycle gate appends a backchannel event (never empty)

At every gate/turn, the responsible meta-agent or lifecycle agent MUST append a
backchannel event by calling `.KCC/tools/backchannel-append.ps1` or
`.KCC/tools/backchannel-append.sh`. The emit is a deterministic helper call,
never a freeform "also write JSON" step.

**Cross-cutting rule: every lifecycle transition emits its matching event via
the helper; a completed run's `backchannel.jsonl` contains the full ordered
spine.** The canonical taxonomy and per-kind payloads live in [[backchannel]];
prior kind names are retained (see that file's naming-compatibility table). Wire
the emit at each transition:

- `auto-policy-parsed` at run start (when flags are normalized).
- `trace-session-created` when Butler creates the session (via `/butler-brief`).
- `brief-issued` / `remember-stored` for each Butler wrap.
- `idea-interrogation-started` and `idea-interrogation-completed`.
- `specialist-brief-created` once per applicable specialist domain
  (`brief_type` = technical / ux / security / infrastructure; the prior
  per-domain `*-brief-issued` kinds remain valid).
- `architecture-pass-complete` after the architect pass.
- `estimate-issued` plus the decision event (`estimate-approved`,
  `estimate-auto-approved`, `auto-policy-approved`, `auto-policy-cap-exceeded`,
  or `estimate-aborted`).
- `human-gate-decision` at each human gate (confidence, loop, budget-cap, ROI,
  prohibited-assumption, toolchain).
- `spec-created` for each spec.
- `plan-created` for each planned spec.
- `toolchain-preflight-started`, `toolchain-preflight-result`, and when
  needed `toolchain-gate-decision` / `toolchain-install-complete`.
- `implement-started` and `implement-completed` for each implementation wave.
- `test-started` and `test-completed`.
- `review-produced` after `/spec-review`.
- `actual-recorded` when harness/API token actuals exist, or
  `actual-recorded` with `source: unavailable` when they do not.
- `session-closed` when the run is closed (final Butler remember turn).

**Invariant:** by the end of any real `auto` run, the run's
`coordination/backchannel.jsonl` is non-empty. If a turn completes with no new
backchannel line, the responsible meta-agent skipped its emit - re-run the
helper before advancing to the next gate. Likewise, butler-remember must have
written memory entries via `.KCC/tools/memory-append.ps1` for any non-obvious,
reusable knowledge produced during the run (a run that touched real
architecture/tech-stack decisions or hit an incident should not end with an
empty `memory/`).

### CR-11 - ROI-confidence gate (silent-mode escalation, distinct from CR-4)

The idea-interrogator's ROI step records an explicit **ROI confidence %** in
`ROI.md` and the idea file. After that step, the orchestrator inspects it:

- **ROI confidence < 60%:** PAUSE - even under `--silent --assume` - and invoke
  `/critical-human-gate` with `mode: roi-gate`. Present the ROI summary, the
  documented assumptions, and the alternatives, and capture
  `proceed / revise scope / abort`. No downstream step (architecture, spec
  creation, planning, implementation) runs until the human resolves it.
- **ROI confidence >= 60%:** continue (silently in Scenarios 2/3).

This is a separate gate from CR-4: CR-4 is the **per-decision accuracy/
confidence gate** (default 95%, fired by any agent's `Confidence: NN%` line);
CR-11 is the **idea-level ROI-confidence gate** (60%, fired once after the ROI
step) and exists specifically so silent mode does not silently pursue
low-confidence ROI. The 60% threshold is fixed and is **not** overridden by
`--accuracy` (which only tunes CR-4). The budget cap (Scenario 3) is also
independent. Both gates route through `/critical-human-gate` but for different
reasons. See [[confidence-gate|confidence-gate]].

### CR-14 - Mechanical conformance gates (self-healing, never silent-able)

Prose alone does not hold under `--silent --assume --parallel`; the orchestrator
MUST verify output mechanically with
`.KCC/tools/check-run-conformance.ps1` (`.sh` on Mac/Linux), which returns a
deterministic violation list. Run it at two checkpoints:

- **Architecture gate** - immediately after the architect pass and **before**
  `/spec-create`: run `check-run-conformance -Scope architecture`. It enforces
  that `architecture/architecture.md` exists with embedded ```mermaid```, that
  there are **zero `.mmd` files** and **no `architecture/README.md`**, and that
  each spec `arch.md` embeds >=1 diagram.
- **Run-close gate** - before `session-closed`: run `check-run-conformance`
  (full scope). It enforces the linking graph (idea<->specs<->architecture
  wikilinks, no `architecture/README` refs, no bare relative architecture
  paths), the 7 canonical trace files, and non-empty memory for substantive
  runs.

**Self-healing loop (honors `--silent`):** on any violation, do NOT proceed.
Route each violation back to its **fix owner** (the tool prints `fix owner`:
architect / spec-writer / idea-interrogator / butler) and re-run that agent with
the violation list, then re-check. This counts as a CR-3 attempt: after 3 failed
self-heal cycles for the same gate, escalate to `/critical-human-gate`. A gate
that returns `Errors: 0` is required before advancing - this is **never**
silent-able, even in Scenario 2/3. Emit a `conformance-checked` backchannel
event (pass/fail + counts) at each checkpoint.

### CR-15 - Exit checks are scripts (never agent say-so)

Every `auto` state advances only on a tool result that follows
`.KCC/kernel/contracts/tool-contract.md`: `check-run-conformance -Scope
idea|specs|plan|review|bugs|architecture|all`, `check-traceability`,
`check-wave-scope`, `check-impl-lock`, and `quality-gate`. Exit 1 routes each
violation to its `fix_owner` (self-healing, counted as CR-3 attempts). Exit 3
(deferred) is never a pass: it pauses for the human in every scenario. The
verifier re-runs traceability and the quality gate itself and records the
commands and exit codes in `review.md -> ## Evidence`.

### CR-16 - Repo bootstrap before the first write (never silent-able)

State 0 runs `.KCC/kernel/protocols/repo-bootstrap.md`. When the workspace
has no git repo or no commit, ask `init-local / connect-remote / skip` in
every scenario. Credentials come only from the human's existing credential
helper, `gh`, or ssh-agent. They are never typed into, stored by, or logged
by KCC. KCC never pushes on its own.

### CR-17 - Continuity: restore points, limits, and handover

Restore points (`kcc-checkpoint`) are written after every spec review, at the
soft usage threshold, at the hard threshold, and on every harness handover.
At the hard threshold the run enters the terminal state `SUSPENDED`, and
`kcc-limit-watch` resumes it unattended after the reset using the configured,
non-bypass permission mode. `auto resume` restores the AutoPolicy, loop
counters, and `next_action` from `coordination/checkpoints/latest.md`. See
`.KCC/kernel/protocols/session-continuity.md`.

### CR-18 - Human bug reports re-enter the flow

`/bug-report` records a Bug backlog item and routes it: planner (regression
Test ID first) -> implementer (red, then green) -> verifier. A `blocker`
pauses the run at the next state boundary and runs as an inserted wave, then
the run resumes where it was. A spec can't close with an open blocker or
major bug (`check-run-conformance -Scope bugs`).

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
   `## Reasoning`, `## Phases`, `## Upfront Budget`, `## Effort Estimate` sections
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
    cases`, CR-6) and `## Waves` (spec-layout v6).
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
| Spec | `check-run-conformance -Scope specs` exits 0 (v6 spec file, backlog items, `arch.md`, `ROADMAP.md`, sizing SZ-1..5). |
| Plan budget | Explicit human approval. |
| Plan | `plan.md` ready with `## Atomic test cases`; mapped to backlog keys. |
| Windows | Human approved or declined sub-agent sessions. |
| Implement budget | Explicit human approval. |
| Confidence (every step) | Each agent >= threshold (default 95%). |

---

## Step Details (loaded on demand by the auto skill)

Full wording for Scenario 1 steps 10-17. The auto skill state table points here.

10. **Spec creation.** Run `/spec-create <SpecWriterStarter.md>` per the
    spec-layout v5.0.0 hierarchy. Pass the IDEA-ID so spec-writer nests
    under `specs/IDEA-{ID}-{slug}-Specs/SPEC-{ID}-{slug}/`.

    When the idea's `QuickRoadmap.md` yields **multiple selected epics**:
    - **Default (sequential):** call `/spec-create` once per selected epic, one
      after another.
    - **With `--parallel` (`parallel: true`):** fan out **one `/spec-create`
      subagent per selected epic** (an L0.5 fan-out reusing the spawner contract
      and barrier semantics from
      [[parallel-execution|parallel-execution]]). Each
      subagent writes its own `SPEC-{ID}-{slug}/` folder; **await the barrier**
      (all selected epics' spec files + `ROADMAP.md` written) before
      planning. The human still chooses *which* epics to create; `--parallel` is
      standing consent to open the spec-creation windows without a separate
      prompt. Per-unit governance (butler-brief/remember, token-guard,
      confidence, CR-3 loop detection) applies to each subagent; the single
      upfront budget gate (step 9) covers all planned specs.

    **Idempotency (no duplicate specs).** Choose **exactly one** path - either the
    sequential pass **or** the parallel fan-out, never both. Each selected epic is
    created **once** and emits **one** `spec-created` backchannel event. Before
    creating a spec, check whether its `SPEC-{ID}-{slug}/` folder already exists;
    if so, skip creation (do not re-emit). (The `--parallel` regression in the
    blog pilot emitted `spec-created` twice for SPEC-001..003 by running a
    sequential pass and then a parallel pass - this guard prevents that.)

    Require (per spec):
    - `IDEA-{ID}-{slug}-Specs.md` (per-idea index, created on first spec)
    - `SPEC-{ID}-{slug}/SPEC-{ID}-{slug}.md`
    - `SPEC-{ID}-{slug}/Backlog/Story-*.md`
    - `SPEC-{ID}-{slug}/Backlog/Enabler-*.md`
    - `SPEC-{ID}-{slug}/arch.md` (section skeleton)
    - `IDEA-{ID}-{slug}-Specs/ROADMAP.md`
    - No stubs: `plan.md` and `review.md` are created by their owners.
    - Gate: `check-run-conformance -Scope specs` exits 0.
11. **Plan-gate budget.** Run `/token-estimate SPEC-{ID}`. Require explicit
    human `approve / revise / abort`.
12. **Planning.** Run `/spec-plan SPEC-{ID}`. After planning, require:
    - `plan.md` is ready, mapped to backlog item keys, and contains the
      `## Atomic test cases` section (CR-6).
    - `plan.md -> ## Waves` contains file-disjoint dependency waves and proposed sub-agent
      sessions.
13. **Sub-agent session permission.** Display the proposed parallel sessions
    from `plan.md -> ## Waves` (count, agent per session, command, working
    directory, story/enabler assignment, dialects, expected outputs). Ask
    `approve windows / sequential / abort`. **If `--parallel` is set, this gate
    is pre-authorized** (standing consent) - show the session plan for awareness
    and proceed to spawn without waiting for the prompt.
14. **Implement-gate budget.** Run `/token-estimate SPEC-{ID}` again
    (refined). Require explicit human `approve / revise / abort`.
14b. **Toolchain preflight before implementation (CR-9).** Derive required
    tools from the selected dialects / `TechnicalDecisionBrief.md` and run the
    preflight per [[toolchain-preflight|toolchain-preflight]]
    (`.KCC/tools/toolchain-preflight.ps1` / `.sh`). If any tool is missing, the
    preflight install gate (`install` / `human-install` / `defer`) is the
    **MANDATORY, non-bypassable** path **before** spawning any implementer unit.
    This gate stops for the human even under `--silent --assume`. There is **no**
    "pick a buildable / toolchain-free stack instead" behavior: per CR-12 the
    ADR-declared stack is never silently changed, and on `defer` the implementer
    writes the real declared-stack code and marks build/test `TOOLCHAIN_DEFERRED`
    rather than substituting a different stack.
15. **Implement -> Test -> Review (with fan-out execution).** This is where
    the planned concurrency actually runs - do **not** self-override to
    sequential. Per [[parallel-execution|parallel-execution]]:
    - **L2 (within a spec).** Read `plan.md -> ## Waves`. For each **wave**,
      spawn one parallel agent per independent story/enabler via the spawner
      contract `run(independent_items)` (Claude realization = one parallel
      subagent call per wave item in a single turn), **await the barrier**
      (all wave items complete), collect their outputs (files under
      `src/IDEA-{ID}-{slug}/...`, tests, agent-named trace appends), then start
      the next wave. Each spawned unit is invoked as a single-story/enabler
      `/spec-implement SPEC-{ID} Story-NNN|Enabler-NNN` writing only its
      declared impacted files.
    - **L1 (across specs).** For multi-spec ideas, first fan out across specs
      that share no cross-spec dependency (one concurrent spec flow each), then
      each spec flow runs its own L2 waves.
    - **Re-run the toolchain preflight before `/spec-test` (CR-9).** If tools
      are missing, invoke the install gate again; if the human `defer`s,
      verification writes a `toolchain-deferred` verdict (NOT pass) instead of
      degrading to a silent "blocked" stub.
    - Run `/spec-test` and `/spec-review` after a spec's waves are exhausted.
    - **HOTL gating:** in Scenario 1 the fan-out is gated by step 13 (show the
      `plan.md -> ## Waves` session plan and ask
      `approve windows / sequential / abort`) before spawning. If the human
      chose `sequential`, run the wave items one at a time instead of spawning.
      In Scenarios 2/3 the pre-flight warning pre-authorizes spawning at maximum
      parallelism; the `--budget` cap still bounds the whole wave set.
      **If `--parallel` is set (any scenario), step 13 is pre-authorized** and
      the fan-out runs without the per-spec window prompt.
    - **Governance per spawned unit:** butler-brief/remember wrap each unit
      (shared session, agent-named appends), token-guard accounts each,
      confidence-gate and loop detection (CR-3/CR-4) apply per unit; one upfront
      token-budget gate (step 14) covers the whole wave set.
16. **(Optional) `/spec-deploy SPEC-{ID}`** - only if the spec has an approved
    `InfrastructureDecisionBrief.md` AND the human opts in. Skipped by
    default; the lifecycle ends at `/spec-review` unless the human
    explicitly invokes `/spec-deploy`. Even in `--silent --assume`, deploy
    never runs silently - it requires explicit human confirmation per the
    [[deployment|deployment protocol]].
17. **Run-close gate + closeout (CR-14, CR-10).** Before finishing:
    - Run the **full** `check-run-conformance` (linking + trace + memory). On any
      error, self-heal via the printed fix owners (up to 3 cycles) then escalate.
    - Ensure `/butler-remember` ran for every agent turn and gate, and that
      substantive decisions were written to `memory/decisions/` (and preferences
      to `memory/preferences/`) via `.KCC/tools/memory-append.ps1` - an empty
      `memory/` after a real run is a violation, not an outcome.
    - Confirm the active `Traces/Session-*/` has the **7 canonical files**
      (`Decisions.md`, `Handovers.md`, `Actions.md`, `ToolsUsed.md`,
      `HumanActions.md`, `HumanDecisions.md`, `TokenUsage.md`) - copied from
      `_session-template/`. Custom files are additive, not substitutes.
    - **Token actuals (TOKEN-001).** `TokenUsage.md` must carry at least one
      *actual* row (not estimates only). On Claude Code the `SessionEnd` hook
      writes a `harness-reported` row automatically at session end; if the run
      ends inside `auto` before that fires, or on a harness without the hook, run
      `.KCC/tools/record-token-actuals.{ps1,sh}` explicitly - `-ManualTotal` when
      a metered count is known, else `-Unavailable -Reason ...`. Then run Token
      Guard **Mode D** to reconcile estimate-vs-actual and feed calibration.
    - **No silent mid-pipeline halt.** A run either completes its lifecycle
      (through `/spec-review` for each in-scope spec) or records an explicit stop
      reason in `Decisions.md` and as a backchannel event - it must never just
      end after spec creation without saying why. Emit `session-closed` last.

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
implementation; etc.), spawn sub-agent sessions per `plan.md -> ## Waves`,
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
     `## Upfront Budget`, `## Effort Estimate`.
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

### Usage block

```text
auto - KCC HOTL lifecycle skill

USAGE
  auto <input>                                          # Operating scenario 1: default HOTL
  auto <input> --silent --assume                        # Operating scenario 2: full hand-off HOTL
  auto <input> --silent --assume --accuracy NN%         #   + custom confidence floor
  auto <input> --silent --assume --accuracy NN% --budget NN [CCY]   # Operating scenario 3: controlled hand-off HOTL
  auto <input> --parallel                               # any scenario + force parallel spec creation & windows
  auto IDEA-{ID}                                        # resume from an existing idea
  auto IDEA-{ID}-{slug}                                 # resume from an existing idea (with slug)
  auto SPEC-{ID}                                        # continue an existing spec
  auto SPEC-{ID}-{slug}                                 # continue an existing spec (with slug)
  auto all                                              # progress every non-Done spec

<input> can be:
  - raw idea text                ("build me an offline solitaire game")
  - a problem statement          ("users get 500s when uploading >10MB CSVs")
  - an existing file path        ("auto C:\Work\notes\requirements.md")
  - an existing folder path      ("auto C:\Work\my-app")   <- existing-solution + idea mode

DOES NOT:
  - treat an empty invocation as a fresh idea
  - skip the upfront budget estimate (even in --silent)
  - skip architecture artifacts (even in --silent - assumptions are documented)
  - allow --silent without --assume (or vice versa)

See: .KCC/kernel/protocols/auto-mode.md
```

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
   selected epics must finish spec creation (spec files + `ROADMAP.md`)
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

Planning is not execution. After `/spec-plan` produces `plan.md -> ## Waves`,
the orchestrator **executes** the planned concurrency through the spawner
contract in [[parallel-execution]] - it must not self-override to sequential.
Two fan-out levels apply:

- **L2 - within a spec.** During implementation, the orchestrator reads
  `plan.md -> ## Waves` and, for each **wave**, spawns one agent per independent
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

- **Default `auto` (Scenario 1):** show the `plan.md -> ## Waves` session plan
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

Stop immediately and report the missing gate when any of these is true,
regardless of operating scenario (subject to operating-scenario-specific overrides above):

- Argument parsing failure (no arguments -> usage help; `--silent` without
  `--assume` or vice versa -> reject).
- Fresh idea without an `ideation/IDEA-{ID}-{slug}/` folder after step 2.
- Required idea-file sections missing after `/idea-interrogator`.
- `TechnicalDecisionBrief.md` missing before `/spec-create`.
- Required specialist brief missing for UX / security / infrastructure
  triggers.
- Required architecture artifacts (CR-2) missing before `/spec-create`.
- Confirmation step skipped in Scenario 1.
- `check-run-conformance -Scope specs` not passing before `/spec-plan`.
- Upfront, plan-gate, or implement-gate budget approval missing for the
  active operating scenario (Scenario 1: explicit human; Scenario 3: cumulative
  within cap).
- Cumulative projected spend exceeds AutoPolicy cap (Scenario 3).
- A missing answer requires a prohibited assumption (CR-7).
- Toolchain missing before implementation or before `/spec-test` and the human
  has not resolved the install gate (CR-9). Never silent, even under
  `--silent --assume`.
- A stack deviation from the architecture ADR (CR-12) - STOP and require a
  re-architecture (new/updated ADR + explicit human approval); never silently
  swap the stack, including in `--silent --assume`. A missing toolchain routes
  through the CR-9 preflight gate or defers build/test - it never changes the
  stack.
- Tool availability driving an idea/architecture/scope decision (CR-12) - STOP.
  Never silently choose a static / dependency-free / single-spec solution to
  avoid installing tools or to "run in a fresh workspace"; this pre-degradation
  is a prohibited silent assumption and re-architecture requiring a new/updated
  ADR plus explicit human approval, including in `--silent --assume`.
- A planned spec set silently reduced (CR-13) - the targeted multi-spec plan
  may not be collapsed to fewer specs without explicit human approval; escalate
  via `/critical-human-gate` instead of dropping `SPEC-002..N`.
- `plan.md` missing or not mapped to backlog items.
- `plan.md` missing the `## Atomic test cases` section (CR-6).
- `plan.md` missing `## Waves` before `/spec-implement`, or `check-impl-lock` not passing.
- Confidence below threshold (CR-4) - pause via `/critical-human-gate`.
- ROI confidence < 60% in silent mode (CR-11) - pause via
  `/critical-human-gate` (`mode: roi-gate`).
- Loop-detection trip (CR-3) - pause via `/critical-human-gate`.
- Any state exit check tool exiting 1 after 3 self-heal cycles, or exiting 3
  (deferred) without a human decision (CR-15).
- Repo bootstrap unresolved before the first lifecycle write (CR-16).
- A write under `src/` while `check-impl-lock` is closed.
- A spec closed with an open blocker or major bug (CR-18).

---

## Output Format At Each Pause

When auto pauses, the orchestrator displays:

- **Scenario in effect** (1 / 2 / 3 / `all`) and active AutoPolicy.
- **Current lifecycle step** (1-15 from Scenario 1, or resume point).
- **Files created or verified** this step.
- **Why we paused** (gate name, e.g. `confidence-gate`,
  `loop-detection`, `budget-cap-exceeded`, `prohibited-assumption`,
  `confirmation-required`).
- **Exact human decision needed** (with the literal allowed answers).
- **Loop-detection counters** with any pair at >=1.
- **AutoPolicy state**: remaining approved budget vs. cap, confidence
  threshold, assumptions made since last pause.

Do not write implementation code during interrogation, technical decision,
architecture, spec creation, token-budget, or planning stages.

---

## Implementation Lock

No application/source files may be created or edited during fresh-idea
auto mode until ALL of these are true:

1. A spec folder exists under `specs/IDEA-{ID}-{slug}-Specs/`.
2. `check-run-conformance -Scope specs` exits 0 (v6 spec file, INVEST-checked backlog items, `ROADMAP.md`).
3. `plan.md` has `## Waves`, and `check-impl-lock` exits 0 (mechanically enforced by hooks).
4. `plan.md` is ready and includes `## Atomic test cases`.
5. The post-plan token estimate is approved (explicit human, or covered
   by the active AutoPolicy budget).
6. Any below-threshold confidence gate is resolved.

When `--parallel` is set with multiple selected epics, **all** selected epics
must finish spec creation (each `SPEC-{ID}-{slug}/` folder + its
`ROADMAP.md`) before the planning phase starts - await the spec-creation
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

