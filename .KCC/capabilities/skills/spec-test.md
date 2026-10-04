---
# Functional fields (consumed by harness adapters)
name: spec-test
description: >
 Verify a v6 spec implementation against spec ACs, backlog item ACs (under `Backlog/`), the planner's atomic test cases, `check-traceability`, and `quality-gate`. Usage: /spec-test SPEC-003
argument-placeholder: <ARGS>
delegates-to:
  - verifier
maturity: L2
maintainer: tarek.fawaz1983@gmail.com
copyright: "KCC framework (c) 2026 Tarek Fawaz"
homepage: "https://tikasway.dev/kcc"
license: "Licensed under the terms in LICENSE"

# Obsidian metadata (used in the vault, ignored by harness adapters)
title: Spec Test Skill
tags:
  - framework/skill
  - lifecycle/test
created: 2026-05-24
updated: 2026-09-21
version: 4.0.0
status: active
---

# Spec Test

Verify implementation of spec <ARGS>.

## Steps

1. Locate `specs/IDEA-{ID}-{slug}-Specs/SPEC-{ID}-{slug}/` from the
   supplied SPEC-ID by scanning the per-idea spec groups under `specs/`.
2. Verify `SPEC-{ID}-{slug}.md`, `Backlog/*.md`, and `plan.md` (with
   `## Waves` and `## Atomic test cases`) exist (legacy v5: `backlog.md`
   fallback).
3. Verify the architecture artifacts referenced by the spec exist for the
   selected architecture depth. Architecture diagrams are **named `.md` files
   with embedded inline ```mermaid``` blocks** (e.g.
   `architecture/c4-context.md`, `architecture/flowcharts/*.md`,
   `architecture/dfds/*.md`), and `architecture/architecture.md` embeds its
   diagrams inline. There are **NO `.mmd` files** and **NO
   `architecture/diagrams/` folder** - flag any such file/folder as a
   deprecated-layout violation. Confirm each spec `arch.md` embeds at least one
   ```mermaid``` block.
4. Confirm the implementation lives under `src/IDEA-{ID}-{slug}/`. Flag
   anything written outside that workspace as scope creep before
   delegating.
4b. **Toolchain re-check before verification.** Re-run the toolchain preflight
   per [[../../kernel/protocols/toolchain-preflight|toolchain-preflight]]
   (helper `.KCC/tools/toolchain-preflight.ps1` / `.sh`) for the tools derived
   from the selected dialects / `TechnicalDecisionBrief.md`. If any tool is
   missing, invoke the install gate (`install` / `human-install` / `defer`) -
   never install silently. If the human defers, the verifier writes a
   `toolchain-deferred` verdict (NOT pass), not a silent "blocked" stub. Record
   every `install` / `human-install` / `defer` decision to the **four sinks**
   (per toolchain-preflight): the choice in `Traces/.../HumanDecisions.md`; the
   events (`toolchain-preflight-started`, `toolchain-preflight-result`,
   `toolchain-gate-decision`, and on an approved install
   `toolchain-install-complete` with command + result + re-detected version) on
   `coordination/backchannel.jsonl` via `.KCC/tools/backchannel-append.ps1`; the
   install command in `Traces/.../ToolsUsed.md`; and the action in
   `Traces/.../Actions.md` - through Butler's trace custody + the
   backchannel-append helper.
4c. **API conformance check (default gate when an API exists).** When the spec
   exposes an HTTP/REST API, the verifier checks the
   [[../../kernel/protocols/api-standards|api-standards]] defaults: a checked-in
   valid OpenAPI 3.x document, a served Swagger UI (default `/docs`), and
   implemented routes/verbs/schemas conforming to the document. Any mismatch is
   **CHANGES_NEEDED**. The default is waived only when an ADR records a non-HTTP
   interface.
4d. **Architecture-conformance check (`QG-ARCH-CONFORMANCE` - default gate on
   every spec).** Per
   [[../../kernel/protocols/architecture-governance|architecture-governance]],
   the ADR-declared stack (`architecture/architecture.md` + ADRs) must match
   what is implemented under `src/IDEA-{ID}-{slug}/` (manifests, file types,
   imports, datastore), else **CHANGES_NEEDED**. Excused ONLY by an Accepted
   (or Proposed + human-approved) ADR. **TOOLCHAIN_DEFERRED** never excuses a
   stack mismatch.
4e. **Verifier-run gates.** The verifier itself runs
   `check-traceability -Spec SPEC-{ID}` and `quality-gate -Spec SPEC-{ID}`
   and records each command + exit code in `review.md -> ## Evidence`.
   `quality-gate` exit 3 -> **QUALITY_DEFERRED** (never a pass). QG-PROD and
   QG-ARCH-DOCS per `.KCC/kernel/protocols/architecture-governance.md` ->
   *Quality gate catalog*.
5. Delegate to the **verifier** agent with the spec ID, backlog item files,
   selected dialects (always `testing-unit` + `testing-integration`, plus
   `testing-performance` / `testing-security` if loaded by the plan), the
   `## Atomic test cases` table, and the implementation scope.
6. The verifier writes test results under `TestResults/IDEA-{ID}/SPEC-{ID}/`
   per [[.KCC/kernel/protocols/test-results-layout]]:
   - `test-run-summary.md` — every AC with PASS/FAIL and a link to any bug
     file;
   - one evidence md PER issue, `Story-{ID}-AC-{n}-Bug-{ID}.md` (or
     `Enabler-`), plus a `Backlog/Bug-{NNN}-{slug}.md` item (`Source:
     verifier`) for each failing AC;
   - all screenshots under `screenshots/`, never the repo root.
   `review.md` (created by the verifier) is the verdict file; self-check
   `check-run-conformance -Scope review`.
7. Display the verdict: APPROVED (only if traceability pass, quality-gate
   exit 0, no open blocker/major bug, QG-PROD + QG-ARCH-DOCS pass),
   CHANGES_NEEDED, QUALITY_DEFERRED, or TOOLCHAIN_DEFERRED (deferred = NOT a
   pass) with a summary of:
   - failing spec ACs and open Bug items;
   - failing story/enabler ACs (per `Story-NNN` / `Enabler-NNN`);
   - failing Test IDs from the atomic test-case table;
   - links to the per-bug files and `test-run-summary.md` under
     `TestResults/IDEA-{ID}/SPEC-{ID}/`.
8. If APPROVED, suggest updating the spec status in `specs/specs.md` and
   in the per-idea index `IDEA-{ID}-{slug}-Specs.md` to Done.
