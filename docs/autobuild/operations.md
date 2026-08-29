---
title: Autobuild Operations
aliases:
  - autobuild-operations
  - autobuild-operator-guide
tags:
  - framework/documentation
  - autobuild
  - operations
created: 2026-08-29
updated: 2026-08-29
version: 1.0.0
status: active
copyright: "KCC framework (c) 2026 Tarek Fawaz"
homepage: "https://tikasway.dev/kcc"
license: "Licensed under the terms in LICENSE"
---

# Autobuild operations

Autobuild is the **opt-in** discovery-and-lock workflow: it deepens
discovery before implementation (think to completion before building to
completion) and, at LOCK, hands the locked Build Contract to the
autonomous controller. It is a **separate capability** from the `auto`
skill: `auto` stays the Human-On-The-Loop spec lifecycle, autobuild is
the contract-locked autonomous build workflow. Starting an autobuild run
never changes `auto` semantics.

The discovery sequence is risk classify -> H1 scope confirm ->
journey/flow map -> clickable prototype -> H2 walkthrough ->
research/architecture -> Trace Matrix + Decision Log ->
dependency/readiness evidence -> red-team review -> Build Contract +
runtime validation -> LOCK & BUILD -> controller handoff. H1 Scope, H2
Prototype and final LOCK are the only formal pre-build gates; after LOCK
the controller proceeds autonomously and only contract-external
conditions may interrupt the human.

## Operator commands

| Command | Meaning |
|---|---|
| `autobuild <idea-or-path>` | Start a new autobuild run from an idea description or a file/folder path (`<idea-or-path>` is the raw idea text or a path that provides it). |
| `autobuild <run-id>` | Resume RUN: re-enter an existing run (e.g. `RUN-001`) and continue from the first incomplete action. |
| `autobuild --status <run-id>` | Show the run's durable lifecycle state and task status. |
| `autobuild --pause <run-id>` | Pause mid-run: durable `PAUSED` first, then drain/fence/freeze. |
| `autobuild --resume <run-id>` | Resume a paused run: `PAUSED -> RESUMING -> BUILDING` from durable state. |

Run IDs follow `RUN-<...>` (`RUN-[A-Za-z0-9][A-Za-z0-9-]*`). In a harness
that exposes the skill as a slash command the same entrypoint is
`/autobuild <idea|run-id>`.

## Lifecycle states

Primary lifecycle: `INTAKE -> DISCOVERY -> PROTOTYPE_REVIEW ->
ARCHITECTURE -> DE_RISK -> READINESS -> CONTRACT_REVIEW -> LOCKED ->
BUILDING -> STAGING_VALIDATED -> DEPLOYED -> PRODUCTION_VALIDATED ->
DONE`. Side states: `BLOCKED` (external condition may clear
automatically), `EXTERNAL_WAIT` (external review pending),
`PAUSED`/`RESUMING` (operator-controlled), `HALTED` (consolidated human
decision), `ROLLING_BACK` (authorized recovery), `ABANDONED` (intentional
end). Transitions are persisted and auditable.

## Pause and resume

- `--pause` persists the `PAUSED` transition **first**, then drains,
  fences and freezes: no new dispatch, worker leases fenced, resources
  frozen, and a pause checkpoint is written — a drain failure mid-pause
  never leaves the run `PAUSED` without a durable checkpoint.
- `--resume` runs durable light-resume revalidation and moves
  `PAUSED -> RESUMING -> BUILDING`. A resume mutation failure leaves the
  run `PAUSED` (fail closed — the next resume revalidates again).
- **Resume RUN** after any interruption reconstructs from durable state
  (lifecycle state, task statuses, completed commits, evidence) and
  continues at the first incomplete action: a passed task is **never**
  re-executed, an in-flight task whose lease lapsed is reclaimed, and
  run-level conditions (ambiguous target state, rollback in progress,
  external wait pending) take precedence, fail closed. Durable run state
  lives under `coordination/autobuild/<RUN-ID>/`; conversational memory
  is never the source of truth.

## BLOCKED auto-recheck

`BLOCKED` means an external condition prevents progress but may clear
automatically. The run stays `BLOCKED` and the controller **auto-rechecks**
on the defined schedule (default outage SLA 900 s for provider outages;
provider or worker outages are rechecked against real evidence, never
replaced by a local pretend-pass). A hard budget-cap breach settles
`BLOCKED` after the books settle (the breach is prevented, not lauded).
If the condition clears, the run resumes; if the SLA/evidence window
exhausts, the failure escalates as an E-code exception before any
`HALTED` decision is produced.

## EXTERNAL_WAIT tracking

External waiting states such as app-store review or third-party manual
approval are modeled as `EXTERNAL_WAIT` with **durable per-run wait
state** (review outcome, wait start, next poll time) — never falsely
reported as completed autonomous work. Polling is monotonic (a poll
before the persisted `next_check_at` is rejected) and elapsed waiting is
not a failure: the BUG-attempt count captured at wait start is preserved
across polls. Routing on the review outcome:

- **APPROVED** -> `PRODUCTION_VALIDATED` (the wait resolves to completed
  production validation);
- **REJECTED, no Tier-1 impact** -> `BUILDING` (the run resumes within
  the locked contract);
- **REJECTED with Tier-1 impact** -> `HALTED`, carrying the review
  reasons as the consolidated decision request;
- still **PENDING** -> `EXTERNAL_WAIT` (the run keeps waiting).

## HALTED — consolidated decision only outside authority

After LOCK the runtime interrupts the human **only** for a
contract-external condition that cannot be safely resolved within the
approved authority envelope (exceptions E1-E8: identity/KYC, out-of-
whitelist provider, hard budget cap, irreversible action outside policy,
legal/compliance/security assumption, credential revocation, provider
unavailable with no allowed fallback, impossible locked invariant).
Multiple blockers are batched into **one consolidated decision request**
(spec 18.1) — questions are never dripped one by one. `HALTED` requires a
human decision; nothing irreversible happens before it; a Tier-1
rejection settles `HALTED` and only a re-contract (revised once and
re-locked once) may revive the run. Unexpected post-lock questions are
tracked as a quality metric (spec 18.2), not resolved by more prompting.

## Runtime machinery

The durable runtime CLI is `kcc-autobuild` (init-run, show-run,
transition, validate-model, harness probe/doctor/smoke, gate-write,
gate-exec); the controller persists every run under
`coordination/autobuild/<RUN-ID>/`. Harness capability proof for post-lock
fresh workers is in [the deepseek harness doc](./deepseek-harness.md) and
[the harness levels doc](./harnesses.md); rollout gates (R1/R2/R3) are in
[the rollout doc](./rollout.md).

## Related

- [Licensing and attribution baselines](./licensing.md) - KCC custom
  (non-SPDX, GitHub `NOASSERTION`) + Superpowers MIT baselines
- [Harnesses and capability levels](./harnesses.md) - two-mode operation
  and report parity
- [DeepSeek Harness (dsh) adapter](./deepseek-harness.md) - dsh sync,
  install, profile proof, and worker boundary
- [Autonomy metrics and rollout gates](./rollout.md) - R1/R2/R3 gates
- [KCC Quickstart](../../QUICKSTART.md)

---

KCC framework (c) 2026 Tarek Fawaz, [tikasway.dev](https://tikasway.dev/kcc). Licensed under the terms in [LICENSE](../../LICENSE).
