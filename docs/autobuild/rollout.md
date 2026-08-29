---
title: Autobuild Autonomy Metrics and Rollout Gates
aliases:
  - autobuild-rollout
  - rollout-gates
  - autonomy-metrics
tags:
  - framework/documentation
  - autobuild
  - rollout
  - evaluation
created: 2026-08-29
updated: 2026-08-29
version: 1.0.0
status: active
copyright: "KCC framework (c) 2026 Tarek Fawaz"
homepage: "https://tikasway.dev/kcc"
license: "Licensed under the terms in LICENSE"
---

# Autobuild autonomy metrics and rollout gates

The autobuild control plane is rolled out in three **cumulative,
evidence-gated stages**. A stage is never granted by prose: the runtime
derives the autonomy metrics from the deterministic 30-scenario
evaluation ([`EvaluationMetrics`](../../.KCC/runtime/src/kcc_autobuild/evaluation/metrics.py))
and the gate ([`eligible_for`](../../.KCC/runtime/src/kcc_autobuild/evaluation/metrics.py))
answers one question only: **is the recorded evidence eligible for the
stage?** It never grants authority by itself.

## The gates

| Stage | Requirements (all must hold) |
|---|---|
| **R1** | 30/30 — exactly the 30 approved evaluation scenarios settle in their expected lifecycle states; zero stale-worker promotions; zero budget-cap breaches; zero policy violations. |
| **R2** | R1, plus `staging_smoke_classes >= 3` covering the three named project classes: **web app, API-only, browser extension**. |
| **R3** | R2, plus `canary_projects >= 5`; `unplanned_post_lock_prompts = 0`; `rollback_drills >= 5`; `resume_drills >= 5`; native harnesses include **`codex`** and **`dsh`**; `harness_parity_runs_passed >= 3`; `dsh_live_smoke_passed = true` — and the latest DSH smoke has **zero human prompts and zero secret findings**. |

Stages are canonical lowercase values (`r1`/`r2`/`r3`); an unknown stage
is refused by the gate, never guessed. Every requirement is reported
with a met/unmet verdict in the returned
[`RolloutEligibility`](../../.KCC/runtime/src/kcc_autobuild/evaluation/metrics.py)
record, so no gap is silent and the evidence can be audited.

## Where the evidence comes from

- **Scenario-suite metrics are derived, never declared.** 
  [`EvaluationMetrics.collect`](../../.KCC/runtime/src/kcc_autobuild/evaluation/metrics.py)
  consumes the `ScenarioResult` trace of every real evaluation run:
  - `30/30` comes from the catalog's expected lifecycle states;
  - stale-worker promotions are *accepted* stale results — the durable
    event trace shows a terminal task event on a superseded lease
    generation; scenario 19 proves the stale promotion is rejected
    before advancement and scenarios 4/13/23/25/26 prove interrupted
    sessions re-execute on fresh lease generations;
  - budget-cap breaches are settled provider actuals above the run's
    hard cap **without** the E3 halt — scenario 9 proves the books
    settle first and the run halts `BLOCKED` (breach prevented, not
    detected-and-ignored);
  - policy violations are operations outside the signed
    destructive-action bundle that actually executed — the policy gate
    audits before it executes and `DENIED` never reaches the executor
    (scenarios 18/27);
  - staging smoke classes come from the real `BUILDING ->
    STAGING_VALIDATED` transitions;
  - resume drills are tasks re-dispatched from durable state on a fresh
    lease generation;
  - unplanned post-lock prompts are decision requests **outside** the
    single consolidated batch (spec 18.1; the batch is the planned
    post-lock channel).
- **Rollout/harness evidence is recorded, never inferred.** Canary
  projects, rollback drills, native harness ids, parity runs and the
  live DSH smoke come from the actual exercises — the DSH smoke is the
  Plan 08 [`HarnessSmokeEvidence`](../../.KCC/runtime/src/kcc_autobuild/harnesses/models.py)
  record whose `passed` verdict is **derived** (all runs, status probe,
  authorized mutation, denied direct mutation, zero prompts/secrets).
  Generic CI never pretends live DSH exists; the gate fails closed
  without a fresh record.

## R3 production authority

At **R3** the control plane may **propose** production authority by
**default** — the R3 gate is the trigger that raises the proposal to the
user — **unless the user opts out before LOCK**. This default is a
proposal, not a grant: the runtime still requires the production
authority to be present in the **locked Build Contract** before any
production-impacting action is executed. `eligible_for` only answers the
metrics question; the authority envelope of the locked Build Contract
(spec 14.3) is the only thing that grants power, and it is never written
by the gate.

## Related

- [Autobuild harnesses and capability levels](./harnesses.md) —
  harness capability tiers, parity contract and the live DSH proof
- [DeepSeek harness](./deepseek-harness.md) — dsh adapter, profile
  proof, and how the live smoke is produced
- [Evaluation scenarios](../../.KCC/runtime/src/kcc_autobuild/evaluation/scenarios.py) —
  the approved 30-scenario catalog
- [KCC Quickstart](../../QUICKSTART.md)

---

KCC framework (c) 2026 Tarek Fawaz, [tikasway.dev](https://tikasway.dev/kcc). Licensed under the terms in [LICENSE](../../LICENSE).
