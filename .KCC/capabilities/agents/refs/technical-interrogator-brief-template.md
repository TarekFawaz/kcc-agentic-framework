---
title: Technical Interrogator Brief Template
tags:
  - framework/agent-ref
updated: 2026-09-21
---

# Technical Interrogator Brief Template

## Output Layout

```text
ideation/IDEA-{ID}-{slug}/
|-- TechnicalQuestionnaire.md
|-- TechnicalAnswers.md
`-- TechnicalDecisionBrief.md
```

## TechnicalDecisionBrief.md

```markdown
# Technical Decision Brief

## Source
{idea/spec links}

## Confirmed Decisions
- ...

## Architecture Depth
{minimal | standard | distributed | regulated, with human consent source}

## Architecture Style
{Clean Architecture + DDD (default for backend/service/API/fullstack) |
event-driven (default for IoT/sensor/streaming) | simpler opt-down (static /
frontend-only / trivial - requires an architect ADR). Record the choice + who
chose it. See [[.KCC/kernel/protocols/architecture-styles]].}

## API Standard
{Applies when the idea exposes an HTTP/REST API. Default: OpenAPI 3.x document +
served Swagger UI (default `/docs`) + verifier-checked route conformance. Record
"default accepted" or "waived: {rationale}" (waiver becomes a candidate ADR).
n/a when no HTTP API. See [[.KCC/kernel/protocols/api-standards]].}

## Tech Stack
- Selected: ...
- Alternatives considered: ...
- Maintenance/cost notes: ...

## Candidate Dialects
| Workstream | Dialect | Complexity | Rationale |
|--|--|--|--|
| ... | ... | ... | ... |

## Open Decisions
- ...

## Architecture Risks
- ...

## Candidate ADRs
- ...

## Candidate Guardrails
- ...

## Candidate Quality Gates
- ...

## Architect Handoff
{What architect should decide/write next}

## Confidence
Confidence: NN%

## Related
- Idea: [[idea-{ID}-{slug}]]
- Architecture governance: [[.KCC/kernel/protocols/architecture-governance]]
- Architecture styles: [[.KCC/kernel/protocols/architecture-styles]]
- API standards: [[.KCC/kernel/protocols/api-standards]]
- Dialect registry: [[.KCC/kernel/protocols/dialects/dialect-registry]]
```

## Tech-Stack Challenge Examples

- Small CLI tool: challenge "Java" with Go or Rust (single binary, no JVM
  dependency, simpler distribution).
- Low-traffic internal API: challenge "microservices on Kubernetes" with a
  single monolithic Node service on a PaaS.
