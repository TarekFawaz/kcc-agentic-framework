---
# Functional fields (consumed by harness adapters)
name: architecture-review
description: >
  Run the architecture-critic over the produced `architecture/` artifacts and
  print a semantic conformance verdict (CONFORMANT / DRIFT) plus specific drift
  findings and required fixes. Read-only and cheaper than the architect; it
  reviews, the architect fixes. Usage: /architecture-review
argument-placeholder: <ARGS>
delegates-to:
  - architecture-critic
maturity: L1
maintainer: tarek.fawaz1983@gmail.com
copyright: "KCC framework (c) 2026 Tarek Fawaz"
homepage: "https://tikasway.dev/kcc"
license: "Licensed under the terms in LICENSE"

# Obsidian metadata (used in the vault, ignored by harness adapters)
title: Architecture Review Skill
tags:
  - framework/skill
  - lifecycle/meta
  - architecture
created: 2026-06-07
updated: 2026-06-07
version: 1.0.0
status: active
---

# Architecture Review

Run a semantic conformance review of the architect's output via the
**architecture-critic** agent. This is the cheap, read-only second opinion that
catches drift (thin `architecture.md`, `.mmd`/`diagrams/` files, missing or
boilerplate supporting docs, degraded/placeholder design) and pushes the
architect back to standard.

## Steps

1. **Locate the architecture.** Find the `architecture/` folder. Note the
   active architecture depth (`lite` | `standard` | `deep`) from the source
   idea (`ideation/IDEA-{ID}-{slug}/idea-{ID}-{slug}.md`), defaulting to
   `standard` if absent. Gather the source idea / `TechnicalDecisionBrief.md`
   so the critic can judge fit.
2. **Invoke the architecture-critic** (`balanced`, read-only) with the active
   depth, the `architecture/` artifacts, and the source idea/tech brief. The
   critic reviews against [[.KCC/kernel/protocols/architecture-documentation]],
   [[.KCC/kernel/protocols/architecture-governance]],
   [[.KCC/kernel/protocols/architecture-styles]], and
   [[.KCC/kernel/protocols/api-standards]].
3. **Print the result** directly: the verdict (CONFORMANT / DRIFT), the
   findings table (issue / standard-rule / required fix), the semantic-fit
   note, and the critic's `Confidence: NN%`. Do not edit any architecture
   files - the critic is read-only and the architect owns the fixes.

## Related

- Architecture critic agent: [[../agents/architecture-critic]]
- Architect agent: [[../agents/architect]]
- Architecture documentation: [[.KCC/kernel/protocols/architecture-documentation]]
- Architecture governance: [[.KCC/kernel/protocols/architecture-governance]]
