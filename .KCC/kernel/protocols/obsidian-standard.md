---
# Functional fields (none - this document defines a convention, it is not consumed by harness adapters)

# Obsidian metadata
title: Obsidian Frontmatter & Linking Standard
aliases:
  - obsidian-standard
  - vault-conventions
tags:
  - framework/protocol
  - documentation
created: 2026-05-24
updated: 2026-05-24
version: 1.0.0
status: active
copyright: "KCC framework (c) 2026 Tarek Fawaz"
homepage: "https://tikasway.dev/kcc"
license: "Licensed under the terms in LICENSE"
---

# Obsidian Frontmatter & Linking Standard

This document is the **canonical specification** for how every Markdown file
under `.KCC/kernel/`, `memory/`, `coordination/`, `specs/`, `Traces/`, and
`ideation/` should be structured so the whole repository can be opened as an
Obsidian vault without losing any harness-adapter functionality.

The standard has three pillars:

1. **Single combined YAML frontmatter block** - functional fields (consumed
   by [[sync-adapters]] and harness runtimes) plus Obsidian metadata
   (consumed only by the vault UI and search).
2. **`[[wikilinks]]`** between in-vault Markdown documents; standard
   Markdown links for external URLs and code references.
3. **Per-folder MOC (Map-of-Content) files** that index the contents of the
   folder for human discovery.

The mini-YAML parser inside [[sync-adapters]] ignores unknown keys, so
adding the Obsidian metadata block alongside existing functional keys is
safe for the Claude and Codex adapter outputs.

---

## 1. Frontmatter block

Every Markdown file gets **one** YAML frontmatter block at the top with two
groups separated by a `# ...` YAML comment line:

```yaml
---
# Functional fields (type-specific; consumed by harness adapters)
# (keep existing fields exactly as they are; do not rename or reorder)

# Obsidian metadata (used in the vault, ignored by harness adapters)
title: <Human-readable title>
aliases:
  - <alt-name-1>
tags:
  - framework/<category>
  - lifecycle/<stage>          # when relevant
  - model-class/<class>        # for agents only
created: YYYY-MM-DD
updated: YYYY-MM-DD
version: 1.1.0
status: active
copyright: "KCC framework (c) 2026 Tarek Fawaz"
homepage: "https://tikasway.dev/kcc"
license: "Licensed under the terms in LICENSE"
---
```

### 1.1 Required Obsidian fields

| Field      | Type    | Notes                                                                                  |
|--|--|--|
| `title`    | string  | Human-readable title; may differ from filename.                                        |
| `tags`     | list    | At least one tag from the top-level taxonomy in section 2.                             |
| `created`  | date    | ISO date (YYYY-MM-DD). Set once on creation; never modified after.                     |
| `updated`  | date    | ISO date. Bump on every substantive edit.                                              |
| `version`  | semver  | `MAJOR.MINOR.PATCH`. See versioning rules below.                                       |
| `status`   | enum    | `active` \| `draft` \| `deprecated` \| `superseded`.                                   |

### 1.2 Optional Obsidian fields

| Field        | Type    | Notes                                                                              |
|--|--|--|
| `aliases`    | list    | Alternative names the file may be linked by (e.g. legacy filenames).               |
| `cssclasses` | list    | Obsidian CSS class overrides (rarely needed).                                      |
| `publish`    | bool    | For Obsidian Publish workflows; unused by default.                                 |

### 1.3 Versioning rules

- **1.0.0** - initial version of a brand-new file.
- **1.1.0** - backward-compatible additions (e.g. adding Obsidian metadata
  to an existing file that previously had only functional fields).
- **2.0.0** - breaking changes to the file's intent or required contract
  (e.g. renaming a required functional field; reshaping the body sections
  that downstream agents depend on).

When `version` is bumped, also bump `updated`. When a file is replaced by
another, set its `status` to `superseded` and add a body note pointing at
the replacement via `[[wikilink]]`.

### 1.4 Functional-field preservation

The Obsidian block is **additive**. Do not rename or remove existing
functional keys (`name`, `role`, `model-class`, `description`,
`tools-required`, `inputs`, `outputs`, `argument-placeholder`,
`delegates-to`, etc.). The [[sync-adapters]] script and the harness
runtimes read those keys by name; the order does not matter, but the
spellings do.

---

## 2. Tag taxonomy

Tags use forward-slash hierarchy (Obsidian's native convention). Pick at
least one top-level tag; add lifecycle and model-class tags when they apply.

### 2.1 Top-level categories

| Top-level tag          | Use for                                                                |
|--|--|
| `framework/agent`      | Files under `.KCC/capabilities/agents/` describing an agent role.              |
| `framework/skill`      | Files under `.KCC/capabilities/skills/` describing a slash-command skill.      |
| `framework/protocol`   | Files under `.KCC/kernel/protocols/` defining cross-cutting protocols.   |
| `framework/template`   | Files under `.KCC/kernel/templates/`.                                    |
| `framework/adapter`    | Files under `.KCC/kernel/adapters/` describing a harness adapter.        |
| `framework/documentation` | Framework-level README / entrypoint docs.                           |
| `memory`               | Files under `memory/` (README, schema, MOC, entries).                  |
| `memory/decision`      | Memory entry of type `decision`.                                       |
| `memory/pattern`       | Memory entry of type `pattern`.                                        |
| `memory/incident`      | Memory entry of type `incident`.                                       |
| `memory/preference`    | Memory entry of type `preference`.                                     |
| `memory/glossary`      | Memory entry of type `glossary`.                                       |
| `spec`                 | Files under `specs/` (specs, plans, reviews).                          |
| `trace`                | Files under `Traces/` (session records).                               |
| `ideation`             | Files under `ideation/` (idea briefings).                              |
| `coordination`         | Files under `coordination/` (parallel-agent backchannel).              |
| `quickstart`           | The root `QUICKSTART.md` and related onboarding docs.                  |
| `documentation`        | Generic catch-all for prose documentation that isn't framework code.   |
| `entrypoint`           | MOC files and folder READMEs that serve as starting points.            |
| `examples`             | Files demonstrating a concept via worked examples.                     |

### 2.2 Lifecycle sub-tags (orthogonal)

Apply when the file pertains to a specific lifecycle stage:

| Tag                       | Stage                                                |
|--|--|
| `lifecycle/interrogate`   | Idea interrogation (pre-spec).                       |
| `lifecycle/create`        | Spec creation.                                       |
| `lifecycle/plan`          | Planning.                                            |
| `lifecycle/implement`     | Implementation.                                      |
| `lifecycle/test`          | Verification / testing.                              |
| `lifecycle/review`        | Review.                                              |
| `lifecycle/meta`          | Cross-cutting (butler, token-guard, etc.).           |

### 2.3 Model-class sub-tags (agents only)

| Tag                                | Maps to                                 |
|--|--|
| `model-class/strong-reasoning`     | Opus / GPT-5.x / Gemini Ultra.          |
| `model-class/balanced`             | Sonnet / GPT-5 mini / Qwen3-max.        |
| `model-class/fast-implementation`  | Haiku / GPT-5 nano / Llama-3-70B.       |
| `model-class/local-strong`         | Ollama >32B.                            |
| `model-class/local-fast`           | Ollama <14B.                            |

### 2.4 Harness sub-tags (adapters only)

| Tag                  | Adapter                |
|--|--|
| `harness/claude`     | Claude Code.           |
| `harness/codex`      | OpenAI Codex CLI.      |
| `harness/opencode`   | OpenCode.              |
| `harness/ollama`     | Ollama runner.         |

### 2.5 Cross-cutting sub-tags

| Tag               | Use for                                                      |
|--|--|
| `cross-harness`   | Anything that defines or describes inter-harness behavior.   |
| `examples`        | Files whose primary purpose is worked examples.              |
| `documentation`   | Prose docs that supplement a primary artifact.               |
| `entrypoint`      | Folder MOCs / READMEs.                                       |

---

## 3. Wikilinks

### 3.1 When to use `[[wikilinks]]`

Use `[[wikilinks]]` whenever you reference another Markdown file inside the
vault (framework, memory, coordination, specs, traces, ideation). Obsidian
resolves them by filename (without `.md`), so:

```markdown
The [[architect]] agent produces decisions consumed by [[planner]].
See [[obsidian-standard]] for the frontmatter rules and
[[handover]] for cross-harness handoffs.
```

is preferred over:

```markdown
The [architect](./.KCC/capabilities/agents/architect.md) agent produces decisions
consumed by [planner](./.KCC/capabilities/agents/planner.md).
```

### 3.2 When to use standard Markdown links

Keep standard Markdown links for:

- External URLs (`https://...`).
- References to source-code files that are not Markdown (e.g. `src/api/throttle.ts`).
- References to non-Markdown configuration files (e.g. `.claude/settings.json`).

### 3.3 Ambiguous filenames

When two files share the same basename (e.g. `.KCC/capabilities/skills/idea-interrogator.md`
and `.KCC/capabilities/agents/idea-interrogator.md`), Obsidian will warn on
ambiguous links. Disambiguate with a folder prefix:

```markdown
The [[agents/idea-interrogator]] role is invoked by the
[[skills/idea-interrogator]] skill.
```

### 3.4 Memory cross-links

Memory entries reference each other with `[[DEC-001]]`, `[[PAT-005]]`, etc.
The filename convention (one entry per file, ID as filename) makes this
unambiguous.

---

## 4. Map-of-Content (MOC) files

Every folder containing more than a few Markdown files should have a MOC
that links its contents. MOCs use the convention:

- Filename: `{folder-name}.md` (e.g. `memory/memory.md`,
  `.KCC/capabilities/agents/agents.md`) **or** `README.md` if the folder already
  has one and it serves the MOC role.
- Frontmatter tag includes `entrypoint`.
- Body: a brief overview, then a table or bulleted list of the folder's
  contents with `[[wikilinks]]` and one-line descriptions.

Special framework MOCs:

- `ideation/ideas.md` links to each idea's parent file, e.g.
  `[[IDEA-001-csv-to-json/idea-001-csv-to-json|IDEA-001-csv-to-json]]`.
- `specs/specs.md` links to each epic spec's same-name folder note, e.g.
  `[[SPEC-001-csv-to-json/SPEC-001-csv-to-json|SPEC-001]]`.

Example MOC body:

```markdown
## Overview
This folder holds the agent definitions...

## Agents
- [[architect]] - design decisions and trade-off analysis.
- [[planner]] - turns specs into ordered implementation plans.
- [[implementer]] - executes plans, writes code, commits.
```

---

## 5. Examples by file type

### 5.1 Agent file

```yaml
---
# Functional fields
name: architect
role: architecture analyst
model-class: strong-reasoning
description: >
  Analyzes design trade-offs...
tools-required:
  - read
  - search
inputs: A design question...
outputs: A structured analysis...

# Obsidian metadata
title: Architect Agent
aliases:
  - architect
tags:
  - framework/agent
  - model-class/strong-reasoning
created: 2026-05-24
updated: 2026-05-24
version: 1.1.0
status: active
copyright: "KCC framework (c) 2026 Tarek Fawaz"
homepage: "https://tikasway.dev/kcc"
license: "Licensed under the terms in LICENSE"
---
```

### 5.2 Skill file

```yaml
---
# Functional fields
name: spec-plan
description: Create an implementation plan for a spec...
argument-placeholder: <ARGS>
delegates-to:
  - planner

# Obsidian metadata
title: Spec Plan Skill
tags:
  - framework/skill
  - lifecycle/plan
created: 2026-05-24
updated: 2026-05-24
version: 1.1.0
status: active
copyright: "KCC framework (c) 2026 Tarek Fawaz"
homepage: "https://tikasway.dev/kcc"
license: "Licensed under the terms in LICENSE"
---
```

### 5.3 Protocol file

```yaml
---
# Functional fields (none - protocols are pure documentation)

# Obsidian metadata
title: Handover Envelope Protocol
aliases:
  - handover-envelope
tags:
  - framework/protocol
  - cross-harness
created: 2026-05-24
updated: 2026-05-24
version: 1.1.0
status: active
copyright: "KCC framework (c) 2026 Tarek Fawaz"
homepage: "https://tikasway.dev/kcc"
license: "Licensed under the terms in LICENSE"
---
```

### 5.4 MOC file

```yaml
---
# Functional fields (none - MOCs are pure documentation)

# Obsidian metadata
title: Memory Store (MOC)
aliases:
  - memory-moc
tags:
  - memory
  - entrypoint
created: 2026-05-24
updated: 2026-05-24
version: 1.0.0
status: active
copyright: "KCC framework (c) 2026 Tarek Fawaz"
homepage: "https://tikasway.dev/kcc"
license: "Licensed under the terms in LICENSE"
---
```

### 5.5 Memory entry

```yaml
---
# Functional fields (memory schema - see memory/schema.md)
id: DEC-001
type: decision
created: 2026-05-24T12:00:00Z
related-specs:
  - SPEC-003
summary: One-line summary...

# Obsidian metadata
title: DEC-001 - Pick Redis for rate-limiter counters
tags:
  - memory/decision
  - lifecycle/plan
updated: 2026-05-24
version: 1.0.0
status: active
copyright: "KCC framework (c) 2026 Tarek Fawaz"
homepage: "https://tikasway.dev/kcc"
license: "Licensed under the terms in LICENSE"
---
```

Note: memory entries already have `created` and `tags` in their functional
schema; the Obsidian block layers on `title`, `updated`, `version`, and
`status`. See [[memory/schema]] for the authoritative entry schema.

---

## 6. Migration checklist

When adding Obsidian frontmatter to a pre-existing file:

1. Open the file. Read all existing frontmatter keys.
2. **Keep every existing key exactly as written.** Do not rename, reorder,
   or remove anything functional.
3. Below the last functional key, insert a `# Obsidian metadata ...` YAML
   comment line.
4. Add `title`, `tags`, `created`, `updated`, `version`, `status` (and
   optionally `aliases`).
5. Bump `version` to `1.1.0` (additive change). Set `created` to the file's
   original creation date if known, otherwise today.
6. Inside the body, convert internal markdown links pointing to other
   in-vault Markdown files into `[[wikilinks]]`. Leave external URLs and
   code-reference links alone.
7. Save. Re-run [[sync-adapters]] if the file is under `.KCC/kernel/` or
   `.KCC/capabilities/`.

---

## 7. See also

- [[handover]] - cross-harness envelope protocol.
- [[handover-examples]] - worked handover envelopes.
- [[memory/schema]] - memory entry schema (also bound by this standard).
- `.KCC/kernel/README.md` - neutral agent and skill file formats.
