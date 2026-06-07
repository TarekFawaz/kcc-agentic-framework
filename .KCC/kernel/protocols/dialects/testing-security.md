---
title: Testing Security Dialect
tags: [kcc/kernel, dialects, testing, security]
created: 2026-05-29
updated: 2026-05-29
version: 0.1.0
status: active
copyright: "KCC framework (c) 2026 Tarek Fawaz"
homepage: "https://tikasway.dev/kcc"
license: "Licensed under the terms in LICENSE"
---

# Testing Security Dialect

Use only when security is explicitly scoped during interrogation (sensitive
data, identity, public exposure, compliance, audit, secrets, payments).
Optional by default. When selected, the planner enumerates atomic security
test cases inside `plan.md` and the implementer translates each into real
test code under the per-idea workspace.

## Coding
- Place security tests under `tests/security/` inside
  `src/IDEA-{ID}-{slug}/`.
- Cover at minimum: authz boundaries, authn failures, input validation,
  injection vectors, secret handling, and audit-log emission for each
  scoped AC.
- Test IDs from `plan.md` (`T-NNN`) must appear in the scenario name.
- Never check real secrets into the repo; use fake credentials and assert
  redaction in logs/errors.

## Review
- Each security AC has an explicit negative test (the system rejects the
  bad input / unauthorized actor / tampered token).
- Audit/log assertions verify that the right event fires with the right
  redactions.

## Bug Fix
- Reproduce with a failing security test that demonstrates the vulnerability,
  patch, then keep the test as a permanent regression guard.

## Testing
- Run in CI on every change to security-relevant files. Mark the suite so it
  cannot be silently skipped.

## Docs
- README must document how to run the security suite and which threats it
  covers; link to the `SecurityDecisionBrief.md` for scope context.

## Complexity
- low: a handful of negative tests on one endpoint.
- medium: full authn/authz matrix for a service.
- high: multi-service trust boundary tests, token tampering, audit checks.
- extra-high: red-team simulation, fuzzing, compliance-mapped suites.
