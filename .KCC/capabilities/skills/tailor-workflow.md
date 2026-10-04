---
# Functional fields (consumed by harness adapters)
name: tailor-workflow
description: >
 Draft solution-specific additions to the KCC workflow from the recorded solution context: agent addenda, custom agents, and custom skills, written as reviewable drafts under `migrations/TAILOR-{NNN}/` and never auto-promoted. Run after `kcc tailor`. Usage: /tailor-workflow [focus or extra context]
argument-placeholder: <ARGS>
delegates-to: []
maturity: L1
maintainer: tarek.fawaz1983@gmail.com
copyright: "KCC framework (c) 2026 Tarek Fawaz"
homepage: "https://tikasway.dev/kcc"
license: "Licensed under the terms in LICENSE"

# Obsidian metadata (used in the vault, ignored by harness adapters)
title: Tailor Workflow Skill
aliases:
  - tailor-workflow-skill
  - workflow-tailoring
tags:
  - framework/skill
  - tailoring
  - hitl
created: 2026-10-04
updated: 2026-10-04
version: 1.0.0
status: active
---

# Tailor Workflow

Extra context from the human: <ARGS>

Deterministic pruning is already done by `kcc tailor`
(`.KCC/kernel/protocols/tailoring.md`). This skill adds what a rule table
cannot: knowledge of this particular solution. It only writes drafts.

## Steps

1. **Read the context.** `.KCC/settings.json -> tailoring` (stop and tell the
   human to run `kcc tailor` first if the section is missing),
   `.KCC/context.md` when present, and `solution/TechStack.md`,
   `solution/CodebaseMap.md`, `solution/RuntimeAndOperations.md` when a
   baseline exists. Read `coordination/orchestrator.md` for the agents that
   remain. Do not read agent bodies you are not going to amend.
2. **Find the gaps.** List only what the generic agents would get wrong or
   have to rediscover on every spawn for this solution, for example:
   - the real build, test, lint, and run commands and where they run;
   - repository layout rules and naming conventions already in use;
   - domain vocabulary and the entities that specs will keep mentioning;
   - mandatory checks of this organisation (review rules, compliance
     evidence, release steps);
   - a recurring task that deserves its own skill, or a role the generic set
     lacks.
   If nothing qualifies, say so and stop. An empty result is a valid result.
3. **Allocate** `migrations/TAILOR-{NNN}/` (next free number, three digits).
4. **Write `plan.md`:** one table row per proposal with: target (`addendum
   to <agent>` / `new agent` / `new skill`), the gap it closes, the evidence
   (file and line in the context or baseline), and the estimated tokens it
   adds per spawn. Order by value. Keep every addendum under 40 lines;
   prefer a pointer to an existing project file over copied text.
5. **Write the drafts** under `migrations/TAILOR-{NNN}/drafts/agents/` and
   `drafts/skills/`:
   - an addendum is a complete copy of the source agent with one new section
     `## Solution context` at the end, so promoting it is a file replace;
   - a new agent or skill follows `.KCC/kernel/contracts/agent-contract.md`
     or `skill-contract.md`, with `maturity: L1`;
   - nothing in a draft may weaken a quality gate, a confidence gate, the
     implementation lock, or the never-push and never-deploy rules.
6. **Hand over to the human.** Print the plan table and these steps:
   review `plan.md`; edit or delete drafts; move the accepted files into
   `.KCC/capabilities/agents/` or `.KCC/capabilities/skills/`; run
   `kcc sync`; run `kcc validate`.

## Rules

- Drafts are never promoted by an agent. Do not write under
  `.KCC/capabilities/`.
- Do not restore an agent, skill, or dialect that tailoring dropped. If the
  context shows it is needed, say so and ask the human to re-run
  `kcc tailor`.
- State confidence per `.KCC/kernel/contracts/confidence-contract.md`; below
  the threshold, invoke `/critical-human-gate`.
