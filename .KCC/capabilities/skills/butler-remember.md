---
# Functional fields (consumed by harness adapters)
name: butler-remember
description: >
 Triage a session report and persist any non-obvious, reusable knowledge into the memory store. Usage: /butler-remember <session-summary or path-to-trace>
argument-placeholder: <ARGS>
delegates-to:
  - butler
maturity: L2
maintainer: tarek.fawaz1983@gmail.com
copyright: "KCC framework (c) 2026 Tarek Fawaz"
homepage: "https://tikasway.dev/kcc"
license: "Licensed under the terms in LICENSE"

# Obsidian metadata (used in the vault, ignored by harness adapters)
title: Butler Remember Skill
tags:
  - framework/skill
  - lifecycle/meta
created: 2026-05-24
updated: 2026-06-07
version: 1.5.0
status: active
---

# Butler Remember

Ingest the session report and write any retained entries: <ARGS>

This skill is intended to run at the **end** of every spec/agent turn. It does
**two distinct jobs**: (a) **tracing** - butler appends this turn's telemetry
to the active session's seven files (always), and (b) **memory triage** -
butler keeps only the rare non-obvious + reusable entries. Most runs store
nothing in memory - that is the correct outcome for routine work - but tracing
still records what happened.

## Steps

1. If <ARGS> is empty, ask the caller for a summary or trace path and stop.
2. If <ARGS> contains the literal token `skip-butler`, emit a one-line
   acknowledgement and exit without delegating.
3. Resolve the report:
   - If <ARGS> is a path under `Traces/` or to a markdown file, pass the path.
   - Otherwise pass the raw text as the session report.
4. **Append turn telemetry to the active trace session (tracing job).**
   Delegate to the **butler** agent (remember mode) to resolve the active
   session from `coordination/orchestrator.json` (creating it if a brief never
   ran) and **append** this turn's timestamped, agent-named entries to the
   seven files: `Actions.md`, `Decisions.md`, `ToolsUsed.md`, `Handovers.md`,
   `HumanActions.md`, `HumanDecisions.md`, `TokenUsage.md`, then refresh the
   per-session MOC and the `Traces/traces.md` row. Butler only appends - it
   never rewrites prior entries. `TokenUsage.md` must use the actual-token
   source contract from [[../../kernel/protocols/trace-layout|trace-layout]];
   if usage is unavailable, record `source: unavailable` and the reason rather
   than estimating. See
   [[../../kernel/protocols/trace-layout|trace-layout]]. This runs regardless
   of whether anything is worth keeping in memory.
5. **Memory triage (separate job, HARD step).** The same remember-mode call
   triages the report for non-obvious, reusable knowledge. **For each retained
   item the butler MUST call
   `.KCC/tools/memory-append.ps1 -Type <decision|pattern|incident|preference|glossary> ...`**
   once - the helper writes the entry file, updates `memory/index.json`, and
   adds the MOC row deterministically. Use the routing table in the butler
   agent (architecture/tech-stack -> `decision`; recurring approach -> `pattern`;
   failure/missing-toolchain/real-bug -> `incident`; human working-style ->
   `preference`; domain term -> `glossary`). Most real lifecycle turns yield at
   least one entry; "no new entries" must be RARE and justified, not the
   default. Tracing is full telemetry; memory is curated reuse - do not conflate
   them.
6. **Confirm the `remember-stored` backchannel event was emitted.** The butler
   emits it via `.KCC/tools/backchannel-append.ps1 -Kind remember-stored
   -From butler ...` on EVERY remember turn - including the rare "0 entries"
   case (then with `entry_ids=none` and a reason). This is a HARD step: if no
   `BC-NNNNN` is reported, re-run the helper before returning. The run's
   `coordination/backchannel.jsonl` must be non-empty.
7. Return the confirmation block verbatim, including the list of entry IDs
   created or updated (if any) and the rationale for each.
8. If the butler returned "No new entries", surface that line as-is - do NOT
   reword it into something that sounds like more work happened. (The trace
   append in step 4 and the `remember-stored` emit in step 6 still occurred even
   when no memory entry was kept.)
