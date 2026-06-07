---
# Functional fields (consumed by harness adapters)
name: technical-interrogator
description: >
 Interrogate the human about technical decisions, architecture depth, and candidate dialects before spec creation, then produce a TechnicalDecisionBrief for the architect. Usage: /technical-interrogator <idea-folder or spec request>
argument-placeholder: <ARGS>
delegates-to:
  - technical-interrogator
maturity: L1
maintainer: tarek.fawaz1983@gmail.com
copyright: "KCC framework (c) 2026 Tarek Fawaz"
homepage: "https://tikasway.dev/kcc"
license: "Licensed under the terms in LICENSE"

# Obsidian metadata (used in the vault, ignored by harness adapters)
title: Technical Interrogator Skill
aliases:
  - technical-interrogator-skill
tags:
  - framework/skill
  - lifecycle/interrogate
  - architecture
created: 2026-05-24
updated: 2026-05-25
version: 1.3.0
status: active
---

# Technical Interrogator

Interrogate technical decisions for: <ARGS>

## Steps

1. Resolve `<ARGS>` to a source idea folder, `SpecWriterStarter.md`, or ad-hoc
   spec request.
2. Delegate to the **technical-interrogator** agent. Pass AutoPolicy context
   when invoked from `auto --silent --assume`.
3. Confirm the output includes `TechnicalDecisionBrief.md` when a source idea
   folder exists, or an inline technical decision brief for ad-hoc requests.
   The brief must include architecture depth, candidate technical approach,
   selected or candidate tech stack, selected KCC dialects from
   `.KCC/kernel/protocols/dialects/`, and open technical decisions.
4. If the agent reports confidence below the configured threshold (95% by
   default), invoke `/critical-human-gate` and pause `/spec-create`.
5. Pass the technical decision brief to the **architect**, specialist
   interrogators, and **spec-writer**.

## Auto Invocation

`/spec-create` must invoke this skill before delegating to `spec-writer` unless
a fresh `TechnicalDecisionBrief.md` already exists and the human confirms it is
still valid.

In `auto --silent --assume` mode, this skill may document low-risk technical
defaults instead of asking every question. It must still ask for or gate any
security, privacy, compliance, data sensitivity, authorization, external spend,
deployment, or production-impacting decision.
