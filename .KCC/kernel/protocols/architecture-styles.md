---
# Functional fields
description: Default architecture-style selection rule for the framework - Clean Architecture + DDD for backend/service/API/fullstack, event-driven for IoT/streaming, opt-down to a simpler style only with a recorded ADR.
inputs: The idea brief, TechnicalDecisionBrief, and the work type (backend / service / API / fullstack / IoT / static / trivial tool).
outputs: A selected architecture style stated in the Architecture Document and ADRs, reflected in the C4 containers/components and the spec-local arch.md.

# Obsidian metadata
title: "Architecture Styles Protocol"
aliases:
  - architecture-styles
  - default-architecture-style
  - clean-architecture-default
tags:
  - framework/protocol
  - architecture
  - kcc/v04
created: 2026-06-06
updated: 2026-06-06
version: 1.0.0
status: active
copyright: "KCC framework (c) 2026 Tarek Fawaz"
homepage: "https://tikasway.dev/kcc"
license: "Licensed under the terms in LICENSE"
---

# Architecture Styles

This protocol defines the framework's **default architecture style** and how the
architect selects it. The style is a durable decision recorded in the
Architecture Document and (when it differs from the default) in an ADR.

## Default style selection rule

| Work type | Default style |
|--|--|
| backend / service / API / fullstack | **Clean Architecture + DDD** |
| IoT / sensor / streaming / real-time ingestion | **event-driven** |
| static / frontend-only / trivial tool | may **opt down** to a simpler style, but only with a recorded ADR |

### Backend / service / API / fullstack -> Clean Architecture + DDD

The default for any backend, service, API, or fullstack work is **Clean
Architecture combined with Domain-Driven Design**:

- **Layered with the dependency rule pointing inward.** Layers are `domain`
  (entities, value objects, domain services - no outward dependencies),
  `application` (use cases / orchestration), `infrastructure` (datastores,
  external services, frameworks), and `interface` (HTTP/CLI/queue adapters).
  Source dependencies only ever point toward the domain; the domain depends on
  nothing outward.
- **DDD building blocks.** Bounded contexts, a ubiquitous language shared by code
  and docs, aggregates/entities/value objects, domain events, and repositories
  as domain-owned abstractions implemented in infrastructure.

### IoT / sensor / streaming / real-time ingestion -> event-driven

Telemetry, sensor, streaming, or real-time-ingestion work defaults to an
**event-driven** style: events as first-class messages, brokers/queues,
producers and consumers, and eventual consistency. A Clean/DDD domain core may
still sit inside consumers, but the system's spine is asynchronous events rather
than synchronous request/response.

### Static / frontend-only / trivial tool -> opt-down with ADR

Trivial or static work (a CSV CLI, a static game, a frontend-only page, a tiny
one-off tool) may opt down to a simpler style - a flat module layout, a simple
MVC, or no formal layering. This is the only path that escapes the default, and
it requires the architect to **record the chosen style and its rationale in an
ADR** (status `Accepted`, or `Proposed` under `--silent --assume`). No ADR means
the default Clean+DDD (or event-driven) style stands.

## What each style implies for diagrams and arch.md

- **Clean Architecture + DDD.** The C4 **container** diagram shows the
  application/service and its datastores; the C4 **component** diagram (deep)
  shows the domain / application / infrastructure / interface layering and the
  inward dependency rule. The Architecture Document names the bounded contexts
  and the ubiquitous language. The spec-local `arch.md` shows which layer(s) the
  spec touches and confirms the dependency rule is preserved.
- **Event-driven.** The C4 container diagram shows brokers/topics, producers,
  and consumers; sequence or flow diagrams show event paths and where eventual
  consistency applies. The spec-local `arch.md` shows the events the spec
  produces/consumes and their contracts.
- **Opted-down simpler style.** The Architecture Document and the ADR state the
  simpler style and why it is sufficient (low risk, no domain complexity, no
  multi-context coupling). Diagrams scale down to the active architecture depth.

## How the architect selects

1. **Detect the work type** from the idea brief and `TechnicalDecisionBrief.md`
   (backend/service/API/fullstack vs IoT/streaming vs static/trivial).
2. **Apply the default** per the rule above (Clean+DDD, or event-driven for
   IoT/streaming).
3. **Opt down only with an ADR.** For static/frontend-only/trivial work, the
   architect may choose a simpler style but MUST record the choice and rationale
   in an ADR. The Architecture Document always states the chosen style and why.
4. **State the style.** The selected style is named in
   `architecture/architecture.md` and reflected in the C4 diagrams and every
   impacted spec's `arch.md`.

## Related

- Architecture governance: [[architecture-governance]]
- Architecture documentation: [[architecture-documentation]]
- API standards: [[api-standards]]
