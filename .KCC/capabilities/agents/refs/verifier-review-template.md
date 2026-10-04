---
title: Verifier review.md Template
tags:
  - framework/agent-ref
updated: 2026-09-21
---

# Verifier review.md Template

## review.md body

Write into `specs/IDEA-{ID}-{slug}-Specs/SPEC-{ID}-{slug}/review.md` (create it; there is no stub):

````markdown
# SPEC-{ID} Verification Report

## Epic Acceptance Criteria
| # | Criterion | Status | Evidence |
|---|--|--|--|
| AC-1 | {criterion text} | PASS/FAIL | {file, commit, Test ID, or manual check} |

## Backlog Item Verification

### Stories
| Item | Dialect | Complexity | AC | Status | Evidence |
|--|--|--|--|--|--|
| Story-001 | frontend-react | medium | AC-1 | PASS/FAIL | ... |
| Story-001 | frontend-react | medium | AC-2 | PASS/FAIL | ... |

### Enablers
| Item | Dialect | Complexity | AC | Status | Evidence |
|--|--|--|--|--|--|
| Enabler-001 | backend-nodejs | medium | AC-1 | PASS/FAIL | ... |

## Atomic Test Case Verification
| Test ID | Item | AC | Level | Status | Evidence |
|--|--|--|--|--|--|
| T-001 | Story-001 | AC-1 | unit | PASS/FAIL | `src/IDEA-{ID}-{slug}/tests/unit/...` |
| T-002 | Story-001 | AC-2 | integration | PASS/FAIL | ... |

## Traceability
{`check-traceability -Spec SPEC-{ID}` result: every AC -> Test ID -> test ->
result mapped, or the violation IDs.}

## Scope Check
{Changed files outside the plan/spec or outside `src/IDEA-{ID}-{slug}/`, or
"No scope creep detected."}

## Build Status
{Build/lint result, or "No build command defined yet."}

## Test Status
{Unit / integration / perf / security results, or "No test suite found."
If the toolchain was missing and the human deferred install, state
"Toolchain deferred" and list which build/lint/test commands could not run.}

## Quality Gate Check
{`quality-gate -Spec SPEC-{ID}` exit code and failing gate IDs. Exit 3 =
quality-deferred (not a pass). Include QG-PROD (pass or `n/a` + reason); see
`.KCC/kernel/protocols/architecture-governance.md` -> *Quality gate catalog*.}

## Architecture Gate Check
{Any violations of architecture/quality-gates.md or "All architecture gates passed."}

## Architecture Documentation Check
{`architecture/architecture.md` embeds diagrams inline (```mermaid```); spec
`arch.md` meets the content bar (>=1 mermaid block + narrative, not link-only
or sub-1 KB); flag any `.mmd` / `architecture/diagrams/` as deprecated layout.
Or "Architecture documentation OK."}

## API Conformance Check
{When the spec exposes an HTTP/REST API: confirm a valid OpenAPI 3.x document is
checked in, Swagger UI is served (default `/docs`), and implemented routes/verbs/
schemas conform to the document. List any divergence (route/verb + spec line) as
CHANGES_NEEDED. "n/a - no API" when the spec exposes no HTTP API, or
"API conformance OK." See [[.KCC/kernel/protocols/api-standards]].}

## Architecture Conformance Check (QG-ARCH-CONFORMANCE)
{Compare the declared stack from `architecture/architecture.md` + ADR(s)
(languages, frameworks, API style, persistence, style) against the stack under
`src/IDEA-{ID}-{slug}/` (manifests, file types, imports, datastore). Mismatch =
CHANGES_NEEDED citing ADR ID + declared (Y) vs implemented (X); excused ONLY by
an Accepted (or Proposed + human-approved) ADR. TOOLCHAIN_DEFERRED never
excuses it. Or "Architecture conformance OK." See
[[.KCC/kernel/protocols/architecture-governance]].}

## Architecture Docs Quality Check (QG-ARCH-DOCS)
{architecture-critic CONFORMANT verdict on record (or `/critical-human-gate`
override), else CHANGES_NEEDED. `architecture.md` is a real document, not a
MOC/stub; no `.mmd` / `architecture/diagrams/`; supporting docs substantive
(fitness-functions, nfrs, technical-budgets, guardrails, quality-gates, adrs/ +
adrs.md). Cite artifact + rule. Or "Architecture docs quality OK." See
[[.KCC/kernel/protocols/architecture-documentation]].}

## Dialect Review
{Findings from selected dialect review checklists, including testing-*.}

## Project Structure and Docs
{`src/IDEA-{ID}-{slug}/`, docs, and README status for generated or touched
project outputs.}

## Bugs
| Bug | Severity | Status | Story / AC |
|--|--|--|--|
| [[Backlog/Bug-001-{slug}]] | blocker/major/minor | open | Story-001 / AC-2 |

Every failing AC found here becomes `Backlog/Bug-*.md` (`Source: verifier`).

## Evidence
| Command (run by verifier) | Exit code | Notes |
|--|--|--|
| `check-traceability -Spec SPEC-{ID}` | 0 | |
| `quality-gate -Spec SPEC-{ID}` | 0 | |
| `{test command}` | 0 | |

## Test Results
- Summary: [[../../../TestResults/IDEA-{ID}/SPEC-{ID}/test-run-summary]]
- Bug files (one per issue): [[../../../TestResults/IDEA-{ID}/SPEC-{ID}/Story-{ID}-AC-{n}-Bug-{ID}]]
- Screenshots: `TestResults/IDEA-{ID}/SPEC-{ID}/screenshots/`

## Verdict
**APPROVED**, **CHANGES_NEEDED**, **QUALITY_DEFERRED**, or **TOOLCHAIN_DEFERRED**

APPROVED only if: traceability pass, `quality-gate` exit 0, no open
blocker/major bug, QG-PROD and QG-ARCH-DOCS pass. `quality-gate` exit 3 ->
**QUALITY_DEFERRED** (not a pass).

A **TOOLCHAIN_DEFERRED** verdict is used when the required build/test toolchain
was missing and the human deferred install: it is NOT a pass. List which
commands could not run and the missing tools, and point to the test-run-summary.

If CHANGES_NEEDED, list specific items with file and line references and
which Test IDs or ACs they map to, and link the matching bug file under
`TestResults/IDEA-{ID}/SPEC-{ID}/`.

## Related
- Epic spec: [[SPEC-{ID}-{slug}]]
- Test results layout: [[../../../.KCC/kernel/protocols/test-results-layout]]
- Plan: [[plan]]
- Roadmap: [[../ROADMAP]]
- Idea-specs index: [[../IDEA-{ID}-{slug}-Specs]]
- All specs: [[../../specs|All specs MOC]]
````

## review.md frontmatter


```yaml
---
spec-id: SPEC-{ID}
title: "SPEC-{ID} Review"
tags:
  - spec
  - review
  - status/{approved|changes-needed|quality-deferred|toolchain-deferred}
  - lifecycle/review
created: <original>
updated: <today>
status: {approved | changes-needed | quality-deferred | toolchain-deferred}
verdict: {APPROVED | CHANGES_NEEDED | QUALITY_DEFERRED | TOOLCHAIN_DEFERRED}
version: 1.0.0
---
```

