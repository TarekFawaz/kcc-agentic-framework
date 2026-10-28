---
title: KCC Release Notes 0.6.0 (2026-10-27)
aliases:
  - release-notes-0.6.0
  - releasenotes-2026-10-27
tags:
  - framework/documentation
  - release-notes
created: 2026-10-14
updated: 2026-10-27
version: 0.6.0
status: active
---

# KCC Release Notes - 0.6.0 (2026-10-27)

Release 0.6.0: cheaper model tiers, a developer fast path (`--fasttrack`), git worktree lanes that build independent
specs at the same time, red gates that are routed to their owner instead of looped, unattended runs that answer
every gate by policy and write `NeedsAttention.md`, a live dashboard, and `kcc hint`. Everything is additive: a run that
uses none of the new flags behaves as before. Upgrade steps: *Updating an existing workspace*, below.

## What changed

### Release-runner fixes: the bash tools on a Linux box, after the first 0.6.0 run

The first v0.6.0 release run (Ubuntu, bash 5.2) sat in its test step for over two hours and ended with nine failures.
The whole suite had passed on Windows, where the PowerShell tools do the real runs and the bash tools are only
dry-run; a Linux rehearsal in a Debian container (`oven/bun`, with `mawk` as the default `awk`, stricter than the
runner's `gawk`) reproduced every failure. All fixed:

- **`build-dashboard.sh` took 5 s of CPU per build** (11 s on the runner): the state table was cut at every record
  with an extglob pattern (`{*( )"id"`), which bash 5.2 matches very slowly. Literal patterns now; a build is 15 ms.
  Every driver state builds the dashboard, so this alone made a one-state run take half a minute and the dashboard
  tests time out.
- **`kcc-run.sh` sent an empty first argument to every state check on `mawk`** (Debian, Alpine, any box without
  `gawk`): the awk helper that joins a check's `args` list used `a[i] = (i in a) ? a[i] sep v : v`, and `mawk`
  evaluates `a[i]` first, so the list started with the separator. `repo-bootstrap` then refused `''` with a usage
  error and the run stopped at state 0. The helper is an `if`/`else` now, which every awk agrees on.
- **`check-wave-scope.sh --test-command auto` died on the first failing test** instead of reporting WAVE-002: the
  script runs with `set -e`, and the command substitution that captured the test output ended it. Mirrors the
  PowerShell behaviour now (exit code captured, output tail in the violation).
- **A project override `harness_invoke.<harness>.effort: ""` was ignored by the bash driver**, which read an empty
  value as "not set" and fell back to the kernel profile, so Codex still received `-c model_reasoning_effort`. A
  present-but-empty override now means "no such flag", as it does in PowerShell.
- **`repo-bootstrap --apply init-local` on a machine with no git identity in its config** (a CI runner) reported
  RB-IDENTITY even when `GIT_AUTHOR_*` / `GIT_COMMITTER_*` were set. Both scripts now ask git itself
  (`git var GIT_AUTHOR_IDENT`), so an environment identity is accepted.
- **`sync-adapters.sh` on macOS generated one agent named `.md`** (the release smoke on macos-latest): the parse cache
  separated fields with byte `\001`, which bash 3.2's `read` never splits on (bash uses that byte internally), so every
  name, class and description came back empty. The separator is `\002` now; Linux output is byte-identical.
- **The release workflow has a 45-minute job timeout** instead of GitHub's six hours, and the full-lifecycle routing
  test looks at the session's flags only (the routing sentence in the prompt legitimately names `kcc-route --agent`).

### Round 14 fixes: a closed run resumes, a waiver is never hidden, Docker limits say what they are

Test round 14 (fast track, depth 2, the first on the 0.6.0 tree) approved two specs that were built at the same time in
git worktree lanes, the first approvals in any round. It also found the defects below. Each is fixed; the ones in the
drivers and the scheduler are covered by a test.

- **A waiver is never hidden by an earlier deferral.** When TEST had accepted a deferred check (exit 3) and REVIEW then
  ended `WAIVER_NEEDED`, both drivers took the "deferral accepted earlier" shortcut: the lane exited 0 with no waiver
  gate, no `## [decided] ... | waiver` item and no `WAIVER NEEDED` line. The shortcut now excludes `REVIEW-004`, so the
  waiver gate opens, and the closing lines print the waiver (the later verdict of a spec replaces its deferral).
- **A closed run resumes for the lanes that are not merged.** CLOSE is one state and runs even when the scheduler
  parked specs, so `kcc run --resume` answered "the run is DONE; nothing to resume" right after the merge conflict it
  had asked you to fix. A resume now reopens a done run when `coordination/lanes.json` lists a lane that is failed,
  parked or still running, and the closing state runs again at the end.
- **A lane merged by hand is merged.** After a conflict you merge `spec/SPEC-NNN` yourself; the scheduler now sees the
  branch in `HEAD`, marks the lane merged, removes the worktree and records a `decided` item, instead of building the
  spec again in a new lane. The attention item says that the lane's review and test results stay on its branch until
  then, and that every conflict marker must be resolved before the commit.
- **Preflight names a stopped daemon.** `LIMIT docker-daemon unreachable` when `docker` is on PATH but the daemon is
  not running (Docker Desktop closed, the service stopped). Before, it was reported as a registry problem and the
  waivers cited the wrong cause.
- **SAST runs on Windows by default.** `quality.scanners.sast_runner` has a new default, `auto`: semgrep or opengrep
  on PATH, else the `semgrep/semgrep` image when Docker is present (with `KCC_CA_BUNDLE` mounted for a TLS-inspecting
  proxy), else deferred. Round 14 deferred QG-SAST on every spec until the runner was switched by hand.
- **Static rules understand multi-stage Dockerfiles.** QG-STATIC skips a `FROM <stage>` that names a stage declared
  earlier in the same file, so a pinned-tag rule no longer flags `FROM toolchain AS build`. The architect profile says
  how to write the rule (digests pass, hyphenated aliases).
- **Dashboard: one agent is visible.** The concurrency strip drew a single agent under 3 px when the peak was 8; the
  minimum is 5 px now and the strip is darker.
- **No project names in the framework.** The review template's example image is `app-web:local`; nothing under
  `.KCC/`, `cli/` or `docs/` names a test project.

### Steer a running session, and survive a usage limit in VS Code

- **`kcc hint "text"` and `/hint`** record guidance for the running session and every subagent: delivered on the next
  tool call through hooks, `--to all|main|subagents|<agent>`, `--expires <minutes>`, `--list`, `--clear H-NNN`. On
  Codex or OpenCode the agent reads `kcc hint --pending`. A hint never waives a gate, a safety rule or an earlier
  instruction. Protocol: `.KCC/kernel/protocols/hints.md`.
- **A usage limit in a session you started yourself** (VS Code, plain `claude`): the `StopFailure` hook runs
  `kcc-limit-hook`, which reads the reset time from the transcript, writes a restore point and arms `kcc-limit-watch`;
  the same session is resumed after the reset. `kcc doctor --fix-hooks` adds the hooks to an existing
  `.claude/settings.json`; `kcc limits` shows the last limit and its reset time.

### Round 12 fixes: a red gate is routed, not looped

Test round 12 (a fast-track run on a machine whose Docker builds cannot reach a registry) sent the implementer back three
times for a gate no code change could turn green, spent 51 minutes on a first verifier pass at `xhigh`, and showed `QG-DEPS`
red for a whole round because of one osv-scanner flag. Each of these is now routed to the owner who can act, and a run never
loops on it. Operator guide: [docs/unattended-runs.md](./docs/unattended-runs.md).

- **A gate no code change can turn green is a waiver, not a loop.** New review verdict `WAIVER_NEEDED`: every Bug is closed
  and what keeps the quality gate red is outside the code (a gate tool error, a stale built image, an environment limit such
  as a registry the build cannot reach or a test the OS cannot run, a check the architecture excluded). `review.md` gets a
  `## Waivers` table (`Item | Why it is not a code fix | What a human does`). The driver (`kcc run`, `kcc-run.ps1`,
  `kcc-run.sh`) opens a new `waiver` gate with the answers `waive` (close the spec as WAIVER_NEEDED, never a pass; the run
  goes on), `recheck` (the human fixed the environment: TEST runs again, scoped) and `abort`. A `CHANGES_NEEDED` review with
  no open Bug, no failing gate check an implementer owns and no traceability error is read the same way (violation
  `REVIEW-004 (human)`), so the implementer is no longer sent back three times for nothing. Under `--silent --assume` the
  policy answer is `waive`, recorded as a `decided` item in `coordination/NeedsAttention.md` with the gate items and the
  command that re-runs the verification; the last message and `closed.md` print `WAIVER NEEDED, NOT A PASS - SPEC-NNN: ...`.
  The dashboard shows the verdict as its own state (amber, like deferred).
- **A scoped TEST with nothing to verify is not dispatched.** When the previous review's `commit:` is HEAD, nothing changed
  under `src/` and no Bug is open or fixed-but-unverified, the verifier is not run; the event is `test-skipped`, and the
  mechanical checks (`check-traceability`, `quality-gate`) alone decide.
- **Environment probes in PREFLIGHT.** When `docker` is a required tool and present, `toolchain-preflight` runs
  `docker pull hello-world` and a one-line `docker build` whose `RUN` step opens a TLS connection to a registry, and prints
  `PROBE <what> reachable` or `LIMIT <what> unreachable: <why>` (`docker-registry`, `docker-build-network`). A LIMIT never
  fails the preflight; the TEST prompt carries the lines as `KNOWN ENVIRONMENT LIMITS`, and the verifier defers the checks
  they rule out at once. The case is Docker Desktop behind a TLS-intercepting proxy or antivirus: the daemon pulls, the build
  containers cannot. Fix: `KCC_CA_BUNDLE`, HTTPS inspection off for Docker, or verify on another host.
- **`quality-gate`.** (a) The scope of `quality-gate -Spec` comes from the plan's `## Gates coverage` table (the architect
  decides the gates, the planner maps them, PLAN-007): the checks the plan does not cover are reported in a new `QG-SCOPE` row
  as out of scope, not failed; `-Scope` / `--scope` still overrides; without a table the scope is `all`. (b) osv-scanner is
  called with `-L <lockfile>` per lockfile, or `-r <dir>` only when no lockfile exists (osv-scanner 2.x exits 127 when both
  are given; this kept QG-DEPS red for a whole round). (c) A scanner that exits without a result (osv-scanner, semgrep or
  opengrep, gitleaks, trivy) is a `deferred` row owned by `human`, never an implementer failure; for dependencies the
  per-stack audit (`npm audit`, `pip-audit`, `dotnet list package`) stands in. (d) Dev-only dependency advisories do not gate
  unless `quality.audit_dev_dependencies` is true (osv-scanner's `dependency_groups`); the `QG-DEPS` message counts
  production groups and names the dev-only ones. (e) A built image older than any workspace file is stale: `QG-IMAGE` defers
  it with a rebuild hint instead of scanning an image from an earlier run. (f) SAST: `quality.scanners.sast` may be `semgrep`
  (default) or `opengrep`; when the named one is missing the other stands in; `quality.sast_rules` (default `auto`, the
  registry) names the rules, and opengrep needs a local rules folder (`architecture/sast-rules/`) or the check is deferred.
- **Router rule 10.** A `review` task (verifier, critic) never runs above `high` effort unless the item's Complexity is
  `extra-high`; reason text `review: effort capped at high (xhigh only for extra-high complexity)`. Round 12's first TEST pass
  ran 51 minutes at `xhigh` for no better result.
- **Dependency advisory policy for the verifier.** A finding is a Bug only when it is at or above
  `quality.fail_on.dependencies`, in a production dependency, and in a package the spec imports or a direct dependency the
  spec added; everything else is an observation with a follow-up line and never a reason to amend an ADR.
- **Price note.** The measured "the fast and balanced tiers cost the same per token" figure was a fallback price the harness
  reports for model ids it does not know; dollar totals in run reports and on the dashboard are estimates until the harness
  knows the ids. The numbers are under *Model tiers* below.
- **Bash driver: the ASK state failed on macOS and Linux.** `kcc-run.sh`'s `internal:files-exist` check with `any: true`
  never looked at the last path of its list (an unterminated last line that `read` dropped), so every `--silent --assume`
  run failed the ASK state, which writes `Assumptions.md`, the second path, and parked the run after three attempts. Fixed;
  the PowerShell driver was never affected.
- **Lanes are git worktrees (round 13).** A lane used to be a copy of the workspace merged back by comparing file hashes;
  the first implementer that added an ignore rule ended an otherwise clean walking skeleton with `merge conflict: .gitignore`
  and parked every dependent spec. In a git workspace a lane is now a worktree on `spec/SPEC-NNN` cut from HEAD (the
  scheduler commits the workspace's uncommitted work first), and merging a lane is `git merge`: fast-forward or a merge
  commit, `.gitignore` and the shared indexes as unions, a real conflict aborted and reported with the files and the branch
  to merge by hand, nothing dropped. The lane folders and the run state are excluded through the repository's `info/exclude`,
  so no tracked file is touched for bookkeeping; restore-point tags in a lane are `kcc/SPEC-NNN/cp-NNN`. A workspace without
  git keeps the copy lane. Protocol: `.KCC/kernel/protocols/parallel-lanes.md`.
- **Container specs get `docker` in PREFLIGHT.** A spec, plan or technical brief that names docker, a compose file or a
  Containerfile adds `docker` to the derived tool list, so the registry probes run in the driver's PREFLIGHT and the TEST prompt
  carries the `KNOWN ENVIRONMENT LIMITS` line (round 13: only the verifier's own preflight saw them).
- **A deferral with no missing tool says what was deferred.** When `check-traceability` defers a Test ID (a service the test
  needs is unusable here) and no gate tool is missing, the closing lines no longer say `missing tool(s) (not recorded)`; they say a
  check could not run on this machine and give the command that re-runs the verification.
- **The scope label in the quality-gate JSON is `scope_source`.** Its values are `plan.md Gates coverage`, `option` (an
  explicit `-Scope` / `--scope`) or `default (all)`, so a report can say why a check was in or out of scope.
- **New names.** Settings: `quality.sast_rules` (default `auto`); `quality.scanners.sast` accepts `opengrep`. Events:
  `test-skipped`; `deferral-accepted` now also carries verdict `WAIVER_NEEDED` and gate `waiver`. Gate: `waiver` (answers
  `waive` / `recheck` / `abort`) in both state tables. Exit-check violation: `REVIEW-004 (human)`. Quality-gate row:
  `QG-SCOPE`. Preflight output lines: `PROBE ...` / `LIMIT ...`.

#### Less paper under fast track

Test round 13 (fast track, depth 2) wrote 1,200 lines in 24 generated files before the first line of code, and most of
them had no reader: standalone C4 files that duplicated the diagrams embedded in `architecture.md`, three flowcharts nobody
downstream opened, a per-spec `arch.md` left as an "awaiting architect" placeholder that the verifier then flagged, both
answer files in a silent run, a `QuickRoadmap.md` that `ROADMAP.md` superseded, and UX and infrastructure briefs only the
architect read. The same roadmap chained seven file-disjoint specs one after the other. Under `--fasttrack` the run now
writes only what a later agent or a check reads, and the split names build-time dependencies only.

- **No per-spec `arch.md` under fast track.** The WRITE state no longer asks for it. The spec note carries a
  `## Architecture references` section instead (5 lines at most: the Decision ids from `architecture.md -> ## Decisions`
  and the containers of the C2 diagram the spec touches, plus the Architecture Document wikilink); the planner and the
  verifier read that section and `architecture.md`, and the verifier never reports a missing or placeholder `arch.md` in
  this profile. `check-run-conformance -RunProfile fasttrack` requires the section (SPEC-001) and reports a stray
  `arch.md` as a warning (SPEC-003); the full lifecycle and depth 3 to 5 are unchanged.
- **No standalone C4 files and no `flowcharts/` folder under fast track.** The ARCH state asks for `architecture.md`
  with C1 and C2 embedded, the `## Decisions` and `## Toolchain` tables, `quality-gates.md` and `static-rules.tsv`, and
  nothing else. A business flow that matters is one embedded flowchart in a `## Flows` section, only when the idea has a
  non-trivial workflow. ARCH-FT-005 no longer requires a flowchart: a present `flowcharts/` folder or a standalone
  `c4-context.md` / `c4-container.md` is now the warning "duplicate of the embedded diagram", not an error.
- **One answers file.** The ASK state writes exactly one of `Assumptions.md` (under `--silent --assume`) or
  `HumanAnswers.md` (after the one question round), never both.
- **No `QuickRoadmap.md` under fast track.** The IDEA state writes the idea file, `Research.md` and
  `SpecWriterStarter.md`; the idea note's `## Phases` and the starter carry the order, and `ROADMAP.md` supersedes the
  quick roadmap. The full lifecycle keeps it (it is a required idea artifact there, read by the spec-writer and token-guard).
- **One brief under fast track.** The BRIEFS state runs two specialists, not four: the technical-interrogator writes
  `TechnicalDecisionBrief.md` with two extra sections, `## UX and UI` and `## Infrastructure and packaging` (at most 15
  lines each, from the catalogue defaults), and the security-analyst writes `SecurityDecisionBrief.md`. `ux-ui-designer`
  and `infrastructure-planner` are not spawned; the architect and the spec-writer read the two sections instead of the
  two briefs.
- **Dependency rule for the split.** `Depends on` names only a spec whose files, API or data this spec needs at build
  time; the walking skeleton (SPEC-001) is the only dependency a feature spec has by default; two feature specs that touch
  disjoint files do not depend on each other even when a user would use them in sequence; the roadmap's `Order` column
  groups the specs that can build at the same time. New conformance rule `SPEC-011` (warning, owner spec-writer, scope
  `specs`, fast track only): a roadmap whose Execution Plan is a single chain gets "the split is serial: every feature
  spec depends on the previous one; name only build-time dependencies so independent specs build in parallel".
- **The consumer rule.** Agent runtime contract rule 10: an agent writes a file only when a named consumer exists (a
  later agent that reads it, named in that agent's inputs, or a check that evaluates it); no placeholders, no skeletons
  "for later"; when unsure, the content goes in the file the consumer already reads. The file tables in `idea-layout.md`
  and `spec-layout.md` now carry a `Read by` column, so the rule is checkable by reading.
- **Fast-track butler.** The memory-only butler writes nothing when the run produced no durable fact: the framework sync
  installs `memory/index.json`, `memory.md` and `schema.md`, and the butler adds no empty entries, notes or index rows to
  them; the answer is `No new entries` with `remember-stored` carrying `entry_ids=none`.

### Earlier in this release

- **Dashboard: parallel agents and the lifecycle flowchart.** The Overview page now has a Now strip (every agent running, with a stale marker when nothing was written for 10 minutes), per-stage runs / peak parallel / sum of agent time / speed-up / cost columns, a swimlane timeline of agent runs with a concurrency strip and hatched human-gate waits, and an inline-SVG flowchart of the real state machine (shared states once, one chart per spec) with loop-back edges, gates and counts taken from dispatch logs and backchannel events. Builders add `goto`, `maxAttempts`, lane run state, dispatch agent/model/effort and `laneEvents` to the data block.

- **A deferred scanner no longer loops the run (round 11).** A missing scanner (semgrep) made the scoped TEST end `QUALITY_DEFERRED`; the REVIEW then failed on an unknown verdict, FIX ran with nothing to fix (86 s) and a second FULL xhigh TEST repeated the same checks. `kcc-run` now reads `QUALITY_DEFERRED` and `TOOLCHAIN_DEFERRED` (any spelling) as one class: with every bug fixed, verified or waived the REVIEW closes the spec as deferred-accepted (event `deferral-accepted`), the lane ends, and the last message says `DEFERRED, NOT A PASS` with the missing tool, the install command and the command that re-runs the gate (also appended to `closed.md`). A `QUALITY_DEFERRED` review makes the next TEST scoped, so it never uses the second full pass. A FIX with no open Bug and no implementer-owned violation is skipped (`fix-completed`, `skipped: true`).
- **One log per dispatch.** `state-16-SPEC-001-2.log`: a second TEST pass or a second FIX no longer overwrites the first; `check-<state>_<spec>-<n>-<tool>.out` carries the same number. `agent-run-started` also carries `tier`, `reasons`, `pass` and `dispatch`, so a page can say why a model and effort were chosen.
- **`--silent --assume` never stops for a human.** Every gate is answered by policy (ruling -> the recommended option, toolchain -> defer, scanner missing -> accept-deferred, confidence -> proceed, loop -> the spec is parked) and written to `coordination/NeedsAttention.md` and to `human-gate-decision` events (`answered_by: policy`). A parked spec is `needs-attention` in `lanes.json`; the other specs finish; the run exits 7 when items are open. A stopped lane is merged into the workspace at once, `src/` included; a lane's git ignores `.kcc-lane/`.
- **WRITE and PLAN have no fan-out limit.** All specs run at once; `--max-parallel` bounds only the build lanes; `--max-fanout N` sets a limit if needed. The split step also writes the per-idea index `IDEA-NNN-slug-Specs.md`, which the planners read.
- **Specs and plans are written in parallel.** Fast track used to ask one spec-writer to write every
  spec and then plan them all; unattended, with no orchestrator to spawn helpers, no plan was
  written and the state failed (round 10: 27 minutes for 5 specs). SPECS now writes only the split
  (ROADMAP.md and a stub note per spec); new per-spec states WRITE (10) and PLAN (11) follow, each marked
  `"fanout": true` in the state table. `kcc run` runs each of them for all specs at the same time
  (no limit: all specs at once; `--max-fanout N` sets one, `--max-parallel` bounds only the build lanes), one `claude -p --agent` process per spec in its own lane with its own
  log `state-<n>-<SPEC>-<k>.log`; a failure retries only that spec. The bare `kcc-run` driver does the same
  states spec by spec. Every dispatch records `agent-run-started` / `agent-run-ended` with spec and agent.

- **Model tiers.** `spec-writer`, `planner`, `architect`, `idea-interrogator`,
  `technical-interrogator`, `ux-ui-designer`, `infrastructure-planner`, and
  `security-analyst` (effort stays `high`) now run on the `balanced` tier
  (on Claude Code, for example, that is Sonnet). The `implementer` also runs on `balanced` (effort `medium`,
  `high` for `high` / `extra-high` or security-sensitive items and retries): it first ran on
  the `fast` tier (Haiku on Claude Code), but round 9 measured `claude-haiku-5-5` and `claude-sonnet-5-5`
  at the same price per token ($8 per million cache-write tokens, probed 2026-10-16). That figure turned
  out to be the fallback price Claude Code 2.1.283 reports for model ids it does not know (both print
  `unrecognized_model`). List prices differ widely: Haiku $0.10 in / $0.50 out, Sonnet $2 / $10, Opus $4 / $20,
  Fable $10 / $50 per million tokens. So the dollar totals in every run report and on the dashboard are
  estimates until the harness knows the ids (`kernel/models.json -> tier_cost_observed` keeps the note; re-probe
  on a build that knows them). The implementer stays on `balanced` because the fast tier wrote
  weaker code (round 9), not because of price. Keep the fast tier for an agent with
  `.KCC/model-overrides` (`implementer = fast-implementation medium`).
  Claude IDs are now the 5.5 family. On Codex the fast tier maps to
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

- **No harness is special.** `kcc-run` used to build its agent, model and effort flags only for Claude and read Claude model
  ids from settings, so fast track and per-item routing worked on Claude alone. How each harness takes an agent, a model and an
  effort is now data (`kernel/harnesses.json`: Claude, Codex, OpenCode, generic; override a key per project with
  `settings.json -> harness_invoke.<harness>.<key>`), and which model each tier is on each harness is the registry
  (`kernel/models.json`; `run.registry: "ollama"` runs Ollama models behind OpenCode). Settings carry tiers
  (`run.orchestrator_tier`, `run.escalation_tier`), not model ids; an explicit `run.orchestrator_model` still works, but a Claude
  id is never passed to another harness. A harness with no agent flag (Codex) runs worker states under one orchestrator session;
  one with no effort flag gets none; efforts a harness cannot take are folded (Codex tops out at `high`). Skills and agents are
  looked up in the harness's own folders. Both drivers build identical commands; the harness CLIs themselves are not
  installed in the test environment, so the commands are verified, not live runs on Codex or OpenCode.
- **The router runs in every cycle, on every harness.** `.KCC/tools/kcc-route.ps1|.sh` are line-for-line ports of the router
  (`cli/src/run/router.ts`; a parity test feeds all three 400 signal rows). `kcc-run` asks it for every dispatch in the full
  `auto` lifecycle and under `--fasttrack`: a direct worker gets the model and effort as flags, an orchestrator session is told
  which tier, model and effort to spawn the agent on, and `model-selected` records the choice. Spawn rule 7 and every skill's
  spawn footer tell the orchestrator and a developer to run it before each spawn.
- **New dialects:** Flutter (with package guidelines), Kotlin, Swift, Ruby and Lua. **New domain protocols**, selected from the
  idea's context by the interrogators and architect, never always-on: mobile app architecture (iOS, Android, hybrid), data
  engineering and data science, and privacy and cybersecurity by region (EU, GCC, US, global baseline).
- **Routing per backlog item, decided at plan time.** `kcc route [SPEC-ID]` turns each item's Complexity, files, domain and
  security words into a model and effort and writes them into `plan.md` as `## Routing`; `kcc run` does it after SPECS. `kcc-run`
  (both drivers) passes each wave and the FIX pass the strongest row of its items and emits `model-selected`, so the rules live
  in `router.ts` only. Implementation is capped at `routing.implement_max_tier` (default `balanced`); `extra-high` gives `xhigh`.
- **Gates that catch what round 9 found late.** Each wave also runs the workspace tests (`check-wave-scope -TestCommand auto`);
  a failed TEST or REVIEW goes to a FIX state (`implementer --bugs`); a DEFERRED test row exits 3 instead of failing; a Bug no
  test can express may say `n/a (reason)`; the plan keeps commands out of Test IDs and maps each cited standard's verifier check
  (`## Standards coverage`, PLAN-006).
- **Every architecture gate maps to something runnable.** The plan's `## Gates coverage` table (`| Gate | Covered by |`) needs a row
  per `QG-*` gate the plan cites and per numbered QG-PROD checklist item: Test IDs that exist in the atomic table,
  `check:<QG-ID>` for a check `quality-gate` implements, or `verifier:<step>`. `check-run-conformance` enforces it as
  PLAN-007 (error, owner planner; round 10: QG-STATIC had no test, the image scan was never run).
- **A live dashboard.** `kcc dashboard --serve`, and `kcc run` serves it for the run: the page is rebuilt from the files on every
  request and shows a stale or dead state honestly. Lane work (`src/`, specs, results) reaches the workspace while it runs.
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

## Breaking changes

None in the files a run reads or writes. Three behaviours differ:

- `quality.scanners.sast_runner` defaults to `auto` (was `local`): a machine without semgrep but with Docker now runs
  SAST through the image instead of deferring it. Set `local` to keep the old behaviour.
- `kcc run --resume` on a done run that still has unmerged lanes reopens the run; it used to print "nothing to resume".
- The review verdict set has `WAIVER_NEEDED` (see above). Anything that reads `review.md` must accept it.

## Known limits

- **Two parallel lanes can edit the same shared files.** In round 14, SPEC-003 and SPEC-004 both patched the inherited
  live-stack probe and its tests (each lane saw the workspace tests fail for a reason outside its plan), and the
  second merge conflicted. The wave-scope check guards a lane against its own plan, not against a sibling lane. Until a
  serialized workspace-health step exists, run the build lanes with `--max-parallel 1` when the inherited tests are
  red, or merge by hand as Needs attention says.
- **Waves inside one spec run one after another in the fast track.** The driver dispatches one implementer per wave,
  and the items of a wave are done by that implementer in turn. The time is saved across specs (lanes); parallel items
  inside a wave are planned for a later release.
- **The implementer stays on the balanced tier.** Routing runs per backlog item at plan time and per state at dispatch,
  but the implementer's default is `balanced` (round 9: the fast tier wrote weaker code) and only `docs` and `scaffold`
  items on a common domain step down, so a run on Claude shows Sonnet for every implementer. `.KCC/model-overrides`
  changes that per agent.
- **The spec file's `status:` is not changed by the driver** after a review. The verdict lives in `review.md`, which
  the dashboard reads.
- Prices for Haiku 5.5 and Sonnet 5.5 are not measured (a Claude Code 2.1.x fallback price), so every reported cost is
  an estimate (`models.json -> tier_cost_observed`).
- The macOS and Linux binaries are built and smoke-tested by the release workflow and have not been used on a real
  project.

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
