---
# Functional fields (consumed by harness adapters)
name: autobuild
description: >
 Run the approved autobuild discovery workflow when the user starts a request with `autobuild <idea>` or `autobuild <run-id>`: risk classify, H1 scope confirmation, journey/flow mapping, clickable prototype + H2 walkthrough, research/architecture, Trace Matrix + Decision Log, dependency/readiness evidence, red team review, Build Contract + runtime validation, then LOCK and controller handoff. H1 Scope, H2 Prototype and final LOCK are the only formal pre-build gates; no post-lock approvals. Usage: `/autobuild <idea|run-id>`
argument-placeholder: <ARGS>
delegates-to:
  - idea-interrogator
  - technical-interrogator
  - ux-ui-designer
  - security-analyst
  - architect
  - spec-writer
  - planner
  - readiness-auditor
  - implementer
  - verifier
maturity: L1
maintainer: tarek.fawaz1983@gmail.com
copyright: "KCC framework (c) 2026 Tarek Fawaz"
homepage: "https://tikasway.dev/kcc"
license: "Licensed under the terms in LICENSE"

# Obsidian metadata (used in the vault, ignored by harness adapters)
title: Autobuild Skill
aliases:
  - autobuild-skill
tags:
  - framework/skill
  - autobuild
  - lifecycle/autobuild
created: 2026-08-27
updated: 2026-08-27
version: 1.0.0
status: active
---

# Autobuild

Autobuild is the Plan-02 discovery-and-lock workflow: it deepens
discovery before implementation (Think to completion before building to
completion) and then hands the locked contract to the autonomous
controller.  It is a **separate capability** from the existing `auto`
skill: `auto` stays the Human-On-The-Loop spec lifecycle, `autobuild`
is the contract-locked autonomous build workflow.

## Flow (approved autobuild sequence)

```text
risk classify
  -> H1 scope confirm
  -> journey/flow map
  -> clickable prototype
  -> H2 walkthrough
  -> research + architecture
  -> Trace Matrix + Decision Log
  -> dependency + readiness evidence
  -> red team review
  -> Build Contract + runtime validation
  -> LOCK & BUILD
  -> controller handoff
```

## Formal gates (Plan-02 ruling R10)

- **H1 — Scope confirmation** (first gate): user confirms scope, major
  goals, success measures and explicit non-goals.
- **H2 — Prototype walkthrough** (second gate): user validates the
  clickable prototype behavior and flow.
- **LOCK & BUILD** (final gate): the user approves the consolidated
  readiness/contract surface.

These three are the only formal pre-build gates.  No additional approval
gate is introduced before or after LOCK.  **No post-lock approvals**:
after LOCK the controller proceeds autonomously and routine
implementation questions are prohibited; progress is delivered as
telemetry/notifications instead (Design Spec v1.2 sections 4.5, 16.1).

## Steps

1. **Risk classify (P0)** — determine project class, risk dimensions
   and discovery depth (fast lane vs deep dive, spec sections 6.2-6.3).
   Initialize the run: `kcc-autobuild init-run RUN-001 "<title>"`.
2. **H1 — scope confirm** — MUST/SHOULD/COULD/WON'T triage (section 9.2);
   record the confirmation before proceeding.
3. **Journeys and flows** — model happy path plus first-time, returning,
   empty, loading, permission-failure, session-expiry, validation-error,
   provider-failure, retry/recovery, offline and cancellation paths
   (sections 9.3-9.4); error branches must be represented.
4. **Prototype** — define UX direction and the screen/state inventory
   (section 9.5); produce the clickable prototype for the primary journey
   (section 9.6); declare interactivity (never assumed) and never mark
   it production implementation.  Fill
   `.KCC/kernel/templates/prototype-manifest.yaml` and validate:
   `kcc-autobuild validate-model prototype prototype-manifest.yaml`.
5. **H2 — walkthrough** — the user validates the prototype; the prototype
   evaluation is walkthrough evidence, not an extra gate.
6. **Research + architecture** — research best-fit options (section 9.7)
   and define the engineering architecture (section 9.8); record every
   material choice with recommended/alternatives/rejected, rationale and
   cost/risk in `.KCC/kernel/templates/decision-log.yaml` and validate:
   `kcc-autobuild validate-model decision-log decision-log.yaml`.
7. **Trace Matrix + Decision Log** — build the requirement-to-production
   spine (section 10.1) in `.KCC/kernel/templates/trace-graph.yaml`;
   an orphan requirement (no acceptance + production validation reach)
   blocks LOCK (section 10.3); validate:
   `kcc-autobuild validate-model trace trace-graph.yaml`.
8. **Dependency + readiness evidence** — classify every dependency and
   validate credentials, permissions, quotas and deployment paths with
   timezone-aware evidence (sections 12.1-12.4); approve fallbacks with
   secret references only (section 24).  Fill
   `.KCC/kernel/templates/readiness-pack.yaml` and validate:
   `kcc-autobuild validate-model readiness readiness-pack.yaml`.
9. **Red team review** — delegate to the `readiness-auditor` agent
   (section 12.6) to re-execute a sample of readiness claims and record
   typed findings/dispositions in `red_team_findings`; OPEN findings
   block LOCK.
10. **Build Contract + runtime validation** — assemble the two-tier
    contract (`.KCC/kernel/templates/build-contract.yaml`, contract
    document in `.KCC/kernel/contracts/autobuild-contract.md`), validate
    with `kcc-autobuild validate-model contract build-contract.yaml`,
    then run the runtime gate checks (trace coverage, readiness
    evaluation, authority/money/destructive safeguards, R6 fallback
    backing) via `kcc_autobuild.contract.lock_contract`.
11. **LOCK & BUILD** — the user grants the single final authorization;
    `lock_contract` records UTC lock time plus Tier-1 canonical hash and
    Tier-2 digest (ruling R7).
12. **Controller handoff** — transition the run to the autonomous
    controller; the execution plane follows the locked contract, and
    only contract-external exceptions (E1-E8, section 18) may interrupt
    the user.

## Controller and gates

The runtime (`kcc-autobuild` CLI) persists `coordination/autobuild/<RUN-ID>/`.
Kernel protocols: `autobuild-discovery.md`, `autobuild-readiness.md`.
After LOCK, progress is notified, not approved (section 25).
