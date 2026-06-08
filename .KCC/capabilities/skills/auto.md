---
# Functional fields (consumed by harness adapters)
name: auto
description: >
 Run Human-On-The-Loop lifecycle automation when the user starts a request with `auto <input>`, `auto IDEA-{ID}`, `auto SPEC-{ID}`, or `auto all`. Encodes operating scenarios (default HOTL, full hand-off HOTL, and controlled hand-off HOTL), always runs an upfront budget estimate, always produces architecture artifacts, and uses loop detection plus confidence gates to escalate to the human. Usage: `auto <input>` | `auto <input> --silent --assume` | `auto <input> --silent --assume --accuracy NN% --budget NN [CCY]` | `auto IDEA-{ID}` | `auto SPEC-{ID}` | `auto all`
argument-placeholder: <ARGS>
delegates-to:
  - idea-interrogator
  - technical-interrogator
  - ux-ui-interrogator
  - security-interrogator
  - infrastructure-interrogator
  - architect
  - spec-writer
  - token-guard
  - planner
  - implementer
  - verifier
  - critical-human-gate
maturity: L1
maintainer: tarek.fawaz1983@gmail.com
copyright: "KCC framework (c) 2026 Tarek Fawaz"
homepage: "https://tikasway.dev/kcc"
license: "Licensed under the terms in LICENSE"

# Obsidian metadata
title: Auto Mode Skill
aliases:
  - auto-skill
  - hotl-skill
tags:
  - framework/skill
  - lifecycle/auto
  - orchestration
created: 2026-05-25
updated: 2026-06-07
version: 1.15.0
status: active
---

# Auto Mode

Run the KCC HOTL lifecycle for: <ARGS>

## Trigger Rule

If the user message begins with `auto`, this skill owns the turn. Strip a
single outer pair of angle brackets from the idea text if present, for example
`auto <build a game>` becomes idea text `build a game`.

`auto` is not blanket implementation approval. It is permission to progress
through the lifecycle until a gate requires human input.

## Argument Parsing (run FIRST, before any agent dispatch)

1. **Empty / no arguments** - `auto` alone, or `auto` followed only by
   whitespace: this is **Bug-Fix 2**. Do **NOT** treat as a fresh empty idea.
   Print the usage block (see [Usage Help](#usage-help)) and exit cleanly with
   no agent dispatch and no file writes.
2. **`auto all`** - operate on every existing non-Done spec (see
   [Scenario `auto all`](#scenario-auto-all)).
3. **`auto SPEC-{ID}` or `auto SPEC-{ID}-{slug}`** - continue a single
   existing spec from its current lifecycle step.
4. **`auto IDEA-{ID}` or `auto IDEA-{ID}-{slug}`** - this is **Bug-Fix 1**.
   Resume from an existing idea (see [IDEA Continuation](#idea-continuation)).
5. **`auto <file-path>`** - `<input>` is a path to an existing file (e.g. a
   pasted requirements doc, transcript, or `SpecWriterStarter.md`). Treat the
   file contents as the raw input for `/idea-interrogator`.
6. **`auto <folder-path>`** - `<input>` is a path to an existing folder
   (likely an existing solution). Mark `input_class = existing-solution` and
   require the idea-interrogator and architect passes to produce an
   impact, gap, and alternatives analysis (see Scenario 1 step 4).
7. **`auto <input> [<input> ...]` with policy flags** - strip and normalize
   AutoPolicy flags (next subsection); remaining text is the raw idea.

### AutoPolicy Flag Normalization

Parse and normalize before classifying the operating scenario:

| Flag | Normalized | Meaning |
|--|--|--|
| `--silent` / `--slient` | `silent: true` | Suppress status interruptions. |
| `--assume` | `assume: true` | Document low-risk assumptions instead of asking. |
| `--accuracy NN%` / `--acuuracy NN%` | `confidence_threshold_pct: NN` | Default 95. |
| `--budget NN [CCY]` | `budget_cap_amount: NN`, `budget_cap_currency: CCY` | Default currency `USD` when omitted. |
| `--parallel` / `--parralel` | `parallel: true` | Force parallel agent sessions: fan out spec creation (one subagent per selected epic) and pre-authorize all parallel session windows. Default false. Scenario-independent. |

After parsing, classify the operating scenario:

| Detected | Operating scenario |
|--|--|
| no flags (or only non-policy flags) | **Operating scenario 1 - default HOTL** |
| `silent: true` AND `assume: true` AND `budget_cap_amount` is null | **Operating scenario 2 - full hand-off HOTL** |
| `silent: true` AND `assume: true` AND `budget_cap_amount` is set | **Operating scenario 3 - controlled hand-off HOTL** |
| `silent: true` XOR `assume: true` | Reject with `auto: --silent and --assume must be used together`. |

`parallel` is **independent of the operating scenario** and may combine with any
of 1/2/3 (e.g. `auto <input> --parallel`, or
`auto <input> --parallel --silent --assume --budget NN`). It does not change the
scenario classification above; it only forces parallel execution (spec-creation
fan-out + standing window consent). See "Spec creation" (step 10) and
[[../../kernel/protocols/auto-mode#--parallel-flag-semantics]].

Record the parsed AutoPolicy as a single JSON-shaped decision block before
dispatching any agent.

---

## Usage Help

Printed when `auto` is invoked with no arguments (Bug-Fix 2):

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

## Common Rules - apply in every operating scenario

These rules are non-negotiable regardless of operating scenario.

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
files** per [[../../kernel/protocols/architecture-documentation|architecture-documentation]].
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
[[../../kernel/protocols/trace-layout|trace-layout]].

Immediately after the trace session is ensured (and again after each gate),
refresh the human-facing dashboard so the human can watch progress live:
`powershell -ExecutionPolicy Bypass -File .KCC\tools\build-dashboard.ps1`
(see [[dashboard]]). It writes a self-contained `dashboard/index.html`.

### CR-9 - Toolchain preflight (never silent-able)

Before any build-dependent work, the build/test toolchain must exist. Run the
toolchain preflight per [[../../kernel/protocols/toolchain-preflight|toolchain-preflight]]
at **two** points: (a) before implementation (after the implement-gate budget,
before the fan-out implement step) and (b) before `/spec-test`. The preflight
derives the required tools from the selected dialects / `TechnicalDecisionBrief.md`,
detects present/missing tools (helper:
`.KCC/tools/toolchain-preflight.ps1` / `.sh`), and if anything is missing
invokes the install gate (`install` / `human-install` / `defer`). Every
`install` / `human-install` / `defer` decision MUST hit the **four sinks** (per
[[../../kernel/protocols/toolchain-preflight|toolchain-preflight]]): the choice
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
reasons. See [[../../kernel/protocols/confidence-gate|confidence-gate]].

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

---

## Operating scenario 1 - `auto <input>` (default HOTL)

The classic Human-In/On-The-Loop flow. Asks at every interrogation,
confirmation, and budget gate.

### Pre-flight

- Invoke `/butler-brief` to create this run's trace session before any agent
  dispatch (CR-8).
- Parse args. Detect `input_class`:
  `raw-text | problem-statement | file-path | folder-path | existing-solution-plus-idea`.
- For `folder-path` or when raw text mentions an existing system, set
  `input_class = existing-solution-plus-idea` and add the "impact + gap +
  alternatives" requirement to the idea brief (step 4 below).

### Steps

1. **Reasoning step (NEW).** Sibling C's `/idea-interrogator` implementation
   is responsible for emitting a `## Reasoning` section inside
   `ideation/IDEA-{ID}-{slug}/idea-{ID}-{slug}.md` that captures the agent's
   interpretation of the input, its framing, and the questions it intends to
   ask. The `/auto` skill simply invokes the interrogator and verifies the
   section exists after the agent returns.
2. **Idea interrogation.** Run `/idea-interrogator <input>` in full HITL
   mode. The agent asks the foundational five, follow-ups, and assumption
   verification.
3. **Idea-folder verification.** Require:
   - `ideation/IDEA-{ID}-{slug}/idea-{ID}-{slug}.md` exists.
   - The parent file contains: `## Reasoning`, `## Phases` (roadmap),
     `## Upfront Budget`, `## Effort` sections, populated.
4. **Existing-solution analysis** (only when `input_class =
   existing-solution-plus-idea`). Require the idea file to contain
   `## Impact Analysis`, `## Gap Analysis`, `## Alternatives` sections.
5. **Technical interrogation.** Run `/technical-interrogator` and require
   `ideation/IDEA-{ID}-{slug}/TechnicalDecisionBrief.md`.
6. **Conditional specialist interrogation** (run in parallel where possible):
   - `/ux-ui-interrogator` - triggered when the work touches web, mobile,
     game, dashboard, report, internal tool, or **any** screen-or-interaction
     surface. The UX agent **MUST** present at least **3 design-system
     options** (e.g. Material, Fluent, Tailwind+shadcn, Carbon, Atlassian,
     fully-custom) and capture the human's pick + rationale.
   - `/security-interrogator` - triggered for identity, data sensitivity,
     public exposure, compliance, audit, secrets, or privacy risk.
   - `/infrastructure-interrogator` - triggered for **any deployable,
     production-ready, hostable, or distributable** work, not just explicit
     cloud requests. Fire it when the work involves: cloud, on-prem,
     hybrid/agnostic hosting, K8s/containers, an API or service that ships,
     a deployable app/binary/package, packaging or distribution, production
     or staging environments, scale, observability, SLO/latency-percentile,
     DR/backup, or paid-service work. **In `--silent --assume` mode the
     default ambition is production-leaning (see Scenario 2), so this trigger
     fires by default for any build the human could realistically run in
     production** - do not skip infra interrogation merely because the human
     did not say the word "cloud". Skip only for pure local one-off scripts,
     docs-only changes, or throwaway prototypes explicitly framed as such.
7. **Confirmation step (NEW).** The orchestrator restates **every captured
   answer** (foundational answers, technical decisions, specialist outcomes,
   chosen design system) as a single bulleted recap and asks one question:
   `confirm all / revise <topic> / abort`. No agent advances until the human
   answers.
8. **Architect pass (REQUIRED - see CR-2).** Produce `architecture/architecture.md`
   (narrative + embedded ```mermaid``` C4 Context + Container), workflow
   flowcharts, DFDs as needed - all **embedded in `.md`, never `.mmd`, and no
   `architecture/README.md`**. Update `architecture/adrs/`,
   `architecture/guardrails.md`, `architecture/quality-gates.md`. The architect
   MUST self-review via `/architecture-review` (mandatory in every scenario).
8b. **Architecture-conformance gate (CR-14).** Run
   `.KCC/tools/check-run-conformance.ps1 -Scope architecture` (`.sh` on
   Mac/Linux). If it reports any error, route the violations back to the
   architect and re-run (self-healing); after 3 failed cycles escalate via
   `/critical-human-gate`. Do **not** proceed to `/spec-create` until it returns
   `Errors: 0`. Emit a `conformance-checked` backchannel event.
9. **Upfront budget estimate (CR-1).** Run `/token-estimate IDEA-{ID}` in
   idea-scope mode against the phases/epics breakdown. Display the
   pessimistic estimate with +/-50% band. Ask the human:
   `approve upfront budget / revise scope / abort`.
10. **Spec creation.** Run `/spec-create <SpecWriterStarter.md>` per the
    spec-layout v5.0.0 hierarchy. Pass the IDEA-ID so spec-writer nests
    under `specs/IDEA-{ID}-{slug}-Specs/SPEC-{ID}-{slug}/`.

    When the idea's `QuickRoadmap.md` yields **multiple selected epics**:
    - **Default (sequential):** call `/spec-create` once per selected epic, one
      after another.
    - **With `--parallel` (`parallel: true`):** fan out **one `/spec-create`
      subagent per selected epic** (an L0.5 fan-out reusing the spawner contract
      and barrier semantics from
      [[../../kernel/protocols/parallel-execution|parallel-execution]]). Each
      subagent writes its own `SPEC-{ID}-{slug}/` folder; **await the barrier**
      (all selected epics' folders + `parallelization.md` written) before
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
    - `SPEC-{ID}-{slug}/backlog.md`
    - `SPEC-{ID}-{slug}/Backlog/Story-*.md`
    - `SPEC-{ID}-{slug}/Backlog/Enabler-*.md`
    - `SPEC-{ID}-{slug}/parallelization.md`
    - `plan.md`, `review.md`, `budget.md`, `handovers.md` stubs.
11. **Plan-gate budget.** Run `/token-estimate SPEC-{ID}`. Require explicit
    human `approve / revise / abort`.
12. **Planning.** Run `/spec-plan SPEC-{ID}`. After planning, require:
    - `plan.md` is ready, mapped to backlog item keys, and contains the
      `## Atomic test cases` section (CR-6).
    - `parallelization.md` contains dependency waves and proposed sub-agent
      sessions.
13. **Sub-agent session permission.** Display the proposed parallel sessions
    from `parallelization.md` (count, agent per session, command, working
    directory, story/enabler assignment, dialects, expected outputs). Ask
    `approve windows / sequential / abort`. **If `--parallel` is set, this gate
    is pre-authorized** (standing consent) - show the session plan for awareness
    and proceed to spawn without waiting for the prompt.
14. **Implement-gate budget.** Run `/token-estimate SPEC-{ID}` again
    (refined). Require explicit human `approve / revise / abort`.
14b. **Toolchain preflight before implementation (CR-9).** Derive required
    tools from the selected dialects / `TechnicalDecisionBrief.md` and run the
    preflight per [[../../kernel/protocols/toolchain-preflight|toolchain-preflight]]
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
    sequential. Per [[../../kernel/protocols/parallel-execution|parallel-execution]]:
    - **L2 (within a spec).** Read `parallelization.md`. For each **wave**,
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
      `parallelization.md` session plan and ask
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
    [[../../kernel/protocols/deployment|deployment protocol]].
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

## Operating scenario 2 - `auto <input> --silent --assume` (full hand-off HOTL, unlimited)

Hands-off operation. Documents assumptions instead of asking. Pauses only
on hard safety gates and the ROI-confidence gate (CR-11).

### Silent-mode default ambition (MID-LEVEL + MODERATE RESEARCH)

`--silent --assume` is **NOT** a license to ship the smallest, simplest,
single-spec stub. The pilots showed silent mode defaulting to
minimal/single-spec/simple - that is wrong. The default posture is
**mid-level ambition with moderate research**:

- **Architecture depth defaults to `standard`** (an app/API/service with
  users, persistence, or integrations), **not `minimal`/lite**. Only drop to
  `minimal` when the idea is genuinely a CLI/script/docs-only change; only rise
  to `distributed`/`regulated` when the idea's content clearly demands it.
- **Decompose into MULTIPLE specs whenever the idea spans distinct concerns.**
  Never force a single spec just because the run is silent. If the idea has
  separable epics (e.g. API + UI + data pipeline, or auth + core domain +
  reporting), the idea-interrogator's Phases/Epics breakdown and `/spec-create`
  produce one spec per distinct concern.
- **Implementation is a production-leaning baseline, not gold-plated:** include
  authentication/authorization where relevant, input validation, error
  handling, tests (unit + integration via the testing dialects), and API
  standards (OpenAPI for any HTTP API). Do **not** add speculative
  extensibility, premature optimization, or features the idea did not ask for.
- **Moderate research:** the idea-interrogator runs a moderate web-research
  pass on prior art + relevant standards before assuming - it does **not**
  assume from zero. (See idea-interrogator agent, silent-mode research rule.)
- **Specialist interrogation still fires by triggers** - in particular the
  infrastructure interrogator fires by default for any production-leaning /
  deployable / API build (Scenario 1 step 6 trigger, broadened wording).

Record the chosen depth and the multi-spec-vs-single-spec decision (with the
distinct concerns enumerated) in the idea file's `## Idea Planning` and
`## Assumptions` sections so the human can audit the ambition level.

### Pre-flight warning (MANDATORY - display before any agent dispatch)

```text
WARNING - Silent + assume mode

Agents will document low-risk assumptions and run with:
  - unlimited token budget (no cap)
  - maximum parallel sessions allowed by default
  - NO interrogation questions asked

You will be paused ONLY for:
  - any agent reporting confidence below NN% (default 95%, configurable via --accuracy)
  - ROI confidence below 60% from the idea-interrogator's ROI step (CR-11)
  - loop detection: same agent failing the same step 3 times
  - a prohibited assumption (legal, security, privacy, compliance, data
    sensitivity, destructive, external spend, production-impacting)

Default ambition is MID-LEVEL with MODERATE RESEARCH:
  - standard architecture depth (not minimal/lite)
  - MULTIPLE specs when the idea spans distinct concerns
  - production-leaning baseline (auth where relevant, input validation,
    error handling, tests, OpenAPI for APIs) - not gold-plated
  - a moderate web-research pass on prior art + standards before assuming

Architecture artifacts will still be produced (assumptions documented).
Upfront budget estimate will still be shown (as awareness, not as a gate).

Proceed? yes / no
```

If the human declines, fall back to Scenario 1.

### Steps (deltas vs. Scenario 1)

1. **Reasoning step + idea interrogation in silent mode.** Invoke
   `/idea-interrogator <input> --silent --assume`. The interrogator
   documents assumptions in `idea-{ID}-{slug}.md` instead of asking, runs a
   **moderate web-research pass** before assuming, defaults architecture depth
   to **`standard`**, and frames the idea at **mid-level ambition** (multiple
   specs when the idea spans distinct concerns - per the silent-mode default
   ambition above).
1b. **ROI-confidence gate (CR-11).** After the idea-interrogator produces
   `ROI.md` with an explicit **ROI confidence %**, inspect it. **If ROI
   confidence is below 60%, STOP even in silent mode** and invoke
   `/critical-human-gate` with `mode: roi-gate`, presenting the ROI summary,
   the documented assumptions, and the alternatives. The human chooses
   `proceed / revise scope / abort`. At or above 60%, continue silently. This
   is distinct from the 95% per-decision confidence gate (CR-4) and from the
   budget cap.
2. **Idea-folder verification** - same as Scenario 1, plus a populated
   `## Assumptions` section, the recorded architecture depth (`standard` by
   default), and the multi-spec-vs-single-spec decision with its enumerated
   distinct concerns.
3. **Skip the question-asking** in `/technical-interrogator`,
   `/ux-ui-interrogator`, `/security-interrogator`,
   `/infrastructure-interrogator` - but **still produce** their decision
   briefs from assumptions. UX still emits the 3-design-system comparison;
   the agent picks the default-best with rationale rather than asking.
4. **Skip the confirmation step (Scenario 1 step 7).**
5. **Architect pass STILL RUNS (CR-2).** All artifacts produced, with diagrams
   **embedded in `.md` (never `.mmd`)** and **no `architecture/README.md`**; each
   contains an `## Assumptions` block. Mandatory `/architecture-review`, then the
   **architecture-conformance gate (CR-14, step 8b)** must return `Errors: 0`
   before spec creation - self-healing, never silent-able.
6. **Upfront budget (CR-1)** - show estimate as awareness only, no gate.
7. **Spec creation, planning** - proceed without human gates.
8. **Maximum parallel sessions** - open the full fan-out from
   `parallelization.md` without asking permission (the pre-flight warning
   covered window-opening consent for this scenario).
9. **Budget gates do not pause** - both `/token-estimate` calls record
   `auto-policy-approved-unlimited` and continue.
10. **Pause-only triggers** (apply throughout):
    - Confidence below threshold -> `/critical-human-gate`.
    - ROI confidence below 60% (CR-11) -> `/critical-human-gate` (`mode: roi-gate`).
    - Loop detection trip (CR-3) -> `/critical-human-gate`.
    - Prohibited-assumption need (CR-7) -> `/critical-human-gate`.
    - Conformance gate failure after 3 self-heal cycles (CR-14) ->
      `/critical-human-gate`. The CR-14 architecture and run-close gates still
      run in silent mode; they self-heal by routing back to the fix owner and are
      never silent-able.

---

## Operating scenario 3 - `auto <input> --silent --assume --accuracy NN% --budget NN [CCY]` (controlled hand-off HOTL)

Like Scenario 2, but with a hard budget cap and a tunable confidence floor.
**It inherits Scenario 2's mid-level + moderate-research default ambition**
(standard depth, multi-spec decomposition when the idea spans distinct
concerns, production-leaning baseline, moderate research) **and the CR-11
ROI-confidence gate at 60%** - the budget cap and the `--accuracy` floor do not
replace either. The 60% ROI gate is fixed regardless of the `--accuracy` value.

### Pre-flight warning (MANDATORY)

Same warning as Scenario 2 (including the mid-level ambition + ROI-gate lines),
plus this appended block:

```text
BUDGET CAP - {amount} {currency}

The upfront token-guard estimate runs in idea-scope mode immediately after
/idea-interrogator produces phases + epics. The first estimate uses a
pessimistic +/-50% confidence band and tightens to +/-20% as specs are created.

If the upfront estimate EXCEEDS {amount} {currency}, the run STOPS for you.
If any per-spec re-estimate pushes the cumulative total over the cap, the
run STOPS for you.

Any decision below {threshold}% confidence triggers a REFINEMENT loop with
you (not a hard abort).

Loop detection still applies: 3 trials per (agent, step).

Proceed? yes / no
```

### Steps (deltas vs. Scenario 2)

0. **CR-11 ROI-confidence gate still applies.** Inherited unchanged from
   Scenario 2 step 1b: if ROI confidence < 60%, STOP and escalate via
   `/critical-human-gate` (`mode: roi-gate`) before the budget gate runs.
1. **Upfront budget IS A HARD GATE.** Run `/token-estimate IDEA-{ID}` in
   idea-scope mode immediately after `/idea-interrogator` produces the
   phases + epics breakdown.
   - If estimate **> budget cap** -> STOP. Display estimate, cap, gap, and
     ask `revise scope / increase cap / abort`. Cannot proceed silently.
   - If estimate **<= budget cap** -> record `auto-policy-approved-bounded`
     in `coordination/backchannel.jsonl` and continue silently.
2. **Per-spec re-estimates** (plan gate + implement gate) recompute the
   cumulative projected spend. If the cumulative crosses the cap -> STOP for
   the human with the same `revise / increase / abort` prompt.
3. **Confidence below `--accuracy` threshold** triggers a **refinement
   loop**, not a hard abort:
   - Invoke `/critical-human-gate` with `mode: refinement`.
   - The human supplies missing inputs; the agent re-runs once.
   - If the second attempt still misses, this counts toward CR-3 loop
     detection; the third miss escalates per CR-3.
4. **Architecture pass STILL RUNS** with documented assumptions (CR-2).
5. **Loop detection (CR-3)** still applies - max 3 trials per
   `(agent, step)`.

---

## Scenario `auto all`

Operate on every spec whose status is not `Done`.

1. Enumerate `specs/IDEA-*-Specs/SPEC-*/SPEC-*.md` and filter on
   `status != Done`.
2. For each, determine its current lifecycle step from its folder contents
   (plan absent -> planning needed; plan ready, no implementation diff ->
   implementation needed; etc.).
3. Fan out per [[../../kernel/protocols/parallel-execution|parallel-execution]]:
   first across independent specs (**L1** - one concurrent spec flow per spec
   with no cross-spec dependency), then each spec flow runs its
   `parallelization.md` waves (**L2** - one agent per independent
   story/enabler, barrier between waves). Respect CR-3 loop detection per
   `(agent, step, spec)` and the active AutoPolicy from the invocation
   (Scenario 1, 2, or 3 semantics).
4. Apply the appropriate scenario's gating rules per spec.

---

## IDEA Continuation

**Bug-Fix 1.** When the argument matches `IDEA-{ID}` or `IDEA-{ID}-{slug}`:

1. Resolve the idea folder:
   - Exact match: `ideation/IDEA-{ID}-{slug}/`.
   - ID-only match: search `ideation/IDEA-{ID}-*/` and pick the unique
     match; if ambiguous, list candidates and stop.
   - No match: print `auto: idea {arg} not found under ideation/` and exit.
2. Inspect the idea folder for **brief completeness**. The brief is
   **complete** when all of these exist and are populated:
   - `idea-{ID}-{slug}.md` with `## Reasoning`, `## Phases`,
     `## Upfront Budget`, `## Effort` sections.
   - `Questionnaire.md`, `HumanAnswers.md`, `Research.md`, `ROI.md`,
     `Conclusion.md`, `QuickRoadmap.md`, `SpecWriterStarter.md`.
   - For `input_class = existing-solution-plus-idea`: also
     `## Impact Analysis`, `## Gap Analysis`, `## Alternatives` in the
     idea file.
3. **Resume point selection:**

   | Missing artifact | Resume at |
   |--|--|
   | `idea-{ID}-{slug}.md` itself or any of the seven artifacts | Scenario 1 step 2 (`/idea-interrogator`) |
   | `TechnicalDecisionBrief.md` | Scenario 1 step 5 (`/technical-interrogator`) |
   | Required specialist brief (UX/security/infra) per content triggers | Scenario 1 step 6 |
   | Confirmation never recorded in trace | Scenario 1 step 7 |
   | Architecture artifacts (CR-2) missing | Scenario 1 step 8 |
   | Upfront budget decision missing | Scenario 1 step 9 |
   | No matching `specs/IDEA-{ID}-{slug}-Specs/` folder | Scenario 1 step 10 (`/spec-create`) |
   | Spec exists but `plan.md` is a stub | Scenario 1 step 11 |
   | Plan exists but no implementation diff | Scenario 1 step 14 |

4. If the brief is **complete** and nothing downstream exists, **skip step
   2** and resume at **step 5** (`/technical-interrogator`), per the
   bug-fix specification.
5. AutoPolicy flags on the continuation invocation apply for the remaining
   steps (so `auto IDEA-007 --silent --assume --budget 50` switches the
   downstream remainder to Scenario 3 semantics).

---

## SPEC Continuation

`auto SPEC-{ID}` or `auto SPEC-{ID}-{slug}` resolves the spec folder under
any `specs/IDEA-*-Specs/` parent and resumes from its current lifecycle
step using the same resume table as IDEA continuation (entries for step 11
and later). AutoPolicy flags apply to the remainder.

---

## Hard Stops

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
- Spec folder note, `backlog.md`, backlog item files, or
  `parallelization.md` missing before `/spec-plan`.
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
- `parallelization.md` missing dependency waves before `/spec-implement`.
- Confidence below threshold (CR-4) - pause via `/critical-human-gate`.
- ROI confidence < 60% in silent mode (CR-11) - pause via
  `/critical-human-gate` (`mode: roi-gate`).
- Loop-detection trip (CR-3) - pause via `/critical-human-gate`.

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

## Related

- Auto-mode protocol: [[../../kernel/protocols/auto-mode]]
- Trace layout (run-start session creation): [[../../kernel/protocols/trace-layout]]
- Spec layout (v5.0.0): [[../../kernel/protocols/spec-layout]]
- Parallel execution (fan-out + spawner contract): [[../../kernel/protocols/parallel-execution]]
- Toolchain preflight (CR-9 install gate): [[../../kernel/protocols/toolchain-preflight]]
- Confidence gate: [[../../kernel/protocols/confidence-gate]]
- Token budget: [[../../kernel/protocols/token-budget]]
- Architecture governance: [[../../kernel/protocols/architecture-governance]]
- Deployment protocol: [[../../kernel/protocols/deployment]]
- Critical human gate: [[critical-human-gate]]
- Idea interrogator: [[idea-interrogator]]
- Token estimate: [[token-estimate]]
- Spec deploy: [[spec-deploy]]
