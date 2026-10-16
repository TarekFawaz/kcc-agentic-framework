---
# Functional fields (consumed by harness adapters)
name: auto
description: >
 Human-On-The-Loop lifecycle automation for requests starting with `auto`: idea -> specialist briefs -> architecture -> budget -> specs + roadmap -> plan -> implement -> test -> review, as a closed state machine whose exit checks are scripts, with confidence, ROI, loop, budget, toolchain, quality, and usage-limit gates. Usage: auto <input> [--silent --assume] [--accuracy NN%] [--budget NN CCY] [--parallel] [--fasttrack] [--depthlevel 1-5] ; auto IDEA-{ID} ; auto SPEC-{ID} ; auto all ; auto resume
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
updated: 2026-09-21
version: 3.0.0
status: active
---

# Auto Mode

Run the KCC HOTL lifecycle for: <ARGS>

This is a **closed state machine**. Each state ends in exactly one of:
**NEXT** (its exit check passed), **PAUSE** (a human gate; resume in the same
state), or **STOP** (terminal; log the reason in `Decisions.md` and emit an
event). Never run a step that isn't in the table below, and never end a run
without a terminal state.

**Exit checks are scripts.** `CRC <scope>` means
`.KCC/tools/check-run-conformance.ps1|.sh -Scope <scope> -Json`. Every tool
follows `.KCC/kernel/contracts/tool-contract.md`: exit 0 = pass, 1 = fix
(route each violation to its `fix_owner`), 3 = deferred (never a pass). A
state never advances on an agent's own word alone.

The full rule text is in `.KCC/kernel/protocols/auto-mode.md` (the protocol).
Grep for the named heading and read only that section, and only when a gate
fires or a check fails.

## 0. Parse (before any dispatch)

| Input | Route |
|--|--|
| empty | Print protocol -> *Usage block*. STOP with no dispatch and no writes. |
| `resume` | Read `coordination/checkpoints/latest.md` (or a `coordination/handover/HO-*.md` named in the prompt); restore the AutoPolicy and loop counters; go to its `next_action` state. |
| `all` | -> [ALL](#3-resume-and-all) |
| `SPEC-{ID}[-slug]` | Resolve under `specs/IDEA-*-Specs/`, then -> [RESUME](#3-resume-and-all) |
| `IDEA-{ID}[-slug]` | Resolve `ideation/IDEA-{ID}-*/`. Ambiguous: list the candidates and STOP. None: print `auto: idea {arg} not found under ideation/` and STOP. Otherwise -> RESUME. |
| file path | File contents = raw idea. `input_class=file-path` |
| folder path | `input_class=existing-solution-plus-idea` |
| text | Raw idea. Strip one outer `<...>`. |

**Flags** (typos accepted): `--silent`/`--slient`, `--assume`,
`--accuracy NN%`/`--acuuracy` (confidence threshold, default 95),
`--budget NN [CCY]` (currency defaults to USD), `--parallel`/`--parralel`,
`--fasttrack`/`--fasttarck` (lean build path, see section 2a),
`--depthlevel N` (1-5, default 5; how much detail agents write, see
`.KCC/kernel/protocols/depth-levels.md`; `--fasttrack` implies 2).

**Scenario:** S1 = neither `--silent` nor `--assume`. S2 = both, no budget.
S3 = both, plus a budget. Only one of the two -> print
`auto: --silent and --assume must be used together` and STOP.
`--parallel`, `--fasttrack`, and `--depthlevel` combine with any scenario.

**Events as they happen (chat sessions).** Emit each spec's event the moment that spec's agent
returns, not in a batch at the end of a state, so the dashboard times are real. Every question to
the human is a gate: emit `human-gate-triggered` (payload `gate_id` GATE-NNN, `state`) before
asking and `human-gate-decision` with the same `gate_id` after the answer, so waiting on the
human shows as human time.

**Dashboard (ask once).** When this run is started in a session (not by `kcc-run`, which
asks for itself), read `.KCC/settings.json` -> `dashboard.auto_open`. `yes`: run
`build-dashboard -Open` once at run start. `no`: do nothing. `ask` (default): ask the human
once - open it now, always, or never - and save always/never to that setting. Never open it
without that permission, and do not ask again for the same run.

Write the AutoPolicy as one JSON block and emit `auto-policy-parsed`. For S2
and S3, show protocol -> *Operating scenario 2 (or 3)* -> *Pre-flight warning*.
If the human answers `no`, run as S1.

## 1. Invariants (every state)

- **Run start (CR-8):** `/butler-brief` creates the trace session before the
  first dispatch (not under `--fasttrack`). Refresh the dashboard after every gate
  (`.KCC/tools/build-dashboard.ps1|.sh`).
- **Spawn** every delegate per `coordination/orchestrator.md` -> *Spawn
  protocol*. Each unit is wrapped by butler brief/remember and accounted for
  by token-guard.
- **Evidence (CR-10):** every transition emits its *Event* through
  `.KCC/tools/backchannel-append.ps1|.sh`. No transition happens without an
  event.
- **Confidence (CR-4):** below the threshold -> PAUSE `/critical-human-gate`.
  In S3 this is `mode: refinement`: one re-run after the human answers.
- **Loops (CR-3):** 3 consecutive failures of the same (agent, state),
  counting failed exit checks -> PAUSE gate (`revise / escalate / abort`).
  A success resets the count. Two things are not retried at all: a Bug with
  `Status: blocked` (it needs a human ruling) pauses the `ruling` gate (`revise / waive /
  escalate / abort`) at once, and a third full verifier pass for one spec pauses the loop
  gate instead (at most two full passes per spec; later TEST runs re-verify only what
  changed). Neither gate is ever answered by `--silent --assume`.
- **Never silent** in any scenario: prohibited assumptions (CR-7), repo
  bootstrap, toolchain and scanner install (CR-9), and conformance errors
  (CR-14).
- **Stack (CR-12):** comes from the ADR. Tool availability never shapes the
  idea, architecture, or scope. A deviation -> PAUSE for a new ADR.
- **Scope (CR-13):** the planned spec set never shrinks without human
  approval. Splitting to meet the sizing rules is allowed.
- **Implementation lock:** `check-impl-lock` must pass before any write under
  `src/`. On Claude Code a `PreToolUse` hook enforces it; the pre-commit hook
  enforces it everywhere git exists.
- **Usage limits:** at the soft threshold, finish the current unit and spawn
  nothing new. At the hard threshold the limit guard writes a restore point
  and arms `kcc-limit-watch`, which resumes the run unattended after the
  reset (`.KCC/kernel/protocols/session-continuity.md`).
- **Bugs:** `/bug-report` may interrupt any state. A `blocker` pauses at the
  next state boundary, runs as an inserted wave (planner -> implementer ->
  verifier), then returns to the interrupted state.

## 2. State table

Gate columns: **S1** / **S2** / **S3**. A dash means no gate: continue when the
exit check passes.

| # | State | Do | Exit check | Gate | Event |
|--|--|--|--|--|--|
| 0 | REPO | `repo-bootstrap -Json` (`.KCC/kernel/protocols/repo-bootstrap.md`) | a git repo with >= 1 commit, or a recorded `skip` | No repo -> PAUSE `init-local / connect-remote / skip`, in all scenarios (asked once per workspace) | `repo-bootstrap-decision` |
| 1 | IDEA | Spawn the **butler** subagent for `/butler-brief` (`--fasttrack`: memory only) in the same message as `/idea-interrogator <input>`. S2/S3 add `--silent --assume`: moderate research, depth `standard`; likely epics are user-visible slices within the spec budget (`--fasttrack`: `spec_sizing.max_specs_fasttrack`, default 5). | `CRC idea` | S1 interrogation is interactive | `idea-interrogation-started` / `-completed` |
| 2 | ROI | Read ROI confidence % from `ROI.md` (CR-11) | value recorded | < 60% -> PAUSE `mode: roi-gate`, in all scenarios; `--accuracy` does not change this | `human-gate-decision` if paused |
| 3 | TECH | `/technical-interrogator` | `TechnicalDecisionBrief.md` exists | S1 asks; S2/S3 assume | `specialist-brief-created` |
| 4 | SPECIALISTS | In parallel, per protocol -> *Operating scenario 1* -> *Step sequence* item 6: UX (any screen), security (identity, data, exposure, compliance, secrets, privacy), infra (anything deployable; on by default in silent mode) | each triggered brief exists; the UX brief lists >= 3 design-system options | S1 asks; S2/S3 assume | `specialist-brief-created` (per domain) |
| 5 | CONFIRM | S1 only: recap every captured answer | answer logged | S1 PAUSE `confirm all / revise <topic> / abort`; S2/S3 skip | `human-gate-decision` |
| 6 | ARCH | architect pass (CR-2), including the `quality-gates.md` catalog (QG-TRACE, QG-QUALITY, QG-PROD, QG-ARCH-DOCS, QG-BUGS), then `/architecture-review` | critic verdict CONFORMANT | - | `architecture-pass-complete` |
| 7 | ARCH-GATE | `CRC architecture` (CR-14) | exit 0 | On violations, re-run the fix owner (up to 3 cycles), then PAUSE | `conformance-checked` |
| 8 | BUDGET-0 | `/token-estimate IDEA-{ID}`, idea scope (CR-1) | estimate shown | S1 PAUSE `approve / revise / abort`. S2 shown for awareness only. S3: over the cap -> PAUSE `revise / increase / abort` | `estimate-issued` + `estimate-approved` / `auto-policy-approved-unlimited` / `auto-policy-approved-bounded` / `auto-policy-cap-exceeded` |
| 9 | SPECS | `/spec-create` per selected epic, passing IDEA-ID (CR-5): v6 single-file specs sized to the smallest user-valuable delivery, plus `ROADMAP.md`. `--parallel`: one subagent per epic, then a barrier. Skip any spec folder that already exists. Token-guard fills the ROADMAP Token Plan. | `CRC specs` (sizing SZ-1..5, links, roadmap) | - | `spec-created` (exactly once per spec), `roadmap-created` |

States 10-17 run **per spec**, scheduled only by `ROADMAP.md` -> `Depends on`: every
spec is planned just in time (when every spec it depends on has started building); its IMPLEMENT starts as soon as every
spec it depends on is APPROVED, even while other specs are still planning (each spec moves
on its own clock: background subagents in an interactive session), so independent specs build at the same time (L1,
`parallel-execution.md` -> *L1*) with no flag or gate.

| # | State | Do | Exit check | Gate | Event |
|--|--|--|--|--|--|
| 10 | BUDGET-P | `/token-estimate SPEC-{ID}` | estimate shown | S1 PAUSE. S2 -. S3: cumulative over the cap -> PAUSE | `estimate-issued` + decision |
| 11 | PLAN | `/spec-plan SPEC-{ID}`: architect writes the spec's `arch.md` slice, then the planner (both inside PLAN, per spec, in parallel across ready specs; under `kcc run` the PLAN of all specs runs at once before any build starts) | `CRC plan` (AC coverage, SZ-4, file-disjoint `## Waves`) | - | `arch-slice-created`, `plan-created` |
| 12 | WINDOWS | Show the session plan | decision logged | S1 PAUSE `approve windows / sequential / abort` (pre-approved if `--parallel`). S2/S3 pre-approved | `human-gate-decision` |
| 13 | BUDGET-I | `/token-estimate SPEC-{ID}` (refined) | estimate shown, then `check-impl-lock -Spec` exits 0 | same as state 10 | `estimate-issued` + decision |
| 14 | PREFLIGHT | Toolchain preflight (CR-9), `toolchain-preflight`, including the scanners that `quality-gate` needs | tools present, or gate resolved | Missing tools -> PAUSE `install / human-install / defer` in **all** scenarios | `toolchain-preflight-started` / `-result` / `toolchain-gate-decision` |
| 15 | IMPLEMENT | For each wave in `plan.md -> ## Waves`: one `/spec-implement SPEC-{ID} Story-NNN\|Enabler-NNN\|Bug-NNN` subagent per item, all in one message, then a barrier, then `check-wave-scope -Spec -Wave N -TestCommand <suite>`. Run items one at a time if the human chose `sequential`. | `check-wave-scope` exits 0 for every wave | - | `implement-started` / `-completed` |
| 16 | TEST | Re-run the preflight, then `/spec-test` | `check-traceability -Spec` exits 0; `quality-gate -Spec` exits 0. Exit 3 -> verdict `quality-deferred` (NOT a pass) | exit 3 -> PAUSE `install / accept-deferred / abort`, in all scenarios | `test-started` / `-completed`, `quality-gate-result` |
| 17 | REVIEW | `/spec-review`. The verifier re-runs the checks itself, and failing ACs become `Backlog/Bug-*` | `CRC review` + `CRC bugs` (evidence block present; APPROVED only with traceability pass, quality pass, and no open blocker/major bug) | CHANGES_NEEDED -> back to state 15 for the Bug/failing items (counts toward CR-3) | `review-produced`, then `kcc-checkpoint -Reason spec-reviewed` |

| # | State | Do | Exit check | Gate | Event |
|--|--|--|--|--|--|
| 18 | CLOSE | Full `CRC all`, `/butler-remember` by the spawned **butler** subagent (never done inline by the orchestrator) plus `memory-append` for reusable knowledge, token actuals via `record-token-actuals` then token-guard Mode D. Details: protocol -> *Step Details* item 17 | exit 0; all 7 canonical trace files; at least one actual token row | Self-heal up to 3 cycles, then PAUSE | `conformance-checked`, `actual-recorded`, `session-closed` (last) |

## 2a. Fast track (`--fasttrack`)

A running app first, with as little paperwork as the quality gates allow. Fast track is **its own
state table**, `.KCC/kernel/auto-states-fasttrack.json`; `kcc-run` and this skill follow it instead
of the table above. The states below are the whole fast-track lifecycle: ROI, CONFIRM, ARCH-GATE,
BUDGET-* and WINDOWS do not exist in it. Ids match the full table so the dashboard and events line up (10 is WRITE here, BUDGET-P there).
WRITE and PLAN are `fanout` states: every spec goes through them side by side before any spec is built.

| # | State | Do | Exit check (outcome, not shape) | Event |
|--|--|--|--|--|
| 0 | REPO | git bootstrap | repo with a commit | `repo-bootstrap-decision` |
| 1 | IDEA | one `idea-interrogator` pass: idea file, short `Research.md` with `## Domain` (common / specialised / novel), `QuickRoadmap.md`, `SpecWriterStarter.md` with at most the spec budget of epics, the first a walking skeleton. Open questions are collected under `## Open questions`, never asked | the four files exist, `CRC idea` | `idea-interrogation-completed` |
| 4 | BRIEFS | technical, infrastructure, ux-ui, security interrogators **at the same time** (four subagents in one message); each writes its brief from the idea and the standards catalogue and lists at most 5 open questions; none asks the human | the four briefs exist | `specialist-brief-created` |
| 5 | ASK | the only question round: merge the open questions (<= 5 per domain). `--silent --assume`: answer them from the catalogue and the idea into `Assumptions.md` (question, assumed answer, rule, risk); a CR-7 question with no catalogue default stays open and is asked. Otherwise one `AskUserQuestion`, with `human-gate-triggered` / `human-gate-decision` around it, into `HumanAnswers.md`; then update the briefs | `HumanAnswers.md` or `Assumptions.md` | `human-gate-decision` |
| 6 | ARCH | architect, fast-track profile: `architecture.md` with C1 and C2 embedded, business flowcharts, a `## Decisions` table (library + version range, catalogue citation, `Accepted` / `Accepted (assumed)`) instead of ADR files, `## Toolchain`, `quality-gates.md`. No `adrs/`, `c4-component`, `dfds/`, `sequences/`, no critic loop: one self-check with `CRC architecture -RunProfile fasttrack` | `CRC architecture -RunProfile fasttrack` (ARCH-FT-*: over-production is drift) | `architecture-pass-complete` |
| 9 | SPECS | `/spec-create --split-only` proposes the split (<= `spec_sizing.max_specs_fasttrack`, SPEC-001 a walking skeleton, explicit `Depends on`), asks the human once to approve or change it (silent: applies the budget; a larger approved split is `Spec budget: N (human approved)` in ROADMAP.md), and writes only the split: `ROADMAP.md` plus a stub note per spec | ROADMAP.md lists specs, each with a folder and a stub note (`internal:roadmap-specs`) | `roadmap-created` |
| 10 | WRITE | per spec, **all specs at once** (one `spec-writer` subagent per spec, in one message; `kcc run` runs one `claude -p --agent spec-writer` per spec, up to `--max-parallel`): `/spec-create --spec SPEC-NNN` writes that spec's note, Backlog items and `arch.md` from its stub, and nothing else | `CRC specs -Spec SPEC-NNN` under the fast-track profile (SPEC-009 budget, SPEC-010 status) | `spec-created` |
| 11 | PLAN | per spec, **all specs at once** (one `planner` subagent per spec, in one message; `kcc run` runs one `claude -p --agent planner` per spec): `/spec-plan SPEC-NNN --fasttrack`. Planning needs only the spec files, the architecture and the dialects, so `Depends on` is ignored. A failed plan retries alone | `CRC plan -Spec SPEC-NNN` (a plan per spec) | `plan-created` |
| 14 | PREFLIGHT | per spec, `toolchain-preflight` with the plan's `## Toolchain` ranges | tools present or gate | `toolchain-preflight-result` |
| 15 | IMPLEMENT | per spec by dependency (`parallel-execution.md` -> L1): one implementer per wave item in one message, then `check-wave-scope` | code changed per the plan (WAVE-004 fails an empty wave) | `implement-completed` |
| 16 | TEST | `/spec-test`: the **full** `quality-gate`; exit 3 is a deferral, never a pass | traceability + quality gate | `test-completed` |
| 17 | REVIEW | `/spec-review`; `CHANGES_NEEDED` returns to 15 | review APPROVED | `review-produced` |
| 18 | CLOSE | `coordination/run/closed.md`: specs, verdicts, open bugs, how to run, gate table; `/butler-remember --fasttrack` only when `run.butler` is on | the file exists | `session-closed` |

Rules that hold in every fast-track state:

- **Two human stops at most** in an interactive run (ASK, and the spec split); none under
  `--silent --assume`. The CR-4 confidence gate records the confidence and continues; only a CR-7
  decision with no catalogue default may stop, and it stops in ASK.
- **No traces, no token-guard, no `arch.md` slices, no ADR files.** Memory only when
  `run.butler` is on.
- **Specs move on their own clock**: a spec builds as soon as the specs it depends on are APPROVED,
  independent specs side by side; nothing waits for an unrelated spec.
- **Models**: the orchestrator session runs on the `run.orchestrator_tier` model (default `fast`) of the active harness;
  agents keep their own tier; the plan's `## Routing` (`kcc route`) sets the implementer's model and effort per item.
  Nothing is Claude-specific: `kernel/harnesses.json` says how each harness takes an agent, model and effort, and
  `kernel/models.json` which model each tier is on it.
- **Never relaxed**: CR-7 prohibited assumptions, CR-9 toolchain gate, CR-12 stack from the
  Decisions table, CR-13 no silent spec drop, CR-16 repo bootstrap, exit 3 is not a pass, and the
  full `quality-gate` scope.

Deploy (`/spec-deploy`) is never part of the run. It happens only on an
explicit human request after state 17. KCC never pushes to a remote on its
own.

**Terminal states:** `DONE` (after state 18), `STOPPED` (reason logged),
`ABORTED` (the human chose abort at any gate), `SUSPENDED` (usage limit:
restore point written, watcher armed). Emit `session-closed` for the first
three, and `limit-reached` for `SUSPENDED`.

## 3. Resume and `all`

**RESUME:** start at the first state, in table order, whose exit check fails.
If the idea brief is complete and nothing exists downstream, start at state 3.
A spec with an open Bug item resumes at state 11 for that item. Flags given
on the continuation apply to the rest of the run, so
`auto IDEA-007 --silent --assume --budget 50` finishes as S3.

**ALL:** find every `specs/IDEA-*-Specs/SPEC-*/SPEC-*.md` with a status other
than `Done`. Resume each one at its first failing state (from state 10 on),
by dependency, running independent specs concurrently. Count loops
per (agent, state, spec).

**Harness switch:** `.KCC/tools/kcc-handover.ps1|.sh -To <harness>` writes a
restore point and envelope. The new harness starts with `auto resume`.

## 4. Pause output

Show: the scenario and AutoPolicy, the state number and name, the files
written in this state, the gate name, the exact allowed answers, any loop
counters at 1 or more, the remaining budget against the cap, the usage-limit
%, and the assumptions made since the last pause. Full format: protocol ->
*Output Format At Each Pause*.
