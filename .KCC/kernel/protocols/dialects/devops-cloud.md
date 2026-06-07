---
title: DevOps Cloud Dialect
tags: [kcc/kernel, dialects, devops, cloud]
created: 2026-05-25
updated: 2026-05-25
version: 0.4.0
status: active
copyright: "KCC framework (c) 2026 Tarek Fawaz"
homepage: "https://tikasway.dev/kcc"
license: "Licensed under the terms in LICENSE"
---

# DevOps Cloud Dialect

Use for cloud infrastructure, CI/CD, deployment automation, and operations.

## Coding
- Prefer infrastructure as code, least privilege, explicit environments, idempotent scripts, and documented rollback.

## Review
- Check secrets, IAM, network exposure, cost, observability, DR, SLOs, and destructive actions.

## Bug Fix
- Reproduce in non-production or dry-run mode, patch narrowly, require human approval for destructive changes.

## Testing
- Use validation, plan/diff, lint, and non-production deployment checks where available.

## Docs
- README/runbook must include deploy, rollback, environment variables, ownership, and cost notes.

## Complexity
- low: junior-safe config/lint.
- medium: mid-level pipeline/resource.
- high: senior production-impacting infra.
- extra-high: principal-expert multi-cloud, regulated, DR, or cost-critical platform.
