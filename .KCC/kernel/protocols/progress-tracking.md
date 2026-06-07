---
# Functional fields
description: Markdown-first progress-tracking convention for KCC v0.4. Defines the cross-idea spec status board, the idea status board, the per-idea spec index, the per-spec story/enabler aggregator, and the future hook for external tracker adapters (Jira / DevOps / Asana / Linear / GitHub Issues) declared via `.KCC/settings.json`.
inputs: Spec-writer creates and updates rows; planner refreshes plan status; implementer flips Ready -> In progress; verifier flips to In review or Blocked; human flips to Done or Abandoned.
outputs: `ideation/ideas.md` (idea status board), `specs/specs.md` (cross-idea spec status board), per-idea `specs/IDEA-{ID}-{slug}-Specs/IDEA-{ID}-{slug}-Specs.md`, per-spec `specs/IDEA-{ID}-{slug}-Specs/SPEC-{ID}-{slug}/SPEC-{ID}-{slug}.md`, and the top-level `progress.md` landing page.

# Obsidian metadata
title: "Progress Tracking Protocol"
aliases:
  - progress-tracking
  - status-board
  - moc-progress
tags:
  - framework/protocol
  - progress-tracking
  - documentation
  - kcc/v04
created: 2026-05-29
updated: 2026-05-29
version: 1.0.0
status: active
copyright: "KCC framework (c) 2026 Tarek Fawaz"
homepage: "https://tikasway.dev/kcc"
license: "Licensed under the terms in LICENSE"
---

# Progress Tracking

This protocol defines the **markdown-first** progress-tracking convention
for KCC v0.4. Per the user's call, progress lives in markdown MOCs (not
HTML, not a database, not a built-in dashboard). External trackers (Jira /
DevOps / Asana / Linear / GitHub Issues) are a **future hook** controlled
by `.KCC/settings.json` - the schema is reserved here; the adapter
implementation is deferred to v1.2.

## Convention

- Progress lives in markdown MOCs across four levels:
  1. **Top-level landing page** - `progress.md` at the repo root, the
     single human-facing entrypoint.
  2. **Cross-idea spec board** - `specs/specs.md`, the spec MOC across
     every idea.
  3. **Idea board** - `ideation/ideas.md`, every idea with its current
     status and link to its spec index.
  4. **Per-idea spec index** -
     `specs/IDEA-{ID}-{slug}-Specs/IDEA-{ID}-{slug}-Specs.md`, the spec
     status board for one idea.
  5. **Per-spec aggregator** -
     `specs/IDEA-{ID}-{slug}-Specs/SPEC-{ID}-{slug}/SPEC-{ID}-{slug}.md`,
     which rolls up the story/enabler statuses for one spec.
- Status is a string field in a markdown table. No emoji-based statuses,
  no HTML.
- Each level aggregates the level below it. Updates propagate up via the
  agents listed in [Who updates what](#who-updates-what).

## File responsibilities

| File | Tracks | Created by | Updated by |
|--|--|--|--|
| `progress.md` | Single landing page linking to ideas + specs + per-idea indexes | this protocol (initial) | rarely (when integrations are added) |
| `ideation/ideas.md` | Every idea with status + ROI + spec-index link | idea-interrogator (first idea) | idea-interrogator on every new idea; spec-writer when the idea is handed off |
| `specs/specs.md` | Every spec across every idea | spec-writer (first spec) | spec-writer on every new spec; planner / implementer / verifier as statuses change |
| `specs/IDEA-{ID}-{slug}-Specs/IDEA-{ID}-{slug}-Specs.md` | Every spec for one idea | spec-writer (first spec for the idea) | spec-writer + planner + verifier |
| `specs/IDEA-{ID}-{slug}-Specs/SPEC-{ID}-{slug}/SPEC-{ID}-{slug}.md` | Every story / enabler for one spec | spec-writer | spec-writer + implementer + verifier |

## Status taxonomy

Both ideas and specs/stories/enablers share a common spirit but have
slightly different states because ideas have a "Parked" notion that
specs do not.

### Idea status

| Status | Meaning |
|--|--|
| `Drafting` | Idea-interrogator is collecting answers; SpecWriterStarter not yet written |
| `Ready for spec` | Briefing complete; awaiting `/spec-create` |
| `Handed off` | `/spec-create` invoked; first SPEC exists; downstream lifecycle owns it |
| `In delivery` | At least one of the idea's specs is `In progress` or further |
| `Done` | Every spec for the idea is `Done` (or explicitly out of scope) |
| `Parked` | Idea is intentionally on hold; not abandoned |
| `Abandoned` | Idea will not proceed |

### Spec / story / enabler status

| Status | Meaning | Who flips it |
|--|--|--|
| `Drafting` | Spec-writer is writing the spec / story / enabler | spec-writer |
| `Ready` | Spec or backlog item passes INVEST and is ready to plan / implement | spec-writer (on completion) |
| `In progress` | Implementer is actively working it | implementer (start of work) |
| `Blocked` | Hard blocker found (failed gate, missing dependency, etc.) | verifier (or any agent that detects it) |
| `In review` | Implementation diff + tests done; verifier or human is reviewing | verifier (after `/spec-test` writes verdict) |
| `Done` | Human approved; ready to ship / merged | human |
| `Abandoned` | Cancelled; will not be delivered | human |

The taxonomy is intentionally small. Anything more nuanced (e.g. "QA",
"UAT", "Staging") belongs in an external tracker once the adapter ships.

## Who updates what

- **idea-interrogator** - creates the row in `ideation/ideas.md`; sets
  `Drafting` and flips to `Ready for spec` when the briefing is
  complete.
- **spec-writer** - creates the per-idea spec index when the idea's
  first spec is materialized; flips the idea row in `ideation/ideas.md`
  to `Handed off`; creates the spec row in `specs/specs.md`,
  in the per-idea index, and in the per-spec folder note; sets
  story/enabler rows to `Drafting` (during decomposition) and
  `Ready` (on completion).
- **planner** - does not change status, but adds plan-readiness
  indicators ("plan ready", "atomic test cases enumerated") in the
  per-spec aggregator. Refreshes the per-idea index `Plan` column.
- **implementer** - flips the spec / story / enabler row from `Ready`
  to `In progress` at start of work; on completion of all atomic test
  cases, hands off to verifier (status stays `In progress` until the
  verifier writes a verdict).
- **verifier** - runs `/spec-test`; flips to `In review` (verdict
  written) or `Blocked` (gate failure / acceptance criterion failure).
- **human** - flips `In review` to `Done` (approve) or `Abandoned`
  (cancel).
- **Idea-level rollup.** When every spec under an idea reaches `Done`,
  spec-writer (or any agent updating that idea's index) flips the idea
  row from `In delivery` / `Handed off` to `Done`. When at least one
  spec is `In progress`, the idea is `In delivery`.

## Required tables

### `ideation/ideas.md`

```markdown
| IDEA-ID | Date | Brief | ROI confidence | Status | Spec index | Effort estimate | Token budget |
|--|--|--|--|--|--|--|--|
```

### `specs/specs.md` - status snapshot (top-of-file)

```markdown
## Status snapshot

- **Ideas with specs**: N
- **Total specs**: N (Ready: N, In progress: N, In review: N, Done: N, Blocked: N)
- **Total stories**: N
- **Total enablers**: N
```

### `specs/specs.md` - per-idea section

Each idea group adds a row to its spec table plus a one-row
mini-summary:

```markdown
### IDEA-{ID}: {Idea title}

- Per-idea index: [[IDEA-{ID}-{slug}-Specs/IDEA-{ID}-{slug}-Specs|IDEA-{ID} specs]]

| Specs | Ready | In progress | In review | Done | Blocked |
|--:|--:|--:|--:|--:|--:|
| {n} | {n} | {n} | {n} | {n} | {n} |

| Key | Title | Priority | Status | Stories (R/IP/D) | Enablers (R/IP/D) | Plan | Review | File |
|--|--|--|--|--|--|--|--|--|
```

The `Stories (R/IP/D)` / `Enablers (R/IP/D)` columns are tiny rollups:
`{Ready}/{In progress}/{Done}` count out of `{total}`.

### Per-idea index - `IDEA-{ID}-{slug}-Specs.md`

Per the spec-layout protocol, this file already has a Specs table. Keep
the same shape but add a `Stories (R/IP/D)` / `Enablers (R/IP/D)` rollup
column so the index reflects the actual progress of each spec's backlog.

### Per-spec folder note - `SPEC-{ID}-{slug}.md`

The per-spec aggregator rolls up the spec's own story/enabler rows.
Per the spec-layout protocol, the folder note already has a `Stories
and Enablers` table; this protocol adds a status snapshot above it:

```markdown
## Status snapshot

- **Spec status**: Ready | In progress | Blocked | In review | Done | Abandoned
- **Stories**: {n total} - Ready: {n}, In progress: {n}, In review: {n}, Done: {n}, Blocked: {n}
- **Enablers**: {n total} - Ready: {n}, In progress: {n}, In review: {n}, Done: {n}, Blocked: {n}
- **Plan**: drafted | ready | refresh-needed
- **Review**: awaiting | passed | failed
```

## Future hook - external tracker adapters

`.KCC/settings.json` reserves a `tracker` block; the adapter
implementations are deferred to v1.2.

```jsonc
{
  "tracker": {
    "type": "none",              // none | jira | devops | asana | linear | github-issues
    "project": null,              // tracker-specific project key
    "credentials_ref": null,      // env var / secret ref; NEVER inline
    "mirror_direction": "push",   // push | pull | bidirectional
    "status_map": {               // markdown status -> external tracker status
      "Drafting":   "To Do",
      "Ready":      "Ready",
      "In progress":"In Progress",
      "Blocked":    "Blocked",
      "In review":  "In Review",
      "Done":       "Done",
      "Abandoned":  "Cancelled"
    }
  }
}
```

When `tracker.type !== "none"`, a future adapter mirrors the markdown
status rows above into the external tracker. The schema is fixed by
this protocol; the adapter is the only moving part.

Adapter table:

| Type | Status | Notes |
|--|--|--|
| `none` | active (default) | Markdown-only; no external mirroring |
| `jira` | TBD (v1.2) | REST v3; epic -> SPEC, story/enabler -> JIRA issue |
| `devops` | TBD (v1.2) | Azure DevOps Work Items; area path = idea slug |
| `asana` | TBD (v1.2) | Asana Tasks; project = idea; sections = specs |
| `linear` | TBD (v1.2) | Linear Issues; project = idea; cycle = spec |
| `github-issues` | TBD (v1.2) | GitHub Issues + Projects (v2) |

The markdown MOCs remain authoritative even after the adapter ships:
they are the source-of-truth that the adapter mirrors. If the external
tracker and the markdown disagree, the markdown wins and the adapter
reconciles on the next push.

## Related

- Spec layout: [[spec-layout]]
- Idea layout: [[idea-layout]]
- Auto mode: [[auto-mode]]
- Architecture documentation: [[architecture-documentation]]
- Architecture governance: [[architecture-governance]]
- Obsidian standard: [[obsidian-standard]]
- Top-level progress: [[../../progress]]
- Ideas MOC: [[../../ideation/ideas]]
- Specs MOC: [[../../specs/specs]]
