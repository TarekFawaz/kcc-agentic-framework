---
# Functional fields (consumed by harness adapters)
name: spec-implement
description: >
 Implement an epic spec, wave, story, or enabler from its approved plan, following the story/enabler backlog under `Backlog/`, writing code under `src/IDEA-{ID}-{slug}/`, and turning the planner's atomic test cases into real tests via the `testing-unit`, `testing-integration`, and optionally `testing-performance` / `testing-security` dialects. Usage: /spec-implement SPEC-003 [--wave N|Story-001|Enabler-001]
argument-placeholder: <ARGS>
delegates-to:
  - implementer
maturity: L2
maintainer: tarek.fawaz1983@gmail.com
copyright: "KCC framework (c) 2026 Tarek Fawaz"
homepage: "https://tikasway.dev/kcc"
license: "Licensed under the terms in LICENSE"

# Obsidian metadata (used in the vault, ignored by harness adapters)
title: Spec Implement Skill
tags:
  - framework/skill
  - lifecycle/implement
created: 2026-05-24
updated: 2026-06-07
version: 3.8.0
status: active
---

# Spec Implement

Implement spec <ARGS>.

## Steps

1. Parse the SPEC-ID and optional scope from arguments. Scope may be the
   whole spec, `--wave N`, `Story-NNN`, or `Enabler-NNN` (matching the
   filename case). Locate
   `specs/IDEA-{ID}-{slug}-Specs/SPEC-{ID}-{slug}/` by scanning the per-idea
   spec groups under `specs/`.
2. Verify `plan.md` exists in the spec folder, has status `ready`, and
   contains a populated `## Atomic test cases` table that covers every AC on
   every story/enabler. If not, tell the user to run
   `/spec-plan SPEC-{ID}` first.
3. Verify the same-name folder note, `backlog.md`, `Backlog/Story-*.md`,
   `Backlog/Enabler-*.md`, `parallelization.md`, and the per-idea index
   `../IDEA-{ID}-{slug}-Specs.md` exist, and that the plan maps changes to
   its stories and enablers using `Story-NNN` / `Enabler-NNN` keys.
4. Verify a post-plan `/token-estimate SPEC-{ID}` approval is recorded in
   the current session trace or `budget.md` for the implement stage. Valid
   approvals are explicit human approval or AutoPolicy `auto-approved` with
   cumulative hosted-model spend still inside the approved budget cap. If
   missing, stop and ask the human to run `/token-estimate SPEC-{ID}`.
5. Create or switch to a branch named `spec/SPEC-{ID}` if branch operations
   are available in the host project.
5b. **Toolchain preflight precondition.** Before delegating to the implementer,
   ensure the build/test toolchain exists per
   [[../../kernel/protocols/toolchain-preflight|toolchain-preflight]]. Derive
   the required tools from the selected dialects / `TechnicalDecisionBrief.md`,
   detect them (helper `.KCC/tools/toolchain-preflight.ps1` / `.sh`), and if any
   are missing invoke the install gate (`install` / `human-install` / `defer`).
   This gate stops for the human even under `--silent --assume`; never install
   silently. Every `install` / `human-install` / `defer` decision MUST be
   recorded to the **four sinks** (per toolchain-preflight): the choice in
   `Traces/.../HumanDecisions.md`, the events
   (`toolchain-preflight-started`, `toolchain-preflight-result`,
   `toolchain-gate-decision`, and on an approved install
   `toolchain-install-complete` with command + result + re-detected version) on
   `coordination/backchannel.jsonl` via `.KCC/tools/backchannel-append.ps1`, the
   install command in `Traces/.../ToolsUsed.md`, and the action in
   `Traces/.../Actions.md` - through Butler's trace custody + the
   backchannel-append helper.
6. Delegate to the **implementer** agent with the spec ID, scope, selected
   backlog item files (under `Backlog/`), `parallelization.md`, and the
   relevant dialect files. The implementer must:
   - put all generated source under `src/IDEA-{ID}-{slug}/...` (workspace
     isolation per the spec-layout protocol);
   - create/maintain the per-idea `src/IDEA-{ID}-{slug}/README.md`;
   - turn every Test ID in scope from `plan.md`'s `## Atomic test cases`
     into real test code using the level's dialect:
     - `unit` -> `testing-unit` conventions;
     - `integration` -> `testing-integration` conventions;
     - `performance` -> `testing-performance` conventions (only if loaded);
     - `security` -> `testing-security` conventions (only if loaded);
   - encode the Test ID in each test's name/annotation so the verifier can
     trace it back to the plan;
   - commit per backlog item with messages including `SPEC-{ID}` and the
     matching `Story-NNN` / `Enabler-NNN` key.
7. When complete, display backlog items completed, Test IDs implemented,
   dialects used (including which `testing-*`), commits made, files
   changed (relative to `src/IDEA-{ID}-{slug}/`), and suggest running
   `/spec-test SPEC-{ID}`.
8. If the implementer reports confidence below the configured threshold
   (95% by default), invoke `/critical-human-gate` before continuing to
   verification.

## Parallel unit invocation

This skill can be invoked as **one parallel unit** - a single `Story-NNN` or
`Enabler-NNN` scope - so the orchestrator can run many in parallel per wave.
Per [[../../kernel/protocols/parallel-execution|parallel-execution]]:

- When invoked with a single-item scope (`/spec-implement SPEC-{ID} Story-001`
  or `Enabler-001`), the implementer writes **only the impacted files declared
  for that story/enabler**, all under `src/IDEA-{ID}-{slug}/...`. This file-
  disjoint guarantee is what makes the unit safe to run concurrently with its
  wave siblings.
- The orchestrator (auto skill / Claude realization) may issue **many such
  single-unit invocations concurrently for one wave** - one parallel subagent
  per independent item - then await the barrier (all units in the wave
  complete) before starting the next wave.
- Each unit is independently governed: its own butler-brief/remember (shared
  session, agent-named trace appends), token-guard accounting, confidence gate,
  and loop detection. The upfront `/token-estimate SPEC-{ID}` approval (step 4)
  covers the whole wave set; individual units do not re-gate the budget.
- The existing whole-spec and `--wave N` behavior is unchanged: a whole-spec
  invocation still walks every wave in order, and a `--wave N` invocation runs
  the items of that single wave.
