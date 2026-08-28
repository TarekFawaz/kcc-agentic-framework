---
# Functional fields
description: Plan-03 autobuild task handoff protocol - every fresh execution agent receives one bounded, scoped handoff pack (run/task identity, reachable requirement and trace context, acceptance criteria, Test IDs, locked decisions with LOCKED_DO_NOT_REDECIDE markers, one lease, attempt budget, provider constraints, policy bundle hash) and may implement/test/debug/review/report exactly that scoped task; KCC remains the sole control plane and owns lifecycle, scheduling, Tier-1 interpretation, provider authority and user-facing exceptions.
inputs: A locked Build Contract (Tier-1 invariants + policy bundle hash), the Trace Matrix, the KCC task queue entry (task id, requirement ids, acceptance ids, Test IDs, scoped providers), the attempt budget, and the relevant decision/ADR log entries.
outputs: A bounded TaskHandoff pack serialized as deterministic JSON via `kcc_autobuild.bridge.ExecutionBridge` (<= max_handoff_bytes, default 65536), plus the worker's eventual Execution Report.

# Obsidian metadata
title: "Autobuild Task Handoff Protocol"
aliases:
  - autobuild-task-handoff
  - task-handoff
tags:
  - framework/protocol
  - autobuild
  - execution/bridge
created: 2026-08-28
updated: 2026-08-28
version: 1.0.0
status: active
copyright: "KCC framework (c) 2026 Tarek Fawaz"
homepage: "https://tikasway.dev/kcc"
license: "Licensed under the terms in LICENSE"
---

# Autobuild Task Handoff

Every fresh implementation agent receives one **bounded task handoff
pack** (Design Spec v1.2 section 16.2).  Together with the Build
Contract and the Trace Matrix, the handoff pack is the **formal
interface between the KCC control plane and the execution plane**
(section 28.3); the finished work comes back as one Execution Report
(`.KCC/kernel/contracts/execution-report.md`).  The machine schema is
`kcc_autobuild.bridge.TaskHandoff`; the behavioral contract is owned by
`.KCC/runtime/tests/test_bridge.py`.

## The pack is bounded and scoped

`kcc_autobuild.bridge.ExecutionBridge(max_handoff_bytes=65536)` builds
the pack; the serialized pack (`TaskHandoff.pack()`) never exceeds the
byte limit.  An oversized pack is **rejected, never truncated** — KCC
rescopes the task rather than silently dropping locked context.

Pack contents (spec 16.2):

- run and task identity plus one **lease** bound to that run/task with
  a strictly positive, incrementing generation (one lease per attempt);
- the task's **requirement ids** and their **forward-reachable trace
  context** only — unrelated requirements and their clusters are never
  packed;
- the task's **acceptance ids** and **Test IDs** (both required;
  acceptance/Test IDs outside the reachable context are rejected);
- **locked decisions** carrying the explicit `LOCKED_DO_NOT_REDECIDE`
  marker — relevant ADR/Decision Log excerpts the worker must treat as
  settled (scoped to the task's requirements, plus global ones);
- the task's **attempt budget** (maximum attempts, time, token, cost,
  escalation tier — KCC-owned, never re-negotiable by the worker);
- **provider constraints** scoped to the task's providers: approved
  accounts, per-provider spend caps, auto-provision status from the
  canonical authority status `AUTO_PROVISION_AUTHORIZED`, and
  credential **references only** (`vault://`, `env://`, `keychain://`)
  — no plaintext secret ever travels in a pack (spec section 24), and
  authority-global accounts/credential refs are attached **only** to
  the constraints of auto-provision-authorized providers (an
  out-of-scope provider carries neither);
- the **policy bundle hash** — the canonical policy/evaluator signature
  anchoring the pack to the exact locked policy bundle it was built
  from.  The anchor is cross-verified, fail-closed: the source contract
  must be **locked** and an explicit hash must equal the contract's
  canonical `contract_hash` (a mismatch or an unlocked contract is
  rejected, never silently packed).

## Worker authority (scoped task only)

Within the task's pack, the worker may:

- **implement** the scoped requirements (RED -> GREEN -> REFACTOR,
  bounded engineering discipline);
- **test** against the packed Test IDs;
- **debug** systematically inside the scoped task when a failure is
  classified for it;
- **review** its work (request review, receive findings, verify before
  completing) against the packed acceptance criteria;
- **report** exactly one Execution Report and **return control to
  KCC**.

## Worker prohibitions

The worker must NOT:

- **alter lifecycle** — no lifecycle transition, state change, lock or
  unlock of the run; lifecycle ownership never moves out of KCC and no
  competing lifecycle controller is adopted (spec 28.1/28.2);
- **schedule sibling tasks** — no task/wave decomposition, no parallel
  dispatch, no re-sequencing of what KCC scheduled (spec 5.1);
- **reinterpret Tier-1** — every packed locked decision is
  `LOCKED_DO_NOT_REDECIDE`; Tier-1 changes require a contract revision
  and re-lock by KCC, never a worker decision (spec 14.1);
- **grant provider authority** — no provider whitelist/account/cap
  expansion, no auto-provision authorization, no credential material
  beyond the packed references;
- **decide user-facing exceptions** — exceptions outside the locked
  authority envelope are classified and reported per the KCC exception
  taxonomy (spec 18); the worker never answers for the user.

## Return path

The worker's Execution Report is a claim that KCC alone verifies and
accepts (execution-report contract).  A rejected report counts as a
failed attempt and the run resumes from durable state, never from
conversational memory (spec 22).
