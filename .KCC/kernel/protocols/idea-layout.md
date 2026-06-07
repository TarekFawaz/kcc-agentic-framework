---
# Functional fields
description: Folder convention for every idea in the framework.
inputs: An IDEA-ID and working title chosen by the idea-interrogator agent.
outputs: An `ideation/IDEA-{ID}-{slug}/` folder with `idea-{ID}-{slug}.md` as the parent file and linked supporting artifacts.

# Obsidian metadata
title: "Idea Folder Layout Protocol"
aliases:
  - idea-layout
  - idea folder convention
tags:
  - framework/protocol
  - ideation
  - documentation
created: 2026-05-24
updated: 2026-06-04
version: 1.2.0
status: active
copyright: "KCC framework (c) 2026 Tarek Fawaz"
homepage: "https://tikasway.dev/kcc"
license: "Licensed under the terms in LICENSE"
---

# Idea Folder Layout

Every idea in this framework is a folder under `ideation/`. The folder's
parent file is always `idea-{ID}-{slug}.md`; every supporting artifact links
back to it. This keeps the ideation space Obsidian-native: the top-level
`ideas.md` MOC links to real idea files, and each idea file links to every
generated artifact.

---

## Folder shape

```text
ideation/
|-- ideas.md
|-- IDEA-{ID}-{slug}/
|   |-- idea-{ID}-{slug}.md
|   |-- Questionnaire.md
|   |-- HumanAnswers.md
|   |-- Research.md
|   |-- ROI.md
|   |-- Conclusion.md
|   |-- QuickRoadmap.md
|   `-- SpecWriterStarter.md
`-- IDEA-002-{slug}/
    `-- ...
```

Legacy folders may omit the slug (`IDEA-001/`), but new ideas should use
`IDEA-{ID}-{slug}/`. The IDEA-ID remains the durable identifier either way.

---

## Required files

| File | Owner | Purpose |
|--|--|--|
| `idea-{ID}-{slug}.md` | idea-interrogator | Parent idea file: brief, original human statement, idea planning, and links to all artifacts. |
| `Questionnaire.md` | idea-interrogator | Foundational questions and follow-up batches with stable question IDs. |
| `HumanAnswers.md` | idea-interrogator | Human answers and verified/corrected assumptions. |
| `Research.md` | idea-interrogator | Scoped prior art, references, compliance notes, and citations. |
| `ROI.md` | idea-interrogator + token-guard | Value, cost, payback, confidence, and token-budget forecasts. |
| `Conclusion.md` | idea-interrogator | Go/no-go synthesis and remaining unknowns. |
| `QuickRoadmap.md` | idea-interrogator | Phased roadmap and likely epics/specs. |
| `SpecWriterStarter.md` | idea-interrogator | Handoff briefing for `/spec-create`; may propose one or more epics. |

Every file must include Obsidian frontmatter and a `## Related` block with at
least:

```markdown
## Related

- Idea: [[idea-{ID}-{slug}]]
- All ideas: [[../ideas|Ideas MOC]]
```

---

## Body section ordering (REQUIRED)

Body sections in `idea-{ID}-{slug}.md` appear in this fixed order:

1. `## Original Request` — **first body section, before everything else.**
   The human's raw input verbatim. See below.
2. `## Reasoning` — the agent's interpretation/framing of the input.
3. `## Brief`
4. `## Original Human Statement` — retained legacy mirror of the verbatim
   text inside a fenced block (kept for backward compatibility; `## Original
   Request` is the canonical visible section).
5. `## Idea Planning`
6. `## Generated Files`
7. `## Phases`, `## Epics (likely specs)`, `## Effort Estimate`
8. `## Related`

`## Original Request` is REQUIRED and MUST precede `## Reasoning` so the
human's original words are the first thing a reader sees, never a paraphrase.
The raw text is ALSO preserved in the `source_prompt:` frontmatter field.

---

## `## Original Request` section (REQUIRED, first body section)

Holds the human's input **exactly as provided** — no paraphrase, no cleanup
beyond prefixing each line with a `>` blockquote marker. It also records the
**input class** so downstream agents know how the idea entered the framework:

- `raw-text` — the human typed/pasted an idea description directly.
- `file-path` — the input pointed at a file (PRD, notes, issue export).
- `existing-solution+idea` — the input references an onboarded solution plus a
  change idea.

Shape:

```markdown
## Original Request

**Input class:** raw-text | file-path | existing-solution+idea

> {the human's raw input, verbatim, each line prefixed with `> `}
```

The same verbatim text is stored in the `source_prompt:` frontmatter field of
`idea-{ID}-{slug}.md`.

---

## `idea-{ID}-{slug}.md` shape

````markdown
# IDEA-{ID}-{slug}: {Working Title}

## Original Request

**Input class:** raw-text | file-path | existing-solution+idea

> {the human's raw input, verbatim, blockquoted}

## Reasoning
{Interpretation / framing of the input. Paraphrase lives here, never above.}

## Brief
{One-paragraph summary of the idea after interrogation. While drafting, use
`> drafting - awaiting human answers`.}

## Original Human Statement

```text
{verbatim original idea exactly as provided by the human}
```

## Idea Planning

| Field | Value |
|--|--|
| Status | Drafting (then Ready for spec -> Handed off -> Parked or Abandoned) |
| Current step | {questionnaire | answers | research | ROI | conclusion | handoff} |
| Architecture depth | {minimal | standard | distributed | regulated} |
| Recommended handoff | `/spec-create` with [[SpecWriterStarter]] |
| Likely epics/specs | {links or "TBD"} |

## Generated Files

- Questionnaire: [[Questionnaire]]
- Human answers: [[HumanAnswers]]
- Research: [[Research]]
- ROI: [[ROI]]
- Conclusion: [[Conclusion]]
- Quick roadmap: [[QuickRoadmap]]
- Spec-writer starter: [[SpecWriterStarter]]

## Related

- All ideas: [[../ideas|Ideas MOC]]
- Source protocol: [[../../.KCC/kernel/protocols/idea-layout]]
````

Update `idea-{ID}-{slug}.md` as the interrogation progresses. It starts as a draft when
the folder is allocated and ends as the navigable summary after all artifacts
exist.

---

## Top-level MOC: `ideation/ideas.md`

`ideas.md` is the single landing page for ideation. It must link to the
actual parent file for every idea:

```markdown
| Idea | Date | Brief | ROI confidence | Status | Specs/Epics |
|--|--|--|--|--|--|
| [[IDEA-001-csv-to-json/idea-001-csv-to-json|IDEA-001-csv-to-json]] | 2026-05-24 | {one-line brief} | Medium | Ready for spec | TBD |
```

Do not leave plain-text IDEA IDs in this table once an idea folder exists.
The link target should be
`[[IDEA-{ID}-{slug}/idea-{ID}-{slug}|IDEA-{ID}-{slug}]]`.

---

## Status lifecycle

`Drafting` -> `Ready for spec` -> `Handed off` -> `Parked` -> `Abandoned`

Set an idea to `Ready for spec` only after `idea-{ID}-{slug}.md` and all required
supporting artifacts exist and link to each other.

---

## Related

- Spec layout: [[spec-layout]]
- Obsidian standard: [[obsidian-standard]]
- Idea interrogator agent: [[.KCC/capabilities/agents/idea-interrogator]]
- Idea interrogator skill: [[.KCC/capabilities/skills/idea-interrogator]]
