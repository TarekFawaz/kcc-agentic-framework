---
title: Parallel Lanes Protocol
aliases: [parallel-lanes, dependency-scheduling]
tags: [framework/protocol, orchestration, parallel]
created: 2026-10-15
updated: 2026-10-15
version: 2.0.0
status: active
copyright: "KCC framework (c) 2026 Tarek Fawaz"
---

# Parallel lanes: dependency-driven scheduling

Whether specs run one after another or at the same time is decided by one thing only: the
dependencies in `ROADMAP.md`. There is no flag for it. `kcc run` (the CLI) does the scheduling;
`kcc-run` ([[kcc-run]]) stays one sequential driver per folder.

## Flow

1. **Shared states, once.** REPO .. SPECS run in the workspace (`kcc-run --until 9`).
2. **Schedule by dependency.** The `## Execution Plan` table of `specs/IDEA-*-Specs/ROADMAP.md` gives
   each spec its `Depends on` list. A spec starts as soon as every spec it depends on is merged; a
   slow spec never holds back one that does not depend on it. Up to `--max-parallel` (default 4)
   specs run at once. A plain chain therefore runs one at a time, a fan-out runs side by side.
3. **One lane per running spec.** `.kcc-lanes/SPEC-NNN` is a private copy of the workspace (no `.git`,
   `node_modules`, run state, gates, checkpoints or dashboard) with its own git baseline and run state.
   `kcc-run --input SPEC-NNN --until 17` runs there (PLAN .. REVIEW). Lanes inherit the workspace's
   Claude Code trust. `.kcc-lanes/` is never committed.
4. **One view.** While lanes run, each lane's spec folder, test results and backchannel events are
   copied into the workspace every 20 seconds and the dashboard is rebuilt, so the workspace dashboard
   shows every spec. The scheduler adds `lane-started`, `lane-merged` and `lane-blocked` events.
5. **Merge back.** A finished lane's files are compared with the snapshot taken when it was cut. A file
   the lane changed is copied in if the workspace copy is unchanged; the lane's own spec folder and
   test results are always taken from the lane. A file both sides changed is a **conflict**: the
   workspace keeps its copy and the spec stops (exit 4). Clashes on shared indexes (`specs/specs.md`,
   `ideation/ideas.md`, `progress.md`, the memory index, `architecture.md`) are left as they are. A
   merged lane folder is deleted.
6. **CLOSE once** in the workspace after every spec is merged.

## Gates and resume

- A lane that pauses at a gate or fails is kept; specs that depend on it wait, unrelated specs carry on.
  Answer with `kcc run --lane SPEC-NNN --answer <choice>`, then `kcc run --resume` continues every lane.
- State: `coordination/lanes.json` (`running | failed | merged` per spec, with the reason).

## Not covered yet

Lanes that must edit the same file (a shared lockfile, `docker-compose.yml`) are reported as a conflict;
the planner should give such files to one spec, or make the later spec depend on the earlier one.
The in-harness `auto` skill still runs specs in sequence; only `kcc run` schedules lanes.
