---
title: Execution Report Contract
aliases:
  - execution-report
  - execution-report-contract
tags:
  - kcc/kernel
  - contract
  - autobuild
  - execution
created: 2026-08-28
updated: 2026-08-28
version: 1.0.0
status: active
copyright: "KCC framework (c) 2026 Tarek Fawaz"
homepage: "https://tikasway.dev/kcc"
license: "Licensed under the terms in LICENSE"
---

# Execution Report Contract

The Execution Report is the worker's terminal statement for one
execution attempt (Design Spec v1.2 sections 16.4, 21, 22).  It is the
return leg of the task handoff: a bounded handoff pack goes out
(`.KCC/kernel/protocols/autobuild-task-handoff.md`), and exactly one
Execution Report comes back.  The machine schema is
`kcc_autobuild.bridge.ExecutionReport`; the chain-of-custody gate is
`kcc_autobuild.evidence.EvidenceVerifier` (with
`kcc_autobuild.evidence.ReportAcceptance` as its verdict model), and
the behavioral contract is owned by
`.KCC/runtime/tests/test_execution_report.py`.

## The report is an evidence claim, never proof

The worker's own narration is not evidence.  "Execution Report claims
are not trusted until KCC verifies chain-of-custody evidence" (plan
Global Constraint).  A report carries *declared* acceptance evidence —
AC IDs, Test IDs and evidence refs — and *declared* outputs (artifacts,
commits, CI runs) and *declared* usage; every declaration is re-checked
against durable records before it is believed.

## KCC alone accepts and advances

KCC is the sole control plane (spec sections 5.1, 28.1): only KCC
accepts a report, advances the run, schedules the next task, or
re-dispatches the task as a new attempt.  The worker never accepts its
own report, never advances its own run, and never authorizes the next
attempt.  Each execution attempt owns one lease, one budget envelope,
one isolated workspace and one Execution Report (Global Constraint).

## What KCC verifies before acceptance

- **Lease identity and liveness** — the attempt lease exists, is bound
  to the run, and is still live; report identity (run id, task id,
  positive attempt number) matches the lease it claims.
- **Passed-report evidence** — a `passed` report must name acceptance
  criteria (AC IDs), the Test IDs that validate them, and evidence refs
  for the test artifacts (spec section 21: all acceptance criteria with
  passing required Test IDs first, plus evidence traceability).
- **Claimed refs and artifacts exist** — every claimed commit exists,
  every claimed CI run completed with a passing result, every artifact
  ref resolves.
- **Usage reconciliation** — spend/token/provider-call actuals
  reconcile with provider records within the contract's budget money
  policy (spec 14.4).

## Rejections (fail-closed)

KCC rejects a report that has:

- a **stale lease** — expired, revoked or unknown lease, or lease/run
  identity mismatch;
- **malformed evidence** — missing AC IDs, missing Test IDs, missing
  or empty evidence refs, duplicate AC ids, a failure classification
  outside the canonical AUTH|RATE|OUTAGE|BUG|DATA|ENV|CONTRACT|UNKNOWN
  taxonomy, or a status outside lowercase `passed` / `failed` /
  `blocked`;
- **missing refs/artifacts** — claimed commits that do not exist,
  referenced CI runs that did not pass, artifact paths that do not
  resolve;
- **failed verification** — any chain-of-custody check that did not
  pass (commits, CI, usage reconciliation, evidence integrity).

## A rejected report counts as a failed attempt

The verdict model is fail-closed and self-consistent:
`ReportAcceptance(accepted=False, counts_as_failed_attempt=True,
reasons=[...])`.  A rejected report **always** counts as a failed
attempt (never silently ignored), carries its rejection reasons, and
consumes one attempt of the task's KCC-owned budget (spec 17).  A
record of the rejection is kept for resumability (spec 22) so the next
attempt resumes from durable state instead of conversational memory.

## Serialization

Reports serialize with the same deterministic model validation used by
`kcc-autobuild validate-model`; a report that does not validate against
the model is malformed and is rejected before any evidence check.
