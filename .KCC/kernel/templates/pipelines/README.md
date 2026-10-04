---
title: Pipeline Templates Matrix
aliases:
  - pipeline-templates
  - pipelines-readme
  - pipeline-matrix
tags:
  - framework/template
  - lifecycle/deploy
  - infrastructure
  - documentation
created: 2026-05-29
updated: 2026-10-04
version: 1.2.0
status: active
copyright: "KCC framework (c) 2026 Tarek Fawaz"
homepage: "https://tikasway.dev/kcc"
license: "Licensed under the terms in LICENSE"
---

# Pipeline Templates Matrix

This directory holds the pipeline templates that the
[[../../capabilities/agents/infrastructure-implementer|infrastructure-implementer]]
agent instantiates per spec when `/spec-deploy` runs. There are two layers:

- **Provider templates** (`quality-gate/`, `ci/`, `deploy/`): one file per CI
  provider, independent of the deployment target. These exist for all four
  providers.
- **Target cells** (`{target}/{ci}/`): target-specific pipelines with real
  deploy commands. None has landed yet; until one does, the provider
  templates are used and their deploy commands stay placeholders.

## Provider templates

| Kind | GitHub Actions | Azure DevOps | GitLab CI | Jenkins |
|--|--|--|--|--|
| Quality gate | `quality-gate/github-actions/quality-gate.yml.tmpl` | `quality-gate/azure-devops/azure-pipelines.quality-gate.yml.tmpl` | `quality-gate/gitlab-ci/.gitlab-ci.quality-gate.yml.tmpl` | `quality-gate/jenkins/Jenkinsfile.quality-gate.tmpl` |
| CI | `ci/github-actions/ci.yml.tmpl` | `ci/azure-devops/azure-pipelines.ci.yml.tmpl` | `ci/gitlab-ci/.gitlab-ci.ci.yml.tmpl` | `ci/jenkins/Jenkinsfile.ci.tmpl` |
| Deploy | `deploy/github-actions/deploy.yml.tmpl` | `deploy/azure-devops/azure-pipelines.deploy.yml.tmpl` | `deploy/gitlab-ci/.gitlab-ci.deploy.yml.tmpl` | `deploy/jenkins/Jenkinsfile.deploy.tmpl` |

The templates are written from each provider's documented syntax. They have
not been executed on the providers from this repository, so treat the first
run of an instantiated pipeline as part of its review.

### CI template

Flow: checkout -> toolchain setup for the declared stack -> quality gate
(`quality-gate --require`) -> restore -> build -> test -> package -> publish
the `kcc-package` artifact (`dist/` under `src/IDEA-{ID}-{slug}/`). The gate
runs first and the build waits for it. Toolchain setup is a commented list
per stack; restore, build, test, and package are placeholders that fail until
replaced with the stack's commands, so an unfinished pipeline cannot report
success.

The gate logic is reused, not copied:

| Provider | How the CI template gets the gate |
|--|--|
| GitHub Actions | Calls the gate workflow as a reusable workflow (`uses: ./.github/workflows/kcc-quality-gate.yml`). |
| GitLab CI | `include: local:` of the instantiated gate file. |
| Azure DevOps | The provider cannot reference a full pipeline file as a stage. The template carries the marker lines `# {{quality_gate_variables}}` and `# {{quality_gate_stage}}`; at instantiation they are replaced with the version variables and the `quality_gate` stage copied unchanged from the gate template. |
| Jenkins | Same approach with `// {{quality_gate_variables}}` and `// {{quality_gate_stages}}` (the gate's two stages). |

### Deploy template

Stages: `dev` -> `staging` -> `production`, in that order, each depending on
the one before.

- **Manual start only.** No push or pull-request trigger
  (`workflow_dispatch`, `trigger: none`, `when: manual`, a parameterised
  Jenkins job). No KCC agent starts a deployment.
- **Gated artifact.** It deploys the artifact published by a CI run, so the
  quality gate has passed for what is deployed.
- **Approval on production-like stages.** `staging` and `production` sit
  behind the provider's own control, which a human configures once:

  | Provider | Control |
  |--|--|
  | GitHub Actions | Environments `staging` / `production` with required reviewers. |
  | Azure DevOps | Environments with Approvals and checks. |
  | GitLab CI | Manual jobs on protected environments. |
  | Jenkins | `input` step with a `submitter` list. |

  The template header says what must be configured. Without it the stage is
  not gated and the template must not be used.
- **Placeholder commands.** Every deploy and smoke-test command is marked
  `PLACEHOLDER` and exits non-zero until a human replaces it with the command
  from the spec's `deploy.md`.

### Where instantiated files go

| Provider | Gate | CI | Deploy |
|--|--|--|--|
| GitHub Actions | `.github/workflows/kcc-quality-gate.yml` | `.github/workflows/SPEC-{ID}-{slug}-ci.yml` | `.github/workflows/SPEC-{ID}-{slug}-deploy.yml` |
| Azure DevOps | inside the CI file | `azure-pipelines/SPEC-{ID}-{slug}-ci.yml` | `azure-pipelines/SPEC-{ID}-{slug}-deploy.yml` |
| GitLab CI | `.gitlab/ci/kcc-quality-gate.yml` | `.gitlab-ci.yml` | `.gitlab/ci/SPEC-{ID}-{slug}-deploy.yml` |
| Jenkins | inside the CI file | `Jenkinsfile` or `jenkins/SPEC-{ID}-{slug}-ci.Jenkinsfile` | `jenkins/SPEC-{ID}-{slug}-deploy.Jenkinsfile` |

### Placeholders

`{{spec_id}}`, `{{spec_slug}}`, `{{idea_id}}`, `{{idea_slug}}`, `{{target}}`,
`{{dialect}}` are substituted with the spec's values. `{{quality_gate_variables}}`,
`{{quality_gate_stage}}`, and `{{quality_gate_stages}}` are the gate markers
described above. `${{ ... }}` in GitHub Actions files is provider syntax and
is left as is.

## Target matrix

| Target / CI | GitHub Actions | Azure DevOps | GitLab CI | Jenkins |
|---|---|---|---|---|
| AWS | provider templates | provider templates | provider templates | provider templates |
| Azure | provider templates | provider templates | provider templates | provider templates |
| GCP | provider templates | provider templates | provider templates | provider templates |
| On-prem k8s | provider templates | provider templates | provider templates | provider templates |
| On-prem bare-metal | provider templates | provider templates | provider templates | provider templates |

"provider templates" means: no `{target}/{ci}/` cell exists, so
`infrastructure-implementer` instantiates `ci/` and `deploy/` for the
provider and leaves the deploy commands as placeholders, listing the commands
a human should put there in the spec's `deploy.md`. A cell that lands replaces
that entry with `ready ({maintainer})`.

Mobile app stores (Apple App Store, Google Play) are not covered.

Deploy commands for a specific target are not shipped without someone who can
validate them against that target. A placeholder that fails is preferred over
a command that looks right and was never run.

## Directory layout

```text
.KCC/kernel/templates/pipelines/
|-- README.md                       <- this file
|-- quality-gate/                   <- mandatory gate, one file per CI provider
|   |-- github-actions/quality-gate.yml.tmpl
|   |-- azure-devops/azure-pipelines.quality-gate.yml.tmpl
|   |-- gitlab-ci/.gitlab-ci.quality-gate.yml.tmpl
|   `-- jenkins/Jenkinsfile.quality-gate.tmpl
|-- ci/                             <- gate, build, test, package
|   |-- github-actions/ci.yml.tmpl
|   |-- azure-devops/azure-pipelines.ci.yml.tmpl
|   |-- gitlab-ci/.gitlab-ci.ci.yml.tmpl
|   `-- jenkins/Jenkinsfile.ci.tmpl
|-- deploy/                         <- dev -> staging -> production, approval-gated
|   |-- github-actions/deploy.yml.tmpl
|   |-- azure-devops/azure-pipelines.deploy.yml.tmpl
|   |-- gitlab-ci/.gitlab-ci.deploy.yml.tmpl
|   `-- jenkins/Jenkinsfile.deploy.tmpl
`-- {target}/{ci}/                  <- optional target cells (none yet):
                                       aws | azure | gcp | onprem-k8s | onprem-bare-metal
```

## Mandatory quality-gate stage

Every CI template runs the KCC quality gate
([`quality-gate.sh`](../../../tools/quality-gate.sh), bash on a Linux runner)
before any build, plan, or package stage, and a deploy template deploys only
an artifact a CI run published. The gate templates live under `quality-gate/`:

| CI provider | Template |
|--|--|
| GitHub Actions | `quality-gate/github-actions/quality-gate.yml.tmpl` |
| Azure DevOps | `quality-gate/azure-devops/azure-pipelines.quality-gate.yml.tmpl` |
| GitLab CI | `quality-gate/gitlab-ci/.gitlab-ci.quality-gate.yml.tmpl` |
| Jenkins | `quality-gate/jenkins/Jenkinsfile.quality-gate.tmpl` |

Rules every template (including future `{target}/{ci}` cells) must keep:

- Run with `--require`: a missing scanner is an error in CI, never deferred.
- Fail the job on exit `1` (violations) **and** exit `3` (deferred). Deferred
  is not a pass anywhere, and CI has no human to defer to.
- Install scanners (gitleaks, osv-scanner, semgrep, syft, trivy) with pinned
  versions and checksum verification, declared in the reviewed pipeline file.
  Locally they are installed only through the toolchain-preflight human gate.
- Restore the declared stack's toolchain and project dependencies before the
  gate; the gate never installs dependencies.
- Publish `quality-gate.json` and `TestResults/` as build evidence.

## Contributing a template

To land a real template for a cell of the matrix:

1. Pick the `{target} x {ci}` cell. Read the matching dialect first:
   - Cloud targets -> [[../../protocols/dialects/devops-cloud]]
   - On-prem / Kubernetes targets -> [[../../protocols/dialects/devops-k8s-onprem-agnostic]]
2. Start from the provider's `ci/` and `deploy/` templates and write the
   cell under `{target}/{ci}/pipeline.yml.tmpl` (or the CI's canonical
   filename: `azure-pipelines.yml.tmpl`, `.gitlab-ci.yml.tmpl`,
   `Jenkinsfile.tmpl`), replacing the deploy placeholders with commands you
   have run against that target.
3. Required stages per template, even if no-op for some targets:
   - **quality-gate** - FIRST stage, mandatory in every provider template:
     `bash .KCC/tools/quality-gate.sh --spec {{spec_id}} --require`; the job
     fails on exit 1 (violations) and on exit 3 (deferred). Copy it from the
     provider file under `quality-gate/` (see above).
   - **lint** - run dialect-appropriate linters
   - **test** - run dialect-appropriate test suite
   - **build** - produce the deployable artifact
   - **plan** - IaC plan / diff against the live target (never apply)
   - **deploy** - `dev` -> `staging` -> `production`; manual start only;
     staging and production require the provider's environment protection
     and explicit human approval
   - **smoke** - post-deploy verification
   - **rollback** - documented procedure, manual trigger
4. Required guardrails per the dialect's review checklist:
   secrets, IAM / RBAC, network exposure, cost, observability, DR, SLOs,
   destructive actions.
5. Update the matrix cell in this README from `provider templates` to
   `ready ({your-name})`.
6. Open a PR against the `.KCC/kernel/templates/` tree. Templates are
   kernel material - they need a kernel-maintainer review per the
   maintainer roles in the root [`README.md`](../../../../README.md).

Templates SHOULD NOT contain production secrets, account IDs, project IDs,
or environment-specific values. Use placeholders and document the required
variables.

## Related

- Deployment protocol: [[../../protocols/deployment]]
- Git workflow protocol: [[../../protocols/git-workflow]]
- Infrastructure implementer agent: [[../../../capabilities/agents/infrastructure-implementer]]
- Spec deploy skill: [[../../../capabilities/skills/spec-deploy]]
- DevOps cloud dialect: [[../../protocols/dialects/devops-cloud]]
- DevOps k8s/on-prem dialect: [[../../protocols/dialects/devops-k8s-onprem-agnostic]]
- Templates index: [[../README|templates README]]
