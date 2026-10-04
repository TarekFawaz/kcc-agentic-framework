---
# Functional fields (none - protocols are pure prose)

# Obsidian metadata (used in the vault, ignored by harness adapters)
title: Token Budget Protocol
aliases:
  - token-budget
tags:
  - framework/protocol
  - lifecycle/meta
created: 2026-05-24
updated: 2026-09-21
version: 1.7.0
status: active
copyright: "KCC framework (c) 2026 Tarek Fawaz"
homepage: "https://tikasway.dev/kcc"
license: "Licensed under the terms in LICENSE"
---

# Token Budget Protocol

This protocol is the **canonical, reproducible formula** the [[token-guard]] agent uses to forecast token cost for a spec or a prompt. Keep it transparent: any human should be able to redo the arithmetic on paper from the inputs alone.

---

## Inputs

| Symbol            | Source                                                   | Example |
|--|--|--|
| `criteria`        | count of epic criteria plus story/enabler criteria       | 12      |
| `files`           | count of entries under `## Impacted Files` in spec       | 4       |
| `backlog_items`   | count of stories plus enablers in the spec `## Backlog` table / `Backlog/` files (legacy v5: `backlog.md`) | 7       |
| `risk`            | `low` / `med` / `high` - from the spec's Risk section    | med     |
| `plan_steps`      | count of numbered steps in plan file (null if no plan)   | 12      |
| `dialect_complexity` | highest backlog item complexity: `low`, `medium`, `high`, `extra-high` | medium |
| `model_class`     | target class per lifecycle step (see defaults below)     | balanced|

For free-form prompts (Mode B), only the prompt's character count is used; no risk or step multipliers apply.

---

## Formula (Mode A - spec estimation)

### 1. Base input tokens

```
base_input = 5000
           + (files         x 1500)
           + (criteria      x 300)
           + (backlog_items x 250)
           + (plan_steps    x 400)   # 0 if no plan yet
           + dialect_overhead
```

The 5000-token floor accounts for: loading `CLAUDE.md`/`AGENTS.md`,
the spec file, `Backlog/` item files, `plan.md`, framework protocols, selected dialect files, and the agent's own system prompt.

Dialect overhead covers loading the selected dialect guidance:

| Complexity | dialect_overhead |
|--|--|
| low        | 500              |
| medium     | 1000             |
| high       | 2000             |
| extra-high | 4000             |

### 2. Output ratio by model-class

Output tokens are estimated as `base_input x output_ratio`. Stronger models emit more reasoning and longer responses:

| Model class           | output_ratio |
|--|--|
| `strong-reasoning`    | 0.60         |
| `balanced`            | 0.45         |
| `fast-implementation` | 0.30         |
| `local-strong`        | 0.50         |
| `local-fast`          | 0.30         |

### 3. Risk multiplier (applied to BOTH input and output)

| Risk  | multiplier |
|--|--|
| low   | 1.0        |
| med   | 1.4        |
| high  | 2.0        |

High-risk specs need more re-reads, more verifier rounds, and more architect consultation - all of which inflate context.

### 4. Complexity multiplier

Apply this after the risk multiplier:

| Complexity | multiplier | Model hint |
|--|--|--|
| low        | 1.0        | junior-safe, often `fast-implementation` or `balanced` |
| medium     | 1.15       | mid-level, usually `balanced` |
| high       | 1.35       | senior, often `strong-reasoning` for plan/review |
| extra-high | 1.75       | principal-expert, `strong-reasoning` and wider confidence band |

### 5. Lifecycle-step multipliers

The base above represents one full agent turn (approximately a planner pass). Each lifecycle step is a fraction or multiple of that base:

| Step        | multiplier | rationale                                                      |
|--|--|--|
| interrogate | 0.3        | Q&A is shallow file-reading + dialogue                         |
| create      | 0.5        | Spec drafting reads codebase but writes a single short artifact|
| plan        | 0.8        | Full code trace, but no editing                                |
| implement   | 1.5        | Reads + writes + re-reads after each edit + commits            |
| test        | 0.7        | Re-reads spec + runs a few targeted checks                     |
| review      | 0.4        | Diff-only, no full re-trace                                    |

### 6. Per-step token computation

For each lifecycle step `s`:

```
input_tokens(s)  = base_input x step_multiplier[s] x risk_multiplier x complexity_multiplier
output_tokens(s) = input_tokens(s) x output_ratio[model_class(s)]
cost(s)          = (input_tokens(s)  / 1e6) x rate_in [model_class(s)]
                 + (output_tokens(s) / 1e6) x rate_out[model_class(s)]
```

Rates are read from [[ROI]] (or the per-idea `ROI.md` if the human has edited them).

### 7. Confidence band

Report each cost as a range: `[cost x 0.7, cost x 1.3]` - i.e. +/-30%. This band is intentionally wide until calibration data accumulates (see Calibration below).

---

## Upfront AutoPolicy Estimate

When `auto` includes `--budget`, Token Guard may estimate from an IDEA folder
before concrete specs exist. It uses the Mode A formula with conservative
inputs inferred from `QuickRoadmap.md`, `SpecWriterStarter.md`, and
`ROADMAP.md` if created. If no concrete spec folder exists, use a +/-50% confidence band and
label the estimate provisional. Later spec-level estimates still run and either
consume the approved cap or stop when the cap is exceeded.

---

## Formula (Mode C - idea-scope estimation)

Mode C is the **pessimistic upfront** method. It produces a forecast for an
entire IDEA before any SPEC has been created, using only the idea-level
breakdown (phases + likely epics + per-epic story points). It is what
`/idea-interrogator` and `/auto` display in every scenario so the human
sees the spend envelope **before** anything expensive starts.

### Inputs

| Symbol                       | Source                                                                | Example |
|--|--|--|
| `phases_count`               | number of phases in `idea-{ID}-{slug}.md` breakdown                   | 3       |
| `epics_count`                | total likely epics across all phases                                  | 6       |
| `story_points_total`         | sum of per-epic story-point estimates                                 | 30      |
| `story_points_per_epic_avg`  | `story_points_total / epics_count`                                    | 5       |
| `avg_complexity`             | average per-epic complexity: low/med/high/huge (default `med`)         | med     |
| `target_model_class[step]`   | per lifecycle step (caller may override defaults)                     | balanced|

Default `target_model_class` mapping for Mode C:

- interrogate, create, plan, review -> `strong-reasoning`
- implement, test -> `balanced`
- meta-agents -> `fast-implementation`

### 1. Per-story base tokens

Mode C uses a per-story constant rather than the spec-level inputs that Mode A
relies on, because no concrete `criteria` / `files` / `plan_steps` exist yet:

| avg_complexity | per_story_base (input tokens) |
|--|--|
| low            | 8 000                         |
| med            | 14 000                        |
| high           | 22 000                        |
| huge           | 36 000                        |

Story point -> story conversion uses `stories_per_point = 1` for forecasting
(one story point approximately one INVEST-sized story).

```
stories_total = epics_count x story_points_per_epic_avg
```

### 2. Complexity multiplier (Mode C)

Same table as Mode A section 4, applied after `per_story_base`:

| avg_complexity | multiplier |
|--|--|
| low            | 1.0        |
| med            | 1.15       |
| high           | 1.35       |
| huge           | 1.75       |

### 3. Per-lifecycle-step token computation (Mode C)

For each lifecycle step `s` in
`{interrogate, create, plan, implement, test, review}`:

```
input_tokens(s)  = stories_total
                 x per_story_base
                 x step_multiplier[s]        # see Mode A section 5
                 x complexity_multiplier
output_tokens(s) = input_tokens(s) x output_ratio[model_class(s)]
cost(s)          = (input_tokens(s)  / 1e6) x rate_in [model_class(s)]
                 + (output_tokens(s) / 1e6) x rate_out[model_class(s)]
```

Per-step totals and a grand TOTAL row are both displayed. Hosted-model
classes get a $ column; `local-strong`/`local-fast` rows report token counts
only and write `n/a (local)` in the $ column.

### 4. Pessimistic-then-tightening confidence band

Mode C uses a **wide +/-50% band** initially because no spec-level anchor
exists. The band tightens to **+/-20%** after the first SPEC for the IDEA is
materialized and Mode A runs against it:

| Stage                                                  | Band  |
|--|--|
| Before any SPEC exists for IDEA                        | +/-50%  |
| After Mode A has produced a real estimate for >=1 SPEC  | +/-20%  |

**Tightening trigger mechanism:**

1. Mode C writes `pending_tighten: on-first-spec-creation` into the idea's
   `ROI.md` (Token Budget - idea-scope section) on first run.
2. The first time Mode A runs for any `SPEC-*` traceable to that IDEA, it
   detects the marker, re-runs Mode C internally using that SPEC's Mode A
   totals as an anchor, switches the band to +/-20%, updates the idea-scope
   forecast block in `ROI.md`, and clears the marker.
3. Subsequent Mode C re-runs (e.g. when the human revises the phases/epics
   breakdown) use +/-20% as long as at least one SPEC exists; if all SPECs are
   deleted, the band reverts to +/-50% on the next Mode C run.

### 5. Worked example (Mode C)

IDEA-007: `phases=3`, `epics=6`, `story_points_total=30`,
`avg_complexity=med`.

```
story_points_per_epic_avg = 30 / 6 = 5
stories_total             = 6 x 5  = 30
per_story_base            = 14 000   (med)
complexity_multiplier     = 1.15

Plan step (strong-reasoning, step_multiplier 0.8, output_ratio 0.60):
  input  = 30 x 14000 x 0.8 x 1.15 = 386 400
  output = 386 400 x 0.60          = 231 840
  cost   = (386400 / 1e6) x 15 + (231840 / 1e6) x 75
         = 5.80 + 17.39 = $23.19
  band   = $11.59 - $34.78   (+/-50%)
```

Repeat for each lifecycle step; sum for the IDEA-scope TOTAL.

### 6. Display rule

The Mode C forecast block is displayed in **every** scenario:

- HITL `/idea-interrogator` - awareness, no gate.
- `/auto` Scenario 1 (no flags) - awareness; the standard per-step approval
  gates still apply downstream.
- `/auto` Scenario 2 (`--silent --assume`) - awareness only; the human sees
  the envelope but the run continues silently.
- `/auto` Scenario 3 (`--budget N`) - awareness PLUS a gate. If the Mode C
  TOTAL exceeds the cap, Token Guard emits `auto-policy-cap-exceeded` and
  STOPS for the human.

## Formula (Mode B - free-form prompt estimation)

```
input_tokens  = max(1, ceil(len(prompt_text) / 4))   # ~4 chars per token
output_tokens = input_tokens x output_ratio[model_class]
cost          = (input_tokens  / 1e6) x rate_in
              + (output_tokens / 1e6) x rate_out
```

Apply the same +/-30% band. No risk, no step multipliers - it's a single shot.

---

## Where estimates are recorded

| Sink | Content |
|--|--|
| `specs/IDEA-{ID}-{slug}-Specs/ROADMAP.md` | `Est. tokens` per spec + `## Token Plan` (model/effort copied from `coordination/orchestrator.json`) |
| `Traces/Session-*/TokenUsage.md` | estimates, actuals, auto-approvals, `## Trials counter` |
| `Traces/Session-*/HumanDecisions.md` | human approve / revise / abort |
| `ideation/IDEA-{ID}-{slug}/ROI.md` | Token Budget sections, `pending_tighten` |
| `coordination/backchannel.jsonl` | `estimate-*` events |

Per-spec `budget.md` is retired (legacy v5 specs may still have one; read only).

---

## Default model-class assignment per lifecycle step

Token Guard uses these defaults when neither the spec nor
`coordination/orchestrator.json` (`agents[].spawn`, which wins) specifies otherwise:

| Step        | Default class       | Override hint                                         |
|--|--|--|
| interrogate | `strong-reasoning`  | Drop to `balanced` for trivial ideas                  |
| create      | `strong-reasoning`  | -                                                     |
| plan        | `strong-reasoning`  | -                                                     |
| implement   | `balanced`          | `fast-implementation` for mechanical / boilerplate    |
| test        | `balanced`          | `fast-implementation` if tests are pure assertion runs|
| review      | `strong-reasoning`  | `balanced` for diff-only reviews                      |

---

## Worked example

Spec: `SPEC-007`, `criteria=6`, `files=4`, `risk=med`, `plan_steps=null`,
`dialect_complexity=medium` (no plan yet).

```
base_input = 5000 + (4 x 1500) + (6 x 300) + 0 + 1000
           = 5000 + 6000 + 1800 + 1000
           = 13800 tokens

risk_multiplier = 1.4
complexity_multiplier = 1.15

Plan step (strong-reasoning, ratio 0.60):
  input  = 13800 x 0.8 x 1.4 x 1.15 = 17774
  output = 17774 x 0.60             = 10664
  cost   = (17774 / 1e6) x 15 + (10664 / 1e6) x 75
         = 0.267 + 0.800 = $1.07
  band   = $0.75 - $1.39
```

Repeat for each lifecycle step; sum for the total.

---

## Calibration

The +/-30% band is a **placeholder** until real data accumulates. Token Guard
reads actuals from `Traces/Session-*/TokenUsage.md`. Actuals are trustworthy
only when the harness, API, or an approved meter reports them; agents must not
invent actual token counts. When the harness does not expose token usage, the
row is still recorded with `source: unavailable` and an `unavailable_reason`,
but it is excluded from calibration math.

Calibration procedure:

1. Every model-backed agent return includes the token usage block defined in
   [[trace-layout]]. Butler appends it to `TokenUsage.md`.
2. Token Guard reads new `TokenUsage.md` rows and emits `actual-recorded` for
   each lifecycle step or agent invocation, linking `estimate_event_id` when
   available.
3. For rows with `source` in `harness-reported | api-usage | manual-meter`,
   Token Guard appends a calibration row to `memory/token-actuals.csv` with
   columns: `spec_id, step, agent, model_class, estimate_input,
   estimate_output, actual_input, actual_output, criteria, files, risk,
   plan_steps, dialect_complexity, source`.
4. Periodically (every ~20 usable rows), recompute the per-step multipliers as
   `mean(actual / formula_estimate)` and propose a protocol update. Note the
   calibration date and sample size in a `## Calibration history` section.
5. Tighten the confidence band when stddev drops:
   `band = +/-max(15%, 1.5 x stddev_of_residuals)`.

Until the first calibration pass, multipliers stay as written above and the band stays at +/-30%.

---

## When to re-estimate

The lifecycle requires a fresh `/token-estimate SPEC-{ID}` at these gates.
The estimate must be explicitly approved by the human unless the AutoPolicy
exception below applies:

- Before `/spec-plan` runs - plan steps are unknown, so `plan_steps=null` and the implement-stage number is provisional.
- Before `/spec-implement` runs - by this point the plan exists, so the estimate is materially tighter; the human re-approves against the firmer number.
- After any spec edit that changes `criteria`, `files`, `risk`, selected dialects, or item complexity - the old approval is invalidated.

Mode B (free-form prompts) is one-shot and never persisted.

AutoPolicy exception: an estimate may proceed without a fresh interruption
when the human already approved an upfront `--budget` cap for the current auto
run, the updated cumulative hosted-model spend remains within that cap, the
estimate confidence is at or above the active threshold, and every assumption
used by the estimate is allowed by the AutoPolicy. In that case Token Guard
records `estimate-auto-approved` instead of asking again.

---

## Loop detection

Token Guard maintains a per-spec-per-step **trials counter** in the active
trace `TokenUsage.md` under `## Trials counter` (restore points carry it
across sessions). The counter is incremented each time an agent
re-attempts the same lifecycle step for the same SPEC (e.g. planner re-runs
`plan`, implementer re-runs `implement`, verifier re-runs `test`).

Schema (YAML block, keyed by spec):

```yaml
SPEC-{ID}:
  trials:
    plan: 0
    implement: 0
    test: 0
    review: 0
```

### Trigger

When the counter for any step reaches **3** (the same agent re-attempts the
same step a 3rd time), Token Guard:

1. Emits a `coordination-note` event to `coordination/backchannel.jsonl`
   with `payload.tag = "loop-detected"`, `payload.spec`, `payload.step`,
   `payload.trial_count = 3`, and `payload.guidance =
   "invoke-critical-human-gate"`.
2. The orchestrator MUST invoke `/critical-human-gate` before any further
   attempt at that step. Loop detection is a hard gate, not advisory.
3. On gate resolution:
   - `approve` or `revise` -> reset the counter to 0;
   - `abort` -> leave the counter as-is and emit `estimate-aborted` with
     `reason = "loop-aborted"`.

### Rationale

A 3rd retry on the same step is a strong signal of either a hidden defect,
a model-class mismatch, or an underspecified acceptance criterion. The cost
of one human gate is much smaller than the cost of an unbounded retry loop
burning the AutoPolicy cap.
