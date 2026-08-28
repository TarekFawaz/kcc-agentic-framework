---
# Functional fields (consumed by harness adapters)
name: engineering-request-review
description: >
 Request a fresh code review of the current task: deliver the specification first, then the code quality evidence, so the reviewer checks the work against what the task required before judging quality. Usage: /engineering-request-review
argument-placeholder: <ARGS>
delegates-to: []
maturity: L1
maintainer: tarek.fawaz1983@gmail.com
copyright: "KCC framework (c) 2026 Tarek Fawaz"
homepage: "https://tikasway.dev/kcc"
license: "Licensed under the terms in LICENSE"
lifecycle-owner: false
upstream: obra/superpowers
upstream-url: https://github.com/obra/superpowers
upstream-commit: b36e0829c6d0140e93cfef2ca599b1b07d4a7797
upstream-license: MIT
adapted-from: skills/requesting-code-review/SKILL.md

# Obsidian metadata (used in the vault, ignored by harness adapters)
title: Engineering Request Review Skill
aliases:
  - engineering-request-review-skill
tags:
  - framework/skill
  - superpowers/engineering
created: 2026-08-28
updated: 2026-08-28
version: 1.0.0
status: active
---

# Engineering Request Review

Request a fresh review of the current task's changes before the task is
reported complete. The reviewer evaluates the work against what the task
required first, then judges quality.

## The request contract (specification first, then quality)

A review request must present the specification first, then the code
quality.

1. **Acceptance criteria.** State the acceptance criteria of the current
   task: the exact behaviors and constraints the task had to deliver.
2. **Specification first.** Restate each requirement the change targets
   and map every change to the requirement it satisfies. Unmapped changes
   are flagged as out of scope.
3. **Quality second.** Report the code quality evidence: the exact
   verification commands that were run, their output, and the test
   results that back each claim about the change.

## How to scope the request

- Give the reviewer the precise change scope (the diff or file set) and
  the current task context.
- State the exact commands that verify the change, with their recorded
  output, so the reviewer can re-run them.
- Never send the agent's session history in place of the change context.

## Acting on the review

- Fix critical findings before proceeding.
- Fix important findings before the task is reported complete.
- Note minor findings for the record.
- Disagree with evidence and reasoning, never by assertion.

## Attribution and boundary

Adapted from obra/superpowers
(https://github.com/obra/superpowers, MIT License) at pinned commit
`b36e0829c6d0140e93cfef2ca599b1b07d4a7797`; see
`THIRD_PARTY_NOTICES.md`. This skill is a bounded, task-local engineering
discipline: it governs the current task only and does not change task
scope.
