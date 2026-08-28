---
# Functional fields
description: Plan-02 autobuild discovery protocol - P0 intake/classify, P1 scope triage with the H1 scope confirmation gate, user journey/flow mapping, UX state inventory, clickable prototype with the H2 prototype walkthrough gate, solution research and engineering architecture, ending with the Trace Matrix and Decision Log handoff.
inputs: A rough user idea plus the autobuild run id (RUN-{ID}); an initialized run via `kcc-autobuild init-run`.
outputs: Confirmed scope (H1), journey/flow graph, UX screen/state inventory, clickable prototype (H2), Trace Matrix YAML, Decision Log YAML, and engineering architecture summary.

# Obsidian metadata
title: "Autobuild Discovery Protocol"
aliases:
  - autobuild-discovery
  - autobuild-p1
tags:
  - framework/protocol
  - autobuild
  - lifecycle/discovery
created: 2026-08-27
updated: 2026-08-27
version: 1.0.0
status: active
copyright: "KCC framework (c) 2026 Tarek Fawaz"
homepage: "https://tikasway.dev/kcc"
license: "Licensed under the terms in LICENSE"
---

# Autobuild Discovery

The autobuild discovery phase front-loads uncertainty (Design Spec v1.2
section 4.1).  It converts a rough idea into a validated product design
and hands the Trace Matrix plus Decision Log to the readiness phase.
The orchestration skill is `/autobuild` (`.KCC/capabilities/skills/autobuild.md`);
this protocol defines the normative sequence and gates.

## Formal gates

Only **H1 — Scope confirmation**, **H2 — Prototype walkthrough** and the
final **LOCK & BUILD** are formal pre-build gates (Plan-02 ruling R10).
Discovery introduces no additional approval gate.

## Sequence

```text
classify risk -> H1 scope -> journeys/flows -> prototype -> H2 walkthrough
               -> research/architecture -> Trace Matrix + Decision Log
```

### P0 — Intake & classify

- Identify project class (web, mobile, API, internal tool, extension,
  CLI, data pipeline, integration-heavy) and risk dimensions
  (money, identity, sensitive data, production mutation, providers,
  irreversibility, public exposure, compliance, deployment complexity —
  section 6.2).
- Record discovery depth: fast lane for low-risk internal/local work;
  full journey/prototype ceremony for UI products (section 6.3).
- Initialize the run: `kcc-autobuild init-run RUN-001 "title"`.
- P0 is adaptive and is not itself a formal user gate (section 8.2).

### H1 — Scope confirmation (first formal gate)

Scope is classified MUST / SHOULD / COULD / WON'T (section 9.2).  The
user confirms product scope, major goals, success measures and explicit
non-goals.  Progress without confirmation is prohibited.

### Journeys and flow graph (sections 9.3-9.4)

- Model primary happy-path, first-time, returning, empty, loading,
  permission-failure, session-expiry, validation-error, provider-failure,
  retry/recovery, offline and cancellation/rollback paths.
- Produce a visual flow graph; error and recovery branches must be
  represented, not only the happy path.

### UX direction and clickable prototype (sections 9.5-9.6)

- Define information architecture, navigation model, screen/state
  inventory, design system recommendation, responsive behavior,
  accessibility baseline, forms/validation, loading/empty/error/success
  states, feedback/confirmations, visual hierarchy and brand/tone.
- Where practical, produce the interactive prototype representing the
  primary journey and important states; it is a pre-lock artifact, never
  production implementation (section 9.6).
- Fill `.KCC/kernel/templates/prototype-manifest.yaml` and validate it:
  `kcc-autobuild validate-model prototype prototype-manifest.yaml`.

### H2 — Prototype walkthrough (second formal gate)

The user validates that the product behaves and flows the way they
expect (section 9.6).  The prototype evaluation
(`kcc_autobuild.prototype.evaluate_prototype`) reports walkthrough
evidence quality; it is evidence for H2 and introduces no gate of its
own (R10).

### Solution research and engineering architecture (sections 9.7-9.8)

- Research and recommend implementation options instead of asking the
  user to choose blindly; record recommended / alternatives / rejected,
  reasoning, implementation fit, testing and sandbox quality, maturity,
  regional limits, expected cost, operational burden and lock-in.
- Record each material choice in `.KCC/kernel/templates/decision-log.yaml`
  and validate it: `kcc-autobuild validate-model decision-log decision-log.yaml`.
- Define system context, components, data model, integration boundaries,
  authn/authz model, external dependencies, infrastructure topology,
  staging/production environments, observability, backup/recovery,
  security/privacy requirements and deployment strategy (section 9.8).
  Define details only to the depth that makes the system buildable and
  testable without over-constraining autonomous implementation.

### Trace Matrix + Decision Log handoff

- Build the Trace Matrix (`.KCC/kernel/templates/trace-graph.yaml`) from
  requirement through journey, screen/action, component, service/API,
  data entity, external dependency, implementation unit, acceptance
  criteria, test ids, infrastructure, observability, staging validation
  and production validation (section 10.1).
- Every in-scope requirement must reach an acceptance criterion and a
  production validation or it is an orphan requirement that blocks LOCK
  (section 10.3); validate the graph with
  `kcc-autobuild validate-model trace trace-graph.yaml`.
- Continue to the readiness protocol
  (`.KCC/kernel/protocols/autobuild-readiness.md`).  The Trace Matrix and
  Decision Log are continuously updated, not end-stage reports
  (section 10, 11).
