---
# Functional fields (consumed by harness adapters)
name: autobuild-task-execute
description: >
  Execute one bounded autobuild task from its handoff pack: read the handoff, verify the single KCC lease, run the TDD discipline, debug only after KCC classifies the current failure as BUG, request and receive review, verify with exact commands and evidence, emit the validated report and hand control back to KCC. The discipline is task-local and never owns or advances the run. Usage: /autobuild-task-execute <task-id>
argument-placeholder: <ARGS>
delegates-to:
  - implementer
  - verifier
  - engineering-tdd
  - engineering-debug
  - engineering-request-review
  - engineering-receive-review
  - engineering-verify
maturity: L1
maintainer: tarek.fawaz1983@gmail.com
copyright: "KCC framework (c) 2026 Tarek Fawaz"
homepage: "https://tikasway.dev/kcc"
license: "Licensed under the terms in LICENSE"
lifecycle-owner: false

# Obsidian metadata (used in the vault, ignored by harness adapters)
title: Autobuild Task Execute Skill
aliases:
  - autobuild-task-execute-skill
tags:
  - framework/skill
  - autobuild
  - execution
created: 2026-08-28
updated: 2026-08-28
version: 1.0.0
status: active
---

# Autobuild Task Execute

The bounded execution discipline for one autobuild task: a fresh worker
runs the task from its KCC handoff pack and returns exactly one terminal
report.  KCC remains the sole control plane: this skill only executes the
scoped task and never owns or advances the run.

## Steps

The discipline in the exact order it must run (the detailed phase
sections below spell each step):

1. **Read handoff** — read the bounded task handoff pack as the only
   interface to the control plane: task id, scoped requirement ids,
   acceptance ids and Test IDs, forward-reachable trace context, locked
   decisions marked `LOCKED_DO_NOT_REDECIDE`, the run id and task id,
   one lease, one attempt budget, provider constraints (secret
   references only) and the canonical policy-bundle hash.  Anything
   outside the pack stays outside the task; the worker never changes
   task scope.
2. **Verify lease** — verify the single KCC lease from the pack before
   any work starts: the lease is present, is bound to the same run id
   and task id as the handoff, and its generation is positive.  Lease
   liveness is not a pack fact: it is a chain-of-custody claim that KCC
   alone verifies before acceptance.  No lease in the pack — or a lease
   that does not bind this task — means no work.
3. **engineering-tdd** — delegate implementation to `implementer` under
   the TDD discipline: smallest meaningful failing test first (RED),
   minimum implementation (GREEN), then refactor while staying green.
   If verification fails, do not guess a fix and do not self-classify
   the failure: the debugging discipline is entered only after KCC
   classifies the current failure as BUG.
4. **engineering-debug** — delegate to the debugging discipline only for
   a failure KCC has classified as BUG: reproduce, evidence, one
   hypothesis, smallest experiment, root-cause fix, regression test.
   Never reopen a locked decision; never change task scope.
5. **Request review** — delegate to engineering-request-review with a
   fresh reviewer: specification and acceptance criteria first, then
   code quality, for the current task only, against the handoff's
   acceptance ids and Test IDs.
6. **engineering-receive-review** — delegate to
   engineering-receive-review: verify each finding before applying it
   and record every rejected finding with its evidence.  Findings never
   change task scope and never reopen a locked decision.
7. **engineering-verify** — delegate to engineering-verify: no
   completion claim without fresh verification evidence; run the exact
   verification commands and cite the evidence refs for every
   acceptance criterion and Test ID of the task.
8. **Execution Report** — build the task's terminal report as YAML
   matching the machine schema `kcc_autobuild.bridge.ExecutionReport`;
   the final report must validate through
   `kcc-autobuild validate-model execution-report <path>` before
   returning.
9. **Return control to KCC** — hand the validated report to KCC and
   stop: KCC alone accepts it, advances the run and decides the next
   attempt.

## Read handoff

Read the bounded task handoff pack (`.KCC/kernel/protocols/autobuild-task-handoff.md`)
and treat it as the only interface to the control plane: task id,
scoped requirement ids, acceptance ids and Test IDs, forward-reachable
trace context, locked decisions marked `LOCKED_DO_NOT_REDECIDE`, run id
and task id, one lease, one attempt budget, provider constraints (secret
references only) and the canonical policy-bundle hash.  Anything outside
the pack stays outside the task: the worker implements, tests, debugs,
reviews and reports the scoped task only, and never changes task scope.

## Verify lease

Verify the single KCC lease before any work starts.  From the handoff
pack the worker can prove the identity claims only: the lease is
present, is bound to the same run id and task id as the handoff, and
its generation is positive.  One lease covers one budget envelope, one
isolated workspace and one attempt.  No lease in the pack — or a lease
that does not bind this task — means no work.  Lease liveness (live
versus expired or revoked) is not a pack fact: it is a chain-of-custody
claim that KCC alone verifies before it accepts the report, and a stale
lease ends in a rejected report.

## engineering-tdd

Delegate implementation to `implementer` under the engineering-tdd
discipline: write the smallest meaningful failing test first, verify RED,
write the minimum implementation, verify GREEN, then refactor while
staying green — all within the current task scope and the locked
decisions of the handoff.  If verification fails, do not guess a fix and
do not self-classify the failure: the debugging discipline is entered
only after KCC classifies the current failure as BUG.

## engineering-debug

KCC has classified the current failure as BUG.  Delegate to the
engineering-debug discipline: reproduce, collect evidence, form exactly
one hypothesis, run the smallest experiment, fix the root cause and add a
regression test.  Debugging is systematic and root-cause first, bounded
to the current task; it never reopens a locked decision and never changes
task scope.

## Request review

Delegate to engineering-request-review with a fresh reviewer, checking
the specification and acceptance criteria first, then code quality —
for the current task only, against the handoff's acceptance ids and
Test IDs.

## engineering-receive-review

Delegate to engineering-receive-review: verify each finding against the
task before applying it, and record every rejected finding with its
evidence.  Findings never change task scope and never reopen a locked
decision.

## engineering-verify

Delegate to engineering-verify: no completion claim without fresh
verification evidence; run the exact verification commands and cite the
evidence references (test results, commit, CI run) for every acceptance
criterion and Test ID of the task.

## Execution Report

Build the task's terminal report as YAML, matching the machine schema
`kcc_autobuild.bridge.ExecutionReport`: report identity matches the
attempt lease (run id, task id, positive attempt), status is lowercase
`passed` / `failed` / `blocked`, a `passed` report declares acceptance
evidence (AC ids, Test IDs and evidence refs) and no failure
classification, a `failed`/`blocked` report carries exactly one failure
class from the canonical taxonomy
AUTH|RATE|OUTAGE|BUG|DATA|ENV|CONTRACT|UNKNOWN, plus usage, outputs,
deviations and trace updates.  The final YAML report must validate
through `kcc-autobuild validate-model execution-report <path>` before
returning.

## Return control to KCC

Return the validated report to KCC and stop.  KCC alone verifies the
chain-of-custody evidence (lease liveness, commits, CI runs, usage
reconciliation), accepts or rejects the report, advances the run and
decides the next attempt.  The worker never accepts its own report,
never advances the run and never schedules anything after it; a rejected
report counts as a failed attempt and resumes from durable state.
