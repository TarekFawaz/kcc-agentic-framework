---
# Functional fields (consumed by harness adapters)
name: token-estimate
description: >
 Estimate token cost (and $ cost) for a spec, upfront auto policy, idea roadmap, or free-form prompt before any expensive lifecycle step runs. Usage: /token-estimate <SPEC-ID or IDEA-ID or "prompt:" + text>
argument-placeholder: <ARGS>
delegates-to:
  - token-guard
maturity: L2
maintainer: tarek.fawaz1983@gmail.com
copyright: "KCC framework (c) 2026 Tarek Fawaz"
homepage: "https://tikasway.dev/kcc"
license: "Licensed under the terms in LICENSE"

# Obsidian metadata (used in the vault, ignored by harness adapters)
title: Token Estimate Skill
tags:
  - framework/skill
  - lifecycle/meta
created: 2026-05-24
updated: 2026-06-06
version: 1.7.0
status: active
---

# Token Estimate

Produce a token + dollar budget for: <ARGS>

This skill is a **gate**. It does not run the work. It forecasts the cost and
asks the human to approve before `/spec-plan` or `/spec-implement` proceeds,
unless an approved AutoPolicy budget cap covers the current estimate.

## Steps

1. Parse <ARGS>:
   - If it matches `SPEC-\d+`, treat as **estimate-spec** mode.
   - If it matches `IDEA-\d+`, or includes `--upfront-auto-policy`, treat as
     **estimate-auto-upfront** mode for one-approval auto budget.
   - If it starts with `prompt:`, treat as **estimate-prompt** mode (everything after the colon is the prompt text).
   - If it includes `--auto-policy`, treat the remaining policy fields as
     AutoPolicy context from the `auto` skill.
   - Otherwise, reject with usage hint.
2. Verify the required files exist before delegating:
   - estimate-spec: `specs/SPEC-{ID}-{slug}/SPEC-{ID}-{slug}.md`,
     `backlog.md`, `backlog/STORY-*.md`, `backlog/ENABLER-*.md`, and
     `parallelization.md` must exist. `plan.md` is optional before planning
     and required before implementation.
   - estimate-auto-upfront: `ideation/IDEA-{ID}-{slug}/idea-{ID}-{slug}.md`
     must exist. Prefer `QuickRoadmap.md`, `SpecWriterStarter.md`, and
     `TechnicalDecisionBrief.md` when present. Existing spec stubs may be read
     if already created.
   - estimate-prompt: no file check.
3. Confirm `.KCC/kernel/protocols/token-budget.md`,
   `.KCC/kernel/templates/ROI.md`, and
   `.KCC/kernel/protocols/dialects/dialect-registry.md` are present. The
   agent depends on these files.
4. Delegate to the **token-guard** agent, passing the parsed mode, arguments,
   and AutoPolicy context when present.
5. Capture the agent's printed budget table verbatim and surface it to the
   human. **Confirm token-guard emitted its `estimate-issued` backchannel
   event** via `.KCC/tools/backchannel-append.ps1 -Kind estimate-issued
   -From token-guard ...` (HARD step; Mode B prompt is the only exception). If
   the table has no `Backchannel: BC-NNNNN` row, the emit was skipped - re-run
   the helper. Each later decision (approve / auto-approve / cap-exceeded /
   abort) in steps 6-7 must likewise be emitted via the helper with the matching
   `-Kind`. The run's `coordination/backchannel.jsonl` must be non-empty after a
   gate.
6. If AutoPolicy context is present and already approved, inspect the
   token-guard outcome:
   - `auto-approved`: record the non-interrupting approval in `budget.md`,
     `Traces/Session-*/HumanDecisions.md` when available, and the backchannel
     as `estimate-auto-approved` (emitted via
     `.KCC/tools/backchannel-append.ps1 -Kind estimate-auto-approved
     -From token-guard ...`); then return control to the lifecycle.
   - `cap-exceeded`: stop and ask the human to approve a higher cap, revise
     scope, or abort.
   - `confidence-below-threshold`: invoke `/critical-human-gate`.
7. If no approved AutoPolicy covers the estimate, prompt the human for one of three responses:
   - **approve** - record approval in the session trace (`Traces/Session-*/HumanDecisions.md`) and return control so the next lifecycle skill (e.g. `/spec-plan`, `/spec-implement`) can run.
   - **revise** - invite the human to override inputs (criteria count, risk level, target model-class) and re-delegate to token-guard with the overrides.
   - **abort** - stop the lifecycle. Record the abort and reason in `Traces/Session-*/HumanDecisions.md`.
8. If estimate-spec or estimate-auto-upfront mode and an idea is traceable,
   confirm the upsert into `ideation/IDEA-{ID}-{slug}/ROI.md` succeeded and
   print the path.

## Output

A Markdown budget table (per `.KCC/capabilities/agents/token-guard.md` Output
Format). If no approved AutoPolicy covers the estimate, follow it with an
explicit `approve / revise / abort` prompt. No code is written, no specs are
mutated. The only file write side-effects are the `ROI.md` upsert (Mode A
only), budget decision appends, trace decision appends, and append-only
backchannel events.

## Gating

`/spec-plan SPEC-{ID}` and `/spec-implement SPEC-{ID}` MUST be preceded by
`/token-estimate SPEC-{ID}` with either:

- an explicit `approve` outcome recorded in the current session's
  `HumanDecisions.md` or the spec `budget.md`; or
- an `auto-approved` outcome recorded under an approved AutoPolicy whose
  cumulative hosted-model spend remains within the budget cap.

If neither approval is on record, the lifecycle skills should refuse to start
and instruct the human to run this skill first.
