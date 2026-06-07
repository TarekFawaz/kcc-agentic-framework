---
title: "Business Workflow - {Workflow Name}"
aliases:
  - flowchart-business
tags:
  - architecture
  - flowchart
  - business-workflow
  - mermaid
  - kcc/v04
created: {YYYY-MM-DD}
updated: {YYYY-MM-DD}
version: 0.1.0
status: draft
copyright: "KCC framework (c) 2026 Tarek Fawaz"
homepage: "https://tikasway.dev/kcc"
license: "Licensed under the terms in LICENSE"
architecture-depth: lite|standard|deep
silent-assumption: false
workflow-owner: "{role or team}"
---

# Business Workflow - {Workflow Name}

> Copy this file to `architecture/flowcharts/{workflow-slug}.md` and
> replace every placeholder. Mermaid `flowchart` substitutes for BPMN in
> this framework - keep the diagram small enough to render in one screen
> in Obsidian.

## Trigger

{What kicks the workflow off - a user action, a schedule, an inbound event}

## Outcome

{What "done" looks like for this workflow, in one sentence}

## Diagram

```mermaid
flowchart TD
    Start([{Trigger event}]) --> Step1[{First task}]
    Step1 --> Check1{{First decision}}
    Check1 -- yes --> Step2[{Happy-path task}]
    Check1 -- no --> Recover[{Recovery / alternative task}]
    Recover --> Step1
    Step2 --> Step3[{Next task}]
    Step3 --> Check2{{Second decision}}
    Check2 -- yes --> Done([{Success outcome}])
    Check2 -- no --> Fail([{Failure outcome}])
```

## Filling instructions

1. **Shapes.**
   - `([rounded])` - start and end events.
   - `[rectangle]` - tasks / activities.
   - `{{double-brace}}` or `{diamond}` - decisions / gateways.
   - `[[subroutine]]` - invocations of another named workflow (link it).
   - `[(cylinder)]` - data store interactions (rare in business workflows;
     prefer the DFD template for data flows).
2. **Edges.** Label decision edges with the answer (`yes` / `no` / a
   short outcome). Label non-decision edges only when the trigger /
   data / state matters.
3. **Direction.** `TD` (top-down) for sequential workflows; `LR`
   (left-right) for assembly-line / pipeline flows.
4. **Subworkflows.** If a step contains its own meaningful flow, use
   `[[Subworkflow name]]` and create a separate flowchart file.
5. **Granularity.** Aim for 5-15 nodes. If the diagram grows past that,
   split it.
6. **Assumptions block** (silent-mode only). When the architect runs
   under `auto --silent --assume`, fill the section below and set the
   frontmatter `silent-assumption: true`.

## Actors

| Actor | Role in this workflow |
|--|--|
| {Persona / system} | {What they do} |

## Failure modes

- {Failure} -> {what happens / who is notified}

## Assumptions (silent runs only)

- {Assumption ID from `architecture/assumptions.md`} - {one-line summary}

## Related

- Architecture MOC: [[../../architecture/architecture]]
- Container diagram: [[../../architecture/c4-container]]
- DFD (if data flow is non-trivial): [[../../architecture/dfds/{flow-slug}]]
- Architecture documentation protocol: [[../protocols/architecture-documentation]]
