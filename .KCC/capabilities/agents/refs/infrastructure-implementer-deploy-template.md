---
title: Infrastructure Implementer Deploy Template
tags:
  - framework/agent-ref
updated: 2026-10-04
---

# Infrastructure Implementer Deploy Template

## deploy.md

````markdown
# SPEC-{ID} Deploy Summary

## Source brief
- [[../../../ideation/IDEA-{ID}-{slug}/InfrastructureDecisionBrief|InfrastructureDecisionBrief.md]]

## Selected dialect
- {devops-cloud | devops-k8s-onprem-agnostic}

## Selected target + CI
- Target: {aws | azure | gcp | onprem-k8s | onprem-bare-metal}
- CI provider: {github-actions | azure-devops | gitlab-ci | jenkins}

## Artifacts created

| Kind | Path | Status | Verify with |
|--|--|--|--|
| Quality gate | `.github/workflows/kcc-quality-gate.yml` | ready | `gh workflow list` |
| CI pipeline | `.github/workflows/SPEC-{ID}-{slug}-ci.yml` | draft (placeholders open) | `gh workflow list` |
| Deploy pipeline | `.github/workflows/SPEC-{ID}-{slug}-deploy.yml` | draft (placeholders open) | `gh workflow list` |
| Terraform | `infrastructure/terraform/SPEC-{ID}-{slug}/main.tf` | stub | `terraform fmt && terraform validate` |
| Helm | `infrastructure/helm/SPEC-{ID}-{slug}/Chart.yaml` | stub | `helm lint infrastructure/helm/SPEC-{ID}-{slug}` |

## Open placeholders
| File | Placeholder | Proposed command |
|--|--|--|
| `.github/workflows/SPEC-{ID}-{slug}-deploy.yml` | Deploy to dev | `{command}` |

## Approval controls to configure (human, before first use)
- {e.g. GitHub: Settings > Environments > `staging`, `production` -> required reviewers}

## Verification commands (human runs these)

```bash
# Lint pipeline
gh workflow list

# Validate IaC
terraform -chdir=infrastructure/terraform/SPEC-{ID}-{slug} fmt
terraform -chdir=infrastructure/terraform/SPEC-{ID}-{slug} validate
```

## Deployment commands (human runs these - NEVER the agent)

```bash
# Plan first
terraform -chdir=infrastructure/terraform/SPEC-{ID}-{slug} plan -out=tfplan

# Apply only after human review
terraform -chdir=infrastructure/terraform/SPEC-{ID}-{slug} apply tfplan
```

## Assumptions made
- ...

## Open questions for human
- ...

## Confidence
Confidence: NN%
````
