---
# Functional fields (none - protocols are pure prose)

# Obsidian metadata (used in the vault, ignored by harness adapters)
title: Depth Levels
aliases:
  - depthlevel
  - depth-levels
tags:
  - framework/protocol
  - token-economy
created: 2026-10-14
updated: 2026-10-14
version: 1.0.0
status: active
copyright: "KCC framework (c) 2026 Tarek Fawaz"
homepage: "https://tikasway.dev/kcc"
license: "Licensed under the terms in LICENSE"
---

# Depth Levels

`--depthlevel N` (1-5) controls how much detail agents write. Output tokens
are the main cost, so lower levels mean shorter files, not fewer files.
Level 5 is the framework's full detail and the default.

## Resolution

First hit wins: a skill's own `--depthlevel N` -> the AutoPolicy
(`coordination/run/run.json` -> `depthlevel`, set by `auto --depthlevel N`) ->
`.KCC/settings.json` -> `defaults.depthlevel` -> `5`. `auto --fasttrack`
defaults to `2` unless a level is given. Orchestrators pass the value in the
handover packet (`depthlevel`, omitted at 5). A missing or invalid value means 5.

## Level meaning and length targets

Targets are lines per file, as a fraction of the cap in
`.KCC/settings.json` -> `spec_sizing`. A cap is a ceiling at every level.

| Level | Style | Spec (cap 150) | Backlog item (cap 80) | Plan (cap 250) | Brief/ADR (cap 100) |
|--|--|--|--|--|--|
| 5 | Full detail, rationale, alternatives | up to 150 | up to 80 | up to 250 | up to 100 |
| 4 | Full structure, short rationale | <= 110 | <= 60 | <= 190 | <= 75 |
| 3 | Decisions and criteria, no alternatives prose | <= 75 | <= 40 | <= 125 | <= 50 |
| 2 | Bullets and tables only, one line per item | <= 45 | <= 25 | <= 75 | <= 30 |
| 1 | Essentials: IDs, ACs, tests, decisions | <= 25 | <= 15 | <= 40 | <= 15 |

## Defaults it sets (never overrides a human choice)

| Level | Architecture depth | `/solution-onboard --depth` | Interrogation |
|--|--|--|--|
| 1-2 | `lite` | `minimal` | Ask only blocking questions |
| 3-4 | `standard` | `standard` | Standard question set |
| 5 | `deep` only if the idea asks; else `standard` | `standard` (ask before `deep`) | Full question set |

An `architecture-depth` or `--depth` the human already chose always wins, and is
never raised later without approval.

## Floors (a lower level never removes these)

- Required sections and artifacts: spec sections (Delivery Brief, Acceptance
  Criteria, Backlog, Architecture), `plan.md` Waves and Atomic test cases,
  ROADMAP, `arch.md` with a mermaid block (full lifecycle; under `--fasttrack`
  the spec note's `## Architecture references` instead), the architecture
  minimums of the chosen depth or profile, `review.md` Evidence.
- Every acceptance criterion and its Test ID. Shortening may merge wording, not
  coverage.
- CR-7 prohibited-assumption escalation, the toolchain gate, and confidence
  gates.
- Security: security briefs and findings, threat and trust-boundary notes, and the
  secrets, dependency-audit, and SAST gates. `depthlevel` and `--fasttrack` shorten the
  prose around them, never the content or the check.

## Rules for agents

1. Aim at the level's target; never exceed the cap. Over the cap means cut
   prose and merge duplicates, not drop a required section.
2. Write each fact once; link to the file that owns it.
3. Tables and bullets over paragraphs. No restated inputs, no template
   boilerplate, no empty sections (write `n/a` once).
4. Reasoning stays out of artifacts; only decisions and their one-line why.
