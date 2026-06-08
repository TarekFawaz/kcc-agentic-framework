---
# Functional fields
description: Folder convention for every epic-level spec in the framework, grouped under a per-idea Specs folder so the idea-to-spec-to-story trace chain is visible in Obsidian.
inputs: An IDEA-ID + slug from the upstream idea, plus a SPEC-ID + slug chosen by the spec-writer agent.
outputs: A `specs/IDEA-{ID}-{slug}-Specs/SPEC-{ID}-{slug}/` epic folder under its parent idea-specs folder, with a same-name folder note, backlog, plan, review, budget, and handover files.

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
updated: 2026-06-05
version: 5.2.0
status: active
copyright: "KCC framework (c) 2026 Tarek Fawaz"
homepage: "https://tikasway.dev/kcc"
license: "Licensed under the terms in LICENSE"
---

# Spec Folder Layout

Every spec in this framework is an **epic folder**, grouped under a parent
**idea-specs folder** so the trace chain `Idea -> Specs -> Story/Enabler` is
visible in Obsidian's graph and backlinks.

```text
ideation/
`-- IDEA-{ID}-{slug}/
    `-- idea-{ID}-{slug}.md           <- upstream idea (untouched by spec layer)

specs/
|-- specs.md                          <- top-level MOC across all ideas
`-- IDEA-{ID}-{slug}-Specs/           <- per-idea spec group
    |-- IDEA-{ID}-{slug}-Specs.md     <- index; the ONLY file that links back to idea-{ID}-{slug}.md
    `-- SPEC-{ID}-{slug}/             <- one folder per epic spec
        |-- SPEC-{ID}-{slug}.md       <- epic folder note; the ONLY file that links stories/enablers
        |-- backlog.md
        |-- Backlog/                   <- stories + enablers folder
        |   |-- Story-{ID}-{slug}.md
        |   `-- Enabler-{ID}-{slug}.md
        |-- parallelization.md
        |-- plan.md
        |-- review.md
        |-- budget.md
        |-- handovers.md
        |-- arch.md                   <- REQUIRED, spec-local design document (embeds diagrams inline)
        |-- notes.md                  <- optional
        `-- traces/                   <- optional, per-spec sessions
```

**Trace chain by design:**

- `ideation/IDEA-{ID}-{slug}/idea-{ID}-{slug}.md` -> `specs/IDEA-{ID}-{slug}-Specs/IDEA-{ID}-{slug}-Specs.md` (this is the only edge from idea into the specs world)
- `IDEA-{ID}-{slug}-Specs.md` -> each `SPEC-{ID}-{slug}/SPEC-{ID}-{slug}.md`
- `SPEC-{ID}-{slug}.md` -> each `Backlog/Story-{ID}-{slug}.md` and `Backlog/Enabler-{ID}-{slug}.md`

No skipping levels: stories/enablers never link directly up to an idea, only
to their spec. Specs never link directly up to ideation, only to their
idea-specs index.

---

## Required files

| File | Owner | Purpose |
|--|--|--|
| `IDEA-{ID}-{slug}-Specs/IDEA-{ID}-{slug}-Specs.md` | spec-writer (creates on first spec for the idea; updates thereafter) | Per-idea spec index. Lists every SPEC, status, links. Single source of truth for the idea->specs edge. |
| `SPEC-{ID}-{slug}/SPEC-{ID}-{slug}.md` | spec-writer | Folder note + actual epic spec: problem, target state, value, measurement, links to stories/enablers. |
| `SPEC-{ID}-{slug}/backlog.md` | spec-writer | INVEST-checked index of stories + enablers, each linked to a file under `Backlog/`. |
| `SPEC-{ID}-{slug}/Backlog/Story-{ID}-{slug}.md` | spec-writer | One story per file; sub-agent handoff-ready. |
| `SPEC-{ID}-{slug}/Backlog/Enabler-{ID}-{slug}.md` | spec-writer | One enabler per file; sub-agent handoff-ready. |
| `SPEC-{ID}-{slug}/parallelization.md` | spec-writer + planner | Dependency waves and sub-agent session proposals. |
| `SPEC-{ID}-{slug}/plan.md` | planner | Ordered implementation plan + atomic test-case enumeration mapped to AC IDs. |
| `SPEC-{ID}-{slug}/review.md` | verifier | PASS/FAIL verdict per epic criterion + per backlog item criterion. |
| `SPEC-{ID}-{slug}/budget.md` | token-guard | Forecasts, approvals, aborts, actuals. |
| `SPEC-{ID}-{slug}/handovers.md` | any agent crossing context | Handover-envelope log. |
| `SPEC-{ID}-{slug}/arch.md` | spec-writer (stub) -> architect (fills) | Per-spec design document. EMBEDS the spec's design slice inline (fenced mermaid + prose), not links. Shape, embed rule, and content bar in [[architecture-documentation]]. |

The folder note, `backlog.md`, backlog item files, and `parallelization.md`
have real content at folder-creation time. `plan.md`, `review.md`,
`budget.md`, `handovers.md`, and `arch.md` are created as stubs with
frontmatter and `> awaiting <agent>`; the `arch.md` stub also carries the
per-spec design-document section skeleton (it is copied from
[[architecture-documentation|the spec-arch template]]). The architect later
fills `arch.md` so it contains at least one embedded ```mermaid``` block plus
the design narrative - a link-only or sub-1 KB `arch.md` fails verification
(the **content bar**).

---

## Spec as Epic

Treat `SPEC-{ID}` as the epic key. A spec may contain multiple stories and
enablers. Decompose every non-trivial epic before handoff to planning.

| Type | Use when | Required statement |
|--|--|--|
| Epic | Top-level business or product outcome represented by `SPEC-{ID}`. | Epic goal + business value + how-measured. |
| Story | User-facing behavior, workflow, or capability. | `As a <persona>, I want <capability>, so that <value>.` |
| Enabler | Technical, architectural, migration, compliance, or infrastructure work needed to deliver stories. | `Enable <capability/outcome> by <technical work>, so that <story/epic value>.` |

Every backlog item must be small enough to implement and verify
independently. Maximize independence so parallel agents can work on parallel
items.

---

## INVEST Rule

Every story and enabler must pass INVEST before the spec is considered ready:

| Letter | Meaning | Practical check |
|--|--|--|
| I | Independent | Can be built without hidden coupling to unrelated backlog items, except explicit dependencies. |
| N | Negotiable | Describes outcome and constraints, not a rigid implementation script. |
| V | Valuable | Delivers user, business, risk, learning, or technical enablement value. |
| E | Estimable | Enough information to size and plan. |
| S | Small | Fits inside a reasonable implementation slice; split if it spans too many concerns. |
| T | Testable | Has objective acceptance criteria and verification steps. |

If an item fails INVEST, split it, rewrite it, or mark it as a blocker in
`backlog.md`.

---

## `IDEA-{ID}-{slug}-Specs.md` Shape (per-idea spec index)

The per-idea spec index is the only file that links upstream to the idea
folder. It is created when the first spec is materialized for the idea and
updated as new specs land.

````markdown
# Specs for IDEA-{ID}: {Idea title}

## Source idea

- Parent idea: [[../../ideation/IDEA-{ID}-{slug}/idea-{ID}-{slug}|IDEA-{ID}: {Idea title}]]

## Specs

| Key | Title | Priority | Status | Stories | Enablers | Plan | Review | File |
|--|--|--|--|--|--|--|--|--|
| SPEC-{ID} | {title} | P1 | Ready | {n} | {n} | drafted | awaiting | [[SPEC-{ID}-{slug}/SPEC-{ID}-{slug}]] |

## Statistics

- Total specs: {n}
- In progress: {n}
- Done: {n}
- Blocked: {n}

## Related

- All ideas: [[../../ideation/ideas|ideas MOC]]
- All specs across all ideas: [[../specs|specs MOC]]
- Layout protocol: [[../../.KCC/kernel/protocols/spec-layout]]
````

---

## Folder Note Shape (`SPEC-{ID}-{slug}.md`)

The same-name Markdown file is the epic parent.

````markdown
# SPEC-{ID}: {Epic Title}

## Priority: {P0/P1/P2/P3} {CRITICAL/HIGH/MEDIUM/LOW}
## Category: {Bug|Feature|Refactor|Infrastructure|Security|Observability}
## Idea-specs index
[[../IDEA-{ID}-{idea-slug}-Specs|Specs for IDEA-{ID}]]

---

## Epic Summary
{One-paragraph outcome}

## Why this exists
{The business or technical motivation}

## Value provided
{The concrete outcome users / stakeholders see}

## How measured
{The success metric(s) - bounded, observable}

## Problem Statement

### Current State
{What is happening now}

### Target State
{What should be true after the epic is complete}

## Scope

### In Scope
- ...

### Out of Scope
- ...

## Impacted Files
- `path/to/file.ext` - {what changes and why}

## Epic Acceptance Criteria
- [ ] AC-1 - {Concrete, testable criterion}
- [ ] AC-2 - {Concrete, testable criterion}

## Stories and Enablers

(This is the only place stories/enablers are linked from. Their parent edge
is to this file, never directly to the idea.)

| Key | Type | Title | Status | File |
|--|--|--|--|--|
| Story-001 | Story | {title} | Ready | [[Backlog/Story-001-{slug}]] |
| Enabler-001 | Enabler | {title} | Ready | [[Backlog/Enabler-001-{slug}]] |

## Architecture

Use **wikilinks** only (never bare relative paths, never `architecture/README.md`
- that file must not exist; the Architecture Document is `architecture.md`):

- Architecture Document: [[../../../architecture/architecture]]
- Technical decision brief: {wikilink or "Not required"}
- ADRs: {wikilinks to `[[../../../architecture/adrs/ADR-...]]` or "None yet"}
- Guardrails: [[../../../architecture/guardrails]]
- Quality gates: [[../../../architecture/quality-gates]]

(Diagrams are embedded inline in `architecture.md` and the spec's `arch.md` -
there are no standalone `.mmd` diagram files to link.)

## Risks
- {Risk} - {mitigation}

## Dependencies
- Depends on: {wikilinks or "None"}
- Blocks: {wikilinks or "None"}

## Verification approach
- {How epic-level criteria are verified - references to plan.md test cases}

## Related

- Backlog index: [[backlog]]
- Parallelization: [[parallelization]]
- Plan: [[plan]]
- Review: [[review]]
- Token budget: [[budget]]
- Handover log: [[handovers]]
- Idea-specs index: [[../IDEA-{ID}-{idea-slug}-Specs]]
- All specs across all ideas: [[../../specs|specs MOC]]
- Architecture governance: [[../../../architecture/architecture]]
````

---

## `backlog.md` Shape (per-spec backlog index)

````markdown
# SPEC-{ID} Backlog

## Epic

- Epic key: `SPEC-{ID}`
- Epic title: [[SPEC-{ID}-{slug}|{Epic Title}]]

## Backlog Summary

| Key | Type | Title | Priority | Status | Estimate | Dialect | Complexity | Parallel | Depends on | INVEST | File |
|--|--|--|--|--|--|--|--|--|--|--|--|
| Story-001 | Story | {title} | P1 | Ready | S | frontend-react | medium | yes | None | PASS | [[Backlog/Story-001-{slug}]] |
| Enabler-001 | Enabler | {title} | P1 | Ready | S | backend-nodejs | medium | no | Story-001 | PASS | [[Backlog/Enabler-001-{slug}]] |

## Stories

- [[Backlog/Story-001-{slug}|Story-001: {Title}]]

## Enablers

- [[Backlog/Enabler-001-{slug}|Enabler-001: {Title}]]

## Related

- Epic spec: [[SPEC-{ID}-{slug}]]
- Parallelization: [[parallelization]]
- Plan: [[plan]]
- Review: [[review]]
- Idea-specs index: [[../IDEA-{ID}-{idea-slug}-Specs]]
````

---

## Backlog Item File Shape (`Backlog/Story-*.md` and `Backlog/Enabler-*.md`)

Every story and enabler gets one file under `Backlog/`.

````markdown
# Story-001: {Title}

| Field | Value |
|--|--|
| Issue type | Story |
| Parent epic | [[../SPEC-{ID}-{slug}|SPEC-{ID}]] |
| Priority | P1 |
| Estimate | S |
| Status | Ready |
| Dialect | frontend-react |
| Complexity | medium |
| Parallel eligible | yes |
| Suggested agent session | implementer using selected dialect |
| Depends on | None |
| Blocks | Story-003 |

## Statement
As a {persona}, I want {capability}, so that {value}.

## Acceptance Criteria
- [ ] AC-1 - Given {context}, when {action}, then {observable result}.

## Success Factors
- {Bounded, observable signal that this story is delivering value (e.g. "P95 response < 200ms", "100% of test cases pass")}

## INVEST Check
| Letter | Result | Notes |
|--|--|--|
| I | PASS | ... |
| N | PASS | ... |
| V | PASS | ... |
| E | PASS | ... |
| S | PASS | ... |
| T | PASS | ... |

## Impacted Files
- `src/IDEA-{ID}-{slug}/...` - {expected change}

## Test Hints (for implementer + planner test-plan)
- Unit: {what unit tests must exist, mapped to AC IDs}
- Integration: {what integration tests must exist, mapped to AC IDs}
- Performance / Security: {only if scoped during interrogation}

## Handoff Notes
- {Context for a sub-agent}
````

For enablers, replace `## Statement` with:

```markdown
## Outcome Statement
Enable {capability/outcome} by {technical work}, so that {story or epic value}.
```

---

## `parallelization.md` Shape

Created by spec-writer; refined by planner.

**File-disjoint wave rule.** Items in the **same wave must have disjoint
`Impacted Files`**. The planner enforces this: if two items would touch the same
file, they go to different waves. This makes **parallel-eligible ==
file-disjoint** by construction, which is the merge-safety guarantee that lets
the orchestrator fan out a wave **concurrently** instead of self-overriding to
sequential. The `File-disjoint` column records this per wave. Git-worktree
isolation is an OPTIONAL upgrade for risky cases, not the default. Full
semantics, the abstract spawner contract, and the per-harness realization matrix
are in [[parallel-execution]].

**Per-harness realization.** The waves here are harness-neutral intent. Each
harness realizes the spawner contract `run(independent_items)` differently:
Claude Code uses native parallel subagents (built); Codex uses N headless
`codex exec` processes; OpenCode uses N headless sessions; Ollama uses
concurrent model calls bounded by `OLLAMA_NUM_PARALLEL` issued by the driving
harness; generic uses `start-agent-session` or sequential (these four are
documented, not yet built). See [[parallel-execution]] and the adapter notes.

````markdown
# SPEC-{ID} Parallelization

## Summary
{Whether sub-agent work is safe and where dependencies exist}

## Dependency Waves

| Wave | Items | Can run together | File-disjoint | Reason |
|--|--|--|--|--|
| 1 | Enabler-001, Story-001 | yes | yes | No dependencies; disjoint impacted files |
| 2 | Story-002 | no | n/a | Depends on Enabler-001 |

## Proposed Sub-agent Sessions

| Session | Items | Dialect | Complexity | Working directory | Expected output |
|--|--|--|--|--|--|
| A | Story-001 | frontend-react | medium | `src/IDEA-{ID}-{slug}/` | UI changes + tests |

## Human Permission
Opening sibling terminal/CMD/harness windows requires explicit human approval.
If declined, run the same waves sequentially in the current session. (This is
the visible/sandboxed delivery surface; the fan-out itself is concurrent
sub-agent execution per [[parallel-execution]], not window-opening.)
````

---

## Top-level MOC: `specs/specs.md`

`specs.md` is the single landing page across **every** idea's specs. It must
contain:

1. Per-idea sections, each listing the per-idea specs index and a summary table.
2. Cross-idea dependency table or matrix.
3. Statistics: total ideas with specs, total specs, in progress, done, blocked.
4. Link to this protocol: `[[../.KCC/kernel/protocols/spec-layout]]`.

Spec links go through the per-idea index when possible:

```text
[[IDEA-001-csv-to-json-Specs/IDEA-001-csv-to-json-Specs|IDEA-001 specs]]
[[IDEA-001-csv-to-json-Specs/SPEC-001-cli-skeleton/SPEC-001-cli-skeleton|SPEC-001]]
```

---

## Test plan inside `plan.md`

The planner is responsible for an **atomic test-case enumeration** section in
`plan.md` that decomposes each story's acceptance criteria into individual
test cases the implementer will turn into real code via the
`testing-unit` / `testing-integration` (and optionally `testing-performance`
/ `testing-security`) dialects. Format:

````markdown
## Atomic test cases

| Test ID | Story / Enabler | AC | Level | Description |
|--|--|--|--|--|
| T-001 | Story-001 | AC-1 | unit | {what is asserted} |
| T-002 | Story-001 | AC-2 | integration | {what is asserted} |
````

There is no separate test-case writer agent. The planner owns this
decomposition; the implementer writes the code.

---

## Source code layout per idea

When implementation begins, source code for a spec lives under the
**per-idea** source tree to keep multiple ideas in one workspace isolated:

```text
src/IDEA-{ID}-{slug}/
|-- README.md           <- idea-level README the implementer maintains
|-- ...                 <- actual solution code
```

This isolation is the workspace-layer contract; see
[[workspace]] (when published) and `.KCC/kernel/cells.md` for cell
materialization details.

---

## Related

- Idea layout: [[idea-layout]]
- Auto mode: [[auto-mode]]
- Parallel execution: [[parallel-execution]]
- Architecture governance: [[architecture-governance]]
- Trace layout: [[trace-layout]]
- Obsidian standard: [[obsidian-standard]]
- Cells: [[cells]]
- Spec writer agent: [[.KCC/capabilities/agents/spec-writer]]
- Planner agent: [[.KCC/capabilities/agents/planner]]
- Verifier agent: [[.KCC/capabilities/agents/verifier]]
- All protocols: [[../README|Framework README]]
