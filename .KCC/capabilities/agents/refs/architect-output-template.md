---
title: Architect Output Template
tags:
  - framework/agent-ref
updated: 2026-09-21
---

# Architect Output Template

## Response structure

Structure your response as:

### Decision Required
{One-sentence statement of what needs to be decided}

### Active depth
`lite` | `standard` | `deep` - sourced from {idea file path or "default standard (documented in assumptions.md)"}

### Inputs Read
- Technical decision brief: {path or "missing"}
- UX / Security / Infrastructure briefs: {paths or "n/a"}
- Specs/ideas: {links}
- Existing ADRs/gates: {links}

### Options Analyzed
For each option:
- **Option N: {Name}**
  - How it works: {brief description}
  - Pros: {list}
  - Cons: {list}
  - Impact on guardrails: {which guardrails affected and how}
  - Impact on quality gates: {which gates affected and how}
  - Impact on fitness functions / budgets / NFRs: {which and how}

### Recommendation
{Which option and why - tie to project constraints, fitness functions, and budgets}

### Files Written
- `architecture/architecture.md` (Architecture Document - narrative + embedded diagrams)
- `architecture/c4-context.md`
- `architecture/c4-container.md`
- `architecture/c4-component.md` (deep)
- `architecture/sequences/{name}.md` (deep)
- `architecture/flowcharts/{workflow}.md`
- `architecture/dfds/{flow}.md` (standard/deep when applicable)
- `architecture/fitness-functions.md`
- `architecture/technical-budgets.md`
- `architecture/nfrs.md`
- `architecture/guardrails.md`
- `architecture/quality-gates.md`
- `architecture/adrs/ADR-000N-{slug}.md`
- `architecture/assumptions.md` (silent runs)
- `specs/IDEA-{ID}-{slug}-Specs/SPEC-{ID}-{slug}/arch.md`

### Required artifacts (checklist for active depth)
- [x] Architecture Document -> `architecture/architecture.md` (narrative + diagrams embedded inline with `Source:` citations)
- [x] Context diagram -> `architecture/c4-context.md` (embedded in the Architecture Document)
- [x] Container diagram -> `architecture/c4-container.md` (embedded)
- [ ] Component diagram (deep only)
- [x] At least one business-workflow flowchart (embedded)
- [ ] DFD(s) for non-trivial data flow (embedded)
- [x] Fitness functions / technical budgets / NFRs
- [x] Spec-local `arch.md` for each impacted spec (>=1 embedded mermaid block + design narrative; not a link-only stub)
- [x] Silent-mode assumptions logged (if applicable)

### Assumptions (silent runs only)
{Bulleted list of low-risk assumptions made; each links to its row in
`architecture/assumptions.md`}

### Risks
{What could go wrong with the recommended approach}

### Impacted Services/Files
{Cross-service impact map}

### Confidence
Confidence: NN%

## Required artifacts per depth (agent copy)

The authoritative matrix is `.KCC/kernel/protocols/architecture-documentation.md`
-> *Required artifacts matrix per depth*. Agent copy kept verbatim:

| Artifact | `lite` | `standard` | `deep` |
|--|:------:|:----------:|:------:|
| `architecture/architecture.md` (Architecture Document - narrative + embedded diagrams) | required | required | required |
| `architecture/c4-context.md` (Mermaid `C4Context` source) | required | required | required |
| `architecture/c4-container.md` (Mermaid `C4Container` source) | optional | required | required |
| `architecture/c4-component.md` (Mermaid `C4Component` source) | - | optional | required |
| `architecture/sequences/*.md` (Mermaid sequence source) | - | optional | required (per cross-service flow) |
| `architecture/flowcharts/*.md` (Mermaid flowchart source - business workflow) | required (>=1) | required (>=1 per workflow) | required (>=1 per workflow) |
| `architecture/dfds/*.md` (Mermaid flowchart source - DFD conventions) | - | required when data flow is non-trivial | required (>=1 per data flow) |
| `architecture/fitness-functions.md` | required | required | required |
| `architecture/technical-budgets.md` | required | required | required |
| `architecture/nfrs.md` | required | required | required |
| `architecture/guardrails.md` | required (when any ADR exists) | required | required |
| `architecture/quality-gates.md` | required (when any ADR exists) | required | required |
| `architecture/adrs/ADR-000N-{slug}.md` | per decision | per decision | per decision |
| Spec-local `arch.md` per impacted spec (embeds diagrams inline - not links; >=1 mermaid block) | required | required | required |
| `architecture/assumptions.md` (silent runs) | required when `--silent --assume` | required when `--silent --assume` | required when `--silent --assume` |
