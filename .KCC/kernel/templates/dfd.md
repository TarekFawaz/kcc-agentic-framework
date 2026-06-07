---
title: "DFD - {Data Flow Name}"
aliases:
  - dfd
  - data-flow-diagram
tags:
  - architecture
  - dfd
  - data-flow
  - mermaid
  - kcc/v04
created: {YYYY-MM-DD}
updated: {YYYY-MM-DD}
version: 0.1.0
status: draft
copyright: "KCC framework (c) 2026 Tarek Fawaz"
homepage: "https://tikasway.dev/kcc"
license: "Licensed under the terms in LICENSE"
architecture-depth: standard|deep
silent-assumption: false
data-sensitivity: "{public|internal|confidential|restricted|PII|PHI|PCI}"
---

# Data Flow Diagram - {Data Flow Name}

> Copy this file to `architecture/dfds/{flow-slug}.md` and replace every
> placeholder. DFDs use Mermaid `flowchart TD` with shape conventions
> that mirror Yourdon / Gane-Sarson style. One DFD per non-trivial data
> flow.

## Scope

{What data does this flow describe? Where does it start, where does it
end, and which trust boundaries does it cross?}

## Diagram

```mermaid
flowchart TD
    %% Shape conventions:
    %%   [Process]            - a process / transformation
    %%   [(Data store)]       - a persistent store
    %%   [/External/]         - an external entity (parallelogram-ish)
    %%   Arrows are labeled with the DATA they carry, not the trigger.

    ext[/External entity/] -- "{data item 1}" --> p1[Process 1: validate]
    p1 -- "{validated data}" --> p2[Process 2: enrich]
    p2 -- "{enriched record}" --> store[(Primary data store)]
    p2 -- "{event payload}" --> p3[Process 3: notify]
    p3 -- "{notification}" --> ext_recv[/Downstream consumer/]

    subgraph trust_boundary [Trust boundary: internal VPC]
        p1
        p2
        p3
        store
    end
```

## Filling instructions

1. **Shapes.**
   - `[Process]` - a process / transformation. Number them (`p1`, `p2`,
     ...) and use a verb in the label ("validate", "enrich", "notify").
   - `[(Data store)]` - a persistent store. Label with the store's
     business name, not its tech.
   - `[/External entity/]` - an external entity (user, third-party
     system, partner). Mermaid renders these as parallelograms via the
     `[/.../]` shape.
2. **Arrows.** Every arrow carries a label describing the **data**, not
   the trigger. "order request" - yes. "user clicks Buy" - no, that goes
   in the business flowchart.
3. **Trust boundaries.** Draw each trust boundary as a `subgraph` block
   and put the processes / stores it contains inside. Cross-boundary
   edges must be explicitly labeled with what crosses (data item + any
   transformation that happens at the boundary, e.g. encryption,
   redaction).
4. **Data sensitivity.** Set `data-sensitivity` in frontmatter using the
   project's taxonomy. If multiple classes flow through the same DFD,
   list the highest and note exceptions in `## Sensitivity notes`.
5. **Granularity.** One DFD per data flow that matters. If you find
   yourself adding "and also..." processes, split into a second DFD.
6. **Assumptions block** (silent-mode only). When the architect runs
   under `auto --silent --assume`, fill the section below and set the
   frontmatter `silent-assumption: true`.

## Sensitivity notes

- {Data class} - {how it's handled across the trust boundary it crosses}

## Retention / deletion

- {Data store} - {retention window, deletion trigger}

## Assumptions (silent runs only)

- {Assumption ID from `architecture/assumptions.md`} - {one-line summary}

## Related

- Architecture MOC: [[../../architecture/architecture]]
- Container diagram: [[../../architecture/c4-container]]
- Business workflow (if relevant): [[../../architecture/flowcharts/{workflow-slug}]]
- Architecture documentation protocol: [[../protocols/architecture-documentation]]
- Architecture governance protocol: [[../protocols/architecture-governance]]
