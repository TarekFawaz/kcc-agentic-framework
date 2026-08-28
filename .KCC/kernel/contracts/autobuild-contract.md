---
title: Autobuild Build Contract
aliases:
  - autobuild-contract
  - build-contract
tags:
  - kcc/kernel
  - contract
  - autobuild
created: 2026-08-27
updated: 2026-08-27
version: 1.0.0
status: active
copyright: "KCC framework (c) 2026 Tarek Fawaz"
homepage: "https://tikasway.dev/kcc"
license: "Licensed under the terms in LICENSE"
---

# Autobuild Build Contract

The Build Contract defines what the autonomous system is allowed and
required to do after LOCK (Design Spec v1.2 section 14).  It is
machine-readable and human-readable, and it is the sole formal interface
between the KCC control plane and the Superpowers execution plane
(section 28.3).  The machine schema is `kcc_autobuild.contract`; the
editable scaffold is `.KCC/kernel/templates/build-contract.yaml`
(`kcc-autobuild validate-model contract build-contract.yaml`).

## Two tiers

### Tier 1 — Locked invariants (section 14.1)

Product scope and explicit non-goals, primary user journeys, approved
UX direction / prototype reference, provider whitelist, auth model, core
data entities where contractually material, security/privacy/compliance
constraints, hard budget/spend caps, production domain/target,
destructive-action policy, approved external accounts, deployment
authority and Definition of Done.  A Tier-1 change requires contract
revision and re-lock.

### Tier 2 — Autonomous engineering detail (section 14.2)

Component boundaries, internal API shapes, helper libraries, DB indexes,
error wording, internal refactors, test organization, minor dependency
changes, CSS/layout detail within the approved UX direction,
observability thresholds within policy and internal staging detail.  The
execution system may change these without asking the user when the
change stays within Tier-1 invariants; material autonomous deviations
are recorded in the deviation log.

## Lock gates

Only **H1 — Scope**, **H2 — Prototype** and the final **LOCK & BUILD**
are formal pre-build gates (ruling R10).  `kcc_autobuild.contract.lock_contract`
is the only path to a locked contract and refuses (with the full reason
set) when:

- the contract is already locked;
- the trace graph has orphan requirements (section 10.3);
- readiness is not evidence-backed / not ready (no coverage, blockers,
  open red-team findings — rulings R2/R3);
- `AUTO_PROVISION_AUTHORIZED` auto-provision is not bounded by the
  approved provider whitelist and approved accounts (ruling R4,
  section 14.3);
- a paid whitelist provider has no positive spend cap (section 14.4);
- production deployment authority names no production target;
- a rollback-required operation has no rollback path, or a whitelisted
  irreversible operation has no verified backup safeguard
  (section 14.5);
- a Tier-1 fallback-whitelist provider has no matching validated
  readiness fallback entry — approved fallbacks cannot exist only on
  paper (ruling R6).

## Authority envelope (section 14.3)

Auto-provisioning within approved accounts/providers, dependency
installation, environment creation, CI/CD configuration, database
migration within the destructive policy, DNS changes within approved
zones and policy, staging/production deployment, rollback,
monitoring/alert setup, secret-reference usage and bounded spend each
default to not authorized (fail-closed).  Credential references only:
`vault://`, `env://`, `keychain://`; raw secrets are rejected
(section 24).

## Money policy (section 14.4)

One-time build budget, per-provider spend cap, monthly infrastructure
cap and model/token cap, all in integer minor units; limits are hard by
default and hard-cap breaches halt autonomous progression.

## Destructive-action policy (section 14.5)

`REVERSIBLE_AUTONOMOUS`, `REVERSIBLE_WITH_ROLLBACK_REQUIRED`,
`IRREVERSIBLE_WHITELISTED` and `IRREVERSIBLE_NOT_AUTHORIZED`.
Production-destructive operations require the contract-defined
safeguards (verified backup/snapshot and rollback path where
meaningful).

## Resume protocol (section 14.6)

Lifecycle state, current task/wave, completed task commits, test
results, review state, outstanding findings, attempt counters, spend so
far, deviations and contract version are the durable resume source of
truth.  A resumed session continues from durable state, never from
conversational memory.

## Hashing and lock time

- `locked_at` is timezone-aware and normalized to UTC (ruling R7).
- The canonical Tier-1 hash (`contract_hash`) covers Tier-1 JSON only:
  Tier-2 detail, trace/readiness evidence and lock metadata never change
  it; any Tier-1 change does.
- `tier2_hash` digests the autonomous engineering detail; it is stable
  for identical Tier-2 content and changes with any Tier-2 change.

## Generated surfaces

Kernel changes are the source of truth.  Regenerate harness outputs with
`.KCC/tools/sync-adapters.sh` (or the PowerShell equivalent on Windows)
after editing; generated adapter surfaces are local output.
