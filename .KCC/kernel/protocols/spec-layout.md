---
# Functional fields
description: Layout for every spec. A spec is one lean file describing the smallest user-valuable delivery, linked to its backlog items and its arch.md, grouped under a per-idea Specs folder with a token-optimised ROADMAP.
inputs: An IDEA-ID + slug from the upstream idea, plus a SPEC-ID + slug chosen by the spec-writer agent.
outputs: A `specs/IDEA-{ID}-{slug}-Specs/` folder with an index, `ROADMAP.md`, and one `SPEC-{ID}-{slug}/` folder per spec (spec file, `arch.md`, `Backlog/` items; `plan.md` and `review.md` created by their owners).

# Obsidian metadata
title: "Spec Folder Layout Protocol"
aliases:
  - spec-layout
  - spec folder convention
  - epic backlog convention
  - spec folder note
  - idea-specs-index
tags:
  - framework/protocol
  - spec
  - backlog
  - documentation
created: 2026-05-24
updated: 2026-09-21
version: 6.0.0
status: active
copyright: "KCC framework (c) 2026 Tarek Fawaz"
homepage: "https://tikasway.dev/kcc"
license: "Licensed under the terms in LICENSE"
---

# Spec Folder Layout

A spec is the **smallest delivery a user can get value from**. It is one lean
file. The detail lives in its backlog items and its `arch.md`, and each file
is read only when a step needs it. Specs are grouped per idea, so the trace
chain `Idea -> Specs -> Story/Enabler/Bug` is visible in Obsidian.

```text
specs/
|-- specs.md                          <- top-level MOC across all ideas
`-- IDEA-{ID}-{slug}-Specs/           <- per-idea spec group
    |-- IDEA-{ID}-{slug}-Specs.md     <- index; the ONLY file linking back to the idea
    |-- ROADMAP.md                    <- spec order, waves, lanes, token plan, restore points
    `-- SPEC-{ID}-{slug}/
        |-- SPEC-{ID}-{slug}.md       <- THE spec: delivery brief + ACs + backlog table + arch link
        |-- arch.md                   <- spec-local design (embedded mermaid)
        |-- Backlog/
        |   |-- Story-{NNN}-{slug}.md
        |   |-- Enabler-{NNN}-{slug}.md
        |   `-- Bug-{NNN}-{slug}.md   <- added by /bug-report or the verifier
        |-- plan.md                   <- created by planner (not a stub)
        `-- review.md                 <- created by verifier (not a stub)
```

**Trace edges:** idea -> index -> spec -> backlog items. No level is skipped.

**No stub files.** Each file is created by its owner when it has real content.
`backlog.md`, `parallelization.md`, `budget.md`, and `handovers.md` are
retired (see *Legacy v5 specs*).

---

## Files and owners

| File | Owner | Content |
|--|--|--|
| `IDEA-{ID}-{slug}-Specs.md` | spec-writer | Spec index: key, delivery, status, links. |
| `ROADMAP.md` | spec-writer (shape), token-guard (estimates) | Execution plan across specs. See *ROADMAP.md shape*. |
| `SPEC-{ID}-{slug}.md` | spec-writer | See *Spec file shape*. |
| `arch.md` | architect (spec-writer seeds the section skeleton) | Embedded design slice. Content bar: >= 1 ```mermaid``` block plus prose ([[architecture-documentation]]). |
| `Backlog/Story-*`, `Enabler-*` | spec-writer | See *Backlog item shape*. |
| `Backlog/Bug-*` | `/bug-report` skill, verifier | See *Bug item shape*. |
| `plan.md` | planner | Ordered changes, `## Waves` (file-disjoint), `## Atomic test cases`. |
| `review.md` | verifier | PASS/FAIL per AC, `## Evidence` (commands run + exit codes), verdict. |

Token estimates and approvals go to `ROADMAP.md`, the trace session
(`TokenUsage.md`, `HumanDecisions.md`), and the backchannel. Handover
envelopes go to `coordination/handover/`.

---

## Sizing rules (enforced by `check-run-conformance -Scope specs`)

| Rule | Limit | If exceeded |
|--|--|--|
| SZ-1 | A spec covers **one** user-valuable delivery (one outcome, one primary persona) | Split into more specs |
| SZ-2 | At most **6** backlog items (stories + enablers) per spec at creation | Split |
| SZ-3 | Each item touches at most **5** impacted files | Split the item |
| SZ-4 | Each item needs at most **8** atomic tests (the planner checks this) | Split the item |
| SZ-5 | The spec file is at most **150** lines | Move detail into items or `arch.md` |

Splitting increases the spec count. It never drops scope (CR-13). Bugs added
later don't count toward SZ-2.

---

## Spec file shape (`SPEC-{ID}-{slug}.md`)

````markdown
# SPEC-{ID}: {Delivery title}

| Priority | Category | Status | Wave | Depends on | Blocks | Index |
|--|--|--|--|--|--|--|
| P1 | Feature | Ready | 1 | None | SPEC-{ID+1} | [[../IDEA-{ID}-{slug}-Specs]] |

## Delivery Brief
- **Who:** {persona}
- **Gets:** {the smallest usable outcome}
- **Value:** {why it matters}
- **Measured by:** {bounded, observable signal}
- **Out of scope:** {explicit exclusions}

## Acceptance Criteria
- [ ] AC-1 - {concrete, testable}

## Backlog
| Key | Type | Title | Status | Depends on | Wave | Files | File |
|--|--|--|--|--|--|--|--|
| Enabler-001 | Enabler | {title} | Ready | None | 1 | 3 | [[Backlog/Enabler-001-{slug}]] |
| Story-001 | Story | {title} | Ready | Enabler-001 | 2 | 4 | [[Backlog/Story-001-{slug}]] |

## Architecture
- Spec design: [[arch]]
- Architecture Document: [[../../../architecture/architecture]]
- ADRs / guardrails / quality gates: [[../../../architecture/guardrails]], [[../../../architecture/quality-gates]]

## Risks
- {risk} - {mitigation}
````

Use wikilinks only. Never use bare relative paths, and never link
`architecture/README.md` (it must not exist). The `Wave` column is
spec-writer's first cut. The planner's `plan.md -> ## Waves` is
authoritative, and items in the same wave must have disjoint impacted files.

---

## Backlog item shape (`Backlog/Story-*.md`, `Backlog/Enabler-*.md`)

````markdown
# Story-001: {Title}

| Type | Parent | Priority | Estimate | Status | Dialect | Depends on | Blocks |
|--|--|--|--|--|--|--|--|
| Story | [[../SPEC-{ID}-{slug}]] | P1 | S | Ready | frontend-react | None | Story-003 |

## Statement
As a {persona}, I want {capability}, so that {value}.

## Acceptance Criteria
- [ ] AC-1 - Given {context}, when {action}, then {result}.

## INVEST
I PASS · N PASS · V PASS · E PASS · S PASS · T PASS  ({notes only for non-obvious calls})

## Impacted Files
- `src/IDEA-{ID}-{slug}/...` - {change}

## Test Hints
- unit: ... · integration: ... (map to AC IDs)
````

Enablers replace `## Statement` with `## Outcome Statement`: *Enable {outcome}
by {technical work}, so that {value}.*

INVEST is required for every story and enabler (Independent, Negotiable,
Valuable, Estimable, Small, Testable). If an item fails, split it, rewrite
it, or mark it `Blocked`.

---

## Bug item shape (`Backlog/Bug-*.md`)

````markdown
# Bug-001: {Title}

| Type | Parent | Source | Severity | Status | Story / AC | Regression test | Evidence |
|--|--|--|--|--|--|--|--|
| Bug | [[../SPEC-{ID}-{slug}]] | human \| verifier | blocker \| major \| minor | open | Story-001 / AC-2 | T-0NN | [[../../../../TestResults/IDEA-{ID}/SPEC-{ID}/Story-001-AC-2-Bug-001]] |

## Reproduce
1. ...

## Expected / Actual
- Expected: ...
- Actual: ...

## Impacted Files
- `src/IDEA-{ID}-{slug}/...` (best guess; the planner confirms)
````

Status lifecycle: `open -> fixing -> fixed -> verified`, or `wontfix` (human
decision only). A spec can't reach `Done` while any `blocker` or `major` bug
is open (`check-run-conformance -Scope bugs`). The regression test is written
first and must fail before the fix, then pass after it.

---

## ROADMAP.md shape

````markdown
# Roadmap - IDEA-{ID}: {title}

## Execution Plan
| Order | Spec | Delivery | Depends on | Lane | Est. tokens | Restore point |
|--|--|--|--|--|--|--|
| 1 | [[SPEC-001-{slug}/SPEC-001-{slug}]] | {one line} | None | A | 180k | CP after review |
| 1 | [[SPEC-002-{slug}/SPEC-002-{slug}]] | {one line} | None | B | 140k | CP after review |
| 2 | [[SPEC-003-{slug}/SPEC-003-{slug}]] | {one line} | SPEC-001 | A | 220k | CP after review |

## Token Plan
| Phase | Agent | Model / effort | Per spec | Total |
|--|--|--|--|--|
| plan | planner | from orchestrator.json | ... | ... |
| implement | implementer | from orchestrator.json | ... | ... |
| verify | verifier | from orchestrator.json | ... | ... |
| **Total** | | | | {n} (band ±{x}%) |

## Optimisation Notes
- Specs in the same order number run in parallel lanes (no cross-spec dependency).
- Take a restore point (`kcc-checkpoint`) after each spec reaches review, and whenever the usage watcher reaches its soft threshold.
````

Model and effort come from `coordination/orchestrator.json`. Never restate
them by hand.

---

## Atomic test cases (in `plan.md`)

````markdown
## Atomic test cases
| Test ID | Item | AC | Level | Description |
|--|--|--|--|--|
| T-001 | Story-001 | AC-1 | unit | {assertion} |
````

The Test ID appears in the real test's name, annotation, or tag, so
`check-traceability` can map AC -> Test ID -> test -> result.

---

## Source code layout

Code lives under `src/IDEA-{ID}-{slug}/` with its own `README.md`. See
[[workspace]] and `.KCC/kernel/cells.md`.

---

## Legacy v5 specs

Specs created before v6 may contain `backlog.md`, `parallelization.md`,
`budget.md`, and `handovers.md`. Tools and agents read them as fallbacks:
the backlog table comes from `backlog.md`, and waves come from
`parallelization.md` when `plan.md` has none. Never create them in new
specs. To migrate, fold the backlog table into the spec file, move the waves
into `plan.md`, and delete the retired files.

---

## Top-level MOC: `specs/specs.md`

Per-idea sections (index + roadmap links), a cross-idea dependency table,
statistics (ideas, specs, in progress, done, blocked), and a link to this
protocol.

## Related

[[idea-layout]] · [[auto-mode]] · [[parallel-execution]] ·
[[architecture-governance]] · [[test-results-layout]] · [[session-continuity]] ·
[[repo-bootstrap]] · [[../contracts/tool-contract|tool-contract]]
