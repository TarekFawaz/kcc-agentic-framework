---
title: Progress
aliases:
  - progress
  - progress-landing
tags:
  - progress-tracking
  - entrypoint
  - kcc/v04
created: 2026-05-29
updated: 2026-05-29
version: 1.0.0
status: active
---

# Progress

Single human-facing landing page for the state of work in this repo.
Progress is **markdown-first** by design - every status lives in a
markdown MOC, not a database, not HTML, not a built-in dashboard.
External trackers (Jira / Azure DevOps / Asana / Linear / GitHub Issues)
are a **future hook** controlled by `.KCC/settings.json`; see the
[Future integrations](#future-integrations) table below. The full
convention is defined in
[[.KCC/kernel/protocols/progress-tracking|the progress-tracking protocol]].

## Ideas

- All ideas with their current status: [[ideation/ideas|Ideas MOC]]

## Specs across ideas

- Every spec across every idea, grouped by per-idea folder:
  [[specs/specs|Specs MOC]]

## Per-idea spec indexes

> Populated as ideas get specs - see
> `specs/IDEA-*-Specs/IDEA-*-Specs.md`. Each idea group inside
> [[specs/specs|Specs MOC]] also links to its index, so this section is
> a convenience list rather than the source of truth.

| Idea | Per-idea spec index |
|--|--|
| _(none yet)_ |  |

## Architecture

- Architecture MOC (C4 diagrams, ADRs, fitness functions, NFRs,
  guardrails, quality gates): [[architecture/architecture|Architecture]]
- Architecture documentation protocol:
  [[.KCC/kernel/protocols/architecture-documentation]]
- Architecture governance protocol:
  [[.KCC/kernel/protocols/architecture-governance]]

## Future integrations

The `tracker` block in `.KCC/settings.json` reserves the schema; the
adapter implementations land in v1.2.

| Type | Status | Notes |
|--|--|--|
| `none` | active (default) | Markdown MOCs are the source of truth; no external mirroring |
| `jira` | TBD (v1.2) | Atlassian Jira REST v3; epic <-> SPEC, story / enabler <-> Jira issue |
| `devops` | TBD (v1.2) | Azure DevOps Work Items; area path = idea slug |
| `asana` | TBD (v1.2) | Asana Tasks; project = idea, section = spec |
| `linear` | TBD (v1.2) | Linear Issues; project = idea, cycle = spec |
| `github-issues` | TBD (v1.2) | GitHub Issues + Projects v2; one Project per idea |

Markdown MOCs stay authoritative even after adapters ship. If the
external tracker and the markdown disagree, the markdown wins and the
adapter reconciles on the next push.

## Related

- Progress tracking protocol: [[.KCC/kernel/protocols/progress-tracking]]
- Spec layout protocol: [[.KCC/kernel/protocols/spec-layout]]
- Idea layout protocol: [[.KCC/kernel/protocols/idea-layout]]
- Architecture governance: [[.KCC/kernel/protocols/architecture-governance]]
- Architecture documentation: [[.KCC/kernel/protocols/architecture-documentation]]
- Auto mode: [[.KCC/capabilities/skills/auto]]
- Traces MOC: [[Traces/traces|Traces MOC]]
- Framework README: [[README]]

---

KCC framework (c) 2026 Tarek Fawaz, [tikasway.dev](https://tikasway.dev/kcc). Licensed under the terms in [LICENSE](./LICENSE).
