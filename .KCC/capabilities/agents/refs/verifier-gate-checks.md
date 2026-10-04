---
title: Verifier Gate Checks
tags:
  - framework/agent-ref
updated: 2026-09-21
---

# Verifier Gate Checks

Full check detail for verifier Process steps 9-9d.

## Architecture gates and documentation (step 9)

9. **Check architecture gates and documentation.** Read
   `architecture/guardrails.md`, `architecture/quality-gates.md`, and the
   named diagram source files (`architecture/c4-*.md`,
   `architecture/flowcharts/*.md`, `architecture/dfds/*.md`,
   `architecture/sequences/*.md`); verify applicable gates and required
   diagrams for the selected architecture depth. Then enforce the
   architecture-documentation rules from [[.KCC/kernel/protocols/architecture-documentation]]:
   - The global `architecture/architecture.md` exists as the **Architecture
     Document** with its required narrative sections (overview, context,
     containers [standard+], components [deep], key workflows, data flows,
     key decisions, quality attributes, risks & assumptions, reference
     artifacts) and embeds diagrams inline (fenced ```mermaid``` with
     `Source:` citations) - not a thin MOC / link hub.
   - Every spec folder under verification has an `arch.md` that meets the
     **content bar**: at least one embedded ```mermaid``` block (not just
     links) plus the per-spec design narrative. A link-only `arch.md` or a
     sub-1 KB stub is **CHANGES_NEEDED**.
   - Architecture diagrams are **named `.md` files with embedded inline
     ```mermaid``` blocks** (e.g. `architecture/c4-context.md`,
     `architecture/flowcharts/*.md`, `architecture/dfds/*.md`,
     `architecture/sequences/*.md`); the global `architecture/architecture.md`
     embeds its diagrams inline. There must be **NO `.mmd` files** and **NO
     `architecture/diagrams/` folder**. Flag any `.mmd` file or
     `architecture/diagrams/` folder as a **deprecated-layout violation**.

## API conformance (step 9b)

9b. **API conformance check (default gate when an API exists).** When the spec
   exposes an HTTP/REST API, run the API conformance check from
   [[.KCC/kernel/protocols/api-standards]]:
   - **OpenAPI document present** - a checked-in, valid OpenAPI 3.x document
     exists at the expected location (default
     `src/IDEA-{ID}-{slug}/<service>/openapi.yaml`, or the dialect's idiomatic
     path).
   - **Swagger UI served** - the running service exposes a Swagger UI (default
     `/docs`) plus the raw document, both rendering the checked-in spec.
   - **Routes conform to the spec** - every implemented route + verb is in the
     OpenAPI document and vice versa; request/response schemas, required
     parameters, and status codes match.
   Any mismatch - undocumented route, documented-but-unimplemented route,
   verb/parameter/schema/status-code divergence, missing Swagger UI, or
   invalid/absent OpenAPI document - is **CHANGES_NEEDED**, citing the route/verb
   and the spec line. The default is waived only when an ADR records a non-HTTP
   interface; in that case verify the alternative contract the ADR names.

## QG-ARCH-CONFORMANCE (step 9c)

9c. **Architecture-conformance check (`QG-ARCH-CONFORMANCE` - default gate,
   runs every spec).** Per [[.KCC/kernel/protocols/architecture-governance]],
   the architecture ADR(s) dictate the stack. The implementation MUST match the
   stack and standards declared in the **Accepted** (or **Proposed +
   human-approved**) architecture ADR(s).
   - **Read the declared stack.** From `architecture/architecture.md` and the
     relevant ADR(s) under `architecture/adrs/`, extract the declared stack:
     languages, frameworks, API style, persistence/datastore, and architecture
     style (Clean/DDD, event-driven, static, etc.).
   - **Read the implemented stack.** Inspect what was actually built under
     `src/IDEA-{ID}-{slug}/...`: e.g. `package.json` / `requirements.txt` /
     `*.csproj` dependencies, source file types/extensions, framework imports,
     entry points, and the presence/absence of a real datastore integration.
   - **Compare.** The two must agree on languages, frameworks, API style,
     persistence, and architecture style. Any divergence - e.g. an ADR
     declaring TypeScript + React + Node API + PostgreSQL but a static HTML/JS
     implementation - is **CHANGES_NEEDED** with a clear finding:
     "implementation stack (X) does not match architecture ADR (Y); either fix
     the implementation to match the ADR, or record an approved ADR documenting
     the change." Cite the ADR ID and the implemented evidence.
   - **Only an ADR excuses divergence.** The implementation may diverge from
     the declared stack ONLY when an ADR (status `Accepted`, or `Proposed` AND
     human-approved) documents that divergence and its rationale. A stack
     change is a prohibited silent assumption - absent such an ADR, a mismatch
     is always CHANGES_NEEDED, never silently passed.
   - **TOOLCHAIN_DEFERRED does NOT excuse a stack mismatch.** Deferred means
     "the declared stack was written but not built/run because tools were
     missing" - it does NOT mean "a different stack was built." If a *different*
     stack from the ADR was actually implemented, that is a conformance
     **CHANGES_NEEDED**, regardless of whether the declared toolchain was
     deferred. Do not let a deferred toolchain mask a stack substitution.

## QG-ARCH-DOCS (step 9d)

9d. **Architecture-docs-quality check (`QG-ARCH-DOCS` - default gate, runs
   every spec).** This gate is about the **quality of the architecture
   documentation**, and is distinct from `QG-ARCH-CONFORMANCE` (which is about
   the implementation matching the declared ADR stack). It aligns with - and
   does not contradict - the validator's structural backstop and the
   architecture-critic's semantic review.
   - **Confirm the architecture was reviewed.** Check that the
     architecture-critic ran and recorded a **CONFORMANT** verdict on the
     produced architecture (the architect's revise loop must have ended on
     CONFORMANT, or a human override of `/critical-human-gate` is on record). If
     there is no CONFORMANT critic verdict on record (or the architecture was
     never reviewed), that is **CHANGES_NEEDED** - the architecture must pass
     `/architecture-review` before the spec ships.
   - **Confirm the architecture artifacts conform** (re-checking the semantic
     bar, not just structure, consistent with step 9):
     - `architecture/architecture.md` is a real Architecture Document with its
       required narrative sections filled with genuine prose - not a thin
       MOC / link hub / sub-1 KB stub.
     - Diagrams are embedded inline (fenced ```mermaid``` + `Source:` citation),
       sourced from named `.md` files. There are **NO `.mmd` files** and **NO
       `architecture/diagrams/` folder** (deprecated-layout violation if found).
     - The supporting docs are present and substantive for the active depth:
       `fitness-functions.md`, `nfrs.md`, `technical-budgets.md`,
       `guardrails.md`, `quality-gates.md`, and `adrs/` + `adrs.md` index.
   - Any failure here is **CHANGES_NEEDED**, citing the artifact and the
     standard rule from [[.KCC/kernel/protocols/architecture-documentation]].
