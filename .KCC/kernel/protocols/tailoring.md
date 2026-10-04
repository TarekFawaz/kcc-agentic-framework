---
title: Tailoring Protocol
aliases:
  - tailoring
  - kcc-tailor
  - context-tailored-workflow
tags:
  - framework/protocol
  - tailoring
  - cli
created: 2026-10-04
updated: 2026-10-04
version: 1.0.0
status: active
copyright: "KCC framework (c) 2026 Tarek Fawaz"
homepage: "https://tikasway.dev/kcc"
license: "Licensed under the terms in LICENSE"
---

# Tailoring

KCC ships generic: every agent, every skill, every dialect. Tailoring fits a
workspace to one solution, so each spawn carries less and the lifecycle never
offers a step that cannot apply. It has two layers:

1. **Deterministic pruning** by the `kcc tailor` command. No model is
   involved; the same context always gives the same result.
2. **Agent refinement** by the optional `/tailor-workflow` skill, which
   drafts solution-specific additions for a human to review.

A workspace with no `tailoring` section in `.KCC/settings.json` is the full
generic framework. Tailoring is always reversible with `kcc tailor --reset`.

## Solution context

The human describes the solution once. Three inputs, later ones win:

| Input | Command | Use |
|--|--|--|
| Repo markers | automatic | `package.json`, `pyproject.toml`, `*.csproj`, `go.mod`, `Cargo.toml`, `pom.xml`, `composer.json`, `CMakeLists.txt`, Helm/Terraform files pre-fill the answers |
| Onboarding baseline | `kcc tailor --from-baseline` | Reads `solution/TechStack.md` and the other files written by `/solution-onboard` |
| Context file | `kcc tailor --context <file>` | `.json` / `.yaml` with the keys below, or a free-form `.md` brief |
| Questions | `kcc tailor` | Asked in the terminal when no file or baseline is given |

Context keys:

| Key | Values | Default |
|--|--|--|
| `name` | text | folder name |
| `project_type` | `web-app`, `api-service`, `cli-tool`, `library`, `mobile`, `embedded`, `data-pipeline`, `other` | `other` |
| `stacks` | list of `python`, `nodejs`, `nestjs`, `mern`, `react`, `angular`, `vanilla-js`, `dotnet`, `go`, `rust`, `java`, `cpp`, `c`, `php` | empty |
| `has_ui` | true / false | true |
| `deployment` | `none`, `cloud`, `kubernetes`, `onprem`, `hybrid` | `cloud` |
| `existing_codebase` | true / false | false |
| `import_workflows` | true / false | false |
| `data_sensitivity` | `low`, `medium`, `high` | `medium` |
| `performance_tests` | true / false | true |
| `coverage_min_pct` | 0-100 | unchanged |
| `dialects` | explicit dialect list; overrides the stack mapping | unset |
| `brief` | free text, stored as `.KCC/context.md` | unset |

A Markdown brief is stored as `.KCC/context.md` and scanned for stack,
UI, and deployment keywords. It is the main input of `/tailor-workflow`.

## Pruning rules

| Context | Effect |
|--|--|
| `stacks` given | Only the matching language dialects stay. `has_ui` adds `frontend-general` and the full-stack dialect of the stack; `embedded` projects get the embedded dialects |
| `stacks` empty | No language dialect is dropped |
| `deployment` | `cloud` keeps `devops-cloud`; `kubernetes` / `onprem` keep `devops-k8s-onprem-agnostic`; `hybrid` keeps both; `none` drops both, plus `infrastructure-planner`, `infrastructure-implementer`, `/infrastructure-interrogator`, `/spec-deploy` |
| `has_ui: false` | Drops `ux-ui-designer` and `/ux-ui-interrogator` |
| `existing_codebase: false` | Drops `solution-cartographer`, `solution-inspector`, `/solution-onboard` |
| `import_workflows: false` | Drops `migrator` and `/adapt-workflow` |
| `performance_tests: false` | Drops `testing-performance` |
| `coverage_min_pct` | Written to `quality.coverage_min_pct` |

The lifecycle agents, the meta-agents, `security-analyst`,
`architecture-critic`, `repo-steward`, and the unit, integration, and
security testing dialects are never dropped.

## What changes on disk

- `.KCC/settings.json -> tailoring`: the context, the kept dialects, and the
  dropped agents and skills.
- `.KCC/tailoring.exclude`: one path per line (relative to `.KCC/`) of every
  file set aside. `validate-kcc` reads it and does not report those files as
  missing.
- Dropped files move to `.KCC/.tailored-out/` with the same relative path.
  Nothing is deleted, so local edits survive and `--reset` moves them back.
- `kernel/protocols/dialects/dialect-registry.md` lists only the kept
  dialects.
- Generated adapters of dropped agents and skills are removed, then
  `sync-adapters` regenerates the rest. `coordination/orchestrator.{md,json}`
  then list only the agents that exist.

**Rule for agents:** an agent or skill that is absent from
`coordination/orchestrator.json` does not apply to this solution. Skip its
step and record `skipped: tailored out` in the trace; do not ask for it and
do not improvise its work. A dialect that is absent from the registry is not
selectable; if the work needs it, stop and ask the human to re-tailor.

`kcc upgrade` keeps tailoring: updated versions of dropped files go to
`.tailored-out/`, and the registry is pruned again.

## Agent refinement (`/tailor-workflow`)

After pruning, a human may run `/tailor-workflow`. The agent reads
`.KCC/context.md`, the `tailoring` section, and the `solution/` baseline
when present, and writes proposals under `migrations/TAILOR-{NNN}/`:

- `plan.md`: what it proposes and why, with the tokens each addition costs
  per spawn;
- `drafts/agents/*.md`, `drafts/skills/*.md`: new solution-specific
  capabilities, or addenda to existing ones (project commands, conventions,
  domain vocabulary).

Drafts follow the migrator rule: **never auto-promoted**. The human reviews
them, moves the accepted files into `.KCC/capabilities/`, and runs
`kcc sync`. Files added this way are not shipped by the CLI, so `kcc
upgrade` leaves them alone.

## Related

- [[workspace]] - workspace topology in `.KCC/settings.json`
- [[solution-onboarding]] - the baseline tailoring can read
- [[adaptation-guide]] - the draft-and-promote convention reused here
- [[dialect-registry]] - the dialect list that pruning rewrites
