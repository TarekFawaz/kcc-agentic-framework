---
# Functional fields (consumed by harness adapters)
name: spec-deploy
description: >
  Generate deployment pipeline + IaC stubs for a spec from its approved
  infrastructure decision brief. Usage: /spec-deploy SPEC-{ID}
  [--ci=github-actions|azure-devops|gitlab-ci]
  [--cloud=aws|azure|gcp|onprem-k8s|onprem-bare-metal]
argument-placeholder: <ARGS>
delegates-to:
  - infrastructure-implementer
maturity: L1
maintainer: tarek.fawaz1983@gmail.com
copyright: "KCC framework (c) 2026 Tarek Fawaz"
homepage: "https://tikasway.dev/kcc"
license: "Licensed under the terms in LICENSE"

# Obsidian metadata (vault-only; ignored by harness adapters)
title: Spec Deploy Skill
aliases:
  - spec-deploy
  - deploy-skill
tags:
  - framework/skill
  - lifecycle/deploy
  - infrastructure
created: 2026-05-29
updated: 2026-05-29
version: 1.0.0
status: active
---

# Spec Deploy

Generate the deployment pipeline + IaC stubs for <ARGS>.

`/spec-deploy` is the OPTIONAL last step of the lifecycle. It runs only
after `/spec-review` returns an `APPROVED` verdict, only if the spec has an
approved `InfrastructureDecisionBrief.md`, and only when the human
explicitly opts in. Pipelines and IaC files are written; no deployment is
executed by the agent.

## Argument Parsing

1. Parse the SPEC-ID (required). Accept `SPEC-{ID}` or `SPEC-{ID}-{slug}`.
2. Parse optional flags:
   - `--ci=github-actions|azure-devops|gitlab-ci` (default: read from
     InfrastructureDecisionBrief; fall back to `github-actions` only if the
     brief and flag both say nothing - and surface this as an
     assumption).
   - `--cloud=aws|azure|gcp|onprem-k8s|onprem-bare-metal` (default: read
     from InfrastructureDecisionBrief; abort if the brief says nothing).
3. Reject Jenkins for v1.1 with the message
   `spec-deploy: jenkins is deferred to v1.2+; pick github-actions, azure-devops, or gitlab-ci`.

## Steps

1. **Locate the spec folder.** Resolve to
   `specs/IDEA-{ID}-{slug}-Specs/SPEC-{ID}-{slug}/`. Abort if not found.
2. **Require the brief.** Confirm an
   `InfrastructureDecisionBrief.md` exists either at the idea level
   (`ideation/IDEA-{ID}-{slug}/`) or inside the spec folder. If missing,
   abort with `spec-deploy: InfrastructureDecisionBrief.md not found -
   run /infrastructure-interrogator first` and exit cleanly.
3. **Require an approved review.** Confirm
   `specs/IDEA-{ID}-{slug}-Specs/SPEC-{ID}-{slug}/review.md` contains an
   `APPROVED` verdict. If not, refuse and tell the human to complete
   `/spec-review` first.
4. **Confirm human opt-in.** Display the planned target + CI + dialect +
   the list of files about to be created. Ask:
   `proceed with file generation / change CI / change cloud / abort`.
   No files are written until the human picks `proceed with file
   generation`.
5. **Invoke `infrastructure-implementer`.** Pass: SPEC-ID, resolved
   InfrastructureDecisionBrief path, target, CI provider, devops dialect.
6. **Display `deploy.md`.** After the agent returns, show the summary
   table from `deploy.md`, the list of files created, and the exact
   verification commands a human will run.
7. **Hard reminder.** Print:
   `Deployment is NOT executed. The agent only wrote pipeline and IaC files.
   YOU run the deployment commands. Review every artifact first.`

## Quality Gates

- Brief MUST exist before any file is written.
- An approved `/spec-review` verdict MUST exist before any file is written.
- Human MUST explicitly opt in at step 4 - no AutoPolicy override.
- The agent MUST emit `Confidence: NN%`. Below threshold triggers
  `/critical-human-gate` per the standard protocol.
- The agent MUST NOT run `terraform apply`, `kubectl apply`,
  `az ... create`, `aws ... create`, or any other environment-mutating
  command. Only read-only / lint / format / dry-run commands are allowed
  via `exec`.

## Related

- Infrastructure implementer: [[../agents/infrastructure-implementer]]
- Infrastructure planner: [[../agents/infrastructure-planner]]
- Infrastructure interrogator skill: [[infrastructure-interrogator]]
- Deployment protocol: [[../../kernel/protocols/deployment]]
- Pipeline templates matrix: [[../../kernel/templates/pipelines/README|pipeline templates]]
- Spec review skill: [[spec-review]]
- Spec test skill: [[spec-test]]
- Confidence gate: [[../../kernel/protocols/confidence-gate]]
- Critical human gate: [[critical-human-gate]]
