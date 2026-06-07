---
title: Security Policy
aliases:
  - security
  - security-policy
  - disclosure-policy
tags:
  - framework/documentation
  - kcc/governance
  - security
created: 2026-05-25
updated: 2026-05-25
version: 1.0.0
status: active
---

# Security Policy

KCC ships PowerShell tools, generated agent definitions, and shared
protocols that orchestrate other people's AI sessions. A security issue
in a capability or in the kernel can ripple across every cell that uses
it. This document explains how to report problems and what is in scope.

## Reporting a vulnerability

**Do not open a public GitHub issue for security reports.**

Email: `tarek.fawaz1983@gmail.com`

Please include:

- A short description of the issue and its impact.
- Reproduction steps (or a minimal capability/skill file that triggers
  the issue if applicable).
- The affected files, capability names, or generated cell paths.
- Your name and contact for follow-up (or "anonymous" if you prefer).

You will receive an acknowledgment within **5 business days**. We aim to
provide a triage assessment within **15 business days**, and a fix or
mitigation within **30 business days** for kernel-level issues and
**60 business days** for capability-level issues.

## What is in scope

- **Lethal Trifecta** matches in shipped capabilities (untrusted input +
  private data + external comms in the same agent without
  `confidence-gate: required`). See
  [`.KCC/kernel/protocols/lethal-trifecta.md`](./.KCC/kernel/protocols/lethal-trifecta.md).
- Capabilities that leak secrets, credentials, or memory entries beyond
  their declared `tools-required` scope.
- Capabilities that bypass the `critical-human-gate` skill in scenarios
  where v0.4 mandates human approval (security, compliance, financial,
  destructive operations).
- PowerShell tooling under `.KCC/tools/` that performs unsafe file
  operations, executes unsanitized input, or escalates privileges
  unexpectedly.
- Backchannel events (`coordination/backchannel.jsonl`) that record
  sensitive data without the proper redaction declared by the
  decision-trace contract.

## What is out of scope

- Security issues in the agent harnesses themselves (Claude Code, Codex
  CLI, OpenCode, Ollama) - please report those upstream to the harness
  maintainers.
- Security issues in models accessed through the harnesses.
- Self-imposed risk in a cell team's `<cell>/local/` additions - those
  are the cell team's responsibility, not the kernel's.

## Disclosure timeline

Once a fix is ready:

1. Maintainers prepare the patch privately.
2. A new release is published with a security advisory.
3. The advisory credits the reporter (or marks anonymous if requested).
4. Cell teams are encouraged to re-run
   `.KCC/tools/framework-init.ps1` and `validate-kcc.ps1` after the
   release.

## Hardening recommendations for cell teams

- Run `validate-kcc.ps1` in CI; treat any Lethal Trifecta warning as a
  blocking finding.
- Pin capability versions in your cell config; do not auto-update.
- Keep `coordination/backchannel.jsonl` out of public repositories
  (already covered by `.gitignore`).
- Restrict the `tools-required` field of every capability to the
  minimum it needs; reject PRs that broaden scope without a kernel ADR.

## Contact

`tarek.fawaz1983@gmail.com` - preferred.

For non-security questions about contribution or governance, see
[`CONTRIBUTING.md`](./CONTRIBUTING.md).

---

KCC framework (c) 2026 Tarek Fawaz, [tikasway.dev](https://tikasway.dev/kcc). Licensed under the terms in [LICENSE](./LICENSE).
