---
name: security-interrogator
description: >
 Interrogate security, data sensitivity, privacy, authentication, authorization, compliance, audit, and secrets concerns before spec or architecture commitments. Usage: /security-interrogator <idea-folder or spec request>
argument-placeholder: <ARGS>
delegates-to:
  - security-analyst
maturity: L1
maintainer: tarek.fawaz1983@gmail.com
copyright: "KCC framework (c) 2026 Tarek Fawaz"
homepage: "https://tikasway.dev/kcc"
license: "Licensed under the terms in LICENSE"

# Obsidian metadata (used in the vault, ignored by harness adapters)
title: Security Interrogator Skill
tags:
  - framework/skill
  - lifecycle/interrogate
  - security
created: 2026-05-25
updated: 2026-05-25
version: 0.5.0
status: active
---

# Security Interrogator

Interrogate security concerns for: <ARGS>

## Steps

1. Resolve `<ARGS>` to an idea folder, technical brief, or spec request.
2. Delegate to **security-analyst**.
3. Require `SecurityDecisionBrief.md` when data, identity, integration,
   public exposure, or compliance risk exists.
4. Pass candidate guardrails and quality gates to architect and spec-writer.
5. If confidence is below the active threshold, invoke `/critical-human-gate`.

## Constraints

- Never assume authentication, authorization, compliance, or data sensitivity.
- Do not implement code.
