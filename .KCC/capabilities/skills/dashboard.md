---
# Functional fields (consumed by harness adapters)
name: dashboard
description: >
 Regenerate and open the self-contained local delivery dashboard (dashboard/index.html),
 themed like Tikasway.dev (light and dark): roadmaps, per-spec progress, bugs, the decisions
 behind each spec, backchannel events, restore points, and traces. Offline, no server,
 no build step. Usage: /dashboard
argument-placeholder: <ARGS>
delegates-to: []
maturity: L1
maintainer: tarek.fawaz1983@gmail.com
copyright: "KCC framework (c) 2026 Tarek Fawaz"
homepage: "https://tikasway.dev/kcc"
license: "Licensed under the terms in LICENSE"

# Obsidian metadata (used in the vault, ignored by harness adapters)
title: Dashboard Skill
aliases:
  - dashboard-skill
tags:
  - framework/skill
  - progress-tracking
created: 2026-06-06
updated: 2026-09-21
version: 1.2.0
status: active
---

# Dashboard

Regenerate the human-facing local dashboard and open it in the browser.

This skill delegates to no agent. It runs the generator tool, which collects the run's
progress and telemetry and fills the shared page template
(`.KCC/kernel/templates/dashboard.html`) into one self-contained `dashboard/index.html`
(inline CSS and JS, no CDNs, no network calls, opens offline). The page uses the
Tikasway.dev look: same palette, the orbital logo, light and dark themes.

## Steps

1. Run the generator:

   ```powershell
   powershell -ExecutionPolicy Bypass -File .KCC\tools\build-dashboard.ps1 -Open
   ```

   ```bash
   bash .KCC/tools/build-dashboard.sh --open
   ```

   Omit `-Open` to regenerate without launching a browser. `-Template <file>` / `--template <file>` renders a workspace with a newer page template than its own `.KCC` has (an older workspace keeps its own template otherwise). Pass `-RepoRoot`
   / `--repo-root` to point at a different workspace root.

2. The tool combines these sources at generation time:
   - **Roadmaps:** `specs/IDEA-*-Specs/ROADMAP.md`, joined to each spec's live progress.
   - **Specs:** `SPEC-*.md` (brief, acceptance criteria, `## Backlog`), `Backlog/Story-*`,
     `Enabler-*`, `Bug-*.md`, `plan.md`, `review.md`, `TestResults/**/test-run-summary.md`,
     and the `architecture/adrs/ADR-*.md` each spec references.
   - **Backchannel:** `coordination/backchannel.jsonl` (every event, with its payload).
   - **Checkpoints:** `coordination/checkpoints/CP-*.md` (restore points).
   - **Stage timing:** `coordination/run/logs/state-*.log` (each harness dispatch: start in the header,
     end at the last write) for agent time, and the `human-gate-triggered` to `human-gate-decision`
     span in the backchannel for human time.
   - **Run state:** `coordination/run/run.json` and `kernel/auto-states.json`
     (the lifecycle pipeline, `--fasttrack` and depth level).
   - **Traces:** `Traces/Session-*/` (the seven files; `Decisions.md` and
     `HumanDecisions.md` are also parsed into decision cards).
   - **Agents:** the Claude Code session transcripts of this workspace
     (`~/.claude/projects/<workspace>/`, or `CLAUDE_CONFIG_DIR`): every headless session `kcc-run`
     starts and every subagent it spawns, with the resolved model, effort, tokens, duration, and
     per-session cost. Subagent effort comes from the agent profile (the transcript does not record it).
   - Ideas (`ideation/`) and the memory index.

3. The page has a head line (delivered %, specs, stories and enablers built, tests,
   open bugs, decisions, events) and six tabs:
   - **Overview:** the lifecycle pipeline with the current state and, for every stage, the time it
     consumed as `HH:MM:SS`, tagged **Agent** or **Human** (the current stage shows "waiting" and its
     clock ticks), plus a table of agent time, human time, and totals per stage, specs with progress,
     what needs attention (stopped run, open bugs), and the latest activity.
   - **Specs:** pick one spec to follow it: lifecycle stages (spec, plan, build, test,
     review), stories and enablers with built/done status, acceptance criteria, bugs,
     the decisions behind it (ADRs, trace decisions, recorded gate events), and its timeline.
   - **Roadmap:** the execution plan per idea with status and progress for each spec.
   - **Agents:** the history of every agent and subagent run (when, state and spec, model, effort,
     tokens in and out, cache, time, cost), totals by model and by agent, and the configured profiles.
   - **Activity:** the backchannel timeline (filter by spec, kind, text) and restore points.
   - **Traces:** each session's files, rendered. Fast-track runs write no traces.
   - **Bugs:** every bug across specs, blockers first.

4. **Opening it during a run:** `kcc-run` opens the dashboard once per run, but only with
   permission: `--open-dashboard` for this run, or `.KCC/settings.json` -> `dashboard.auto_open`
   (`yes`, `no`, or `ask`, the default). With `ask` on a terminal it asks once and can save
   always or never; with no terminal (silent or unattended runs) it opens nothing and prints a
   hint. `--no-open-dashboard` always wins. Inside a session, the `auto` skill asks the same way.

5. **Live:** the Live button reloads the page every 10 seconds (on by default while a run is
   running; every 30 seconds otherwise). `kcc-run` and
   `backchannel-append` rewrite the file after each state and event, so an open page
   follows the run. The theme (light, dark, system) and Live choices are remembered.

## Notes

- Robust to missing folders: an empty repo still produces a valid page.
- Progress is a weighted lifecycle score: spec 10, plan 15, build 40 (built stories and
  enablers, from `implement-completed` events or item status), tests 15, review 20. A spec
  counts as delivered when its review is `APPROVED` or its status is `Done`.
- Read-only with respect to framework state; it only writes `dashboard/index.html`.
- Fonts: the page asks for Fraunces, Inter and JetBrains Mono and falls back to Georgia
  and system fonts when they are not installed (nothing is downloaded).
- `.KCC/tools/backchannel-append.ps1|.sh` refresh the dashboard after each event unless
  `KCC_SKIP_DASHBOARD=1` or `-NoDashboard` / `--no-dashboard` is used.

## Related

- Generator tool: `.KCC/tools/build-dashboard.ps1`
- Bash generator: `.KCC/tools/build-dashboard.sh`
- Activity log: [[../../kernel/protocols/backchannel|backchannel]]
- Trace layout: [[../../kernel/protocols/trace-layout|trace-layout]]
- Inspector pipeline: [[inspect]]
