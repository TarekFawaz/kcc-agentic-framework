---
title: Architecture Critic Report Template
tags:
  - framework/agent-ref
updated: 2026-09-21
---

# Architecture Critic Report Template

## Report

### Verdict
**CONFORMANT** or **DRIFT**

### Active depth
`lite` | `standard` | `deep` - sourced from {idea file path or "default standard"}

### Findings
(empty when CONFORMANT)

| # | Issue (what is wrong) | Standard rule violated | Required fix |
|---|--|--|--|
| 1 | `architecture.md` is a 1.3 KB link hub; Context/Containers sections are headers with no prose | architecture-documentation - "Architecture Document, not a MOC; sections need real prose" | Rewrite `architecture.md` as the narrative design document with explanatory prose per section, embedding each diagram inline |
| 2 | `.mmd` files under `architecture/diagrams/` | architecture-documentation - diagram storage rule (no `.mmd`, no `diagrams/`) | Delete `diagrams/`; recreate each diagram as a named `architecture/*.md` source and embed inline with a `Source:` citation |
| 3 | `fitness-functions.md` / `nfrs.md` / `technical-budgets.md` missing or empty | architecture-documentation - required-artifacts matrix (mandatory every depth) | Author each with substantive, objective content for this idea |

### Semantic-fit note
{One-paragraph judgment: does the chosen style/stack actually fit the idea, or is it a degraded placeholder? Cite the style rule + idea evidence.}

### Confidence
Confidence: NN%
