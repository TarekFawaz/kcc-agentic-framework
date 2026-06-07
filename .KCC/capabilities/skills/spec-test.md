---
# Functional fields (consumed by harness adapters)
name: spec-test
description: >
 Verify an epic spec implementation against epic criteria, story/enabler acceptance criteria (under `Backlog/`), and the planner's atomic test-case enumeration. Usage: /spec-test SPEC-003
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
updated: 2026-06-07
version: 3.8.0
status: active
---

# Spec Test

Verify implementation of spec <ARGS>.

## Steps

1. Locate `specs/IDEA-{ID}-{slug}-Specs/SPEC-{ID}-{slug}/` from the
   supplied SPEC-ID by scanning the per-idea spec groups under `specs/`.
2. Verify the same-name folder note, `backlog.md`, `Backlog/Story-*.md`,
   `Backlog/Enabler-*.md`, `parallelization.md`, `plan.md` (with a
   populated `## Atomic test cases` table), and the per-idea index
   `../IDEA-{ID}-{slug}-Specs.md` all exist.
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
   the architecture ADR(s) dictate the stack. The verifier reads the declared
   stack from `architecture/architecture.md` + the relevant ADR(s) (languages,
   frameworks, API style, persistence, architecture style) and compares it with
   what was actually implemented under `src/IDEA-{ID}-{slug}/` (package
   manifests, file types, framework imports, datastore integration). The
   implementation MUST match the declared stack, or **CHANGES_NEEDED** with a
   finding: "implementation stack (X) does not match architecture ADR (Y); fix
   the implementation or record an approved ADR documenting the change." A
   divergence is excused ONLY by an Accepted (or Proposed + human-approved) ADR
   documenting it - a stack change is a prohibited silent assumption. A
   **TOOLCHAIN_DEFERRED** state does NOT excuse a stack mismatch: deferred means
   the declared stack was written but not built, not that a different stack was
   built.
5. Delegate to the **verifier** agent with the spec ID, backlog item files,
   selected dialects (always `testing-unit` + `testing-integration`, plus
   `testing-performance` / `testing-security` if loaded by the plan), the
   `## Atomic test cases` table, and the implementation scope.
6. The verifier writes test results under `TestResults/IDEA-{ID}/SPEC-{ID}/`
   per [[.KCC/kernel/protocols/test-results-layout]]:
   - `test-run-summary.md` — every AC with PASS/FAIL and a link to any bug
     file;
   - one bug md PER issue, named `Story-{ID}-AC-{n}-Bug-{ID}.md` (or the
     `Enabler-` variant), each linked to its AC + story/enabler;
   - all screenshots under `screenshots/`, never the repo root.
   `review.md` remains the verdict file and links into this tree.
7. Display the verdict: APPROVED, CHANGES_NEEDED, or TOOLCHAIN_DEFERRED (the
   latter when tools were missing and install was deferred - NOT a pass) with a
   summary of:
   - failing epic ACs;
   - failing story/enabler ACs (per `Story-NNN` / `Enabler-NNN`);
   - failing Test IDs from the atomic test-case table;
   - links to the per-bug files and `test-run-summary.md` under
     `TestResults/IDEA-{ID}/SPEC-{ID}/`.
8. If APPROVED, suggest updating the spec status in `specs/specs.md` and
   in the per-idea index `IDEA-{ID}-{slug}-Specs.md` to Done.
