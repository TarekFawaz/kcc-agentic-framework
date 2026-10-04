---
# Functional fields (consumed by harness adapters)
name: bug-report
description: >
 Let a human report a bug at any point: triage it to its spec, story, and acceptance criterion, record it as a Bug backlog item with evidence, then route it through a regression test, fix, test, and review, and resume the interrupted flow. Usage: /bug-report <SPEC-ID | description> [--severity blocker|major|minor]
argument-placeholder: <ARGS>
delegates-to:
  - planner
  - implementer
  - verifier
maturity: L1
maintainer: tarek.fawaz1983@gmail.com
copyright: "KCC framework (c) 2026 Tarek Fawaz"
homepage: "https://tikasway.dev/kcc"
license: "Licensed under the terms in LICENSE"

# Obsidian metadata (used in the vault, ignored by harness adapters)
title: Bug Report Skill
aliases:
  - bug-report-skill
  - report-bug
tags:
  - framework/skill
  - lifecycle/bugfix
  - hitl
created: 2026-09-21
updated: 2026-09-21
version: 1.0.0
status: active
---

# Bug Report

Report: <ARGS>

A human-reported bug becomes a normal backlog item and flows through the same
gates as any other work. It never becomes an ad-hoc edit. The bug item shape
and status lifecycle are in `.KCC/kernel/protocols/spec-layout.md` -> *Bug
item shape*.

## Steps

1. **Capture.** Take anything the human didn't give from the report, and ask
   only for what's missing, in one message: steps to reproduce, expected
   result, actual result, evidence (a screenshot or log path), severity
   (`blocker` stops current work; `major` must be fixed before the spec
   closes; `minor` is queued). Default severity: `major`.
2. **Triage.** Resolve the spec: take the given `SPEC-ID`, or grep the specs'
   Delivery Briefs and backlog item titles for the described behaviour. Then
   pick the Story/Enabler and AC it violates. If more than one candidate
   matches, show the top 3 and ask. If none fits, the report is either a new
   requirement or a gap: offer `new-story` (spec-writer adds an item) or
   `new-spec`, and stop this skill.
3. **Record.**
   - Write `TestResults/IDEA-{ID}/SPEC-{ID}/{Item}-AC-{n}-Bug-{NNN}.md` per
     `.KCC/kernel/protocols/test-results-layout.md`, with `source: human`.
   - Write `Backlog/Bug-{NNN}-{slug}.md` (status `open`) and add a row to the
     spec file's `## Backlog` table.
   - Emit `bug-reported` (spec, item, AC, severity) through `backchannel-append`.
4. **Route** (spawn per `coordination/orchestrator.md` -> *Spawn protocol*):
   1. `planner`: add a regression Test ID to `plan.md` -> `## Atomic test
      cases` that reproduces the bug, and put the bug item in a wave.
   2. `implementer`: write the regression test (it must fail), fix, and
      re-run the test (it must pass). Status becomes `fixing`, then `fixed`.
   3. `verifier`: run `check-traceability -Spec` and `quality-gate -Spec`,
      then update `review.md`. Status becomes `verified`, or the bug is
      reopened.
5. **Resume the flow.**
   - If an `auto` run is active (`coordination/checkpoints/latest.md` or the
     active trace session shows a live state), `blocker` pauses it at the next
     state boundary. Steps 4.1-4.3 then run as an inserted wave, and `auto`
     resumes at the state it was in. `major` and `minor` are queued into the
     spec's next wave without pausing.
   - If no run is active, print `auto SPEC-{ID}` as the command that picks up
     the open bug through the resume table.
6. **Close.** `check-run-conformance -Scope bugs -Spec SPEC-{ID}` must exit 0
   before the spec can return to `Done`. Only the human can mark a bug
   `wontfix`, and that decision goes in `HumanDecisions.md`.

## Output

Bug key, spec, item/AC, severity, the files written, the route taken
(queued, inserted wave, or new-story), and the exact resume command.
