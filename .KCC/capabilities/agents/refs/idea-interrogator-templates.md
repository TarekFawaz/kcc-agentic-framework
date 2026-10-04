---
title: Idea Interrogator Templates
tags:
  - framework/agent-ref
updated: 2026-09-21
---

# Idea Interrogator Templates

## Architecture Depth

| Depth | Use for |
|--|--|
| `minimal` | CLI, script, local tool, documentation-only change. |
| `standard` | App/API/service with users, persistence, or integrations. |
| `distributed` | Multiple services, event-driven flows, scale, or cloud/on-prem infrastructure decisions. |
| `regulated` | Sensitive data, compliance, strict audit, high availability, or DR concerns. |

## Foundational Questions

- Q1 - Problem: what pain are we solving, for whom, and what evidence shows it exists?
- Q2 - Outcome: what does success look like in measurable terms?
- Q3 - Audience: who are the primary users, at what scale, and how willing are they to adopt?
- Q4 - Scope and non-goals: what is explicitly in vs. out of the first version?
- Q5 - Constraints: budget, timeline, regulatory, tech-stack, and must-integrate systems?
- Q6 - Feasibility: is this technically doable inside the available time/skill window, and what would make it not?
- Q7 - Viability: is the audience real, reachable, and willing to adopt - what evidence?
- Q8 - Economic worth: is the build + run cost worth the value, at best/likely/worst case?

Risks, deeper ROI inputs, and sub-areas become follow-up batches.

## Epics Table

```markdown
| Phase | Epic (likely SPEC) | One-line description |
|--|--|--|
| 1     | Cli skeleton       | Bootstrap the CLI with parsing + tests. |
```

## Effort Estimate

Story points (1, 2, 3, 5, 8, 13) x complexity factor (`low` x1.0, `medium`
x1.5, `high` x2.0, `extra-high` x3.0). Default rate: 1 SP = 0.5 man-days at
medium complexity. Display +/-20%.

```markdown
## Effort Estimate

| Phase | Epic | Story points | Complexity | Estimate (man-days, +/-20%) |
|--|--|--|--|--|
| 1     | ...  | 5            | medium     | 2.5 +/- 0.5                  |

Total: {N} man-days (~{N/5} weeks at 1 FTE), +/-20% band.
```

## Upfront Budget

From `/token-estimate` idea-scope mode (pessimistic +/-50%; tightens to
+/-20% after SPEC-001 lands).

```markdown
## Upfront Budget

| Lifecycle step | Tokens (low / mid / high) | $ (low / mid / high) |
|--|--|--|
| interrogate    | ...                        | ...                  |
| plan           | ...                        | ...                  |
| implement      | ...                        | ...                  |
| test           | ...                        | ...                  |
| review         | ...                        | ...                  |
| **total**      | ...                        | ...                  |

Source: `/token-estimate` idea-scope forecast. Tightens to +/-20% after
SPEC-001 lands.
```

## SpecWriterStarter Contents

- Source idea link: `[[idea-{ID}-{slug}]]`.
- Recommended first epic/spec title and one-line description.
- Other likely epics/specs, copied from Phases / Epics.
- Problem statement copied or summarized from `Conclusion.md`.
- Seed epic acceptance criteria.
- Seed backlog candidates: user-facing stories ("As a / I want / so that"
  where possible); technical enablers needed to make them shippable.
- Likely impacted areas.
- Dependencies and unknowns the spec-writer should resolve.
- Pointers to `TechnicalDecisionBrief.md`, `UXDecisionBrief.md`,
  `SecurityDecisionBrief.md`, `InfrastructureDecisionBrief.md` (if present).
- `## Recommended specialist interrogations`: each specialist that must run,
  one-line trigger reason each. Recommend `/infrastructure-interrogator` for
  ANY deployable, production-ready, hostable, distributable, API, service,
  packaging, cloud, or on-prem work; omit only for pure local one-off scripts,
  docs-only changes, or explicit throwaway prototypes.
- Effort + Upfront Budget copied from `idea-{ID}-{slug}.md`.

## Conclusion Contents

- One-paragraph problem statement.
- One-paragraph proposed solution shape.
- Go / no-go recommendation with reasoning.
- Top 3 risks and mitigations.
- What we still do not know.
