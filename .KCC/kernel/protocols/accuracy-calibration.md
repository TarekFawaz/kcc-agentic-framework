---
# Functional fields
description: >
  Defines the accuracy-calibration loop the Butler meta-agent maintains:
  claimed agent confidence vs observed outcomes, per-agent rolling tables,
  drift detection, and how the confidence-gate uses calibration to bias
  trust on subsequent turns.

# Obsidian metadata
title: "Accuracy Calibration Protocol"
aliases:
  - accuracy-calibration
  - calibration-loop
  - agent-calibration
tags:
  - framework/protocol
  - calibration
  - confidence
  - butler
  - documentation
created: 2026-05-29
updated: 2026-05-29
version: 1.0.0
status: active
copyright: "KCC framework (c) 2026 Tarek Fawaz"
homepage: "https://tikasway.dev/kcc"
license: "Licensed under the terms in LICENSE"
---

# Accuracy Calibration Protocol

KCC v0.4 Surface 8 (Confidence) requires every agent turn to emit a computed
confidence score. That alone is not enough to know whether an agent's
confidence is **honest**. An agent that always claims `Confidence: 99%`
but whose work is rejected at `/critical-human-gate` half the time is
miscalibrated - its claim is decoupled from reality. An agent that always
claims `Confidence: 60%` but whose work is approved 95% of the time is
miscalibrated in the other direction - it is sandbagging.

**Accuracy calibration** is the operational loop that ties claimed
confidence to observed outcome, surfaces drift, and biases trust on
subsequent turns. It is owned by [[../../capabilities/agents/butler|Butler]]
as a third mode alongside `brief` and `remember`.

## What "accuracy" means here

For every agent turn, we have:

- **Claimed confidence** - the `Confidence: NN%` line the agent emitted
  (from the [[confidence-gate]] contract).
- **Observed outcome** - the downstream signal that proves whether the
  agent's work was right:
  - `approved` - the human or the next-stage agent accepted the work as-is.
  - `revised` - the work was kept but required edits before acceptance.
  - `escalated` - the work was punted to a different agent / dialect / human.
  - `aborted` - the work was discarded.

Calibration = the relationship between **claimed** and **observed** over a
rolling window of turns, per agent.

## Why Butler owns it

Butler is the framework's memory custodian and one of two meta-agents that
always runs alongside every lifecycle skill. Putting calibration anywhere
else creates a duplicate-source-of-truth problem:

- If `token-guard` owned it, the calibration table would diverge from
  Butler's `memory/` entries on the same agent turns.
- If each lifecycle agent owned its own calibration, there would be no
  single curator and no shared drift detector.
- If a new meta-agent owned it, the always-on overhead doubles.

Butler already triages every session report on `/butler-remember`. Reading
the `Confidence: NN%` line and the eventual outcome is a small extension
to that triage, not a separate scan. The single curator avoids fragmentation
and keeps the always-on meta-agent footprint flat.

## Per-agent calibration table format

The human-readable canonical form lives at
`memory/calibration/agent-calibration.md` and follows this shape:

````markdown
# Agent Calibration

_Last updated: {ISO-8601 timestamp}_
_Window size: 10 turns (rolling)_
_Drift threshold: +/-10 percentage points_

| Agent | N (turns in window) | Mean claimed confidence | Observed success rate | Drift (pp) | Last updated | Notes |
|--|--|--|--|--|--|--|
| idea-interrogator | 10 | 92% | 90% | -2 | 2026-05-29 | within band |
| technical-interrogator | 10 | 95% | 80% | -15 | 2026-05-29 | NEGATIVE DRIFT - claims too high |
| spec-writer | 8 | 88% | 100% | +12 | 2026-05-29 | POSITIVE DRIFT - sandbagging |
| architect | 10 | 93% | 95% | +2 | 2026-05-29 | within band |
| planner | 9 | 90% | 89% | -1 | 2026-05-29 | within band |
| implementer | 10 | 87% | 85% | -2 | 2026-05-29 | within band |
| verifier | 10 | 96% | 95% | -1 | 2026-05-29 | within band |
| ... | | | | | | |
````

Each row covers the **last N turns** for that agent (default rolling
window: 10). When N < 5, the row is marked `insufficient data` and the
drift column is left blank - calibration claims need at least 5 samples
to mean anything.

Optional cross-references: an interesting calibration finding (e.g. a
persistent negative drift) MAY also be stored as a `pattern` entry in the
memory store (`memory/patterns/PAT-NNN.md`) with a wikilink to the agent
row. Cross-referencing is encouraged when the finding generalizes, not
required for every row.

## Update cadence

The calibration table updates in two ways:

1. **Per session end** - Butler's `remember` mode (triggered by
   `/butler-remember`) reads the session trace, extracts every
   `(agent, claimed_confidence, outcome)` triple from the handover log and
   the backchannel events, and rolls each into the matching agent row.
2. **Scheduled re-calibration** (future) - when `settings.json` defines a
   scheduled calibration hook (e.g. nightly across all open sessions),
   Butler runs a full rebuild from the trace + backchannel history. This
   hook is not yet wired; the per-session update is the only live path for
   v1.1.

Calibration writes are append-only conceptually: a row in the markdown
table represents the *current* window state, but the underlying outcomes
that fed it are appended to `coordination/backchannel.jsonl` as
`outcome-recorded` events so the rolling window can be rebuilt without loss.

## Drift detection

A row enters **drift** when, over the rolling window:

- `mean_claimed_confidence - observed_success_rate > +10 pp` ->
  **negative drift** (agent claims too high; trust should decrease).
- `mean_claimed_confidence - observed_success_rate < -10 pp` ->
  **positive drift / sandbagging** (agent claims too low; trust should
  increase but the gate is firing unnecessarily).

When drift crosses the +/-10 pp threshold, Butler:

1. Updates the row's `Notes` column with `NEGATIVE DRIFT` or
   `POSITIVE DRIFT` plus the magnitude.
2. Emits a `calibration-drift` event to
   `coordination/backchannel.jsonl`:

   ```json
   {
     "ts": "2026-05-29T11:02:17Z",
     "id": "BC-00099",
     "from": "butler",
     "to": "broadcast",
     "kind": "calibration-drift",
     "spec": null,
     "session": "<session-id-or-null>",
     "payload": {
       "agent": "technical-interrogator",
       "window_size": 10,
       "mean_claimed_pct": 95,
       "observed_success_pct": 80,
       "drift_pp": -15,
       "direction": "negative",
       "recommendation": "lower trust on next turn; bias /critical-human-gate to fire"
     }
   }
   ```

3. Surfaces the drift in the **next** `/butler-brief` for any spec that
   would route through the drifting agent (as a `Known Pitfalls` entry).

The threshold (default +/-10 pp), window size (default 10), and minimum
sample count (default 5) are tunable via the calibration section of
`memory/calibration/agent-calibration.md` frontmatter - Butler reads its
own configuration from the file it owns.

## How `/critical-human-gate` uses calibration

The [[../../capabilities/skills/critical-human-gate|/critical-human-gate]]
skill consults the calibration table when deciding how aggressively to
involve the human:

| Situation | Gate behavior |
|--|--|
| Agent has **negative drift** (claims too high) | Lower the effective confidence threshold for THIS agent by the drift magnitude. An agent claiming `95%` with `-15 pp` drift is treated as if it claimed `80%`, which falls below the default 95% threshold and fires the gate. |
| Agent has **positive drift** (sandbagging) | Note the drift in the gate prompt so the human knows the gate may be over-firing, but do not auto-bypass. |
| Agent has insufficient data (N < 5) | Treat as no drift; use the raw claimed confidence. |
| Agent is within band (|drift| <= 10 pp) | Use the raw claimed confidence - no adjustment. |

This is how calibration **closes the loop**: the meta-agent's observation
of past outcomes actively biases the gate on future turns. Without it,
confidence is a number the agent emits and nobody trusts; with it, the
number is anchored to a track record.

## Integration with the existing confidence-gate protocol

[[confidence-gate]] is the on-turn enforcement layer. This protocol is the
**off-turn calibration layer** that biases the gate's threshold per agent.
Together:

- `confidence-gate` says: "every agent emits `Confidence: NN%`; below the
  threshold, invoke `/critical-human-gate`."
- `accuracy-calibration` (this protocol) says: "Butler tracks
  claimed-vs-observed per agent and, when drift exceeds +/-10 pp, adjusts
  the per-agent effective threshold the gate uses."

The confidence contract itself is unchanged - agents still emit a single
`Confidence: NN%` line. The interpretation of that number depends on the
agent's calibration history.

## Storage

| What | Where |
|--|--|
| Human-readable calibration table | `memory/calibration/agent-calibration.md` |
| Per-row optional pattern entry | `memory/patterns/PAT-NNN.md` (cross-referenced from the row) |
| Outcome events (rolling-window source) | `coordination/backchannel.jsonl` (`outcome-recorded` events) |
| Drift events | `coordination/backchannel.jsonl` (`calibration-drift` events) |

Butler is the sole writer of `memory/calibration/agent-calibration.md`,
consistent with its existing role as the sole writer of `memory/`.

## Related

- Butler agent: [[../../capabilities/agents/butler]]
- Confidence gate protocol: [[confidence-gate]]
- Critical human gate skill: [[../../capabilities/skills/critical-human-gate]]
- Confidence contract: [[../contracts/confidence-contract]]
- Backchannel protocol: [[backchannel]]
- Token budget protocol (related calibration pattern for cost): [[token-budget]]
