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
2. **Fan-out states, all specs at once.** States the table marks `"fanout": true` (fast track: WRITE, a spec-writer per
   spec, then PLAN, a planner per spec; the full table: PLAN) run for every spec whose exit check does not pass yet, **all at once, with
   no limit** (these are short, file-disjoint planning tasks; round 11 lost 7-9 minutes when the 5th spec waited for a free slot of a pool
   of 4; `--max-fanout N` sets a limit for someone who needs one, `--max-parallel` never applies here), each in its own lane and **ignoring `Depends on`**: a spec note or a plan needs only its
   own files, the architecture and the dialects. Each lane runs `kcc-run --input SPEC-NNN --until <state>`, its own `claude -p --agent ...`
   process with its own log and `agent-run-started` / `agent-run-ended` events. A failed spec retries alone (its lane keeps the
   attempts and the loop gate); the run goes on when every spec has passed the state. `kcc route` then runs on the finished plans.
   The bare `kcc-run` driver has no scheduler: it does WRITE and PLAN spec by spec, in table order.
3. **Schedule by dependency.** The `## Execution Plan` table of `specs/IDEA-*-Specs/ROADMAP.md` gives
   each spec its `Depends on` list. A spec starts as soon as every spec it depends on is merged; a
   slow spec never holds back one that does not depend on it. Up to `--max-parallel` (default 4)
   specs build at once (this bounds only the build lanes, IMPLEMENT .. REVIEW, never WRITE or PLAN). A plain chain therefore runs one at a time, a fan-out runs side by side.
4. **One lane per running spec.** `.kcc-lanes/SPEC-NNN` is a private copy of the workspace (no `.git`,
   `node_modules`, run state, gates, checkpoints or dashboard) with its own git baseline and run state.
   `kcc-run --input SPEC-NNN --from <state after the fan-out states> --until 17` runs there (up to REVIEW). Lanes inherit the workspace's
   Claude Code trust. `.kcc-lanes/` is never committed.
5. **One view.** While lanes run, each lane's spec folder, test results and backchannel events are
   copied into the workspace every 20 seconds and the dashboard is rebuilt, so the workspace dashboard
   shows every spec. The scheduler adds `lane-started`, `lane-merged` and `lane-blocked` events.
6. **Merge back.** A finished lane's files are compared with the snapshot taken when it was cut. A file
   the lane changed is copied in if the workspace copy is unchanged; the lane's own spec folder and
   test results are always taken from the lane. A file both sides changed is a **conflict**: the
   workspace keeps its copy and the spec stops (exit 4). Clashes on shared indexes (`specs/specs.md`,
   `ideation/ideas.md`, `progress.md`, the memory index, `architecture.md`) are left as they are. A
   merged lane folder is deleted.
7. **CLOSE once** in the workspace after every spec is merged.

## Gates and resume

- A lane that pauses at a gate or fails is kept; specs that depend on it wait, unrelated specs carry on.
  Answer with `kcc run --lane SPEC-NNN --answer <choice>`, then `kcc run --resume` continues every lane.
- State: `coordination/lanes.json` (`running | failed | merged | needs-attention` per spec, with the reason).
- **The workspace never lags a lane.** Whenever a lane stops for any reason (merged, paused at a gate, failed, aborted, parked as
  needs-attention), its owned files **and `src/`** (the lane is a scratch copy; the code belongs in the workspace) are merged into the workspace
  right then, with the same merge a finished lane gets. A file both sides changed is a conflict: the workspace keeps its copy and the
  conflict is reported (under `--silent --assume` as an `open` item in `coordination/NeedsAttention.md`), never dropped. `.kcc-lanes/` is never
  committed, and a lane's own git ignores its marker folder (`createLane` appends `.kcc-lane/` to the lane copy's `.gitignore` when it is missing).
- **Silent runs** (`--silent --assume`): a lane never pauses. It answers every gate by policy and, when a spec cannot continue, parks it
  (exit 7 -> `needs-attention`); the scheduler runs every other spec, marks the specs that depend on a parked one `needs-attention` too, closes the
  run, and exits 7. Each lane writes its own `coordination/NeedsAttention.md` (not merged as a file); the scheduler appends its new sections to the
  workspace's file while the lane runs and when it stops. `kcc run --resume` retries parked lanes. See [[kcc-run]] -> *Silent runs never stop for a human*.

## Not covered yet

Lanes that must edit the same file (a shared lockfile, `docker-compose.yml`) are reported as a conflict;
the planner should give such files to one spec, or make the later spec depend on the earlier one.
The in-harness `auto` skill still runs specs in sequence; only `kcc run` schedules lanes.
