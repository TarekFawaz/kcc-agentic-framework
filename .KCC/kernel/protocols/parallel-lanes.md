---
title: Parallel Lanes Protocol
aliases: [parallel-lanes, dependency-scheduling]
tags: [framework/protocol, orchestration, parallel]
created: 2026-10-15
updated: 2026-10-19
version: 3.0.0
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
4. **One lane per running spec, a git worktree.** In a git workspace (the normal case: `repo-bootstrap` makes one)
   `.kcc-lanes/SPEC-NNN` is a **worktree** of the workspace repository on the branch `spec/SPEC-NNN` (the work branch the
   [[git-workflow]] protocol names), cut from the workspace HEAD. Before the cut the scheduler commits the workspace's
   uncommitted work (`SPEC-NNN: workspace state before the lane (kcc)`), so the lane sees every file the shared states wrote.
   The ignored runtime files a lane needs (the harness folders `.claude/`, `.codex/`, `.opencode/`, `.agents/`, the
   orchestrator files, the event log) are copied in; the lane folders and the run state are excluded through the
   repository's `info/exclude`, never through a tracked file. `kcc-run --input SPEC-NNN --from <state after the fan-out
   states> --until 17` runs there (up to REVIEW). Lanes inherit the workspace's Claude Code trust. Restore-point tags in a
   lane are namespaced `kcc/SPEC-NNN/cp-NNN`, because tags are repository-wide.
   A workspace without git keeps the older **copy lane**: a private copy with a hash snapshot, merged file by file.
5. **One view.** While lanes run, each lane's backchannel events and attention items are appended to the workspace's
   files every 20 seconds and the dashboard is rebuilt; the dashboard reads the lane folders for each spec's own state, so
   the workspace dashboard shows every spec. The lane's files reach the workspace when it merges. The scheduler adds
   `lane-started`, `lane-merged` (with `mode: worktree | copy`) and `lane-blocked` events.
6. **Merge back is a git merge.** When a lane finishes, its leftover edits are committed on its branch
   (`SPEC-NNN: lane checkpoint (kcc)`), the workspace's own leftovers on its branch, and `spec/SPEC-NNN` is merged into the
   workspace branch: a fast-forward when nothing else moved, a merge commit otherwise. `.gitignore`, `specs/specs.md`,
   `ideation/ideas.md`, `progress.md` and `memory/memory.md` merge as **unions** (both sides add lines; set through the
   repository's `info/attributes`), so two lanes adding rows never clash. A real conflict **aborts the merge**: the
   workspace is left as it was, the files are named, the lane's work stays on its branch, and the spec stops (exit 4; under
   `--silent --assume` an `open` item in `coordination/NeedsAttention.md` with `git merge spec/SPEC-NNN` as the next step).
   A merged worktree is removed (`git worktree remove`); the branch stays for the pull request.
   The bookkeeping commits run without hooks: they only record what the agents already produced; the agents' own commits
   go through the hooks as before.
7. **CLOSE once** in the workspace after every spec is merged.

## Gates and resume

- A lane that pauses at a gate or fails is kept; specs that depend on it wait, unrelated specs carry on.
  Answer with `kcc run --lane SPEC-NNN --answer <choice>`, then `kcc run --resume` continues every lane.
- State: `coordination/lanes.json` (`running | failed | merged | needs-attention` per spec, with the reason).
- **Nothing a lane did is lost.** A worktree lane that stops for any reason (paused at a gate, failed, parked as needs-attention)
  has its work committed on `spec/SPEC-NNN` right then; the branch and the lane folder stay until the spec merges. A copy lane is
  merged into the workspace right then, the way a finished lane is. A conflict is reported (under `--silent --assume` as an
  `open` item in `coordination/NeedsAttention.md`), never dropped. `.kcc-lanes/` is never committed.
- **Silent runs** (`--silent --assume`): a lane never pauses. It answers every gate by policy and, when a spec cannot continue, parks it
  (exit 7 -> `needs-attention`); the scheduler runs every other spec, marks the specs that depend on a parked one `needs-attention` too, closes the
  run, and exits 7. Each lane writes its own `coordination/NeedsAttention.md` (not merged as a file); the scheduler appends its new sections to the
  workspace's file while the lane runs and when it stops. `kcc run --resume` retries parked lanes. See [[kcc-run]] -> *Silent runs never stop for a human*.

## Not covered yet

Lanes that must edit the same lines of the same file (a shared lockfile, `docker-compose.yml`) are reported as a conflict;
the planner should give such files to one spec, or make the later spec depend on the earlier one. Different lines of the same
file merge as git merges them.
The in-harness `auto` skill still runs specs in sequence; only `kcc run` schedules lanes.
