# How To Use KCC

This guide explains the main ways to use a materialized KCC cell after you run
`kcc init` (or the `framework-init` script) and generate adapter files for
Codex, Claude Code, OpenCode, generic `.agents`, or Ollama-backed runners.

Before the first idea, fit the framework to the solution with `kcc tailor`
([tailoring.md](./tailoring.md)). Every `auto ...` form below can also be
driven from a terminal with `kcc run --input "<same argument>"`, which adds
automatic wait-and-resume when the harness hits a usage limit
([cli.md](./cli.md)).

KCC is local-first. You use the generated adapter surface for your harness, but
the source of truth remains `.KCC/kernel/` and `.KCC/capabilities/`.

## Scenario 1: Start From Scratch

Use this when you have a fresh idea and no existing spec.

### Option A: Human-guided `auto`

```text
auto <idea text>
auto <idea filepath>
```

Examples:

```text
auto build a CLI that converts CSV to JSON
auto docs/new-product-idea.md
```

What happens:

1. `auto` treats the input as a fresh idea.
2. The idea-interrogator starts in HITL mode and asks foundational questions.
3. Specialist interrogators run when relevant:
   - technical-interrogator for stack and architecture decisions
   - ux-ui-interrogator for user-facing surfaces
   - security-interrogator for identity, data, privacy, compliance, and secrets
   - infrastructure-interrogator for deployable or packageable work
4. The architect produces architecture artifacts for the selected depth.
5. Specs are created, planned, implemented, tested, and reviewed through gates.

Interrogation depth:

| Depth | Use for | What it adds |
|---|---|---|
| `lite` | Minimal CLI, script, docs-only, or small local tool work. | Context diagram, flowchart, fitness functions, budgets, NFRs. |
| `standard` | Default for apps, APIs, services, persistence, integrations, or user workflows. | Container view, guardrails, quality gates, ADRs, spec-local architecture. |
| `deep` | Distributed, regulated, cross-service, security-heavy, or DR/SLO-sensitive work. | Component and sequence diagrams, trust boundaries, security/data-flow diagrams, DR/SLO details. |

### Option B: Full hand-off `auto`

```text
auto <idea text> --silent --assume
auto <idea filepath> --silent --assume
```

Examples:

```text
auto build a customer support triage dashboard --silent --assume
auto ideas/ops-automation.md --silent --assume --accuracy 97% --budget 150 USD
```

What happens:

1. Agents document low-risk assumptions instead of asking routine questions.
2. Specialist decision briefs are still produced.
3. Architecture defaults to a production-leaning standard depth unless the idea indicates otherwise.
4. The run continues until a non-silent-able gate appears.

Non-silent-able gates:

| Gate | Why it stops |
|---|---|
| Prohibited assumptions | Legal, security posture, privacy, compliance, destructive actions, external spend, and production-impacting choices require a human. |
| Toolchain install | KCC can detect missing tools, but installation is always human-gated. |
| Low confidence | Any agent below the confidence floor triggers `/critical-human-gate`. |
| Loop detection | Repeated failure for the same agent and step stops the chain. |
| Budget cap | Controlled hand-off stops if estimates exceed `--budget`. |

Useful flags:

| Flag | Meaning |
|---|---|
| `--silent` | Suppresses routine interruptions, but not required gates. |
| `--assume` | Allows documented low-risk assumptions. |
| `--accuracy NN%` | Sets the confidence floor. Default is 95%. |
| `--budget NN [CCY]` | Sets hosted-model spend cap. Local models remain token-only. |
| `--parallel` | Forces spec fan-out and later implementation wave fan-out when safe. |

### Option C: Interrogate first, then resume with `auto`

```text
/idea-interrogator <idea text>
/idea-interrogator <idea filepath>
auto IDEA-{ID}
```

Examples:

```text
/idea-interrogator "build a plugin marketplace for KCC capabilities"
auto IDEA-007
```

Use this when you want to shape the idea carefully before allowing the lifecycle
to continue. After the idea folder exists, `auto IDEA-{ID}` resumes from the
first missing lifecycle artifact.

## Scenario 2: Start With An Existing Solution

Use this when you already have a codebase or solution and want KCC to operate
against it.

### Step 1: Onboard the solution

```text
/solution-onboard <path>
/solution-onboard <path> --depth=minimal
/solution-onboard <path> --depth=standard
/solution-onboard <path> --depth=deep
/solution-onboard <path> --skip-inspector
```

Examples:

```text
/solution-onboard .
/solution-onboard ../ExistingApp --depth=standard
/solution-onboard . --depth=minimal --skip-inspector
```

What happens:

1. solution-cartographer builds a read-only baseline of the codebase.
2. solution-inspector captures workspace topology when enabled:
   - single repo or multi-repo
   - cross-repo dependencies
   - tracker choice
   - integration boundaries
3. KCC writes solution artifacts such as `solution/solution.md` and supporting maps.
4. `.KCC/settings.json` is populated with workspace assumptions.

Depth options:

| Depth | Use for | Behavior |
|---|---|---|
| `minimal` | Small tools or a quick baseline. | Cartographer only; skips topology interrogation by default. |
| `standard` | Most existing applications. | Cartographer plus inspector workspace questions. |
| `deep` | Large, multi-repo, regulated, or high-risk systems. | Deeper topology, dependency, and tracker probing. |

### Step 2: Choose the next path

After onboarding, you can use either:

```text
auto <change idea>
```

or:

```text
/spec-create <detailed prompt or file path>
```

Use `auto` when you want KCC to run the whole lifecycle with gates. Use
`/spec-create` when you already have enough detail and want to start directly
at spec creation.

## Scenario 3: Adapt An Existing Agentic Workflow To KCC

Use this when you already have prompts, rules, agents, slash commands, or
workflow files from another system.

```text
/adapt-workflow <path>
/adapt-workflow <path> --format=cursor
/adapt-workflow <path> --format=claude
/adapt-workflow <path> --format=codex
/adapt-workflow <path> --format=opencode
/adapt-workflow <path> --format=aider
/adapt-workflow <path> --format=generic
```

Examples:

```text
/adapt-workflow ../OtherProject
/adapt-workflow ../OtherProject --format=cursor
```

What happens:

1. KCC scans the source workflow.
2. It inventories candidate agents, prompts, commands, and rules.
3. It writes a draft migration under `migrations/IMPORT-{NNN}/`.
4. Drafts are never auto-promoted.
5. You review and explicitly move approved drafts into `.KCC/capabilities/`.

## Skill Reference

Use slash-form in harnesses that support slash commands. In Codex or OpenCode,
you can also invoke the same skill by asking the agent to follow the matching
KCC skill from `AGENTS.md`.

| Skill | Main use | Arguments and examples |
|---|---|---|
| `/auto` | Run the lifecycle from idea, idea ID, spec ID, or all active specs. | `auto <idea>`, `auto <file>`, `auto IDEA-007`, `auto SPEC-003`, `auto all`, `auto <idea> --silent --assume --accuracy 97% --budget 150 USD --parallel` |
| `/idea-interrogator` | Turn a raw idea into an idea folder and spec-writer-ready handoff. | `/idea-interrogator <idea text>`, `/idea-interrogator <file path>` |
| `/technical-interrogator` | Capture and challenge technical choices before spec creation. | `/technical-interrogator <idea folder or spec request>` |
| `/ux-ui-interrogator` | Capture UX/UI, design-system, accessibility, and interaction decisions. | `/ux-ui-interrogator <idea folder or spec request>` |
| `/security-interrogator` | Capture data sensitivity, identity, authorization, privacy, compliance, audit, and secrets concerns. | `/security-interrogator <idea folder or spec request>` |
| `/infrastructure-interrogator` | Capture deployment, packaging, observability, SLO, DR, scale, and cost decisions. | `/infrastructure-interrogator <idea folder or spec request>` |
| `/spec-create` | Create an epic spec folder, backlog files, and parallelization stub. | `/spec-create <problem description>`, `/spec-create <file path>`, `/spec-create <folder path>`, `/spec-create <SpecWriterStarter.md>` |
| `/spec-plan` | Create an implementation plan and atomic test-case table. | `/spec-plan SPEC-003` |
| `/spec-implement` | Implement a spec, wave, story, or enabler from an approved plan. | `/spec-implement SPEC-003`, `/spec-implement SPEC-003 --wave 2`, `/spec-implement SPEC-003 Story-001`, `/spec-implement SPEC-003 Enabler-001` |
| `/spec-test` | Verify implementation against epic and backlog acceptance criteria. | `/spec-test SPEC-003` |
| `/spec-review` | Run a lighter diff/spec review. | `/spec-review SPEC-003` |
| `/spec-status` | Show status across specs, plans, reviews, and verdicts. | `/spec-status` |
| `/spec-merge` | After an approved review: check branch and commits, merge wave lanes, and draft the pull request. Never pushes. | `/spec-merge SPEC-003` |
| `/spec-deploy` | Generate deployment pipeline and IaC stubs from approved infrastructure decisions. | `/spec-deploy SPEC-003`, `/spec-deploy SPEC-003 --ci=github-actions --cloud=aws` |
| `/bug-report` | Report a defect at any point; it becomes a Bug backlog item that goes through regression test, fix, test, and review. | `/bug-report SPEC-003 export drops the last row`, `/bug-report <description> --severity major` |
| `/tailor-workflow` | Draft solution-specific agent addenda, agents, and skills from the recorded context. Drafts only. | `/tailor-workflow`, `/tailor-workflow focus on release steps` |
| `/solution-onboard` | Build a baseline understanding of an existing solution. | `/solution-onboard .`, `/solution-onboard ../App --depth=deep`, `/solution-onboard . --skip-inspector` |
| `/adapt-workflow` | Draft-migrate another agentic workflow into KCC format. | `/adapt-workflow ../OtherProject`, `/adapt-workflow ../OtherProject --format=cursor` |
| `/architecture-review` | Review architecture artifacts for semantic conformance and drift. | `/architecture-review` |
| `/dashboard` | Regenerate the local progress and activity dashboard. | `/dashboard` |
| `/inspect` | Run the basic Inspector detect/propose pipeline over real signals. | `/inspect` |
| `/butler-brief` | Produce a compact memory/context pack before a lifecycle turn. | `/butler-brief SPEC-003`, `/butler-brief authentication architecture` |
| `/butler-remember` | Persist non-obvious reusable learning after a turn. | `/butler-remember <session summary>`, `/butler-remember Traces/Session-x` |
| `/token-estimate` | Estimate token and hosted-model spend before expensive work. | `/token-estimate SPEC-003`, `/token-estimate IDEA-007`, `/token-estimate prompt:<text>`, `/token-estimate --calibrate` |
| `/critical-human-gate` | Pause when confidence, safety, loop, or budget conditions require human decision. | `/critical-human-gate <agent confidence context>` |

## Practical Usage Patterns

| If you want | Use |
|---|---|
| Maximum guidance | `/idea-interrogator <idea>`, then `auto IDEA-{ID}` |
| Fast but governed automation | `auto <idea>` |
| Mostly hands-off automation | `auto <idea> --silent --assume --accuracy 95% --budget 200 USD` |
| Existing codebase baseline | `/solution-onboard . --depth=standard` |
| Direct spec from detailed notes | `/spec-create <file path>` |
| Import existing prompts/rules | `/adapt-workflow <path>` |
| Check the whole framework | `.KCC/tools/validate-kcc.ps1` or `.sh` |

---

KCC framework (c) 2026 Tarek Fawaz, [tikasway.dev](https://tikasway.dev/kcc). Licensed under the terms in [LICENSE](../LICENSE).
