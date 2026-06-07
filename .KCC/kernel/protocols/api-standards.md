---
# Functional fields
description: Default API standard for the framework - OpenAPI 3.x document, served Swagger UI, and spec-as-contract conformance enforced by the verifier.
inputs: Any spec that exposes an HTTP/REST API, plus the selected backend/fullstack dialect and architecture style.
outputs: An OpenAPI 3.x document under the idea workspace, a served Swagger UI, and a verifier conformance check wired into the quality gates.

# Obsidian metadata
title: "API Standards Protocol"
aliases:
  - api-standards
  - openapi-default
  - swagger-default
tags:
  - framework/protocol
  - api
  - standards
  - kcc/v04
created: 2026-06-06
updated: 2026-06-06
version: 1.0.0
status: active
copyright: "KCC framework (c) 2026 Tarek Fawaz"
homepage: "https://tikasway.dev/kcc"
license: "Licensed under the terms in LICENSE"
---

# API Standards

This protocol defines the framework's **default API standard**. It applies to
every spec that exposes an HTTP/REST API, regardless of dialect or architecture
style. The default is non-negotiable unless an explicit ADR waives it (see
[[architecture-governance]]).

## The default (all APIs)

Every spec that exposes an HTTP/REST API MUST by default ship all three of:

1. **An OpenAPI 3.x document** - a machine-readable description of every route,
   verb, request/response schema, status code, and error shape the API exposes.
2. **A served Swagger UI** - an interactive, human-browsable rendering of the
   OpenAPI document, served by the running service (for example at `/docs`).
3. **Spec-as-contract conformance** - the OpenAPI document IS the API contract.
   The implemented routes, verbs, parameters, and schemas must conform to it,
   and the verifier checks that conformance (see below).

This is a **default**, not a suggestion. It can only be waived with an explicit
ADR recording the rationale (for example a non-HTTP interface such as a CLI,
gRPC-only service, message-queue worker, or library with no HTTP surface). The
ADR must name the alternative contract mechanism (e.g. a `.proto` file, an
AsyncAPI document, or a typed library API) so there is still a single source of
truth for the interface.

## Where the OpenAPI document lives

The OpenAPI document is the **source of truth** for the API contract and is
checked into the idea workspace alongside the code it describes:

```text
src/IDEA-{ID}-{slug}/<service>/openapi.yaml   <- single source of truth
```

- `openapi.yaml` (or `openapi.json`) lives under the service it describes inside
  `src/IDEA-{ID}-{slug}/`. When a stack has its own idiomatic location (e.g.
  generated from code annotations, or under a `contracts/`/`api/` subfolder),
  the dialect's idiomatic path may be used instead, but the file must be
  discoverable, checked in, and named so the verifier can find it.
- The document is hand-authored (design-first) or generated from code-first
  annotations - either is allowed, provided the **served** document matches the
  checked-in one and both match the implementation.

## How Swagger UI is served

- The running service serves an interactive Swagger UI (or an equivalent
  OpenAPI viewer) at a documented route, `/docs` by default.
- The served UI must render the same OpenAPI document that is checked in. The
  raw document should also be reachable (for example `/openapi.json`) so tooling
  and the verifier can fetch it.
- For local-only or air-gapped builds, a static Swagger UI bundle served from
  the service is acceptable; an externally-hosted-only UI is not, because the
  contract must travel with the service.

## Verifier conformance check

When a spec exposes an API, the verifier runs an **API conformance check** as a
default quality gate. Conformance means:

1. **OpenAPI document present** - a checked-in OpenAPI 3.x document exists at the
   expected location and is valid OpenAPI 3.x.
2. **Swagger UI served** - the service exposes a Swagger UI (default `/docs`)
   and the raw document, both rendering the checked-in spec.
3. **Routes conform to the spec** - every implemented route + verb is described
   in the OpenAPI document, and every route + verb in the document is
   implemented. Request/response schemas, required parameters, and status codes
   must match the spec.

Any mismatch - an undocumented route, a documented-but-unimplemented route, a
verb/parameter/schema/status-code divergence, a missing Swagger UI, or an
invalid/absent OpenAPI document - is **CHANGES_NEEDED**. The verifier cites the
offending route/verb and the spec line it diverges from.

The architect wires this gate into `architecture/quality-gates.md` (for example
`QG-API-CONFORMANCE`) whenever the solution exposes an API, so planner and
verifier both see it.

## Versioning and acceptance criteria

- **API versioning.** The OpenAPI document carries an `info.version`. Breaking
  contract changes (removed/renamed routes, narrowed types, new required fields)
  require a version bump and, where the API is already consumed, a versioned
  route prefix (e.g. `/v1`, `/v2`) or an explicit deprecation window recorded in
  an ADR.
- **Interaction with spec acceptance criteria.** A spec that exposes an API must
  include acceptance criteria that reference the contract: at minimum (a) the
  OpenAPI document exists and is valid, (b) Swagger UI is served, and (c)
  implemented routes conform to the document. The spec-writer adds these ACs and
  the verifier checks them as part of the API conformance gate. When the spec
  changes the contract, an AC must state the new/changed routes and the version
  bump.

## Related

- Architecture governance: [[architecture-governance]]
- Architecture styles: [[architecture-styles]]
- Spec layout: [[spec-layout]]
- Dialect registry: [[dialects/dialect-registry]]
