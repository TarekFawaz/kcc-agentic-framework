---
# Functional fields
description: Plan-02 autobuild readiness protocol - P2 de-risk and prove readiness: dependency inventory, credential/permission validation with timezone-aware evidence, infrastructure smoke deployment, test strategy, pre-build execution simulation, independent red-team readiness review, living failure catalog, and the consolidated Readiness Evidence Pack with BLOCKER / RISK / ACCEPTED / READY taxonomy.
inputs: The verified Trace Matrix and Decision Log, the dependency inventory per provider, the red-team readiness review results, and the Readiness Evidence Pack under construction.
outputs: A validated Readiness Evidence Pack YAML (items + red_team_findings), readiness evaluation (0 blockers, evidence coverage, no open red-team findings) and the readiness input to the Build Contract lock gates.

# Obsidian metadata
title: "Autobuild Readiness Protocol"
aliases:
  - autobuild-readiness
  - autobuild-p2
tags:
  - framework/protocol
  - autobuild
  - lifecycle/readiness
created: 2026-08-27
updated: 2026-08-27
version: 1.0.0
status: active
copyright: "KCC framework (c) 2026 Tarek Fawaz"
homepage: "https://tikasway.dev/kcc"
license: "Licensed under the terms in LICENSE"
---

# Autobuild Readiness

The readiness phase prevents the system from entering the autonomous
build with hidden dependency gaps (Design Spec v1.2 section 12).
Readiness is evidence-backed: `READY` is never based on an agent's
statement (section 4.2).  The orchestration skill is `/autobuild`; this
protocol defines the normative sequence and evidence rules.

## Formal gates

No gate is introduced here.  Only **H1 — Scope confirmation**, **H2 —
Prototype walkthrough** and final **LOCK & BUILD** are formal pre-build
gates (Plan-02 ruling R10).  Readiness evidence feeds the LOCK decision;
it does not add an approval step.

## Sequence

```text
dependency inventory -> credential/permission validation -> smoke deployment
                      -> test strategy -> execution simulation
                      -> red-team readiness review -> evidence pack -> LOCK
```

### Dependency inventory (section 12.1)

Every dependency is classified as one of `USER_MUST_PROVIDE`,
`ALREADY_EXISTS`, `AUTO_PROVISION_AUTHORIZED` or `NOT_REQUIRED`.  The
canonical spellings live in `kcc_autobuild.models.DependencyStatus`
(`AUTO_PROVISION_AUTHORIZED` is the approved canonical enum — never
renamed; ruling R4).  Human-identity-bound providers (cloud account,
payment/merchant, app-store, registrar, OAuth provider setup, KYC,
billing activation) are `USER_MUST_PROVIDE`; the framework may validate
them once provided but must not assume it can create them autonomously.

### Credential and permission validation (section 12.2)

- Validate before LOCK: authentication success, account identity,
  required scopes, target resource access, quota/limits, billing mode,
  sandbox/test mode, API availability and rotation metadata.
- Evidence timestamps are **timezone-aware and normalized to UTC**
  (rulings R3/R7); naive timestamps are rejected.
- Secrets are never written into artifacts — only secret references
  (`vault://`, `env://`, `keychain://`; section 24).

### Infrastructure smoke deployment (section 12.3)

Where the deployment target is known, perform the smallest safe proof
(disposable hello-world deployment, CI/CD authentication check, target
health check, TLS/routing proof, staging resource access).  No
irreversible production provisioning happens pre-lock unless explicitly
required and separately authorized.

### Test strategy (section 12.4)

Derive unit/integration/E2E/security/performance/accessibility plans,
fixtures, test identities, sandbox-vs-live usage, browser/device matrix,
staging validation and production smoke tests from requirements and
journeys.  Every acceptance criterion maps to one or more Test IDs.

### Pre-build execution simulation (section 12.5)

For each feature answer internally: how is it implemented, what does it
depend on, how is it tested, what identity/account is required, what
environment, what deployment permission, how is failure observed, how
does recovery work.  The simulation writes no production code.

### Red-team readiness review (section 12.6)

An independent reviewer
(`.KCC/capabilities/agents/readiness-auditor.md`) attempts to find every
predictable reason the post-lock build would need to ask the user for
help.  The red team must **re-execute a sample of the claims** — provider
token revalidation, quota re-read, OAuth callback verification,
deployment permission verification, sandbox webhook path verification,
test-identity verification, smoke-deployment confirmation — not re-read
them.  Findings are recorded with typed dispositions in
`red_team_findings`; OPEN findings block LOCK.

### Living failure catalog (section 12.7)

Check the project against reusable failure classes before LOCK:
OAuth redirect URI missing, email sender not verified, webhook
inaccessible, sandbox/live credentials confused, API quota insufficient,
DNS permission missing, provider billing inactive, test account
unavailable, deployment identity expired, staging not representative.

## Readiness Evidence Pack (section 13)

Fill `.KCC/kernel/templates/readiness-pack.yaml` (items + typed
`red_team_findings` and dispositions — ruling R2) and validate it:

```text
kcc-autobuild validate-model readiness readiness-pack.yaml
```

Taxonomy (section 13.1):

- **BLOCKER** — must be resolved before LOCK;
- **RISK / MITIGATED** — known risk with an accepted mitigation;
- **ACCEPTED RISK** — intentionally accepted within the contract;
- **READY** — evidence-supported readiness.

`BLOCKERS = 0` is necessary but not sufficient: evidence coverage is
required.  A READY claim holds only with current pass evidence for every
required probe kind — stale, fresh-fail or fresh-unknown evidence never
satisfies READY (ruling R3).  The runtime evaluation is
`kcc_autobuild.readiness.evaluate_readiness`; the contract layer refuses
to lock a pack with blockers, no coverage or open red-team findings
(`kcc_autobuild.contract.lock_contract`).

## Handoff

The validated pack becomes the `readiness` section of the Build
Contract; see `.KCC/kernel/contracts/autobuild-contract.md` and the
`.KCC/kernel/templates/build-contract.yaml` template.
