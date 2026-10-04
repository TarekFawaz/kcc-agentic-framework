---
# Functional fields (consumed by harness adapters)
name: dashboard
description: >
 Regenerate and open the self-contained local progress + activity dashboard
 (dashboard/index.html) from the current ideas, specs, backlog, backchannel,
 traces, test results, and memory index. Offline, no server, no build step.
 Usage: /dashboard
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

This skill delegates to no agent - it simply runs the generator tool, which
reads the current progress and telemetry surfaces and writes a single
self-contained `dashboard/index.html` (inline CSS + vanilla JS, no external
CDNs, opens offline in any browser).

## Steps

1. Run the generator:

   ```powershell
   powershell -ExecutionPolicy Bypass -File .KCC\tools\build-dashboard.ps1 -Open
   ```

   ```bash
   bash .KCC/tools/build-dashboard.sh --open
   ```

   Omit `-Open` to regenerate without launching a browser. Pass `-RepoRoot`
   / `--repo-root` to point at a different workspace root.

2. The tool reads, at generation time:
   - `ideation/ideas.md` + each `ideation/IDEA-*/idea-*.md` (ideas + status)
   - `specs/specs.md` + each `specs/IDEA-*-Specs/ROADMAP.md` + `SPEC-*/SPEC-*.md`
     (`## Backlog` table; legacy v5 `backlog.md`) + `Backlog/Story-*` /
     `Enabler-*` / `Bug-*.md` (spec, item, and bug status)
   - `coordination/backchannel.jsonl` (activity events)
   - `Traces/Session-*/` (per-session trace summaries)
   - `TestResults/IDEA-*/SPEC-*/test-run-summary.md` (PASS/FAIL verdicts)
   - `memory/index.json` (memory entry counts)

3. The page has two tabs:
   - **Progress** - idea -> spec -> story/enabler tree with status badges,
     counts, and test verdicts.
   - **Activity / Replay** - a chronological, readable timeline of
     backchannel events plus per-session trace summaries, filterable by spec
     and by event kind.

4. The page is re-openable later without re-running the tool (all parsed data
   is embedded inline). Re-run `/dashboard` to refresh after new work lands.

## Notes

- Robust to missing folders: an empty repo still produces a valid page that
  reads "no ideas yet" rather than failing.
- Read-only with respect to framework state; it only writes
  `dashboard/index.html`.
- `.KCC/tools/backchannel-append.ps1` and `.KCC/tools/backchannel-append.sh`
  refresh the dashboard automatically after each event unless
  `KCC_SKIP_DASHBOARD=1` or `-NoDashboard` / `--no-dashboard` is used.

## Related

- Generator tool: `.KCC/tools/build-dashboard.ps1`
- Bash generator: `.KCC/tools/build-dashboard.sh`
- Activity log: [[../../kernel/protocols/backchannel|backchannel]]
- Trace layout: [[../../kernel/protocols/trace-layout|trace-layout]]
- Inspector pipeline: [[inspect]]
