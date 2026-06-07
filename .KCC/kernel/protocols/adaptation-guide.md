---
title: Adaptation Guide
aliases:
  - migration-guide
  - workflow-adaptation
tags:
  - framework/protocol
  - migration
  - documentation
  - lifecycle/meta
created: 2026-05-24
updated: 2026-05-25
version: 1.1.0
status: active
copyright: "KCC framework (c) 2026 Tarek Fawaz"
homepage: "https://tikasway.dev/kcc"
license: "Licensed under the terms in LICENSE"
---

# Adaptation Guide

How the [[.KCC/capabilities/agents/migrator|migrator]] agent (driven by the
[[.KCC/capabilities/skills/adapt-workflow|/adapt-workflow]] skill) imports an existing
agentic workflow from another harness into this framework's local capability
source using the neutral [[.KCC/kernel/README|kernel format]].

This document is reference material. It defines the recognized source
formats, the on-disk layout the migrator produces, the manual promote-drafts
workflow, and the field/model mapping tables the migrator applies.

---

## Recognized source formats

| Format    | Detection signal                                              | Notes |
|--|--|--|
| Cursor    | `.cursor/rules/*.mdc`                                         | One `.mdc` per rule; YAML-ish frontmatter + body |
| Claude Code | `.claude/agents/*.md` and/or `.claude/skills/*/SKILL.md`    | Already very close to neutral format |
| Codex CLI | Root `AGENTS.md` (single catalog) - no `.opencode/` sibling   | Catalog-style; one document, many agent rows |
| OpenCode  | Root `AGENTS.md` **plus** `.opencode/` or `opencode.toml`     | Same file convention as Codex, disambiguated by sibling files |
| Aider     | `AIDER.md` and/or `.aider*` (e.g. `.aider.conf.yml`)          | Conventions + per-task prompt files |
| Generic   | `prompts/*.md` or `agents/*.md` with no other signal          | Free-form; expect low confidence and more `needs-review` |

### Minimal examples

**Cursor (`.cursor/rules/architect.mdc`):**

```mdc
---
description: Architecture reasoning rule
glob: "src/**/*.ts"
---
You are the architect. Trace data flow ...
```

**Claude Code (`.claude/agents/planner.md`):**

```md
---
model: claude-opus-4-6
description: Implementation planner
allowed-tools:
  - Read
  - Glob
---
# Planner
...
```

**Codex `AGENTS.md` row:**

```md
| `architect` | architecture analyst | gpt-5 | Design trade-offs |
```

**Aider `AIDER.md`:**

```md
# Conventions
- Use TDD
- Prefer composition
```

**Generic `prompts/refactor.md`:**

```md
You are a refactoring assistant. Given a file ...
```

---

## On-disk layout produced

The migrator never writes outside `migrations/IMPORT-{NNN}/`:

```text
migrations/
`-- IMPORT-{NNN}/
    |-- plan.md                  <- human-readable migration plan
    |-- mapping.md               <- per-source-file translation report
    `-- drafts/
        |-- agents/
        |   `-- {name}.md        <- draft, frontmatter `status: draft`
        `-- skills/
            `-- {name}.md        <- draft, frontmatter `status: draft`
```

`{NNN}` is zero-padded and monotonically increasing; old `IMPORT-*` folders
are never overwritten.

---

## Promote-drafts workflow (manual, deliberate)

Drafts are **not** auto-promoted. The human owns this step:

1. Open `migrations/IMPORT-{NNN}/plan.md`. Verify the inventory matches what
   you expected from the source workflow.
2. Open `migrations/IMPORT-{NNN}/mapping.md`. Address every "needs human
   review" row - either fix it in the corresponding draft or decide to drop
   the artifact.
3. Edit the files under `migrations/IMPORT-{NNN}/drafts/` in place. Change
   their frontmatter `status:` from `draft` to `active` once you are
   satisfied.
4. **Move** (not copy) accepted drafts:
   - `migrations/IMPORT-{NNN}/drafts/agents/*.md` -> `.KCC/capabilities/agents/`
   - `migrations/IMPORT-{NNN}/drafts/skills/*.md` -> `.KCC/capabilities/skills/`
5. Resolve naming collisions. Drafts that collided with existing files were
   suffixed `-imported` by the migrator; pick whether to replace, merge, or
   keep both.
6. Run `.KCC/tools/sync-adapters.ps1` so per-harness files (`.claude/`,
   `AGENTS.md`) regenerate from the new neutral sources.
7. Commit the move and the regenerated adapter outputs as one logical
   change. Keep `migrations/IMPORT-{NNN}/` in the repo as the provenance
   record - do not delete it.

If an import was a mistake, delete the entire `migrations/IMPORT-{NNN}/`
folder; nothing else needs reverting because no `.KCC/capabilities/` files were
touched.

---

## Field mapping tables

### Common neutral fields

| Source field                           | Neutral field           | Notes |
|--|--|--|
| Cursor `description:`                  | `description:`          | Copy verbatim |
| Cursor `glob:`                         | _(dropped)_             | Add a `mapping.md` note; neutral format has no per-file targeting |
| Cursor body                            | Agent body              | Reformat into `## Process` / `## Output Format` / `## Constraints` where possible |
| Claude `description:`                  | `description:`          | Copy verbatim |
| Claude `model:`                        | `model-class:`          | Use the table below |
| Claude `allowed-tools:`                | `tools-required:`       | Reverse-map via the [[.KCC/kernel/adapters/claude|Claude adapter]] tool table; combine `Glob`+`Grep` into `search`, `Write`+`Edit` into `edit`, `Bash(...)` into `exec` |
| Codex/OpenCode `AGENTS.md` table row   | One agent each          | Split the row into per-agent draft files; the row's "one-liner" becomes `description:` |
| Aider conventions in `AIDER.md`        | Project doc, not agent  | Surface as a `mapping.md` note; usually no neutral agent maps cleanly |
| Aider per-task prompt files            | Agent body              | Best-effort; flag for human |
| Generic `prompts/*.md` body            | Agent body              | Low confidence; usually needs `description:` invented and flagged |

### Model name -> neutral `model-class`

All rows below are sensible defaults - the human **must verify** during the
promote step (the migrator records the chosen class in `mapping.md`).

| Source model name                                   | Neutral `model-class`  |
|--|--|
| `claude-3-5-sonnet`, `claude-sonnet-4-x`            | `balanced`             |
| `claude-3-5-haiku`, `claude-haiku-4-x`              | `fast-implementation`  |
| `claude-opus-*` (any version)                       | `strong-reasoning`     |
| `gpt-5`, `gpt-5.x`                                  | `strong-reasoning`     |
| `gpt-5-mini`                                        | `balanced`             |
| `gpt-5-nano`, `gpt-4o-mini`                         | `fast-implementation`  |
| `qwen2.5:72b`, `llama3:70b`, `glm-4.5`              | `local-strong`         |
| `qwen2.5:7b`, `llama3:8b`                           | `local-fast`           |
| Anything else / unknown / not specified             | _(flag for human)_     |

### Tool name -> neutral tool

When mapping from a harness-specific tool list back to the neutral
`tools-required:` set, collapse to these five buckets:

| Concrete tool(s)                              | Neutral tool |
|--|--|
| `Read`, file-read, `read_file`                | `read`       |
| `Glob`, `Grep`, `find`, `ripgrep`             | `search`     |
| `Write`, `Edit`, `apply_patch`, `str_replace` | `edit`       |
| `Bash`, `Bash(...)`, `shell`, `exec`          | `exec`       |
| `WebSearch`, `WebFetch`, `browse`             | `web`        |

Anything outside these buckets is dropped with a `mapping.md` note.

---

## Status field convention

Every draft file the migrator writes carries `status: draft` in its Obsidian
frontmatter. The promote step flips this to `status: active`. Anything still
marked `status: draft` in `.KCC/capabilities/agents/` or `.KCC/capabilities/skills/` is, by
convention, treated as work-in-progress and is ignored by
`.KCC/tools/sync-adapters.ps1`.
