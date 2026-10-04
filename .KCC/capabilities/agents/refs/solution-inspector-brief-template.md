---
title: Solution Inspector Brief Template
tags:
  - framework/agent-ref
updated: 2026-09-21
---

# Solution Inspector Brief Template

## SolutionInspectionBrief.md

```markdown
# Solution Inspection Brief

## Source
- Target path: {absolute or repo-relative}
- Depth: {minimal | standard | deep}
- Cartographer baseline: [[solution|solution.md]] (or "not yet produced")

## Detected Topology
- Repo identity: {git remote name + URL}
- Last commit: {short SHA + title}
- Sibling repos detected: {list or "none"}
- Monorepo markers detected: {list or "none"}
- Initial hypothesis: {single-repo | multi-repo | monorepo}

## Declared Topology (Human Answers)
- W1 Topology: {answer}
- W2 Repositories: {table}
- W3 Cross-repo dependencies: {table or prose}
- W4 Tracker integration: {choice + notes}
- W5 Model-class overrides: {map or "none"}
- W6 AutoPolicy defaults: {settings or "default"}

## Conflicts Between Detected and Declared
- {explicit conflict, or "none"}

## Settings Written
- `.KCC/settings.json` updated keys: {list of JSON paths updated}

## Confidence
Confidence: NN%

## Related
- Cartographer baseline: [[solution|solution.md]]
- Workspace protocol: [[.KCC/kernel/protocols/workspace]]
- Onboarding protocol: [[.KCC/kernel/protocols/solution-onboarding]]
```
