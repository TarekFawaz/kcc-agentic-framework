---
title: KCC Release Notes (unreleased)
aliases:
  - release-notes-unreleased
tags:
  - framework/documentation
  - release-notes
created: 2026-10-14
updated: 2026-10-14
version: unreleased
status: draft
---

# KCC Release Notes - unreleased

Cheaper model tiers, a developer fast path, and an output-economy control.
Everything is additive: a run that uses none of the new flags behaves as before.

## What changed

- **Model tiers.** `spec-writer`, `planner`, `architect`, `idea-interrogator`,
  `technical-interrogator`, `ux-ui-designer`, `infrastructure-planner`, and
  `security-analyst` (effort stays `high`) now run on the `balanced` class
  (Sonnet on Claude). The `implementer` is the executor on `fast-implementation`
  (Haiku on Claude, effort `medium`). The orchestrator may spawn the implementer
  on `balanced` for `high` / `extra-high` items or after a FAIL, and emits a
  `model-escalated` event (`coordination/orchestrator.md`, spawn rule 7).
  Claude IDs are now the 5.5 family. On Codex the executor class maps to
  `gpt-5-mini` instead of `gpt-5-nano`.
- **`auto --fasttrack`.** Skips ROI, confirm, architecture review, all budget
  gates, and the windows gate. No traces or token-guard (a memory-only butler stays); progress is
  kept in `coordination/backchannel.jsonl`. Lite ideation, quick technical
  interrogation, architecture depth `lite`, small specs, the full quality gate (coverage, dependency audit, SAST, SBOM). The safety gates stay. Implies `--depthlevel 2`.
- **`--depthlevel 1-5`.** 5 is today's detail (default), 1 is essentials only.
  Passed to every agent in the handover packet. Table:
  `.KCC/kernel/protocols/depth-levels.md`. Output-economy rule added to the
  agent runtime contract and to every skill.
- **Length caps.** New ceilings in `settings.json -> spec_sizing`:
  `max_backlog_item_lines` (80, SZ-6), `max_plan_lines` (250, SZ-7),
  `max_brief_lines` (100, warning). `validate-kcc` warns about agent, skill, and
  ref files over a line budget.

- **DeepThinking mode.** A `deep` tier in `kernel/models.json` (Claude: `claude-fable-5-1`, `xhigh` or `max`) for four
  named analysis tasks only (`architecture-tradeoff`, `threat-model`, `failure-root-cause`, `cross-spec-consistency`).
  It is not an agent class and the router never picks it. Each spawn needs a human who has seen the cost range
  (measured: about $0.80 before any work, about $48 per million output tokens including thinking). Two ways in: the
  orchestrator proposes it during `auto` (also under `--fasttrack`) and the gate asks you; or you run `/deep <task or
  question>` yourself (any bounded question, `human-directed`). Silent runs fall back to `strong` unless
  `deep.pre_approved_usd` covers the estimate. The orchestrator is limited to `deep.max_per_run` (2); your own calls are not. `check-run-conformance -Scope deep` rejects a deep spawn with no prior approval (DEEP-001),
  too many (DEEP-002), or a task outside the list (DEEP-003). `kcc models --check` skips the deep probe (it costs money);
  `--deep` adds it. Skill: `/deep`. Protocol: `.KCC/kernel/protocols/deep-thinking.md`.

- **`kcc report`.** Measures the run in a folder: time per stage, human waits, agents, cost and output, with a pass/fail
  verdict against a time budget (default: walking skeleton 45 minutes, whole app 180) that names the slowest stages.
  It reuses the dashboard's own stage-timing code. `TestRounds/new-round.sh <slug> --measure` runs one unattended
  fast-track round on a fixed idea and writes `diagnosis/ROUND-NN-<slug>.md`.
- **Framework version 0.6.0** (CLI and payload). The upgrade path is covered by a test: settings and local edits kept,
  new keys added, `.KCC/model-overrides` honoured, the sync that follows validates.

- **Dashboard redesign.** `dashboard/index.html` now uses the Tikasway.dev look (same
  palette, orbital logo, light and dark themes) and combines roadmaps, per-spec progress,
  bugs, the decisions behind each spec, the backchannel, restore points, and traces. It has
  a head line of overall statistics, a lifecycle pipeline for the current run, a per-spec
  view, and a Live toggle that follows the run (kcc-run now refreshes it at every state).
  Both generators (`build-dashboard.ps1` and `.sh`) fill one shared template,
  `.KCC/kernel/templates/dashboard.html`; the old page is replaced on the next refresh.

- **Dashboard opens during a run, with permission.** `kcc-run` opens `dashboard/index.html`
  once per run when you allow it: `--open-dashboard`, or `.KCC/settings.json` ->
  `dashboard.auto_open` (`ask` by default, `yes`, `no`). On a terminal `ask` prompts once and
  can remember always or never; with no terminal (silent runs) nothing opens. The page follows
  the run (Live is on while it is running).
- **Agent history on the dashboard.** A new Agents tab lists every agent and subagent run from
  the Claude Code transcripts of the workspace: model actually used, effort, tokens (fresh in,
  out, cache read/write), duration, and per-session cost, with totals by model and by agent.

- **Fasttrack never trades away design, security, or gates.** It drops ceremony only: the full quality gate,
  traceability, the verifier's security review and design-conformance check, and the approved-review requirement
  all stay. One lean architecture review still runs; security-sensitive items always run on the balanced model;
  the planner scaffolds the project so the gates have something to check.

- **Cheaper fasttrack, still orchestrated.** Under `--fasttrack` each state's orchestrator session runs on Haiku at low effort
  (`run.orchestrator_model`, `run.orchestrator_effort`) and still spawns every agent as a subagent, so the spawn protocol,
  per-agent model and effort, and hints all apply. That wrapper cost roughly $0.5-1 per state on the session default and about
  $0.1 now. A `high` Complexity wave (security-sensitive items) or a retry spawns the implementer on `sonnet`. Running workers
  directly with `claude --agent` is now the default for worker states (`run.fasttrack_direct: false` brings the wrapper back); the dashboard labels those sessions "direct".
- **The butler now works in every run.** `kcc-run` used to dispatch no butler at all. Full runs tell each state's orchestrator to
  brief and remember with the butler (`run.butler: off` to disable). Fasttrack runs a memory-only butler: a brief in the IDEA
  session and a remember in CLOSE, with no `Traces/` folder. It shows in the dashboard's Agents tab.

- **Time per stage on the dashboard.** The lifecycle pipeline shows how long each stage consumed (`HH:MM:SS`) and whether
  it was waiting on an agent or a human, with a per-stage table (agent time, human time, total). Human time is the span from a
  gate opening to its answer; the running stage ticks live.
- **An abandoned chat run shows as `idle`, not `running`.** A chat-driven `auto` run has no driver to say it stopped.
  When no event and no agent transcript appeared for 30 minutes, both generators mark the run `idle` with the time of the
  last activity and `auto resume` as the way back; the page stops its timers, shows nobody as "waiting", and lists the
  run under attention. A chat run with no `run.json` also reads `--fasttrack`/`--parallel` from its `auto-policy-parsed`
  event, so the fast-track pipeline is shown instead of the full one.
- **Token-actuals hook fixed on Windows.** The `SessionEnd` hook used a `%CLAUDE_PROJECT_DIR%` path that the Git Bash
  hooks run in does not expand, so it failed after every session. The template now expands it correctly and picks PowerShell
  (or bash elsewhere); `kcc doctor` warns about the old form and `kcc doctor --fix-hooks` repairs it in place.

## Fixes in `kcc-run` (found by a real end-to-end run)

- **States skipped without running.** When `architecture/` or `specs/` did not exist yet,
  the exit checks passed with nothing to check, so the ARCH and SPECS states were marked
  done and the architect and spec-writer never ran. A state can now name an artifact it must
  produce (`precheck_requires`) before an already-passing check may skip it. CLOSE uses the
  same guard.
- **One-spec runs broke the PowerShell driver.** Indexing the single spec returned its first
  character (`I`), so PLAN and IMPLEMENT looked for `plan.md` for "I". Fixed.
- **`CHANGES_NEEDED` reviews finished the run.** The REVIEW state only checked that the
  report was well-formed. A new `internal:review-verdict` check fails the state unless the
  review says `APPROVED` (a `TOOLCHAIN_DEFERRED` review is a deferred exit 3), so the run
  goes back to implement as `auto.md` describes and stops at the loop gate after 3 failures.
  Check chains can now nest `then` twice (bash and PowerShell).
- **Models are pinned, not aliased.** The `haiku` alias still resolved to Haiku 4.5 (no auto mode)
  and `sonnet` to `claude-sonnet-5`, so agents and the fasttrack orchestrator did not run on the
  5.5 tier the docs promised. Claude agents now carry `claude-opus-5-5` / `claude-sonnet-5-5` /
  `claude-haiku-5-5`; `run.orchestrator_model` defaults to `claude-haiku-5-5` and the new
  `run.escalation_model` (the implementer on a high-complexity wave or a retry) to
  `claude-sonnet-5-5`. A `settings.json` that still says `haiku`/`sonnet`/`opus` is mapped to the
  pinned IDs by `kcc-run`, so older workspaces need no edit. Codex now maps to `gpt-6-astra`
  (strong), `gpt-6.1-sol` (balanced) and `gpt-6-luna` (fast), because the GPT-5.x IDs are retired
  from Codex with ChatGPT sign-in; OpenCode keeps the pinned Anthropic IDs.

- **Wave scope across uncommitted waves.** Restore points are a tag on HEAD and nothing commits between
  waves, so wave 2 reported wave 1's files as out of scope and every multi-wave spec stalled at wave 2.
  `check-wave-scope` now also accepts files declared by earlier waves of the same spec, and a new `WAVE-004`
  fails a wave that declares `src/` files and changed none of them (before, a wave that wrote nothing passed).

- **Specs run by dependency, in parallel where they can.** Before, `kcc-run` took specs strictly in
  sequence. Now `kcc run` runs the shared states once, then starts each spec as soon as the specs it
  depends on (`ROADMAP.md` -> `Depends on`) are merged: independent specs run at the same time in
  private lanes (`.kcc-lanes/SPEC-NNN`, never committed, removed after merge), dependent ones wait,
  and nothing has to be switched on. Lane progress shows on the one workspace dashboard while it
  runs; a file both a lane and the workspace changed is a conflict, never overwritten. A stopped lane
  is answered with `kcc run --lane SPEC-NNN --answer <choice>`. New `kcc-run --until <id>` stops a
  run after a state. See `protocols/parallel-lanes.md`.
- **Wave-scope fixes found by test rounds.** An allowance row (`any`) no longer lets a wave that wrote nothing pass
  (`WAVE-004` now counts only an item's own Impacted Files), the plan template and planner now document the
  `## Wave file allowances` table the gate reads, and `check-run-conformance` rejects Impacted Files outside
  `src/IDEA-{ID}-{slug}/` (`SPEC-008`).

- **Planning quality (test round 02).** An unattended run stopped at implement with five open questions. Fixed:
  - `repo-bootstrap` no longer git-ignores `ideation/`, `specs/` and `src/` in a project (it hid the
    deliverables); it now ignores run state, `node_modules/`, build output and `.env` files instead.
    Its bootstrap commit no longer takes minutes on Windows: the pre-commit lock check looks only at
    `src/IDEA-*` paths.
  - New `protocols/standards-catalog.md` (security, API, data, quality and operations, accessibility,
    supply chain, each with a framework default) and a style catalogue in `architecture-styles.md`
    (modular monolith, hexagonal, microservices, CQRS, event sourcing, serverless, BFF, and more).
    Architect, security analyst and technical interrogator start from them; every technology ADR names
    its library and a version range.
  - Under `--silent --assume` and `--fasttrack`, catalogue-backed ADRs are `Accepted`, low-risk assumed
    ones `Accepted (assumed)`, and only CR-7 decisions without a catalogue default stay `Proposed`, so
    the plan no longer adds a blanket "STOP before implement".
  - Every third-party package is added by a named plan item, and the plan's `## Toolchain` table
    (copied from the Architecture Document) is checked by PREFLIGHT: `toolchain-preflight` accepts
    `node@>=20` style ranges and reports a wrong version as `WRONG`.
  - The implementer no longer stops under `--silent --assume` for questions the ADRs, plan or catalogue
    already answer.

- **False usage-limit suspensions.** An architect summary that said "rate-limit values are assumptions"
  matched the generic limit patterns, so `kcc-run` suspended a healthy run and the limit watcher
  resumed it later. A harness that exits 0 now counts as limited only when its own limit notice is on
  the last lines (kcc-run in both shells, and the CLI). `--until` is kept in `run.json`, so a resume by
  the watcher still stops where `kcc lanes` asked.

- **Headless runs use auto mode.** `continuity.permission_mode` now defaults to `auto` (was `acceptEdits`).
  Under `acceptEdits` a headless session is denied every Bash command a hand-written allowlist does not
  match, so implementers and verifiers could not build, test, or run the KCC checks and stopped (every
  test round hit this). Auto mode approves routine commands and still blocks risky ones; it needs a
  5.5-tier model, which the pinned model IDs provide. Existing workspaces keep their own value: set
  `"permission_mode": "auto"` in `.KCC/settings.json` to switch.

- **Fast track reaches a running app first (test round 5: 2.5 hours, 15 specs, no app).**
  - Spec budget: at most `spec_sizing.max_specs_fasttrack` specs (default 5). SPECS proposes the split
    and asks the human once; a larger split they approve is recorded as `Spec budget: N (human approved)`
    in ROADMAP.md. `check-run-conformance` rejects a fast-track roadmap over budget (SPEC-009) and a
    spec without a `status:` (SPEC-010).
  - SPEC-001 is a walking skeleton (one thin feature end to end, runnable); later specs add features.
  - Specs are planned just in time (when their dependencies start building) and build as soon as their
    dependencies are APPROVED, each spec on its own clock (background subagents in a chat session).
  - Fast track skips the spec-local `arch.md` slices; outside fast track they are written at the start
    of each spec's PLAN, in parallel, not in a sequential pass.
  - A minor or patch bump inside an ADR's declared range needs no ADR change.
  - The pre-commit secrets scan skips lockfiles (the full quality gate still scans them); a staged
    lockfile made each commit wait minutes.
  - The wave-scope gate reads every backticked path on an Impacted Files line, not only the first.
  - The butler runs as its own subagent; chat runs log each spec event when it happens and every
    question to the human as a gate, so the dashboard times are real.
- **Dashboard for chat-driven runs.** Stage and per-stage times come from the backchannel when there is
  no driver state; parallel specs count once (wall-clock); the pipeline shows the earliest stage a spec
  is in; a run-wide preflight counts for every planned spec. New cards: Working now (agents active in the
  last two minutes), Development lanes (git worktrees and kcc lanes). A hook (`kcc-dashboard-refresh`)
  rebuilds the page while agents work. Spec cards are slimmer with chips; the list keeps its position.

- **Fast track is its own lifecycle** (`kernel/auto-states-fasttrack.json`; diagnosis in
  `docs/plans/DIAGNOSIS-2026-10-16-fasttrack.md`). `--fasttrack` now runs REPO -> IDEA -> BRIEFS (four
  specialists at once) -> ASK (one question round, or `Assumptions.md` under `--silent --assume`) ->
  ARCH (C1, C2, flowcharts, a Decisions table instead of ADR files, quality gates; ADRs, component
  diagrams, DFDs and sequences are drift: ARCH-FT-001..009) -> SPECS (split approved once, then every
  spec planned at once) -> PREFLIGHT -> IMPLEMENT -> TEST -> REVIEW -> CLOSE. ROI, CONFIRM, ARCH-GATE,
  BUDGET-* and WINDOWS do not exist in it; the full `auto` lifecycle is unchanged. Exit checks are
  outcome-based (`internal:files-exist`, a plan per spec, `WAVE-004`). Both drivers select the table;
  the dashboard reads it for a fast-track run. Interrogators collect questions instead of asking;
  the confidence gate records and continues under fast track.
- **Lifecycle test with a stub harness** (`cli/test/lifecycle.test.ts`, `test/fixtures/stub-harness.sh`):
  both tables dry-run, the fast track run end to end through IMPLEMENT, an empty IDEA pausing at the
  loop gate and resuming, over-production in ARCH failing, an empty wave failing.
- **Dashboard truth.** Gates that name their stage (`"state":"IDEA"`) are paired, human wait is never
  agent time (round 6: IDEA 4:58 agent / 34:22 human), attempts per stage for chat runs, a spec's
  "waits SPEC-00N" chip, `kcc dashboard --check` (compiles the page, parses the data, renders it headless
  and fails on a blank view), and `test/dashreliability.test.ts` with round-5/6 shaped scenarios.
- **Model registry and router.** `kernel/models.json` (the model of each tier per harness),
  `protocols/model-routing.md` (tier and effort from task, domain, risk, size, attempt, budget),
  `kcc models [--check|--refresh]` (probes the pinned ids against the installed Claude Code and shows
  what each alias resolves to), `kcc doctor` warns when the registry is older than 30 days, and
  `kcc-run` routes direct agent runs (domain from `Research.md -> ## Domain`, complexity, retry).
- **Less harness time under fast track.** Single-agent states (IDEA, ARCH, SPECS, IMPLEMENT, TEST,
  REVIEW) run as the agent itself (`claude --agent`, `run.fasttrack_direct` now defaults to true);
  hand-backs are a 10-line summary plus a file list.

## Updating an existing workspace

1. Install the new `kcc`, then run `kcc upgrade` in the project folder
   (`kcc upgrade --dry-run` lists what would change).
2. `.KCC/` files you never edited are replaced. A file you edited is listed as a
   conflict and kept, so an edited agent keeps its own model tier.
3. `.KCC/settings.json` is yours and is never overwritten. The upgrade now adds
   the new keys it lacks (`defaults.depthlevel`, the three caps, `notices`) and
   changes no value you set. Tools also work without them (defaults built in).
4. Agents are regenerated (`.claude/agents`, `.codex/`, `.opencode/`,
   `coordination/orchestrator.*`), which is where the new tiers take effect.
5. To keep earlier tiers for an agent, create `.KCC/model-overrides` (never
   touched by upgrades) and run `kcc sync`:

   ```text
   # name = model-class [effort]
   implementer = strong-reasoning high
   spec-writer = strong-reasoning
   ```

## Notes

- `check-impl-lock` accepts one new run-wide approval, `fasttrack-approved`, valid
  until the next `auto-policy-parsed`.
- `check-run-conformance` has a `-RunProfile fasttrack` option (auto-detected from
  `coordination/run/run.json`); `quality-gate` reads the same file for its default
  scope. Every tool change exists in both the `.ps1` and the `.sh` version.
