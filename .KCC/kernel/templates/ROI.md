---
# Functional fields (none - this is a template; the populated copy carries its own functional state)

# Obsidian metadata (used in the vault, ignored by harness adapters)
title: ROI Template
aliases:
  - roi-template
tags:
  - framework/template
  - lifecycle/interrogate
created: 2026-05-24
updated: 2026-06-06
version: 1.3.0
status: active
copyright: "KCC framework (c) 2026 Tarek Fawaz"
homepage: "https://tikasway.dev/kcc"
license: "Licensed under the terms in LICENSE"
---

# ROI - IDEA-{ID}: {Title}

> Template. Copy to `ideation/IDEA-{ID}-{slug}/ROI.md` and fill in. The Token Budget
> section is populated by the [[token-guard]] agent - humans may edit the rates
> table to drive a recalculation. All other sections are owned by the
> [[idea-interrogator]] agent and the human.

---

## Effort estimate

Developer-time impact of building this idea vs. doing it manually / not at all.

| Item                                | Hours (est.) | Notes                                         |
|--|--|--|
| Implementation effort               | 0            | sum of plan-step estimates                    |
| Maintenance / on-call cost (annual) | 0            | ongoing burden                                |
| Manual work displaced (annual)      | 0            | the thing we stop doing if this ships         |
| **Net hours saved per year**        | **0**        | manual displaced - (impl + maintenance)       |

Convert to dollars at the org's loaded developer rate (e.g. $150/hr):

```
net_value_per_year = net_hours_saved x loaded_rate
```

---

## Token Budget

> Owned by `token-guard`. Humans may edit the **Assumed rates** table; the
> agent will recalculate on the next `/token-estimate` run.
>
> Rates assumed, update as needed. Last reviewed: 2026-05-24.

### Assumed rates (per 1M tokens)

| Model class           | Input ($) | Output ($) | Notes                                              |
|--|--|--|--|
| `strong-reasoning`    | 15.00     | 75.00      | Claude Opus 4.7 / GPT-5.x list price tier          |
| `balanced`            | 3.00      | 15.00      | Claude Sonnet 4.6 / GPT-5 mini                     |
| `fast-implementation` | 0.80      | 4.00       | Claude Haiku 4.5 / GPT-5 nano                      |
| `local-strong`        | 0.00      | 0.00       | Ollama; add infra-cost placeholder below if needed |
| `local-fast`          | 0.00      | 0.00       | Ollama                                             |

Local infra-cost placeholder (optional, $ per hour of GPU time):

| Class          | $/hr   | Avg. step duration (min) | Effective $/step |
|--|--|--|--|
| `local-strong` | 0.00   | 0                        | 0.00             |
| `local-fast`   | 0.00   | 0                        | 0.00             |

### Token Budget - idea-scope (upfront forecast)

> Owned by `token-guard` (Mode C - estimate-idea-scope). Produced by
> `/idea-interrogator` after the phases + epics breakdown is drafted, and
> consumed by `/auto` for display in every scenario. This is the
> **pessimistic upfront** envelope for the whole IDEA - wide +/-50% band
> initially, tightens to +/-20% after the first SPEC is created.

Inputs: phases=0, epics=0, total story points=0, avg complexity=med
Confidence band: +/-50% (will tighten to +/-20% after the first SPEC is created)
Tightening trigger: `pending_tighten: on-first-spec-creation`

| Step        | Per-step total tokens | Per-step ($) | Per-step band   |
|--|--|--|--|
| interrogate | 0                     | 0.00         | 0.00 - 0.00     |
| create      | 0                     | 0.00         | 0.00 - 0.00     |
| plan        | 0                     | 0.00         | 0.00 - 0.00     |
| implement   | 0                     | 0.00         | 0.00 - 0.00     |
| test        | 0                     | 0.00         | 0.00 - 0.00     |
| review      | 0                     | 0.00         | 0.00 - 0.00     |
| **TOTAL**   | **0**                 | **0.00**     | **0.00 - 0.00** |

> Local-class steps (if any) report token counts only; no $ conversion.
> Band will tighten to +/-20% once the first SPEC for this IDEA is created
> and Mode A produces a real anchor.

### Forecast by lifecycle step

> Populated by `token-guard`. Each row is one lifecycle step for one spec.
> When a spec gets re-estimated, append a new dated row and mark the old as
> `superseded`.

| Date       | Spec       | Step        | Model class       | Input tokens | Output tokens | Est. cost ($) | Band (+/-30%)   | Status     |
|--|--|--|--|--|--|--|--|--|
| YYYY-MM-DD | SPEC-XXX   | interrogate | strong-reasoning  | 0            | 0             | 0.00          | 0.00 - 0.00   | current    |
| YYYY-MM-DD | SPEC-XXX   | create      | strong-reasoning  | 0            | 0             | 0.00          | 0.00 - 0.00   | current    |
| YYYY-MM-DD | SPEC-XXX   | plan        | strong-reasoning  | 0            | 0             | 0.00          | 0.00 - 0.00   | current    |
| YYYY-MM-DD | SPEC-XXX   | implement   | balanced          | 0            | 0             | 0.00          | 0.00 - 0.00   | current    |
| YYYY-MM-DD | SPEC-XXX   | test        | balanced          | 0            | 0             | 0.00          | 0.00 - 0.00   | current    |
| YYYY-MM-DD | SPEC-XXX   | review      | strong-reasoning  | 0            | 0             | 0.00          | 0.00 - 0.00   | current    |
| YYYY-MM-DD | SPEC-XXX   | implement   | local-strong      | 0            | 0             | n/a (local)   | 0.00 - 0.00   | current    |
| YYYY-MM-DD | SPEC-XXX   | implement   | local-fast        | 0            | 0             | n/a (local)   | 0.00 - 0.00   | current    |

> Local model rows track token counts only; infra cost is tracked separately in coordination/ if needed.

### Per-model-class subtotals

| Model class           | Input tokens | Output tokens | Cost ($)    |
|--|--|--|--|
| `strong-reasoning`    | 0            | 0             | 0.00        |
| `balanced`            | 0            | 0             | 0.00        |
| `fast-implementation` | 0            | 0             | 0.00        |
| `local-strong`        | 0            | 0             | n/a (local) |
| `local-fast`          | 0            | 0             | n/a (local) |
| **TOTAL**             | **0**        | **0**         | **0.00**    |

---

## Risk-adjusted value

Discount the net value by the probability the idea actually delivers.

| Factor                         | Value | Notes                                                |
|--|--|--|
| Probability of shipping (0-1)  | 0.0   | based on spec risk + dependency count                |
| Probability of adoption (0-1)  | 0.0   | will the displaced manual work actually go away?     |
| Combined success probability   | 0.0   | product of the two                                   |

```
risk_adjusted_value = net_value_per_year x combined_success_probability
```

---

## Final ROI score

```
total_cost      = build_effort_$ + token_budget_$ + (year_1_maintenance_$)
total_benefit   = risk_adjusted_value  (year 1)
roi_year_1      = (total_benefit - total_cost) / total_cost
payback_months  = total_cost / (risk_adjusted_value / 12)
```

| Metric           | Value | Verdict (>0.5 = green, 0-0.5 = amber, <0 = red) |
|--|--|--|
| Total cost ($)   | 0.00  |                                                  |
| Total benefit ($)| 0.00  |                                                  |
| ROI (year 1)     | 0.00  |                                                  |
| Payback (months) | 0.00  |                                                  |

### ROI confidence

> Owned by `idea-interrogator`. Record an explicit **percentage** (not just a
> word). Map the qualitative band to a number: **High = 80%**, **Medium = 60%**,
> **Low = 40%** (an intermediate % is allowed when the evidence warrants).
> Mirror this value into `idea-{ID}-{slug}.md` and the `ROI confidence` column
> of `ideation/ideas.md`.

| Field              | Value      | Reasoning                                  |
|--|--|--|
| ROI confidence band| High/Med/Low |                                          |
| ROI confidence (%) | 0          | strength of evidence, unverified assumptions, market/feasibility uncertainty |

> **ROI gate (silent mode):** if ROI confidence is **< 60%**, an
> `auto --silent --assume` run must NOT proceed silently. The idea-interrogator
> flags `ROI confidence below 60% - ROI gate required` here (with the
> documented assumptions and at least two alternatives), and the `/auto` skill
> escalates via `/critical-human-gate` (`mode: roi-gate`) for a
> `proceed / revise scope / abort` decision. This 60% ROI gate is distinct from
> the per-decision 95% accuracy/confidence gate. See
> [[../protocols/confidence-gate|confidence-gate]].

### Decision

> One of: `proceed`, `defer`, `kill`. Recorded by the human after reviewing the
> table above. If `proceed`, the idea moves to `/spec-create`.
