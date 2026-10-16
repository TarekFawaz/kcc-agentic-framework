# Diagnosis: why six test rounds produced no product, and the fix plan

Date: 2026-10-16. Scope: the `auto` lifecycle, `--fasttrack`, the dashboard, and model routing.
Evidence: test rounds 0 to 6 under `E:\Tikasway.dev\TestRounds\_archive` and `TestRound6`,
their backchannels, Claude session transcripts, and the framework files in `.KCC/`.

## 1. The result so far

| Round | Driver | Flags | Ran for | Got to | Product | Why it stopped |
|--|--|--|--|--|--|--|
| 0 LabBook (in the repo) | kcc-run | fasttrack silent | ~1 h | IMPLEMENT w1 | none | Haiku 4.5 (no auto mode), IDEA passed empty, scope gate |
| 2 BudgetPal | kcc-run | fasttrack silent | 1 h 18 | TEST SPEC-001 | none | waves "passed" with no code, Bash denied |
| 3 BudgetPal | kcc lanes | fasttrack silent | ~1 h | SPECS | none | false usage-limit suspension, SPECS passed empty |
| 4 BudgetPal | kcc run (dependency lanes) | fasttrack silent | ~50 min | IMPLEMENT w2 | none | Bash denied, background subagent lost; dropped |
| 5 BudgetPal | chat `/auto` | fasttrack | 2 h 25 | IMPLEMENT SPEC-001 w1 | scaffold only | 15 specs, 40 min SPECS, 46 min PLAN |
| 6 BudgetPal | chat `/auto` | fasttrack | 1 h 20 | SPECS (not started) | none | 32 questions in 13 rounds, 14 ADRs, 3 critic loops |

Six rounds, roughly eight hours of wall-clock time, zero runnable applications. Every round
found and fixed real defects (24 framework fixes are in the working tree, 104 tests), but the
shape of the lifecycle itself was never changed: each round still had to walk the whole
document pipeline before the first line of code.

## 2. Pain points, with evidence

### P1. Fast track is a list of exceptions on top of the full lifecycle, and the orchestrator ignores them

- The `auto` skill is 267 lines; the full state table is the body and fast track is a bullet list
  near the end ("skip ROI, lean architecture, small specs ..."). The orchestrator is an LLM reading
  that text; under load it follows the table and drops the exceptions.
- Round 6 under `--fasttrack`: the architect wrote **14 ADRs**, `c4-component.md`, DFDs and a
  318-line Architecture Document, and the critic ran **3 review loops** (hand-backs at 22:25,
  22:29, 22:31) although the rule says "one lean pass". Nothing was wrong with the agents: the
  architecture-documentation protocol's "required artifacts" matrix has no fast-track column, so
  the critic enforces the standard matrix and the architect produces to pass it.
- Round 5: the orchestrator ran a sequential `arch.md` pass for 15 specs and planned every spec
  before building any, both allowed by the prose at the time.
- Conclusion: behaviour that must hold has to be structure (a state table, a profile column, a
  check) and not prose. Where it is structure (`kcc-run`, the exit checks) it held; where it is
  prose it drifted in every round.

### P2. Too many human gates, each one a full stop

- Round 6, interactive fast track: **13 question rounds, 32 questions**, at REPO, IDEA (twice),
  TECH, SPECIALISTS (four times), ARCH. The longest wait was 34 minutes (GATE-002, "framing
  confirm"). At 22:14 the human switched the run to `--silent --assume` out of frustration; the
  architect still asked one more question at 22:26.
- Causes: each interrogator asks its own "at most 5" questions (5 x 4 agents = 20), the CR-4
  confidence gate (95%) fires on any uncertainty, and nothing batches questions across agents.
- Under `--silent --assume` the gates vanish but the assumptions are spread over six briefs and
  fourteen ADRs, so a human cannot review them in one place afterwards.

### P3. Documents before code: 80 to 115 minutes before the first spec, every round

| Round | IDEA..SPECIALISTS | ARCH | SPECS | PLAN | First code |
|--|--|--|--|--|--|
| 5 | 11 min | 16 min | 40 min (15 specs) | 46 min (15 plans) | at 1 h 53 |
| 6 | 62 min (incl. 50 min human wait) | 17 min | interrupted | - | never |

- Specs are sliced horizontally (foundation, schema, auth, API pieces, UI pieces), so a runnable
  app exists only near the end. SPEC-001 in round 5 was "API foundation": a scaffold with 9 tests
  and no feature.
- Every spec costs a writer, a plan, an `arch.md` slice, a review and a merge. 15 specs for a
  small budgeting app is the single biggest multiplier.
- Several sub-steps that could run together ran one after another: idea reasoning then idea
  writing, tech questions then tech brief, architect then critic (three times), arch slices one by
  one, specs then plans.

### P4. The dashboard drifts from reality

- **Human wait counted as agent time.** Round 6 wrote proper gate events (`human-gate-triggered`
  GATE-002 at 21:16:35, decision at 21:50:57), but the page never paired them: chat runs name the
  gate's stage (`"state":"IDEA"`) while the pairing code expected a number (`Number("IDEA")` is
  NaN), so every gate was dropped, human time was always 00:00:00, and the 34-minute wait showed as
  agent time under IDEA. (First diagnosis blamed the payload being stored as a string; the page
  already parsed that at load. Fixed on 2026-10-16: stage by name or number, gate time subtracted
  from the agent interval, verified against the round-6 data: IDEA = 4:58 agent, 34:22 human.)
- Already fixed this week (kept here for the record): stage stuck on REPO for chat runs, PLAN with
  no timer, parallel specs summed instead of wall-clock, PREFLIGHT never completing, working
  agents invisible, lanes invisible, spec list jumping to the top.
- Still missing: an attempt count per stage for chat runs (the table shows 1 dispatch for a stage
  that looped three times), and a per-spec "waiting on" reason.

### P5. Model routing is static and blind to the task

- Each agent has one model class and one effort, fixed in its frontmatter: spec-writer always
  `claude-sonnet-5-5 / high`, implementer always `claude-haiku-5-5 / medium`, escalation to Sonnet
  only on a `high` complexity label or a retry.
- Nothing looks at the task: a well-known CRUD app and a niche protocol get the same tier; a
  one-line config change and a security module get the same effort.
- Model IDs are hand-pinned in `sync-adapters` and checked nowhere at run time: the `haiku` alias
  silently meant Haiku 4.5 (no auto mode) until round 0 failed, and `claude-haiku-5-5` is
  "unrecognized" by Claude Code 2.1.283 (it still works, with a warning).
- Harness overhead is paid on every state: in `kcc-run` each state is a fresh `claude -p`
  (orchestrator session boot, reading `orchestrator.md` and the skill, relaying hand-backs); in
  chat, the main session re-reads a 267-line skill and relays every subagent result through its
  own context. Round 2's PLAN state: 3 min 52 s wall-clock for about 2 min 40 s of planner work.

### P6. Exit checks that pass on nothing, and checks that block real work

- Passed on nothing (all fixed this week, but each cost a round): IDEA with no idea, SPECS with no
  specs, waves with no code (twice: no files, then an allowance row), a conformance scope with
  nothing in it.
- Blocked real work: the wave-scope gate read only the first path per Impacted Files line; wave N
  flagged wave N-1's uncommitted files; the pre-commit secrets scan spent 3 minutes on a lockfile;
  PREFLIGHT treated `typescript` as a missing command.
- The pattern: checks were written against the shape of the documents, not against the outcome
  ("did code appear and do the tests pass"). A check that cannot tell an empty state from a done
  state is not a gate.

### P7. The test loop for the framework itself is manual and expensive

Every defect above was found by a human watching a two-hour run. There is no scripted run of the
state machine against a stub harness that asserts order, parallelism, gates and "no empty pass".
The 104 unit tests cover tools in isolation; nothing exercises a whole lifecycle.

## 3. Root causes (what connects the pain points)

1. **Prose where structure is needed** (P1, P3, P5). The full lifecycle is a state table with
   scripted exit checks; fast track, parallelism, question batching and model choice are
   paragraphs. Paragraphs do not survive a 2-hour orchestrator context.
2. **One lifecycle, two intents.** "Prove the design" (full `auto`) and "show me a running app
   fast" (fast track) share one state table, one artifact matrix, one critic, one gate policy.
   Fast track can only subtract, and every subtraction is optional.
3. **Checks test documents, not outcomes** (P6). The lifecycle can be "done" with no product.
4. **Humans are asked per agent, not per run** (P2).
5. **No feedback loop on the framework** (P7): defects are found in production rounds.

## 4. Fix plan

Ordered by payoff. Phases 1 to 4 are what is needed before another round is worth running;
5 to 7 follow. Nothing here changes the full `auto` lifecycle except where marked "both".

### Phase 1. Fast track becomes its own lifecycle (structure, not exceptions)

- New state table `.KCC/kernel/auto-states-fasttrack.json` and a short skill section (target
  <= 80 lines) that the orchestrator follows instead of the full table when `--fasttrack` is
  set. The full `auto-states.json` and the full skill text stay untouched.
- Fast-track states (per the human's requested shape):

| # | State | Does | Parallel inside | Exit check (outcome-based) |
|--|--|--|--|--|
| 0 | REPO | git bootstrap | - | repo with a commit |
| 1 | IDEA | one idea-interrogator writes `idea`, `Research.md`, `QuickRoadmap.md`, `SpecWriterStarter.md` in one pass | - | the four files exist, `SpecWriterStarter.md` lists <= `max_specs_fasttrack` epics with the first a walking skeleton |
| 2 | BRIEFS | technical, infrastructure, UX, security briefs | 4 agents at once | 4 brief files; each `<= max_brief_lines` |
| 3 | ASK | one batched question round: the 4 briefs' open questions merged, <= 5 per domain, one `AskUserQuestion`; skipped under `--silent --assume` (assumptions recorded in one `Assumptions.md`) | - | `HumanAnswers.md` or `Assumptions.md` exists |
| 4 | ARCH-LITE | `architecture.md` with C1 context, C2 container, the main flowcharts, quality gates, and a **Decisions table** (library + version range, catalogue citation) instead of ADR files; no critic loop, one self-check against the fast-track artifact column | - | `architecture.md` has C1, C2, >= 1 flowchart, `## Toolchain`, `## Decisions`, `quality-gates.md` exists; **no** `adrs/`, `c4-component.md`, `dfds/`, `sequences/` |
| 5 | SPECS+PLANS | spec-writer proposes the split (<= budget, skeleton first), asks once (or applies the budget silently), then one agent per spec writes the spec **and its plan** | one agent per spec | <= budget specs, each with `status:`, `plan.md` with waves and atomic tests, SPEC-009/010 pass |
| 6 | BUILD (per spec, by dependency) | PREFLIGHT once for the run; IMPLEMENT waves with one implementer per item; TEST; REVIEW | specs by dependency, items by wave | `src/IDEA-*/` changed per the plan, tests run and pass, review APPROVED |
| 7 | CLOSE-LITE | summary with gate table and "how to run" | - | `coordination/run/closed.md` |

- No traces, no token-guard, no butler unless `fasttrack.memory: on`. No `arch.md` slices.
  No WINDOWS, BUDGET-*, ROI, CONFIRM, ARCH-GATE states at all (they are absent from the table,
  not skipped).
- `kcc-run` loads the fast-track table when `-Fasttrack` is set, so the unattended driver and the
  chat skill run the same machine.
- Files: `kernel/auto-states-fasttrack.json`, `capabilities/skills/auto.md` (fast-track section
  rewritten to point at the table), `tools/kcc-run.ps1|.sh` (table selection), `cli/src/run/*`.
- Done when: a stub-harness run of the fast-track table (Phase 7 test) reaches CLOSE-LITE with the
  expected order, 4 parallel briefs, N parallel spec+plan agents, and build lanes by dependency;
  round 7 produces a runnable skeleton after SPEC-001.

### Phase 2. One question round, assumptions in one place (fast track only)

- The ASK state is the only interactive stop before building; SPECS+PLANS has one more (approve
  the split). Interrogators under fast track **collect** questions (`## Open questions` in their
  brief) and never call `AskUserQuestion` themselves; the orchestrator merges and asks once, with
  `human-gate-triggered` / `human-gate-decision` events around it.
- CR-4 confidence gate: under fast track it records the confidence and continues; only CR-7
  (security, privacy, secrets, compliance with no catalogue default) may stop, and it stops once,
  in ASK.
- `--silent --assume`: ASK writes `Assumptions.md` (one table: decision, assumed value, source
  rule, risk) so the human reviews every assumption in one file at the end.
- Files: the four interrogator agents and skills (fast-track sections), `confidence-gate.md`,
  `auto.md`.
- Done when: round 7 interactive has exactly two human stops before code; round 7 silent has zero
  and one `Assumptions.md`.

### Phase 3. Artifact matrix and critic know the profile (both lifecycles, additive)

- `architecture-documentation.md` required-artifacts matrix gets a `fasttrack` column
  (architecture.md with C1+C2+flowcharts+decisions table+quality gates; everything else "-").
- The architecture-critic reads the run profile (`run.json` -> `fasttrack`, or `--run-profile`)
  and validates against that column; `check-run-conformance -Scope architecture` and
  `validate-kcc` do the same. Over-production under fast track is a DRIFT finding, not a pass.
- Depth and profile are separate axes: `depthlevel` sets prose length; the profile sets which
  artifacts exist.
- Done when: a fast-track run that writes `adrs/` or `c4-component.md` fails its ARCH exit check
  in the stub test.

### Phase 4. Dashboard tells the truth

1. Parse the payload as an object in the page (keep the raw string for display); human gates pair
   up; human wait is subtracted from the open agent interval, so the pipeline and the table show
   "waiting on human" with the real minutes.
2. Per-stage attempts for chat runs from `*-started` / `*-completed` pairs and critic loops.
3. Per spec: "waiting on" reason (dependency not approved, gate, failed check) from
   `lanes.json` / events.
4. A `kcc dashboard --check` that renders the page in headless Chrome and fails on a JavaScript
   error, run in the test suite, so a blank page (as happened once this week) cannot ship.
- Done when: round 7's human waits appear as human time to the minute, and the attempt counts
  match the transcripts.

### Phase 5. Model router (both lifecycles)

- **Registry** `.KCC/kernel/models.json`: per harness, per tier (`strong`, `balanced`, `fast`),
  the current model ID, context window, cost per million tokens, capabilities (auto mode, effort
  levels), and a `verified` date. `kcc models` lists it; `kcc models --refresh` asks each installed
  harness for its model list (`claude --model` probe, `codex` catalogue) and flags a pinned ID the
  harness does not know; `kcc doctor` warns when the registry is older than 30 days.
- **Routing rules** (`.KCC/kernel/protocols/model-routing.md`, applied when the orchestrator or
  `kcc-run` builds the handover packet; the chosen tier and effort go into the packet and the
  `model-escalated` / `model-selected` event):

| Signal | Source | Effect |
|--|--|--|
| Domain familiarity | `Research.md` -> `## Domain` (`common` / `specialised` / `novel`), set by the idea-interrogator | novel -> one tier up; common -> one tier down for writing tasks |
| Task kind | the state | research, architecture, security review -> reasoning tier; spec/plan/review -> balanced; implementation per plan, scaffolding, docs -> fast |
| Risk | CR-7 domains, `Complexity: high` in the plan | never below balanced; effort high |
| Size | items in the wave, files in the item | > 5 files or > 3 items -> effort up one level |
| Retry | second attempt of the same unit | tier up one level |
| Budget | `--budget` left | at < 20% left, never above balanced except CR-7 |

- Effort follows the tier unless a signal moves it (`low` for scaffolds and docs, `medium`
  default, `high` for security, architecture, novel domains).
- The per-agent `model-class` in frontmatter becomes the *default* tier for that agent, which the
  router may move by at most one step in either direction (so a human override stays meaningful).
- Done when: the router is a pure function with tests (signals -> tier, effort), the packet
  records the choice, and `kcc models --refresh` catches an unknown or outdated ID.

### Phase 6. Less harness time

- `kcc-run`: worker states (IMPLEMENT, TEST, REVIEW, SPECS+PLANS) run as the agent directly
  (`claude --agent`, the existing `fasttrack_direct` path) by default under fast track: no
  orchestrator session above a single worker. Light adjacent states (REPO, IDEA, BRIEFS) run in one
  session.
- Chat: the fast-track skill section is short (Phase 1), hand-backs carry a 10-line summary and a
  file list, not the agent's full report; the orchestrator does not re-read skills per state.
- Measure: `coordination/run/logs` already give per-dispatch times; the dashboard's "Agent" vs
  "Total" per stage becomes the overhead metric. Target: overhead < 20% of stage time.

### Phase 7. A test loop for the framework (before round 7)

- `cli/test/lifecycle.test.ts`: runs both state tables through `kcc-run` with a **stub harness**
  (a script that writes the artifacts each state should produce, or deliberately does not) and
  asserts: state order, which states are absent under fast track, that an empty state fails its
  exit check, that parallel groups overlap in time, that a gate opens where expected and nowhere
  else.
- `TestRounds/new-round.sh --measure`: one real run with the fixed BudgetPal idea, a time budget
  (fast track: skeleton <= 45 min, app <= 3 h), and a report (`diagnosis/ROUND-NN.md`) generated
  from the backchannel: stages, waits, questions, agents, cost, outcome. A round that misses the
  budget is a failing test, with the stage that blew it named.
- Round 7 runs only after Phases 1 to 4 and 7 are green.

## 5. Order and estimate

| Phase | Depends on | Effort |
|--|--|--|
| 7a stub-harness lifecycle test | - | 0.5 day (needed first, it is how 1 to 3 are verified) |
| 1 fast-track state table + skill section | 7a | 1 day |
| 3 artifact matrix profile column + critic | 1 | 0.5 day |
| 2 one question round, assumptions file | 1 | 0.5 day |
| 4 dashboard truth (payload, human time, attempts, JS check) | - | 0.5 day |
| 7b measured round 7 | 1, 2, 3, 4 | 1 run (3 h budget) |
| 5 model registry + router | - | 1.5 days |
| 6 harness overhead | 1, 5 | 1 day |

Phases 4, 5 and 7a can start now, in parallel with 1.

## 6. Definition of done for the whole plan

- `auto <idea> --fasttrack --silent --assume` on the BudgetPal idea, unattended, produces a
  runnable walking skeleton (API + UI + compose, one feature end to end) within 45 minutes and the
  full app with APPROVED reviews within 3 hours, with zero human gates and one `Assumptions.md`.
- The same idea without `--silent --assume` asks the human exactly twice before code.
- The dashboard's stage times, human waits, attempts and working agents match the transcripts.
- The full `auto` lifecycle passes the same stub-harness test with its current behaviour unchanged.
- Every model ID the framework pins is verified against the installed harness by `kcc doctor`.
