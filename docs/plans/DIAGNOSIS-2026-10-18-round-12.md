---
title: "Diagnosis: test round 12 (BudgetPal, unattended fast track)"
tags:
  - framework/plans
  - diagnosis
created: 2026-10-18
status: acted-on
---

# Diagnosis: round 12 and the twelve unattended rounds before it

Rounds 0 to 12 of the unattended fast-track test (`TestRounds/new-round.sh budgetpal --measure`,
`--fasttrack --silent --assume` on a fixed idea) never ended with an APPROVED walking skeleton. The
reports said "stuck on the bugs after implementation". The record of round 12 says something more
precise, and the fixes in this commit follow from it.

## What round 12 did

| Step | Model and effort | Agent time | Outcome |
|--|--|--|--|
| IMPLEMENT, 4 waves and 2 retries | balanced, high and xhigh | 57 min | every wave passed its scope check |
| TEST pass 1 | balanced, xhigh | 51 min | 30 of 32 Test IDs pass, 4 Bugs filed |
| FIX, one ruling answered by policy | balanced, xhigh | 35 min | all 4 Bugs fixed and verified |
| TEST pass 2 and REVIEW pass 2 | balanced, high | 15 min | CHANGES_NEEDED with zero open Bugs |
| FIX 3, TEST 3 | balanced | until the run was stopped | FIX wrote nothing and said so |

The four Bugs were real and the loop closed them: a HIGH advisory in a transitive package, a build
output that could not start, a moderate advisory in an unused pin, and a flaky skip rule in the compose
smoke test. Two of the four were supply-chain pins the verifier raised by policy, not defects.

## Why it could not finish

After the fixes the quality gate stayed red for three things no code change can turn green:

1. `QG-DEPS` exited 127. Commit d00c3e3 added `-L <lockfile>` next to `-r <dir>` in the osv-scanner
   call; osv-scanner 2.x takes one or the other and stops before scanning. The gate mapped the exit
   code to `fail`, owner `implementer`.
2. `QG-IMAGE` scanned `budgetpal-web:local` and `budgetpal-api:local`, images built on October 16 by
   rounds 10 and 11, and found 43 fixable HIGH findings in code that was not this round's. The idea
   had excluded image scans, the plan covered no `QG-IMAGE`, and the gate ran it anyway.
3. Deferrals the framework already knew about: semgrep not installed, Docker builds blocked by TLS
   interception, the SIGTERM test skipped on Windows.

The verifier reasoned correctly ("none of these is a defect in the changed files; each needs an
environment fix or a recorded human waiver") but had no verdict for it. The vocabulary was APPROVED,
CHANGES_NEEDED, QUALITY_DEFERRED and TOOLCHAIN_DEFERRED, and QUALITY_DEFERRED was reserved for gate
exit 3. A gate that exits 1 for a non-code reason became CHANGES_NEEDED; the driver labelled every
CHANGES_NEEDED `REVIEW-002 (implementer)`, so the FIX-skip rule never fired and the spec went
FIX, TEST, REVIEW again until the attempt cap parked it. Round 11 had the same shape with a different
trigger. The problem was the state machine, not the model and not the number of bugs.

Two more things cost time without changing the outcome: the first TEST pass ran 51 minutes at xhigh,
20 of them on a compose build that was known to fail on this machine; and the run's dollar totals
were a fallback price Claude Code 2.1.283 reports for model ids it does not know (`unrecognized_model`
on every dispatch), which is also where the "Haiku costs the same as Sonnet" conclusion came from.

## On the model-tier question

Main ran architect, spec-writer, planner and implementer on the strong tier; this branch runs them on
balanced. Nothing in round 12 points at reasoning strength: the architecture passed conformance, the
plans had complete test tables and were executed, and the terminal loop was a shell script. Rounds 0
to 6 ran with strong-tier defaults and produced no runnable app at all. The verifier, which decides the
outcome, was balanced on both branches. Model strength is a second-order variable here; it is cheap to
test as a controlled variable once the driver is fixed (round 13 as the branch stands, round 14 with
the planning agents on strong, same fixture).

## What changed (this commit)

- `quality-gate` (both shells): osv-scanner called with `-L` per lockfile or `-r` alone; a scanner that
  exits without a result is a deferral owned by a human with the per-stack audit standing in; dev-only
  advisories do not gate unless `quality.audit_dev_dependencies` is true; a built image older than the
  workspace files is stale and deferred; the scope comes from the plan's `## Gates coverage`
  (`QG-SCOPE` row names what the architecture left out); `opengrep` stands in for `semgrep`.
- `kcc-run` (both shells): the `WAIVER_NEEDED` verdict and the `waiver` gate (waive, recheck, abort;
  policy: waive); a CHANGES_NEEDED review with no open Bug, no implementer-owned gate failure and no
  traceability error is read the same way (`REVIEW-004`); a scoped TEST on an unchanged HEAD runs no
  verifier; PREFLIGHT `LIMIT` lines reach the verifier as known environment limits; the bash
  `files-exist any` check reads its last path (ASK failed on macOS and Linux before).
- `toolchain-preflight` (both shells): Docker registry and build-network probes.
- Router rule 10: a review never runs above high unless the item is extra-high.
- Verifier: the waiver verdict and table, the advisory policy, environment limits.
- Dashboard, conformance checks and state tables know the new verdict and gate.

## What a round 13 should show

- SPEC-001 ends APPROVED, or WAIVER_NEEDED with only the two environment items of this machine
  (Docker build network, SIGTERM on Windows), in one TEST and one REVIEW after the FIX pass.
- No FIX dispatch that writes nothing.
- The first TEST pass under 30 minutes (no compose build attempt, effort high).
- `QG-DEPS` green on the production dependencies; `QG-IMAGE` out of scope by the plan.
