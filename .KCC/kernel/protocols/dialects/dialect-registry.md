---
title: Development Dialect Registry
aliases:
  - dialect-registry
tags:
  - kcc/kernel
  - dialects
created: 2026-05-25
updated: 2026-06-06
version: 0.5.0
status: active
copyright: "KCC framework (c) 2026 Tarek Fawaz"
homepage: "https://tikasway.dev/kcc"
license: "Licensed under the terms in LICENSE"
---

# Development Dialect Registry

Dialects are shared protocols for coding, review, bug fixing, testing, docs,
and project structure. They are not separate implementer agents. The single
implementer, planner, verifier, reviewer, Butler, and Token Guard all use the
same selected dialect.

## Selection

Technical Interrogator proposes candidate dialects. Architect confirms them in
ADRs, guardrails, diagrams, or the technical brief. Spec Writer assigns one or
more dialects to each story/enabler. Planner groups work by dialect and
dependency wave. Implementer and Verifier load the same dialect for execution
and review.

## Framework defaults

Independent of dialect, two framework defaults apply:

- **API work follows [[api-standards]]** - any spec exposing an HTTP/REST API
  ships an OpenAPI 3.x document + served Swagger UI (default `/docs`) +
  verifier-checked route conformance. Waivable only with an ADR.
- **Architecture style follows [[architecture-styles]]** - Clean Architecture +
  DDD is the default for backend/service/API/fullstack, event-driven for
  IoT/streaming; static/frontend-only/trivial work may opt down only with an ADR.

## Complexity Variation

| Complexity | Variation | Model implication |
|--|--|--|
| low | junior-safe | Prefer fast/balanced model when risk is low. |
| medium | mid-level | Balanced default. |
| high | senior | Stronger planning/review; balanced or strong implementation. |
| extra-high | principal-expert | Strong reasoning, extra review, explicit architecture gates. |

## Dialects

| Dialect | File |
|--|--|
| Backend C# | [[backend-csharp]] |
| Backend Go | [[backend-go]] |
| Backend Python | [[backend-python]] |
| Backend Rust | [[backend-rust]] |
| Backend PHP | [[backend-php]] |
| Backend Java | [[backend-java]] |
| Backend C++ | [[backend-cpp]] |
| Backend NodeJS | [[backend-nodejs]] |
| Full-stack .NET | [[fullstack-dotnet]] |
| Full-stack MERN | [[fullstack-mern]] |
| Full-stack NestJS | [[fullstack-nestjs]] |
| Full-stack Python | [[fullstack-python]] |
| Full-stack Go | [[fullstack-go]] |
| Embedded C | [[embedded-c]] |
| Embedded C++ | [[embedded-cpp]] |
| Embedded Rust | [[embedded-rust]] |
| Frontend Angular | [[frontend-angular]] |
| Frontend React | [[frontend-react]] |
| Frontend Vanilla JS | [[frontend-vanilla-js]] |
| Frontend general | [[frontend-general]] |
| DevOps cloud | [[devops-cloud]] |
| DevOps K8s on-prem/agnostic | [[devops-k8s-onprem-agnostic]] |

## Required Dialect Sections

Each dialect file must define:

- coding rules;
- review checklist;
- bug-fix workflow;
- testing expectations;
- documentation expectations;
- greenfield project structure;
- complexity variation notes;
- when to escalate to architect or human.
