---
# Functional fields (consumed by harness adapters)
name: butler-brief
description: >
 Produce a focused context pack from the memory store for an upcoming spec or agent turn. Usage: /butler-brief <SPEC-ID or topic>

argument-placeholder: <ARGS>
delegates-to:
  - butler
maturity: L2
maintainer: tarek.fawaz1983@gmail.com
copyright: "KCC framework (c) 2026 Tarek Fawaz"
homepage: "https://tikasway.dev/kcc"
license: "Licensed under the terms in LICENSE"

# Obsidian metadata (used in the vault, ignored by harness adapters)
title: Butler Brief Skill
tags:
  - framework/skill
  - lifecycle/meta
created: 2026-05-24
updated: 2026-06-07
version: 1.5.0
status: active
---

# Butler Brief

Generate a context pack for: <ARGS>

This skill is intended to run at the **start** of every spec/agent turn so the
next agent inherits institutional memory instead of working from scratch. As
the first butler touch of a run, it also **guarantees the run's trace session
exists** (butler is the trace custodian) - so even pure HITL individual-skill
use gets a `Traces/Session-*/` folder.

## Steps

1. If <ARGS> is empty, ask the caller for a SPEC-ID or topic and stop.
2. If <ARGS> contains the literal token `skip-butler`, emit a one-line
   acknowledgement and exit without delegating.
3. **Ensure the active trace session exists.** Delegate to the **butler** agent
   (brief mode) to read the active-session pointer in
   `coordination/orchestrator.json` and, if missing or stale for this run, copy
   `Traces/_session-template/` to `Traces/Session-{slug}-{datetime}/`, record
   the pointer, and seed the per-session MOC + `Traces/traces.md` row. **Rename
   the copied `session-template.md` to `session-{slug}-{datetime}.md`; the new
   session folder must NOT contain any file literally named `session-template.md`
   or `session.md`.** This is idempotent: a live session for the current run is
   left untouched. When a new session is created, Butler emits
   `trace-session-created` to the backchannel. See
   [[../../kernel/protocols/trace-layout|trace-layout]].
4. Resolve the scope:
   - If <ARGS> matches `SPEC-\d+`, treat it as a spec scope and also pull
     associated tags from `specs/SPEC-{ID}-*.md` if the file exists.
   - Otherwise treat <ARGS> as a free-form topic and extract keywords.
5. Delegate to the **butler** agent in brief mode, passing the resolved scope,
   any extracted tags, and a target cap of ~1500 tokens. (The same brief-mode
   call also performs the trace-session custody from step 3.)
6. **Confirm the `brief-issued` backchannel event was emitted.** The butler
   agent (brief mode) emits it deterministically by calling
   `.KCC/tools/backchannel-append.ps1 -Kind brief-issued -From butler ...` -
   this is a HARD step, never a "consider emitting". If the agent's output does
   not report a `BC-NNNNN` for this brief, the emit was skipped: re-run the
   helper before returning. The run's `coordination/backchannel.jsonl` must be
   non-empty after a brief.
7. Return the context pack verbatim to the caller. Do not summarize or edit
   it - downstream agents consume it directly.
8. Append a single trailing line: `_Consume this pack and cite entries by ID
   in your output._`
