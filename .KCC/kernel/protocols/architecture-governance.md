---
# Functional fields
description: Global architecture decision, guardrail, and quality-gate convention.
inputs: Technical decision brief, architecture analysis, and project constraints.
outputs: Global ADRs, guardrails, quality gates, and the Architecture Document under `architecture/`.

# Obsidian metadata
title: "Architecture Governance Protocol"
aliases:
  - architecture-governance
  - adr-layout
  - guardrails
  - quality-gates
tags:
  - framework/protocol
  - architecture
  - documentation
  - kcc/v04
created: 2026-05-24
updated: 2026-06-06
version: 1.6.0
status: active
copyright: "KCC framework (c) 2026 Tarek Fawaz"
homepage: "https://tikasway.dev/kcc"
license: "Licensed under the terms in LICENSE"
---

# Architecture Governance

Architecture decisions are global project assets. The **architect** agent owns
these files:

```text
architecture/
|-- architecture.md          <- the Architecture Document (narrative + embedded diagrams; NOT a MOC)
|-- guardrails.md
|-- quality-gates.md
|-- c4-context.md            <- named Mermaid diagram source (.md, one fenced block)
|-- c4-container.md
|-- flowcharts/{name}.md
|-- dfds/{name}.md
|-- sequences/{name}.md
`-- adrs/
    |-- adrs.md
    `-- ADR-0001-{slug}.md
```

`architecture/architecture.md` is **the Architecture Document** - a readable
narrative design document that SHOWS the design inline, not a MOC / link hub.
Two rules apply (full detail in [[architecture-documentation]]):

- **Embed rule.** Every diagram referenced in `architecture.md` (and in a
  spec's `arch.md`) appears as an inline fenced ```mermaid``` block with a
  `Source: [[file]]` citation - never a bare link in place of the diagram.
- **Diagram storage rule.** Named diagram source files are `.md` (single
  source of truth), never `.mmd`, with no `architecture/diagrams/` subfolder.
  The legacy `diagrams/` folder and raw `.mmd` files are deprecated.

Spec-local architecture lives in a spec folder as `arch.md` - a real per-spec
design document that embeds the spec's slice of the design inline (fenced
mermaid + prose), never a link-only stub. Durable decisions, guardrails, and
gates must still be written globally.

---

## Technical Decision Brief

Before `/spec-create` writes an epic spec, `/technical-interrogator` collects
technical inputs from the human and writes `TechnicalDecisionBrief.md` in the
source idea folder when one exists. For ad-hoc specs, the brief is passed to
the spec-writer and architect as session context.

The architect reads this brief before creating ADRs or gates.

---

## Default architecture style

The architect selects an architecture style per
[[architecture-styles]] using this default rule:

- **backend / service / API / fullstack -> Clean Architecture + DDD** (layered
  domain / application / infrastructure / interface, bounded contexts,
  ubiquitous language, dependency rule pointing inward).
- **IoT / sensor / streaming / real-time ingestion -> event-driven** (events,
  brokers, producers/consumers, eventual consistency).
- **static / frontend-only / trivial tool -> may opt down** to a simpler style,
  but ONLY with an ADR recording the choice + rationale.

The chosen style is stated in `architecture/architecture.md` and shapes the C4
container/component diagrams and each spec's `arch.md`. Any opt-down from the
default requires an ADR; without one, the default style stands. Full rule in
[[architecture-styles]].

## Default API standard

When the solution exposes an HTTP/REST API, the architecture and quality gates
MUST require the framework's default API standard per [[api-standards]]: an
OpenAPI 3.x document (the source of truth for the contract), a served Swagger UI
(default `/docs`), and verifier-checked route/verb/schema conformance. The
architect adds an API conformance quality gate (e.g. `QG-API-CONFORMANCE`) to
`architecture/quality-gates.md`. The default is waivable only with an explicit
ADR naming a non-HTTP interface and its alternative contract mechanism. Full
rule in [[api-standards]].

---

## Stack changes are ADR-gated

The architecture document (`architecture/architecture.md`) and the architecture
ADR(s) are the **single source of truth for the technology stack** - languages,
frameworks, API style, persistence/datastore, and architecture style
(Clean/DDD, event-driven, static, etc.). The planner, implementer, and verifier
all follow this declared stack.

- **Any change to the declared stack or architecture style requires a new or
  updated ADR plus explicit human approval.** This includes swapping a language
  or framework, changing the API style, replacing the datastore, or opting into
  a different architecture style than the one recorded.
- **A stack change is a prohibited silent assumption.** Under
  `auto --silent --assume`, the architect MUST NOT silently rewrite the stack.
  It may record a `Proposed` ADR documenting the proposed change, but that ADR
  does not authorize divergence until a human accepts it. Until then the
  original declared stack stands.
- **A missing toolchain is NOT grounds for a silent stack change.** When a
  required tool is absent, the resolution is the toolchain install/defer gate in
  [[toolchain-preflight]] - install, request human install, or defer. Deferring
  means "the declared stack was written but not built/run," NOT "a different
  stack was built." The declared stack remains intact through a deferral.
- **The verifier enforces conformance via `QG-ARCH-CONFORMANCE`.** It reads the
  declared stack from `architecture/architecture.md` + the relevant ADR(s) and
  compares it against what was actually implemented under `src/IDEA-{ID}-{slug}/`
  (package manifests, file types, framework imports, datastore integration). Any
  mismatch is **CHANGES_NEEDED** unless an Accepted (or Proposed +
  human-approved) ADR documents the divergence. A `TOOLCHAIN_DEFERRED` verdict
  does **not** excuse a stack mismatch: if a *different* stack from the ADR was
  actually built, that is a conformance failure regardless of toolchain state.

Add the gate to `architecture/quality-gates.md`:

| ID | Gate | Evidence required | Applies to | Source ADR | Status |
|--|--|--|--|--|--|
| QG-ARCH-CONFORMANCE | Implemented stack matches the declared architecture ADR stack | Declared stack (languages/frameworks/API style/persistence/architecture style) from `architecture.md` + ADR(s) vs implemented stack under `src/IDEA-{ID}-{slug}/`; divergence allowed only with an approved ADR | every spec | the relevant architecture ADR | active |

Cross-references: [[toolchain-preflight]], [[architecture-styles]],
[[api-standards]].

---

The human controls architecture depth at idea introduction. Minimal ideas do
not require deep architecture artifacts unless risk, data sensitivity, or human
direction asks for them, but every depth requires at least lightweight Mermaid
diagrams. Distributed or regulated ideas should receive fuller architecture
treatment, including trade-offs, diagrams, guardrails, and gates.

## Required Mermaid Diagrams

The architect writes each diagram as a named `.md` source file (one fenced
```mermaid``` block per file) under `architecture/` and its `flowcharts/`,
`dfds/`, `sequences/` subfolders. **No `.mmd` files; no `diagrams/` folder**
(both deprecated). The `lite` / `standard` / `deep` matrix in
[[architecture-documentation]] is the authoritative per-depth diagram list; the
legacy `minimal` / `distributed` / `regulated` mapping below is kept for
backward compatibility only.

| Depth (legacy) | Required diagrams |
|--|--|
| `minimal` | context, runtime-flow |
| `standard` | context, component-flow, runtime-flow |
| `distributed` | Standard diagrams plus deployment, integration/event, and data-flow diagrams as relevant |
| `regulated` | Distributed diagrams plus trust-boundary, data-sensitivity, security-flow, and DR/SLO diagrams |

Rules:

- Diagrams must be valid Mermaid.
- Diagrams should be simple enough to maintain.
- `architecture/architecture.md` (the Architecture Document) **embeds** every
  diagram inline as a fenced ```mermaid``` block with a `Source: [[file]]`
  citation - it does not merely link them.
- Verifier checks that diagrams exist for the selected depth and are embedded
  in the Architecture Document and spec `arch.md` before approving
  architecture-sensitive specs.

---

## Required artifacts per depth

The `lite` / `standard` / `deep` taxonomy is the depth dialect used by the
KCC v0.4 always-on architecture flow. Each depth level requires a specific
set of artifacts under `architecture/`. The architect agent emits a
`## Required artifacts` checklist at the end of every run that ticks each
of these boxes.

| Artifact | `lite` | `standard` | `deep` |
|--|:------:|:----------:|:------:|
| `architecture/architecture.md` (Architecture Document - narrative + embedded diagrams) | required | required | required |
| `architecture/c4-context.md` (Mermaid `C4Context` source) | required | required | required |
| `architecture/c4-container.md` (Mermaid `C4Container` source) | optional | required | required |
| `architecture/c4-component.md` (Mermaid `C4Component` source) | - | optional | required |
| `architecture/sequences/*.md` (Mermaid sequence source) | - | optional | required (per cross-service flow) |
| `architecture/flowcharts/*.md` (Mermaid flowchart source - business workflow) | required (>=1) | required (>=1 per workflow) | required (>=1 per workflow) |
| `architecture/dfds/*.md` (Mermaid flowchart source with DFD conventions) | - | required when data flow is non-trivial | required (>=1 per data flow) |
| `architecture/fitness-functions.md` | required | required | required |
| `architecture/technical-budgets.md` | required | required | required |
| `architecture/nfrs.md` | required | required | required |
| `architecture/guardrails.md` | required (when any ADR exists) | required | required |
| `architecture/quality-gates.md` | required (when any ADR exists) | required | required |
| `architecture/adrs/ADR-000N-{slug}.md` | per decision | per decision | per decision |
| Spec-local `arch.md` per impacted spec (embeds diagrams inline - not links) | required | required | required |
| `architecture/assumptions.md` | required when `auto --silent --assume` | required when `auto --silent --assume` | required when `auto --silent --assume` |

Depth declaration lives in `ideation/IDEA-{ID}-{slug}/idea-{ID}-{slug}.md`
(frontmatter `architecture-depth` or `## Architecture depth` section). When
unset, the architect defaults to `standard` and records the default in
`architecture/assumptions.md`.

The legacy `minimal` / `distributed` / `regulated` depths above are kept
for backward compatibility with v0.3 ideas. New ideas use the
`lite` / `standard` / `deep` axis. Mapping is straightforward: `minimal ->
lite`, `standard -> standard`, `distributed -> deep`, `regulated -> deep` (plus
the security-flow / DR / data-sensitivity diagrams from the regulated row,
which become deep-level extras).

See [[architecture-documentation]] for the full how-to (Mermaid syntax,
filenames, templates).

---

## Mermaid-only convention

Mermaid is the only diagram dialect this framework accepts. Rationale:

- **Obsidian renders Mermaid natively.** No external tools, no PNG exports,
  no broken renderings in someone else's vault.
- **One dialect to learn.** Architect, planner, implementer, and verifier
  all read and write the same syntax.
- **AI-friendly.** Mermaid round-trips cleanly through agents; PlantUML and
  binary formats do not.
- **Flowcharts substitute for BPMN.** Per the user's documentation
  decision, business workflows use Mermaid `flowchart` blocks - NO BPMN.
  The flowchart template (`.KCC/kernel/templates/flowchart-business.md`)
  shows the convention.
- **DFDs use Mermaid flowcharts too.** The DFD template
  (`.KCC/kernel/templates/dfd.md`) uses Mermaid `flowchart TD` with shape
  conventions (rectangles = processes, cylinders = stores, parallelograms =
  external entities). No separate DFD dialect.

What this rules out:

- No PlantUML.
- No draw.io / Lucid / Visio binaries committed to the repo.
- No BPMN XML / BPMN-rendered images.
- No `.png` / `.jpg` diagrams except as an illustrative complement to a
  Mermaid source-of-truth.

---

## How architect outputs flow into the spec lifecycle

The architect's outputs are not stand-alone documents - they are inputs to
the rest of the lifecycle. The flow is:

```text
architect agent
   |
   |--> writes architecture/c4-context.md
   |--> writes architecture/c4-container.md
   |--> writes architecture/c4-component.md         (deep)
   |--> writes architecture/flowcharts/*.md         (business workflows)
   |--> writes architecture/dfds/*.md               (data flows)
   |--> writes architecture/sequences/*.md          (deep, cross-service)
   |--> writes architecture/fitness-functions.md
   |--> writes architecture/technical-budgets.md
   |--> writes architecture/nfrs.md
   |--> writes architecture/guardrails.md           (when any ADR exists)
   |--> writes architecture/quality-gates.md        (when any ADR exists)
   |--> writes architecture/adrs/ADR-000N-*.md      (per decision)
   |--> writes architecture/assumptions.md          (silent runs)
   |--> writes specs/IDEA-*-Specs/SPEC-*/arch.md    (per impacted spec)
              |
              v
       planner agent reads:
         - architecture/architecture.md (Architecture Document)
         - architecture/c4-*.md
         - architecture/fitness-functions.md
         - architecture/technical-budgets.md
         - architecture/nfrs.md
         - architecture/guardrails.md
         - architecture/quality-gates.md
         - spec-local arch.md
              |
              v
       planner agent writes plan.md, citing:
         - C4 component names where changes are scoped
         - ADR IDs that justify ordering
         - fitness functions / NFRs / budgets the implementation must respect
         - guardrails and quality gates the verifier will enforce
              |
              v
       implementer reads plan.md (and spec-local arch.md), writes code
              |
              v
       verifier reads architecture/quality-gates.md +
                architecture/fitness-functions.md and enforces them per AC
```

Trace-chain rule: the spec-local `arch.md` is the single point that
cross-references the global architecture from inside the spec folder. Stories
and enablers do not link to `architecture/` directly; they go through the
spec folder note, which links to `arch.md`, which links to the global
artifacts.

In `auto --silent --assume` mode, the same flow applies, but the architect
documents low-risk assumptions in `architecture/assumptions.md` and keeps
ADR `Status: Proposed` until the human confirms. The planner still reads
everything as-is; the verifier flags any `Proposed`-status ADR that gated a
quality check.

---

## ADR Shape

ADR files live under `architecture/adrs/` and use this name:

```text
ADR-0001-{decision-slug}.md
```

Each ADR contains:

```markdown
# ADR-0001: {Decision Title}

## Status
Proposed | Accepted | Superseded | Deprecated

## Context
{Forces, constraints, technical decision brief inputs, related specs}

## Decision
{The decision}

## Options Considered
| Option | Pros | Cons | Why not |
|--|--|--|--|

## Consequences
{Positive, negative, and follow-up impacts}

## Guardrails Added
- [[../guardrails|Guardrail name]]

## Quality Gates Added
- [[../quality-gates|Gate name]]

## Related
- Architecture Document: [[../architecture]]
- ADR index: [[adrs]]
- Related spec: {folder-note link}
```

---

## Guardrails

`architecture/guardrails.md` captures design constraints that future agents
must obey unless a new ADR explicitly changes them. Guardrails should be short,
stable, and actionable.

Use this table:

| ID | Guardrail | Applies to | Source ADR | Status |
|--|--|--|--|--|
| GR-001 | {rule} | {scope} | [[adrs/ADR-0001-example|ADR-0001]] | active |

---

## Quality Gates

`architecture/quality-gates.md` captures objective checks. Verifier and planner
must read this file for every spec.

Use this table:

| ID | Gate | Evidence required | Applies to | Source ADR | Status |
|--|--|--|--|--|--|
| QG-001 | {testable gate} | {test, command, metric, review evidence} | {scope} | [[adrs/ADR-0001-example|ADR-0001]] | active |

### Quality gate catalog (framework defaults)

The architect copies every gate that applies into `architecture/quality-gates.md`.
The verifier enforces them. A gate can be dropped only through an ADR.

| ID | Gate | Evidence (mechanical where possible) | Applies to |
|--|--|--|--|
| QG-ARCH-CONFORMANCE | The implemented stack matches the ADR-declared stack | Declared vs implemented languages, frameworks, API style, persistence | every spec |
| QG-ARCH-DOCS | The architecture docs are reviewed and substantive | architecture-critic verdict **CONFORMANT** on record (or a human override); `architecture/architecture.md` is a narrative document, not a hub or a sub-1 KB stub; diagrams are embedded ```mermaid``` blocks with a `Source:` line; **no** `.mmd` files and **no** `architecture/diagrams/`; the supporting docs for the active depth are present and substantive (`fitness-functions.md`, `nfrs.md`, `technical-budgets.md`, `guardrails.md`, `quality-gates.md`, `adrs/` + `adrs.md`); `check-run-conformance -Scope architecture` exits 0 | every spec |
| QG-TRACE | Every AC is proven by a passing test | `check-traceability -Spec` exits 0 | every spec |
| QG-QUALITY | Build, lint, tests, coverage floor, lockfile, secrets, dependency audit, SAST | `quality-gate -Spec` exits 0 (exit 3 = deferred, **not** a pass). Coverage floor: `.KCC/settings.json` -> `quality.coverage_min_pct` (default 80) unless this file sets `coverage_min_pct: NN` | every spec with code |
| QG-PROD | Production readiness | Health/readiness endpoint or CLI self-check; structured logging with no secrets in logs; configuration from environment or config files with no hard-coded secrets or hosts; graceful shutdown and timeouts on external calls; reversible data migrations with documented rollback; a documented rollback/redeploy path; for deployables, SBOM plus image/fs scan (`quality-gate` QG-SBOM/QG-IMAGE) | deployable, service, or API specs; `n/a` with a reason otherwise |
| QG-API-CONFORMANCE | The API matches its contract (OpenAPI/AsyncAPI) | Contract tests or schema validation | specs with an API |
| QG-BUGS | No open blocker or major bugs | `check-run-conformance -Scope bugs` exits 0 | every spec |

---

## Related

- Architecture documentation protocol: [[architecture-documentation]]
- Architecture styles protocol: [[architecture-styles]]
- API standards protocol: [[api-standards]]
- Auto mode: [[auto-mode]]
- Confidence gate: [[confidence-gate]]
- Spec layout: [[spec-layout]]
- Progress tracking: [[progress-tracking]]
- Architect agent: [[.KCC/capabilities/agents/architect]]
- Planner agent: [[.KCC/capabilities/agents/planner]]
- Technical interrogator agent: [[.KCC/capabilities/agents/technical-interrogator]]
