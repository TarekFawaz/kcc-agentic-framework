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
updated: 2026-09-21
version: 1.1.0
status: active
copyright: "KCC framework (c) 2026 Tarek Fawaz"
homepage: "https://tikasway.dev/kcc"
license: "Licensed under the terms in LICENSE"
---

# Pipeline Templates Matrix

This directory holds reference pipeline templates that the
[[../../capabilities/agents/infrastructure-implementer|infrastructure-implementer]]
agent instantiates per spec when `/spec-deploy` runs. Templates are
organized as `{target}/{ci-provider}/...`.

## Matrix status - v1.1

| Target / CI | GitHub Actions | Azure DevOps | GitLab CI | Jenkins |
|---|---|---|---|---|
| AWS | TBD v1.2 | TBD v1.2 | TBD v1.2 | TBD v1.2+ |
| Azure | TBD v1.2 | TBD v1.2 | TBD v1.2 | TBD v1.2+ |
| GCP | TBD v1.2 | TBD v1.2 | TBD v1.2 | TBD v1.2+ |
| On-prem k8s | TBD v1.2 | TBD v1.2 | TBD v1.2 | TBD v1.2+ |
| On-prem bare-metal | TBD v1.2 | TBD v1.2 | TBD v1.2 | TBD v1.2+ |

Mobile app stores (Apple App Store, Google Play) are deferred to **v1.3+**.

For v1.1, when `infrastructure-implementer` cannot find a real template for
the requested `{target} x {ci}` cell, it generates a placeholder pipeline
file containing:

- A `# TBD v1.2 - see .KCC/kernel/templates/pipelines/README.md` banner.
- Comments explaining what each pipeline stage must do for that target.
- A link back to the spec's `deploy.md` and to this README.

This is deliberate: shipping fabricated templates without the per-cloud
expertise to validate them is worse than shipping honest placeholders that
flag the gap.

## Directory layout (when templates land)

```text
.KCC/kernel/templates/pipelines/
|-- README.md                       <- this file
|-- quality-gate/                   <- mandatory first stage, one file per CI provider
|   |-- github-actions/quality-gate.yml.tmpl
|   |-- azure-devops/azure-pipelines.quality-gate.yml.tmpl
|   |-- gitlab-ci/.gitlab-ci.quality-gate.yml.tmpl
|   `-- jenkins/Jenkinsfile.quality-gate.tmpl
|-- aws/
|   |-- github-actions/
|   |   `-- pipeline.yml.tmpl
|   |-- azure-devops/
|   |   `-- pipeline.yml.tmpl
|   `-- gitlab-ci/
|       `-- pipeline.yml.tmpl
|-- azure/
|   |-- github-actions/
|   |-- azure-devops/
|   `-- gitlab-ci/
|-- gcp/
|   |-- github-actions/
|   |-- azure-devops/
|   `-- gitlab-ci/
|-- onprem-k8s/
|   |-- github-actions/
|   |-- azure-devops/
|   `-- gitlab-ci/
`-- onprem-bare-metal/
    |-- github-actions/
    |-- azure-devops/
    `-- gitlab-ci/
```

Each template file is a CI-native pipeline document (`pipeline.yml.tmpl`,
`azure-pipelines.yml.tmpl`, `.gitlab-ci.yml.tmpl`) with `{{spec_id}}`,
`{{spec_slug}}`, `{{idea_id}}`, `{{idea_slug}}`, `{{target}}`, and
`{{dialect}}` substitution placeholders.

## Mandatory quality-gate stage

Every provider template runs the KCC quality gate
([`quality-gate.sh`](../../../tools/quality-gate.sh), bash on a Linux runner)
before any build, plan, or deploy stage. Ready-to-use stage templates live
under `quality-gate/`:

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
2. Write the template under `{target}/{ci}/pipeline.yml.tmpl` (or the
   CI's canonical filename: `azure-pipelines.yml.tmpl`,
   `.gitlab-ci.yml.tmpl`).
3. Required stages per template, even if no-op for some targets:
   - **quality-gate** - FIRST stage, mandatory in every provider template:
     `bash .KCC/tools/quality-gate.sh --spec {{spec_id}} --require`; the job
     fails on exit 1 (violations) and on exit 3 (deferred). Copy it from the
     provider file under `quality-gate/` (see above).
   - **lint** - run dialect-appropriate linters
   - **test** - run dialect-appropriate test suite
   - **build** - produce the deployable artifact
   - **plan** - IaC plan / diff against the live target (never apply)
   - **deploy** - guarded: requires environment-protection rule and
     explicit human approval in the CI provider's review UI
   - **smoke** - post-deploy verification
   - **rollback** - documented procedure, manual trigger
4. Required guardrails per the dialect's review checklist:
   secrets, IAM / RBAC, network exposure, cost, observability, DR, SLOs,
   destructive actions.
5. Update the matrix row in this README from `TBD v1.2` to `v1.2 ready
   ({your-name})`.
6. Open a PR against the `.KCC/kernel/templates/` tree. Templates are
   kernel material - they need a kernel-maintainer review per the
   maintainer roles in the root [`README.md`](../../../../README.md).

Templates SHOULD NOT contain production secrets, account IDs, project IDs,
or environment-specific values. Use placeholders and document the required
variables.

## Related

- Deployment protocol: [[../../protocols/deployment]]
- Infrastructure implementer agent: [[../../../capabilities/agents/infrastructure-implementer]]
- Spec deploy skill: [[../../../capabilities/skills/spec-deploy]]
- DevOps cloud dialect: [[../../protocols/dialects/devops-cloud]]
- DevOps k8s/on-prem dialect: [[../../protocols/dialects/devops-k8s-onprem-agnostic]]
- Templates index: [[../README|templates README]]
