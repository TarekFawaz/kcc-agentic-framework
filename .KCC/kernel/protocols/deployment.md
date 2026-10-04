---
# Functional fields
description: >
  Defines the optional `deploy` lifecycle stage. Spells out supported cloud
  and on-prem targets, supported CI providers, where pipeline and IaC
  artifacts land, the per-spec deploy summary file, the pipeline
  templates, and the integration with the rest of the spec lifecycle.

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
updated: 2026-10-04
version: 1.1.0
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
| AWS | provider templates | Terraform / CloudFormation IaC |
| Azure | provider templates | Terraform / Bicep IaC |
| GCP | provider templates | Terraform IaC |
| On-prem Kubernetes | provider templates | Helm + manifests |
| On-prem bare metal | provider templates | Ansible playbooks |
| Mobile app stores | not covered | Apple App Store, Google Play, etc. |

"provider templates" means the pipeline comes from the target-neutral `ci/`
and `deploy/` templates of the CI provider, and the deploy commands for the
target stay placeholders for a human to fill. Target-specific cells
(`.KCC/kernel/templates/pipelines/{target}/{ci}/`) are optional and none
exists yet. See [[../templates/pipelines/README|pipeline templates README]].

## Supported CI providers

| CI provider | Status | Pipeline location |
|--|--|--|
| GitHub Actions | templates ready | `.github/workflows/kcc-quality-gate.yml`, `.github/workflows/SPEC-{ID}-{slug}-ci.yml`, `.github/workflows/SPEC-{ID}-{slug}-deploy.yml` |
| Azure DevOps | templates ready | `azure-pipelines/SPEC-{ID}-{slug}-ci.yml` (or root `azure-pipelines.yml`), `azure-pipelines/SPEC-{ID}-{slug}-deploy.yml` |
| GitLab CI | templates ready | `.gitlab-ci.yml`, `.gitlab/ci/kcc-quality-gate.yml`, `.gitlab/ci/SPEC-{ID}-{slug}-deploy.yml` |
| Jenkins | templates ready | `Jenkinsfile` (or `jenkins/SPEC-{ID}-{slug}-ci.Jenkinsfile`), `jenkins/SPEC-{ID}-{slug}-deploy.Jenkinsfile` |

## Where artifacts land

```text
.github/workflows/kcc-quality-gate.yml          <- if CI = github-actions
.github/workflows/SPEC-{ID}-{slug}-ci.yml
.github/workflows/SPEC-{ID}-{slug}-deploy.yml
azure-pipelines/SPEC-{ID}-{slug}-ci.yml         <- if CI = azure-devops
azure-pipelines/SPEC-{ID}-{slug}-deploy.yml
.gitlab-ci.yml                                  <- if CI = gitlab-ci
.gitlab/ci/kcc-quality-gate.yml
.gitlab/ci/SPEC-{ID}-{slug}-deploy.yml
Jenkinsfile | jenkins/SPEC-{ID}-{slug}-ci.Jenkinsfile   <- if CI = jenkins
jenkins/SPEC-{ID}-{slug}-deploy.Jenkinsfile

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

## Pipeline templates

Templates live under `.KCC/kernel/templates/pipelines/` and are described in
[[../templates/pipelines/README|pipeline templates README]]. For each CI
provider (GitHub Actions, Azure DevOps, GitLab CI, Jenkins) there are three:

| Template | What it does |
|--|--|
| `quality-gate/{ci}/` | Runs `quality-gate.sh --require`; exit 1 and exit 3 both fail the job. |
| `ci/{ci}/` | Checkout, toolchain setup for the declared stack, the quality gate, restore, build, test, package, publish the artifact. Reuses the gate template instead of copying it. |
| `deploy/{ci}/` | `dev` -> `staging` -> `production`. Manual start only. Staging and production sit behind the provider's approval / environment protection. Deploys the artifact a CI run published. |

`infrastructure-implementer` instantiates all three for the selected
provider. Restore, build, test, package, deploy, and smoke commands in the
templates are placeholders that exit non-zero until replaced: build-side
commands come from the selected dialect, deploy-side commands are proposed in
`deploy.md` and put into the pipeline by a human after review. If a
target-specific cell `{target}/{ci}/` exists it is used instead of the
provider `deploy/` template.

The agent does not configure the approval controls (environment reviewers,
approvals and checks, protected environments, Jenkins submitters). `deploy.md`
lists them as required human setup, and the deploy pipeline must not be used
before they exist.

The source branch model these pipelines assume (protected trunk, pull
requests from `spec/SPEC-{ID}`) is defined in [[git-workflow]].

## Hard rules

- **No auto-execution.** The deploy agent only writes files. The human runs
  the deployment commands. Deploy pipelines have no push or pull-request
  trigger; a person starts each run and approves each production-like stage.
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
- Git workflow protocol: [[git-workflow]]
- Auto-mode skill: [[../../capabilities/skills/auto]]
- Confidence gate: [[confidence-gate]]
- Architecture governance: [[architecture-governance]]
