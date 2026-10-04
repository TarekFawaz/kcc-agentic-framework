---
title: Planner plan.md Template
tags:
  - framework/agent-ref
updated: 2026-09-21
---

# Planner plan.md Template

## plan.md body

Write into `specs/IDEA-{ID}-{slug}-Specs/SPEC-{ID}-{slug}/plan.md`:

````markdown
# SPEC-{ID} Implementation Plan

## Dependency Check
{Confirm all blocking specs are resolved, or flag blockers as STOP.}

## Architecture Gate Check
{Guardrails / quality gates that apply, or "No architecture gates defined yet."}

## Backlog Coverage
| Item | Type | Dialect | Complexity | Wave | Plan coverage | Notes |
|--|--|--|--|--|--|--|
| Story-001 | Story | frontend-react | medium | 1 | Covered | ... |
| Enabler-001 | Enabler | backend-nodejs | medium | 1 | Covered | ... |

## Ordered Changes
Numbered list of files to modify, in dependency order. All new source paths
use the per-idea workspace prefix `src/IDEA-{ID}-{slug}/...`.

For each step:
- **Backlog item(s):** {Story-001, Enabler-001, ...}
- **File:** `src/IDEA-{ID}-{slug}/path/to/file.ext`
- **Change:** {what to modify}
- **Why:** {which epic AC or backlog AC this satisfies}
- **Depends on:** {which prior step, if any}

## Waves
Authoritative wave map (overrides the spec's `Wave` column). Same-wave items
must have disjoint `Impacted Files`; `check-wave-scope -Spec -Wave` enforces
it. See [[.KCC/kernel/protocols/parallel-execution]].

| Wave | Items | Files | File-disjoint | Notes |
|--|--|--|--|--|

## Dialects Loaded
- `frontend-react` - {why}
- `backend-nodejs` - {why}
- `testing-unit` - mandatory
- `testing-integration` - mandatory
- `testing-performance` - {only if scoped}
- `testing-security` - {only if scoped}

## New Files
{Any new files needed: tests, configs, docs, migrations, etc., all under
`src/IDEA-{ID}-{slug}/`}

## Risk Flags
{Lock ordering, breaking changes, config changes, rollback concerns,
cross-idea infrastructure leaks}

## Atomic test cases

| Test ID | Item | AC | Level | Description |
|--|--|--|--|--|
| T-001 | Story-001 | AC-1 | unit | {what is asserted} |
| T-002 | Story-001 | AC-2 | integration | {what is asserted} |
| T-003 | Bug-001 | Story-001/AC-2 | unit | regression: fails before fix |

Every item AC appears at least once; <= 8 rows per item (SZ-4). Bug items get
a failing regression Test ID first. Levels: `unit`, `integration`,
`performance`, `security` (the last two only when that dialect is loaded).
The Test ID must appear in the real test's name/annotation/tag.

## Verification Steps
{Concrete commands or checks mapped to epic criteria and backlog items; cite
the Test IDs above where applicable}

## Scope
{Small (1-3 files) | Medium (4-8) | Large (9+)}

## Confidence
Confidence: NN%

## Related
- Epic spec: [[SPEC-{ID}-{slug}]]
- Spec design: [[arch]]
- Roadmap / token plan: [[../ROADMAP]]
- Idea-specs index: [[../IDEA-{ID}-{slug}-Specs]]
- All specs: [[../../specs|All specs MOC]]
````
