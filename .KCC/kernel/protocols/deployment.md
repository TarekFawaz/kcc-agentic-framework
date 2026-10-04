---
# Functional fields
description: >
  Defines the optional `deploy` lifecycle stage. Spells out supported cloud
  and on-prem targets, supported CI providers, where pipeline and IaC
  artifacts land, the per-spec deploy summary file, the v1.1 template
  matrix, and the integration with the rest of the spec lifecycle.

# Obsidian metadata
title: "Deployment Lifecycle Protocol"
aliases:
  - deployment
  - deploy-protocol
  - deploy-stage
tags:
  - framework/protocol
  - lifecycle/deploy
  - infrastructure
  - documentation
created: 2026-05-29
updated: 2026-05-29
version: 1.0.0
status: active
copyright: "KCC framework (c) 2026 Tarek Fawaz"
homepage: "https://tikasway.dev/kcc"
license: "Licensed under the terms in LICENSE"
---

# Deployment Lifecycle Protocol

The `deploy` stage is the OPTIONAL right edge of the spec lifecycle, sitting
after `/spec-review` returns `APPROVED`. Not every spec needs to deploy
anything: a doc-only spec, a refactor inside an already-deployed cell, or a
prototype run locally all skip this stage entirely. When a spec DOES need
deployment, this protocol defines the contract.

```text
... -> /spec-implement -> /spec-test -> /spec-review -> [/spec-deploy?] -> done
                                                       ^ optional
                                                       ^ requires APPROVED review
                                                       ^ requires InfrastructureDecisionBrief
                                                       ^ never auto-executed
```

## Position in the lifecycle

- Runs only after `/spec-review` returns `APPROVED`.
- Runs only when an approved `InfrastructureDecisionBrief.md` exists for the
  spec (or for its parent idea). The brief is produced by
  [[../../capabilities/skills/infrastructure-interrogator|/infrastructure-interrogator]]
  via [[../../capabilities/agents/infrastructure-planner|infrastructure-planner]].
- Invoked through
  [[../../capabilities/skills/spec-deploy|/spec-deploy SPEC-{ID}]], which
  delegates to
  [[../../capabilities/agents/infrastructure-implementer|infrastructure-implementer]].
- The lifecycle ends at `/spec-review` by default; `/spec-deploy` is
  explicit human opt-in. The `auto` skill includes deploy as an optional
  step 15 - see [[../../capabilities/skills/auto]].

## Supported targets

| Target | Status | Notes |
|--|--|--|
| AWS | v1.1 - TBD templates | Terraform / CloudFormation IaC |
| Azure | v1.1 - TBD templates | Terraform / Bicep IaC |
| GCP | v1.1 - TBD templates | Terraform IaC |
| On-prem Kubernetes | v1.1 - TBD templates | Helm + manifests |
| On-prem bare metal | v1.1 - TBD templates | Ansible playbooks |
| Mobile app stores | **deferred to v1.3+** | Apple App Store, Google Play, etc. |

Templates for each target live under `.KCC/kernel/templates/pipelines/{target}/{ci}/`.
For v1.1 these are placeholder READMEs; v1.2 lands real templates per the
matrix in [[../templates/pipelines/README|pipeline templates README]].

## Supported CI providers

| CI provider | Status | Pipeline location |
|--|--|--|
| GitHub Actions | v1.1 | `.github/workflows/SPEC-{ID}-{slug}.yml` |
| Azure DevOps | v1.1 | `azure-pipelines/SPEC-{ID}-{slug}.yml` (or root `azure-pipelines.yml`) |
| GitLab CI | v1.1 | `.gitlab-ci.yml` (extend / include per spec) |
| Jenkins | **deferred to v1.2+** | TBD per matrix |

## Where artifacts land

```text
.github/workflows/SPEC-{ID}-{slug}.yml          <- if CI = github-actions
azure-pipelines/SPEC-{ID}-{slug}.yml            <- if CI = azure-devops
.gitlab-ci.yml                                  <- if CI = gitlab-ci

infrastructure/
|-- terraform/SPEC-{ID}-{slug}/
|-- bicep/SPEC-{ID}-{slug}/
|-- cloudformation/SPEC-{ID}-{slug}/
|-- ansible/SPEC-{ID}-{slug}/
`-- helm/SPEC-{ID}-{slug}/

specs/IDEA-{ID}-{slug}-Specs/SPEC-{ID}-{slug}/deploy.md   <- per-spec summary
```

## Per-spec `deploy.md`

`/spec-deploy` writes `deploy.md` inside the spec folder. The file
summarizes:

- The source `InfrastructureDecisionBrief.md` that drove the run.
- The selected target (cloud or on-prem) and CI provider.
- Every artifact created, with path + status (draft / stub / ready) + the
  verification command for that artifact.
- The exact deployment commands a HUMAN must run (never the agent).
- Assumptions made and open questions for the human.
- Final `Confidence: NN%` line.

See the
[[../../capabilities/agents/infrastructure-implementer|infrastructure-implementer]]
agent's `## Output Format` section for the full file shape.

## Pipeline templates: v1.1 TBD, v1.2 lands real templates

For v1.1, `.KCC/kernel/templates/pipelines/{target}/{ci}/` directories
contain placeholder READMEs marked `TBD v1.2`. When
`infrastructure-implementer` cannot find a real template, it generates a
placeholder pipeline file with explanatory comments pointing at the matrix
in [[../templates/pipelines/README|pipeline templates README]]. This is
deliberate: shipping fabricated templates without the per-cloud expertise
to validate them is worse than shipping honest placeholders.

The v1.2 milestone lands hand-validated reference templates for each
(target x CI) cell of the matrix.

## Hard rules

- **No auto-execution.** The deploy agent only writes files. The human runs
  the deployment commands.
- **No bypass of `/spec-review`.** A spec without an `APPROVED` review
  cannot deploy.
- **No bypass of the InfrastructureDecisionBrief.** A spec without an
  approved brief cannot deploy. Run
  `/infrastructure-interrogator` first.
- **Explicit human opt-in.** `auto` mode includes deploy only as an
  OPTIONAL step 15 - even in `--silent --assume`, deploy never runs
  silently.
- **Destructive commands are human-only.** `terraform apply`,
  `kubectl apply`, `az ... create`, `aws ... create`, `helm install`, and
  similar mutating commands are never invoked by the agent. The agent may
  run read-only / lint / format / dry-run commands only.
- **Brief drives the choice.** Target and CI provider come from the
  InfrastructureDecisionBrief or the `/spec-deploy` flags. The agent does
  not improvise.

## Integration with the rest of the lifecycle

| Stage | Owner | Output | Feeds deploy? |
|--|--|--|--|
| `/infrastructure-interrogator` | infrastructure-planner | `InfrastructureDecisionBrief.md` | YES - required input |
| `/spec-create` | spec-writer | spec file + `Backlog/` items | Reads the brief; deploy stage references it later |
| `/spec-plan` | planner | `plan.md` | Plan may include deployment notes; does not produce pipeline files |
| `/spec-implement` | implementer | code under `src/IDEA-{ID}-{slug}/` | Code only - no infra |
| `/spec-test` | verifier | test results | Must pass before deploy |
| `/spec-review` | verifier | `review.md` with `APPROVED` verdict | Required gate for deploy |
| `/spec-deploy` | infrastructure-implementer | pipeline + IaC + `deploy.md` | THIS stage |

## Related

- Spec deploy skill: [[../../capabilities/skills/spec-deploy]]
- Infrastructure implementer agent: [[../../capabilities/agents/infrastructure-implementer]]
- Infrastructure planner agent: [[../../capabilities/agents/infrastructure-planner]]
- DevOps cloud dialect: [[dialects/devops-cloud]]
- DevOps k8s/on-prem dialect: [[dialects/devops-k8s-onprem-agnostic]]
- Pipeline templates matrix: [[../templates/pipelines/README|pipeline templates]]
- Spec layout protocol: [[spec-layout]]
- Auto-mode skill: [[../../capabilities/skills/auto]]
- Confidence gate: [[confidence-gate]]
- Architecture governance: [[architecture-governance]]
