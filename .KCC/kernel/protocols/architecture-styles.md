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
updated: 2026-10-15
version: 1.1.0
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

## Style catalogue

The defaults above are where the architect starts, not the only options. Every style below is a
known, documented pattern; an ADR that adopts one names it, cites why it fits (scale, team, change
rate, consistency needs), and lists the consequences. An ADR that picks one of these for the reason
given in "Use when" is **standard-backed** (see [[architecture-governance]] -> *ADR status under
--silent --assume and fasttrack*).

| Style | Use when | Avoid when | What it implies in KCC |
|--|--|--|--|
| Layered (n-tier) | CRUD-heavy apps with thin rules | rich domain rules that leak across layers | one container; layers as folders; simplest plan |
| Clean / Hexagonal / Onion (ports and adapters) | domain logic must outlive frameworks; many adapters (HTTP, CLI, queue) | trivial tools | domain/application/infrastructure/interface folders; adapters are file-disjoint lanes |
| DDD (tactical + strategic) | several sub-domains with their own language | one small model | bounded contexts map to modules and, often, to specs |
| Modular monolith | one deployable with clear module boundaries; small team; transactional consistency | independent scaling or release per module is required | modules own disjoint paths and migration ranges, so specs per module run in parallel lanes |
| Microservices | independent deploy/scale/ownership per service; mature ops | early product, one team, shared database | one container per service; contract tests; QG-PROD per service |
| Event-driven (pub/sub) | async workflows, integration, IoT/streaming | strong read-your-write consistency everywhere | brokers in C4; event contracts versioned like APIs |
| CQRS | read and write models diverge sharply in shape or load | simple CRUD | separate read/write paths; projections need rebuild tests |
| Event sourcing | full audit history or temporal queries are a requirement | ordinary state storage | event store + snapshots; schema evolution plan in an ADR |
| Serverless / FaaS | spiky, stateless workloads; pay-per-use | long-running, latency-critical, or stateful work | function per handler; cold-start budget in technical-budgets.md |
| Pipes and filters / batch ETL | data transformation pipelines | interactive request/response | each filter testable alone; idempotent re-runs |
| Microkernel / plugin | a core with third-party or optional extensions | no extension points needed | plugin contract ADR; plugins as separate specs |
| MVC / MVVM (UI) | conventional UI with view state | n/a | component tests per view; state store named in an ADR |
| SPA, SSR, SSG (web delivery) | SPA for app-like UIs; SSR for SEO/first paint; SSG for content | SPA for SEO-critical content | rendering mode named in the frontend ADR |
| Micro-frontends | several teams own parts of one UI | one team, one app | shell + remotes; shared design system |
| Backend for Frontend (BFF) | clients need different API shapes or auth handling | one client | one BFF per client type, its own contract |
| CLI / library | developer tools, packages | n/a | public API surface and SemVer in an ADR |

Selection rule of thumb: start with the simplest style that meets the non-functional requirements
in `architecture/nfrs.md`; move to a distributed style (microservices, event-driven, serverless)
only when an NFR or an organisational constraint demands it, and record that NFR in the ADR.

## Related

- Standards catalogue: [[standards-catalog]]
- Architecture governance: [[architecture-governance]]
- Architecture documentation: [[architecture-documentation]]
- API standards: [[api-standards]]
