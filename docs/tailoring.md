# Tailoring KCC To A Solution

Out of the box KCC carries every agent, every skill, and 26 development
dialects. A Python command-line tool does not need the UX designer, the
deployment agents, or the embedded-C dialect. `kcc tailor` removes what
cannot apply, so each agent spawn is smaller and the lifecycle stops
offering steps that have no meaning for the project.

The rules and file effects are specified in
`.KCC/kernel/protocols/tailoring.md`. This page is the how-to.

## Three ways to describe the solution

**Answer questions** (the default):

```text
kcc tailor
```

The answers are pre-filled from what the repository already shows
(`package.json`, `pyproject.toml`, `*.csproj`, `go.mod`, Helm charts, ...).

**Give a context file:**

```text
kcc tailor --context solution-context.yaml
```

```yaml
name: billing-api
project_type: api-service        # web-app | api-service | cli-tool | library | mobile | embedded | data-pipeline | other
stacks: [dotnet]                 # python nodejs nestjs mern react angular vanilla-js dotnet go rust java cpp c php
has_ui: false
deployment: kubernetes           # none | cloud | kubernetes | onprem | hybrid
existing_codebase: true
import_workflows: false
data_sensitivity: high           # low | medium | high
performance_tests: true
coverage_min_pct: 85
brief: |
  Invoicing service for the finance platform. Integrates with the ERP over
  REST. Releases go through the change advisory board.
```

A `.json` file with the same keys works too. A free-form `.md` brief is also
accepted: it is scanned for stack, UI, and deployment keywords and stored as
`.KCC/context.md`.

**Use the onboarding baseline** of an existing codebase:

```text
/solution-onboard .          (in your harness)
kcc tailor --from-baseline
```

All three can also be given to `kcc init` (`--context`, `--from-baseline`,
`--yes`), so a new project is tailored before its adapters are generated.

## See it before applying

```text
kcc tailor --context solution-context.yaml --dry-run
```

```text
Solution: billing-api | api-service | stacks: dotnet | UI: no | deployment: kubernetes
  - stacks dotnet -> backend-csharp
  - no user interface -> UX/UI designer and interrogator dropped
  - no external workflow to import -> migrator dropped
Dialects kept (6): backend-csharp, devops-k8s-onprem-agnostic, testing-integration, ...
Agents dropped (2): ux-ui-designer, migrator
Skills dropped (2): ux-ui-interrogator, adapt-workflow
```

`kcc tailor --show` prints what is currently applied.

## What happens

- The context is saved in `.KCC/settings.json` under `tailoring`.
- Dropped files move to `.KCC/.tailored-out/`. Nothing is deleted.
- The dialect registry lists only the kept dialects.
- Adapters are regenerated; dropped agents and skills disappear from
  `.claude/`, `.codex/`, `.opencode/`, `.agents/`, and from
  `coordination/orchestrator.md`.
- `coverage_min_pct` is written to `quality.coverage_min_pct`.

Undo everything:

```text
kcc tailor --reset
```

Re-run `kcc tailor` whenever the solution changes (a UI is added, a
deployment target is chosen). `kcc upgrade` keeps the tailoring.

## Second step: solution-specific additions

Pruning removes; it cannot add knowledge about your project. For that, run
this skill in your harness after `kcc tailor`:

```text
/tailor-workflow
```

The agent reads the recorded context, `.KCC/context.md`, and the onboarding
baseline, and writes proposals to `migrations/TAILOR-001/`:

- `plan.md` lists each proposal, the gap it closes, and the tokens it adds
  per spawn;
- `drafts/agents/` and `drafts/skills/` hold the files: agent addenda with
  your real build and test commands and conventions, or new agents and
  skills for recurring work.

Nothing is promoted for you. Review the drafts, move the ones you accept
into `.KCC/capabilities/agents/` or `.KCC/capabilities/skills/`, then:

```text
kcc sync
kcc validate
```

## What is never dropped

The lifecycle agents (interrogators, architect, spec-writer, planner,
implementer, verifier), the meta-agents (butler, token-guard), the security
analyst, the architecture critic, the repo steward, and the unit,
integration, and security testing dialects.
