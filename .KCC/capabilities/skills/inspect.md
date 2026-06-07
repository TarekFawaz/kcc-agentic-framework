---
# Functional fields (consumed by harness adapters)
name: inspect
description: >
 Run the BASIC Inspector Pipeline (Detect + Propose) over real run signals -
 backchannel events, trace sessions, and test results - and write reviewable
 proposal stubs under .KCC/inspector/proposals/. Honest about insufficient
 signal; never fabricates patterns. Usage: /inspect
argument-placeholder: <ARGS>
delegates-to: []
maturity: L1
maintainer: tarek.fawaz1983@gmail.com
copyright: "KCC framework (c) 2026 Tarek Fawaz"
homepage: "https://tikasway.dev/kcc"
license: "Licensed under the terms in LICENSE"

# Obsidian metadata (used in the vault, ignored by harness adapters)
title: Inspect Skill
aliases:
  - inspect-skill
  - inspector-skill
tags:
  - framework/skill
  - inspector
created: 2026-06-06
updated: 2026-06-06
version: 1.0.0
status: active
---

# Inspect

Run the basic Inspector Pipeline over accumulated run signals and emit
human-reviewable change proposals.

This skill delegates to no agent - it runs the tool, which implements the
**Detect** and **Propose** stages at a basic level. **Observe** reads
existing traces + backchannel; **Review** and **Promote** remain human (you
read the generated proposal, decide Adopt / Investigate / Defer, and promote
manually).

## Steps

1. Run the tool:

   ```powershell
   powershell -ExecutionPolicy Bypass -File .KCC\tools\kcc-inspect.ps1
   ```

   Optional tuning: `-MinEvents N` (signal floor), `-MinOccurrences N` (how
   many repeats before a pattern is proposed), `-RepoRoot <path>`.

2. The tool reads:
   - `coordination/backchannel.jsonl`
   - `Traces/Session-*/`
   - `TestResults/` (including `*Bug-*.md` files)

3. It detects a few simple, REAL patterns:
   - Repeated `estimate-aborted` / budget cap exceedances on specs.
   - Recurring confidence-gate trips for the same agent.
   - Recurring bug categories (by severity) across `TestResults/*/Bug-*.md`.
   - Calibration divergence per agent (only when calibration data exists).

4. For each detected pattern it writes a proposal stub to
   `.KCC/inspector/proposals/{date}-{slug}.md` with: what was observed, which
   capability/kernel area it suggests changing, and a recommended action
   (Adopt / Investigate / Defer), plus a human Review checklist.

## Honesty contract

- If there is not enough signal (fewer than `-MinEvents` backchannel events
  and fewer than `-MinOccurrences` bug files), the tool prints
  `insufficient signal - N events; need more runs` and **writes nothing**.
- It never fabricates patterns; a proposal is written only when a real,
  counted repetition crosses the threshold.

## Related

- Inspector pipeline (protocol): [[../../kernel/inspector/README|Inspector Pipeline]]
- Detect stage: [[../../kernel/inspector/stages/detect|detect]]
- Propose stage: [[../../kernel/inspector/stages/propose|propose]]
- Tool: `.KCC/tools/kcc-inspect.ps1`
- Dashboard: [[dashboard]]
